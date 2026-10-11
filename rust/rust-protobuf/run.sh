#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
exec build/target/release/bench-rust-protobuf "$@"
