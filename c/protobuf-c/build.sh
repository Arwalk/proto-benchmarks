#!/usr/bin/env bash
# Code generation + release build for the protobuf-c harness.
# Requires protoc-gen-c on PATH and libprotobuf-c discoverable through pkg-config.
set -euo pipefail
cd "$(dirname "$0")"
: "${PROTOC:=protoc}"
: "${PROTO_DIR:=../../proto}"

mkdir -p build gen
"$PROTOC" -I "$PROTO_DIR" --c_out=gen "$PROTO_DIR/bench.proto"

GEN=()
if command -v ninja >/dev/null 2>&1; then GEN=(-G Ninja); fi
cmake -S . -B build "${GEN[@]}" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build --config Release

pkg-config --modversion libprotobuf-c > build/version.txt
echo "protobuf-c $(cat build/version.txt) built: build/bench"
