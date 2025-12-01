#!/usr/bin/env bash
set -euo pipefail

# defaults
OUTFILE="storage_profile.txt"

usage() {
  cat <<'EOF'
Usage: script.sh [options]

Options:
  -o, --outfile FILE       Output file. Default: storage_profile.txt.
  -h, --help               Show this help.

You can use --flag=value or --flag value.
EOF
}

# parse args
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--outfile)
      [ $# -ge 2 ] || { echo "error: --outfile needs a value" >&2; exit 2; }
      OUTFILE="$2"; shift 2 ;;
    --outfile=*)
      OUTFILE="${1#*=}"; shift ;;
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
echo "OUTFILE=$OUTFILE"

# Clear caches before each run to pick up reads from disk
sudo sync
echo 3 | sudo tee /proc/sys/vm/drop_caches

# start timing the workflow
START_TIME=$(date +%s)

/usr/bin/time -v "$@" 2>&1 | tee "$OUTFILE"

# end timing the workflow
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Append elapsed time to file
echo "Elapsed time (s): $ELAPSED" >> "$OUTFILE"

# Parse outfile and print read and write volumes
READ_BLOCKS=$(grep "File system inputs" "$OUTFILE" | awk -F': ''{print $2}' | tr -d ' ')
WRITE_BLOCKS=$(grep "File system outputs" "$OUTFILE" | awk -F': ''{print $2}' | tr -d ' ')

# Convert to GBs
READ_GB=$(echo "scale=2; $READ_BLOCKS * 512 / (1024^3)" | bc)
WRITE_GB=$(echo "scale=2; $WRITE_BLOCKS * 512 / (1024^3)" | bc)

echo "Total read volume (GB): $READ_GB" >> "$OUTFILE"
echo "Total write volume (GB): $WRITE_GB" >> "$OUTFILE"