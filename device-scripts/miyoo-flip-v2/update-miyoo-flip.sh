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

# Step 1: Patch stock boot.img with new kernel/initrd
# Always start from the stock GammaOS boot.img to avoid corruption from
# re-patching an already-patched image (DTB recompilation changes layout).
GAMMAOS_BOOT_IMG="${PROJECT_DIR}/gammaloader/gammaos_core/extracted/boot.img"
if [ ! -f "$GAMMAOS_BOOT_IMG" ]; then
    echo "Error: Stock GammaOS boot.img not found at $GAMMAOS_BOOT_IMG"
    exit 1
fi

echo "==> Step 1: Patching stock boot.img with new kernel + initrd..."

# Re-compress initrd as GZIP (stock boot.img uses gzip ramdisk, not lz4)
INITRD_LZ4="$BOOT_DIR/boot/initrd.lz4"
unlz4 "$INITRD_LZ4" "$WORK/initrd.cpio"
gzip -9 < "$WORK/initrd.cpio" > "$WORK/initrd.gz"
rm -f "$WORK/initrd.cpio"
echo "  initrd.lz4: $(wc -c < "$INITRD_LZ4" | tr -d ' ') bytes -> initrd.gz: $(wc -c < "$WORK/initrd.gz" | tr -d ' ') bytes"

python3 << PYEOF
import struct, shutil, os, hashlib

shutil.copy('${GAMMAOS_BOOT_IMG}', '${WORK}/patched-boot.img')

with open('${WORK}/patched-boot.img', 'r+b') as f:
    header = bytearray(f.read(2048))
    kernel_size = struct.unpack_from('<I', header, 8)[0]
    ramdisk_size = struct.unpack_from('<I', header, 16)[0]
    second_size = struct.unpack_from('<I', header, 24)[0]
    page_size = struct.unpack_from('<I', header, 36)[0]
    recovery_dtbo_size = struct.unpack_from('<I', header, 1632)[0]
    dtb_size_val = struct.unpack_from('<I', header, 1648)[0]

    def pages(size):
        return ((size + page_size - 1) // page_size) * page_size

    kernel_offset = page_size
    ramdisk_offset = kernel_offset + pages(kernel_size)

    with open('${BOOT_DIR}/boot/linux', 'rb') as kf:
        new_kernel = kf.read()
    with open('${WORK}/initrd.gz', 'rb') as rf:
        new_initrd = rf.read()

    if len(new_kernel) > kernel_size:
        print(f"  ERROR: kernel too large! ({len(new_kernel)} > {kernel_size})")
        exit(1)
    if len(new_initrd) > ramdisk_size:
        print(f"  ERROR: initrd too large! ({len(new_initrd)} > {ramdisk_size})")
        exit(1)

    f.seek(kernel_offset)
    f.write(new_kernel)
    if len(new_kernel) < kernel_size:
        f.write(b'\x00' * (kernel_size - len(new_kernel)))
    print(f"  Kernel: {len(new_kernel)} bytes (stock: {kernel_size})")

    f.seek(ramdisk_offset)
    f.write(new_initrd)
    if len(new_initrd) < ramdisk_size:
        f.write(b'\x00' * (ramdisk_size - len(new_initrd)))
    print(f"  Ramdisk: {len(new_initrd)} bytes (stock: {ramdisk_size})")

    new_cmdline = b'label=BATOCERA rootwait loglevel=7 console=tty0 console=ttyFIQ0'
    header[64:64+len(new_cmdline)] = new_cmdline
    header[64+len(new_cmdline):576] = b'\x00' * (512 - len(new_cmdline))
    header[608:1632] = b'\x00' * 1024
    print(f"  Cmdline: {new_cmdline.decode()}")

    rsce_offset = ramdisk_offset + pages(ramdisk_size)
    bootargs_needle = b'mtdparts=spi-nand0:'
    replacement = b'label=BATOCERA loglevel=7'
    search_start = rsce_offset
    patch_count = 0
    while True:
        f.seek(0)
        full_data = f.read()
        ba_idx = full_data.find(bootargs_needle, search_start)
        if ba_idx < 0:
            break
        ba_end = full_data.index(b'\x00', ba_idx)
        old_len = ba_end - ba_idx
        f.seek(ba_idx)
        f.write(replacement + b' ' * (old_len - len(replacement)))
        patch_count += 1
        search_start = ba_idx + old_len
    print(f"  DTB bootargs: patched {patch_count} instance(s)")

    second_offset = rsce_offset
    f.seek(kernel_offset); kernel_data = f.read(kernel_size)
    f.seek(ramdisk_offset); ramdisk_data = f.read(ramdisk_size)
    f.seek(second_offset); second_data = f.read(second_size)
    recovery_dtbo_data = b''
    if recovery_dtbo_size > 0:
        f.seek(second_offset + pages(second_size))
        recovery_dtbo_data = f.read(recovery_dtbo_size)
    dtb_offset = second_offset + pages(second_size) + pages(recovery_dtbo_size)
    f.seek(dtb_offset); dtb_data = f.read(dtb_size_val)

    h = hashlib.sha1()
    h.update(kernel_data); h.update(struct.pack('<I', kernel_size))
    h.update(ramdisk_data); h.update(struct.pack('<I', ramdisk_size))
    h.update(second_data); h.update(struct.pack('<I', second_size))
    h.update(recovery_dtbo_data); h.update(struct.pack('<I', recovery_dtbo_size))
    h.update(dtb_data); h.update(struct.pack('<I', dtb_size_val))
    new_sha = h.digest()

    header[576:596] = new_sha
    header[596:608] = b'\x00' * 12
    f.seek(0)
    f.write(header)
    print(f"  SHA-1: {bytes(header[576:596]).hex()}")
    print(f"  Output: {os.path.getsize('${WORK}/patched-boot.img')} bytes")
PYEOF

# Step 2: Write patched boot.img to SD card
echo ""
echo "==> Step 2: Writing patched boot.img to SD card..."
diskutil unmountDisk force "$DISK" 2>/dev/null || true

# Pad to sector boundary
PATCHEDSIZE=$(wc -c < "$WORK/patched-boot.img" | tr -d ' ')
REMAINDER=$(( PATCHEDSIZE % 512 ))
if [ "$REMAINDER" -ne 0 ]; then
    PAD=$(( 512 - REMAINDER ))
    dd if=/dev/zero bs=1 count=$PAD >> "$WORK/patched-boot.img" 2>/dev/null
fi

dd if="$WORK/patched-boot.img" of="$RDISK" bs=512 seek=51200 conv=notrunc 2>&1
echo "  Written to sector 51200"

# Step 3: Update BATOCERA partition
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
