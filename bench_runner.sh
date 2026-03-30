#!/usr/bin/env bash

# ===============================================================
# bench_runner.sh
#
# Runs the full benchmark matrix (WRITE & READ)
# ===============================================================

set -e

RAMDIR="$1"
export RAMDIR
DISKDIR="$2"
NFS_RAM="$3"
NFS_DISK="$4"
WORKLOAD="${5:-SEQ}"
TOOL="${6:-fio}"
TEST_MODE="${7:-}"

SIZES=("10M" "100M" "750M")
ANALYSIS_SIZE="750M"

RESULTS_FILE="${TMPDIR:-/tmp}/bench_results.$$"
SKIPPED_FILE="${TMPDIR:-/tmp}/skipped_tests.$$"
touch "$RESULTS_FILE" "$SKIPPED_FILE"

OS=$(uname -s)
OS_VER=$(uname -r)

# ------------------------------------------------
# Privilege handling
# ------------------------------------------------

is_root() {
    [ "$(id -u)" -eq 0 ]
}

have_sudo() {
    command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null
}

as_root() {
    if is_root; then
        "$@"
    elif have_sudo; then
        sudo "$@"
    else
        echo "ERROR: This operation requires root privileges: $*" >&2
        exit 1
    fi
}

[ "$WORKLOAD" = "RAND" ] && WORKLOAD_LABEL="(Random)" || WORKLOAD_LABEL="(Sequential)"

if [ "$OS" = "Darwin" ]; then
    HW_INFO=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model)
elif [ "$OS" = "Linux" ]; then
    HW_INFO=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^[ \t]*//' || echo "Unknown Linux")
else
    HW_INFO="Unknown"
fi

# ------------------------------------------------
# purge_cache
# ------------------------------------------------
purge_cache() {
    local TARGET_PATH="$1"
    if [ "$OS" = "Darwin" ]; then
        sync
        if ! purge 2>/dev/null; then
            as_root purge 2>/dev/null || true
        fi
        # Only remount if NOT an NFS path and RAMDIR is set
        if [[ "$TARGET_PATH" != *"nfs_"* ]] && [ -n "$RAMDIR" ] && mount | grep -q " on $RAMDIR "; then
            # Match exact mount point to avoid confusion with NFS sources
            DEV=$(mount | awk -v p="$RAMDIR" '$3 == p {print $1}')
            if [ -n "$DEV" ]; then
                as_root umount "$RAMDIR" 2>/dev/null \
                    && as_root mount -t hfs "$DEV" "$RAMDIR" 2>/dev/null || true
            fi
        fi
    elif [ "$OS" = "Linux" ]; then
        sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        # Only remount if NOT an NFS path and RAMDIR is set
        if [[ "$TARGET_PATH" != *"nfs_"* ]] && [ -n "$RAMDIR" ] && mount | grep -q " $RAMDIR "; then
            DEV=$(mount | awk -v p="$RAMDIR" '$3==p {print $1}')
            if [ -n "$DEV" ]; then
                as_root umount "$RAMDIR" 2>/dev/null \
                    && as_root mount "$DEV" "$RAMDIR" 2>/dev/null || true
            fi
        fi
    elif [ "$OS" = "SunOS" ]; then
        sync
        if mount | grep -q "$RAMDIR"; then
            DEV=$(mount | awk -v p="$RAMDIR" '$1 == p {print $3}')
            [ -z "$DEV" ] && DEV="/dev/ramdisk/benchram"
            
            as_root umount "$RAMDIR" 2>/dev/null \
                && as_root mount -F ufs -o nologging "$DEV" "$RAMDIR" 2>/dev/null || true
        fi
    fi
}

echo
echo "==========================================="
echo " STORAGE BENCHMARK $WORKLOAD_LABEL"
echo "==========================================="
echo "OS:       $OS ($OS_VER)"
echo "Hardware: $HW_INFO"
echo "Tool:     $TOOL"
echo

START_TIME_ALL=$(date +%s)

# ------------------------------------------------
# run_bench_pair
# ------------------------------------------------

