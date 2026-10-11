// proto-benchmarks harness: Google's C++ protobuf runtime (https://github.com/protocolbuffers/protobuf).
//
// Implements the measurement loop of docs/HARNESS.md (mirrors tools/pyharness.py 1:1).
// Wire: generated code (ParseFromArray / SerializeToString), no arenas.
// JSON: google/protobuf/util/json_util.h (MessageToJsonString / JsonStringToMessage, default options).
#include <cerrno>
#include <cstdint>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <time.h>

#include <google/protobuf/stubs/common.h>
#include <google/protobuf/util/json_util.h>
#include "bench.pb.h"

#define HARNESS_LANGUAGE "cpp"
#define HARNESS_NAME "protobuf"

namespace {

// ---------------------------------------------------------------- black hole
volatile uint64_t sink = 0;

// ---------------------------------------------------------------- utilities
[[noreturn]] void die(const char *msg, const char *arg = nullptr) {
    if (arg) std::fprintf(stderr, "error: %s: %s\n", msg, arg);
    else std::fprintf(stderr, "error: %s\n", msg);
    std::exit(1);
}

int64_t now_ns() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000000000LL + static_cast<int64_t>(ts.tv_nsec);
}

std::string read_file(const std::string &path) {
    FILE *f = std::fopen(path.c_str(), "rb");
    if (!f) die("cannot open", path.c_str());
    if (std::fseek(f, 0, SEEK_END) != 0) die("fseek failed", path.c_str());
    long n = std::ftell(f);
    if (n < 0) die("ftell failed", path.c_str());
    std::rewind(f);
    std::string buf(static_cast<size_t>(n), '\0');
    if (n > 0 && std::fread(&buf[0], 1, buf.size(), f) != buf.size()) die("short read", path.c_str());
    std::fclose(f);
    return buf;
}

void write_file(const std::string &path, const std::string &data) {
    FILE *f = std::fopen(path.c_str(), "wb");
    if (!f) die("cannot write", path.c_str());
    if (!data.empty() && std::fwrite(data.data(), 1, data.size(), f) != data.size()) die("short write", path.c_str());
    std::fclose(f);
}

void mkdir_p(const std::string &dir) {
    if (dir.empty()) die("bad directory");
    std::string tmp = dir;
    for (size_t i = 1; i < tmp.size(); i++) {
        if (tmp[i] == '/') {
            tmp[i] = '\0';
            if (mkdir(tmp.c_str(), 0777) != 0 && errno != EEXIST) die("mkdir failed", tmp.c_str());
            tmp[i] = '/';
        }
    }
    if (mkdir(tmp.c_str(), 0777) != 0 && errno != EEXIST) die("mkdir failed", tmp.c_str());
}

void json_escape(FILE *f, const std::string &s) {
    std::fputc('"', f);
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') { std::fputc('\\', f); std::fputc(c, f); }
        else if (c < 0x20) std::fprintf(f, "\\u%04x", c);
        else std::fputc(c, f);
    }
    std::fputc('"', f);
}

// ---------------------------------------------------------------- datasets / types
struct type_ops {
    const char *name;
    google::protobuf::Message *(*new_msg)();
    uint64_t (*scalar)(const google::protobuf::Message &);
    // the four operations; `ctx` is an op_ctx*
    void (*wire_decode)(void *);
    void (*wire_encode)(void *);
    void (*json_encode)(void *);
    void (*json_decode)(void *);
};

struct op_ctx {
    const type_ops *t;
    const std::string *wire;
    const std::string *text;
    const google::protobuf::Message *fixture;
};

inline uint64_t scalar_of(const bench::SmallMessage &m) { return static_cast<uint64_t>(static_cast<int64_t>(m.id())); }
inline uint64_t scalar_of(const bench::MediumMessage &m) { return static_cast<uint64_t>(m.created_at()); }
inline uint64_t scalar_of(const bench::LargeMessage &m) { return static_cast<uint64_t>(m.source().size()); }

