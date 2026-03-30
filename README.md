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
- **OmniOS / illumos** (SunOS): tested on OmniOS r151052

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
2. **Measured Runs**: 8 runs for small sizes, 5 runs for 750MB.
3. **Trimmed Mean**: The best and worst results are discarded, and the final result is calculated from the remaining runs to provide a stable average.

## Benchmarked Results

Based on the 750MB run of dd.
Sample commands:
```
dd if=/dev/zero of="test_file.dat" bs=1M count=750 conv=fsync status=none
dd if="test_file.dat" of=/dev/null bs=1M count=750 status=none
```

| Machine                    | OS                              | RAM Local (W/R) [MB/s] | Disk Local (W/R) [MB/s] | RAM NFS (W/R) [MB/s] | Disk NFS (W/R) [MB/s] |
| :------------------------- | :-----------------------------: | :--------------------: | :---------------------: | :------------------: | :-------------------: |
| MacBook Air M1             | Darwin (23.6.0)                 |     4900 / 5200        |      1225 / 2470        |      970 / 365       |       485 / 190       |
| Dell (i5-11300H) (VM)      | Linux (6.12.74+deb13+1-amd64)   |     1040 / 3150        |      1860 / 2890        |      815 / 1428      |       697 / 1218      |
| Dell (i5-11300H) (VM)      | OmniOS (r151052)                |      433 / 418         |      3280 / 7264        |      N/A / N/A       |       N/A / N/A       |

### Discussion

1. On OmniOS (illumos), the "Local Disk" results (2590 MB/s Write / 5563 MB/s Read) completely dwarf the "RAM Disk" (334 MB/s). Why?
   * ZFS ARC vs. Legacy Ramdisk: OmniOS uses ZFS. ZFS uses the ARC (Adaptive Replacement Cache), which effectively treats almost all available system RAM as a high-speed cache.
     Writing to a ZFS "disk" means writing to an extremely optimized in-memory transaction group.
   * The Bottleneck: The RAM disk was created using the legacy ramdiskadm driver and UFS. This driver is often single-threaded or constrained by older kernel code paths.
   * Conclusion: On illumos, ZFS is a better "RAM disk" than an actual RAM disk. The 5.5 GB/s read speed proves you are reading directly from the ARC (RAM), not physical storage.

2. Read vs. Write: The "Read-Ahead" Advantage
   In almost every local test, Read is significantly faster than Write.
   * Write Overhead: Even with optimizations, writes require metadata updates (updating the journal or ZFS Uberblock), space allocation, and "blocking" calls to ensure the data is persisted.
   * Read Optimization: Modern kernels use Read-Ahead. When they detect a sequential read (like dd or fio do), the OS pre-fetches the next several megabytes into cache before the application even asks for
     them. This hides the latency of the storage media.

3. MacBook Air M1 Performance:
   The MacBook's RAM Local performance (~5.2 GB/s) is incredibly high.
   * Unified Memory Architecture: On Apple Silicon, the CPU and GPU share the same memory pool with extremely wide, high-bandwidth buses. The macOS hdiutil ramdisk is highly optimized to leverage this,
     resulting in throughput that nears the theoretical limits of the memory hardware.
   * The NFS "Tax": Notice the drop on the Mac from 5220 MB/s (Local) to 929 MB/s (NFS). This represents the "Network Protocol Tax"—the overhead of the TCP/IP stack, context switching between the
     application and the nfsd daemon, and the NFSv3 protocol's own management overhead.

4. Linux VM: The "Host Cache" Effect
   On the Linux VM, the Local Disk (1926 MB/s) actually outperformed the Guest's RAM Disk (1647 MB/s).
   * Double Caching: In a Virtual Machine, the "Local Disk" is usually just a file on the Host OS. Even if the cache is cleared/flushed inside the Linux VM (using drop_caches), the Host OS (Windows)
     likely still has that file in its RAM.
   * Result: We are not benchmarking the guest's disk, we are benchmarking the host's RAM speed through the hypervisor's virtio-blk driver.

## License

MIT
