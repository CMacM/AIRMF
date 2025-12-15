#!/usr/bin/env bash
# install_likwid.sh
set -euo pipefail

# Defaults
VERSION="${VERSION:-stable}"

mkdir -p tools/third_party
cd tools/third_party

TARBALL="likwid-${VERSION}.tar.gz"
URL="http://ftp.fau.de/pub/likwid/${TARBALL}"

# Check if tarball already exists
if [[ -f "${TARBALL}" ]]; then
  echo "LIKWID tarball already exists: ${TARBALL}"
else
  echo "Downloading: ${URL}"
  wget -q --show-progress "${URL}"

  echo "Extracting: ${TARBALL}"
  tar -xaf "${TARBALL}"
fi

# Detect extracted top-level directory
TOPDIR=$(find . -maxdepth 1 -type d -name "likwid-*" | head -n 1 | sed 's|^\./||')
if [[ -z "${TOPDIR}" || ! -d "${TOPDIR}" ]]; then
  echo "Failed to detect LIKWID source directory." >&2
  exit 1
fi
cd "${TOPDIR}"

# Compile
make

# Install (requires sudo)
echo "Installing LIKWID (sudo required)"
sudo make install

echo "Done."
echo "Tip: Edit config.mk and re-run 'make' to customize the build."
