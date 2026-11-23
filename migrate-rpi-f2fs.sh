#!/usr/bin/env bash
set -Eeuo pipefail

# Raspberry Pi ext4 -> F2FS migration
#
# Usage:
#   sudo ./migrate-rpi-f2fs.sh /dev/sdX [backup-directory]
#
# Example:
#   sudo ./migrate-rpi-f2fs.sh /dev/sdb ~/rpi-backups

DISK="${1:-}"
BACKUP_BASE="${2:-$PWD}"
MOUNT_BASE="/mnt/rpi-f2fs-migration"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root."
    exit 1
fi

if [[ -z "$DISK" || ! -b "$DISK" ]]; then
    echo "Usage: $0 /dev/sdX [backup-directory]"
    exit 1
fi

for cmd in rsync mkfs.f2fs blkid mount umount lsblk; do
    command -v "$cmd" >/dev/null || {
        echo "Missing dependency: $cmd"
        exit 1
    }
done

DISK=$(readlink -f "$DISK")

# Determine partition names.
if [[ "$DISK" =~ [0-9]$ ]]; then
    BOOT_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    BOOT_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

[[ -b "$BOOT_PART" && -b "$ROOT_PART" ]] || {
    echo "Expected partitions not found."
    exit 1
}

BOOT_TYPE=$(blkid -s TYPE -o value "$BOOT_PART")
ROOT_TYPE=$(blkid -s TYPE -o value "$ROOT_PART")

[[ "$BOOT_TYPE" == "vfat" ]] || {
    echo "Expected FAT32 boot partition, got: $BOOT_TYPE"
    exit 1
}

[[ "$ROOT_TYPE" == "ext4" ]] || {
    echo "Expected ext4 root partition, got: $ROOT_TYPE"
    exit 1
}

for part in "$BOOT_PART" "$ROOT_PART"; do
    if findmnt -rn -S "$part" >/dev/null; then
        echo "Partition already mounted: $part"
        exit 1
    fi
done

ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_PART")

mkdir -p "$BACKUP_BASE" "$MOUNT_BASE/root"

BACKUP=$(mktemp -d "$BACKUP_BASE/rpi-f2fs-backup.XXXXXX")

ROOT_MNT="$MOUNT_BASE/root"
BOOT_MNT="$ROOT_MNT/boot/firmware"

cleanup() {
    mountpoint -q "$BOOT_MNT" && umount "$BOOT_MNT" || true
    mountpoint -q "$ROOT_MNT" && umount "$ROOT_MNT" || true
}
trap cleanup EXIT

echo "Target disk:"
lsblk "$DISK"

echo
echo "Boot partition: $BOOT_PART"
echo "Root partition: $ROOT_PART"
echo "Backup location: $BACKUP"

read -r -p "Type YES to continue: " answer
[[ "$answer" == "YES" ]] || exit 1

# Mount original filesystems.
mount "$ROOT_PART" "$ROOT_MNT"
mkdir -p "$BOOT_MNT"
mount "$BOOT_PART" "$BOOT_MNT"

FSTAB="$ROOT_MNT/etc/fstab"
CMDLINE="$BOOT_MNT/cmdline.txt"

[[ -f "$FSTAB" && -f "$CMDLINE" ]] || {
    echo "Missing fstab or cmdline.txt."
    exit 1
}

grep -qE "^PARTUUID=${ROOT_PARTUUID}[[:space:]]+/[[:space:]]+ext4([[:space:]]|$)" "$FSTAB" || {
    echo "Cannot identify ext4 root entry in fstab."
    exit 1
}

grep -qE "(^|[[:space:]])root=PARTUUID=${ROOT_PARTUUID}([[:space:]]|$)" "$CMDLINE" || {
    echo "Root PARTUUID mismatch in cmdline.txt."
    exit 1
}

grep -qE '(^|[[:space:]])rootfstype=ext4([[:space:]]|$)' "$CMDLINE" || {
    echo "Cannot identify rootfstype=ext4."
    exit 1
}

# Preserve original boot configuration.
cp -a "$FSTAB" "$BACKUP/fstab"
cp -a "$CMDLINE" "$BACKUP/cmdline.txt"

# Backup root filesystem.
echo
echo "Backing up root filesystem..."

mkdir -p "$BACKUP/rootfs"

rsync -aHAXx --numeric-ids --info=progress2 \
    --exclude='/dev/***' \
    --exclude='/proc/***' \
    --exclude='/sys/***' \
    --exclude='/run/***' \
    --exclude='/tmp/***' \
    "$ROOT_MNT/" "$BACKUP/rootfs/"

echo
echo "Backup completed: $BACKUP/rootfs"

# Unmount original filesystems.
umount "$BOOT_MNT"
umount "$ROOT_MNT"

echo
echo "WARNING: This will ERASE $ROOT_PART."
read -r -p "Type FORMAT to continue: " answer
[[ "$answer" == "FORMAT" ]] || exit 1

# Format root partition.
echo
echo "Creating F2FS filesystem..."

mkfs.f2fs -f -l rootfs "$ROOT_PART"

# Restore root filesystem.
echo
echo "Restoring filesystem..."

mount -t f2fs "$ROOT_PART" "$ROOT_MNT"

rsync -aHAXx --numeric-ids --info=progress2 \
    "$BACKUP/rootfs/" "$ROOT_MNT/"

# IMPORTANT:
# Recreate directories excluded during backup.
install -d -m 0755 \
    "$ROOT_MNT/dev" \
    "$ROOT_MNT/proc" \
    "$ROOT_MNT/sys" \
    "$ROOT_MNT/run" \
    "$ROOT_MNT/dev/pts" \
    "$ROOT_MNT/dev/shm" \
    "$ROOT_MNT/dev/mqueue" \
    "$ROOT_MNT/run/lock" \
    "$ROOT_MNT/boot/firmware"

install -d -m 1777 "$ROOT_MNT/tmp"

# Update fstab.
sed -i -E \
    "s#^(PARTUUID=${ROOT_PARTUUID}[[:space:]]+/[[:space:]]+)ext4([[:space:]]+)#\\1f2fs\\2#" \
    "$ROOT_MNT/etc/fstab"

# Update boot command line.
mount "$BOOT_PART" "$BOOT_MNT"

sed -i -E \
    's/(^|[[:space:]])rootfstype=ext4([[:space:]]|$)/\1rootfstype=f2fs\2/' \
    "$CMDLINE"

# Verify configuration.
grep -qE "^PARTUUID=${ROOT_PARTUUID}[[:space:]]+/[[:space:]]+f2fs([[:space:]]|$)" "$ROOT_MNT/etc/fstab" || {
    echo "ERROR: fstab verification failed."
    exit 1
}

grep -qE '(^|[[:space:]])rootfstype=f2fs([[:space:]]|$)' "$CMDLINE" || {
    echo "ERROR: cmdline.txt verification failed."
    exit 1
}

# Final checks.
echo
echo "Checking restored directories..."

for dir in dev proc sys run tmp boot/firmware; do
    [[ -d "$ROOT_MNT/$dir" ]] || {
        echo "ERROR: Missing directory: $dir"
        exit 1
    }
done

sync

echo
echo "Migration completed successfully!"
echo
echo "Filesystem: F2FS"
echo "Backup: $BACKUP"
echo
echo "Unmounting filesystems..."
