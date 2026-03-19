#!/usr/bin/env bash
set -euo pipefail

# Update a Miyoo Flip SD card WITHOUT touching the SHARE partition.
#
# This re-patches boot.img with the new kernel/initrd and updates the
# BATOCERA partition with new rootfs and boot files. SHARE is untouched.
#
# Usage:
#   sudo ./update-miyoo-flip.sh /dev/disk4 [boot.tar.gz or boot-dir]
#
# If no boot source is given, the script looks for the latest boot tarball
# in the build output directory.

DISK="${1:-}"
BOOT_SOURCE="${2:-}"

if [ -z "$DISK" ]; then
    echo "Usage: sudo $0 /dev/diskN [boot.tar.gz | boot-dir]"
    echo ""
    echo "  Updates a Miyoo Flip SD card."
    echo "  SHARE partition is completely untouched."
    echo ""
    echo "  boot.tar.gz: A boot tarball from the build"
    echo "  boot-dir:    A directory with boot/, extlinux/, batocera-boot.conf"
    echo ""
    diskutil list external
    exit 1
fi

RDISK="${DISK/disk/rdisk}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOARD_DIR="${PROJECT_DIR}/board/batocera/rockchip/rk3566/miyoo-flip"
PATCH_BOOTIMG="${BOARD_DIR}/patch_bootimg.py"

if [ ! -f "$PATCH_BOOTIMG" ]; then
    echo "Error: patch_bootimg.py not found at $PATCH_BOOTIMG"
    exit 1
fi

# Find boot source
if [ -z "$BOOT_SOURCE" ]; then
    BOOT_SOURCE=$(ls -t "${PROJECT_DIR}/output/rk3566-bsp/knulli-"*"_boot.tar.gz" 2>/dev/null | head -1)
    if [ -z "$BOOT_SOURCE" ]; then
        echo "Error: No boot source specified and no build output found."
        echo "  Specify a boot.tar.gz or boot directory as the second argument."
        exit 1
    fi
    echo "Using latest build output: $BOOT_SOURCE"
fi

WORK="/tmp/update-miyoo-flip-$$"
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

# Validate boot directory
for f in boot/linux boot/initrd.lz4; do
    if [ ! -f "$BOOT_DIR/$f" ]; then
        echo "Error: Missing $f in boot directory"
        exit 1
    fi
done

# Check for rootfs (batocera or batocera.update)
ROOTFS=""
if [ -f "$BOOT_DIR/boot/batocera" ]; then
    ROOTFS="boot/batocera"
elif [ -f "$BOOT_DIR/boot/batocera.update" ]; then
    ROOTFS="boot/batocera.update"
fi

echo ""
echo "==> Update Miyoo Flip"
echo "    Target: $DISK"
echo "    Kernel: $BOOT_DIR/boot/linux ($(wc -c < "$BOOT_DIR/boot/linux" | tr -d ' ') bytes)"
echo "    Initrd: $BOOT_DIR/boot/initrd.lz4 ($(wc -c < "$BOOT_DIR/boot/initrd.lz4" | tr -d ' ') bytes)"
if [ -n "$ROOTFS" ]; then
    echo "    Rootfs: $BOOT_DIR/$ROOTFS ($(wc -c < "$BOOT_DIR/$ROOTFS" | tr -d ' ') bytes)"
fi
echo "    SHARE:  UNTOUCHED"
echo "    NOTE:   Bootloader (idbloader/uboot) is NOT updated by this script."
echo "            Use write-miyoo-flip-patched-bootimg.sh for a full reflash."
echo ""

# Step 1: Read current boot.img from SD card
echo "==> Step 1: Reading current boot.img from SD card..."
diskutil unmountDisk "$DISK"

# Read boot.img header to calculate size
dd if="$RDISK" bs=2048 skip=$((51200 * 512 / 2048)) count=1 of="$WORK/boot-header.bin" 2>/dev/null

