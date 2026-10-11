#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
exec java -cp "build/maven/bench.jar:$(cat build/classpath.txt)" io.protobench.Bench "$@"