run_bench_pair() {
    LABEL="$1"
    PATHDIR="$2"
    SIZE="$3"

    if [ ! -w "$PATHDIR" ]; then
        echo "Skipping $LABEL : $SIZE (Path not writable)"
        return
    fi

    # NFS check
    if [[ "$LABEL" == *"NFS"* ]]; then
        if [ "$OS" = "Darwin" ]; then
            mount | grep -E " on $PATHDIR \(nfs" >/dev/null || { echo "Skipping $LABEL: Not NFS"; return; }
        else
            mount | awk '{print $3, $5}' | grep -E "^$PATHDIR nfs" >/dev/null || { echo "Skipping $LABEL: Not NFS"; return; }
        fi
    fi

    FILE="$PATHDIR/test_${SIZE}.dat"

    printf "Benchmarking %-12s [%s]: Write... " "$LABEL" "$SIZE"

    # WRITE
    OUT_W="${TMPDIR:-/tmp}/bench_w.$$"
    if ! RAMDIR="$RAMDIR" ./bench.sh "$FILE" "$SIZE" "$WORKLOAD" "$TOOL" "WRITE" "$TEST_MODE" > "$OUT_W" 2>&1; then
        echo -e "\n[!] ERROR: Write test failed. Log output:"
        cat "$OUT_W"
        rm -f "$OUT_W"
        exit 1
    fi
    THR_W=$(awk '/^Mean throughput:/ {print $3}' "$OUT_W" | tail -n1)
    STD_W=$(awk '/^Stddev:/ {print $2}' "$OUT_W" | tail -n1)

    # CRITICAL: Purge cache before Read
    purge_cache "$PATHDIR"

    printf "Read... "

    # READ
    OUT_R="${TMPDIR:-/tmp}/bench_r.$$"
    if ! RAMDIR="$RAMDIR" ./bench.sh "$FILE" "$SIZE" "$WORKLOAD" "$TOOL" "READ" "$TEST_MODE" > "$OUT_R" 2>&1; then
        echo -e "\n[!] ERROR: Read test failed. Log output:"
        cat "$OUT_R"
        rm -f "$OUT_W" "$OUT_R"
        exit 1
    fi
    THR_R=$(awk '/^Mean throughput:/ {print $3}' "$OUT_R" | tail -n1)
    STD_R=$(awk '/^Stddev:/ {print $2}' "$OUT_R" | tail -n1)

    rm -f "$OUT_W" "$OUT_R"

    printf "Done.\n"
    # Format: LABEL,SIZE,THR_W,STD_W,THR_R,STD_R
    printf "%s,%s,%s,%s,%s,%s\n" "$LABEL" "$SIZE" "$THR_W" "$STD_W" "$THR_R" "$STD_R" >> "$RESULTS_FILE"

    # CRITICAL: Clean up the file to free space
    rm -f "$FILE"
}

echo "Running benchmarks..."
for SIZE in "${SIZES[@]}"; do
    run_bench_pair "RAM_LOCAL" "$RAMDIR" "$SIZE"
    run_bench_pair "DISK_LOCAL" "$DISKDIR" "$SIZE"
    run_bench_pair "RAM_NFS" "$NFS_RAM" "$SIZE"
    run_bench_pair "DISK_NFS" "$NFS_DISK" "$SIZE"
done

END_TIME_ALL=$(date +%s)
TOTAL_DURATION=$((END_TIME_ALL - START_TIME_ALL))

echo
echo "Total benchmark time: $((TOTAL_DURATION / 60))m $((TOTAL_DURATION % 60))s"
echo
echo "==========================================="
echo " RESULTS TABLE $WORKLOAD_LABEL - Tool: $TOOL"
echo "==========================================="
echo

# Precise header alignment
printf "%-12s %-8s %-12s %-12s %-12s %-12s\n" "MODE" "SIZE" "MB/s (W)" "STDEV (W)" "MB/s (R)" "STDEV (R)"
printf "%-12s %-8s %-12s %-12s %-12s %-12s\n" "------------" "--------" "------------" "------------" "------------" "------------"

tr -d '\r' < "$RESULTS_FILE" | while IFS=',' read L S TW SW TR SR; do
    printf "%-12s %-8s %-12s %-12s %-12s %-12s\n" "$L" "$S" "$TW" "$SW" "$TR" "$SR"
done

echo
echo "==========================================="
echo " ANALYSIS (Based on Write performance)"
echo "==========================================="
RAM_L=$(awk -F',' -v s="$ANALYSIS_SIZE" '$1=="RAM_LOCAL" && $2==s {print $3}' "$RESULTS_FILE")
DISK_L=$(awk -F',' -v s="$ANALYSIS_SIZE" '$1=="DISK_LOCAL" && $2==s {print $3}' "$RESULTS_FILE")
DISK_N=$(awk -F',' -v s="$ANALYSIS_SIZE" '$1=="DISK_NFS" && $2==s {print $3}' "$RESULTS_FILE")

[ -n "$RAM_L" ] && [ -n "$DISK_L" ] && echo "Factor: RAM is $(awk -v r="$RAM_L" -v d="$DISK_L" 'BEGIN {printf "%.2f", r/d}')x faster than Local Disk (Write)."
[ -n "$DISK_L" ] && [ -n "$DISK_N" ] && echo "Factor: Local Disk is $(awk -v d="$DISK_L" -v n="$DISK_N" 'BEGIN {printf "%.2f", d/n}')x faster than NFS (Write)."

rm -f "$RESULTS_FILE" "$SKIPPED_FILE"