template <class M>
struct Ops {
    static google::protobuf::Message *new_msg() { return new M(); }
    static uint64_t scalar(const google::protobuf::Message &m) { return scalar_of(static_cast<const M &>(m)); }

    // one iteration of wire_decode: bytes -> fully materialised message (destroyed at scope exit)
    static void wire_decode(void *p) {
        op_ctx *c = static_cast<op_ctx *>(p);
        M m;
        if (!m.ParseFromArray(c->wire->data(), static_cast<int>(c->wire->size()))) die("ParseFromArray failed", c->t->name);
        sink ^= scalar_of(m);
    }
    // one iteration of wire_encode: message -> fresh std::string
    static void wire_encode(void *p) {
        op_ctx *c = static_cast<op_ctx *>(p);
        std::string out;
        if (!static_cast<const M *>(c->fixture)->SerializeToString(&out)) die("SerializeToString failed", c->t->name);
        sink ^= static_cast<uint64_t>(out.size());
    }
    // one iteration of json_encode: message -> fresh JSON std::string
    static void json_encode(void *p) {
        op_ctx *c = static_cast<op_ctx *>(p);
        std::string out;
        if (!google::protobuf::util::MessageToJsonString(*c->fixture, &out).ok()) die("MessageToJsonString failed", c->t->name);
        sink ^= static_cast<uint64_t>(out.size());
    }
    // one iteration of json_decode: JSON text -> fresh message (destroyed at scope exit)
    static void json_decode(void *p) {
        op_ctx *c = static_cast<op_ctx *>(p);
        M m;
        if (!google::protobuf::util::JsonStringToMessage(*c->text, &m).ok()) die("JsonStringToMessage failed", c->t->name);
        sink ^= scalar_of(m);
    }
};

template <class M>
constexpr type_ops make_type(const char *name) {
    return {name, Ops<M>::new_msg, Ops<M>::scalar, Ops<M>::wire_decode, Ops<M>::wire_encode,
            Ops<M>::json_encode, Ops<M>::json_decode};
}

const type_ops TYPES[] = {
    make_type<bench::SmallMessage>("small"),
    make_type<bench::MediumMessage>("medium"),
    make_type<bench::LargeMessage>("large"),
};
constexpr int NDATASETS = 3;

const char *const OPS[] = {"wire_encode", "wire_decode", "json_encode", "json_decode"};
constexpr int NOPS = 4;

// ---------------------------------------------------------------- measurement loop (HARNESS.md)
struct round_rec {
    uint64_t iterations;
    int64_t elapsed_ns;
};

typedef void (*op_fn)(void *);

inline void run_batch(op_fn fn, void *ctx, uint64_t batch) {
    for (uint64_t i = 0; i < batch; i++) fn(ctx);
}

// steady-state warm-up: run probes of WARMUP_PROBE_NS and stop once the last STEADY_WINDOW probe
// rates agree within STEADY_TOL (never before warmup_s, never after warmup_max_s)
constexpr int64_t WARMUP_PROBE_NS = 500000000LL;
constexpr int STEADY_WINDOW = 3;
constexpr double STEADY_TOL = 0.05;

