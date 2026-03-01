#!/usr/bin/env bash
set -euo pipefail

# Update a Trimui Brick SD card WITHOUT touching the SHARE partition.
#
# The Trimui Brick boots via an Android boot.img (containing kernel + initrd)
# at a raw disk offset. The BATOCERA FAT32 partition holds the rootfs squashfs,
# boot config, and firmware signature. This script updates those files.
#
# To also update the kernel/initrd, use the --boot-img flag to write a new
# boot.img to the raw partition.
#
# Usage:
#   sudo ./update-trimui-brick.sh /dev/disk4 [boot.tar.gz or boot-dir]
#
# If no boot source is given, the script looks for the latest boot tarball
# in the build output directory.

DISK="${1:-}"
BOOT_SOURCE="${2:-}"

if [ -z "$DISK" ]; then
    echo "Usage: sudo $0 /dev/diskN [boot.tar.gz | boot-dir]"
    echo ""
    echo "  Updates a Trimui Brick SD card."
    echo "  SHARE partition is completely untouched."
    echo ""
    echo "  boot.tar.gz: A boot tarball from the build"
    echo "  boot-dir:    A directory with boot/, batocera-boot.conf"
    echo ""
    diskutil list external
    exit 1
fi

RDISK="${DISK/disk/rdisk}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Find boot source
if [ -z "$BOOT_SOURCE" ]; then
    BOOT_SOURCE=$(ls -t "${PROJECT_DIR}/output/a133/knulli-"*"_boot.tar.gz" 2>/dev/null | head -1)
    if [ -z "$BOOT_SOURCE" ]; then
        echo "Error: No boot source specified and no build output found."
        echo "  Specify a boot.tar.gz or boot directory as the second argument."
        exit 1
    fi
    echo "Using latest build output: $BOOT_SOURCE"
fi

WORK="/tmp/update-trimui-brick-$$"
rm -rf "$WORK"
mkdir -p "$WORK"

cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

# Prepare boot directory
if [ -d "$BOOT_SOURCE" ]; then
    BOOT_DIR="$BOOT_SOURCE"
elif [ -f "$BOOT_SOURCE" ]; then
    echo "==> Extracting boot tarball..."
    mkdir -p "$WORK/boot-extracted"
    tar xzf "$BOOT_SOURCE" -C "$WORK/boot-extracted"
    BOOT_DIR="$WORK/boot-extracted"
else
    echo "Error: Boot source not found: $BOOT_SOURCE"
    exit 1
fi

# Check for rootfs (batocera or batocera.update)
ROOTFS=""
if [ -f "$BOOT_DIR/boot/batocera" ]; then
    ROOTFS="boot/batocera"
elif [ -f "$BOOT_DIR/boot/batocera.update" ]; then
    ROOTFS="boot/batocera.update"
fi

# Check for boot.img (kernel + initrd)
BOOTIMG=""
if [ -f "$BOOT_DIR/partitions/boot.img" ]; then
    BOOTIMG="$BOOT_DIR/partitions/boot.img"
fi

echo ""
echo "==> Update Trimui Brick"
echo "    Target: $DISK"
if [ -n "$ROOTFS" ]; then
    echo "    Rootfs:   $BOOT_DIR/$ROOTFS ($(wc -c < "$BOOT_DIR/$ROOTFS" | tr -d ' ') bytes)"
fi
if [ -n "$BOOTIMG" ]; then
    echo "    boot.img: $BOOTIMG ($(wc -c < "$BOOTIMG" | tr -d ' ') bytes)"
else
    echo "    boot.img: UNTOUCHED (not in tarball)"
fi
echo "    SHARE:    UNTOUCHED"
echo ""

