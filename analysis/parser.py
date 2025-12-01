import pandas as pd
import os
import re
from pathlib import Path
from glob import glob
import argparse

metrics = [
    'smsp__sass_thread_inst_executed_op_hadd_pred_on.sum',
    'smsp__sass_thread_inst_executed_op_hmul_pred_on.sum',
    'smsp__sass_thread_inst_executed_op_hfma_pred_on.sum',
    'smsp__sass_thread_inst_executed_op_ffma_pred_on.sum',
    'smsp__sass_thread_inst_executed_op_fmul_pred_on.sum',
    'smsp__sass_thread_inst_executed_op_fadd_pred_on.sum',
    'smsp__sass_thread_inst_executed_op_dfma_pred_on.sum',
    'smsp__sass_thread_inst_executed_op_dmul_pred_on.sum',
    'smsp__sass_thread_inst_executed_op_dadd_pred_on.sum',
    'sm__ops_path_tensor_src_tf32_dst_fp32.sum',
    'dram__bytes.sum',
    'pcie__read_bytes.sum',
    'pcie__write_bytes.sum',
]

metrics_rename = [
    'f16_add_TFLOP',
    'f16_mul_TFLOP',
    'f16_fma_TFLOP',
    'f32_fma_TFLOP',
    'f32_mul_TFLOP',
    'f32_add_TFLOP',
    'f64_fma_TFLOP',
    'f64_mul_TFLOP',
    'f64_add_TFLOP',
    'tensor_tf32_TFLOP',
    'dram_Gbytes',
    'pcie_read_Gbytes',
    'pcie_write_Gbytes',
]

def parse_ncu(rep_files):

    # Parse each file and store the data in a list of DataFrames
    dfs = []
    for f in rep_files:
        try:
            df = pd.read_csv(f, low_memory=False)

            # Check if required metrics are present
            for metric in metrics:
                if metric not in df.columns:
                    print(f"WARNING: Metric {metric} not found in file {f}")
            found_metrics = [metric for metric in metrics if metric in df.columns]

            df = df[found_metrics]
            dfs.append(df)
        except pd.errors.EmptyDataError:
            print(f"Warning: File {f} is empty.")

    convert_to_bytes = {
        'byte': 1,
        'Kbyte': 1024,
        'Mbyte': 1024 ** 2,
        'Gbyte': 1024 ** 3,
        'Tbyte': 1024 ** 4,
    }

    results = pd.DataFrame()
    for i, df in enumerate(dfs):
        # Add report file name as first column
        results.at[i, 'report_file'] = os.path.basename(rep_files[i])

        for metric in df.columns:
            value = pd.to_numeric(df[metric], errors='coerce').sum()
            if "fma" in metric:
                value *= 2
                # Convert to TFLOP
                value /= 1e12
            elif "bytes" in metric:
                unit = df[metric].values[0]
                if unit in convert_to_bytes:
                    value *= convert_to_bytes[unit]
                    # Convert to GB
                    value /= convert_to_bytes['Gbyte']
            else:
                # Convert to TFLOP
                value /= 1e12
            # add to results
            idx = metrics.index(metric)
            results.at[i, metrics_rename[idx]] = value

    return results

def parse_likwid(rep_files, fma_frac):

    lane_map = {
        ("SCALAR_SINGLE"): 1,
        ("128B_PACKED_SINGLE"): 4,
        ("256B_PACKED_SINGLE"): 8,
        ("512B_PACKED_SINGLE"): 16,
        ("SCALAR_DOUBLE"): 1,
        ("128B_PACKED_DOUBLE"): 2,
        ("256B_PACKED_DOUBLE"): 4,
        ("512B_PACKED_DOUBLE"): 8,
    }

    fp_event_re = re.compile(
        r"^FP_ARITH_INST_RETIRED_(SCALAR|\d+B_PACKED)_(SINGLE|DOUBLE)$"
    )

    results = pd.DataFrame()
    for i, rep_file in enumerate(rep_files):

        # Add report file names as first column
        results.at[i, 'report_file'] = os.path.basename(rep_file)

        text = Path(rep_file).read_text()
        lines = text.splitlines()

        # Parse FP and Memory events
        for line in lines:
            # STAT lines look like:
            # FP_ARITH_INST_RETIRED_128B_PACKED_SINGLE STAT
            if line.startswith("FP_ARITH_INST_RETIRED") and "STAT" in line:
                # split by comma
                parts = re.split(r"[,]+", line.strip())
                event_name = parts[0]
                # remove "FP_ARITH_INST_RETIRED_" prefix and " STAT" suffix
                width_precision = event_name.replace("FP_ARITH_INST_RETIRED_", "")
                width_precision = width_precision.replace(" STAT", "")
                # get width and precision from match groups
                lanes = lane_map.get(width_precision)
                # Multiply by number of lanes and FMA fraction
                sum_value = int(parts[2]) * lanes * (1 + fma_frac)
                # Convert to TFLOP
                sum_value /= 1e12
                
                # add results to new row in dataframe
                results.at[i, event_name] = sum_value

            elif line.startswith("Memory data volume") and "STAT" in line:
                # split by comma
                parts = re.split(r"[,]+", line.strip())
                # Example line:
                # Memory Data Volume [GBytes] STAT, 123456
                # Extract unit
                event_name = parts[0]
                sum_value = parts[1]

                results.at[i, event_name] = float(sum_value)

    return  results

def parse_time():
    return

def main(args):
    
    ncu_reps = glob(os.path.join(args.ncu_path, '*.csv'))

    ncu_results = parse_ncu(ncu_reps)

    # Save results to CSV
    ncu_results.to_csv("ncu_rep_summary.csv", index=False)

    likwid_reps = glob(os.path.join(args.likwid_path, '*.csv'))

    likwid_results = parse_likwid(likwid_reps, args.fma_frac)

    # Save results to CSV
    likwid_results.to_csv("likwid_rep_summary.csv", index=False)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Parse performance reports.")
    parser.add_argument('--ncu_path', type=str, required=True, help='Path to NCU report CSV files.')
    parser.add_argument('--likwid_path', type=str, required=True, help='Path to Likwid report CSV files.')
    parser.add_argument('--fma_frac', type=float, default=1.0, help='Fraction of FMA instructions.')
    args = parser.parse_args()
    main(args)