uint64_t measure(op_fn fn, void *ctx, double warmup_s, double warmup_max_s, double round_s, int rounds,
                 std::vector<round_rec> &out, int64_t &warmup_ns_out, bool &steady_out) {
    uint64_t batch = 1;
    for (;;) {  // calibration: double the batch until one batch takes >= 10 ms
        int64_t t0 = now_ns();
        run_batch(fn, ctx, batch);
        if (now_ns() - t0 >= 10000000LL) break;
        batch *= 2;
    }
    int64_t min_ns = static_cast<int64_t>(warmup_s * 1e9);
    int64_t max_ns = static_cast<int64_t>(warmup_max_s * 1e9);
    if (max_ns < min_ns) max_ns = min_ns;
    double rates[STEADY_WINDOW];
    int n = 0;
    bool steady = false;
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
        rates[n % STEADY_WINDOW] = static_cast<double>(iters) * 1e9 / static_cast<double>(now_ns() - p0);
        n++;
        if (now_ns() - w0 >= min_ns && n >= STEADY_WINDOW) {
            double lo = rates[0], hi = rates[0];
            for (int i = 1; i < STEADY_WINDOW; i++) {
                if (rates[i] < lo) lo = rates[i];
                if (rates[i] > hi) hi = rates[i];
            }
            if (hi <= lo * (1.0 + STEADY_TOL)) { steady = true; break; }
        }
    }
    warmup_ns_out = now_ns() - w0;
    steady_out = steady;
    int64_t round_ns = static_cast<int64_t>(round_s * 1e9);
    out.clear();
    for (int r = 0; r < rounds; r++) {
        uint64_t iters = 0;
        int64_t start = now_ns();
        while (now_ns() - start < round_ns) {
            run_batch(fn, ctx, batch);
            iters += batch;
        }
        out.push_back({iters, now_ns() - start});
    }
    return batch;
}

// ---------------------------------------------------------------- arguments
struct args_t {
    std::string fixtures, out;
    double warmup_seconds = 3.0;
    double warmup_max_seconds = 15.0;
    double round_seconds = 1.0;
    int rounds = 10;
    std::string datasets = "small,medium,large";
    std::string ops = "wire_encode,wire_decode,json_encode,json_decode";
    std::string dump;
    bool have_dump = false;
};

[[noreturn]] void usage_error(const char *msg, const char *arg = nullptr) {
    if (arg) std::fprintf(stderr, "error: %s: %s\n", msg, arg);
    else std::fprintf(stderr, "error: %s\n", msg);
    std::fprintf(stderr,
                 "usage: bench --fixtures DIR --out FILE [--warmup-seconds F] [--warmup-max-seconds F]\n"
                 "             [--round-seconds F] [--rounds N] [--datasets a,b] [--ops a,b] [--dump DIR]\n");
    std::exit(2);
}

args_t parse_args(int argc, char **argv) {
    args_t a;
    for (int i = 1; i < argc; i++) {
        std::string k = argv[i];
        std::string v;
        size_t eq = k.find('=');
        if (k.rfind("--", 0) == 0 && eq != std::string::npos) {  // --key=value
            v = k.substr(eq + 1);
            k = k.substr(0, eq);
        } else {
            if (i + 1 >= argc) usage_error("missing value for", k.c_str());
            v = argv[++i];
        }
        if (k == "--fixtures") a.fixtures = v;
        else if (k == "--out") a.out = v;
        else if (k == "--warmup-seconds") a.warmup_seconds = std::strtod(v.c_str(), nullptr);
        else if (k == "--warmup-max-seconds") a.warmup_max_seconds = std::strtod(v.c_str(), nullptr);
        else if (k == "--round-seconds") a.round_seconds = std::strtod(v.c_str(), nullptr);
        else if (k == "--rounds") a.rounds = std::atoi(v.c_str());
        else if (k == "--datasets") a.datasets = v;
        else if (k == "--ops") a.ops = v;
        else if (k == "--dump") { a.dump = v; a.have_dump = true; }
        else usage_error("unknown argument", k.c_str());
    }
    if (a.fixtures.empty()) usage_error("--fixtures is required");
    if (a.out.empty()) usage_error("--out is required");
    if (a.rounds < 1) usage_error("--rounds must be >= 1");
    if (a.warmup_seconds < 0 || a.warmup_max_seconds < 0 || a.round_seconds <= 0)
        usage_error("invalid duration (must not be negative)");
    return a;
}

