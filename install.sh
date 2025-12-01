#!/usr/bin/env bash
set -euo pipefail

# Resolve AIRMF root (directory containing this install.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIRMF_ROOT="$SCRIPT_DIR"
TOOLS_DIR="$AIRMF_ROOT/tools"
BIN_DIR="$AIRMF_ROOT/bin"

echo ">>> AIRMF install"
echo "    Root   : $AIRMF_ROOT"
echo "    Tools  : $TOOLS_DIR"
echo "    Bin    : $BIN_DIR"
echo

# ---------------------------------------------------------------------------
# 1. Run third-party install scripts under tools/
# ---------------------------------------------------------------------------

run_tool_installer() {
  local name="$1"
  local script="$2"

  if [[ -x "$script" ]]; then
    echo ">>> Running $name installer: $script"
    "$script"
  elif [[ -f "$script" ]]; then
    echo ">>> Making $script executable and running $name installer"
    chmod +x "$script"
    "$script"
  else
    echo "!!! WARNING: $name install script not found at: $script" >&2
  fi
  echo
}

# Adjust names if your scripts differ
run_tool_installer "CUTLASS"      "$TOOLS_DIR/install_cutlass.sh"
run_tool_installer "LIKWID"       "$TOOLS_DIR/install_likwid.sh"
run_tool_installer "NVBandwidth"  "$TOOLS_DIR/install_nvbandwidth.sh"

# ---------------------------------------------------------------------------
# 2. Make project scripts executable
# ---------------------------------------------------------------------------

echo ">>> Making project scripts executable"

# bin/
if [[ -d "$BIN_DIR" ]]; then
  chmod +x "$BIN_DIR"/* 2>/dev/null || true
fi

# workflow_profiling/
if [[ -d "$AIRMF_ROOT/workflow_profiling" ]]; then
  find "$AIRMF_ROOT/workflow_profiling" -type f -name '*.sh' -exec chmod +x {} \;
fi

# system_benchmarking/
if [[ -d "$AIRMF_ROOT/system_benchmarking" ]]; then
  find "$AIRMF_ROOT/system_benchmarking" -type f -name '*.sh' -exec chmod +x {} \;
fi

# tools/ scripts
if [[ -d "$TOOLS_DIR" ]]; then
  find "$TOOLS_DIR" -type f -name '*.sh' -exec chmod +x {} \;
fi

# Top-level .sh scripts (if any)
find "$AIRMF_ROOT" -maxdepth 1 -type f -name '*.sh' -exec chmod +x {} \;

echo ">>> Script permissions updated"
echo

# ---------------------------------------------------------------------------
# 3. Add AIRMF/bin to PATH via ~/.bashrc (if not already there)
# ---------------------------------------------------------------------------

echo ">>> Configuring PATH for AIRMF commands"

if [[ ! -d "$BIN_DIR" ]]; then
  echo "!!! WARNING: bin directory not found at $BIN_DIR; skipping PATH setup." >&2
else
  # Check if already on PATH in current shell
  case ":$PATH:" in
    *":$BIN_DIR:"*)
      echo ">>> $BIN_DIR is already in current PATH."
      ;;
    *)
      # Check if ~/.bashrc already contains this export
      BASHRC="${HOME}/.bashrc"
      LINE="export PATH=\"$BIN_DIR:\$PATH\""

      if [[ -f "$BASHRC" ]] && grep -Fq "$BIN_DIR" "$BASHRC"; then
        echo ">>> $BIN_DIR already referenced in $BASHRC"
      else
        echo ">>> Adding $BIN_DIR to PATH in $BASHRC"
        {
          echo ""
          echo "# Added by AIRMF installer on $(date)"
          echo "$LINE"
        } >> "$BASHRC"
      fi

      echo
      echo ">>> To activate the new PATH in this shell, run:"
      echo "    source \"$BASHRC\""
      echo ">>> After that, you can run AIRMF commands from anywhere, e.g.:"
      echo "    airmf-profile ..."
      ;;
  esac
fi

echo
echo ">>> AIRMF installation complete."
