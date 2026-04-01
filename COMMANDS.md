# Storage Benchmarking Command Sequences

This document outlines the expanded sequence of actual commands executed by the suite.

## Top-Level Execution
The following command initiates the sequential benchmark using `dd`:

```bash
# as root, or add "sudo -E" after &&
$ export BASE="$(pwd)/bench_workdir_run1" && ./run_sequential.sh dd 2>&1 | tee benchmark_output.txt
```

---

## Scenario 1: Linux RAM Disk Benchmarking

This section describes the commands executed on Linux, assuming the base directory is resolved to `/root/work/disk-write-profiling-fio/bench_workdir_run1`.

### 1. Environment & RAM Disk Setup
These commands prepare the isolated environment and the kernel-level RAM disk device.
```bash
# 1. Cleanup any previous artifacts
sudo umount /root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk 2>/dev/null
sudo rmmod brd 2>/dev/null
rm -rf /root/work/disk-write-profiling-fio/bench_workdir_run1

# 2. Create directory structure
mkdir -p /root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk

# 3. Initialize Linux RAM disk (900MB) with ext2 FS (no journaling)
# rd_size is in KB: 921600 KB = 900 MB (matching OmniOS ramdisk size for fair comparison)
sudo modprobe brd rd_nr=1 rd_size=921600
sudo mkfs.ext2 /dev/ram0
sudo mount /dev/ram0 /root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk
```

### 2. Execution Phase: RAM_LOCAL
For the **750M** size test:

#### **Part A: The Sequential Write (6 runs total - 1 warmup + 5 measured)**
The `bench.sh` script executes the write loop. The file is deleted before each write run.
```bash
# Executed 6 times
rm -f /root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk/test_750M.dat
dd if=/dev/zero of=/root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk/test_750M.dat bs=1M count=750 conv=fsync status=none
```

#### **Part B: One-Time Cache Purge Before Read Phase**
Executed by `bench_runner.sh` after all write runs complete and before switching to Read mode.
```bash
sync
sudo bash -c "echo 3 > /proc/sys/vm/drop_caches"
sudo umount /root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk
sudo mount /dev/ram0 /root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk
```

#### **Part C: The Sequential Read (6 runs total - 1 warmup + 5 measured)**
The `bench.sh` script executes the read loop. The cache is purged **before every single read run** (inside the loop) to ensure zero caching effects.
```bash
# Executed 6 times - each iteration performs:
# 1. Cache Purge (inside loop)
sync
sudo bash -c "echo 3 > /proc/sys/vm/drop_caches"
sudo umount /root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk
sudo mount /dev/ram0 /root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk

# 2. Actual Read
dd if=/root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk/test_750M.dat of=/dev/null bs=1M count=750 status=none
```
Note: The cache purge in Part C is repeated 6 times (once per iteration), not just once.

### 3. Cleanup & Teardown
Triggered automatically when the script exits to return the system to its original state.
```bash
sudo umount /root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk 2>/dev/null
sudo rmmod brd 2>/dev/null
sudo rm -rf /root/work/disk-write-profiling-fio/bench_workdir_run1
```

---

## Scenario 2: OmniOS (SunOS) RAM Disk Benchmarking

This section describes the commands executed on OmniOS, assuming the user runs with `pfexec` and the base directory is `/root/work/disk-write-profiling-fio/bench_workdir_run1`.
```bash
export BASE="$(pwd)/bench_workdir_run1" && pfexec ./run_sequential.sh dd 2>&1 | tee benchmark_output.txt
```

### 1. Environment & RAM Disk Setup
OmniOS uses `ramdiskadm` for memory storage and `newfs` (UFS) for the filesystem.
```bash
# 1. Cleanup any previous artifacts
pfexec umount /root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk 2>/dev/null
pfexec ramdiskadm -d benchram 2>/dev/null
rm -rf /root/work/disk-write-profiling-fio/bench_workdir_run1

# 2. Create directory structure
mkdir -p /root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk

# 3. Initialize OmniOS RAM disk (approx 900MB)
# ramdiskadm uses bytes; 943718400 = 900MB
pfexec ramdiskadm -a benchram 943718400
echo y | pfexec newfs /dev/ramdisk/benchram

# 4. Mount with 'nologging' to maximize performance and save RAM
pfexec mount -F ufs -o nologging /dev/ramdisk/benchram /root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk
```

### 2. Execution Phase: RAM_LOCAL
For the **750M** size test:

#### **Part A: The Sequential Write (6 runs total - 1 warmup + 5 measured)**
OmniOS `dd` does not support `1M` syntax or `conv=fsync`, so it uses bytes and a manual `sync`. The file is deleted before each write run.
```bash
# Executed 6 times
rm -f /root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk/test_750M.dat
dd if=/dev/zero of=/root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk/test_750M.dat bs=1048576 count=750
sync
```

#### **Part B: One-Time Cache Purge Before Read Phase**
OmniOS uses a remount trick to clear the buffer cache. This is executed once after all write runs complete and before switching to Read mode.
```bash
sync
pfexec umount /root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk
pfexec mount -F ufs -o nologging /dev/ramdisk/benchram /root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk
```

#### **Part C: The Sequential Read (6 runs total - 1 warmup + 5 measured)**
The `bench.sh` script executes the read loop. The cache is cleared **before every single read run** (inside the loop) to ensure zero-cached reads.
```bash
# Executed 6 times - each iteration performs:
# 1. Cache Purge (inside loop)
sync
pfexec umount /root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk
pfexec mount -F ufs -o nologging /dev/ramdisk/benchram /root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk

# 2. Actual Read
dd if=/root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk/test_750M.dat of=/dev/null bs=1048576 count=750
```
Note: The cache purge in Part C is repeated 6 times (once per iteration), not just once.

### 3. Cleanup & Teardown
```bash
pfexec umount /root/work/disk-write-profiling-fio/bench_workdir_run1/ramdisk 2>/dev/null
pfexec ramdiskadm -d benchram 2>/dev/null
rm -rf /root/work/disk-write-profiling-fio/bench_workdir_run1
```