// Split a comma separated list and map each entry to an index in `names`.
std::vector<int> parse_list(const std::string &list, const char *const *names, int nnames, const char *what) {
    std::vector<int> out;
    size_t pos = 0;
    while (pos <= list.size()) {
        size_t q = list.find(',', pos);
        std::string item = list.substr(pos, q == std::string::npos ? std::string::npos : q - pos);
        if (!item.empty()) {
            int found = -1;
            for (int i = 0; i < nnames; i++)
                if (item == names[i]) found = i;
            if (found < 0) {
                std::fprintf(stderr, "error: unknown %s %s\n", what, item.c_str());
                std::exit(2);
            }
            if (std::find(out.begin(), out.end(), found) == out.end()) out.push_back(found);  // ignore duplicates
        }
        if (q == std::string::npos) break;
        pos = q + 1;
    }
    return out;
}

// ---------------------------------------------------------------- result records
struct result_rec {
    const char *dataset = nullptr;
    const char *operation = nullptr;
    bool supported = false;
    std::string reason;
    size_t payload_bytes = 0;
    bool wire_bytes_match = false, wire_size_match = false, json_roundtrip_ok = false;
    size_t json_bytes = 0;
    int64_t warmup_ns = 0;
    bool steady = false;
    uint64_t batch = 0;
    std::vector<round_rec> rounds;
};

void write_results(const args_t &a, const std::vector<result_rec> &res) {
    FILE *f = std::fopen(a.out.c_str(), "w");
    if (!f) die("cannot write", a.out.c_str());
    std::fprintf(f, "{\n \"schema_version\": 1,\n \"harness\": {\n");
    std::fprintf(f, "  \"language\": \"%s\",\n  \"name\": \"%s\",\n", HARNESS_LANGUAGE, HARNESS_NAME);
    std::fprintf(f, "  \"runtime\": ");
    json_escape(f, "g++ " __VERSION__);
    std::fprintf(f, ",\n  \"library_version\": ");
    json_escape(f, google::protobuf::internal::VersionString(GOOGLE_PROTOBUF_VERSION));
    std::fprintf(f, "\n },\n \"results\": [\n");
    for (size_t i = 0; i < res.size(); i++) {
        const result_rec &r = res[i];
        std::fprintf(f, "  {\n   \"dataset\": \"%s\",\n   \"operation\": \"%s\",\n", r.dataset, r.operation);
        if (!r.supported) {
            std::fprintf(f, "   \"supported\": false,\n   \"reason\": ");
            json_escape(f, r.reason);
            std::fprintf(f, "\n  }");
        } else {
            std::fprintf(f, "   \"supported\": true,\n   \"payload_bytes\": %zu,\n", r.payload_bytes);
            std::fprintf(f, "   \"validation\": {\n    \"wire_bytes_match\": %s,\n    \"wire_size_match\": %s,\n"
                            "    \"json_roundtrip_ok\": %s,\n    \"json_bytes\": %zu\n   },\n",
                         r.wire_bytes_match ? "true" : "false", r.wire_size_match ? "true" : "false",
                         r.json_roundtrip_ok ? "true" : "false", r.json_bytes);
            std::fprintf(f, "   \"warmup_ns\": %lld,\n   \"steady\": %s,\n", static_cast<long long>(r.warmup_ns),
                         r.steady ? "true" : "false");
            std::fprintf(f, "   \"batch\": %llu,\n   \"rounds\": [\n", static_cast<unsigned long long>(r.batch));
            for (size_t k = 0; k < r.rounds.size(); k++)
                std::fprintf(f, "    {\n     \"iterations\": %llu,\n     \"elapsed_ns\": %lld\n    }%s\n",
                             static_cast<unsigned long long>(r.rounds[k].iterations),
                             static_cast<long long>(r.rounds[k].elapsed_ns), k + 1 < r.rounds.size() ? "," : "");
            std::fprintf(f, "   ]\n  }");
        }
        std::fprintf(f, "%s\n", i + 1 < res.size() ? "," : "");
    }
    std::fprintf(f, " ]\n}\n");
    std::fclose(f);
}

}  // namespace

