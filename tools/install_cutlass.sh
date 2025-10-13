#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# CUTLASS detector/installer for AI Roofline Modelling Framework
# - Finds an existing cutlass_profiler or builds a pinned version user-locally.
#
# Layout assumption (same as LIKWID plan):
#   airmf/
#     tools/
#       detect_cutlass.sh   <-- this file
#     third_party/
#       sources/            <-- git clone cache (ignored by VCS)
#       _builds/            <-- local installs (ignored by VCS)
#
# On success, prints `export PATH=...` and `export CUTLASS_PREFIX=...`
# so you can:  eval "$(/path/to/tools/detect_cutlass.sh)"
#
# Requirements to BUILD from source (fallback):
#   - CUDA toolkit (nvcc), CMake, Git, Ninja or Make, a C++ compiler
# ------------------------------------------------------------

say() { echo "[cutlass-detect] $*"; }
die() { echo "[cutlass-detect][ERROR] $*" >&2; exit 1; }

# ----------------------------
# Config (override via env)
# ----------------------------
PIN_TAG="${PIN_TAG:-v3.4.0}"                # pinned tag (adjust as needed)
PIN_COMMIT="${PIN_COMMIT:-}"                # optional exact commit override
PREFIX="${PREFIX:-$(pwd)/third_party/_builds/cutlass-${PIN_TAG}}"
SRC_DIR="${SRC_DIR:-$(pwd)/third_party/sources/cutlass}"
BUILD_SUBDIR="${BUILD_SUBDIR:-build-${PIN_TAG}}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 8)}"

# CUDA/NVCC detection
CUDACXX="${CUDACXX:-${CUDA_INSTALL_PATH:-/usr/local/cuda}/bin/nvcc}"

# GPU arch detection (for CMAKE_CUDA_ARCHITECTURES)
GPU_INDEX="${GPU_INDEX:-0}"
get_cc_short() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    # pick CC for first visible GPU (after CUDA_VISIBLE_DEVICES)
    mapfile -t CCS < <(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null || true)
    if [[ ${#CCS[@]} -gt 0 ]]; then
      local cc="${CCS[$GPU_INDEX]}"
      cc="${cc/./}"     # "8.0" -> "80", "9.0" -> "90", "10.0" -> "100"
      echo "$cc"
      return 0
    fi
  fi
  echo ""  # fallback to empty (lets CMake choose, or user overrides)
}
ARCH_OVERRIDE="${ARCH_OVERRIDE:-}"  # e.g. "80", "90", "100"
ARCH="$( [[ -n "$ARCH_OVERRIDE" ]] && echo "$ARCH_OVERRIDE" || get_cc_short )"

# ----------------------------
# 0) Already available on PATH?
# ----------------------------
if command -v cutlass_profiler >/dev/null 2>&1; then
  say "Found on PATH: $(cutlass_profiler --help >/dev/null 2>&1 && echo cutlass_profiler)"
  exit 0
fi

# ----------------------------
# 1) Try environment modules (common on HPC)
# ----------------------------
if command -v module >/dev/null 2>&1; then
  for mod in cutlass CUTLASS; do
    if module avail "$mod" 2>&1 | grep -qi "$mod"; then
      say "Trying environment module: $mod"
      # shellcheck disable=SC1090
      module load "$mod" && command -v cutlass_profiler >/dev/null 2>&1 && exit 0
    fi
  done
fi

# ----------------------------
# 2) Try Spack (if present)
# ----------------------------
if command -v spack >/dev/null 2>&1; then
  say "Trying Spack: spack install cutlass"
  # Note: Spack package name may be 'cutlass'. If site recipes differ, this may fail harmlessly.
  if spack install cutlass; then
    # shellcheck disable=SC2046
    eval "$(spack load --sh cutlass)" || true
    if command -v cutlass_profiler >/dev/null 2>&1; then
      say "Using Spack-provided cutlass_profiler"
      exit 0
    fi
  fi
fi

# ----------------------------
# 3) Fallback: pinned source build (user space, no sudo)
# ----------------------------
say "Falling back to pinned source build: ${PIN_TAG:-$PIN_COMMIT}"

# Basic tool checks (only for build path)
command -v git    >/dev/null 2>&1 || die "git not found"
command -v cmake  >/dev/null 2>&1 || die "cmake not found"
command -v "$CUDACXX" >/dev/null 2>&1 || die "nvcc not found at CUDACXX=$CUDACXX"
GENERATOR="Unix Makefiles"
if command -v ninja >/dev/null 2>&1; then
  GENERATOR="Ninja"
fi

mkdir -p "$(dirname "$SRC_DIR")" "$PREFIX"

# Shallow clone (pinned)
if [[ ! -d "$SRC_DIR/.git" ]]; then
  if [[ -n "$PIN_TAG" ]]; then
    say "Cloning CUTLASS @ $PIN_TAG"
    git clone --depth 1 --branch "$PIN_TAG" https://github.com/NVIDIA/cutlass.git "$SRC_DIR"
  else
    say "Cloning CUTLASS default branch"
    git clone https://github.com/NVIDIA/cutlass.git "$SRC_DIR"
  fi
fi

pushd "$SRC_DIR" >/dev/null
if [[ -n "$PIN_COMMIT" ]]; then
  say "Checking out commit $PIN_COMMIT"
  git fetch --depth 1 origin "$PIN_COMMIT"
  git checkout --detach "$PIN_COMMIT"
fi

BUILD_DIR="$SRC_DIR/$BUILD_SUBDIR"
mkdir -p "$BUILD_DIR"

# Compose CMake args
CMAKE_ARGS=(
  -S "$SRC_DIR"
  -B "$BUILD_DIR"
  -G "$GENERATOR"
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
  -DCMAKE_CUDA_COMPILER="$CUDACXX"
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCUTLASS_ENABLE_TESTS=OFF
  -DCUTLASS_UNITY_BUILD_ENABLED=ON
)
# Prefer modern CMake arch variable if we have a numeric arch
if [[ -n "$ARCH" ]]; then
  CMAKE_ARGS+=(-DCMAKE_CUDA_ARCHITECTURES="$ARCH")
fi

say "Configuring with generator: $GENERATOR (ARCH=${ARCH:-auto})"
cmake "${CMAKE_ARGS[@]}"

say "Building cutlass_profiler (jobs=$JOBS)"
cmake --build "$BUILD_DIR" --target cutlass_profiler -- -j"$JOBS"

# Try to install if the project supports it; otherwise stage bin manually
if cmake --build "$BUILD_DIR" --target install -- -j"$JOBS" 2>/dev/null; then
  BIN_DIR="$PREFIX/bin"
else
  BIN_DIR="$PREFIX/bin"
  mkdir -p "$BIN_DIR"
  # Find the profiler binary in the build tree
  PROF_BIN="$(find "$BUILD_DIR" -type f -name cutlass_profiler -perm -111 | head -n1 || true)"
  [[ -n "$PROF_BIN" ]] || die "Built but couldn't locate cutlass_profiler binary"
  cp -f "$PROF_BIN" "$BIN_DIR/"
fi
popd >/dev/null

# Exports for caller to eval
echo "export PATH=\"$BIN_DIR:\$PATH\""
echo "export CUTLASS_PREFIX=\"$PREFIX\""

# Verify
if PATH="$BIN_DIR:$PATH" command -v cutlass_profiler >/dev/null 2>&1; then
  say "Installed to $PREFIX"
  exit 0
else
  die "CUTLASS install completed but cutlass_profiler not found on PATH"
fi
