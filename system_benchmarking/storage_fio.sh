#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage: storage_bw --mode MODE --size SIZE --bs BS --jobs N

  --mode MODE      read | write
                   Mode 'write' measures sequential write bandwidth.
                   Mode 'read' pre-fills files and then measures sequential read bandwidth.
  --size SIZE      File size *per task*, e.g. 1G, 512M, 4G.
  --bs BS          Block size, e.g. 4k, 128k, 1M.
  --jobs N         Number of parallel tasks (fio numjobs).
  -h, --help       Show this help.

Notes:
  - Files are created in the current working directory.
  - Temporary benchmark files are removed after the run.
  - SIZE is per job: with --jobs N, total I/O is approximately N * SIZE.

Examples:
  # 4 parallel writers, each writing 2G, 1M blocks
  fs_bw_fio --mode write --size 2G --bs 1M --jobs 4

  # 8 parallel readers on 1G files, 128k blocks
  fs_bw_fio --mode read --size 1G --bs 128k --jobs 8
EOF
}

MODE=""
FILESIZE=""
BLOCKSIZE=""
NUMJOBS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"; shift 2 ;;
    --size)
      FILESIZE="${2:-}"; shift 2 ;;
    --bs)
      BLOCKSIZE="${2:-}"; shift 2 ;;
    --jobs)
      NUMJOBS="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "storage_bw: unknown argument: $1" >&2
      usage
      exit 2 ;;
  esac
done

# Basic validation
if [[ -z "$MODE" || -z "$FILESIZE" || -z "$BLOCKSIZE" || -z "$NUMJOBS" ]]; then
  echo "storage_bw: --mode, --size, --bs and --jobs are required" >&2
  usage
  exit 2
fi

case "$MODE" in
  read|write) ;;
  *)
    echo "storage_bw: --mode must be 'read' or 'write', got '$MODE'" >&2
    exit 2 ;;
esac

if ! [[ "$NUMJOBS" =~ ^[0-9]+$ ]] || [[ "$NUMJOBS" -le 0 ]]; then
  echo "storage_bw: --jobs must be a positive integer, got '$NUMJOBS'" >&2
  exit 2
fi

if ! command -v fio >/dev/null 2>&1; then
  echo "storage_bw: 'fio' not found in PATH; please install fio." >&2
  exit 1
fi

TARGET_DIR="$PWD"
FILE_PREFIX="fio_fsbench_file"
JOB_NAME="fs_bw_${MODE}_${BLOCKSIZE}_${NUMJOBS}jobs"

cleanup() {
  rm -f "${TARGET_DIR}/${FILE_PREFIX}."* 2>/dev/null || true
}
trap cleanup EXIT

echo ">>> Filesystem bandwidth benchmark (fio)"
echo "    Mode       : $MODE"
echo "    File size  : $FILESIZE per job"
echo "    Block size : $BLOCKSIZE"
echo "    Jobs       : $NUMJOBS"
echo "    Directory  : $TARGET_DIR"
echo

FIO_COMMON=(
  --name="$JOB_NAME"
  --directory="$TARGET_DIR"
  --filename_format="${FILE_PREFIX}.\$jobnum"
  --ioengine=psync
  --direct=1
  --bs="$BLOCKSIZE"
  --size="$FILESIZE"
  --numjobs="$NUMJOBS"
  --group_reporting=1
)

if [[ "$MODE" == "write" ]]; then
  echo ">>> Running sequential write bandwidth benchmark..."
  fio "${FIO_COMMON[@]}" --rw=write

else
  echo ">>> Running sequential read bandwidth benchmark..."
  fio "${FIO_COMMON[@]}" --rw=read 
fi

echo ">>> FIO filesystem bandwidth benchmark complete."
rm -f "${TARGET_DIR}/${FILE_PREFIX}."* 2>/dev/null || true
