# Disk Write Profiling with fio

A portable storage benchmarking suite designed to measure and compare write throughput across various storage layers and configurations. This tool is particularly useful for identifying bottlenecks in local disk subsystems versus network-attached storage (NFS).

## Overview

The suite automates the setup, execution, and analysis of write benchmarks across:
- **Local RAM Disk**: Measures the maximum theoretical throughput of the system's memory and OS overhead.
- **Local Disk**: Measures the performance of the local physical storage.
- **NFS-mounted RAM Disk**: Isolates the performance impact of the NFS protocol by using a high-speed memory backend.
- **NFS-mounted Disk**: Measures the end-to-end performance of network-attached storage.

By comparing these results, the suite calculates performance factors to help determine if bottlenecks lie within the disk subsystem or the network protocol itself.

## Supported Operating Systems

- **macOS** (Darwin / Apple Silicon)
- **Linux** (various distributions)
- **FreeBSD**
- **OmniOS / illumos** (SunOS)

## Prerequisites

- **bash**: The scripts are written for the Bash shell.
- **fio**: The Flexible I/O Tester is the core benchmarking engine.
- **jq**: Used for parsing JSON output from `fio`.
- **sudo**: Required for setting up RAM disks and NFS exports.

The `run_full_benchmark.sh` script attempts to install these dependencies automatically using the system's package manager (Homebrew on macOS, apt/dnf/yum on Linux, pkg on FreeBSD/SunOS).

## Usage

### Fully Automated Run

The simplest way to run the entire suite is using the master orchestrator:

```bash
sudo ./run_full_benchmark.sh
```

This script will:
1. Detect your OS and install missing dependencies.
2. Create and mount a 2GB RAM disk.
3. Configure and start a local NFS server.
4. Mount loopback NFS shares for both the RAM disk and a local disk directory.
5. Execute the benchmark matrix (10MB, 100MB, 1000MB files).
6. Print a summary table and factor analysis.
7. Automatically clean up all temporary mounts, RAM disks, and configurations.

### Manual Components

- **`bench.sh <target_file> <size_mb>`**: Runs a single benchmark on a specific file and reports mean throughput and standard deviation. It handles OS-specific tweaks (e.g., disabling `O_DIRECT` on macOS APFS).
- **`bench_runner.sh <ramdir> <diskdir> <nfs_ram> <nfs_disk>`**: Runs the benchmark matrix if you have already manually set up the target directories.
- **`fio_write_bench.ini`**: The `fio` job configuration file defining the workload (sequential 1M writes, synchronous I/O).

## Project Structure

- `run_full_benchmark.sh`: Master setup and teardown script.
- `bench_runner.sh`: Benchmark matrix orchestrator.
- `bench.sh`: Core `fio` wrapper and statistics calculator.
- `fio_write_bench.ini`: Standardized `fio` workload definition.
- `.gitignore`: Ignore benchmark output.

## Benchmarked Results

*Comparison of performance across different operating systems and hardware.*

| OS    | Hardware                                                       | Local RAM | Local Disk | NFS RAM | NFS Disk | RAM/Disk Local | Disk Local/NFS | RAM/Disk NFS |
|:------|:---------------------------------------------------------------|:----------|:-----------|:--------|:---------|:---------------|:---------------|:-------------|
| macOS | MacBook Air (M1, 2020) \| M1 8-core \| 16GB \| Apple SSD 512GB | 6369.74   | 2314.48    | 191.73  | 194.12   | 2.75x          | 11.92x         | 0.99x        |

*Results are based on 1000MB file writes. All units are in MB/s except for Factors. Exact results will naturally differ from run to run, but have been verified to be consistent.*


## License

MIT
