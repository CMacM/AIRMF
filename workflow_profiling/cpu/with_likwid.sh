#!/usr/bin/env bash
set -euo pipefail

CORES="${CORES:-0-$(($(nproc)-1))}"
OUTFILE="${OUTFILE:-./likwid_results.csv}"

mkdir -p "$(dirname -- "$OUTFILE")"

echo ">>> Running under LIKWID"
echo ">>> Cores:   $CORES"
echo ">>> Command: $*"
echo ">>> Output:  $OUTFILE"

likwid-perfctr -C "$CORES" -g FLOPS_SP -g FLOPS_DP -g MEM -O -o "$OUTFILE" "$@" | tee /dev/tty

awk -v FS='[;,]' '
function toNum(s, t){t=s; gsub(/[^0-9eE+.\-]/,"",t); return (t==""?0:t+0)}
{
  line=$0
  is_flops = (line ~ /(^|[;,])FLOPS_(SP|DP)([;,]|$)/)
  is_mem   = (line ~ /(^|[;,])MEM([;,]|$)/)
  if (is_flops && line ~ /Region[[:space:]]+MFLOP([^\/]|$)/) {
    for (i=NF;i>=1;i--) if ($i ~ /[0-9]/){ total_mflops+=toNum($i); break }
  } else if (is_mem && line ~ /Memory[[:space:]]+data[[:space:]]+volume[[:space:]]+\[MBytes\]/) {
    for (i=NF;i>=1;i--) if ($i ~ /[0-9]/){ total_mbytes+=toNum($i); break }
  }
}
END{
  total_flops = total_mflops*1e6
  total_bytes = total_mbytes*1e6
  printf("Total FLOPs: %.0f (%.3f GFLOPs)\n", total_flops, total_flops/1e9)
  printf("Total DRAM traffic: %.0f bytes (%.3f GB)\n", total_bytes, total_bytes/1e9)
}
' "$OUTFILE"
