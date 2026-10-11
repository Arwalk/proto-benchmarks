#!/usr/bin/env bash
# swift-protobuf harness build: build protoc-gen-swift from the pinned dependency,
# generate harness/Sources/bench/gen/bench.pb.swift, build the `bench` executable in release mode.
#
# The SwiftPM package lives in harness/ (not in this directory): SwiftPM derives the
# root package identity from its directory name, and "swift-protobuf" would collide
# with the identity of the dependency (SwiftPM then reports a cyclic dependency).
set -euo pipefail
cd "$(dirname "$0")"
: "${PROTOC:=protoc}"
: "${PROTO_DIR:=$(cd ../../proto && pwd)}"
PKG="$PWD/harness"
SCRATCH="$PWD/build/spm"
mkdir -p build "$PKG/Sources/bench/gen"

# llbuild keeps its state in an SQLite db; on some (FUSE) filesystems the first
# access after `resolve` can fail with "attempt to write a readonly database".
swift_build() {
  local i
  for i in 1 2 3; do
    if swift build -c release --package-path "$PKG" --scratch-path "$SCRATCH" "$@"; then return 0; fi
    echo "swift build $* failed (attempt $i), retrying" >&2
    sleep 1
  done
  return 1
}

# Resolve exactly what Package.resolved pins.
swift package --package-path "$PKG" --scratch-path "$SCRATCH" resolve
# protoc plugin, built from the dependency itself (same version as the runtime).
swift_build --product protoc-gen-swift
"$PROTOC" -I "$PROTO_DIR" \
  --plugin=protoc-gen-swift="$SCRATCH/release/protoc-gen-swift" \
  --swift_out="$PKG/Sources/bench/gen" --swift_opt=Visibility=Internal \
  "$PROTO_DIR/bench.proto"
swift_build --product bench
cp -f "$SCRATCH/release/bench" build/bench

python3 - "$PKG/Package.resolved" > build/version.txt <<'PY'
import json, sys
for pin in json.load(open(sys.argv[1]))["pins"]:
    if pin["identity"] == "swift-protobuf":
        print(pin["state"]["version"])
PY
swift --version 2>/dev/null | head -1 > build/runtime.txt
