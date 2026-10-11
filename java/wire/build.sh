#!/usr/bin/env bash
# Fetches the Wire compiler (fat jar, pinned to ${wire.version} from pom.xml) from Maven Central,
# generates Java code, and builds the harness with Maven.
# Outputs: build/tools/wire-compiler-*.jar, gen/, build/maven/bench.jar, build/classpath.txt, build/version.txt
set -euo pipefail
cd "$(dirname "$0")"
: "${PROTO_DIR:=../../proto}"
. "${BENCH_ROOT:-../..}/tools/maven_settings.sh"

WIRE_VERSION=$(sed -n 's:.*<wire\.version>\(.*\)</wire\.version>.*:\1:p' pom.xml | head -1)
COMPILER="build/tools/wire-compiler-${WIRE_VERSION}-jar-with-dependencies.jar"

mkdir -p build/tools
if [ ! -f "$COMPILER" ]; then
  # wire-maven-plugin (3.0.x) does not support Wire 5, so use the standalone compiler.
  "${MVN[@]}" dependency:copy \
    -Dartifact="com.squareup.wire:wire-compiler:${WIRE_VERSION}:jar:jar-with-dependencies" \
    -DoutputDirectory=build/tools
fi

rm -rf gen
mkdir -p gen
java -jar "$COMPILER" --proto_path="$PROTO_DIR" --java_out=gen bench.proto

"${MVN[@]}" package

echo "$WIRE_VERSION" > build/version.txt
