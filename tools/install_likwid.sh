#!/usr/bin/env bash
set -euo pipefail

# Config
PIN_TAG="${PIN_TAG:-v5.3.0}"          # change as needed
PIN_COMMIT="${PIN_COMMIT:-}"          # optional: override with exact commit
PREFIX="${PREFIX:-$(pwd)/third_party/_builds/likwid-${PIN_TAG}}"
SRC_DIR="${SRC_DIR:-$(pwd)/third_party/sources/likwid}"

say() { echo "[likwid-detect] $*"; }

# 1) Already on PATH?
if command -v likwid-perfctr >/dev/null 2>&1; then
  say "Found on PATH: $(likwid-perfctr --version | head -n1)"
  exit 0
fi

# 2) Cluster modules?
if command -v module >/dev/null 2>&1; then
  for mod in likwid LIKWID; do
    if module avail "$mod" 2>&1 | grep -qi "$mod"; then
      say "Trying environment module: $mod"
      module load "$mod" && command -v likwid-perfctr >/dev/null && exit 0
    fi
  done
fi

# 5) Fallback: pinned source build (user space, no sudo)
say "Falling back to pinned source build: ${PIN_TAG:-$PIN_COMMIT}"
mkdir -p "$(dirname "$SRC_DIR")" "$(dirname "$PREFIX")"

if [ ! -d "$SRC_DIR/.git" ]; then
  git clone --depth 1 --branch "${PIN_TAG:-master}" https://github.com/RRZE-HPC/likwid.git "$SRC_DIR"
fi

pushd "$SRC_DIR" >/dev/null
if [ -n "$PIN_COMMIT" ]; then
  git fetch --depth 1 origin "$PIN_COMMIT"
  git checkout --detach "$PIN_COMMIT"
fi
make -j
make install PREFIX="$PREFIX"
popd >/dev/null

# Export wrapper hints
echo "export PATH=\"$PREFIX/bin:\$PATH\""
echo "export LIKWID_PREFIX=\"$PREFIX\""

# Verify
if PATH="$PREFIX/bin:$PATH" command -v likwid-perfctr >/dev/null; then
  say "Installed to $PREFIX"
  exit 0
else
  say "ERROR: LIKWID install failed."
  exit 1
fi
