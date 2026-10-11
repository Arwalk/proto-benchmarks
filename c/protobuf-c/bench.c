/* proto-benchmarks harness: protobuf-c (https://github.com/protobuf-c/protobuf-c).
 *
 * Implements the measurement loop of docs/HARNESS.md (mirrors tools/pyharness.py 1:1).
 * protobuf-c has no JSON support, so json_encode/json_decode are reported unsupported.
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include <protobuf-c/protobuf-c.h>
#include "bench.pb-c.h"

#define HARNESS_LANGUAGE "c"
#define HARNESS_NAME "protobuf-c"
#define JSON_UNSUPPORTED_REASON "protobuf-c has no JSON support"

/* ---------------------------------------------------------------- black hole */
static volatile uint64_t sink = 0;

/* ---------------------------------------------------------------- utilities */
static void die(const char *msg, const char *arg) {
    if (arg) fprintf(stderr, "error: %s: %s\n", msg, arg);
    else fprintf(stderr, "error: %s\n", msg);
    exit(1);
}

static int64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

static uint8_t *read_file(const char *path, size_t *len_out) {
    FILE *f = fopen(path, "rb");
    if (!f) die("cannot open", path);
    if (fseek(f, 0, SEEK_END) != 0) die("fseek failed", path);
    long n = ftell(f);
    if (n < 0) die("ftell failed", path);
    rewind(f);
    uint8_t *buf = malloc((size_t)n + 1);
    if (!buf) die("out of memory", path);
    if (n > 0 && fread(buf, 1, (size_t)n, f) != (size_t)n) die("short read", path);
    buf[n] = 0;
    fclose(f);
    *len_out = (size_t)n;
    return buf;
}

static void write_file(const char *path, const void *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) die("cannot write", path);
    if (len && fwrite(data, 1, len, f) != len) die("short write", path);
    fclose(f);
}

static void mkdir_p(const char *dir) {
    char tmp[4096];
    size_t n = strlen(dir);
    if (n == 0 || n >= sizeof tmp) die("bad directory", dir);
    memcpy(tmp, dir, n + 1);
    for (size_t i = 1; i < n; i++) {
        if (tmp[i] == '/') {
            tmp[i] = 0;
            if (mkdir(tmp, 0777) != 0 && errno != EEXIST) die("mkdir failed", tmp);
            tmp[i] = '/';
        }
    }
    if (mkdir(tmp, 0777) != 0 && errno != EEXIST) die("mkdir failed", tmp);
}

static void json_escape(FILE *f, const char *s) {
    fputc('"', f);
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { fputc('\\', f); fputc(c, f); }
        else if (c < 0x20) fprintf(f, "\\u%04x", c);
        else fputc(c, f);
    }
    fputc('"', f);
}

/* ---------------------------------------------------------------- datasets / types */
typedef struct {
    const char *name;
    void *(*unpack)(size_t len, const uint8_t *data);
    void (*free_unpacked)(void *msg);
    size_t (*get_packed_size)(const void *msg);
    size_t (*pack)(const void *msg, uint8_t *out);
    uint64_t (*scalar)(const void *msg);
} type_ops;

#define WRAP(T, prefix)                                                                     \
    static void *prefix##_unpack_w(size_t len, const uint8_t *data) {                       \
        return prefix##__unpack(NULL, len, data);                                           \
    }                                                                                       \
    static void prefix##_free_w(void *m) { prefix##__free_unpacked((T *)m, NULL); }         \
    static size_t prefix##_size_w(const void *m) { return prefix##__get_packed_size((const T *)m); } \
    static size_t prefix##_pack_w(const void *m, uint8_t *out) { return prefix##__pack((const T *)m, out); }

WRAP(Bench__SmallMessage, bench__small_message)
WRAP(Bench__MediumMessage, bench__medium_message)
WRAP(Bench__LargeMessage, bench__large_message)

