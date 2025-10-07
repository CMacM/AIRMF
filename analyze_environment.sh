#!/usr/bin/env bash
# system_probe.sh — simplified HW probe + benchmark availability report (TSV)
# Focus: Nvidia GPUs, Intel/AMD CPUs. Benchmarks only in TSV (no perf/nsight there).
set -euo pipefail

have() { command -v "$1" >/dev/null 2>&1; }
xargs_trim() { xargs 2>/dev/null || cat; }  # portable trim

BENCH_OUT="./benchmark_report.tsv"
if [[ "${1:-}" == "--bench-out" && -n "${2:-}" ]]; then
  BENCH_OUT="$2"
  shift 2
fi

echo "==================== SYSTEM DETECTION REPORT ===================="

# ---------------------------
# CPU (simple lscpu)
# ---------------------------
echo "CPU:"
if have lscpu; then
  cpu_vendor=$(lscpu | awk -F: '/Vendor ID/ {print $2}' | xargs_trim)
  cpu_model=$(lscpu | awk -F: '/Model name/ {print $2}' | xargs_trim)
  cpu_arch=$(lscpu | awk -F: '/Architecture/ {print $2}' | xargs_trim)
  cpu_sockets=$(lscpu | awk -F: '/Socket\(s\)/ {print $2}' | xargs_trim)
  cpu_cores_ps=$(lscpu | awk -F: '/Core\(s\) per socket/ {print $2}' | xargs_trim)
  cpu_threads=$(lscpu | awk -F: '/^CPU\(s\)/ {print $2}' | xargs_trim)
  echo "  Vendor       : $cpu_vendor"
  echo "  Model        : $cpu_model"
  echo "  Arch         : $cpu_arch"
  echo "  Sockets      : ${cpu_sockets:-unknown}"
  echo "  Cores/Socket : ${cpu_cores_ps:-unknown}"
  echo "  Threads      : ${cpu_threads:-unknown}"
else
  echo "  lscpu not found"
fi
echo

# ---------------------------
# GPU (NVIDIA only, via nvidia-smi)
# ---------------------------
echo "GPU:"
gpu_present=false
if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
  gpu_present=true
  gpu_count=$(nvidia-smi -L | wc -l | xargs_trim)
  driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | xargs_trim)
  echo "  Vendor       : NVIDIA"
  echo "  Count        : $gpu_count"
  echo "  Driver       : $driver_version"
  echo "  Devices      :"
  nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader \
    | awk -F, '{printf "    GPU %s : %s (Memory %s)\n", $1, $2, $3}'
else
  echo "  No NVIDIA GPU detected"
fi

# ---------------------------
# Perf (kept in human report only, not in benchmark TSV)
# ---------------------------
echo
echo "Perf:"
if have perf; then
  perf_version=$(perf --version 2>/dev/null | awk '{print $3}')
  echo "  Installed    : yes (v$perf_version)"
  if perf_list=$(timeout 6s perf list 2>/dev/null); then
    flop_events=()
    dram_events=()
    grep -q "fp_arith_inst_retired" <<<"$perf_list"     && flop_events+=("fp_arith_inst_retired")
    grep -q "fp_ret_sse_avx_ops.all" <<<"$perf_list"    && flop_events+=("fp_ret_sse_avx_ops.all")
    grep -q "cache" <<<"$perf_list"                     && dram_events+=("cache*")
    grep -q "L1-dcache" <<<"$perf_list"                 && dram_events+=("L1-dcache")

    if [[ ${#flop_events[@]} -gt 0 ]]; then
      echo "  FLOP ctrs    : available"; for ev in "${flop_events[@]}";  do echo "    - $ev"; done
    else
      echo "  FLOP ctrs    : not found"
    fi
    if [[ ${#dram_events[@]} -gt 0 ]]; then
      echo "  DRAM ctrs    : available"; for ev in "${dram_events[@]}"; do echo "    - $ev"; done
    else
      echo "  DRAM ctrs    : not found"
    fi
  else
    echo "  Note         : perf list failed (permissions?)"
  fi
else
  echo "  Installed    : no"
fi

# ---------------------------
# LIKWID (kept in human report only)
# ---------------------------
echo
echo "LIKWID:"
if have likwid-perfctr; then
  likwid_version=$(likwid-perfctr --version 2>/dev/null | awk '{print $4}')
  echo "  Installed    : yes (v$likwid_version)"
  if likwid_events=$(timeout 6s likwid-perfctr -a 2>/dev/null); then
    flop_avail="not found"; dram_avail="not found"
    echo "$likwid_events" | grep -q "FLOPS_DP" && flop_avail="FLOPS_DP"
    [[ "$flop_avail" == "not found" ]] && echo "$likwid_events" | grep -q "FLOPS_SP" && flop_avail="FLOPS_SP"
    echo "$likwid_events" | grep -q "MEM"      && dram_avail="MEM"
    [[ "$dram_avail" == "not found" ]] && echo "$likwid_events" | grep -q "CACHE" && dram_avail="CACHE"
    echo "  FLOP ctrs    : $flop_avail"
    echo "  DRAM ctrs    : $dram_avail"
  else
    echo "  Note         : likwid-perfctr -a failed (permissions?)"
  fi
else
  echo "  Installed    : no"
fi

# ---------------------------
# NVIDIA Nsight (kept in human report only)
# ---------------------------
echo
echo "NVIDIA Nsight Tools:"
if have nsys; then
  nsys_version=$(nsys --version 2>/dev/null | head -n1 | awk '{print $NF}')
  echo "  Nsight Systems : installed (v$nsys_version)"
else
  echo "  Nsight Systems : not installed"
fi
if have ncu; then
  ncu_version=$(ncu --version 2>/dev/null | awk '/Version/ {print $2}')
  echo "  Nsight Compute : installed (v$ncu_version)"
else
  echo "  Nsight Compute : not installed"
fi

echo "================================================================="
