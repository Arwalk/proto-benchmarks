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
# Static module (no reflection) for the wire format ...
node_modules/.bin/pbjs -t static-module -w esm --no-verify --no-delimited --no-typeurl \
  -o gen/bench.js "$PROTO_DIR/bench.proto"
# ... and the JSON descriptor the ext/protojson extension needs for ProtoJSON.
node_modules/.bin/pbjs -t json -o gen/bench.json "$PROTO_DIR/bench.proto"
node -p "JSON.parse(require('fs').readFileSync('node_modules/protobufjs/package.json','utf8')).version" > build/version.txt
