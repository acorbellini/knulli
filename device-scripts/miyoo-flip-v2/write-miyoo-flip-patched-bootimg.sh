#!/usr/bin/env bash
set -euo pipefail

# Patch stock GammaOS boot.img in-place with custom kernel, initrd, and cmdline.
#
# Replaces kernel, ramdisk (initrd), cmdline, and DTB bootargs in the
# stock boot.img while keeping exact file size, offsets, header sizes,
# and the appended X.509 signature intact.
#
# CRITICAL: boot_android verifies the SHA-1 hash in the boot.img header.
# After patching any data section, we MUST recalculate the SHA-1 hash
# using the AOSP v2 formula, or boot_android will reject the boot.img.
#
# boot_android will:
#   1. Verify SHA-1 hash (recalculated after patching)
#   2. Accept boot.img (X.509 signature at expected offset)
#   3. Parse RSCE, show logo.bmp → DISPLAY INITIALIZED
#   4. Boot custom kernel + cmdline + initrd
#   5. Init finds BATOCERA partition → full boot
#
# Usage: sudo ./write-miyoo-flip-patched-bootimg.sh /dev/disk4

DISK="${1:-}"
if [ -z "$DISK" ]; then
    echo "Usage: sudo $0 /dev/diskN"
    diskutil list external
    exit 1
fi

RDISK="${DISK/disk/rdisk}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

GAMMAOS_64MB="${SCRIPT_DIR}/gammaos-dump/first-64mb.bin"
GAMMAOS_BOOT_IMG="${PROJECT_DIR}/gammaloader/gammaos_core/extracted/boot.img"
BOARD_DIR="${PROJECT_DIR}/board/batocera/rockchip/rk3566/miyoo-flip"

# Find the latest boot tarball
BOOT_TARBALL=$(ls -t "${PROJECT_DIR}/output/rk3566-bsp/knulli-rk3568-miyoo-flip-gladiator-ii-"*"_boot.tar.gz" 2>/dev/null | head -1)

for f in "$GAMMAOS_64MB" "$GAMMAOS_BOOT_IMG" "$BOOT_TARBALL"; do
    if [ ! -f "$f" ]; then
        echo "Error: $f not found"
        exit 1
    fi
done

echo "==> Patched Stock boot.img"
echo "    Target: $DISK"
echo "    Method: In-place kernel + ramdisk + cmdline replacement"
echo ""

WORK="/tmp/patched-miyoo-flip-bootimg"
rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK"

# Extract boot components
echo "==> Extracting boot components..."
tar xzf "$BOOT_TARBALL" boot/linux boot/initrd.lz4 boot/batocera.board boot/batocera.update batocera-boot.conf

# Re-compress initrd as GZIP (stock boot.img uses gzip ramdisk, not lz4)
echo "==> Re-compressing initrd as GZIP (matching stock ramdisk format)..."
unlz4 boot/initrd.lz4 boot/initrd.cpio
gzip -9 < boot/initrd.cpio > boot/initrd.gz
echo "  initrd.lz4: $(wc -c < boot/initrd.lz4 | tr -d ' ') bytes"
echo "  initrd.gz:  $(wc -c < boot/initrd.gz | tr -d ' ') bytes"

# Patch the stock boot.img with custom components
echo "==> Patching stock boot.img with kernel + initrd + cmdline..."
python3 << PYEOF
import struct, shutil, os, hashlib

# Copy stock boot.img (preserves signature at end)
shutil.copy('${GAMMAOS_BOOT_IMG}', 'patched-boot.img')

