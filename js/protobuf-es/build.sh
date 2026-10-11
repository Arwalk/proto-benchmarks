#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${PROTOC:=protoc}"
: "${PROTO_DIR:=../../proto}"
mkdir -p build gen
export npm_config_cache="$PWD/build/npm-cache" npm_config_update_notifier=false
if [ -f package-lock.json ]; then
  npm ci --no-audit --no-fund --loglevel=error
else
  npm install --no-audit --no-fund --loglevel=error   # creates package-lock.json; commit it
fi
"$PROTOC" -I "$PROTO_DIR" \
  --plugin=protoc-gen-es="$PWD/node_modules/.bin/protoc-gen-es" \
  --es_out=gen --es_opt=target=js+dts \
  "$PROTO_DIR/bench.proto"
node -p "JSON.parse(require('fs').readFileSync('node_modules/@bufbuild/protobuf/package.json','utf8')).version" > build/version.txt
