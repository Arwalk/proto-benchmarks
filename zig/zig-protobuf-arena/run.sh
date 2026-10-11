#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
exec ../zig-protobuf/build/bin/bench-arena "$@"
