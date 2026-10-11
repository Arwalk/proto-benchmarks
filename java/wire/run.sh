#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
exec java -Dprotobench.library.version="$(cat build/version.txt)" \
  -cp "build/maven/bench.jar:$(cat build/classpath.txt)" io.protobench.Bench "$@"
