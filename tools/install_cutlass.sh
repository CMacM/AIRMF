#!/usr/bin/env bash
set -euo pipefail

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

# Already available on PATH?
if command -v cutlass_profiler >/dev/null 2>&1; then
  say "Found on PATH: $(cutlass_profiler --help >/dev/null 2>&1 && echo cutlass_profiler)"
  exit 0
fi

# Move to third_party/
mkdir -p third_party/ && cd third_party/

# Clone CUTLASS repo
if [[ ! -d cutlass/.git ]]; then
  echo "Cloning CUTLASS repository..."
  git clone https://github.com/NVIDIA/cutlass.git
fi

cd cutlass
mkdir -p build
cd build

# Compile CUTLASS
echo "Building CUTLASS..."
cmake .. \
  -DCUTLASS_NVCC_ARCHS="${ARCH}a" \
  -DCUTLASS_ENABLE_TESTS=OFF \
  -DCUTLASS_UNITY_BUILD_ENABLED=ON \
  -DCUTLASS_LIBRARY_OPERATIONS='conv2d;GEMM' \

# Build and install
make cutlass_profiler -j"$(nproc)"

# Add to PATH
CUTLASS_PROFILER="$(pwd)/tools/profiler/cutlass_profiler"
if [[ -f "$CUTLASS_PROFILER" ]]; then
  # Add to PATH for current session
  export PATH="$(dirname "$CUTLASS_PROFILER"):$PATH"
  echo "CUTLASS profiler installed at: $CUTLASS_PROFILER"
  echo "You may want to add it to your PATH permanently."
fi


