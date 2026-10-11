#!/usr/bin/env bash
# Collects machine / toolchain information into a JSON document on stdout.
set -uo pipefail

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))'; }
ver() { # ver <label> <command...>  -> "label": "first line of output"
  local label=$1; shift
  local out
  out=$("$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -v "^Picked up" | head -n 1) || out="n/a"
  [ -z "$out" ] && out="n/a"
  printf '    %s: %s' "$(printf '%s' "$label" | json_escape)" "$(printf '%s' "$out" | json_escape)"
}

cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')
cpu_count=$(nproc 2>/dev/null || echo "?")
governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
mem_kb=$(grep -m1 MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
in_docker=false; [ -f /.dockerenv ] && in_docker=true
smt=$(cat /sys/devices/system/cpu/smt/active 2>/dev/null || echo "unknown")

cat <<JSON
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hostname": $(hostname | json_escape),
  "kernel": $(uname -sr | json_escape),
  "arch": $(uname -m | json_escape),
  "os": $( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") | json_escape),
  "cpu_model": $(printf '%s' "$cpu_model" | json_escape),
  "cpu_count": ${cpu_count},
  "cpu_governor": $(printf '%s' "$governor" | json_escape),
  "smt_active": $(printf '%s' "$smt" | json_escape),
  "memory_kb": ${mem_kb:-0},
  "in_docker": ${in_docker},
  "image": $(printf '%s' "${PROTO_BENCH_IMAGE:-}" | json_escape),
  "toolchains": {
$(ver protoc "${PROTOC:-protoc}" --version),
$(ver gcc gcc --version),
$(ver "g++" g++ --version),
$(ver cmake cmake --version),
$(ver rustc rustc --version),
$(ver cargo cargo --version),
$(ver go go version),
$(ver java java -version),
$(ver mvn mvn -B --version),
$(ver python3 python3 --version),
$(ver dotnet dotnet --version),
$(ver node node --version),
$(ver swift swift --version),
$(ver zig zig version)
  }
}
JSON