static uint64_t small_scalar(const void *m) { return (uint64_t)(int64_t)((const Bench__SmallMessage *)m)->id; }
static uint64_t medium_scalar(const void *m) { return (uint64_t)((const Bench__MediumMessage *)m)->created_at; }
static uint64_t large_scalar(const void *m) {
    const char *s = ((const Bench__LargeMessage *)m)->source;
    return s ? (uint64_t)strlen(s) : 0;
}

static const type_ops TYPES[] = {
    {"small", bench__small_message_unpack_w, bench__small_message_free_w,
     bench__small_message_size_w, bench__small_message_pack_w, small_scalar},
    {"medium", bench__medium_message_unpack_w, bench__medium_message_free_w,
     bench__medium_message_size_w, bench__medium_message_pack_w, medium_scalar},
    {"large", bench__large_message_unpack_w, bench__large_message_free_w,
     bench__large_message_size_w, bench__large_message_pack_w, large_scalar},
};
#define NDATASETS 3

static const char *const OPS[] = {"wire_encode", "wire_decode", "json_encode", "json_decode"};
#define NOPS 4

/* ---------------------------------------------------------------- the four operations */
typedef struct {
    const type_ops *t;
    const uint8_t *wire;
    size_t wire_len;
    const void *fixture;
} op_ctx;

typedef void (*op_fn)(op_ctx *c);

/* one iteration of wire_decode: bytes -> message, scalar into the sink, message released */
static void op_wire_decode(op_ctx *c) {
    void *m = c->t->unpack(c->wire_len, c->wire);
    if (!m) die("unpack failed", c->t->name);
    sink ^= c->t->scalar(m);
    c->t->free_unpacked(m);
}

/* one iteration of wire_encode: message -> freshly allocated buffer, length into the sink */
static void op_wire_encode(op_ctx *c) {
    size_t n = c->t->get_packed_size(c->fixture);
    uint8_t *buf = malloc(n ? n : 1);
    if (!buf) die("out of memory", "pack");
    c->t->pack(c->fixture, buf);
    sink ^= (uint64_t)n;
    free(buf);
}

/* ---------------------------------------------------------------- measurement loop (HARNESS.md) */
typedef struct {
    uint64_t iterations;
    int64_t elapsed_ns;
} round_rec;

static void run_batch(op_fn fn, op_ctx *ctx, uint64_t batch) {
    for (uint64_t i = 0; i < batch; i++) fn(ctx);
}

/* steady-state warm-up: run probes of WARMUP_PROBE_NS and stop once the last STEADY_WINDOW probe
 * rates agree within STEADY_TOL (never before warmup_s, never after warmup_max_s) */
#define WARMUP_PROBE_NS 500000000LL
#define STEADY_WINDOW 3
#define STEADY_TOL 0.05

static uint64_t measure(op_fn fn, op_ctx *ctx, double warmup_s, double warmup_max_s, double round_s, int rounds,
                        round_rec *out, int64_t *warmup_ns_out, int *steady_out) {
    uint64_t batch = 1;
    for (;;) { /* calibration: double the batch until one batch takes >= 10 ms */
        int64_t t0 = now_ns();
        run_batch(fn, ctx, batch);
        if (now_ns() - t0 >= 10000000LL) break;
        batch *= 2;
    }
    int64_t min_ns = (int64_t)(warmup_s * 1e9);
    int64_t max_ns = (int64_t)(warmup_max_s * 1e9);
    if (max_ns < min_ns) max_ns = min_ns;
    double rates[STEADY_WINDOW];
    int n = 0, steady = 0;
    int64_t w0 = now_ns();
    for (;;) {
        int64_t elapsed = now_ns() - w0;
        if (elapsed >= max_ns) break;
        int64_t probe_ns = WARMUP_PROBE_NS;
        if (max_ns - elapsed < probe_ns) probe_ns = max_ns - elapsed;
        int64_t p0 = now_ns();
        uint64_t iters = 0;
        while (now_ns() - p0 < probe_ns) {
            run_batch(fn, ctx, batch);
            iters += batch;
        }
        rates[n % STEADY_WINDOW] = (double)iters * 1e9 / (double)(now_ns() - p0);
        n++;
        if (now_ns() - w0 >= min_ns && n >= STEADY_WINDOW) {
            double lo = rates[0], hi = rates[0];
            for (int i = 1; i < STEADY_WINDOW; i++) {
                if (rates[i] < lo) lo = rates[i];
                if (rates[i] > hi) hi = rates[i];
            }
            if (hi <= lo * (1.0 + STEADY_TOL)) { steady = 1; break; }
        }
    }
    *warmup_ns_out = now_ns() - w0;
    *steady_out = steady;
    int64_t round_ns = (int64_t)(round_s * 1e9);
    for (int r = 0; r < rounds; r++) {
        uint64_t iters = 0;
        int64_t start = now_ns();
        while (now_ns() - start < round_ns) {
            run_batch(fn, ctx, batch);
            iters += batch;
        }
        out[r].iterations = iters;
        out[r].elapsed_ns = now_ns() - start;
    }
    return batch;
}

