#!/usr/bin/env bash
# Downloads the pinned nanopb release, generates bench.pb.{c,h} with nanopb_generator.py
# (dynamic allocation options from bench.options) and builds the harness with CMake.
set -euo pipefail
cd "$(dirname "$0")"
: "${PROTOC:=protoc}"
: "${PROTO_DIR:=../../proto}"

NANOPB_VERSION="0.4.9.2"
NANOPB_URL="https://github.com/nanopb/nanopb/archive/refs/tags/nanopb-${NANOPB_VERSION}.tar.gz"

mkdir -p build gen

# 1. nanopb runtime + generator sources (pinned tag)
if [ ! -f "build/nanopb-src/pb.h" ] || ! grep -q "\"nanopb-${NANOPB_VERSION}\"" build/nanopb-src/pb.h; then
  echo "downloading nanopb ${NANOPB_VERSION}"
  rm -rf build/nanopb-src build/nanopb-extract
  curl -fsSL -o build/nanopb.tar.gz "$NANOPB_URL"
  mkdir -p build/nanopb-extract
  # Only the runtime sources and the generator are needed (the full tree contains
  # symlinked directories for SwiftPM that some filesystems refuse to extract).
  tar xzf build/nanopb.tar.gz -C build/nanopb-extract \
    "nanopb-nanopb-${NANOPB_VERSION}/LICENSE.txt" \
    "nanopb-nanopb-${NANOPB_VERSION}/pb.h" \
    "nanopb-nanopb-${NANOPB_VERSION}/pb_common.h" "nanopb-nanopb-${NANOPB_VERSION}/pb_common.c" \
    "nanopb-nanopb-${NANOPB_VERSION}/pb_encode.h" "nanopb-nanopb-${NANOPB_VERSION}/pb_encode.c" \
    "nanopb-nanopb-${NANOPB_VERSION}/pb_decode.h" "nanopb-nanopb-${NANOPB_VERSION}/pb_decode.c" \
    "nanopb-nanopb-${NANOPB_VERSION}/generator"
  mv build/nanopb-extract/nanopb-nanopb-${NANOPB_VERSION} build/nanopb-src
  rm -rf build/nanopb-extract build/nanopb.tar.gz
fi

# 2. Python environment for the generator (it needs protobuf + grpcio-tools)
if [ ! -x build/venv/bin/python ]; then
  python3 -m venv build/venv
fi
build/venv/bin/pip install -q --disable-pip-version-check -r requirements.txt

# 3. Code generation (nanopb_generator.py compiles the .proto itself through grpcio-tools)
build/venv/bin/python build/nanopb-src/generator/nanopb_generator.py \
  -I "$PROTO_DIR" -D gen -f "$PWD/bench.options" --error-on-unmatched --quiet bench.proto

# 4. Release build
GEN=()
if command -v ninja >/dev/null 2>&1; then GEN=(-G Ninja); fi
cmake -S . -B build "${GEN[@]}" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build --config Release

echo "nanopb ${NANOPB_VERSION} built: build/bench"
