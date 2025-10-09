#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# CUTLASS benchmark installer for AI Roofline Modelling Framework
# - Installs CUTLASS (clone + build) if not found
#
# Notes:
# - Requires CUDA toolkit (nvcc), CMake, Git, and a C++ build system (Ninja or Make) to build CUTLASS.
# ------------------------------------------------------------

# Detect GPU architecture
# ---------- GPU arch detection ----------
# Respect CUDA_VISIBLE_DEVICES (defaults to GPU 0)
GPU_INDEX="${GPU_INDEX:-0}"
# Query visible GPUs; pick the first visible by default
IFS=$'\n' read -r -d '' -a GPU_NAMES < <(nvidia-smi --query-gpu=name --format=csv,noheader && printf '\0' || true)
IFS=$'\n' read -r -d '' -a GPU_CCS   < <(nvidia-smi --query-gpu=compute_cap --format=csv,noheader && printf '\0' || true)

if [[ ${#GPU_NAMES[@]} -eq 0 ]]; then
  echo "ERROR: No NVIDIA GPU detected by nvidia-smi." >&2
  exit 1
fi

# Choose GPU by index (after CUDA_VISIBLE_DEVICES masking)
GPU_NAME="${GPU_NAMES[$GPU_INDEX]}"
GPU_CC="${GPU_CCS[$GPU_INDEX]}"            # e.g., "8.0", "8.6", "8.9", "9.0", "10.0"
GPU_CC_SHORT="${GPU_CC/./}"                # "80", "86", "89", "90", "100"

# Map to CUTLASS_NVCC_ARCHS. Allow override.
ARCH="${ARCH_OVERRIDE:-$GPU_CC_SHORT}"

CUTLASS_ROOT="${CUTLASS_ROOT:-$PWD/cutlass}"
if [[ ! -d "$CUTLASS_ROOT" ]]; then
  git clone https://github.com/NVIDIA/cutlass.git "$CUTLASS_ROOT"
fi

# Construct build directory
export CUDACXX="${CUDA_INSTALL_PATH:-/usr/local/cuda}/bin/nvcc"

# build directory inside CUTLASS
mkdir -p "$CUTLASS_ROOT/build"
cd "$CUTLASS_ROOT/build"

# Build only GEMM operations
cmake .. -DCUTLASS_NVCC_ARCHS="${ARCH}a" \
    -DCUTLASS_ENABLE_TESTS=OFF \
    -DCUTLASS_UNITY_BUILD_ENABLED=ON \
    -DCUTLASS_LIBRARY_OPERATIONS=gemm

# Compile the CUTLASS profiler
make cutlass_profiler -j12