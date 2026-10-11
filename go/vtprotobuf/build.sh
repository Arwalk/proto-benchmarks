#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${PROTOC:=protoc}"
: "${PROTO_DIR:=../../proto}"
mkdir -p build/bin gen/bench
# Install protoc-gen-go and protoc-gen-go-vtproto at exactly the versions pinned in go.mod.
PB_VERSION="$(go list -m -f '{{.Version}}' google.golang.org/protobuf)"
VT_VERSION="$(go list -m -f '{{.Version}}' github.com/planetscale/vtprotobuf)"
GOBIN="$PWD/build/bin" go install "google.golang.org/protobuf/cmd/protoc-gen-go@${PB_VERSION}"
GOBIN="$PWD/build/bin" go install "github.com/planetscale/vtprotobuf/cmd/protoc-gen-go-vtproto@${VT_VERSION}"
"$PROTOC" -I "$PROTO_DIR" \
  --plugin=protoc-gen-go="$PWD/build/bin/protoc-gen-go" \
  --plugin=protoc-gen-go-vtproto="$PWD/build/bin/protoc-gen-go-vtproto" \
  --go_out=gen --go_opt=module=protobench/gen \
  --go-vtproto_out=gen --go-vtproto_opt=module=protobench/gen \
  --go-vtproto_opt=features=marshal+unmarshal+size \
  "$PROTO_DIR/bench.proto"
go build -o build/bench .
echo "$VT_VERSION" > build/version.txt
