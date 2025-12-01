#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIRMF_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CUTLASS_PROFILER_BIN="$AIRMF_ROOT/tools/third_party/cutlass/build/tools/profiler/cutlass_profiler"

usage() {
  cat <<EOF
Usage: gpu_peakflops_cutlass --op OP --op_type TYPE --precision PREC

  --op OP           gemm | conv2d
  --op_type TYPE    tensorcore | cudacore
  --precision P     fp32 | fp16 | bf16 | tf32 | int8

Runs the CUTLASS profiler with a fixed problem size,
writes a CSV, and prints the max throughput in TFLOP/s.

Examples:
  gpu_peakflops_cutlass --op conv2d --op_type tensorcore --precision tf32
  gpu_peakflops_cutlass --op conv2d --op_type cudacore  --precision fp32
  gpu_peakflops_cutlass --op gemm   --op_type tensorcore --precision fp16
EOF
}

# --------------------- parse CLI -----------------------

OP=""
OP_TYPE=""
PRECISION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --op)        OP="${2:-}";        shift 2 ;;
    --op_type)   OP_TYPE="${2:-}";   shift 2 ;;
    --precision) PRECISION="${2:-}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)
      echo "gpu_peakflops_cutlass: unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

[[ -z "$OP" || -z "$OP_TYPE" || -z "$PRECISION" ]] && {
  echo "gpu_peakflops_cutlass: --op, --op_type, --precision are required" >&2
  usage
  exit 2
}

case "$OP" in
  gemm|GEMM)          OP="gemm" ;;
  conv2d|CONV2D|conv) OP="conv2d" ;;
  *)
    echo "gpu_peakflops_cutlass: unsupported --op '$OP' (gemm|conv2d)" >&2
    exit 2
    ;;
esac

case "$OP_TYPE" in
  tensorcore|tensorop|tensor-core)
    OP_TYPE="tensorcore"
    CUTLASS_OP_CLASS="tensorop"
    ;;
  cudacore|cuda-core|simt)
    OP_TYPE="cudacore"
    CUTLASS_OP_CLASS="simt"
    ;;
  *)
    echo "gpu_peakflops_cutlass: unsupported --op_type '$OP_TYPE' (tensorcore|cudacore)" >&2
    exit 2
    ;;
esac

# Map precision to CUTLASS element & accumulator types (single source of truth)
case "$PRECISION" in
  fp32|f32)
    PRECISION="fp32"
    ELEM="f32"
    ACCUM="f32"
    MATH="f32"
    ;;
  fp16|f16)
    PRECISION="fp16"
    ELEM="f16"
    ACCUM="f32"
    MATH="f32"
    ;;
  bf16)
    PRECISION="bf16"
    ELEM="bf16"
    ACCUM="f32"
    MATH="f32"
    ;;
  tf32)
    PRECISION="tf32"
    ELEM="tf32"   # inputs
    ACCUM="f32"
    MATH="tf32"
    ;;
  int8|s8)
    PRECISION="int8"
    ELEM="s8"
    ACCUM="s32"
    MATH="s32"
    ;;
  *)
    echo "gpu_peakflops_cutlass: unsupported --precision '$PRECISION'" >&2
    exit 2
    ;;
esac

if [[ "$OP_TYPE" == "tensorcore" && "$PRECISION" == "fp32" ]]; then
  echo "gpu_peakflops_cutlass: tensorcore + fp32 is usually not supported; use fp16/bf16/tf32/int8" >&2
  exit 2
fi

[[ -x "$CUTLASS_PROFILER_BIN" ]] || {
  echo "gpu_peakflops_cutlass: '$CUTLASS_PROFILER_BIN' not found/executable" >&2
  exit 1
}

# Base name without CUTLASS suffixes
OUT_BASE="gpu_peakflops_cutlass_${OP}_${OP_TYPE}_${PRECISION}"
# This is what CUTLASS will actually write:
OUT_CSV="${OUT_BASE}.${OP}.csv"


# --------------------- helpers -------------------------

