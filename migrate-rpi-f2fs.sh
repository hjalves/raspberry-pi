
#!/usr/bin/env bash
set -Eeuo pipefail

# Raspberry Pi ext4 -> F2FS migration
# Usage: sudo ./migrate-rpi-f2fs.sh /dev/mmcblk0 [backup-directory]

DISK="${1:-}"
BACKUP_BASE="${2:-$PWD}"
MOUNT_BASE="/mnt/rpi-f2fs-migration"

if [[ $EUID -ne 0 ]]; then
    echo "Run this script as root."
    exit 1
fi

if [[ -z "$DISK" || ! -b "$DISK" ]]; then
    echo "Usage: $0 /dev/mmcblk0 [backup-directory]"
    exit 1
fi

for cmd in rsync mkfs.f2fs blkid mount umount lsblk; do
    command -v "$cmd" >/dev/null || {
        echo "Missing dependency: $cmd"
        exit 1
    }
done

DISK=$(readlink -f "$DISK")

# Support both /dev/mmcblk0 and /dev/sda naming conventions.
if [[ "$DISK" =~ [0-9]$ ]]; then
    BOOT_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    BOOT_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

[[ -b "$BOOT_PART" && -b "$ROOT_PART" ]] || {
    echo "Expected partitions were not found."
    exit 1
}

BOOT_TYPE=$(blkid -s TYPE -o value "$BOOT_PART")
ROOT_TYPE=$(blkid -s TYPE -o value "$ROOT_PART")

[[ "$BOOT_TYPE" == "vfat" ]] || {
    echo "Expected FAT32 boot partition, found: $BOOT_TYPE"
    exit 1
}

[[ "$ROOT_TYPE" == "ext4" ]] || {
    echo "Expected ext4 root partition, found: $ROOT_TYPE"
    exit 1
}

# Never operate on mounted partitions.
for part in "$BOOT_PART" "$ROOT_PART"; do
    if findmnt -rn -S "$part" >/dev/null; then
        echo "Partition is already mounted: $part"
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

echo
echo "Target disk:    $DISK"
echo "Boot partition: $BOOT_PART"
echo "Root partition: $ROOT_PART"
echo "Backup:         $BACKUP"
echo

lsblk "$DISK"

echo
read -r -p "Continue with this SD card? Type YES: " answer
[[ "$answer" == "YES" ]] || exit 1

# Mount original filesystem.
mount "$ROOT_PART" "$ROOT_MNT"
mkdir -p "$BOOT_MNT"
mount "$BOOT_PART" "$BOOT_MNT"

# Validate boot configuration.
FSTAB="$ROOT_MNT/etc/fstab"
CMDLINE="$BOOT_MNT/cmdline.txt"

[[ -f "$FSTAB" && -f "$CMDLINE" ]] || {
    echo "Missing fstab or cmdline.txt."
    exit 1
}

grep -qE "^PARTUUID=${ROOT_PARTUUID}[[:space:]]+/[[:space:]]+ext4([[:space:]]|$)" "$FSTAB" || {
    echo "Could not identify the expected ext4 root entry in fstab."
    exit 1
}

grep -qE "(^|[[:space:]])root=PARTUUID=${ROOT_PARTUUID}([[:space:]]|$)" "$CMDLINE" || {
    echo "cmdline.txt does not reference the expected root partition."
    exit 1
}

grep -qE '(^|[[:space:]])rootfstype=ext4([[:space:]]|$)' "$CMDLINE" || {
    echo "Could not identify rootfstype=ext4 in cmdline.txt."
    exit 1
}

# Backup.
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

# Unmount before formatting.
umount "$BOOT_MNT"
umount "$ROOT_MNT"

echo
echo "IMPORTANT: The next operation will ERASE $ROOT_PART."
read -r -p "Type FORMAT to proceed: " answer
[[ "$answer" == "FORMAT" ]] || exit 1

# Format.
echo
echo "Creating F2FS filesystem..."

mkfs.f2fs -f -l rootfs "$ROOT_PART"

# Restore.
echo
echo "Restoring filesystem..."

mount -t f2fs "$ROOT_PART" "$ROOT_MNT"

rsync -aHAXx --numeric-ids --info=progress2 \
    "$BACKUP/rootfs/" "$ROOT_MNT/"

# Update fstab.
sed -i -E \
    "s#^(PARTUUID=${ROOT_PARTUUID}[[:space:]]+/[[:space:]]+)ext4([[:space:]]+)#\\1f2fs\\2#" \
    "$FSTAB"

# Update boot configuration.
mount "$BOOT_PART" "$BOOT_MNT"

sed -i -E \
    's/(^|[[:space:]])rootfstype=ext4([[:space:]]|$)/\1rootfstype=f2fs\2/' \
    "$CMDLINE"

# Verify configuration.
grep -qE "^PARTUUID=${ROOT_PARTUUID}[[:space:]]+/[[:space:]]+f2fs([[:space:]]|$)" "$FSTAB" || {
    echo "ERROR: fstab verification failed."
    exit 1
}

grep -qE '(^|[[:space:]])rootfstype=f2fs([[:space:]]|$)' "$CMDLINE" || {
    echo "ERROR: cmdline.txt verification failed."
    exit 1
}

sync

echo
echo "Migration completed successfully!"
echo
echo "Root filesystem: F2FS"
echo "Backup retained: $BACKUP"
echo
echo "Unmounting filesystems..."
