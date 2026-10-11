#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${PROTOC:=protoc}"
: "${PROTO_DIR:=../../proto}"
mkdir -p build gen
python3 -m venv build/venv
build/venv/bin/pip install -q --disable-pip-version-check -r requirements.txt
"$PROTOC" -I "$PROTO_DIR" --python_out=gen "$PROTO_DIR/bench.proto"
build/venv/bin/python -c "import google.protobuf as p; print(p.__version__)" > build/version.txt
