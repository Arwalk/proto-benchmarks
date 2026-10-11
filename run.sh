#!/usr/bin/env bash
# proto-benchmarks: build every implementation, run them one at a time under identical
# conditions, cross-validate their outputs and aggregate everything into results/report.html.
#
#   ./run.sh [options]
#     --only a/b,c/d        run only these implementations (language/name)
#     --skip a/b,c/d        skip these implementations
#     --repeat N            run the whole suite N times in rotated order (default 1)
#     --core C              pin benchmark processes to the single CPU core C
#                           (default: pin to the whole CPU set allowed to this shell/container)
#     --no-pin              do not pin
#     --warmup-seconds F    minimum warm-up per dataset x operation (default 3)
#     --warmup-max-seconds F
#                           warm-up cap; after the minimum, 0.5 s probes run until 3 consecutive
#                           probes agree within 5 % or the cap is hit (default 15)
#     --round-seconds F     (default 1)
#     --rounds N            (default 10)
#     --quick               smoke-test settings: warmup 0.2 s (cap 0.2 s), rounds 2 x 0.2 s, repeat 1
#     --skip-build          do not run build.sh scripts
#     --build-only          only build, do not run
#     --no-report           do not aggregate
#     --results DIR         output directory (default ./results)
#     --baseline ID         baseline implementation for the report (default zig/zig-protobuf)
set -uo pipefail

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BENCH_ROOT"
export BENCH_ROOT
export PROTO_DIR="$BENCH_ROOT/proto"
# protoc: $PROTOC if set, else the protoc installed for this suite, else whatever is on PATH.
PROTOC_EXPECTED=36.2
if [ -z "${PROTOC:-}" ]; then
  if [ -x "$HOME/.local/protoc/bin/protoc" ]; then PROTOC="$HOME/.local/protoc/bin/protoc"
  else PROTOC="$(command -v protoc || true)"; fi
fi
export PROTOC
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
export CARGO_TERM_COLOR=never

ONLY=""; SKIP=""; REPEAT=1; CORE="auto"; PIN=1
WARMUP=3; WARMUP_MAX=15; ROUND=1; ROUNDS=10
DO_BUILD=1; DO_RUN=1; DO_REPORT=1
RESULTS="$BENCH_ROOT/results"; BASELINE="zig/zig-protobuf"

while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="$2"; shift 2;;
    --skip) SKIP="$2"; shift 2;;
    --repeat) REPEAT="$2"; shift 2;;
    --core) CORE="$2"; shift 2;;
    --no-pin) PIN=0; shift;;
    --warmup-seconds) WARMUP="$2"; shift 2;;
    --warmup-max-seconds) WARMUP_MAX="$2"; shift 2;;
    --round-seconds) ROUND="$2"; shift 2;;
    --rounds) ROUNDS="$2"; shift 2;;
    --quick) WARMUP=0.2; WARMUP_MAX=0.2; ROUND=0.2; ROUNDS=2; REPEAT=1; shift;;
    --skip-build) DO_BUILD=0; shift;;
    --build-only) DO_RUN=0; DO_REPORT=0; shift;;
    --no-report) DO_REPORT=0; shift;;
    --results) RESULTS="$(mkdir -p "$2" && cd "$2" && pwd)"; shift 2;;
    --baseline) BASELINE="$2"; shift 2;;
    -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

