#!/usr/bin/env bash
# install_likwid.sh
set -euo pipefail

# Defaults
VERSION="${VERSION:-stable}"

mkdir -p third_party
cd third_party

TARBALL="likwid-${VERSION}.tar.gz"
URL="http://ftp.fau.de/pub/likwid/${TARBALL}"

echo "Downloading: ${URL}"
wget -q --show-progress "${URL}"

echo "Extracting: ${TARBALL}"
tar -xaf "${TARBALL}"

# Detect extracted top-level directory
TOPDIR="$(tar -tzf "${TARBALL}" | head -1 | cut -d/ -f1)"
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
