# Disk Write Profiling with `fio` and `dd`

A portable storage benchmarking suite designed to measure and compare write throughput across various storage layers and configurations. This tool is particularly useful for identifying bottlenecks in local disk subsystems versus network-attached storage (NFS).

## Overview

The suite automates the setup, execution, and analysis of write benchmarks across:
- **Local RAM Disk**: Measures the maximum theoretical throughput of the system's memory and OS overhead.
- **Local Disk**: Measures the performance of the local physical storage.
- **NFS-mounted RAM Disk**: Isolates the performance impact of the NFS protocol by using a high-speed memory backend.
- **NFS-mounted Disk**: Measures the end-to-end performance of network-attached storage.

Supports both **Sequential** and **Random** write workloads using either **fio** or **dd**.

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

The wrappers accept an optional tool argument (`fio` or `dd`):

```bash
# Run sequential benchmarks (defaulting to fio)
sudo ./run_sequential.sh [fio|dd]

# Run random benchmarks (defaulting to fio)
sudo ./run_random.sh [fio|dd]
```

### Automated Orchestrator

The wrappers call the master orchestrator with workload and tool arguments:

```bash
sudo ./run_full_benchmark.sh [SEQ|RAND] [fio|dd]
```

## Benchmark Configuration

The suite uses **1MB blocks** for both sequential and random workloads to isolate the **Access Pattern** as the primary variable.

*   **Sequential**: Writes data in contiguous blocks.
*   **Random**: Writes data to random offsets within the file.

### Tool Parity (`fio` vs `dd`)
To ensure results are comparable:
- **fio**: Configured with `sync=1` (O_SYNC) and `fsync_on_close=1` to ensure every block is committed to storage.
- **dd**: Implemented with a loop that performs an `fsync` (or `fdatasync`) after every 1MB block write, preventing OS page cache inflation of results.

### Statistical Rigor
Every test point is measured multiple times:
1. **Warmup Run**: Discarded to account for filesystem metadata allocation and cache warmup.
2. **Measured Runs**: 8 runs for small sizes, 5 runs for 1000MB.
3. **Trimmed Mean**: The best and worst results are discarded, and the final result is calculated from the remaining runs to provide a stable average.

## Benchmarked Results

*Comparison of performance across different operating systems and hardware. Results below use **numjobs=4** and reflect throughput in **MB/s**.*

| OS        | Workload | Hardware      | Local RAM | Local Disk | NFS RAM | NFS Disk | RAM/Disk | Local/NFS | NFS Gain |
| :---------| :--------| :-------------| ---------:| ----------:| -------:| --------:| --------:| ---------:| --------:|
| **macOS** | SEQ      | MBA M1 (16GB) | 10,733.7  | 3,614.7    | 162.4   | 132.8    | 2.97x    | 27.22x    | 1.22x    |
| **macOS** | RAND     | MBA M1 (16GB) | 9,426.6   | 3,042.4    | 164.8   | 130.1    | 3.10x    | 23.39x    | 1.27x    |
| **Debian**| SEQ      | Vultr (8GB)   | 7,078.3   | 155.2      | 3,541.1 | 145.4    | 45.60x   | 1.07x     | 24.36x   |

*Note: "NFS Gain" is the ratio of RAM-NFS over Disk-NFS. A factor near 1.0x indicates the network protocol is the total bottleneck.*

## Key Observations (macOS)

### 1. The NFS Bottleneck & Lack of Parallelism
On macOS, the built-in **`nfsd`** (running **NFSv3**) acts as a rigid throughput ceiling.
- **The "Steel Ceiling"**: Throughput caps at ~130-160 MB/s regardless of whether the backend is a 10GB/s RAM disk or a 3GB/s SSD.
- **No Scaling**: Increasing parallelism (`numjobs=4`) does **not** increase NFS throughput; in fact, it often causes a slight drop due to lock contention in the kernel's NFS stack. This suggests that macOS NFS is effectively non-parallel for local loopback workloads.

### 2. Block Size vs. Access Pattern
When using large **1MB blocks**, the difference between Sequential and Random access is negligible (less than 10%). This indicates that for modern SSDs and RAM disks, the overhead of seeking to a new 1MB-aligned location is insignificant compared to the data transfer time. The "Random I/O penalty" typically observed with 4KB blocks disappears at this scale.

### 3. Local Hardware Scaling
Unlike NFS, local storage scales significantly with parallelism. By moving from 1 to 4 jobs, the RAM disk throughput nearly doubled (saturating the SoC memory bandwidth at ~10GB/s), and the SSD throughput increased by ~50%, proving the hardware has significant untapped potential for multi-threaded applications.

## License

MIT
