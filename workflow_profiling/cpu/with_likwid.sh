#!/usr/bin/env bash
set -euo pipefail

GROUPS="${GROUPS:-FLOPS_SP,FLOPS_DP,MEM,L3}" # LIKWID groups to monitor
CORES="${CORES:-0-$(($(nproc)-1))}" # Obtain number of CPU cores
OUTFILE="${OUTFILE:-./likwid_results.csv}" # Default output file

echo ">>> Running under LIKWID"
echo ">>> Cores:   $CORES"
echo ">>> Command: $*"
echo ">>> Output:  $OUTFILE"

# Parse the groups into -g arguments
IFS=',' read -ra GROUP_ARRAY <<< "$GROUPS"
GROUP_ARGS=()
for group in "${GROUP_ARRAY[@]}"; do
  GROUP_ARGS+=("-g" "$group")
done

# Run the command with LIKWID monitoring
likwid-perfctr -C "$CORES" "${GROUP_ARGS[@]}" -o "$OUTFILE" "$@" | tee /dev/tty

echo ">>> LIKWID monitoring complete. Report file saved to $OUTFILE"
