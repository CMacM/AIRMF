#!/usr/bin/env bash
# install_likwid.sh
set -euo pipefail

# Defaults
VERSION="${VERSION:-stable}"
JOBS="${JOBS:-$(nproc)}"

# Parse K=V args. VERSION and JOBS are handled above but may be overridden here.
declare -A KV
for arg in "$@"; do
  if [[ "$arg" =~ ^[A-Za-z_][A-Za-z0-9_]*=.+$ ]]; then
    key="${arg%%=*}"
    val="${arg#*=}"
    if [[ "$key" == "VERSION" ]]; then VERSION="$val"; continue; fi
    if [[ "$key" == "JOBS" ]]; then JOBS="$val"; continue; fi
    KV["$key"]="$val"
  else
    echo "Skip non K=V arg: $arg"
  fi
done

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

# Ensure config.mk exists
if [[ ! -f config.mk ]]; then
  echo "config.mk not found. Creating empty one to append overrides."
  : > config.mk
fi

# Append overrides to config.mk so they take precedence.
# This avoids brittle in-place sed over existing ?= defaults.
if [[ "${#KV[@]}" -gt 0 ]]; then
  echo "# ---- BEGIN auto overrides from install_likwid.sh ----" >> config.mk
  for k in "${!KV[@]}"; do
    v="${KV[$k]}"
    # Escape backslashes and quotes for safety
    v_escaped="${v//\\/\\\\}"
    v_escaped="${v_escaped//\"/\\\"}"
    echo "${k} = ${v_escaped}" >> config.mk
  done
  echo "# ---- END auto overrides ----" >> config.mk
fi

echo "Building LIKWID (jobs: ${JOBS})"
make -j"${JOBS}"

echo "Installing LIKWID (sudo required)"
sudo make install

echo "Done."
echo "Tip: rerun with overrides, e.g.:"
echo "  ./install_likwid.sh VERSION=stable NVIDIA_INTERFACE=true BUILDDAEMON=true PREFIX=/opt/likwid"
