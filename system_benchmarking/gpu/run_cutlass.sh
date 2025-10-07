#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# CUTLASS benchmark runner for AI Roofline Modelling Framework
# - Detects NVIDIA GPU + cutlass_profiler
# - Optionally installs CUTLASS (clone + build) if not found
# - Runs a GEMM benchmark and writes CSV results
#
# Usage:
#   ./run_cutlass_benchmark.sh [--install-dir DIR] [--cutlass-root DIR] [--m 4096 --n 4096 --k 4096]
#                              [--dtype f16] [--accum f32] [--iterations 50] [--out results.csv]
#
# Notes:
# - Requires CUDA toolkit (nvcc), CMake, Git, and a C++ build system (Ninja or Make) to build CUTLASS.
# ------------------------------------------------------------

# Defaults
INSTALL_DIR_DEFAULT="$HOME/cutlass"
CUTLASS_ROOT_DEFAULT=""
M=4096
N=4096
K=4096
DTYPE="f16"      # typical tensor-core path
ACCUM="f32"
ITER=50
OUTFILE="../logs/cutlass_results_$(date +%Y%m%d_%H%M%S).csv"

# Parse args
INSTALL_DIR="$INSTALL_DIR_DEFAULT"
CUTLASS_ROOT="$CUTLASS_ROOT_DEFAULT"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir) INSTALL_DIR="$2"; shift 2;;
    --cutlass-root) CUTLASS_ROOT="$2"; shift 2;;
    --m) M="$2"; shift 2;;
    --n) N="$2"; shift 2;;
    --k) K="$2"; shift 2;;
    --dtype) DTYPE="$2"; shift 2;;
    --accum) ACCUM="$2"; shift 2;;
    --iterations) ITER="$2"; shift 2;;
    --out) OUTFILE="$2"; shift 2;;
    -h|--help)
      echo "Usage: $0 [--install-dir DIR] [--cutlass-root DIR] [--m M --n N --k K] [--dtype f16|f32] [--accum f32] [--iterations N] [--out file.csv]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Utilities
have() { command -v "$1" >/dev/null 2>&1; }

fail() { echo "ERROR: $*" >&2; exit 1; }

log() { echo "[cutlass-bench] $*"; }

# 1) Verify NVIDIA GPU presence
if ! have nvidia-smi; then
  fail "No NVIDIA GPU detected (nvidia-smi not found). This benchmark only supports NVIDIA GPUs."
fi

# 2) Find cutlass_profiler in PATH or common locations
find_profiler() {
  if have cutlass_profiler; then
    command -v cutlass_profiler
    return 0
  fi

  # consider CUTLASS_ROOT if provided
  local roots=()
  if [[ -n "$CUTLASS_ROOT" ]]; then
    roots+=("$CUTLASS_ROOT")
  fi

  # common defaults
  roots+=("$INSTALL_DIR" "$HOME/cutlass" "$HOME/src/cutlass" "/opt/cutlass" "/usr/local/cutlass")

  for r in "${roots[@]}"; do
    [[ -d "$r" ]] || continue
    # typical build paths by generator
    for p in \
      "$r/build/tools/profiler/cutlass_profiler" \
      "$r/build/tools/profiler/Release/cutlass_profiler" \
      "$r/build/bin/cutlass_profiler" \
      "$r/tools/profiler/cutlass_profiler"
    do
      if [[ -x "$p" ]]; then
        echo "$p"
        return 0
      fi
    done
  done

  return 1
}

PROFILER_PATH="$(find_profiler || true)"

