#!/usr/bin/env bash
# goose-protobuf harness build: fetch the library at $GOOSE_PROTOBUF_REF (default: the pinned
# commit below; the project has no release tag yet), build protoc-gen-goose from it, generate
# bench.goose, vendor the pb_wire runtime next to main.goose and build build/bin/bench with
# `goose build` at its defaults (-O2 through the system C compiler, generic x86-64).
set -euo pipefail
cd "$(dirname "$0")"
: "${PROTOC:=protoc}"
: "${PROTO_DIR:=$(cd ../../proto && pwd)}"
: "${GOOSE_PROTOBUF_REF:=a9e99bb010eb6817d374de8e93666dc955eb8a01}"
REPO=https://github.com/Arwalk/goose-protobuf
SRC=build/goose-protobuf-src
STAGE=build/stage

mkdir -p build/bin build/plugin
# Keep Goose's intermediates (runtime object, generated C) inside this directory.
export GOOSE_HOME="$PWD/build/goose-home"

# 1. Check out the requested ref. The third_party/protobuf submodule is only used by the
#    project's conformance runner and stays empty.
if [ ! -d "$SRC/.git" ]; then
  git clone -q "$REPO" "$SRC"
elif [[ "$GOOSE_PROTOBUF_REF" =~ ^[0-9a-f]{7,40}$ ]] && git -C "$SRC" cat-file -e "$GOOSE_PROTOBUF_REF^{commit}" 2>/dev/null; then
  : # pinned commit already present locally: no network needed
else
  git -C "$SRC" fetch -q --tags origin
fi
commit=$(git -C "$SRC" rev-parse -q --verify "origin/$GOOSE_PROTOBUF_REF^{commit}" 2>/dev/null \
      || git -C "$SRC" rev-parse -q --verify "$GOOSE_PROTOBUF_REF^{commit}")
git -C "$SRC" checkout -q --detach "$commit"
short=$(git -C "$SRC" rev-parse --short "$commit")

# 2. The plugin, from the same checkout: generated code only builds against the runtime of the
#    same version.
plugin=$("$SRC/scripts/install_plugin.sh" "$PWD/build/plugin" 2>/dev/null)
libver=$("$plugin" --version | awk '{print $2}')
version="$libver (git $short)"

# 3. Assemble the program: harness, generated code, vendored runtime and build info.
rm -rf "$STAGE"; mkdir -p "$STAGE"
"$PROTOC" --plugin=protoc-gen-goose="$plugin" --goose_out="$STAGE" -I "$PROTO_DIR" bench.proto
"$SRC/scripts/vendor_runtime.sh" "$STAGE"
cp main.goose "$STAGE/"
goose_ver=$(goose version)
cc_ver=$(goose toolchain | awk -F': *' '/^C compiler:/ {print $2}' | sed 's/, found.*//')
cat > "$STAGE/buildinfo.goose" <<GOOSE
let LIBRARY_VERSION = "$version";
let RUNTIME_STRING = "$goose_ver, goose build -O2, $cc_ver";
GOOSE

# 4. Release build: `goose build` defaults, which is -O2 without debug checks.
bin="$PWD/build/bin/bench"
(cd "$STAGE" && goose build main.goose -o "$bin")
echo "$version" > build/version.txt