run_conv2d() {
  # Fixed conv2d: N=8, H=W=224, C=K=128, R=S=3, NHWC
  local N=8 H=224 W=224 C=128 K=128 R=3 S=3
  local PAD_H=1 PAD_W=1 STRIDE_H=1 STRIDE_W=1 DIL_H=1 DIL_W=1

  # Inputs always use ELEM; output uses ELEM except TF32 where we store FP32
  local ACT_LAYOUT="${ELEM}:nhwc"
  local FILT_LAYOUT="${ELEM}:nhwc"
  local OUT_ELEM="$ELEM"
  if [[ "$PRECISION" == "tf32" ]]; then
    OUT_ELEM="f32"
  fi
  local OUT_LAYOUT="${OUT_ELEM}:nhwc"

  local COMMON=(
    --operation=Conv2d
    --conv_kind=fprop
    --op_class="$CUTLASS_OP_CLASS"
    --Activation="$ACT_LAYOUT"
    --Filter="$FILT_LAYOUT"
    --Output="$OUT_LAYOUT"
    --accum="$ACCUM"
    --n="$N" --h="$H" --w="$W" --c="$C" --k="$K" --r="$R" --s="$S"
    --pad_h="$PAD_H" --pad_w="$PAD_W"
    --stride_h="$STRIDE_H" --stride_w="$STRIDE_W"
    --dilation_h="$DIL_H" --dilation_w="$DIL_W"
    --providers=cutlass
    --output="$OUT_BASE" --sort-results=true
  )

  if [[ "$CUTLASS_OP_CLASS" == "tensorop" ]]; then
    "$CUTLASS_PROFILER_BIN" \
      --verification-providers=device \
      "${COMMON[@]}"
  else
    "$CUTLASS_PROFILER_BIN" "${COMMON[@]}"
  fi
}

run_gemm() {
  # GEMM: C = A * B + C with all column-major (safe default)
  local M=8192 N=8192 K=8192

  local A_LAYOUT="${ELEM}:column"
  local B_LAYOUT="${ELEM}:column"

  # For TF32: inputs TF32, output FP32; others: C uses ELEM
  local C_ELEM="$ELEM"
  if [[ "$PRECISION" == "tf32" ]]; then
    C_ELEM="f32"
  fi
  local C_LAYOUT="${C_ELEM}:column"

  "$CUTLASS_PROFILER_BIN" \
    --operation=Gemm \
    --op_class="$CUTLASS_OP_CLASS" \
    --A="$A_LAYOUT" --B="$B_LAYOUT" --C="$C_LAYOUT" --accum="$ACCUM" \
    --m="$M" --n="$N" --k="$K" \
    --providers=cutlass \
    --output="$OUT_BASE" --sort-results=true
}

parse_max_tflops() {
  local f="$1"
  awk -F',' '
    NR==1 {
      for (i=1; i<=NF; i++) {
        h = $i
        gsub(/"/, "", h)
        if (h == "TFLOPs" || h == "tflops") tcol = i
        if (h == "GFLOPs" || h == "gflops") gcol = i
      }
      next
    }
    NR > 1 {
      if (tcol) {
        v = $tcol
      } else if (gcol) {
        v = $gcol / 1000.0
      } else {
        next
      }
      gsub(/"/, "", v)
      if (v + 0 > max) max = v + 0
    }
    END {
      if (max > 0) {
        printf "%.6f\n", max
      }
    }
  ' "$f"
}

# --------------------- run + report --------------------

echo ">>> CUTLASS benchmark"
echo "    Operation : $OP"
echo "    Type      : $OP_TYPE ($CUTLASS_OP_CLASS)"
echo "    Precision : $PRECISION"
echo "    Output    : $OUT_CSV"
echo

if [[ "$OP" == "conv2d" ]]; then
  run_conv2d
else
  run_gemm
fi

if [[ ! -s "$OUT_CSV" ]]; then
  echo "gpu_peakflops_cutlass: CSV is empty – likely no kernels matched this configuration." >&2
  exit 1
fi

MAX_TFLOPS="$(parse_max_tflops "$OUT_CSV" || true)"

if [[ -z "$MAX_TFLOPS" ]]; then
  echo "gpu_peakflops_cutlass: could not derive TFLOP/s from $OUT_CSV" >&2
  echo "First few lines of the CSV for debugging:" >&2
  echo "Check output to ensure requested benchmark was valid." >&2
  head -n 5 "$OUT_CSV" >&2
  exit 1
fi

echo ">>> Max throughput: ${MAX_TFLOPS} TFLOP/s"
rm -f "$OUT_CSV"   # uncomment if you want to auto-clean
