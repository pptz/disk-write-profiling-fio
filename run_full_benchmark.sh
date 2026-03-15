#!/usr/bin/env bash

# ================================================================
# run_full_benchmark.sh
#
# Fully automated storage benchmark setup + execution
# Supports:
#   Linux
#   FreeBSD
#   OmniOS / illumos
#   macOS (Darwin / Apple Silicon)
#
# Requires:
#   bash
#   fio
# ================================================================

set -euo pipefail

OS=$(uname -s)

can_sudo() {
    # If we are already root, we don't need sudo
    if [ "$(id -u)" -eq 0 ]; then return 0; fi

    # Try sudo -n true. If it fails with "Operation not permitted" (126), it's blocked by seatbelt.
    # If it fails with "a password is required", it's just not configured for non-interactive use.
    # However, in this environment, it's blocked.
    /usr/bin/sudo -n true 2>/dev/null && return 0
    return 1
}

if ! can_sudo; then
    echo "WARNING: sudo is not permitted. Commands requiring root will likely fail."
    sudo() {
        # Pass-through for sudo when it's not available.
        # This allows the script to try running commands anyway.
        # Handle sudo -n true specifically
        if [ "$1" = "-n" ] && [ "$2" = "true" ]; then return 1; fi
        "$@"
    }
fi

# ------------------------------------------------
# Install required packages if missing
# ------------------------------------------------

install_dependencies() {

    echo "Checking required tools..."

    NEED_INSTALL=()

    command -v fio >/dev/null 2>&1 || NEED_INSTALL+=("fio")
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
                sudo apt update
                sudo apt install -y fio jq nfs-kernel-server

            elif command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y fio jq nfs-utils

            elif command -v yum >/dev/null 2>&1; then
                sudo yum install -y fio jq nfs-utils

            else
                echo "Unsupported Linux package manager."
                echo "Please install: fio jq nfs-utils"
                exit 1
            fi
            ;;

        FreeBSD*)

            sudo pkg update
            sudo pkg install -y fio jq
            ;;

        SunOS*)

            # OmniOS / illumos IPS packages
            sudo pkg refresh
            sudo pkg install fio jq
            ;;

        Darwin*)

            # macOS: use Homebrew.  nfs-utils is built into macOS so only
            # fio and jq need to be installed.
            if ! command -v brew >/dev/null 2>&1; then
                echo "Homebrew not found. Please install it from https://brew.sh"
                exit 1
            fi
            # brew install doesn't usually need sudo
            brew install fio jq
            ;;

        *)

            echo "Unsupported OS"
            exit 1
            ;;

    esac

    echo "Dependency installation complete."
}

BASE="${BASE:-${TMPDIR:-/tmp}/storage_bench}"
RAMDIR="$BASE/ramdisk"
DISKDIR="$BASE/disk"
NFS_RAM_MNT="$BASE/nfs_ram"
NFS_DISK_MNT="$BASE/nfs_disk"

SIZES=("10" "100" "1000")

mkdir -p "$BASE"

echo "Detected OS: $OS"
echo

# ------------------------------------------------
# Ensure fio exists
# ------------------------------------------------

if ! command -v fio >/dev/null 2>&1; then
    echo "ERROR: fio not found. Please install fio."
    exit 1
fi

# ------------------------------------------------
# Setup ramdisk
# ------------------------------------------------

setup_ramdisk() {

    echo "Setting up RAM disk..."

    case "$OS" in

        Linux*)

            mkdir -p "$RAMDIR"

            mountpoint -q "$RAMDIR" || \
                sudo mount -t tmpfs -o size=2G tmpfs "$RAMDIR"
            ;;

        FreeBSD*)

            mkdir -p "$RAMDIR"

            if ! mount | grep -q "$RAMDIR"; then
                mdconfig -a -t swap -s 2G -u 0
                newfs /dev/md0
                mount /dev/md0 "$RAMDIR"
            fi
            ;;

        SunOS*)

            mkdir -p "$RAMDIR"

            if ! mount | grep -q "$RAMDIR"; then
                RAMDISK=$(ramdiskadm -a benchram 2048m)
                newfs "$RAMDISK"
                mount "$RAMDISK" "$RAMDIR"
            fi
            ;;

        Darwin*)

            mkdir -p "$RAMDIR"

            if ! mount | grep -q "$RAMDIR"; then
                # hdiutil uses 512-byte sectors; 4194304 sectors = 2 GiB
                RAMDEV=$(hdiutil attach -nomount ram://4194304)
                # hdiutil output is tab-separated; grab just the device token
                RAMDEV=$(echo "$RAMDEV" | awk '{print $1}')
                # newfs_hfs requires the raw character device (/dev/rdiskN)
                # hdiutil returns the block device (/dev/diskN), so convert
                RAWDEV=$(echo "$RAMDEV" | sed 's|/dev/disk|/dev/rdisk|')
                newfs_hfs "$RAWDEV"
                # mount uses the block device (/dev/diskN) as normal
                mount -t hfs "$RAMDEV" "$RAMDIR"
            fi
            ;;

        *)
            echo "Unsupported OS"
            exit 1
            ;;

    esac
}

