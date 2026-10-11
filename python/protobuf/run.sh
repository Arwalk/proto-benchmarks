#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=upb
exec build/venv/bin/python -I bench.py "$@"