# 3) If not found, prompt to install & build CUTLASS
maybe_install_cutlass() {
  log "CUTLASS profiler not found."
  read -r -p "Would you like to clone & build CUTLASS now at '$INSTALL_DIR'? [Y/n] " ans
  ans=${ans:-Y}
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    # prerequisite checks
    have git || fail "git is required to clone CUTLASS."
    have cmake || fail "cmake is required to build CUTLASS. (e.g., sudo apt-get install -y cmake)"
    if ! have nvcc; then
      fail "CUDA toolkit (nvcc) not found. Please install NVIDIA CUDA Toolkit compatible with your driver."
    fi

    # Prepare folder
    mkdir -p "$(dirname "$INSTALL_DIR")"
    if [[ -d "$INSTALL_DIR/.git" ]]; then
      log "Existing CUTLASS repo detected at $INSTALL_DIR. Pulling latest..."
      (cd "$INSTALL_DIR" && git pull --ff-only)
    elif [[ -d "$INSTALL_DIR" && -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]]; then
      fail "Install dir '$INSTALL_DIR' exists and is not empty. Use --install-dir to choose another location."
    else
      log "Cloning CUTLASS into $INSTALL_DIR ..."
      git clone --depth 1 https://github.com/NVIDIA/cutlass.git "$INSTALL_DIR"
    fi

    # Configure & build (prefer Ninja if available)
    local gen_args=()
    if have ninja; then
      gen_args+=("-G" "Ninja")
    fi

    log "Configuring CUTLASS build ..."
    cmake -S "$INSTALL_DIR" -B "$INSTALL_DIR/build" \
      "${gen_args[@]}" \
      -DCMAKE_BUILD_TYPE=Release

    log "Building cutlass_profiler (this can take a while) ..."
    cmake --build "$INSTALL_DIR/build" --config Release --target cutlass_profiler -j

    # Re-locate the profiler
    PROFILER_PATH="$(find_profiler || true)"
    [[ -x "${PROFILER_PATH:-}" ]] || fail "Build finished but cutlass_profiler not found. Please check the build logs."
  else
    fail "CUTLASS profiler is required to run this benchmark. Aborting."
  fi
}

if [[ -z "${PROFILER_PATH:-}" ]]; then
  maybe_install_cutlass
fi

log "Using cutlass_profiler: $PROFILER_PATH"

# 4) Run a representative GEMM benchmark
# Try a modern set of flags first; if it fails, fall back to a minimal set.
run_benchmark() {
  local outfile="$1"
  local ok=0

  log "Running GEMM M=${M} N=${N} K=${K} dtype=${DTYPE} accum=${ACCUM}, iterations=${ITER}"
  log "Writing CSV to: $outfile"

  # Attempt: CSV to stdout (commonly supported)
  if "$PROFILER_PATH" \
      --operation=Gemm \
      --m="$M" --n="$N" --k="$K" \
      --dtype="$DTYPE" --accum="$ACCUM" \
      --warmup-iterations=2 \
      --iterations="$ITER" \
      --csv >"$outfile" 2>cutlass_stderr.log; then
    ok=1
  else
    log "Primary invocation failed, trying a simpler command line ..."
    if "$PROFILER_PATH" \
        --operation=Gemm \
        --m="$M" --n="$N" --k="$K" \
        --csv >"$outfile" 2>>cutlass_stderr.log; then
      ok=1
    fi
  fi

  if [[ "$ok" -ne 1 ]]; then
    echo "----- cutlass_profiler stderr (last lines) -----" >&2
    tail -n 50 cutlass_stderr.log >&2 || true
    fail "cutlass_profiler failed to run. Try: '$PROFILER_PATH --help' to inspect supported flags."
  fi
}

run_benchmark "$OUTFILE"

# 5) Summarize key metric (GFLOPs/TFLOPs) if present
PEAK_GFTS=""
if grep -iE '(gflops|tflops)' "$OUTFILE" >/dev/null 2>&1; then
  # Try to parse a GFLOPs/TFLOPs column from CSV header
  # Find the column index and print the last data row's value
  header_line=$(head -n1 "$OUTFILE")
  IFS=',' read -r -a cols <<<"$header_line"

  idx=-1
  for i in "${!cols[@]}"; do
    name="$(echo "${cols[$i]}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    [[ "$name" == "gflops" || "$name" == "tflops" ]] && idx="$i" && break
  done

  if [[ "$idx" -ge 0 ]]; then
    last_line=$(tail -n1 "$OUTFILE")
    IFS=',' read -r -a vals <<<"$last_line"
    metric_val="${vals[$idx]}"
    PEAK_GFTS="$metric_val"
  fi
fi

log "DONE. CSV written to: $OUTFILE"
if [[ -n "$PEAK_GFTS" ]]; then
  log "Parsed performance metric: ${PEAK_GFTS}"
fi

# Machine-readable summary line (for chaining)
echo "BENCHMARK:CUTLASS_PROFILER path=$PROFILER_PATH m=$M n=$N k=$K dtype=$DTYPE accum=$ACCUM iterations=$ITER csv=$OUTFILE metric=${PEAK_GFTS:-NA}"
