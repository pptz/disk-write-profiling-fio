#!/usr/bin/env bash

# ===============================================================
# bench.sh
#
# Portable fio/dd benchmark runner
# ===============================================================

set -e

TARGET_FILE="$1"
SIZE_STR="$2"
WORKLOAD="${3:-SEQ}"
TOOL="${4:-fio}"
MODE="${5:-WRITE}" # WRITE or READ
TEST_MODE="${6:-}"
OS=$(uname -s)

if [ -z "$TARGET_FILE" ] || [ -z "$SIZE_STR" ]; then
    echo "Usage: $0 <target_file> <size> [SEQ|RAND] [fio|dd] [WRITE|READ] [test]" >&2
    exit 1
fi

# Portable lowercase for MODE
MODE_LOWER=$(echo "$MODE" | tr '[:upper:]' '[:lower:]')

# ------------------------------------------------
# purge_cache (Internal)
# ------------------------------------------------
purge_cache() {
    if [ "$OS" = "Darwin" ]; then
        sync
        if ! purge 2>/dev/null; then
            sudo purge 2>/dev/null || echo "WARNING: purge failed — read results may reflect cache" >&2
        fi
        if mount | grep -q " on $RAMDIR "; then
            DEV=$(mount | awk -v p="$RAMDIR" '$0 ~ p {print $1}')
            as_root umount "$RAMDIR" 2>/dev/null \
                && as_root mount -t hfs "$DEV" "$RAMDIR" 2>/dev/null || true
        fi
    elif [ "$OS" = "Linux" ]; then
        sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        if mount | grep -q " $RAMDIR "; then
            DEV=$(mount | awk -v p="$RAMDIR" '$3==p {print $1}')
            as_root umount "$RAMDIR" 2>/dev/null \
                && as_root mount "$DEV" "$RAMDIR" 2>/dev/null || true
        fi
    fi
}

RUNS=9
WARMUP=1

if [ "$TEST_MODE" = "test" ]; then
    RUNS=2
    WARMUP=1
elif [ "$SIZE_STR" = "1000M" ]; then
    RUNS=6
fi

RESULTS=()

# Parse SIZE_STR to COUNT (assuming bs=1M)
SIZE_VAL=$(grep -oE '^[0-9]+' <<< "$SIZE_STR")
SIZE_UNIT=$(grep -oE '[MG]' <<< "$SIZE_STR")
if [ "$SIZE_UNIT" = "G" ]; then
    COUNT=$((SIZE_VAL * 1024))
else
    COUNT=$SIZE_VAL
fi

for i in $(seq 1 $RUNS); do
    
    if [ "$MODE" = "WRITE" ]; then
        rm -f "$TARGET_FILE"
    else
        purge_cache
    fi

    if [ "$TOOL" = "fio" ]; then
        OUTFILE="${TMPDIR:-/tmp}/fio_out.$$.$i.json"
        
        # Determine FIO_RW
        if [ "$MODE" = "WRITE" ]; then
            [ "$WORKLOAD" = "SEQ" ] && FIO_RW="write" || FIO_RW="randwrite"
            DIRECT=1
            SYNC=1
        else
            [ "$WORKLOAD" = "SEQ" ] && FIO_RW="read" || FIO_RW="randread"
            DIRECT=1
            SYNC=0 # sync=1 is for writes (O_SYNC)
        fi

        # Darwin override for direct=1
        [ "$OS" = "Darwin" ] && DIRECT=0

        fio --name=bench_job \
            --filename="$TARGET_FILE" \
            --size="$SIZE_STR" \
            --bs=1M \
            --rw="$FIO_RW" \
            --direct="$DIRECT" \
            --sync="$SYNC" \
            --ioengine=sync \
            --buffer_pattern=0xdeadbeef \
            --output-format=json \
            --output="$OUTFILE" \
            --overwrite=1 \
            --group_reporting=1

        # Extract BW.
        BW=$(jq -r ".jobs[0].${MODE_LOWER}.bw" "$OUTFILE" 2>/dev/null || echo 0)
        MBPS=$(awk -v bw="$BW" 'BEGIN {printf "%.2f", bw/1024}')
        rm -f "$OUTFILE"
    else
        # dd implementation
        T_START=$(perl -MTime::HiRes=time -e 'print time' 2>/dev/null || date +%s)
        
        if [ "$MODE" = "WRITE" ]; then
            if [ "$WORKLOAD" = "SEQ" ]; then
                dd if=/dev/zero of="$TARGET_FILE" bs=1M count=$COUNT conv=fsync status=none 2>/dev/null
            else
                touch "$TARGET_FILE"
                for (( j=0; j<COUNT; j++ )); do
                    OFFSET=$(( RANDOM % COUNT ))
                    dd if=/dev/zero of="$TARGET_FILE" bs=1M count=1 seek=$OFFSET conv=notrunc status=none 2>/dev/null
                done
                dd if=/dev/null of="$TARGET_FILE" conv=notrunc,fsync status=none 2>/dev/null
            fi
        else
            if [ "$WORKLOAD" = "SEQ" ]; then
                dd if="$TARGET_FILE" of=/dev/null bs=1M count=$COUNT status=none 2>/dev/null
            else
                for (( j=0; j<COUNT; j++ )); do
                    OFFSET=$(( RANDOM % COUNT ))
                    dd if="$TARGET_FILE" of=/dev/null bs=1M count=1 skip=$OFFSET status=none 2>/dev/null
                done
            fi
        fi

        T_END=$(perl -MTime::HiRes=time -e 'print time' 2>/dev/null || date +%s)
        DURATION=$(awk -v start="$T_START" -v end="$T_END" 'BEGIN {print end - start}')
        if (( $(awk -v d="$DURATION" 'BEGIN {print (d > 0.001)}') )); then
            MBPS=$(awk -v size="$COUNT" -v duration="$DURATION" 'BEGIN {printf "%.2f", size/duration}')
        else
            MBPS="0.00"
        fi
    fi

    if [ "$i" -le "$WARMUP" ]; then
        continue
    fi
    RESULTS+=("$MBPS")
done

# Portable Trimmed Statistics
SORTED_RESULTS=$(printf "%s\n" "${RESULTS[@]}" | sort -n)
if [ "$TEST_MODE" = "test" ]; then
    TRIMMED="$SORTED_RESULTS"
else
    TRIMMED=$(echo "$SORTED_RESULTS" | sed '1d;$d')
fi

echo "Mean throughput: $(echo "$TRIMMED" | awk '{sum+=$1; n++} END {if (n>0) printf "%.2f", sum/n; else print "0.00"}') MB/s"
echo "Stddev: $(echo "$TRIMMED" | awk '{sum+=$1; sumsq+=$1*$1; n++} END {if (n>1) printf "%.2f", sqrt((sumsq - (sum*sum)/n)/(n-1)); else print "0.00"}') MB/s"
