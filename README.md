# Disk Write Profiling with `fio`

A portable storage benchmarking suite designed to measure and compare write throughput across various storage layers and configurations. This tool is particularly useful for identifying bottlenecks in local disk subsystems versus network-attached storage (NFS).

## Overview

The suite automates the setup, execution, and analysis of write benchmarks across:
- **Local RAM Disk**: Measures the maximum theoretical throughput of the system's memory and OS overhead.
- **Local Disk**: Measures the performance of the local physical storage.
- **NFS-mounted RAM Disk**: Isolates the performance impact of the NFS protocol by using a high-speed memory backend.
- **NFS-mounted Disk**: Measures the end-to-end performance of network-attached storage.

By comparing these results, the suite calculates performance factors to help determine if bottlenecks lie within the disk subsystem or the network protocol itself.

## Supported Operating Systems

- **macOS** (Darwin / Apple Silicon): tested on Sonoma 14.6.1
- **Linux** (various distributions): tested on Debian 13
- **FreeBSD**: not tested yet
- **OmniOS / illumos** (SunOS): not tested yet

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

## Benchmark Configuration

The benchmark uses sequential 1MB writes with a single job to measure raw throughput while minimizing latency effects from random seeks. To ensure results represent actual storage performance rather than OS page cache speeds, the configuration employs several strict synchronization flags:

*   **`sync=1` (O_SYNC)**: Forces each write syscall to block until the data is committed to the filesystem. This is particularly critical on macOS, where `O_DIRECT` is not supported on APFS/HFS+ volumes.
*   **`direct=1`**: Bypasses the page cache on Linux, FreeBSD, and illumos.
*   **`fsync_on_close=1` and `end_fsync=1`**: Ensures that all writeback is flushed and the full cost of draining the write queue is captured in the recorded time.
*   **`buffer_pattern=0xdeadbeef`**: Uses a fixed, non-compressible pattern to prevent hardware or filesystem-level compression from inflating throughput numbers.

## Project Structure

- `run_full_benchmark.sh`: Master setup and teardown script.
- `bench_runner.sh`: Benchmark matrix orchestrator.
- `bench.sh`: Core `fio` wrapper and statistics calculator.
- `fio_write_bench.ini`: Standardized `fio` workload definition.
- `.gitignore`: Ignore benchmark output.

## Benchmarked Results

*Comparison of performance across different operating systems and hardware.*

*Results are based on 1000MB file writes. All units are in MB/s except for Factors. Exact results will naturally differ from run to run, but the numbers have been verified to be representative and largely consistent.*

| OS                  | Hardware                                                       | Local RAM | Local Disk | NFS RAM | NFS Disk | RAM/Disk Local | Disk Local/NFS | RAM/Disk NFS |
|:--------------------|:---------------------------------------------------------------|:----------|:-----------|:--------|:---------|:---------------|:---------------|:-------------|
| macOS Sonoma 14.6.1 | MacBook Air (M1, 2020) \| M1 8-core \| 16GB \| Apple SSD 512GB | 6369.74   | 2314.48    | 191.73* | 194.12   | 2.75x          | 11.92x         | 0.99x        |
| Debian 13           | Vultr VPS \| 8GB (shared vCPU, cloud block storage)            | 7078.31   | 155.23     | 3541.14 | 145.35   | 45.60x         | 1.07x          | 24.36x       |

\* Results (low) suggest that Mac probably used a physical network interface, not the loopback

### Other
- The first run of every (10/100/1000MB) write is significantly slower than subsequent runs due to filesystem overhead
- Writing 10MB to local RAM shows practically 0 STD. We assume this write is a CPU-only operation, not involving any physical memory. L2/L3 CPU cache is likely larger than 10MB.
- Throughput consistently incereases with the amount of data transferred, suggesting that a set-up penalty is incurred.

## License

MIT
