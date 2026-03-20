#!/usr/bin/env bash

# ===============================================================
# bench_runner.sh
#
# Runs the full benchmark matrix and prints a summary table
#
# Usage:
#   bench_runner.sh <ramdir> <diskdir> <nfs_ram> <nfs_disk> <workload>
#
# Example:
#   ./bench_runner.sh /tmp/ramdisk /tmp/disk /mnt/nfs_ram /mnt/nfs_disk SEQ
# ===============================================================

set -e

RAMDIR="$1"
DISKDIR="$2"
NFS_RAM="$3"
NFS_DISK="$4"
WORKLOAD="${5:-SEQ}"

# Using identical sizes for both SEQ and RAND (1MB block size each)
# to isolate the Access Pattern variable.
SIZES=("10M" "100M" "1000M")
ANALYSIS_SIZE="1000M"

RESULTS_FILE="${TMPDIR:-/tmp}/bench_results.$$"
SKIPPED_FILE="${TMPDIR:-/tmp}/skipped_tests.$$"
touch "$RESULTS_FILE" "$SKIPPED_FILE"

echo
echo "==========================================="
echo " STORAGE BENCHMARK ($WORKLOAD)"
echo "==========================================="
echo

OS=$(uname -s)
echo "OS: $OS"
echo

# ------------------------------------------------
# run_single_test
# ------------------------------------------------

run_single_test() {

    LABEL="$1"
    PATHDIR="$2"
    SIZE="$3"
    # WORKLOAD is now global

    # Basic write check
    if [ ! -w "$PATHDIR" ]; then
        echo "Skipping $LABEL : $SIZE (Path not writable: $PATHDIR)"
        echo "$LABEL ($SIZE): Path not writable ($PATHDIR)" >> "$SKIPPED_FILE"
        return
    fi

    # Verification: Ensure the path is actually the type of mount we expect.
    case "$LABEL" in
        *NFS*)
            # Match 'nfs', 'nfs4', 'nfs3' etc. drop -w (whole-word) so
            # that NFSv4 mounts (type 'nfs4') are not falsely skipped.
            if ! mount | grep "$PATHDIR" | grep -i "nfs" >/dev/null 2>&1; then
                echo "Skipping $LABEL : $SIZE (Path is not an NFS mount: $PATHDIR)"
                echo "$LABEL ($SIZE): Not an NFS mount ($PATHDIR)" >> "$SKIPPED_FILE"
                return
            fi
            ;;
        RAM_LOCAL)
            OS=$(uname -s)
            if [ "$OS" = "Darwin" ]; then
                if ! mount | grep "$PATHDIR" | grep -iw "hfs" >/dev/null 2>&1; then
                   echo "Skipping $LABEL : $SIZE (Path is not on a RAM disk: $PATHDIR)"
                   echo "$LABEL ($SIZE): Not a RAM disk ($PATHDIR)" >> "$SKIPPED_FILE"
                   return
                fi
            elif [ "$OS" = "Linux" ]; then
                if ! mount | grep "$PATHDIR" | grep -iw "tmpfs" >/dev/null 2>&1; then
                   echo "Skipping $LABEL : $SIZE (Path is not on a RAM disk: $PATHDIR)"
                   echo "$LABEL ($SIZE): Not a RAM disk ($PATHDIR)" >> "$SKIPPED_FILE"
                   return
                fi
            fi
            ;;
    esac

    FILE="$PATHDIR/test_${SIZE}.dat"

    printf "Running %-12s [%4s] : %s... " "$LABEL" "$WORKLOAD" "$SIZE"

    OUTPUT=$(./bench.sh "$FILE" "$SIZE" "$WORKLOAD")
    rm -f "$FILE"

    # Parse throughput and stddev from bench.sh output
    THROUGHPUT=$(echo "$OUTPUT" | awk '/Mean throughput:/ {print $3}')
    STDDEV=$(echo "$OUTPUT" | awk '/Stddev:/ {print $2}')

    if [ -z "$THROUGHPUT" ]; then
        echo "Failed!"
        exit 1
    fi

    printf "Result: %8s MB/s (± %s MB/s)\n" "$THROUGHPUT" "$STDDEV"
    printf "%s,%s,%s,%s,%s\n" "$LABEL" "$WORKLOAD" "$SIZE" "$THROUGHPUT" "$STDDEV" >> "$RESULTS_FILE"
}

