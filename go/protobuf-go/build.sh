#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${PROTOC:=protoc}"
: "${PROTO_DIR:=../../proto}"
mkdir -p build/bin gen/bench
# Resolve the pinned google.golang.org/protobuf version from go.mod and install the
# matching protoc-gen-go so generated code and runtime are the same release.
PB_VERSION="$(go list -m -f '{{.Version}}' google.golang.org/protobuf)"
GOBIN="$PWD/build/bin" go install "google.golang.org/protobuf/cmd/protoc-gen-go@${PB_VERSION}"
"$PROTOC" -I "$PROTO_DIR" \
  --plugin=protoc-gen-go="$PWD/build/bin/protoc-gen-go" \
  --go_out=gen --go_opt=module=protobench/gen \
  "$PROTO_DIR/bench.proto"
go build -o build/bench .
echo "$PB_VERSION" > build/version.txt
