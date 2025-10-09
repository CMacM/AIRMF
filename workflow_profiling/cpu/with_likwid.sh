#!/usr/bin/env bash
# likwid-run.sh : Run a command under LIKWID performance monitoring
#
# Usage:
#   ./likwid-run.sh "python preprocess.py"
#   ./likwid-run.sh "./run_workflow.sh"
#
# Options (env vars):
#   CORES   = core list (default: all cores)
#   GROUPS  = performance groups (default: FLOPS_SP and MEM)
#   OUTDIR  = directory to store CSV results (default: ./likwid_results)

set -euo pipefail

# Defaults
CORES="${CORES:-0-$(($(nproc)-1))}"4444444444444444444444444
GROUPS="${GROUPS:-FLOPS_DP FLOPS_SP L3}"
OUTDIR="${OUTDIR:-./likwid_results}"

mkdir -p "$OUTDIR"

# Build LIKWID group args
GROUP_ARGS=()
for g in $GROUPS; do
  GROUP_ARGS+=(-g "$g")
done

# Output file name with timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CMD_HASH=$(echo "$@" | tr ' /' '__')
OUTFILE="$OUTDIR/${CMD_HASH}_${TIMESTAMP}.csv"

echo ">>> Running under LIKWID"
echo ">>> Cores:   $CORES"
echo ">>> Groups:  $GROUPS"
echo ">>> Command: $*"
echo ">>> Output:  $OUTFILE"

# Check for presence of output file and if it exists, remove it
if [[ -f "$OUTFILE" ]]; then
  echo "Warning: Output file $OUTFILE already exists. It will be overwritten."
  rm -f "$OUTFILE"
fi

# May need to run as sudo or enable access to the performance counters
# via sudo likwid-accessD start
likwid-perfctr -C "$CORES" \
"${GROUP_ARGS[@]}" \
-O -o "$OUTFILE" \
"$@"

# awk notes:
# - FS splits on comma or semicolon.
# - We sum rows where:
#     * Group column (or whole line) mentions the chosen FLOPS_GROUP AND the metric is 'Region MFLOP'  (NOT MFLOP/s)
#     * Group mentions MEM AND the metric is 'Memory data volume [MBytes]'
# - We strip units/symbols and parse scientific notation safely.
awk -v GROUP="$FLOPS_GROUP" '
BEGIN {
  FS = "[;,]"; 
  total_mflops = 0.0;
  total_mbytes = 0.0;
}
function toNum(s,    t) {
  t = s;
  gsub(/[^0-9eE+.\-]/, "", t);
  if (t == "" || t == "+" || t == "-" || t == "." ) return 0.0;
  return t + 0.0;
}
{
  line = $0;

  # Try to locate common columns by name if present (case-insensitive):
  # Some LIKWID CSVs have columns like: "Group;Event;Metric;Value;Unit;...".
  # We’ll heuristically detect metric name and value by searching the line text.
  is_flops_group = (line ~ GROUP);
  is_mem_group   = (line ~ /(^|[;,])MEM([;,]|$)/);

  # Detect metric names by their canonical strings
  has_region_mflop      = (line ~ /Region[[:space:]]+MFLOP([^\/]|$)/);       # avoid MFLOP/s
  has_mem_data_mbytes   = (line ~ /Memory[[:space:]]+data[[:space:]]+volume[[:space:]]+\[MBytes\]/);

  # Value is typically in the last field or near the end; grab the last numeric token.
  # We scan fields from right to left and pick the first numeric-looking token.
  if (is_flops_group && has_region_mflop) {
    for (i=NF; i>=1; i--) {
      v = toNum($i);
      if ($i ~ /[0-9]/) { total_mflops += v; break; }
    }
  }
  else if (is_mem_group && has_mem_data_mbytes) {
    for (i=NF; i>=1; i--) {
      v = toNum($i);
      if ($i ~ /[0-9]/) { total_mbytes += v; break; }
    }
  }
}
END {
  total_flops = total_mflops * 1e6;      # MFLOP -> FLOPs
  total_bytes = total_mbytes * 1e6;      # MBytes (decimal) -> bytes

  gflops = total_flops / 1e9;            # decimal billions
  gbytes = total_bytes / 1e9;            # decimal GB

  printf("FLOPS group: %s\n", GROUP);
  printf("Total FLOPs: %.0f ops (%.3f GFLOPs)\n", total_flops, gflops);
  printf("Total DRAM traffic: %.0f bytes (%.3f GB)\n", total_bytes, gbytes);
}
' "$CSV"