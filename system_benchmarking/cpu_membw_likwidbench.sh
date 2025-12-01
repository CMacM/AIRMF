#!/usr/bin/env bash
set -euo pipefail

# stream_bw.sh
# Run likwid-bench STREAM triad bandwidth benchmark with automatic topology detection.
# Arguments:
#   1) precision:  dp | sp
#   2) operation:  triad | fma
#   3) vector:     scalar | sse | avx | avx512
#
# Kernels used (roofline-relevant only, no non-temporal *_mem variants):
#   Double precision:
#     stream              (scalar triad)
#     stream_sse
#     stream_avx
#     stream_avx512
#     stream_sse_fma
#     stream_avx_fma
#     stream_avx512_fma
#   Single precision:
#     stream_sp           (scalar triad)
#     stream_sp_sse
#     stream_sp_avx
#     stream_sp_avx512
#     stream_sp_sse_fma
#     stream_sp_avx_fma
#     stream_sp_avx512_fma

usage() {
    echo "Usage: $0 <precision: dp|sp> <operation: triad|fma> <vector: scalar|sse|avx|avx512>" >&2
    echo "Example: $0 dp triad avx" >&2
    echo "         $0 dp fma avx512" >&2
    exit 1
}

if [[ $# -ne 3 ]]; then
    usage
fi

if ! command -v likwid-bench >/dev/null 2>&1; then
    echo "Error: likwid-bench not found in PATH." >&2
    exit 1
fi

if ! command -v likwid-topology >/dev/null 2>&1; then
    echo "Error: likwid-topology not found in PATH." >&2
    exit 1
fi

if ! command -v nproc >/dev/null 2>&1; then
    echo "Error: nproc not found (needed for fallback topology)." >&2
    exit 1
fi

precision=$(echo "$1" | tr '[:upper:]' '[:lower:]')
operation=$(echo "$2" | tr '[:upper:]' '[:lower:]')
vector=$(echo "$3" | tr '[:upper:]' '[:lower:]')

# Validate arguments
case "$precision" in
    dp|sp) ;;
    *) echo "Error: precision must be dp or sp (got '$precision')." >&2; usage ;;
esac

case "$operation" in
    triad|fma) ;;
    *) echo "Error: operation must be triad or fma (got '$operation')." >&2; usage ;;
esac

case "$vector" in
    scalar|sse|avx|avx512) ;;
    *) echo "Error: vector must be scalar, sse, avx, or avx512 (got '$vector')." >&2; usage ;;
esac

# Map to kernel name
if [[ "$precision" == "dp" ]]; then
    base="stream"
else
    base="stream_sp"
fi

kernel=""

if [[ "$operation" == "triad" ]]; then
    case "$vector" in
        scalar)
            kernel="$base"
            ;;
        sse|avx|avx512)
            kernel="${base}_${vector}"
            ;;
    esac
else  # operation == fma
    case "$vector" in
        scalar)
            echo "Scalar FMA STREAM triad not available; falling back to scalar triad kernel." >&2
            kernel="$base"
            ;;
        sse|avx|avx512)
            kernel="${base}_${vector}_fma"
            ;;
    esac
fi

if [[ -z "$kernel" ]]; then
    echo "Internal error: kernel not resolved (precision=$precision, operation=$operation, vector=$vector)." >&2
    exit 1
fi

# Detect topology from likwid-topology
topo_out=$(likwid-topology)

get_field() {
    local pattern="$1"
    awk -F':' -v pat="$pattern" '
        $1 ~ pat {
            gsub(/^[ \t]+/, "", $2);
            print $2;
            exit
        }' <<< "$topo_out"
}

sockets=$(get_field "Sockets")
cores_per_socket=$(get_field "Cores per socket")
threads_per_core=$(get_field "Threads per core")

# Fallbacks if parsing failed
if [[ -z "${sockets:-}" || -z "${cores_per_socket:-}" || -z "${threads_per_core:-}" ]]; then
    echo "Warning: could not fully parse likwid-topology output; falling back to nproc." >&2
    sockets=1
    cores_per_socket=$(nproc)
    threads_per_core=1
fi

if ! [[ "$sockets" =~ ^[0-9]+$ && "$cores_per_socket" =~ ^[0-9]+$ && "$threads_per_core" =~ ^[0-9]+$ ]]; then
    echo "Error: non-integer topology values detected (Sockets=$sockets, Cores/socket=$cores_per_socket, Threads/core=$threads_per_core)." >&2
    exit 1
fi

hwthreads=$(( sockets * cores_per_socket * threads_per_core ))

if (( hwthreads <= 0 )); then
    echo "Error: computed non-positive number of hardware threads: $hwthreads" >&2
    exit 1
fi

# Choose working set size: ~32 MB per HW thread, capped at 8 GB total.
# This should be large enough to hit DRAM for roofline purposes.
per_thread_mb=32
total_mb=$(( hwthreads * per_thread_mb ))

max_total_mb=$(( 8 * 1024 ))  # 8 GB in MB
if (( total_mb > max_total_mb )); then
    total_mb=$max_total_mb
fi

if (( total_mb <= 0 )); then
    echo "Error: computed non-positive total working set size: ${total_mb}MB" >&2
    exit 1
fi

workset="${total_mb}MB"

echo "Detected topology: ${sockets} socket(s), ${cores_per_socket} core(s)/socket, ${threads_per_core} thread(s)/core."
echo "Using ${hwthreads} hardware thread(s) in total."
echo "Benchmark kernel: ${kernel} (precision=${precision}, op=${operation}, vector=${vector})"
echo "Total stream size: ${workset} (~${per_thread_mb}MB per thread, capped at 8GB total)."
echo

# Run likwid-bench and capture output
bench_output=$(likwid-bench -t triad -W "N:${workset}:${hwthreads}" 2>&1)

# Print full original output
printf '%s\n' "$bench_output"

# Extract final MByte/s value (last value on the last matching line)
bw_mbytes=$(printf '%s\n' "$bench_output" \
    | awk '/MByte\/s/ {val=$NF} END { if (val != "") print val }')

# Convert to GB/s for easier reading if large enough
if [[ -n "$bw_mbytes" ]]; then
    if (( $(echo "$bw_mbytes >= 10000" | bc -l) )); then
        bw_gbytes=$(echo "scale=3; $bw_mbytes / 1024" | bc -l)
        echo "Summary: Peak STREAM bandwidth = ${bw_gbytes} GByte/s"
        exit 0
    fi
fi

echo
if [[ -n "$bw_mbytes" ]]; then
    echo "Summary: Peak STREAM bandwidth = ${bw_mbytes} MByte/s"
else
    echo "Summary: Could not parse MByte/s from likwid-bench output."
fi
