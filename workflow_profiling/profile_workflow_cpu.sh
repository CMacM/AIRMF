#!/usr/bin/env bash
set -euo pipefail

USE_L3=false
OUTFILE=cpu_likwid_report.txt

usage() {
  cat <<'EOF'
Usage: profile_workflow_cpu.sh [options] -- command [args...]

Options:
  -L, --use-l3             Enable L3. Default: false.
  -o, --outfile            Output file
  -h, --help               Show this help.

You can use --flag=value or --flag value.
EOF
}

# parse args
while [ $# -gt 0 ]; do
  case "$1" in
    -L|--use-l3)
      USE_L3=true; shift ;;
    -o|--outfile)
      OUTFILE=$2; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    --) shift; break ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage; exit 2 ;;
    *)  # positional (stop parsing if you expect none)
      break ;;
  esac
done

# show config (optional)
echo ">>> USE_L3=$USE_L3"
echo ">>> OUTFILE=$OUTFILE"

if $USE_L3; then
  MEM_GROUP="L3"
else
  MEM_GROUP="MEM"
fi

likwid-perfctr -C 0-$(($(nproc)-1)) \
  -g FLOPS_SP \
  -g FLOPS_DP \
  -g $MEM_GROUP \
  -f \
  -o "$OUTFILE" \
  -O \
  "$@" | tee /dev/tty
  

# end timing the workflow
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

#Append elapsed time to the output file
echo ">>> Elapsed time (s): $ELAPSED" >> $OUTFILE

echo ">>> LIKWID monitoring complete. Report file saved to $OUTFILE"