# ------------------------------------------------
# Setup disk benchmark directory
# ------------------------------------------------

setup_diskdir() {

    echo "Preparing disk benchmark directory..."

    case "$OS" in

        SunOS*)

            # If ZFS exists, create tuned dataset
            if command -v zfs >/dev/null 2>&1; then

                ZPOOL=$(zpool list -H -o name | head -n1)

                DATASET="$ZPOOL/bench"

                if ! zfs list "$DATASET" >/dev/null 2>&1; then
                    echo "Creating ZFS dataset $DATASET"
                    zfs create "$DATASET"
                fi

                echo "Applying ZFS benchmark tuning..."

                zfs set primarycache=metadata "$DATASET"
                zfs set sync=always "$DATASET"
                zfs set compression=off "$DATASET"
                zfs set logbias=throughput "$DATASET"

                DISKDIR="/$DATASET"

            else
                mkdir -p "$DISKDIR"
            fi
            ;;

        *)

            mkdir -p "$DISKDIR"
            ;;

    esac
}

# ------------------------------------------------
# Setup NFS server
# ------------------------------------------------

setup_nfs_server() {

    echo "Configuring NFS server..."

    case "$OS" in

        Linux*)

            sudo mkdir -p "$RAMDIR" "$DISKDIR"

            # /etc/exports may not exist on minimal Debian installs
            # create it if missing so exportfs and sed don't fail.
            sudo touch /etc/exports

            # Write directly to /etc/exports rather than /etc/exports.d/
            # because the drop-in directory is not guaranteed to exist on
            # all distributions (e.g. Debian minimal installs omit it).
            # Use sed to remove any stale entries first, then append fresh ones,
            # so re-runs don't accumulate duplicate lines.
            sudo sed -i "\|$RAMDIR|d"  /etc/exports
            sudo sed -i "\|$DISKDIR|d" /etc/exports
            echo "$RAMDIR *(rw,sync,no_root_squash)"  | sudo tee -a /etc/exports
            echo "$DISKDIR *(rw,sync,no_root_squash)" | sudo tee -a /etc/exports

            # Ensure nfs-kernel-server is running before re-exporting.
            # Restart rather than start so it picks up the freshly written
            # /etc/exports a running daemon won't re-read it on 'start'.
            sudo systemctl restart nfs-kernel-server 2>/dev/null ||                 sudo systemctl restart nfs-server 2>/dev/null || true
            sudo exportfs -ra
            ;;

        FreeBSD*)

            sudo sh -c "echo '$RAMDIR -maproot=root localhost 127.0.0.1' >> /etc/exports"
            sudo sh -c "echo '$DISKDIR -maproot=root localhost 127.0.0.1' >> /etc/exports"

            sudo service mountd restart
            sudo service nfsd restart
            ;;

        SunOS*)

            share -F nfs -o rw "$RAMDIR"
            share -F nfs -o rw "$DISKDIR"
            ;;

        Darwin*)

            sudo mkdir -p "$RAMDIR" "$DISKDIR"
            sudo chmod 777 "$RAMDIR" "$DISKDIR"

            # /tmp on macOS is a symlink to /private/tmp.
            REAL_RAMDIR=$(realpath "$RAMDIR")
            REAL_DISKDIR=$(realpath "$DISKDIR")

            # macOS exports format is identical to FreeBSD.
            # Using -network/-mask is often more robust for loopback on Darwin.
            # -maproot=0 is equivalent to root but sometimes more reliable.
            sudo sh -c "echo '$REAL_RAMDIR  -maproot=0 -alldirs -network 127.0.0.0 -mask 255.0.0.0' >> /etc/exports"
            sudo sh -c "echo '$REAL_DISKDIR -maproot=0 -alldirs -network 127.0.0.0 -mask 255.0.0.0' >> /etc/exports"

            # Enable the NFS daemon so it starts at boot.
            sudo nfsd enable

            if sudo nfsd status | grep -q "is running"; then
                sudo nfsd update
            else
                sudo nfsd start
            fi

            # Give nfsd a longer moment to process the updated exports.
            sleep 3
            echo "--- /etc/exports ---"
            sudo cat /etc/exports
            echo "--- showmount -e 127.0.0.1 ---"
            showmount -e 127.0.0.1
            echo "--------------------"
            ;;


    esac
}

# ------------------------------------------------
# Mount loopback NFS
# ------------------------------------------------

