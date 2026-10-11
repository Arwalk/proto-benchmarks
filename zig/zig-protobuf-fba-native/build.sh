#!/usr/bin/env bash
# Shares the build of ../zig-protobuf: one `zig build` there produces bench, bench-arena, bench-fba
# and their -native twins compiled for the host CPU (same sources, same generated code).
set -euo pipefail
cd "$(dirname "$0")"
../zig-protobuf/build.sh
mkdir -p build
cp ../zig-protobuf/build/version.txt build/version.txt