/* ---------------------------------------------------------------- arguments */
typedef struct {
    const char *fixtures;
    const char *out;
    double warmup_seconds;
    double warmup_max_seconds;
    double round_seconds;
    int rounds;
    const char *datasets;
    const char *ops;
    const char *dump;
} args_t;

static void usage_error(const char *msg, const char *arg) {
    if (arg) fprintf(stderr, "error: %s: %s\n", msg, arg);
    else fprintf(stderr, "error: %s\n", msg);
    fprintf(stderr,
            "usage: bench --fixtures DIR --out FILE [--warmup-seconds F] [--warmup-max-seconds F]\n"
            "             [--round-seconds F] [--rounds N] [--datasets a,b] [--ops a,b] [--dump DIR]\n");
    exit(2);
}

static args_t parse_args(int argc, char **argv) {
    args_t a = {NULL, NULL, 3.0, 15.0, 1.0, 10, "small,medium,large",
                "wire_encode,wire_decode,json_encode,json_decode", NULL};
    for (int i = 1; i < argc; i++) {
        const char *k = argv[i];
        const char *v = NULL;
        char keybuf[64];
        const char *eq = strchr(k, '=');
        if (strncmp(k, "--", 2) == 0 && eq && (size_t)(eq - k) < sizeof keybuf) { /* --key=value */
            memcpy(keybuf, k, (size_t)(eq - k));
            keybuf[eq - k] = 0;
            k = keybuf;
            v = eq + 1;
        } else {
            if (i + 1 >= argc) usage_error("missing value for", k);
            v = argv[++i];
        }
        if (!strcmp(k, "--fixtures")) a.fixtures = v;
        else if (!strcmp(k, "--out")) a.out = v;
        else if (!strcmp(k, "--warmup-seconds")) a.warmup_seconds = strtod(v, NULL);
        else if (!strcmp(k, "--warmup-max-seconds")) a.warmup_max_seconds = strtod(v, NULL);
        else if (!strcmp(k, "--round-seconds")) a.round_seconds = strtod(v, NULL);
        else if (!strcmp(k, "--rounds")) a.rounds = atoi(v);
        else if (!strcmp(k, "--datasets")) a.datasets = v;
        else if (!strcmp(k, "--ops")) a.ops = v;
        else if (!strcmp(k, "--dump")) a.dump = v;
        else usage_error("unknown argument", k);
    }
    if (!a.fixtures) usage_error("--fixtures is required", NULL);
    if (!a.out) usage_error("--out is required", NULL);
    if (a.rounds < 1) usage_error("--rounds must be >= 1", NULL);
    if (a.warmup_seconds < 0 || a.warmup_max_seconds < 0 || a.round_seconds <= 0)
        usage_error("invalid duration (must not be negative)", NULL);
    return a;
}

