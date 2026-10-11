#!/usr/bin/env bash
# Code generation + release build for the C++ protobuf harness.
# libprotobuf (+abseil, utf8_range) must be installed under $PROTOBUF_PREFIX (default /usr/local)
# and match the protoc version ($PROTOC).
set -euo pipefail
cd "$(dirname "$0")"
: "${PROTOC:=protoc}"
: "${PROTO_DIR:=../../proto}"
: "${PROTOBUF_PREFIX:=/usr/local}"

mkdir -p build gen
"$PROTOC" -I "$PROTO_DIR" --cpp_out=gen "$PROTO_DIR/bench.proto"

GEN=()
if command -v ninja >/dev/null 2>&1; then GEN=(-G Ninja); fi
cmake -S . -B build "${GEN[@]}" -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$PROTOBUF_PREFIX" >/dev/null
cmake --build build --config Release

# version.txt is written by CMake from the protobuf package config (protobuf_VERSION)
test -s build/version.txt
echo "protobuf (C++) $(cat build/version.txt) built: build/bench"