BOOTIMG_DATA_SIZE=$(python3 -c "
import struct
with open('$WORK/boot-header.bin', 'rb') as f:
    h = f.read(2048)
if h[:8] != b'ANDROID!':
    print('ERROR', file=__import__('sys').stderr)
    exit(1)
ks = struct.unpack_from('<I', h, 8)[0]
rs = struct.unpack_from('<I', h, 16)[0]
ss = struct.unpack_from('<I', h, 24)[0]
ps = struct.unpack_from('<I', h, 36)[0]
rds = struct.unpack_from('<I', h, 1632)[0]
ds = struct.unpack_from('<I', h, 1648)[0]
def p(s): return ((s + ps - 1) // ps) * ps
# Data size + 2048 bytes for X.509 signature
total = ps + p(ks) + p(rs) + p(ss) + p(rds) + p(ds) + 2048
print(total)
")

if [ -z "$BOOTIMG_DATA_SIZE" ] || [ "$BOOTIMG_DATA_SIZE" = "ERROR" ]; then
    echo "Error: No valid boot.img found at sector 51200."
    echo "  Is this a Miyoo Flip SD card?"
    exit 1
fi

BOOTIMG_SECTORS=$(( (BOOTIMG_DATA_SIZE + 511) / 512 ))
echo "  boot.img: $BOOTIMG_DATA_SIZE bytes ($BOOTIMG_SECTORS sectors)"

dd if="$RDISK" bs=512 skip=51200 count=$BOOTIMG_SECTORS of="$WORK/current-boot.img" 2>/dev/null
echo "  Read from sector 51200"

# Step 2: Re-patch boot.img with new kernel/initrd
echo ""
echo "==> Step 2: Patching boot.img with new kernel + initrd..."
python3 "$PATCH_BOOTIMG" \
    --stock-bootimg "$WORK/current-boot.img" \
    --kernel "$BOOT_DIR/boot/linux" \
    --initrd "$BOOT_DIR/boot/initrd.lz4" \
    --output "$WORK/patched-boot.img"

# Step 3: Write patched boot.img back to SD card
echo ""
echo "==> Step 3: Writing patched boot.img to SD card..."
diskutil unmountDisk "$DISK" 2>/dev/null || true

# Pad to sector boundary
PATCHEDSIZE=$(wc -c < "$WORK/patched-boot.img" | tr -d ' ')
REMAINDER=$(( PATCHEDSIZE % 512 ))
if [ "$REMAINDER" -ne 0 ]; then
    PAD=$(( 512 - REMAINDER ))
    dd if=/dev/zero bs=1 count=$PAD >> "$WORK/patched-boot.img" 2>/dev/null
fi

dd if="$WORK/patched-boot.img" of="$RDISK" bs=512 seek=51200 conv=notrunc 2>&1
echo "  Written to sector 51200"

# Step 4: Update BATOCERA partition
echo ""
echo "==> Step 4: Updating BATOCERA partition..."

# Find the BATOCERA partition
BATOCERA_PART=""
for i in s8 s9 s10; do
    TESTPART="${DISK}${i}"
    if diskutil info "$TESTPART" 2>/dev/null | grep -qi "BATOCERA"; then
        BATOCERA_PART="$TESTPART"
        break
    fi
done

if [ -z "$BATOCERA_PART" ]; then
    # Try mounting by label
    sleep 1
    diskutil unmountDisk "$DISK" 2>/dev/null || true
    sleep 1

    # Read GPT to find BATOCERA partition
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

echo "  BATOCERA partition: $BATOCERA_PART"

sleep 1
diskutil mount "$BATOCERA_PART"
BATOCERA_MNT="/Volumes/BATOCERA"

if [ ! -d "$BATOCERA_MNT" ]; then
    echo "Error: BATOCERA not mounted at $BATOCERA_MNT"
    exit 1
fi

# Update boot files
echo "  Updating boot files..."
for f in linux initrd.lz4 batocera.board; do
    if [ -f "$BOOT_DIR/boot/$f" ]; then
        cp "$BOOT_DIR/boot/$f" "$BATOCERA_MNT/boot/"
        echo "    boot/$f"
    fi
done

# DTB
for dtb in "$BOOT_DIR"/boot/*.dtb; do
    if [ -f "$dtb" ]; then
        cp "$dtb" "$BATOCERA_MNT/boot/"
        echo "    boot/$(basename "$dtb")"
    fi
done

# Rootfs
if [ -n "$ROOTFS" ]; then
    echo "  Updating rootfs (this may take a moment)..."
    cp "$BOOT_DIR/$ROOTFS" "$BATOCERA_MNT/boot/batocera"
    echo "    boot/batocera"
fi

# Config files
if [ -f "$BOOT_DIR/batocera-boot.conf" ]; then
    cp "$BOOT_DIR/batocera-boot.conf" "$BATOCERA_MNT/"
    echo "    batocera-boot.conf"
fi

# Extlinux
if [ -d "$BOOT_DIR/extlinux" ]; then
    mkdir -p "$BATOCERA_MNT/extlinux"
    cp "$BOOT_DIR/extlinux/"* "$BATOCERA_MNT/extlinux/"
    echo "    extlinux/"
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
echo "    boot.img: re-patched with new kernel + initrd"
echo "    BATOCERA: updated with new rootfs and boot files"
echo "    SHARE:    untouched (your bios/roms are safe)"
echo ""
echo "    Insert the card and boot your Miyoo Flip."