mount_nfs() {

    echo "Mounting loopback NFS..."

    # macOS requires root for NFS mounts; use sudo for mkdir and mount
    # on Darwin so the mount point creation and mount itself both succeed.
    case "$OS" in
        Darwin*)
            sudo mkdir -p "$NFS_RAM_MNT"
            sudo mkdir -p "$NFS_DISK_MNT"
            sudo chmod 777 "$NFS_RAM_MNT" "$NFS_DISK_MNT"
            ;;
        *)
            mkdir -p "$NFS_RAM_MNT"
            mkdir -p "$NFS_DISK_MNT"
            ;;
    esac

    # Choose NFS mount options per OS.
    #   - noatime:  suppress access-time updates so reads don't trigger writes
    #               and skew latency numbers.
    #   - vers=3:   force NFSv3 on FreeBSD/OmniOS.  Without this the client and
    #               server can negotiate different versions in a loopback setup,
    #               leading to silent hangs or permission errors.
    #   - 127.0.0.1 instead of localhost: avoids hostname-resolution overhead
    #               and the IPv6 pitfall on FreeBSD where localhost -> ::1 while
    #               nfsd only listens on IPv4.
    #   - resvport: macOS NFS client requires a privileged source port by
    #               default; without this the loopback mount is refused.
    #               noatime is a local-FS option on macOS and not valid for NFS,
    #               so it is omitted here.
    case "$OS" in

        Linux*)
            # Specify vers=3 explicitly so the mount type appears as 'nfs'
            # rather than 'nfs4' in mount output.  Without this the client
            # negotiates NFSv4 by default, which breaks the NFS mount
            # detection check in bench_runner.sh.
            MOUNT_OPTS="rw,noatime,vers=3"
            ;;

        FreeBSD*|SunOS*)
            MOUNT_OPTS="rw,noatime,vers=3"
            ;;

        Darwin*)
            MOUNT_OPTS="rw,resvport,vers=3"
            ;;

        *)
            MOUNT_OPTS="rw,noatime"
            ;;

    esac

    case "$OS" in

        SunOS*)
            # illumos uses -F to specify the filesystem type and -o for options.
            mount -F nfs -o "$MOUNT_OPTS" 127.0.0.1:"$RAMDIR"  "$NFS_RAM_MNT"
            mount -F nfs -o "$MOUNT_OPTS" 127.0.0.1:"$DISKDIR" "$NFS_DISK_MNT"
            ;;

        Darwin*)
            # macOS requires sudo for NFS mounts even for loopback.
            # The export was written with the realpath (/private/tmp/...);
            # the mount request must use the same resolved path or nfsd
            # will deny it with EPERM even though the path is the same dir.
            REAL_RAMDIR=$(realpath "$RAMDIR")
            REAL_DISKDIR=$(realpath "$DISKDIR")
            sudo mount -t nfs -o "$MOUNT_OPTS" 127.0.0.1:"$REAL_RAMDIR"  "$NFS_RAM_MNT"
            sudo mount -t nfs -o "$MOUNT_OPTS" 127.0.0.1:"$REAL_DISKDIR" "$NFS_DISK_MNT"
            ;;

        *)
            mount -t nfs -o "$MOUNT_OPTS" 127.0.0.1:"$RAMDIR"  "$NFS_RAM_MNT"
            mount -t nfs -o "$MOUNT_OPTS" 127.0.0.1:"$DISKDIR" "$NFS_DISK_MNT"
            ;;

    esac

}

# ------------------------------------------------
# Run orchestrator
# ------------------------------------------------

run_benchmarks() {

    echo
    echo "Starting benchmark suite..."
    echo

    ./bench_runner.sh "$RAMDIR" "$DISKDIR" "$NFS_RAM_MNT" "$NFS_DISK_MNT"
}

# ------------------------------------------------
# Teardown
#
# Safe to call at any point — every step is
# guarded so it skips quietly if the resource
# it is trying to clean up does not exist.
# Called explicitly before setup (pre-clean) and
# registered via trap so it also runs on exit,
# Ctrl-C, or any unhandled error.
# ------------------------------------------------

