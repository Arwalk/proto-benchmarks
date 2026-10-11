#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export BENCH_RUNTIME="$(cat build/runtime.txt 2>/dev/null || echo Swift)"
export BENCH_LIBRARY_VERSION="$(cat build/version.txt 2>/dev/null || echo unknown)"
exec build/bench "$@"