mkdir -p "$RESULTS/logs" "$RESULTS/dumps"
FAIL_FILE="$RESULTS/failures.txt"; : > "$FAIL_FILE"
log() { printf '\033[1m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { echo "$*" >> "$FAIL_FILE"; printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------- discover implementations
IMPLS=()
for meta in "$BENCH_ROOT"/*/*/meta.json; do
  dir="$(dirname "$meta")"
  id="$(basename "$(dirname "$dir")")/$(basename "$dir")"
  if [ -n "$ONLY" ] && ! grep -qx "$id" <<< "${ONLY//,/$'\n'}"; then continue; fi
  if [ -n "$SKIP" ] && grep -qx "$id" <<< "${SKIP//,/$'\n'}"; then continue; fi
  IMPLS+=("$id")
done
if [ ${#IMPLS[@]} -eq 0 ]; then echo "no implementations selected" >&2; exit 2; fi
log "implementations: ${IMPLS[*]}"
protoc_ver="$("$PROTOC" --version 2>/dev/null | awk '{print $2}')"
log "protoc: ${PROTOC:-<none>} (${protoc_ver:-not found})"
if [ "$protoc_ver" != "$PROTOC_EXPECTED" ]; then
  log "WARNING: protoc $protoc_ver found, the suite is pinned to $PROTOC_EXPECTED; generated code will differ from the reference runs"
fi

# ---------------------------------------------------------------- build
BUILT=()
if [ "$DO_BUILD" = 1 ]; then
  for id in "${IMPLS[@]}"; do
    logf="$RESULTS/logs/${id//\//-}.build.log"
    log "build $id (log: $logf)"
    start=$(date +%s)
    if (cd "$BENCH_ROOT/$id" && bash ./build.sh) > "$logf" 2>&1; then
      log "built $id in $(( $(date +%s) - start ))s"
      BUILT+=("$id")
    else
      fail "build $id (see $logf)"; tail -n 20 "$logf" >&2
    fi
  done
else
  BUILT=("${IMPLS[@]}")
fi

if [ "$DO_RUN" = 0 ]; then
  log "build-only: done, $(wc -l < "$FAIL_FILE") failure(s)"
  [ -s "$FAIL_FILE" ] && exit 1 || exit 0
fi

# ---------------------------------------------------------------- environment + fixtures
PYREF="$BENCH_ROOT/python/protobuf/build/venv/bin/python"
[ -x "$PYREF" ] || PYREF="python3"
export PROTO_BENCH_IMAGE="${PROTO_BENCH_IMAGE:-}"
bash "$BENCH_ROOT/tools/env_info.sh" > "$RESULTS/environment.json" || fail "env_info"
if [ -f "$BENCH_ROOT/python/protobuf/gen/bench_pb2.py" ]; then
  if ! "$PYREF" -I "$BENCH_ROOT/tools/check_fixtures.py" "$BENCH_ROOT/python/protobuf/gen" > "$RESULTS/logs/check_fixtures.log" 2>&1; then
    fail "fixtures do not match tools/gen_fixtures.py (see $RESULTS/logs/check_fixtures.log)"
  fi
fi

# ---------------------------------------------------------------- pinning
# Every harness process is pinned to the same CPU set. By default that is the whole set allowed to
# this shell/container (e.g. docker --cpuset-cpus=0-2), so the runtimes keep their GC/JIT helper
# threads and their processor-count ergonomics (HotSpot picks G1 instead of SerialGC, Go's GOMAXPROCS
# equals the set size). --core C restricts everyone to one core instead; both are recorded in the
# result file (run.cpuset / run.core).
PIN_PREFIX=(); CPUSET=""
if [ "$PIN" = 1 ] && command -v taskset >/dev/null 2>&1; then
  allowed="$(taskset -cp $$ 2>/dev/null | sed 's/.*: *//')"
  if [ "$CORE" = "auto" ]; then CPUSET="$allowed"; CORE=""; else CPUSET="$CORE"; fi
  PIN_PREFIX=(taskset -c "$CPUSET")
  log "pinning benchmark processes to cpuset $CPUSET${CORE:+ (single core)}"
else
  CORE=""; log "not pinning (taskset unavailable or --no-pin)"
fi

# ---------------------------------------------------------------- run
log "settings: warmup ${WARMUP}s (cap ${WARMUP_MAX}s), ${ROUNDS} rounds x ${ROUND}s, repeat ${REPEAT}"
# Previous result files of the selected implementations are replaced, never pooled with the new
# ones (the aggregator merges every <id>.<repeat>.json it finds in $RESULTS).
for id in "${BUILT[@]}"; do
  rm -f "$RESULTS/${id//\//-}".*.json
  rm -rf "$RESULTS/dumps/${id//\//-}"
done
for (( r=0; r<REPEAT; r++ )); do
  # rotate the order on every repeat (A B C / B C A / C A B ...) so that slow drift (thermal,
  # background load) does not systematically favour the implementations that run first, and no
  # implementation runs twice back-to-back (which a simple reversal would do).
  n=${#BUILT[@]}; ORDER=()
  for (( i=0; i<n; i++ )); do ORDER+=("${BUILT[$(( (i + r) % n ))]}"); done
  for id in "${ORDER[@]}"; do
    out="$RESULTS/${id//\//-}.${r}.json"
    logf="$RESULTS/logs/${id//\//-}.run.${r}.log"
    args=(--fixtures "$BENCH_ROOT/fixtures" --out "$out" --warmup-seconds "$WARMUP" --warmup-max-seconds "$WARMUP_MAX"
          --round-seconds "$ROUND" --rounds "$ROUNDS")
    [ "$r" = 0 ] && args+=(--dump "$RESULTS/dumps/${id//\//-}")
    log "run [$((r+1))/$REPEAT] $id"
    rm -f "$out"
    if (cd "$BENCH_ROOT/$id" && "${PIN_PREFIX[@]}" bash ./run.sh "${args[@]}") > "$logf" 2>&1 && [ -s "$out" ]; then
      grep -E 'ops/s' "$logf" | sed 's/^/    /'
      python3 "$BENCH_ROOT/tools/finalize_result.py" "$out" --meta "$BENCH_ROOT/$id/meta.json" \
        --env "$RESULTS/environment.json" --repeat "$r" --core "${CORE:-}" --cpuset "${CPUSET:-}" --id "$id" \
        --warmup "$WARMUP" --warmup-max "$WARMUP_MAX" --round "$ROUND" --rounds "$ROUNDS" \
        --version-file "$BENCH_ROOT/$id/build/version.txt" \
        || fail "finalize $id"
    else
      fail "run $id repeat $r (see $logf)"; tail -n 15 "$logf" >&2; rm -f "$out"
    fi
  done
done

# ---------------------------------------------------------------- validate + report
if [ -f "$BENCH_ROOT/python/protobuf/gen/bench_pb2.py" ]; then
  log "cross-validating dumped outputs with the reference runtime"
  "$PYREF" -I "$BENCH_ROOT/tools/validate_outputs.py" --dumps "$RESULTS/dumps" --out "$RESULTS/validation.json" \
    | tee "$RESULTS/logs/validate_outputs.log" || fail "cross-validation found mismatches (see $RESULTS/validation.json)"
else
  log "python/protobuf not built: skipping cross-validation"
fi

if [ "$DO_REPORT" = 1 ]; then
  log "aggregating"
  python3 "$BENCH_ROOT/report/aggregate.py" "$RESULTS" --baseline "$BASELINE" || fail "aggregate"
fi

if [ -s "$FAIL_FILE" ]; then
  echo; log "$(wc -l < "$FAIL_FILE") failure(s):"; sed 's/^/  - /' "$FAIL_FILE"; exit 1
fi
log "done"
