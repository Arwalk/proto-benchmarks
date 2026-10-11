#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${PROTO_DIR:=../../proto}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
PROTOGEN_VERSION=3.4.30
mkdir -p build gen
# protobuf-net's own code generator (protogen), installed as a local dotnet tool under build/tools.
if [ ! -x build/tools/protogen ] || [ "$(cat build/tools/.version 2>/dev/null)" != "$PROTOGEN_VERSION" ]; then
  rm -rf build/tools
  dotnet tool install protobuf-net.Protogen --version "$PROTOGEN_VERSION" --tool-path build/tools
  echo "$PROTOGEN_VERSION" > build/tools/.version
fi
build/tools/protogen --proto_path="$PROTO_DIR" bench.proto --csharp_out=gen
dotnet build Bench.csproj -c Release --nologo -v quiet
# Resolve the protobuf-net version from the project's PackageReference.
sed -n 's/.*PackageReference Include="protobuf-net" Version="\([^"]*\)".*/\1/p' Bench.csproj > build/version.txt
