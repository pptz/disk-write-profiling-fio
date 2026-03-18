#!/usr/bin/env bash

# ===============================================================
# bench.sh
#
# Portable fio benchmark runner
# Works on:
#   Linux
#   FreeBSD
#   OmniOS / illumos
#   macOS (Darwin / Apple Silicon)
#
# Usage:
#   ./bench.sh <target_file> <size_mb>
#
# Example:
#   ./bench.sh /tmp/testfile 100
# ===============================================================

set -e

TARGET_FILE="$1"
SIZE_MB="$2"

JOBFILE="fio_write_bench.ini"

if [ -z "$TARGET_FILE" ] || [ -z "$SIZE_MB" ]; then
    echo "Usage: $0 <target_file> <size_mb>" >&2
    exit 1
fi

if ! command -v fio >/dev/null 2>&1; then
    echo "fio not installed" >&2
    exit 1
fi

if [ ! -f "$JOBFILE" ]; then
    echo "Missing job file: $JOBFILE" >&2
    exit 1
fi

# ---------------------------------------------------------------
# Darwin / macOS: APFS does not support O_DIRECT, so direct=1
# from the job file would cause fio to abort.  Create a temporary
# copy of the job file with direct=0 for this run only.
# All other platforms use the original job file unchanged.
# ---------------------------------------------------------------

OS=$(uname -s)
EFFECTIVE_JOBFILE="$JOBFILE"

if [ "$OS" = "Darwin" ]; then
    EFFECTIVE_JOBFILE="${TMPDIR:-/tmp}/fio_write_bench_darwin.$$.ini"
    sed 's/^direct=1/direct=0/' "$JOBFILE" > "$EFFECTIVE_JOBFILE"
    # clean up the temp file on exit, regardless of success or failure
    trap 'rm -f "$EFFECTIVE_JOBFILE"' EXIT
fi

RUNS=9
WARMUP=1

RESULTS=()

echo "Benchmarking $TARGET_FILE (${SIZE_MB}MB)"
echo

for i in $(seq 1 $RUNS); do

    rm -f "$TARGET_FILE"

    echo "Run $i / $RUNS"

    JSON=$(fio "$EFFECTIVE_JOBFILE" \
        --filename="$TARGET_FILE" \
        --size="${SIZE_MB}M" \
        --output-format=json)

    # Extract write bandwidth from fio's JSON using jq.
    # The naive awk approach ('/"bw"/') matches the read.bw field first,
    # which is always 0 in a write-only job, producing 0.00 MB/s for every
    # run.  jq navigates directly to jobs[0].write.bw, which is in KB/s.
    BW=$(echo "$JSON" | jq '[.jobs[0].write.bw] | .[0]')

    # fio reports KB/s
    MBPS=$(awk -v bw="$BW" 'BEGIN {printf "%.2f", bw/1024}')

    # The first run is often slower due to filesystem metadata allocation,
    # kernel/VFS cache warmup, NFS connection overhead, and hardware state
    # state_changes. We discard it to measure steady-state performance.
    if [ "$i" -le "$WARMUP" ]; then
        echo "Warmup run: $MBPS MB/s"
        continue
    fi

    echo "Measured: $MBPS MB/s"

    RESULTS+=("$MBPS")

done

echo
echo "Calculating statistics..."

# Sort results and remove min/max
# We have 8 measured runs, we want to drop 1 min and 1 max to get 6.
SORTED_RESULTS=($(printf "%s\n" "${RESULTS[@]}" | sort -n))
# Drop first (min) and last (max)
RESULTS_TRIMMED=("${SORTED_RESULTS[@]:1:${#SORTED_RESULTS[@]}-2}")

COUNT=${#RESULTS_TRIMMED[@]}

SUM=0

for v in "${RESULTS_TRIMMED[@]}"; do
    SUM=$(awk -v a="$SUM" -v b="$v" 'BEGIN{print a+b}')
done

MEAN=$(awk -v sum="$SUM" -v n="$COUNT" 'BEGIN{printf "%.2f", sum/n}')

VAR=0

for v in "${RESULTS_TRIMMED[@]}"; do
    DIFF=$(awk -v v="$v" -v m="$MEAN" 'BEGIN{print v-m}')
    SQ=$(awk -v d="$DIFF" 'BEGIN{print d*d}')
    VAR=$(awk -v a="$VAR" -v b="$SQ" 'BEGIN{print a+b}')
done

STDDEV=$(awk -v v="$VAR" -v n="$COUNT" 'BEGIN{printf "%.2f", sqrt(v/n)}')

echo
echo "------------------------------------------------"
echo "Runs used (trimmed): $COUNT"
echo "Mean throughput:     $MEAN MB/s"
echo "Stddev:              $STDDEV MB/s"
echo "------------------------------------------------"
