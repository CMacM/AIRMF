#!/usr/bin/env bash
set -euo pipefail

OUTFILE="gpu_ncu_report"

usage() {
  cat <<'EOF'
Usage: profile_workflow_gpu.sh [options] 

Options:
  -o, --outfile FILE         Output file. Default: gpu_ncu_report.csv.
  -h, --help               Show this help.

You can use --flag=value or --flag value.
EOF
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--outfile)
      OUTFILE="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift
      break ;;
    -*)
      echo "profile_workflow_gpu: unknown option: $1" >&2
      usage
      exit 2 ;;
    *)
      echo "profile_workflow_gpu: unexpected argument before '--': $1" >&2
      usage
      exit 2 ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "profile_workflow_gpu: missing target_command after '--'" >&2
  usage
  exit 2
fi

if ! command -v ncu >/dev/null 2>&1; then
  echo "profile_workflow_gpu: 'ncu' (Nsight Compute CLI) not found in PATH" >&2
  exit 1
fi

TARGET_CMD=("$@")

echo "OUTFILE=${OUTFILE}"
echo "TARGET=${TARGET_CMD[*]}"

# NCU metrics to collect for compute and memory analysis
METRICS='smsp__sass_thread_inst_executed_op_hadd_pred_on.sum,'\
'smsp__sass_thread_inst_executed_op_hmul_pred_on.sum,'\
'smsp__sass_thread_inst_executed_op_hfma_pred_on.sum,'\
'smsp__sass_thread_inst_executed_op_ffma_pred_on.sum,'\
'smsp__sass_thread_inst_executed_op_fmul_pred_on.sum,'\
'smsp__sass_thread_inst_executed_op_fadd_pred_on.sum,'\
'smsp__sass_thread_inst_executed_op_dfma_pred_on.sum,'\
'smsp__sass_thread_inst_executed_op_dmul_pred_on.sum,'\
'smsp__sass_thread_inst_executed_op_dadd_pred_on.sum,'\
'sm__ops_path_tensor_src_tf32_dst_fp32.sum,'\
'dram__bytes.sum',\
'pcie__read_bytes.sum,'\
'pcie__write_bytes.sum'

sudo env \
    PATH="$PATH" \
    LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
    CONDA_PREFIX="$CONDA_PREFIX" \
    "$(command -v ncu)" \
    --target-processes all \
    --metrics "$METRICS" \
    --force-overwrite \
    --export "$OUTFILE" \
    "${TARGET_CMD[@]}"

# Convert ncu output to CSV
ncu -i "$OUTFILE.ncu-rep" --page raw --csv > "$OUTFILE.csv"

echo "All tiles processed. Results are in $OUTFILE.csv"