// ---------------------------------------------------------------- main
int main(int argc, char **argv) {
    GOOGLE_PROTOBUF_VERIFY_VERSION;
    args_t a = parse_args(argc, argv);
    const char *dataset_names[NDATASETS];
    for (int i = 0; i < NDATASETS; i++) dataset_names[i] = TYPES[i].name;
    std::vector<int> ds_idx = parse_list(a.datasets, dataset_names, NDATASETS, "dataset");
    std::vector<int> op_idx = parse_list(a.ops, OPS, NOPS, "op");

    std::vector<result_rec> results;

    for (int di : ds_idx) {
        const type_ops *t = &TYPES[di];
        std::string wire = read_file(a.fixtures + "/" + t->name + ".bin");
        std::string text = read_file(a.fixtures + "/" + t->name + ".json");

        google::protobuf::Message *fixture = t->new_msg();
        if (!fixture->ParseFromArray(wire.data(), static_cast<int>(wire.size()))) die("cannot decode fixture", t->name);

        // validation
        std::string reenc;
        if (!fixture->SerializeToString(&reenc)) die("cannot encode fixture", t->name);
        bool size_match = reenc.size() == wire.size();
        bool bytes_match = reenc == wire;
        std::string js;
        if (!google::protobuf::util::MessageToJsonString(*fixture, &js).ok()) die("MessageToJsonString failed", t->name);
        size_t json_bytes = js.size();
        google::protobuf::Message *back_msg = t->new_msg();
        if (!google::protobuf::util::JsonStringToMessage(js, back_msg).ok()) die("JsonStringToMessage failed", t->name);
        std::string back;
        if (!back_msg->SerializeToString(&back)) die("cannot re-encode", t->name);
        delete back_msg;
        bool json_ok = bytes_match ? (back == wire) : (back.size() == wire.size());
        if (a.have_dump) {
            mkdir_p(a.dump);
            write_file(a.dump + "/" + t->name + ".json", js);
            write_file(a.dump + "/" + t->name + ".wire.bin", reenc);
        }

        for (int oi : op_idx) {
            const char *op = OPS[oi];
            result_rec r;
            r.dataset = t->name;
            r.operation = op;
            op_fn fn;
            if (!std::strcmp(op, "wire_decode")) { fn = t->wire_decode; r.payload_bytes = wire.size(); }
            else if (!std::strcmp(op, "wire_encode")) { fn = t->wire_encode; r.payload_bytes = wire.size(); }
            else if (!std::strcmp(op, "json_encode")) { fn = t->json_encode; r.payload_bytes = text.size(); }
            else { fn = t->json_decode; r.payload_bytes = text.size(); }
            op_ctx ctx = {t, &wire, &text, fixture};
            r.supported = true;
            r.wire_bytes_match = bytes_match;
            r.wire_size_match = size_match;
            r.json_roundtrip_ok = json_ok;
            r.json_bytes = json_bytes;
            r.batch = measure(fn, &ctx, a.warmup_seconds, a.warmup_max_seconds, a.round_seconds, a.rounds, r.rounds,
                              r.warmup_ns, r.steady);
            double best = 0;
            for (const round_rec &k : r.rounds) {
                double v = static_cast<double>(k.iterations) / static_cast<double>(k.elapsed_ns) * 1e9;
                if (v > best) best = v;
            }
            std::fprintf(stderr, "%s/%s %-6s %-12s %14.1f ops/s warmup %.1fs %s\n", HARNESS_LANGUAGE, HARNESS_NAME,
                         t->name, op, best, static_cast<double>(r.warmup_ns) / 1e9, r.steady ? "steady" : "NOT steady");
            results.push_back(std::move(r));
        }
        delete fixture;
    }

    write_results(a, results);
    std::fprintf(stderr, "sink=%llu\n", static_cast<unsigned long long>(sink));
    google::protobuf::ShutdownProtobufLibrary();
    return 0;
}