/* Split a comma separated list and map each entry to an index in `names`; returns count. */
static int parse_list(const char *list, const char *const *names, int nnames, int *out, const char *what) {
    int n = 0;
    const char *p = list;
    while (*p) {
        const char *q = strchr(p, ',');
        size_t len = q ? (size_t)(q - p) : strlen(p);
        if (len > 0) {
            int found = -1;
            for (int i = 0; i < nnames; i++)
                if (strlen(names[i]) == len && !strncmp(names[i], p, len)) found = i;
            if (found < 0) {
                char tmp[64];
                snprintf(tmp, sizeof tmp, "%.*s", (int)(len < 60 ? len : 60), p);
                fprintf(stderr, "error: unknown %s %s\n", what, tmp);
                exit(2);
            }
            int dup = 0; /* each name is kept once, so n <= nnames */
            for (int i = 0; i < n; i++)
                if (out[i] == found) dup = 1;
            if (!dup) {
                if (n >= 16) die("too many entries", what);
                out[n++] = found;
            }
        }
        p = q ? q + 1 : p + len;
    }
    return n;
}

/* ---------------------------------------------------------------- result records */
typedef struct {
    const char *dataset;
    const char *operation;
    int supported;
    const char *reason;
    size_t payload_bytes;
    int wire_bytes_match, wire_size_match;
    int64_t warmup_ns;
    int steady;
    uint64_t batch;
    int nrounds;
    round_rec *rounds;
} result_rec;

static void write_results(const args_t *a, const result_rec *res, int nres) {
    FILE *f = fopen(a->out, "w");
    if (!f) die("cannot write", a->out);
    fprintf(f, "{\n \"schema_version\": 1,\n \"harness\": {\n");
    fprintf(f, "  \"language\": \"%s\",\n  \"name\": \"%s\",\n", HARNESS_LANGUAGE, HARNESS_NAME);
    fprintf(f, "  \"runtime\": ");
    json_escape(f, "gcc " __VERSION__);
    fprintf(f, ",\n  \"library_version\": ");
    json_escape(f, protobuf_c_version());
    fprintf(f, "\n },\n \"results\": [\n");
    for (int i = 0; i < nres; i++) {
        const result_rec *r = &res[i];
        fprintf(f, "  {\n   \"dataset\": \"%s\",\n   \"operation\": \"%s\",\n", r->dataset, r->operation);
        if (!r->supported) {
            fprintf(f, "   \"supported\": false,\n   \"reason\": ");
            json_escape(f, r->reason);
            fprintf(f, "\n  }");
        } else {
            fprintf(f, "   \"supported\": true,\n   \"payload_bytes\": %zu,\n", r->payload_bytes);
            fprintf(f, "   \"validation\": {\n    \"wire_bytes_match\": %s,\n    \"wire_size_match\": %s,\n"
                       "    \"json_roundtrip_ok\": null,\n    \"json_bytes\": null\n   },\n",
                    r->wire_bytes_match ? "true" : "false", r->wire_size_match ? "true" : "false");
            fprintf(f, "   \"warmup_ns\": %lld,\n   \"steady\": %s,\n", (long long)r->warmup_ns,
                    r->steady ? "true" : "false");
            fprintf(f, "   \"batch\": %llu,\n   \"rounds\": [\n", (unsigned long long)r->batch);
            for (int k = 0; k < r->nrounds; k++)
                fprintf(f, "    {\n     \"iterations\": %llu,\n     \"elapsed_ns\": %lld\n    }%s\n",
                        (unsigned long long)r->rounds[k].iterations, (long long)r->rounds[k].elapsed_ns,
                        k + 1 < r->nrounds ? "," : "");
            fprintf(f, "   ]\n  }");
        }
        fprintf(f, "%s\n", i + 1 < nres ? "," : "");
    }
    fprintf(f, " ]\n}\n");
    fclose(f);
}

