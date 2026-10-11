#!/usr/bin/env bash
# Generates Java code with protoc and builds the harness with Maven.
# Outputs: build/maven/bench.jar, build/classpath.txt, build/version.txt
set -euo pipefail
cd "$(dirname "$0")"
: "${PROTOC:=protoc}"
: "${PROTO_DIR:=../../proto}"
. "${BENCH_ROOT:-../..}/tools/maven_settings.sh"

rm -rf gen
mkdir -p build gen
"$PROTOC" -I "$PROTO_DIR" --java_out=gen "$PROTO_DIR/bench.proto"

"${MVN[@]}" package

sed -n 's:.*<protobuf\.version>\(.*\)</protobuf\.version>.*:\1:p' pom.xml | head -1 > build/version.txt
