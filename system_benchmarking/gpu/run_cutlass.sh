#!/usr/bin/env bash
set -euo pipefail

# --- Config (overridable via env or CLI) ---
PROFILER_BIN="${PROFILER_BIN:-./cutlass/cutlass/build/tools/profiler/cutlass_profiler}"
M="${1:-8192}"
N="${2:-8192}"
K="${3:-8192}"
OUTDIR="${OUTDIR:-./logs}"
TF32_KERNEL_FILTER="${TF32_KERNEL_FILTER:-*tf32gemm*}"  # common CUTLASS naming for TF32 TC GEMM

mkdir -p "$OUTDIR"

if [[ ! -x "$PROFILER_BIN" ]]; then
  echo "ERROR: Can't execute profiler at: $PROFILER_BIN"
  echo "Tip: set PROFILER_BIN=/path/to/cutlass_profiler"
  exit 1
fi

echo "== CUTLASS Peak FLOPS (FP32 & TF32) =="
echo "Profiler: $PROFILER_BIN"
echo "Problem:  M=$M N=$N K=$K"
echo

# --- Helpers ---
parse_max_gflops () {
  # Robust-ish CSV parser for simple CUTLASS outputs (no embedded commas expected).
  # Prints: "<max_gflops>,<kernel_name>,<op_class>,<math_mode>"
  local csv="$1"
  awk -F, '
    NR==1{
      for (i=1;i<=NF;i++){
        f[$i]=i
      }
      gcol = (f["GFLOP/s"] ? f["GFLOP/s"] : (f["GFLOPs"] ? f["GFLOPs"] : 0))
      kcol = (f["Kernel Name"] ? f["Kernel Name"] : (f["Kernel"] ? f["Kernel"] : 0))
      ocol = (f["Operation"] ? f["Operation"] : 0)
      mcol = (f["Math Instruction"] ? f["Math Instruction"] : (f["Math Mode"] ? f["Math Mode"] : 0))
      next
    }
    NR>1 && gcol>0 {
      # skip obvious non-results
      if ($gcol=="" || $gcol ~ /nan|inf/) next
      g = $gcol + 0
      if (g>best) {best=g; kern=(kcol?kcol:0? $kcol:""); op=(ocol? $ocol:""); math=(mcol? $mcol:"") }
    }
    END{
      if (best>0) {
        printf("%.2f,%s,%s,%s\n", best, kern, op, math)
      }
    }
  ' "$csv"
}

# --- FP32 (SIMT) ---
echo "[1/2] Running FP32 (SIMT) GEMM ..."
"$PROFILER_BIN" \
  --operation=conv2d \
  --op_class=simt \
  --A=f32:column --B=f32:column --C=f32:column --accum=f32 \
  --m="$M" --n="$N" --k="$K" \
  --enable-best-kernel-for-fixed-shape \
  --sort-results-flops-per-sec \
  --output="$OUTDIR/fp32_simt.csv"

FP32_SUMMARY="$(parse_max_gflops "$OUTDIR/fp32_simt.gemm.csv")"
if [[ -z "$FP32_SUMMARY" ]]; then
  echo "WARNING: No FP32 results parsed from $OUTDIR/fp32_simt.gemm.csv"
fi

# --- TF32 (Tensor Cores) ---
echo "[2/2] Running TF32 (Tensor Core) GEMM ..."
"$PROFILER_BIN" \
  --operation=conv2d \
  --op_class=tensorop \
  --A=f32:column --B=f32:column --C=f32:column --accum=f32 \
  --kernels="$TF32_KERNEL_FILTER" \
  --m="$M" --n="$N" --k="$K" \
  --enable-best-kernel-for-fixed-shape \
  --sort-results-flops-per-sec \
  --output="$OUTDIR/tf32_tensorop.csv"
  
# Locate output file with regex


TF32_SUMMARY="$(parse_max_gflops "$OUTDIR/tf32_tensorop.convolution.csv")"
if [[ -z "$TF32_SUMMARY" ]]; then
  echo "WARNING: No TF32 results parsed from $OUTDIR/tf32_tensorop.convolution.csv"
fi

# --- Print summary ---
echo
echo "== Summary (best entries) =="
printf "%-8s %-12s %-12s %-s\n" "Mode" "GFLOP/s" "OpClass" "Kernel"
IFS=',' read -r gflops kernel opclass math <<<"$FP32_SUMMARY"
if [[ -n "${gflops:-}" ]]; then
  printf "%-8s %-12s %-12s %-s\n" "FP32" "$gflops" "${opclass:-simt}" "${kernel:-N/A}"
else
  printf "%-8s %-12s %-12s %-s\n" "FP32" "N/A" "simt" "N/A"
fi
IFS=',' read -r gflops kernel opclass math <<<"$TF32_SUMMARY"
if [[ -n "${gflops:-}" ]]; then
  printf "%-8s %-12s %-12s %-s\n" "TF32" "$gflops" "${opclass:-tensorop}" "${kernel:-N/A}"
else
  printf "%-8s %-12s %-12s %-s\n" "TF32" "N/A" "tensorop" "N/A"
fi

echo
