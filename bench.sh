#!/usr/bin/env bash

# ===============================================================
# bench.sh
#
# Portable fio benchmark runner (SSH-friendly)
# Works on:
#   Linux
#   FreeBSD
#   OmniOS / illumos
#   macOS (Darwin / Apple Silicon)
#
# Usage:
#   ./bench.sh <target_file> <size_mb> [SEQ|RAND]
#
# Example:
#   ./bench.sh /tmp/testfile 100 SEQ
# ===============================================================

set -e

TARGET_FILE="$1"
SIZE_STR="$2"
WORKLOAD="${3:-SEQ}"

if [ -z "$TARGET_FILE" ] || [ -z "$SIZE_STR" ]; then
    echo "Usage: $0 <target_file> <size> [SEQ|RAND]" >&2
    exit 1
fi

if ! command -v fio >/dev/null 2>&1; then
    echo "fio not installed" >&2
    exit 1
fi

# Select job file
if [ "$WORKLOAD" = "RAND" ]; then
    JOBFILE="fio_random_bench.ini"
else
    JOBFILE="fio_sequential_bench.ini"
fi

if [ ! -f "$JOBFILE" ]; then
    echo "Missing job file: $JOBFILE" >&2
    exit 1
fi

# ---------------------------------------------------------------
# Darwin / macOS: APFS does not support O_DIRECT, so direct=1
# from the job file would cause fio to abort.
# ---------------------------------------------------------------
OS=$(uname -s)
EFFECTIVE_JOBFILE="$JOBFILE"
if [ "$OS" = "Darwin" ]; then
    EFFECTIVE_JOBFILE="${TMPDIR:-/tmp}/fio_write_bench_darwin.$$.ini"
    sed 's/^direct=1/direct=0/' "$JOBFILE" > "$EFFECTIVE_JOBFILE"
    trap 'rm -f "$EFFECTIVE_JOBFILE"' EXIT
fi

RUNS=9
WARMUP=1

# Reduce runs for 1000M tests to save time
if [ "$SIZE_STR" = "1000M" ]; then
    RUNS=6
fi

RESULTS=()

echo "Benchmarking $TARGET_FILE ($SIZE_STR, $WORKLOAD)"
echo

for i in $(seq 1 $RUNS); do
    rm -f "$TARGET_FILE"
    echo "Run $i / $RUNS"

    # Use a temporary file for JSON output to avoid stdout blocking over SSH
    OUTFILE="${TMPDIR:-/tmp}/fio_out.$$.$i.json"

    fio "$EFFECTIVE_JOBFILE" \
        --filename="$TARGET_FILE" \
        --size="$SIZE_STR" \
        --output-format=json \
        --output="$OUTFILE"

    # Extract write bandwidth from JSON (in KB/s)
    BW=$(jq '.jobs[0].write.bw' "$OUTFILE")
    MBPS=$(awk -v bw="$BW" 'BEGIN {printf "%.2f", bw/1024}')

    if [ "$i" -le "$WARMUP" ]; then
        echo "Warmup run: $MBPS MB/s"
        continue
    fi

    echo "Measured: $MBPS MB/s"
    RESULTS+=("$MBPS")

    rm -f "$OUTFILE"
done

rm -f "$TARGET_FILE"

echo
echo "Calculating statistics..."

# Trim min and max
SORTED_RESULTS=($(printf "%s\n" "${RESULTS[@]}" | sort -n))
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
echo

# Ensure bench_runner.sh can parse it
echo "Mean throughput: $MEAN MB/s"
echo "Stddev: $STDDEV MB/s"
