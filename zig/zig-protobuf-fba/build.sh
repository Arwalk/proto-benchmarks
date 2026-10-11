#!/usr/bin/env bash
# Shares the build of ../zig-protobuf: one `zig build` there produces bench, bench-arena and
# bench-fba (same sources, same generated code, different allocation strategy).
set -euo pipefail
cd "$(dirname "$0")"
../zig-protobuf/build.sh
mkdir -p build
cp ../zig-protobuf/build/version.txt build/version.txt
