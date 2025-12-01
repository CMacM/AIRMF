#!/usr/bin/env bash
set -euo pipefail

# peakflops.sh
# Run likwid-bench peak FLOPs benchmark with automatic topology detection.
# Arguments:
#   1) precision:  dp | sp
#   2) operation:  fma | madd
#   3) vector:     scalar | avx | avx512 | sse

usage() {
    echo "Usage: $0 <precision: dp|sp> <operation: fma|madd> <vector: scalar|avx|avx512|sse>" >&2
    echo "Example: $0 dp fma avx" >&2
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
    fma|madd) ;;
    *) echo "Error: operation must be fma or madd (got '$operation')." >&2; usage ;;
esac

case "$vector" in
    scalar|avx|avx512|sse) ;;
    *) echo "Error: vector must be scalar, avx, avx512, or sse (got '$vector')." >&2; usage ;;
esac

# Map to kernel name
if [[ "$precision" == "dp" ]]; then
    base="peakflops"
else
    base="peakflops_sp"
fi

kernel=""

if [[ "$operation" == "madd" ]]; then
    case "$vector" in
        scalar)
            kernel="$base"
            ;;
        avx|avx512|sse)
            kernel="${base}_${vector}"
            ;;
    esac
else  # operation == fma
    case "$vector" in
        avx|avx512)
            kernel="${base}_${vector}_fma"
            ;;
        scalar)
            echo "Scalar FMA not supported, falling back to ${precision} scalar madd benchmark." >&2
            kernel="$base"
            ;;
        sse)
            echo "SSE FMA not supported, falling back to ${precision} SSE madd benchmark." >&2
            if [[ "$precision" == "dp" ]]; then
                kernel="peakflops_sse"
            else
                kernel="peakflops_sp_sse"
            fi
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

# Choose working set size so that each HW thread gets ~20kB (fits into L1)
per_thread_kb=20
total_kb=$(( hwthreads * per_thread_kb ))
workset="${total_kb}kB"

echo "Detected topology: ${sockets} socket(s), ${cores_per_socket} core(s)/socket, ${threads_per_core} thread(s)/core."
echo "Using ${hwthreads} hardware thread(s) in total."
echo "Benchmark kernel: ${kernel} (precision=${precision}, op=${operation}, vector=${vector})"
echo "Total stream size: ${workset} (~${per_thread_kb}kB per thread)."
echo

# Run likwid-bench and capture output
bench_output=$(likwid-bench -t "$kernel" -W "N:${workset}:${hwthreads}" 2>&1)

# Print full original output
printf '%s\n' "$bench_output"

# Extract final MFlops/s value, taking the last value on the last matching line
mflops=$(printf '%s\n' "$bench_output" \
    | awk '/MFlops\/s/ {val=$NF} END { if (val != "") print val }')

# Convert to TFLOP/s for easier reading if large enough
if [[ -n "$mflops" ]]; then
    if (( $(echo "$mflops >= 1000000" | bc -l) )); then
        tflops=$(echo "scale=3; $mflops / 1000000" | bc -l)
        echo "Summary: Peak FLOP rate = ${tflops} TFlops/s"
        exit 0
    fi
fi

echo
if [[ -n "$mflops" ]]; then
    echo "Summary: Peak FLOP rate = ${mflops} MFlops/s"
else
    echo "Summary: Could not parse MFlops/s from likwid-bench output."
fi
