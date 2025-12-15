#!/usr/bin/env bash
# install_likwid.sh
set -euo pipefail

# CUDA/NVCC detection
if [ -z "${CUDACXX:-}" ]; then
  if command -v nvcc >/dev/null 2>&1; then
    export CUDACXX=$(command -v nvcc)
  elif [ -x /usr/local/cuda/bin/nvcc ]; then
    export CUDACXX=/usr/local/cuda/bin/nvcc
  else
    echo "nvcc not found. Install CUDA or add it to PATH."
    exit 1
  fi
fi

echo "Using NVCC at: $CUDACXX"

# Clone nvbandwidth repo
mkdir -p tools/third_party
cd tools/third_party
if [[ ! -d nvbandwidth/.git ]]; then
  echo "Cloning nvbandwidth repository..."
  git clone https://github.com/NVIDIA/nvbandwidth.git
fi
cd nvbandwidth

# Run install script
chmod +x debian_install.sh
sudo -E ./debian_install.sh