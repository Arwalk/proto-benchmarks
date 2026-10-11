#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${PROTOC:=protoc}"
: "${PROTO_DIR:=../../proto}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
mkdir -p build gen
"$PROTOC" -I "$PROTO_DIR" --csharp_out=gen "$PROTO_DIR/bench.proto"
dotnet build Bench.csproj -c Release --nologo -v quiet
# Resolve the Google.Protobuf version from the project's PackageReference.
sed -n 's/.*PackageReference Include="Google.Protobuf" Version="\([^"]*\)".*/\1/p' Bench.csproj > build/version.txt
