# #!/usr/bin/env bash
# set -euo pipefail

# # defaults
# OUTFILE="storage_profile.txt"

# usage() {
#   cat <<'EOF'
# Usage: script.sh [options]

# Options:
#   -o, --outfile FILE       Output file. Default: storage_profile.txt.
#   -h, --help               Show this help.

# You can use --flag=value or --flag value.
# EOF
# }

# # parse args
# while [ $# -gt 0 ]; do
#   case "$1" in
#     -o|--outfile)
#       [ $# -ge 2 ] || { echo "error: --outfile needs a value" >&2; exit 2; }
#       OUTFILE="$2"; shift 2 ;;
#     --outfile=*)
#       OUTFILE="${1#*=}"; shift ;;
#     -h|--help)
#       usage; exit 0 ;;
#     --) shift; break ;;
#     -*)
#       echo "error: unknown option: $1" >&2
#       usage; exit 2 ;;
#     *)  # positional (stop parsing if you expect none)
#       break ;;
#   esac
# done

# # show config (optional)
# echo "OUTFILE=$OUTFILE"

# # Clear caches before each run to pick up reads from disk
# sudo sync
# echo 3 | sudo tee /proc/sys/vm/drop_caches

# # start timing the workflow
# START_TIME=$(date +%s)

# /usr/bin/time -v "$@" 2>&1 | tee "$OUTFILE"

# # end timing the workflow
# END_TIME=$(date +%s)
# ELAPSED=$((END_TIME - START_TIME))

# # Append elapsed time to file
# echo "Elapsed time (s): $ELAPSED" >> "$OUTFILE"

# # Parse outfile and get read and write block counts
# # /usr/bin/time -v lines look like:
# #   File system inputs:  12345
# #   File system outputs: 67890
# READ_BLOCKS=$(
#   awk -F':' '/File system inputs/ {
#     gsub(/ /,"",$2);   # remove spaces
#     print $2
#   }' "$OUTFILE"
# )

# WRITE_BLOCKS=$(
#   awk -F':' '/File system outputs/ {
#     gsub(/ /,"",$2);   # remove spaces
#     print $2
#   }' "$OUTFILE"
# )

# # Convert 512-byte blocks to GB (GiB)
# READ_GB=$(echo "scale=2; $READ_BLOCKS * 512 / 1024 / 1024 / 1024" | bc)
# WRITE_GB=$(echo "scale=2; $WRITE_BLOCKS * 512 / 1024 / 1024 / 1024" | bc)

# echo "Total read volume (GB): $READ_GB"   >> "$OUTFILE"
# echo "Total write volume (GB): $WRITE_GB" >> "$OUTFILE"

# # Also print to stdout if you like:
# echo "Total read volume (GB): $READ_GB"
# echo "Total write volume (GB): $WRITE_GB"


#!/usr/bin/env bash
set -euo pipefail

# Accept optional "--"
if [[ "${1:-}" == "--" ]]; then
  shift
fi

# Now whatever remains is the command
if [[ $# -lt 1 ]]; then
  echo "usage: $0 [--] command [args...]" >&2
  exit 2
fi


# Require cgroup v2
[ -f /sys/fs/cgroup/cgroup.controllers ] || { echo "error: cgroup v2 not available" >&2; exit 1; }

CG="/sys/fs/cgroup/io_wrap.$$.$(date +%s)"

sudo mkdir -p "$CG"

# Best-effort enable io controller at the root (may already be enabled; ignore failures)
sudo bash -c 'grep -q "\bio\b" /sys/fs/cgroup/cgroup.subtree_control || echo +io >> /sys/fs/cgroup/cgroup.subtree_control' \
  >/dev/null 2>&1 || true

[ -f "$CG/io.stat" ] || { echo "error: $CG/io.stat not available (io controller not enabled/permitted)" >&2; exit 1; }

# Clear page cache before measuring I/O
sudo sync
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

before="$(sudo cat "$CG/io.stat")"

# Run workload inside the cgroup
sudo env \
  PATH="$PATH" \
  LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
  CONDA_PREFIX="$CONDA_PREFIX" \
  bash -c '
  cg="$1"; shift
  echo $$ > "$cg/cgroup.procs"
  exec "$@"
' -- "$CG" "$@"
rc=$?

after="$(sudo cat "$CG/io.stat")"

# Print totals (sum across devices)
awk -v B="$before" -v A="$after" '
function sum(txt,    i,n,f,rb,wb) {
  n=split(txt, lines, "\n")
  rb=wb=0
  for(i=1;i<=n;i++){
    split(lines[i], f, " ")
    for(j=2;j<=length(f);j++){
      if(f[j] ~ /^rbytes=/){ sub(/^rbytes=/,"",f[j]); rb += f[j] }
      else if(f[j] ~ /^wbytes=/){ sub(/^wbytes=/,"",f[j]); wb += f[j] }
    }
  }
  return rb SUBSEP wb
}
BEGIN{
  split(sum(B), b, SUBSEP)
  split(sum(A), a, SUBSEP)
  r=a[1]-b[1]; w=a[2]-b[2]
  if(r<0) r=0; if(w<0) w=0
  printf("read_bytes=%d write_bytes=%d read_GiB=%.3f write_GiB=%.3f\n",
         r, w, r/1024/1024/1024, w/1024/1024/1024)
}
'

sudo rmdir "$CG" >/dev/null 2>&1 || true
exit "$rc"
