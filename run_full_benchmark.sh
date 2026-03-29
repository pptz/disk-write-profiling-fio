#!/usr/bin/env bash

# ================================================================
# run_full_benchmark.sh
# ================================================================

set -euo pipefail

WORKLOAD="${1:-SEQ}"
TOOL="${2:-fio}"
TEST_MODE="${3:-}"
OS=$(uname -s)

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

# ------------------------------------------------
# Install dependencies
# ------------------------------------------------

install_dependencies() {

    echo "Checking required tools..."

    NEED_INSTALL=()

    if [ "$TOOL" = "fio" ]; then
        command -v fio >/dev/null 2>&1 || NEED_INSTALL+=("fio")
    fi
    command -v jq  >/dev/null 2>&1 || NEED_INSTALL+=("jq")

    if [ ${#NEED_INSTALL[@]} -eq 0 ]; then
        echo "All dependencies already installed."
        return
    fi

    echo "Missing packages: ${NEED_INSTALL[*]}"
    echo "Attempting installation..."

    case "$OS" in

        Linux*)
            if command -v apt >/dev/null 2>&1; then
                as_root apt update
                as_root apt install -y fio jq nfs-kernel-server
            elif command -v dnf >/dev/null 2>&1; then
                as_root dnf install -y fio jq nfs-utils
            elif command -v yum >/dev/null 2>&1; then
                as_root yum install -y fio jq nfs-utils
            else
                echo "Unsupported Linux package manager."
                exit 1
            fi
            ;;

        FreeBSD*)
            as_root pkg update
            as_root pkg install -y fio jq
            ;;

        SunOS*)
            as_root pkg refresh
            as_root pkg install fio jq
            ;;

        Darwin*)
            if ! command -v brew >/dev/null 2>&1; then
                echo "Homebrew not found: https://brew.sh"
                exit 1
            fi
            brew install fio jq
            ;;

        *)
            echo "Unsupported OS"
            exit 1
            ;;
    esac
}

# ------------------------------------------------
# Paths
# ------------------------------------------------

BASE="${BASE:-${TMPDIR:-/tmp}/storage_bench}"
RAMDIR="$BASE/ramdisk"
DISKDIR="$BASE/disk"
NFS_RAM_MNT="$BASE/nfs_ram"
NFS_DISK_MNT="$BASE/nfs_disk"

mkdir -p "$BASE"

echo "Detected OS: $OS"
echo

# ------------------------------------------------
# Sanity check
# ------------------------------------------------

if [ "$TOOL" = "fio" ]; then
    command -v fio >/dev/null 2>&1 || {
        echo "ERROR: fio not found."
        exit 1
    }
fi

# ------------------------------------------------
# RAM disk
# ------------------------------------------------

setup_ramdisk() {

    echo "Setting up RAM disk..."

    case "$OS" in

        Linux*)
            mkdir -p "$RAMDIR"
            if ! mountpoint -q "$RAMDIR"; then
                as_root modprobe brd rd_nr=1 rd_size=2097152
                as_root mkfs.ext4 /dev/ram0
                as_root mount /dev/ram0 "$RAMDIR"
            fi
            ;;

        FreeBSD*)
            mkdir -p "$RAMDIR"
            if ! mount | grep -q "$RAMDIR"; then
                MD=$(as_root mdconfig -a -t swap -s 2G)
                as_root newfs "/dev/$MD"
                as_root mount "/dev/$MD" "$RAMDIR"
            fi
            ;;

        SunOS*)
            mkdir -p "$RAMDIR"
            if ! mount | grep -q "$RAMDIR"; then
                RAMDISK=$(as_root ramdiskadm -a benchram 2048m)
                as_root newfs "$RAMDISK"
                as_root mount "$RAMDISK" "$RAMDIR"
            fi
            ;;

        Darwin*)
            mkdir -p "$RAMDIR"
            if ! mount | grep -q "$RAMDIR"; then
                DEV=$(hdiutil attach -nomount ram://4194304 | awk '{print $1}')
                RAW=$(echo "$DEV" | sed 's|/dev/disk|/dev/rdisk|')
                as_root newfs_hfs "$RAW"
                as_root mount -t hfs "$DEV" "$RAMDIR"
                echo "Mounted ramdisk $DEV on $RAMDIR"
            fi
            ;;
    esac
}

# ------------------------------------------------
# Disk dir
# ------------------------------------------------

setup_diskdir() {
    echo "Preparing disk benchmark directory..."
    mkdir -p "$DISKDIR"
}

