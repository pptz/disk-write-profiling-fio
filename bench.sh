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

# Define AWK for SunOS compatibility
AWK_BIN="awk"
[ "$OS" = "SunOS" ] && AWK_BIN="nawk"

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

# Portable lowercase for MODE
MODE_LOWER=$(echo "$MODE" | tr '[:upper:]' '[:lower:]')

# ------------------------------------------------
# purge_cache (Internal)
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
            # Format: /mountpoint on /dev/device
            DEV=$(mount | $AWK_BIN -v p="$RAMDIR" '$1 == p {print $3}')
            [ -z "$DEV" ] && DEV="/dev/ramdisk/benchram"
            
            pfexec umount "$RAMDIR" 2>/dev/null \
                && pfexec mount -F ufs -o nologging "$DEV" "$RAMDIR" 2>/dev/null || true
        fi
    fi
}

RUNS=9
WARMUP=1

if [ "$TEST_MODE" = "test" ]; then
    RUNS=2
    WARMUP=1
elif [ "$SIZE_STR" = "750M" ]; then
    RUNS=6
fi

RESULTS=()

# Parse SIZE_STR to COUNT portably (assuming bs=1M)
SIZE_VAL=$(echo "$SIZE_STR" | sed 's/[^0-9]//g')
SIZE_UNIT=$(echo "$SIZE_STR" | sed 's/[0-9]//g')
if [ "$SIZE_UNIT" = "G" ]; then
    COUNT=$((SIZE_VAL * 1024))
else
    COUNT=$SIZE_VAL
fi

for i in $(seq 1 $RUNS); do
    
    if [ "$MODE" = "WRITE" ]; then
        rm -f "$TARGET_FILE"
    else
        purge_cache "$TARGET_FILE"
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
            SYNC=0
        fi

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

        BW=$(jq -r ".jobs[0].${MODE_LOWER}.bw" "$OUTFILE" 2>/dev/null || echo 0)
        MBPS=$(echo "$BW" | $AWK_BIN '{printf "%.2f", $1/1024}')
        rm -f "$OUTFILE"
    else
        # dd implementation
        T_START=$(perl -MTime::HiRes=time -e 'print time' 2>/dev/null || date +%s)

        if [ "$MODE" = "WRITE" ]; then
            if [ "$WORKLOAD" = "SEQ" ]; then
                if [ "$OS" = "SunOS" ]; then
                    dd if=/dev/zero of="$TARGET_FILE" bs=1048576 count=$COUNT
                    sync
                else
                    dd if=/dev/zero of="$TARGET_FILE" bs=1M count=$COUNT conv=fsync status=none
                fi
            else
                touch "$TARGET_FILE"
                for (( j=0; j<COUNT; j++ )); do
                    OFFSET=$(( RANDOM % COUNT ))
                    if [ "$OS" = "SunOS" ]; then
                        dd if=/dev/zero of="$TARGET_FILE" bs=1048576 count=1 seek=$OFFSET conv=notrunc
                    else
                        dd if=/dev/zero of="$TARGET_FILE" bs=1M count=1 seek=$OFFSET conv=notrunc status=none
                    fi
                done
                if [ "$OS" = "SunOS" ]; then
                    sync
                else
                    dd if=/dev/null of="$TARGET_FILE" conv=notrunc,fsync status=none
                fi
            fi
        else
            if [ "$WORKLOAD" = "SEQ" ]; then
                if [ "$OS" = "SunOS" ]; then
                    dd if="$TARGET_FILE" of=/dev/null bs=1048576 count=$COUNT
                else
                    dd if="$TARGET_FILE" of=/dev/null bs=1M count=$COUNT status=none
                fi
            else
                for (( j=0; j<COUNT; j++ )); do
                    OFFSET=$(( RANDOM % COUNT ))
                    if [ "$OS" = "SunOS" ]; then
                        dd if="$TARGET_FILE" of=/dev/null bs=1048576 count=1 skip=$OFFSET
                    else
                        dd if="$TARGET_FILE" of=/dev/null bs=1M count=1 skip=$OFFSET status=none
                    fi
                done
            fi
        fi

        # Capture End Time and Calculate MBPS
        T_END=$(perl -MTime::HiRes=time -e 'print time' 2>/dev/null || date +%s)
        
        DURATION=$(echo "$T_START $T_END" | $AWK_BIN '{print $2 - $1}')
        IS_VALID=$(echo "$DURATION" | $AWK_BIN '{if ($1 > 0.001) print "1"; else print "0"}')
        
        if [ "$IS_VALID" = "1" ]; then
            MBPS=$(echo "$COUNT $DURATION" | $AWK_BIN '{printf "%.2f", $1/$2}')
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

echo "Mean throughput: $(echo "$TRIMMED" | $AWK_BIN '{sum+=$1; n++} END {if (n>0) printf "%.2f", sum/n; else print "0.00"}') MB/s"
echo "Stddev: $(echo "$TRIMMED" | $AWK_BIN '{sum+=$1; sumsq+=$1*$1; n++} END {if (n>1) printf "%.2f", sqrt((sumsq - (sum*sum)/n)/(n-1)); else print "0.00"}') MB/s"