with open('patched-boot.img', 'r+b') as f:
    # Read header
    header = bytearray(f.read(2048))
    kernel_size = struct.unpack_from('<I', header, 8)[0]
    ramdisk_size = struct.unpack_from('<I', header, 16)[0]
    second_size = struct.unpack_from('<I', header, 24)[0]
    page_size = struct.unpack_from('<I', header, 36)[0]
    recovery_dtbo_size = struct.unpack_from('<I', header, 1632)[0]
    dtb_size_val = struct.unpack_from('<I', header, 1648)[0]

    def pages(size):
        return ((size + page_size - 1) // page_size) * page_size

    # Calculate offsets (page-aligned layout)
    kernel_offset = page_size
    ramdisk_offset = kernel_offset + pages(kernel_size)

    # Read new components
    with open('boot/linux', 'rb') as kf:
        new_kernel = kf.read()
    with open('boot/initrd.gz', 'rb') as rf:
        new_initrd = rf.read()

    print(f"  --- Kernel ---")
    print(f"  Stock:  {kernel_size} bytes")
    print(f"  New: {len(new_kernel)} bytes")

    if len(new_kernel) > kernel_size:
        print(f"  ERROR: custom kernel too large! ({len(new_kernel) - kernel_size} bytes over)")
        exit(1)

    print(f"  --- Ramdisk ---")
    print(f"  Stock:  {ramdisk_size} bytes")
    print(f"  New: {len(new_initrd)} bytes")

    if len(new_initrd) > ramdisk_size:
        print(f"  ERROR: custom initrd too large! ({len(new_initrd) - ramdisk_size} bytes over)")
        exit(1)

    # 1. Patch kernel (at kernel_offset, zero-pad to stock kernel_size)
    f.seek(kernel_offset)
    f.write(new_kernel)
    if len(new_kernel) < kernel_size:
        f.write(b'\x00' * (kernel_size - len(new_kernel)))
    print(f"  Kernel patched at offset {kernel_offset}, zero-padded to {kernel_size}")

    # 2. Patch ramdisk (at ramdisk_offset, zero-pad to stock ramdisk_size)
    # GZIP decompressor reads headers and stops at end of valid data,
    # so trailing zeros are harmless.
    f.seek(ramdisk_offset)
    f.write(new_initrd)
    if len(new_initrd) < ramdisk_size:
        f.write(b'\x00' * (ramdisk_size - len(new_initrd)))
    print(f"  Ramdisk patched at offset {ramdisk_offset}, zero-padded to {ramdisk_size}")

    # 3. Patch cmdline in header bytearray (written to file at end with SHA-1)
    new_cmdline = b'label=BATOCERA rootwait loglevel=7 console=tty0 console=ttyFIQ0'
    header[64:64+len(new_cmdline)] = new_cmdline
    header[64+len(new_cmdline):576] = b'\x00' * (512 - len(new_cmdline))
    header[608:1632] = b'\x00' * 1024  # Clear extra_cmdline (stock Android params)
    print(f"  Cmdline patched: {new_cmdline.decode()}")

    # 4. Patch DTB bootargs inside RSCE and v2 DTB
    # boot_android may use DTB chosen/bootargs instead of boot.img cmdline.
    # We need label=BATOCERA in the DTB bootargs for the init script.
    # Replace the useless mtdparts= section with label=BATOCERA.
    # There are TWO DTBs in boot.img: one in RSCE, one in the v2 DTB field.
    rsce_offset = ramdisk_offset + pages(ramdisk_size)

    bootargs_needle = b'mtdparts=spi-nand0:'
    replacement = b'label=BATOCERA loglevel=7'
    search_start = rsce_offset
    patch_count = 0

    print(f"  --- DTB Bootargs ---")
    while True:
        f.seek(0)
        full_data = f.read()
        ba_idx = full_data.find(bootargs_needle, search_start)
        if ba_idx < 0:
            break
        ba_end = full_data.index(b'\x00', ba_idx)
        mtdparts_len = ba_end - ba_idx
        padded_replacement = replacement + b' ' * (mtdparts_len - len(replacement))
        f.seek(ba_idx)
        f.write(padded_replacement)
        patch_count += 1
        print(f"  Patched mtdparts at offset {ba_idx} ({mtdparts_len} chars)")
        search_start = ba_idx + len(padded_replacement)

    if patch_count == 0:
        print(f"  WARNING: Could not find mtdparts in any DTB!")
    else:
        print(f"  Patched {patch_count} DTB(s)")

    # 5. CRITICAL: Recalculate SHA-1 hash in header
    # boot_android verifies this hash (AOSP v2 formula).
    # Without updating it after patching, boot_android rejects the boot.img.
    f.seek(kernel_offset)
    kernel_data = f.read(kernel_size)
    f.seek(ramdisk_offset)
    ramdisk_data = f.read(ramdisk_size)
    second_offset = ramdisk_offset + pages(ramdisk_size)
    f.seek(second_offset)
    second_data = f.read(second_size)
    recovery_dtbo_data = b''
    if recovery_dtbo_size > 0:
        f.seek(second_offset + pages(second_size))
        recovery_dtbo_data = f.read(recovery_dtbo_size)
    dtb_offset = second_offset + pages(second_size) + pages(recovery_dtbo_size)
    f.seek(dtb_offset)
    dtb_data = f.read(dtb_size_val)

    h = hashlib.sha1()
    h.update(kernel_data)
    h.update(struct.pack('<I', kernel_size))
    h.update(ramdisk_data)
    h.update(struct.pack('<I', ramdisk_size))
    h.update(second_data)
    h.update(struct.pack('<I', second_size))
    h.update(recovery_dtbo_data)
    h.update(struct.pack('<I', recovery_dtbo_size))
    h.update(dtb_data)
    h.update(struct.pack('<I', dtb_size_val))
    new_sha = h.digest()

    old_sha = bytes(header[576:596])
    header[576:596] = new_sha
    header[596:608] = b'\x00' * 12
    f.seek(0)
    f.write(header)
    print(f"  --- SHA-1 Hash ---")
    print(f"  Old: {old_sha.hex()}")
    print(f"  New: {new_sha.hex()}")
    print(f"  UPDATED in header!")

    print(f"  --- Header ---")
    print(f"  Size fields: UNCHANGED (kernel_size={kernel_size}, ramdisk_size={ramdisk_size})")

print(f"  Output: patched-boot.img ({os.path.getsize('patched-boot.img')} bytes)")
print(f"  File size matches stock: {os.path.getsize('patched-boot.img') == os.path.getsize('${GAMMAOS_BOOT_IMG}')}")
PYEOF

BOOT_IMG="${WORK}/patched-boot.img"

echo ""
echo "==> Unmounting..."
diskutil unmountDisk force "$DISK"

echo "==> Writing GammaOS first 64MB (GPT + bootloader)..."
dd if="$GAMMAOS_64MB" of="$RDISK" bs=1048576 conv=notrunc 2>&1

echo "==> Writing updated idbloader (DDR V1.23) at sector 64..."
diskutil unmountDisk force "$DISK" 2>/dev/null || true
dd if="${BOARD_DIR}/idbloader.img" of="$RDISK" bs=512 seek=64 conv=notrunc 2>&1

echo "==> Writing updated uboot.img (BL31 V1.44) at sector 16384..."
diskutil unmountDisk force "$DISK" 2>/dev/null || true
dd if="${BOARD_DIR}/uboot.img" of="$RDISK" bs=512 seek=16384 conv=notrunc 2>&1

echo "==> Writing patched boot.img to sector 51200..."
diskutil unmountDisk force "$DISK" 2>/dev/null || true
# Pad boot.img to 512-byte boundary (rdisk requires sector-aligned writes)
BOOTIMG_SIZE=$(wc -c < "$BOOT_IMG" | tr -d ' ')
REMAINDER=$(( BOOTIMG_SIZE % 512 ))
if [ "$REMAINDER" -ne 0 ]; then
    PAD=$(( 512 - REMAINDER ))
    echo "  Padding boot.img by $PAD bytes to align to 512-byte sector boundary"
    dd if=/dev/zero bs=1 count=$PAD >> "$BOOT_IMG" 2>/dev/null
fi
dd if="$BOOT_IMG" of="$RDISK" bs=512 seek=51200 conv=notrunc 2>&1

# Write GPT directly using Python (sgdisk fails on this disk's corrupt backup GPT)
DISK_SECTORS=$(diskutil info "$DISK" | grep -oE 'exactly [0-9]+' | awk '{print $2}')
if [ -z "$DISK_SECTORS" ]; then
    echo "ERROR: Could not determine disk size!"
    diskutil info "$DISK" | grep -i size
    exit 1
fi
echo ""
diskutil unmountDisk force "$DISK" 2>/dev/null || true
echo "==> Writing GPT partition table directly..."
python3 << PYEOF
import struct, binascii, uuid
DISK = '${RDISK}'
DISK_SECTORS = ${DISK_SECTORS}
with open(DISK, 'rb') as f:
    f.seek(2 * 512)
    existing_entries = f.read(128 * 128)
gammaos_entries = []
for i in range(7):
    entry = existing_entries[i*128:(i+1)*128]
    if entry[:16] == b'\x00' * 16: break
    gammaos_entries.append(bytearray(entry))
print(f"  Preserved {len(gammaos_entries)} GammaOS partitions")
MSBASIC_GUID = bytes.fromhex('A2A0D0EB' + 'E5B9' + '3344' + '87C0' + '68B6B72699C7')
LINUX_GUID = bytes.fromhex('AF3DC60F' + '8384' + '7247' + '8E79' + '3D69D8477DE4')
def make_entry(tguid, first, last, name):
    e = bytearray(128)
    e[0:16] = tguid
    e[16:32] = uuid.uuid4().bytes_le
    struct.pack_into('<Q', e, 32, first)
    struct.pack_into('<Q', e, 40, last)
    nb = name.encode('utf-16-le')[:72]
    e[56:56+len(nb)] = nb
    return e
BATOCERA_START, BATOCERA_SIZE = 155648, 8388608
SHARE_START = BATOCERA_START + BATOCERA_SIZE + 2048
SHARE_LAST = DISK_SECTORS - 34  # fill remaining disk
entries = bytearray(128 * 128)
for i, e in enumerate(gammaos_entries):
    entries[i*128:(i+1)*128] = e
entries[7*128:8*128] = make_entry(MSBASIC_GUID, BATOCERA_START, BATOCERA_START+BATOCERA_SIZE-1, 'BATOCERA')
entries[8*128:9*128] = make_entry(MSBASIC_GUID, SHARE_START, SHARE_LAST, 'SHARE')
entries_crc = binascii.crc32(bytes(entries)) & 0xFFFFFFFF
LAST_USABLE = DISK_SECTORS - 34
DISK_GUID = bytes.fromhex('23000000' + '0000' + '4C4A' + '8000' + '699000005ABB')
def make_hdr(my_lba, alt_lba, entries_lba):
    h = bytearray(512)
    h[0:8] = b'EFI PART'
    struct.pack_into('<I', h, 8, 0x00010000)
    struct.pack_into('<I', h, 12, 92)
    struct.pack_into('<Q', h, 24, my_lba)
    struct.pack_into('<Q', h, 32, alt_lba)
    struct.pack_into('<Q', h, 40, 34)
    struct.pack_into('<Q', h, 48, LAST_USABLE)
    h[56:72] = DISK_GUID
    struct.pack_into('<Q', h, 72, entries_lba)
    struct.pack_into('<I', h, 80, 128)
    struct.pack_into('<I', h, 84, 128)
    struct.pack_into('<I', h, 88, entries_crc)
    crc = binascii.crc32(bytes(h[:92])) & 0xFFFFFFFF
    struct.pack_into('<I', h, 16, crc)
    return h
with open(DISK, 'r+b') as f:
    f.seek(512); f.write(make_hdr(1, DISK_SECTORS-1, 2))
    f.seek(2*512); f.write(entries)
    f.seek((DISK_SECTORS-33)*512); f.write(entries)
    f.seek((DISK_SECTORS-1)*512); f.write(make_hdr(DISK_SECTORS-1, 1, DISK_SECTORS-33))
print(f"  BATOCERA: sectors {BATOCERA_START}-{BATOCERA_START+BATOCERA_SIZE-1}")
print(f"  SHARE:    sectors {SHARE_START}-{SHARE_LAST}")
print(f"  GPT written (primary + backup)")
PYEOF

echo ""
echo "==> Formatting BATOCERA as FAT32..."
sleep 2
diskutil unmountDisk "$DISK"
newfs_msdos -F 32 -v BATOCERA "${RDISK}s8" 2>&1

echo "==> Mounting BATOCERA..."
sleep 1
diskutil mount "${DISK}s8"

BATOCERA_MNT="/Volumes/BATOCERA"
if [ ! -d "$BATOCERA_MNT" ]; then
    echo "Error: BATOCERA not mounted"
    exit 1
fi

echo "==> Copying boot files to BATOCERA..."
mkdir -p "${BATOCERA_MNT}/boot"
mkdir -p "${BATOCERA_MNT}/extlinux"

cp boot/linux "${BATOCERA_MNT}/boot/"
# Use the stock DTB from the RSCE (already in boot.img)
cp "${SCRIPT_DIR}/gammaos-core-dtb.dtb" "${BATOCERA_MNT}/boot/rk3566-miyoo-flip.dtb"
cp boot/batocera.board "${BATOCERA_MNT}/boot/"
cp batocera-boot.conf "${BATOCERA_MNT}/"
cp boot/initrd.lz4 "${BATOCERA_MNT}/boot/"

cat > "${BATOCERA_MNT}/extlinux/extlinux.conf" << 'EXTEOF'
LABEL batocera.linux
LINUX /boot/linux
FDT   /boot/rk3566-miyoo-flip.dtb
APPEND initrd=/boot/initrd.lz4 label=BATOCERA rootwait loglevel=7 console=tty0 console=ttyFIQ0
EXTEOF

echo "==> Copying rootfs..."
cp boot/batocera.update "${BATOCERA_MNT}/boot/batocera"

cd "$PROJECT_DIR"

echo ""
echo "==> Verifying..."
ls -la "${BATOCERA_MNT}/boot/"
df -h "${BATOCERA_MNT}"

sync
diskutil unmountDisk "$DISK"

echo ""
echo "==> Done! Patched stock boot.img"
echo ""
echo "    Stock boot.img modified in-place:"
echo "      - Kernel: replaced with custom kernel (zero-padded to stock size)"
echo "      - Ramdisk: replaced with custom initrd.gz (zero-padded)"
echo "      - Cmdline: label=BATOCERA rootwait loglevel=7 console=tty0 console=ttyFIQ0"
echo "      - DTB bootargs: mtdparts replaced with label=BATOCERA"
echo "      - SHA-1 hash: RECALCULATED (boot_android verifies this)"
echo "      - RSCE/signature/sizes: PRESERVED from stock"
echo ""
echo "    boot_android verifies SHA-1, accepts boot.img, shows logo,"
echo "    then boots custom kernel + initrd + cmdline."