# Step 1: Write boot.img to raw partition if present
if [ -n "$BOOTIMG" ]; then
    echo "==> Writing boot.img to raw partition..."
    diskutil unmountDisk "$DISK" 2>/dev/null || true

    # Find boot partition offset from GPT
    BOOT_SECTOR=$(python3 -c "
import struct
with open('$RDISK', 'rb') as f:
    f.seek(2 * 512)
    entries = f.read(128 * 128)
for i in range(128):
    e = entries[i*128:(i+1)*128]
    if e[:16] == b'\x00' * 16: break
    name = e[56:128].decode('utf-16-le').rstrip('\x00')
    if name == 'boot':
        print(struct.unpack_from('<Q', e, 32)[0])
        break
" 2>/dev/null)

    if [ -z "$BOOT_SECTOR" ]; then
        echo "  Warning: Could not find boot partition in GPT, using default offset 73728"
        BOOT_SECTOR=73728
    fi

    echo "    Writing to sector $BOOT_SECTOR"
    dd if="$BOOTIMG" of="$RDISK" bs=512 seek="$BOOT_SECTOR" conv=notrunc 2>&1
fi

# Step 2: Update BATOCERA partition
echo "==> Finding BATOCERA partition..."

BATOCERA_PART=""
for i in s1 s2 s3 s4 s5 s6 s7 s8 s9 s10; do
    TESTPART="${DISK}${i}"
    if diskutil info "$TESTPART" 2>/dev/null | grep -qi "BATOCERA"; then
        BATOCERA_PART="$TESTPART"
        break
    fi
done

if [ -z "$BATOCERA_PART" ]; then
    # Try reading GPT to find BATOCERA partition by name
    diskutil unmountDisk "$DISK" 2>/dev/null || true
    sleep 1

    BATOCERA_PART=$(python3 -c "
import struct
with open('$RDISK', 'rb') as f:
    f.seek(2 * 512)
    entries = f.read(128 * 128)
for i in range(128):
    e = entries[i*128:(i+1)*128]
    if e[:16] == b'\x00' * 16: break
    name = e[56:128].decode('utf-16-le').rstrip('\x00')
    if name == 'BATOCERA':
        print('${DISK}s' + str(i + 1))
        break
" 2>/dev/null)
fi

if [ -z "$BATOCERA_PART" ]; then
    echo "Error: BATOCERA partition not found on $DISK"
    exit 1
fi

echo "    BATOCERA partition: $BATOCERA_PART"

# Mount BATOCERA partition
sleep 1
diskutil unmountDisk "$DISK" 2>/dev/null || true
sleep 1
diskutil mount "$BATOCERA_PART"
BATOCERA_MNT="/Volumes/BATOCERA"

if [ ! -d "$BATOCERA_MNT" ]; then
    echo "Error: BATOCERA not mounted at $BATOCERA_MNT"
    exit 1
fi

# Update boot files
echo ""
echo "==> Updating BATOCERA partition..."
mkdir -p "$BATOCERA_MNT/boot"

for f in batocera.board firmware.sig; do
    if [ -f "$BOOT_DIR/boot/$f" ]; then
        cp "$BOOT_DIR/boot/$f" "$BATOCERA_MNT/boot/"
        echo "    boot/$f"
    fi
done

# Rootfs
if [ -n "$ROOTFS" ]; then
    echo "==> Updating rootfs (this may take a moment)..."
    cp "$BOOT_DIR/$ROOTFS" "$BATOCERA_MNT/boot/batocera"
    echo "    boot/batocera"
fi

# Config files
if [ -f "$BOOT_DIR/batocera-boot.conf" ]; then
    cp "$BOOT_DIR/batocera-boot.conf" "$BATOCERA_MNT/"
    echo "    batocera-boot.conf"
fi

# Boot logo
if [ -f "$BOOT_DIR/bootlogo.bmp" ]; then
    cp "$BOOT_DIR/bootlogo.bmp" "$BATOCERA_MNT/"
    echo "    bootlogo.bmp"
fi

# Clean up files that can interfere with boot
echo ""
echo "==> Cleaning up boot partition..."
# Remove macOS resource fork files (._*) that can confuse Linux init scripts
dot_clean "$BATOCERA_MNT" 2>/dev/null || true
find "$BATOCERA_MNT" -name '._*' -delete 2>/dev/null || true
find "$BATOCERA_MNT" -name '.DS_Store' -delete 2>/dev/null || true
# Remove restart.flag that can cause boot loops
rm -f "$BATOCERA_MNT/restart.flag"
# Remove stale overlay so rootfs boots clean from the new squashfs
if [ -f "$BATOCERA_MNT/boot/overlay" ]; then
    echo "    Removing stale overlay (rootfs will boot clean)"
    rm -f "$BATOCERA_MNT/boot/overlay"
fi
echo "    Done"

echo ""
echo "==> Syncing and unmounting..."
sync
diskutil unmountDisk "$DISK"

echo ""
echo "==> Update complete!"
echo ""
echo "    BATOCERA: updated with rootfs and boot config"
if [ -n "$BOOTIMG" ]; then
    echo "    boot.img: updated (kernel + initrd)"
else
    echo "    boot.img: untouched (kernel + initrd unchanged)"
fi
echo "    SHARE:    untouched (your bios/roms are safe)"
echo ""
echo "    Insert the card and boot your Trimui Brick."