/* ---------------------------------------------------------------- main */
int main(int argc, char **argv) {
    args_t a = parse_args(argc, argv);
    const char *dataset_names[NDATASETS];
    for (int i = 0; i < NDATASETS; i++) dataset_names[i] = TYPES[i].name;
    int ds_idx[16], op_idx[16];
    int nds = parse_list(a.datasets, dataset_names, NDATASETS, ds_idx, "dataset");
    int nops = parse_list(a.ops, OPS, NOPS, op_idx, "op");

    result_rec results[NDATASETS * NOPS];
    int nres = 0;

    for (int di = 0; di < nds; di++) {
        const type_ops *t = &TYPES[ds_idx[di]];
        char path[4096];
        size_t wire_len;
        snprintf(path, sizeof path, "%s/%s.bin", a.fixtures, t->name);
        uint8_t *wire = read_file(path, &wire_len);
        /* the JSON fixture is read for parity with the other harnesses even though JSON ops are unsupported */
        size_t text_len;
        snprintf(path, sizeof path, "%s/%s.json", a.fixtures, t->name);
        uint8_t *text = read_file(path, &text_len);

        void *fixture = t->unpack(wire_len, wire);
        if (!fixture) die("cannot decode fixture", t->name);

        /* validation */
        size_t reenc_len = t->get_packed_size(fixture);
        uint8_t *reenc = malloc(reenc_len ? reenc_len : 1);
        if (!reenc) die("out of memory", "validation");
        if (t->pack(fixture, reenc) != reenc_len) die("pack size mismatch", t->name);
        int size_match = reenc_len == wire_len;
        int bytes_match = size_match && memcmp(reenc, wire, wire_len) == 0;
        if (a.dump) {
            mkdir_p(a.dump);
            snprintf(path, sizeof path, "%s/%s.wire.bin", a.dump, t->name);
            write_file(path, reenc, reenc_len);
        }

        for (int oi = 0; oi < nops; oi++) {
            const char *op = OPS[op_idx[oi]];
            result_rec *r = &results[nres++];
            memset(r, 0, sizeof *r);
            r->dataset = t->name;
            r->operation = op;
            op_fn fn;
            if (!strcmp(op, "wire_decode")) fn = op_wire_decode;
            else if (!strcmp(op, "wire_encode")) fn = op_wire_encode;
            else {
                r->supported = 0;
                r->reason = JSON_UNSUPPORTED_REASON;
                continue;
            }
            op_ctx ctx = {t, wire, wire_len, fixture};
            r->supported = 1;
            r->payload_bytes = wire_len;
            r->wire_bytes_match = bytes_match;
            r->wire_size_match = size_match;
            r->nrounds = a.rounds;
            r->rounds = calloc((size_t)a.rounds, sizeof(round_rec));
            if (!r->rounds) die("out of memory", "rounds");
            r->batch = measure(fn, &ctx, a.warmup_seconds, a.warmup_max_seconds, a.round_seconds, a.rounds,
                               r->rounds, &r->warmup_ns, &r->steady);
            double best = 0;
            for (int k = 0; k < a.rounds; k++) {
                double v = (double)r->rounds[k].iterations / (double)r->rounds[k].elapsed_ns * 1e9;
                if (v > best) best = v;
            }
            fprintf(stderr, "%s/%s %-6s %-12s %14.1f ops/s warmup %.1fs %s\n", HARNESS_LANGUAGE, HARNESS_NAME,
                    t->name, op, best, (double)r->warmup_ns / 1e9, r->steady ? "steady" : "NOT steady");
        }
        free(reenc);
        /* fixture, wire and text are kept alive until the end (they back the result records) */
        t->free_unpacked(fixture);
        free(wire);
        free(text);
    }

    write_results(&a, results, nres);
    for (int i = 0; i < nres; i++) free(results[i].rounds);
    fprintf(stderr, "sink=%llu\n", (unsigned long long)sink);
    return 0;
}
