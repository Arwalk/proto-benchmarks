#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${PROTOC:=protoc}"
: "${PROTO_DIR:=$(cd ../../proto && pwd)}"
export PROTOC PROTO_DIR
export CARGO_TARGET_DIR="$PWD/build/target"
mkdir -p build
cargo build --release --locked
awk '/^name = "prost"$/ { found = 1; next } found && /^version = / { gsub(/"/, "", $3); print $3; exit }' Cargo.lock > build/version.txt
