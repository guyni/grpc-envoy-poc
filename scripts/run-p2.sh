#!/usr/bin/env bash
# Tiny wrapper: run-p2.sh <workers> <agents> <duration> <name>
set -euo pipefail
exec env ENVOY_CONCURRENCY="$1" "$(dirname "$0")/50-run-path.sh" \
  --path p2 --agents "$2" --duration "$3" --name "$4"
