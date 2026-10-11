#!/usr/bin/env bash
# zig-protobuf harness build: fetch the library at $ZIG_PROTOBUF_REF (default: the pinned
# commit below; set ZIG_PROTOBUF_REF=master or any branch/tag/sha to override),
# generate gen/bench.pb.zig with protoc + protoc-gen-zig, build build/bin/bench (ReleaseFast,
# generic x86-64 / -Dcpu=baseline like the other compilers' defaults).
set -euo pipefail
cd "$(dirname "$0")"
: "${PROTOC:=protoc}"
: "${PROTO_DIR:=$(cd ../../proto && pwd)}"
: "${ZIG_PROTOBUF_REF:=65aa24107dedbd87fece8bb95c19c2d545d23e1a}"
PROTOC_ABS=$(realpath "$(command -v "$PROTOC")")
PROTO_DIR_ABS=$(realpath "$PROTO_DIR")
REPO=https://github.com/Arwalk/zig-protobuf
SRC=build/zig-protobuf-src

mkdir -p build
# Keep every cache under build/ so the directory is self-contained and idempotent.
export ZIG_GLOBAL_CACHE_DIR="$PWD/build/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="$PWD/build/zig-cache"

# 1. Check out the requested ref with git. Zig's own HTTP client cannot traverse
#    some (MITM) proxies, so the package is handed to `zig fetch` as a local
#    directory; the resulting content hash is identical to the one `zig fetch
#    git+https://...#ref` computes, and build.zig.zon keeps the git+https URL.
if [ ! -d "$SRC/.git" ]; then
  git clone -q "$REPO" "$SRC"
elif [[ "$ZIG_PROTOBUF_REF" =~ ^[0-9a-f]{7,40}$ ]] && git -C "$SRC" cat-file -e "$ZIG_PROTOBUF_REF^{commit}" 2>/dev/null; then
  : # pinned commit already present locally: no network needed
else
  git -C "$SRC" fetch -q --tags origin
fi
commit=$(git -C "$SRC" rev-parse -q --verify "origin/$ZIG_PROTOBUF_REF^{commit}" 2>/dev/null \
      || git -C "$SRC" rev-parse -q --verify "$ZIG_PROTOBUF_REF^{commit}")
git -C "$SRC" checkout -q --detach "$commit"
short=$(git -C "$SRC" rev-parse --short "$commit")
hash=$(zig fetch "$SRC")

# 2. Keep build.zig.zon in sync with the requested ref (url fragment + content hash).
want_url="git+$REPO#$ZIG_PROTOBUF_REF"
if ! grep -q "\"$want_url\"" build.zig.zon || ! grep -q "\"$hash\"" build.zig.zon; then
  echo "WARNING: rewriting build.zig.zon for ZIG_PROTOBUF_REF=$ZIG_PROTOBUF_REF (hash $hash); this change shows up in git diff, do not commit it unless intended" >&2
  sed -i -E "s|\.url = \"git\+https://github.com/Arwalk/zig-protobuf#[^\"]*\"|.url = \"$want_url\"|; s|\.hash = \"protobuf-[^\"]*\"|.hash = \"$hash\"|" build.zig.zon
fi

# 3. zig-protobuf declares protoc as a lazy dependency and requests it even when
#    a protoc path is given (-Dprotoc). Put the exact archive it expects into the
#    package cache without relying on Zig's HTTP client.
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  dep="protoc-linux-x86_64" ;;
  Linux-aarch64) dep="protoc-linux-aarch_64" ;;
  Darwin-arm64)  dep="protoc-osx-aarch_64" ;;
  Darwin-x86_64) dep="protoc-osx-x86_64" ;;
  *) dep="" ;;
esac
if [ -n "$dep" ]; then
  purl=$(grep -A3 "\"$dep\"" "$SRC/build.zig.zon" | sed -n 's/.*\.url = "\([^"]*\)".*/\1/p' | head -1)
  phash=$(grep -A3 "\"$dep\"" "$SRC/build.zig.zon" | sed -n 's/.*\.hash = "\([^"]*\)".*/\1/p' | head -1)
  if [ -n "$phash" ] && [ ! -e "$ZIG_GLOBAL_CACHE_DIR/p/$phash.tar.gz" ] && [ ! -d "$ZIG_GLOBAL_CACHE_DIR/p/$phash" ]; then
    rm -f build/protoc-dl.zip
    # Prefer a local copy of the release zip (the Docker image keeps one in $PROTOC_ARCHIVE_DIR);
    # otherwise download it, failing loudly instead of unzipping an HTTP error page.
    local_zip="${PROTOC_ARCHIVE_DIR:-/nonexistent}/$(basename "$purl")"
    if [ -f "$local_zip" ]; then
      cp "$local_zip" build/protoc-dl.zip
    elif ! curl -fsSL --retry 3 --retry-all-errors -o build/protoc-dl.zip "$purl"; then
      echo "failed to download $purl" >&2
      echo "zig-protobuf needs this protoc release archive as a package dependency. Download it" >&2
      echo "manually and point PROTOC_ARCHIVE_DIR at the directory containing $(basename "$purl")." >&2
      exit 1
    fi
    if ! unzip -tq build/protoc-dl.zip >/dev/null 2>&1; then
      echo "build/protoc-dl.zip is not a zip archive (download of $purl returned something else)" >&2
      head -c 300 build/protoc-dl.zip >&2; echo >&2
      exit 1
    fi
    rm -rf build/protoc-dl && mkdir -p build/protoc-dl && unzip -q build/protoc-dl.zip -d build/protoc-dl
    got=$(zig fetch build/protoc-dl)
    [ "$got" = "$phash" ] || { echo "protoc archive hash mismatch: $got != $phash" >&2; exit 1; }
    rm -rf build/protoc-dl build/protoc-dl.zip
  fi
fi

# 4. Generate + build.
libver=$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' "$SRC/build.zig.zon" | head -1)
version="$libver (git $short)"
# -Dcpu=baseline: generic x86-64 like every other compiler's default. build.zig additionally
# compiles the three *-native executables for the host CPU (zig/zig-protobuf-*-native).
zig build -Doptimize=ReleaseFast -Dcpu=baseline \
  -Dprotoc="$PROTOC_ABS" -Dproto-dir="$PROTO_DIR_ABS" -Dlibrary-version="$version" \
  --prefix "$PWD/build" --cache-dir "$ZIG_LOCAL_CACHE_DIR" --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR"
echo "$version" > build/version.txt
