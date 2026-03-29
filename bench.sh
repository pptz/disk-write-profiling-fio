#!/usr/bin/env bash

# ===============================================================
# bench.sh
#
# Portable fio/dd benchmark runner (SSH-friendly)
# Works on:
#   Linux
#   FreeBSD
#   OmniOS / illumos
#   macOS (Darwin / Apple Silicon)
#
# Usage:
#   ./bench.sh <target_file> <size_mb> [SEQ|RAND] [fio|dd]
#
# Example:
#   ./bench.sh /tmp/testfile 100 SEQ dd
# ===============================================================

set -e

TARGET_FILE="$1"
SIZE_STR="$2"
WORKLOAD="${3:-SEQ}"
TOOL="${4:-fio}"
OS=$(uname -s)

if [ -z "$TARGET_FILE" ] || [ -z "$SIZE_STR" ]; then
    echo "Usage: $0 <target_file> <size> [SEQ|RAND] [fio|dd]" >&2
    exit 1
fi

if [ "$TOOL" = "fio" ]; then
    if ! command -v fio >/dev/null 2>&1; then
        echo "fio not installed" >&2
        exit 1
    fi
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

echo "Benchmarking $TARGET_FILE ($SIZE_STR, $WORKLOAD) using $TOOL"
echo

for i in $(seq 1 $RUNS); do
    rm -f "$TARGET_FILE"
    #echo "Run $i / $RUNS"

    if [ "$TOOL" = "fio" ]; then
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
        rm -f "$OUTFILE"
    else
        # dd implementation
        # Parse SIZE_STR to COUNT (assuming bs=1M)
        SIZE_VAL=$(grep -oE '^[0-9]+' <<< "$SIZE_STR")
        SIZE_UNIT=$(grep -oE '[MG]' <<< "$SIZE_STR")
        if [ "$SIZE_UNIT" = "G" ]; then
            COUNT=$((SIZE_VAL * 1024))
        else
            COUNT=$SIZE_VAL
        fi

        # We'll use a loop to match fio's sync=1 (O_SYNC) behavior, 
        # as many dd versions don't support oflag=dsync.
        
        T_START=$(perl -MTime::HiRes=time -e 'print time' 2>/dev/null || date +%s)
        
        # Pre-create file to avoid truncation issues in loop
        touch "$TARGET_FILE"

        for (( j=0; j<COUNT; j++ )); do
            if [ "$WORKLOAD" = "RAND" ]; then
                OFFSET=$(( RANDOM % COUNT ))
            else
                OFFSET=$j
            fi
            
            if [ "$OS" = "Linux" ]; then
                # On Linux we can try to use oflag=direct,dsync if supported, 
                # but for consistency with Darwin we'll use a loop-based approach 
                # or just use the tool flags if available.
                # Here we stick to a simple loop with fsync to ensure we match fio.
                dd if=/dev/zero of="$TARGET_FILE" bs=1M count=1 seek=$OFFSET conv=notrunc,fdatasync status=none 2>/dev/null
            else
                # Darwin/BSD
                dd if=/dev/zero of="$TARGET_FILE" bs=1M count=1 seek=$OFFSET conv=notrunc,fsync status=none 2>/dev/null
            fi
        done

        T_END=$(perl -MTime::HiRes=time -e 'print time' 2>/dev/null || date +%s)
        
        # Calculate MBPS
        DURATION=$(awk -v start="$T_START" -v end="$T_END" 'BEGIN {print end - start}')
        if (( $(awk -v d="$DURATION" 'BEGIN {print (d > 0.001)}') )); then
            MBPS=$(awk -v size="$COUNT" -v duration="$DURATION" 'BEGIN {printf "%.2f", size/duration}')
        else
            MBPS="0.00"
        fi
    fi

    if [ "$i" -le "$WARMUP" ]; then
        #echo "Warmup run: $MBPS MB/s"
        continue
    fi

    #echo "Measured: $MBPS MB/s"
    RESULTS+=("$MBPS")
done

rm -f "$TARGET_FILE"

echo
echo "Calculating statistics..."

# Trim min and max
SORTED_RESULTS=($(printf "%s\n" "${RESULTS[@]}" | sort -n))
RESULTS_TRIMMED=("${SORTED_RESULTS[@]:1:${#SORTED_RESULTS[@]}-2}")

COUNT_RES=${#RESULTS_TRIMMED[@]}
SUM=0
for v in "${RESULTS_TRIMMED[@]}"; do
    SUM=$(awk -v a="$SUM" -v b="$v" 'BEGIN{print a+b}')
done

MEAN=$(awk -v sum="$SUM" -v n="$COUNT_RES" 'BEGIN{printf "%.2f", sum/n}')

VAR=0
for v in "${RESULTS_TRIMMED[@]}"; do
    DIFF=$(awk -v v="$v" -v m="$MEAN" 'BEGIN{print v-m}')
    SQ=$(awk -v d="$DIFF" 'BEGIN{print d*d}')
    VAR=$(awk -v a="$VAR" -v b="$SQ" 'BEGIN{print a+b}')
done

STDDEV=$(awk -v v="$VAR" -v n="$COUNT_RES" 'BEGIN{printf "%.2f", sqrt(v/n)}')

# Ensure bench_runner.sh can parse it
echo "Mean throughput: $MEAN MB/s"
echo "Stddev: $STDDEV MB/s"