teardown() {

    echo "Running teardown..."

    # ---- NFS mount points ------------------------------------------
    # Unmount loopback NFS before touching the exported directories.
    # 'umount' exits non-zero if the path is not mounted; the '|| true'
    # prevents set -e from aborting the rest of teardown in that case.

    case "$OS" in

        SunOS*)
            umount "$NFS_RAM_MNT"  2>/dev/null || true
            umount "$NFS_DISK_MNT" 2>/dev/null || true
            ;;

        Darwin*)
            # Try a clean umount first; if the handle is stale the kernel
            # will refuse it, so fall back to 'diskutil unmount force' which
            # bypasses the NFS layer entirely and tears down the mount point
            # directly.  Use the canonical /private/tmp path because diskutil
            # requires the resolved path, not the /tmp symlink.
            for MNT in "$NFS_RAM_MNT" "$NFS_DISK_MNT"; do
                REAL_MNT=$(cd "$MNT" 2>/dev/null && pwd -P || echo "$MNT")
                sudo umount "$REAL_MNT" 2>/dev/null || \
                    sudo diskutil unmount force "$REAL_MNT" 2>/dev/null || true
            done
            ;;

        *)
            umount "$NFS_RAM_MNT"  2>/dev/null || true
            umount "$NFS_DISK_MNT" 2>/dev/null || true
            ;;

    esac

    # ---- NFS server exports ----------------------------------------
    # Clear /etc/exports so stale entries don't accumulate across runs,
    # then signal the daemon to reload.

    case "$OS" in

        Linux*)
            # Remove only the lines this script added; leave other exports intact.
            sudo sed -i "\|$RAMDIR|d"  /etc/exports 2>/dev/null || true
            sudo sed -i "\|$DISKDIR|d" /etc/exports 2>/dev/null || true
            sudo exportfs -ra 2>/dev/null || true
            ;;

        FreeBSD*)
            # Remove only the lines this script added; leave other exports intact.
            sudo sed -i '' "\|$RAMDIR|d"  /etc/exports 2>/dev/null || true
            sudo sed -i '' "\|$DISKDIR|d" /etc/exports 2>/dev/null || true
            sudo service mountd restart 2>/dev/null || true
            ;;

        SunOS*)
            unshare "$RAMDIR"  2>/dev/null || true
            unshare "$DISKDIR" 2>/dev/null || true
            ;;

        Darwin*)
            # Remove only the lines this script added; leave other exports intact.
            # Use the resolved paths because that is what was written to the file.
            REAL_RAMDIR=$(realpath "$RAMDIR"   2>/dev/null || echo "$RAMDIR")
            REAL_DISKDIR=$(realpath "$DISKDIR" 2>/dev/null || echo "$DISKDIR")
            sudo sed -i '' "\|$REAL_RAMDIR|d"  /etc/exports 2>/dev/null || true
            sudo sed -i '' "\|$REAL_DISKDIR|d" /etc/exports 2>/dev/null || true
            sudo nfsd update 2>/dev/null || true
            ;;

    esac

    # ---- RAM disk --------------------------------------------------
    # Unmount the ramdisk, then release the underlying device so the
    # RAM is returned to the OS.

    case "$OS" in

        Linux*)
            # tmpfs — unmounting is sufficient; no device to detach.
            umount "$RAMDIR" 2>/dev/null || true
            ;;

        FreeBSD*)
            umount "$RAMDIR" 2>/dev/null || true
            # Detach the md(4) device that backs the ramdisk.
            MDDEV=$(mount | awk -v p="$RAMDIR" '$3==p {print $1}')
            if [ -n "$MDDEV" ]; then
                mdconfig -d -u "${MDDEV##/dev/md}"
            fi
            ;;

        SunOS*)
            umount "$RAMDIR" 2>/dev/null || true
            ramdiskadm -d benchram 2>/dev/null || true
            ;;

        Darwin*)
            sudo umount "$RAMDIR" 2>/dev/null || true
            # Detach the hdiutil RAM disk by finding the device that was
            # mounted on $RAMDIR.  'hdiutil detach' unmounts and ejects.
            HDIDEV=$(hdiutil info | awk -v p="$RAMDIR" '$0 ~ p {print prev} {prev=$1}')
            if [ -n "$HDIDEV" ]; then
                hdiutil detach "$HDIDEV" 2>/dev/null || true
            fi
            ;;

    esac

    # ---- Temp files ------------------------------------------------
    # $BASE and its subdirectories are created with sudo, so removal
    # also needs sudo.  The results file is unprivileged, so it does not.
    sudo rm -rf "$BASE"
    rm -f "${TMPDIR:-/tmp}"/bench_results.*

    echo "Teardown complete."
}

# ------------------------------------------------
# Main
# ------------------------------------------------

# Register teardown to run automatically on exit (normal or otherwise),
# so that Ctrl-C or an unhandled error still cleans up after itself.
trap teardown EXIT

# Pre-clean any leftovers from a previous run before setting up fresh.
teardown

install_dependencies
setup_ramdisk || echo "WARNING: Failed to setup RAM disk. Skipping RAM-based tests."
setup_diskdir || echo "WARNING: Failed to prepare disk directory."
setup_nfs_server || echo "WARNING: Failed to configure NFS server. Skipping NFS tests."
mount_nfs || echo "WARNING: Failed to mount NFS. Skipping NFS tests."
run_benchmarks

echo
echo "Benchmark complete."
