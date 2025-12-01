#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIRMF_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NVBANDWIDTH_BIN="$AIRMF_ROOT/tools/third_party/nvbandwidth/nvbandwidth"

usage() {
  cat <<EOF
Usage: nvbandwidth -t [--testcase] TESTCASE

  Run "nvbandwidth -l" to list available testcases.

Examples:
EOF
}

if [[ $# -lt 1 ]]; then
  echo "nvbandwidth: missing arguments" >&2
  usage
  exit 2
fi

"$NVBANDWIDTH_BIN" "$@"