# ------------------------------------------------
# NFS server
# ------------------------------------------------

setup_nfs_server() {

    echo "Configuring NFS server..."

    case "$OS" in

        Linux*)
            as_root mkdir -p "$RAMDIR" "$DISKDIR"
            as_root touch /etc/exports

            as_root sed -i "\|$RAMDIR|d" /etc/exports || true
            as_root sed -i "\|$DISKDIR|d" /etc/exports || true

            echo "$RAMDIR *(rw,sync,no_root_squash)"  | as_root tee -a /etc/exports >/dev/null
            echo "$DISKDIR *(rw,sync,no_root_squash)" | as_root tee -a /etc/exports >/dev/null

            as_root systemctl restart nfs-kernel-server 2>/dev/null || true
            as_root exportfs -ra
            ;;

        Darwin*)
            as_root mkdir -p "$RAMDIR" "$DISKDIR"
            REAL_RAMDIR=$(cd "$RAMDIR" && pwd)
            REAL_DISKDIR=$(cd "$DISKDIR" && pwd)
            
            # Use a more robust sed pattern and ensure we are cleaning up
            as_root sed -i '' "\|$REAL_RAMDIR|d" /etc/exports 2>/dev/null || true
            as_root sed -i '' "\|$REAL_DISKDIR|d" /etc/exports 2>/dev/null || true

            echo "$REAL_RAMDIR -maproot=0 -alldirs -network 127.0.0.0 -mask 255.0.0.0" | as_root tee -a /etc/exports >/dev/null
            echo "$REAL_DISKDIR -maproot=0 -alldirs -network 127.0.0.0 -mask 255.0.0.0" | as_root tee -a /etc/exports >/dev/null

            as_root nfsd enable || true
            as_root nfsd update || true
            
            # Give nfsd time to digest the new exports
            sleep 2
            ;;
    esac
}

# ------------------------------------------------
# Mount NFS
# ------------------------------------------------

mount_nfs() {

    echo "Mounting loopback NFS..."

    mkdir -p "$NFS_RAM_MNT" "$NFS_DISK_MNT"

    case "$OS" in
        Linux*)
            OPTS="rw,noatime,vers=3"
            ;;
        Darwin*)
            OPTS="rw,resvport,vers=3"
            ;;
        *)
            OPTS="rw"
            ;;
    esac

    as_root mount -t nfs -o "$OPTS" 127.0.0.1:"$RAMDIR"  "$NFS_RAM_MNT"
    as_root mount -t nfs -o "$OPTS" 127.0.0.1:"$DISKDIR" "$NFS_DISK_MNT"
}

# ------------------------------------------------
# Benchmarks
# ------------------------------------------------

run_benchmarks() {
    # Ensure TEST_MODE is defined for the label printing
    LBL="${TEST_MODE:-Standard}"
    echo "Starting benchmark suite ($WORKLOAD) using $TOOL (Mode: $LBL)..."
    ./bench_runner.sh "$RAMDIR" "$DISKDIR" "$NFS_RAM_MNT" "$NFS_DISK_MNT" "$WORKLOAD" "$TOOL" "$TEST_MODE"
}

# ------------------------------------------------
# Teardown
# ------------------------------------------------

teardown() {

    echo "Running teardown..."

    as_root umount "$NFS_RAM_MNT" 2>/dev/null || true
    as_root umount "$NFS_DISK_MNT" 2>/dev/null || true

    case "$OS" in
        Linux*)
            as_root sed -i "\|$RAMDIR|d" /etc/exports || true
            as_root sed -i "\|$DISKDIR|d" /etc/exports || true
            as_root exportfs -ra || true
            ;;
        Darwin*)
            # Clean up /etc/exports
            as_root sed -i '' "\|$RAMDIR|d" /etc/exports 2>/dev/null || true
            as_root sed -i '' "\|$DISKDIR|d" /etc/exports 2>/dev/null || true
            as_root nfsd update || true
            ;;
    esac

    as_root umount "$RAMDIR" 2>/dev/null || true
    as_root rmmod brd 2>/dev/null || true
    as_root rm -rf "$BASE"

    echo "Teardown complete."
}

# ------------------------------------------------
# Main
# ------------------------------------------------

trap teardown EXIT

teardown

install_dependencies
setup_ramdisk || echo "WARNING: RAM disk failed"
setup_diskdir
setup_nfs_server || echo "WARNING: NFS setup failed"
mount_nfs || echo "WARNING: NFS mount failed"

run_benchmarks

echo
echo "Benchmark complete."
