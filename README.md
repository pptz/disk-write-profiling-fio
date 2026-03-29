# Disk Write Profiling with `fio` and `dd`

A portable storage benchmarking suite designed to measure and compare write throughput across various storage layers and configurations. This tool is particularly useful for identifying bottlenecks in local disk subsystems versus network-attached storage (NFS).

## Overview

The suite automates the setup, execution, and analysis of write benchmarks across:
- **Local RAM Disk**: Measures the maximum theoretical throughput of the system's memory and OS overhead.
- **Local Disk**: Measures the performance of the local physical storage.
- **NFS-mounted RAM Disk**: Isolates the performance impact of the NFS protocol by using a high-speed memory backend.
- **NFS-mounted Disk**: Measures the end-to-end performance of network-attached storage.

Supports both **Sequential** and **Random** workloads using either **fio** or **dd**.

By comparing these results, the suite calculates performance factors to help determine if bottlenecks lie within the disk subsystem or the network protocol itself.

## Supported Operating Systems

- **macOS** (Darwin / Apple Silicon): tested on Sonoma 14.6.1
- **Linux** (various distributions): tested on Debian 13
- **FreeBSD**: not tested yet
- **OmniOS / illumos** (SunOS): not tested yet

## Prerequisites

- **bash**: The scripts are written for the Bash shell.
- **fio** (Optional): The Flexible I/O Tester. Required if choosing `fio` as the benchmark tool.
- **dd**: Available on all Unix-like systems. Used as an alternative to `fio`.
- **jq**: Used for parsing JSON output from `fio`.
- **sudo**: Required for setting up RAM disks and NFS exports.

## Usage

### Typical Way to Run

The recommended way to run the benchmark, ensuring a clean workspace and capturing all output, is:

```bash
export BASE="$(pwd)/bench_workdir_run1" && sudo -E ./run_sequential.sh fio 2>&1 | tee benchmark_output.txt
```

### High-Level Wrappers

The wrappers accept an optional tool argument (`fio` or `dd`) and an optional mode (`test` for a quick single-run debug):

```bash
# Run sequential benchmarks (defaulting to fio)
sudo ./run_sequential.sh [fio|dd] [test]

# Run random benchmarks (defaulting to fio)
sudo ./run_random.sh [fio|dd] [test]
```

### Automated Orchestrator

```bash
sudo ./run_full_benchmark.sh [SEQ|RAND] [fio|dd] [test]
```

## Benchmark Configuration

The suite uses **1MB blocks** for both sequential and random workloads to isolate the **Access Pattern** as the primary variable. The configuration is managed dynamically by the scripts to ensure optimal and accurate settings for each OS and tool.

*   **Sequential**: Writes or reads data in contiguous blocks.
*   **Random**: Writes or reads data at random offsets.

### Tool Parity (`fio` vs `dd`)
To ensure results are comparable:
- **fio**: Configured with `direct=1` (where supported) and `sync=1` for writes to ensure actual storage is benchmarked.
- **dd**: Implemented with a loop that performs an `fsync` after every 1MB block write, and uses `purge` between runs to bypass the OS Page Cache.

### Statistical Rigor
Every test point is measured multiple times (unless `test` mode is used):
1. **Warmup Run**: Discarded to account for filesystem metadata allocation and cache warmup.
2. **Measured Runs**: 8 runs for small sizes, 5 runs for 1000MB.
3. **Trimmed Mean**: The best and worst results are discarded, and the final result is calculated from the remaining runs to provide a stable average.

## Benchmarked Results

| Machine                    | OS                              | RAM Local (W/R) [MB/s] | Disk Local (W/R) [MB/s] | RAM NFS (W/R) [MB/s] | Disk NFS (W/R) [MB/s] |
| :------------------------- | :-----------------------------: | :--------------------: | :---------------------: | :------------------: | :-------------------: |
| MacBook Air M1             | Darwin (23.6.0)                 |     5220 / 5951        |      1225 / 2935        |      929 / 355       |       563 / 218       |
| Dell (i5-11300H) (VM)      | Linux (6.12.74+deb13+1-amd64)   |     1647 / 3273        |      1926 / 3129        |      815 / 1428      |       697 / 1218      |

## License

MIT