# ------------------------------------------------
# run all tests
# ------------------------------------------------

echo "Running benchmarks ($WORKLOAD)..."
echo

echo "Running local benchmarks..."
echo

for SIZE in "${SIZES[@]}"; do
    run_single_test "RAM_LOCAL" "$RAMDIR" "$SIZE"
    run_single_test "DISK_LOCAL" "$DISKDIR" "$SIZE"
done

echo
echo "Running NFS benchmarks..."
echo

for SIZE in "${SIZES[@]}"; do
    run_single_test "RAM_NFS" "$NFS_RAM" "$SIZE"
    run_single_test "DISK_NFS" "$NFS_DISK" "$SIZE"
done

echo
echo "==========================================="
echo " RESULTS TABLE ($WORKLOAD)"
echo "==========================================="
echo

printf "%-12s %-6s %-8s %-12s %-12s\n" "MODE" "TYPE" "SIZE" "MB_per_s" "STDDEV"
printf "%-12s %-6s %-8s %-12s %-12s\n" "------------" "------" "--------" "------------" "------------"

cat "$RESULTS_FILE" | while IFS=',' read MODE TYPE SIZE THR STD; do
    printf "%-12s %-6s %-8s %-12s %-12s\n" "$MODE" "$TYPE" "$SIZE" "$THR" "$STD"
done

echo
echo "==========================================="
echo " ANALYSIS ($WORKLOAD)"
echo "==========================================="
echo

RAM_LOCAL=$(awk -F',' -v s="$ANALYSIS_SIZE" '$1=="RAM_LOCAL" && $3==s {print $4}' "$RESULTS_FILE" || echo "")
DISK_LOCAL=$(awk -F',' -v s="$ANALYSIS_SIZE" '$1=="DISK_LOCAL" && $3==s {print $4}' "$RESULTS_FILE" || echo "")
RAM_NFS=$(awk -F',' -v s="$ANALYSIS_SIZE" '$1=="RAM_NFS" && $3==s {print $4}' "$RESULTS_FILE" || echo "")
DISK_NFS=$(awk -F',' -v s="$ANALYSIS_SIZE" '$1=="DISK_NFS" && $3==s {print $4}' "$RESULTS_FILE" || echo "")

echo "Using $ANALYSIS_SIZE tests for factor analysis:"
echo

[ -n "$RAM_LOCAL" ]  && echo "RAM local throughput:  $RAM_LOCAL MB/s"
[ -n "$DISK_LOCAL" ] && echo "Disk local throughput: $DISK_LOCAL MB/s"
[ -n "$RAM_NFS" ]    && echo "RAM NFS throughput:    $RAM_NFS MB/s"
[ -n "$DISK_NFS" ]   && echo "Disk NFS throughput:   $DISK_NFS MB/s"

echo

if [ -n "$RAM_LOCAL" ] && [ -n "$DISK_LOCAL" ]; then
    FACTOR=$(awk -v r="$RAM_LOCAL" -v d="$DISK_LOCAL" 'BEGIN {printf "%.2f", r/d}')
    echo "Factor: RAM is ${FACTOR}x faster than Local Disk."
fi

if [ -n "$DISK_LOCAL" ] && [ -n "$DISK_NFS" ]; then
    FACTOR=$(awk -v d="$DISK_LOCAL" -v n="$DISK_NFS" 'BEGIN {printf "%.2f", d/n}')
    echo "Factor: Local Disk is ${FACTOR}x faster than NFS."
fi

if [ -n "$RAM_NFS" ] && [ -n "$DISK_NFS" ]; then
    FACTOR=$(awk -v r="$RAM_NFS" -v d="$DISK_NFS" 'BEGIN {printf "%.2f", r/d}')
    echo "Factor: RAM NFS is ${FACTOR}x faster than Disk NFS."
    echo "Analysis: If this factor is close to 1.0, the NFS protocol is the bottleneck."
    echo "          If this factor is > 2.0, the Disk subsystem is the bottleneck."
fi

echo

if [ -s "$SKIPPED_FILE" ]; then
    echo "==========================================="
    echo " SKIPPED TESTS"
    echo "==========================================="
    cat "$SKIPPED_FILE"
    echo "==========================================="
    echo
fi

rm -f "$RESULTS_FILE" "$SKIPPED_FILE"
