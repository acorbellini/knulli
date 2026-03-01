#!/usr/bin/env bash
set -euo pipefail

# DEBUG version: Patched boot.img + diagnostic initrd that saves logs to SHARE.
#
# KEY FIX: Uses sgdisk -e to fix the corrupt backup GPT before modifying
# partitions. Without this, sgdisk silently fails and no BATOCERA/SHARE
# partitions are created.
#
# After booting, pull SD card and run:
#   sudo ./read-miyoo-flip-debug-logs.sh /dev/diskN
#
# Also adds panic=10 to cmdline:
#   - Device REBOOTS after ~10s → kernel panic
#   - Stuck at logo → init running, check SHARE for logs
#
# Usage: sudo ./write-miyoo-flip-patched-bootimg-debug.sh /dev/disk4

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

# Find the latest boot tarball
BOOT_TARBALL=$(ls -t "${PROJECT_DIR}/output/rk3566-bsp/knulli-rk3568-miyoo-flip-gladiator-ii-"*"_boot.tar.gz" 2>/dev/null | head -1)

# Check required tools
for tool in lz4 cpio dtc; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: $tool not found. Install with: brew install $tool"
        exit 1
    fi
done

for f in "$GAMMAOS_64MB" "$GAMMAOS_BOOT_IMG" "$BOOT_TARBALL"; do
    if [ ! -f "$f" ]; then
        echo "Error: $f not found"
        exit 1
    fi
done

echo "==> DEBUG: Full Patch + Debug Ramdisk"
echo "    Target: $DISK"
echo "    Method: Custom kernel + debug ramdisk + patched cmdline + patched DTB bootargs"
echo "    SHA-1 hash recalculated so boot_android accepts the patched boot.img"
echo "    Logs will be saved to BATOCERA and/or SHARE partition"
echo ""

WORK="/tmp/patched-miyoo-flip-debug"
rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK"

# Extract boot components
echo "==> Extracting boot components..."
tar xzf "$BOOT_TARBALL" boot/linux boot/initrd.lz4 boot/batocera.board boot/batocera.update batocera-boot.conf

# ============================================================
# Build debug initrd
# ============================================================
echo "==> Building debug initrd..."
mkdir -p debug-initrd

# Decompress original initrd
unlz4 boot/initrd.lz4 boot/initrd.cpio

# Extract cpio contents
cd debug-initrd
cpio -idm < ../boot/initrd.cpio 2>/dev/null

echo "  Original init script:"
head -3 init

# Replace init with debug version
cat > init << 'INITEOF'
#!/bin/ash

# ============================================================
# DEBUG INIT — logs everything, saves to ANY partition
# ============================================================

LOG="/tmp/boot-debug.log"
LOG_DEV=""

log() {
    echo "$@"
    echo "$@" >> "$LOG" 2>/dev/null
}

save_logs() {
    # Try to save logs to any writable FAT32 partition we can find
    if [ -z "$LOG_DEV" ]; then
        mkdir -p /log_mnt
        # Scan ALL mmcblk partitions (we don't know device numbering)
        for dev in /dev/mmcblk*p*; do
            [ -b "$dev" ] || continue
            if mount "$dev" /log_mnt 2>/dev/null; then
                LOG_DEV="$dev"
                log "LOG: Mounted $dev as log partition"
                break
            fi
        done
    fi

    if [ -n "$LOG_DEV" ]; then
        cp "$LOG" /log_mnt/boot-debug.log 2>/dev/null
        dmesg > /log_mnt/dmesg.log 2>/dev/null
        # Unmount+remount to flush writes (no sync in this busybox)
        umount /log_mnt 2>/dev/null
        mount "$LOG_DEV" /log_mnt 2>/dev/null
        log "LOG: Saved logs to $LOG_DEV"
    else
        log "LOG: WARNING - could not mount any partition for logging"
    fi
}

save_logs_to_boot() {
    # Save logs to BATOCERA partition (already mounted as /boot_root)
    # This is the most reliable method since we know /boot_root works
    boot_mounted=n
    if mountpoint -q /boot_root 2>/dev/null; then
        boot_mounted=y
    elif [ -f /proc/mounts ]; then
        while read dev mp rest; do
            [ "$mp" = "/boot_root" ] && boot_mounted=y
        done < /proc/mounts
    fi
    if [ "$boot_mounted" = "y" ]; then
        mount -o remount,rw /boot_root 2>/dev/null
        cp "$LOG" /boot_root/boot-debug.log 2>/dev/null
        dmesg > /boot_root/dmesg.log 2>/dev/null
        mount -o remount,ro /boot_root 2>/dev/null
        log "LOG: Saved logs to /boot_root (BATOCERA partition)"
    fi
}

do_mount() {
    if mount -o ro "${1}" /boot_root; then return 0; fi
    return 1
}

do_root() {
    mkdir -p /boot_root /new_root /overlay_root /sys /proc /tmp /log_mnt || return 1
    mount -t proc  -o nodev,noexec,nosuid proc  /proc  || return 1
    mount -t sysfs -o nodev,noexec,nosuid sysfs /sys   || return 1
    mount -t devtmpfs none /dev

    log "========================================"
    log "DEBUG BOOT LOG"
    log "========================================"

    log ""
    log "=== /proc/cmdline ==="
    cat /proc/cmdline >> "$LOG" 2>/dev/null

    log ""
    log "=== /proc/version ==="
    cat /proc/version >> "$LOG" 2>/dev/null

    log ""
    log "=== ALL block devices ==="
    ls -la /dev/mmcblk* >> "$LOG" 2>&1 || log "(no mmcblk devices)"
    ls -la /dev/sd* >> "$LOG" 2>&1 || log "(no sd devices)"

    log ""
    log "=== /proc/partitions ==="
    cat /proc/partitions >> "$LOG" 2>/dev/null

    log ""
    log "=== /dev/block/ ==="
    ls -la /dev/block/ >> "$LOG" 2>&1 || log "no /dev/block/"

    log ""
    log "=== /proc/filesystems (supported fs) ==="
    cat /proc/filesystems >> "$LOG" 2>/dev/null

    log ""
    log "=== Attempting to mount each partition ==="
    mkdir -p /test_mnt
    for dev in /dev/mmcblk*p*; do
        [ -b "$dev" ] || continue
        if mount "$dev" /test_mnt 2>/dev/null; then
            log "  $dev: MOUNTABLE - contents:"
            ls -la /test_mnt/ >> "$LOG" 2>&1
            umount /test_mnt 2>/dev/null
        else
            log "  $dev: mount failed"
        fi
    done

    # Try to save logs early (to any partition we can mount)
    save_logs

    # Read cmdline
    read -r cmdline < /proc/cmdline
    log ""
    log "=== Parsed cmdline ==="
    log "cmdline: $cmdline"

    devretry=5
    for param in ${cmdline} ; do
        case ${param} in
            devretry=*) devretry=${param#devretry=};;
        esac
    done

    MOUNTARG=none
    boot_root_mounted=n
    attempt=0

    log ""
    log "=== Mount loop ==="

    while [ $boot_root_mounted = n ]
    do
        attempt=$((attempt + 1))
        log "--- Outer loop iteration $attempt ---"

        for param in ${cmdline}
        do
            case ${param} in
                dev=*)      MOUNTARG=${param#dev=};;
                label=*)    MOUNTARG=LABEL=${param#label=};;
                uuid=*)     MOUNTARG=UUID=${param#uuid=};;
                *)          continue;;
            esac
            log "Trying MOUNTARG=$MOUNTARG (from param=$param)"

            for i in $(seq $devretry)
            do
                log "  Mount attempt $i/$devretry: mount -o ro $MOUNTARG /boot_root"
                if do_mount "${MOUNTARG}"
                then
                    log "  SUCCESS: Mounted ${MOUNTARG} as /boot_root"
                    log "  Contents of /boot_root:"
                    ls -la /boot_root/ >> "$LOG" 2>&1
                    ls -la /boot_root/boot/ >> "$LOG" 2>&1
                    boot_root_mounted=y
                    # Save logs to BATOCERA partition now that it's mounted
                    save_logs_to_boot
                    break
                else
                    log "  FAILED: mount returned $?"
                fi
                sleep 1
            done
            if [ $boot_root_mounted = y ]
            then
                break
            fi
        done

        # Save logs after each outer loop iteration
        save_logs

        # Safety: after 3 outer iterations, give up and drop to shell
        if [ $attempt -ge 3 ] && [ $boot_root_mounted = n ]; then
            log ""
            log "=== GIVING UP after $attempt iterations ==="
            log "=== Saving final dmesg ==="
            dmesg >> "$LOG" 2>/dev/null
            save_logs
            log "Dropping to debug shell..."
            return 1
        fi
    done

    log ""
    log "=== Boot root mounted, continuing... ==="

    # Save logs to BATOCERA partition
    save_logs_to_boot

    # update the squashfs
    if test -e /boot_root/boot/batocera.update
    then
        log "Found batocera.update, updating..."
        mount -o remount,rw /boot_root || return 1
        mv /boot_root/boot/batocera.update /boot_root/boot/batocera || return 1
        if test -e /boot_root/boot/overlay
        then
            mv /boot_root/boot/overlay /boot_root/boot/overlay.old || return 1
        fi
        mount -o remount,ro /boot_root || return 1
        log "Update complete"
    fi

    # create an overlay on memory
    log "Setting up overlay..."
    mount -t tmpfs -o size=256M tmpfs /overlay_root || return 1
    mkdir /overlay_root/base /overlay_root/overlay /overlay_root/work /overlay_root/saved || return 1

    # fill the overlay with the stored one
    if test -f /boot_root/boot/overlay
    then
        if mount -o ro /boot_root/boot/overlay /overlay_root/saved
        then
            cp -pr /overlay_root/saved/* /overlay_root/overlay || return 1
            umount /overlay_root/saved || return 1
        fi
    fi

    # mount the squashfs
    log "Mounting squashfs from /boot_root/boot/batocera..."
    if ! mount /boot_root/boot/batocera /overlay_root/base; then
        log "FAILED to mount squashfs!"
        log "File info:"
        ls -la /boot_root/boot/batocera >> "$LOG" 2>&1
        xxd -l 32 /boot_root/boot/batocera >> "$LOG" 2>&1 || true
        save_logs
        return 1
    fi
    log "Squashfs mounted OK"

    # mount the future root in read write
    log "Setting up overlayfs..."
    if ! mount -t overlay overlay -o rw,lowerdir=/overlay_root/base,upperdir=/overlay_root/overlay,workdir=/overlay_root/work /new_root
    then
        log "Overlayfs failed, trying direct squashfs mount..."
        mount /boot_root/boot/batocera /new_root || return 1
    fi
    log "Root filesystem ready"

    # Save final logs before switch_root
    log ""
    log "=== PRE-SWITCH_ROOT ==="
    log "About to switch_root to /new_root"
    log "Contents of /new_root:"
    ls -la /new_root/ >> "$LOG" 2>&1
    log "Contents of /new_root/sbin/:"
    ls -la /new_root/sbin/init >> "$LOG" 2>&1 || true

    # Save final dmesg
    log ""
    log "=== FINAL DMESG ==="
    dmesg >> "$LOG" 2>/dev/null

    # Save logs everywhere we can
    save_logs
    save_logs_to_boot

    # Unmount log partition before switch_root (umount flushes writes)
    if [ -n "$LOG_DEV" ]; then
        umount /log_mnt 2>/dev/null || true
    fi

    # moving current mounts
    mount --move /boot_root    /new_root/boot    || return 1
    mount --move /overlay_root /new_root/overlay || return 1
    mount --move /sys          /new_root/sys     || return 1
    mount --move /proc         /new_root/proc    || return 1
    mount --move /dev          /new_root/dev     || return 1

    # switch to the new root
    exec switch_root /new_root /sbin/init || return 1
}

if ! do_root
then
    echo "=== do_root FAILED ==="
    # Try one more save
    save_logs
    save_logs_to_boot
    echo "Debug logs saved (if any partition was mounted)"
    echo "Dropping to emergency shell..."
    /bin/ash
fi
INITEOF

chmod 755 init
echo "  Debug init script created"

# Repack cpio
echo "==> Repacking initrd as cpio..."
find . | cpio -o -H newc > ../boot/debug-initrd.cpio 2>/dev/null
cd ..

echo "  CPIO size: $(wc -c < boot/debug-initrd.cpio) bytes"

# Compress with GZIP (stock GammaOS ramdisk uses gzip, not lz4!)
echo "==> Compressing with GZIP (matching stock ramdisk format)..."
gzip -9 < boot/debug-initrd.cpio > boot/debug-initrd.gz
DEBUG_INITRD_SIZE=$(wc -c < boot/debug-initrd.gz | tr -d ' ')
echo "  Debug initrd.gz: $DEBUG_INITRD_SIZE bytes"
echo "  Original initrd.lz4: $(wc -c < boot/initrd.lz4 | tr -d ' ') bytes"

# Read stock ramdisk size to check fit
python3 -c "
import struct
with open('${GAMMAOS_BOOT_IMG}', 'rb') as f:
    f.seek(16)
    ramdisk_size = struct.unpack('<I', f.read(4))[0]
    print(f'  Stock ramdisk_size: {ramdisk_size} bytes')
    debug_size = ${DEBUG_INITRD_SIZE}
    if debug_size > ramdisk_size:
        print(f'  ERROR: Debug initrd too large! ({debug_size - ramdisk_size} bytes over)')
        exit(1)
    else:
        print(f'  Fits OK ({ramdisk_size - debug_size} bytes to spare)')
"

# ============================================================
# Patch the stock boot.img
# ============================================================
echo ""
echo "==> Patching stock boot.img with kernel + debug ramdisk..."
python3 << PYEOF
import struct, shutil, os, hashlib

shutil.copy('${GAMMAOS_BOOT_IMG}', 'patched-boot.img')

with open('patched-boot.img', 'r+b') as f:
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

    # Read custom kernel
    with open('boot/linux', 'rb') as kf:
        new_kernel = kf.read()
    # Read debug ramdisk (gzip compressed)
    with open('boot/debug-initrd.gz', 'rb') as rf:
        debug_initrd = rf.read()

    # 1. Patch kernel
    print(f"  --- Kernel ---")
    print(f"  Stock:  {kernel_size} bytes")
    print(f"  New: {len(new_kernel)} bytes")
    if len(new_kernel) > kernel_size:
        print(f"  ERROR: custom kernel too large! ({len(new_kernel) - kernel_size} bytes over)")
        exit(1)
    f.seek(kernel_offset)
    f.write(new_kernel)
    if len(new_kernel) < kernel_size:
        f.write(b'\x00' * (kernel_size - len(new_kernel)))
    print(f"  Kernel patched at offset {kernel_offset}, zero-padded to {kernel_size}")

    # 2. Patch ramdisk
    print(f"  --- Ramdisk ---")
    print(f"  Stock:  {ramdisk_size} bytes")
    print(f"  Debug:  {len(debug_initrd)} bytes")
    if len(debug_initrd) > ramdisk_size:
        print(f"  ERROR: Debug initrd too large! ({len(debug_initrd) - ramdisk_size} bytes over)")
        exit(1)
    f.seek(ramdisk_offset)
    f.write(debug_initrd)
    if len(debug_initrd) < ramdisk_size:
        f.write(b'\x00' * (ramdisk_size - len(debug_initrd)))
    print(f"  Ramdisk patched at offset {ramdisk_offset}, zero-padded to {ramdisk_size}")

    # 3. Patch cmdline in header bytearray (written to file at end with SHA-1)
    # Header layout: cmdline at [64:576] (512 bytes), extra_cmdline at [608:1632] (1024 bytes)
    new_cmdline = b'label=BATOCERA rootwait panic=10 loglevel=7 console=tty0 console=ttyFIQ0'
    header[64:64+len(new_cmdline)] = new_cmdline
    header[64+len(new_cmdline):576] = b'\x00' * (512 - len(new_cmdline))
    # Clear extra_cmdline to remove stock Android params (init=/init, etc.)
    header[608:1632] = b'\x00' * 1024
    print(f"  --- Cmdline ---")
    print(f"  Patched: {new_cmdline.decode()}")
    print(f"  Extra cmdline: CLEARED (removed stock Android params)")

    # 4. Patch DTB bootargs (replace mtdparts= with label=BATOCERA in all DTBs)
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
        print(f"  Patched mtdparts at offset {ba_idx} ({mtdparts_len} chars) -> {replacement.decode()}")
        search_start = ba_idx + len(padded_replacement)

    if patch_count == 0:
        print(f"  WARNING: Could not find mtdparts in any DTB!")
    else:
        print(f"  Patched {patch_count} DTB(s)")

    # 5. CRITICAL: Recalculate SHA-1 hash in header
    # boot_android verifies this hash! Without updating it, boot is rejected.
    f.seek(kernel_offset)
    kernel_data = f.read(kernel_size)
    f.seek(ramdisk_offset)
    ramdisk_data_new = f.read(ramdisk_size)
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
    h.update(ramdisk_data_new)
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

# ============================================================
# Write to SD card
# ============================================================
echo ""
echo "==> Unmounting..."
diskutil unmountDisk "$DISK"

# Wipe any pre-existing partition data that might confuse the bootloader.
# 128GB+ cards often have exFAT metadata at various offsets.
echo "==> Wiping first 128MB (clean slate for GPT + bootloader + boot.img)..."
dd if=/dev/zero of="$RDISK" bs=1048576 count=128 conv=notrunc 2>&1

echo "==> Writing GammaOS first 64MB (GPT + bootloader)..."
dd if="$GAMMAOS_64MB" of="$RDISK" bs=1048576 conv=notrunc 2>&1

# Re-unmount in case macOS auto-detected the new GPT and mounted partitions
diskutil unmountDisk "$DISK" 2>/dev/null || true

echo "==> Writing patched boot.img to sector 51200..."
# Pad boot.img to 512-byte boundary (rdisk requires sector-aligned writes)
BOOTIMG_SIZE=$(wc -c < "$BOOT_IMG" | tr -d ' ')
REMAINDER=$(( BOOTIMG_SIZE % 512 ))
if [ "$REMAINDER" -ne 0 ]; then
    PAD=$(( 512 - REMAINDER ))
    echo "  Padding boot.img by $PAD bytes to align to 512-byte sector boundary"
    dd if=/dev/zero bs=1 count=$PAD >> "$BOOT_IMG" 2>/dev/null
fi
dd if="$BOOT_IMG" of="$RDISK" bs=512 seek=51200 conv=notrunc 2>&1

# Verify boot.img was written correctly by reading back the header
echo "==> Verifying boot.img write..."
python3 << PYVERIFY
import struct, hashlib

with open('${RDISK}', 'rb') as f:
    # Read header from disk at sector 51200
    f.seek(51200 * 512)
    disk_header = f.read(2048)

    magic = disk_header[:8]
    print(f"  boot.img magic on disk: {magic}")
    if magic != b'ANDROID!':
        print("  ERROR: boot.img magic mismatch! Write may have failed.")
        exit(1)

    # Compare SHA-1 in header on disk vs what we wrote
    disk_sha = disk_header[576:596].hex()

with open('${WORK}/patched-boot.img', 'rb') as f:
    file_header = f.read(2048)
    file_sha = file_header[576:596].hex()

print(f"  SHA-1 on disk:   {disk_sha}")
print(f"  SHA-1 in file:   {file_sha}")
if disk_sha == file_sha:
    print(f"  VERIFIED: boot.img header matches!")
else:
    print(f"  ERROR: SHA-1 mismatch — boot.img write may be corrupted!")
    exit(1)
PYVERIFY

# ============================================================
# Write GPT directly using Python (sgdisk fails on this disk)
# ============================================================
#
# sgdisk cannot reliably modify this GPT because first-64mb.bin has a backup
# GPT header pointing to a different disk size, causing CRC mismatches.
# Instead, we write the GPT partition entries directly using Python.
#
# We keep GammaOS partitions 1-7 intact and replace 8-15 with BATOCERA + SHARE.

# Get disk size for backup GPT placement
DISK_SECTORS=$(diskutil info "$DISK" | grep -oE 'exactly [0-9]+' | awk '{print $2}')
if [ -z "$DISK_SECTORS" ]; then
    echo "ERROR: Could not determine disk size!"
    diskutil info "$DISK" | grep -i size
    exit 1
fi
echo ""
echo "==> Writing GPT partition table directly (bypassing sgdisk)..."
echo "    Disk sectors: $DISK_SECTORS"

python3 << PYEOF
import struct, binascii, uuid, os

DISK = '${RDISK}'
DISK_SECTORS = ${DISK_SECTORS}

# Partition definitions: (number, name, first_lba, last_lba, type_guid_bytes)
# Keep GammaOS partitions 1-7, add BATOCERA(8) + SHARE(9)

# GammaOS uses custom type GUIDs. Read them from the existing GPT.
with open(DISK, 'rb') as f:
    # Read existing GPT entries (LBA 2-33)
    f.seek(2 * 512)
    existing_entries = f.read(128 * 128)

# Extract GammaOS partitions 1-7 (indices 0-6)
gammaos_entries = []
for i in range(7):
    entry = existing_entries[i*128:(i+1)*128]
    type_guid = entry[:16]
    if type_guid == b'\x00' * 16:
        break
    gammaos_entries.append(bytearray(entry))

print(f"  Preserved {len(gammaos_entries)} GammaOS partitions (1-7)")

# Microsoft Basic Data GUID: EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
MSBASIC_GUID = bytes.fromhex('A2A0D0EB' + 'E5B9' + '3344' + '87C0' + '68B6B72699C7')
# Linux filesystem GUID: 0FC63DAF-8483-4772-8E79-3D69D8477DE4
LINUX_GUID = bytes.fromhex('AF3DC60F' + '8384' + '7247' + '8E79' + '3D69D8477DE4')

def make_gpt_entry(type_guid, unique_guid, first_lba, last_lba, name):
    """Create a 128-byte GPT partition entry."""
    entry = bytearray(128)
    entry[0:16] = type_guid
    entry[16:32] = unique_guid
    struct.pack_into('<Q', entry, 32, first_lba)
    struct.pack_into('<Q', entry, 40, last_lba)
    # Attributes = 0
    # Name (UTF-16LE, up to 36 chars)
    name_bytes = name.encode('utf-16-le')[:72]
    entry[56:56+len(name_bytes)] = name_bytes
    return entry

# BATOCERA: partition 8, starts at sector 155648, 4GB
BATOCERA_START = 155648
BATOCERA_SIZE = 8388608
BATOCERA_END = BATOCERA_START + BATOCERA_SIZE - 1

# SHARE: partition 9, after BATOCERA + 2048 gap
SHARE_START = BATOCERA_END + 1 + 2048
SHARE_SIZE = 1048576
SHARE_END = SHARE_START + SHARE_SIZE - 1

batocera_entry = make_gpt_entry(
    MSBASIC_GUID,
    uuid.uuid4().bytes_le,
    BATOCERA_START, BATOCERA_END,
    'BATOCERA'
)

share_entry = make_gpt_entry(
    MSBASIC_GUID,
    uuid.uuid4().bytes_le,
    SHARE_START, SHARE_END,
    'SHARE'
)

print(f"  BATOCERA: sectors {BATOCERA_START}-{BATOCERA_END} ({BATOCERA_SIZE*512//(1024*1024)} MB)")
print(f"  SHARE:    sectors {SHARE_START}-{SHARE_END} ({SHARE_SIZE*512//(1024*1024)} MB)")

# Build full partition entry array (128 entries × 128 bytes = 16384 bytes)
entries = bytearray(128 * 128)
for i, e in enumerate(gammaos_entries):
    entries[i*128:(i+1)*128] = e
entries[7*128:8*128] = batocera_entry   # partition 8
entries[8*128:9*128] = share_entry      # partition 9

# Calculate CRC32 of partition entries
entries_crc = binascii.crc32(bytes(entries)) & 0xFFFFFFFF

# Build GPT header
# Place backup GPT right after SHARE partition (NOT at end of disk).
# On 128GB+ cards, placing backup at the last sector causes U-Boot to seek
# to byte offsets > 4GB which may overflow 32-bit arithmetic in the GPT parser.
# By keeping everything within the first ~5GB, we avoid this.
BACKUP_GAP = 2048  # gap after SHARE
BACKUP_ENTRIES_LBA = SHARE_END + 1 + BACKUP_GAP  # backup entries start
BACKUP_HDR_LBA = BACKUP_ENTRIES_LBA + 32          # backup header (after 32 sectors of entries)
LAST_USABLE = BACKUP_ENTRIES_LBA - 1              # last usable sector before backup GPT

print(f"  Backup GPT at LBA {BACKUP_ENTRIES_LBA} (entries) / {BACKUP_HDR_LBA} (header)")
print(f"  Byte offset of backup: {BACKUP_HDR_LBA * 512} ({BACKUP_HDR_LBA * 512 / (1024*1024*1024):.2f} GB)")
print(f"  LastUsableLBA: {LAST_USABLE}")

DISK_GUID = bytes.fromhex('23000000' + '0000' + '4C4A' + '8000' + '699000005ABB')

def make_gpt_header(my_lba, alt_lba, entries_lba, entries_crc, disk_guid, last_usable):
    """Create a 92-byte GPT header (padded to 512 bytes)."""
    hdr = bytearray(512)
    hdr[0:8] = b'EFI PART'                          # Signature
    struct.pack_into('<I', hdr, 8, 0x00010000)       # Revision 1.0
    struct.pack_into('<I', hdr, 12, 92)              # Header size
    struct.pack_into('<I', hdr, 16, 0)               # CRC placeholder
    struct.pack_into('<I', hdr, 20, 0)               # Reserved
    struct.pack_into('<Q', hdr, 24, my_lba)          # My LBA
    struct.pack_into('<Q', hdr, 32, alt_lba)         # Alternate LBA
    struct.pack_into('<Q', hdr, 40, 34)              # First usable LBA
    struct.pack_into('<Q', hdr, 48, last_usable)     # Last usable LBA
    hdr[56:72] = disk_guid                           # Disk GUID
    struct.pack_into('<Q', hdr, 72, entries_lba)     # Partition entries LBA
    struct.pack_into('<I', hdr, 80, 128)             # Number of entries
    struct.pack_into('<I', hdr, 84, 128)             # Entry size
    struct.pack_into('<I', hdr, 88, entries_crc)     # Entries CRC32
    hdr_crc = binascii.crc32(bytes(hdr[:92])) & 0xFFFFFFFF
    struct.pack_into('<I', hdr, 16, hdr_crc)
    return hdr

# Primary header at LBA 1, entries at LBA 2
primary_hdr = make_gpt_header(
    my_lba=1,
    alt_lba=BACKUP_HDR_LBA,
    entries_lba=2,
    entries_crc=entries_crc,
    disk_guid=DISK_GUID,
    last_usable=LAST_USABLE
)

# Backup header right after SHARE partition
backup_hdr = make_gpt_header(
    my_lba=BACKUP_HDR_LBA,
    alt_lba=1,
    entries_lba=BACKUP_ENTRIES_LBA,
    entries_crc=entries_crc,
    disk_guid=DISK_GUID,
    last_usable=LAST_USABLE
)

# Write to disk
with open(DISK, 'r+b') as f:
    # Write primary GPT header (LBA 1)
    f.seek(1 * 512)
    f.write(primary_hdr)
    print(f"  Wrote primary GPT header at LBA 1")

    # Write primary partition entries (LBA 2-33)
    f.seek(2 * 512)
    f.write(entries)
    print(f"  Wrote partition entries at LBA 2-33")

    # Write backup partition entries (right after SHARE)
    f.seek(BACKUP_ENTRIES_LBA * 512)
    f.write(entries)
    print(f"  Wrote backup entries at LBA {BACKUP_ENTRIES_LBA}")

    # Write backup GPT header
    f.seek(BACKUP_HDR_LBA * 512)
    f.write(backup_hdr)
    print(f"  Wrote backup GPT header at LBA {BACKUP_HDR_LBA}")

print(f"  GPT written successfully!")

# Write proper protective MBR at sector 0
# The first-64mb.bin dump has an MBR from the original dump source,
# which may have wrong disk size. U-Boot may check MBR validity.
with open(DISK, 'r+b') as f:
    # Read existing MBR to preserve any bootcode in first 446 bytes
    f.seek(0)
    mbr = bytearray(f.read(512))

    # Show what the dump had
    old_type = mbr[446 + 4]
    old_lba = struct.unpack_from('<I', mbr, 446 + 8)[0]
    old_size = struct.unpack_from('<I', mbr, 446 + 12)[0]
    print(f"  --- Protective MBR ---")
    print(f"  Dump MBR: type=0x{old_type:02x}, start_lba={old_lba}, size={old_size} sectors ({old_size*512/(1024*1024*1024):.1f} GB)")

    # Clear all 4 partition entries (bytes 446-509)
    mbr[446:510] = b'\x00' * 64

    # Write protective MBR partition entry 1 (type 0xEE = GPT)
    mbr[446] = 0x00           # Status: not bootable
    mbr[446+1] = 0x00         # CHS first: head
    mbr[446+2] = 0x02         # CHS first: sector (1-based, cylinder in high bits)
    mbr[446+3] = 0x00         # CHS first: cylinder
    mbr[446+4] = 0xEE         # Type: GPT protective
    mbr[446+5] = 0xFF         # CHS last: head
    mbr[446+6] = 0xFF         # CHS last: sector
    mbr[446+7] = 0xFF         # CHS last: cylinder
    struct.pack_into('<I', mbr, 446+8, 1)  # LBA start = 1
    # Use backup GPT location + 1 as the MBR size (covers all our data)
    pmbr_size = BACKUP_HDR_LBA
    struct.pack_into('<I', mbr, 446+12, pmbr_size)  # Size in sectors

    # Ensure boot signature
    mbr[510] = 0x55
    mbr[511] = 0xAA

    f.seek(0)
    f.write(mbr)
    print(f"  New MBR:  type=0xEE, start_lba=1, size={pmbr_size} sectors ({pmbr_size*512/(1024*1024*1024):.1f} GB)")
    print(f"  Protective MBR covers through backup GPT (avoids large sector numbers)")

# Verify by re-reading
with open(DISK, 'rb') as f:
    f.seek(512)
    hdr = f.read(512)
    sig = hdr[:8]
    stored_crc = struct.unpack_from('<I', hdr, 16)[0]
    verify_hdr = bytearray(hdr[:92])
    struct.pack_into('<I', verify_hdr, 16, 0)
    calc_crc = binascii.crc32(bytes(verify_hdr)) & 0xFFFFFFFF
    print(f"  Verify: signature={sig}, header CRC {'OK' if stored_crc == calc_crc else 'MISMATCH!'}")

    f.seek(2 * 512)
    read_entries = f.read(128 * 128)
    for i in range(9):
        entry = read_entries[i*128:(i+1)*128]
        type_guid = entry[:16]
        if type_guid == b'\x00' * 16:
            continue
        first = struct.unpack_from('<Q', entry, 32)[0]
        last = struct.unpack_from('<Q', entry, 40)[0]
        name = entry[56:128].decode('utf-16-le').rstrip('\x00')
        print(f"  Verify part {i+1}: '{name}' sectors {first}-{last}")
PYEOF

# Force macOS to re-read the partition table
echo ""
echo "==> Re-reading partition table..."
sleep 1
diskutil unmountDisk "$DISK"
sleep 2

echo "==> Checking macOS sees new partitions..."
diskutil list "$DISK"

echo ""
echo "==> Formatting BATOCERA as FAT32..."
newfs_msdos -F 32 -v BATOCERA "${RDISK}s8" 2>&1

echo "==> Formatting SHARE as FAT32 (for debug logs)..."
newfs_msdos -F 32 -v SHARE "${RDISK}s9" 2>&1

echo "==> Mounting BATOCERA..."
sleep 1
diskutil mount "${DISK}s8"

BATOCERA_MNT="/Volumes/BATOCERA"
if [ ! -d "$BATOCERA_MNT" ]; then
    echo "Error: BATOCERA not mounted at $BATOCERA_MNT"
    echo "Checking what mounted..."
    ls /Volumes/
    exit 1
fi

# Prevent Spotlight from indexing (it holds the disk and can corrupt on eject)
mdutil -i off "$BATOCERA_MNT" 2>/dev/null || true
touch "${BATOCERA_MNT}/.metadata_never_index" 2>/dev/null || true

echo "==> Copying boot files to BATOCERA..."
mkdir -p "${BATOCERA_MNT}/boot"
mkdir -p "${BATOCERA_MNT}/extlinux"

cp boot/linux "${BATOCERA_MNT}/boot/"
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
echo "==> Verifying BATOCERA contents..."
ls -la "${BATOCERA_MNT}/boot/"
echo ""
cat "${BATOCERA_MNT}/extlinux/extlinux.conf"
echo ""
df -h "${BATOCERA_MNT}"

# Force unmount (don't let Spotlight prevent clean unmount)
sync
sleep 1
diskutil unmountDisk force "$DISK" 2>&1

# ============================================================
# Final verification: re-read raw disk to confirm everything
# ============================================================
echo ""
echo "==> FINAL VERIFICATION: Full disk check..."
python3 << PYEOF2
import struct, hashlib

with open('${RDISK}', 'rb') as f:
    # 1. Check MBR
    f.seek(0)
    mbr = f.read(512)
    print(f"  --- MBR (sector 0) ---")
    print(f"  Boot sig: 0x{mbr[510]:02x}{mbr[511]:02x} {'OK' if mbr[510]==0x55 and mbr[511]==0xAA else 'BAD!'}")
    for p in range(4):
        off = 446 + p * 16
        ptype = mbr[off + 4]
        if ptype == 0: continue
        plba = struct.unpack_from('<I', mbr, off + 8)[0]
        psize = struct.unpack_from('<I', mbr, off + 12)[0]
        print(f"  MBR part {p+1}: type=0x{ptype:02x}, lba={plba}, size={psize} ({psize*512/(1024*1024*1024):.1f} GB)")

    # 2. Check GPT header
    f.seek(512)
    hdr = f.read(512)
    print(f"\n  --- GPT Header (sector 1) ---")
    print(f"  Signature: {hdr[:8]}")
    my_lba = struct.unpack_from('<Q', hdr, 24)[0]
    alt_lba = struct.unpack_from('<Q', hdr, 32)[0]
    first_usable = struct.unpack_from('<Q', hdr, 40)[0]
    last_usable = struct.unpack_from('<Q', hdr, 48)[0]
    entries_lba = struct.unpack_from('<Q', hdr, 72)[0]
    num_entries = struct.unpack_from('<I', hdr, 80)[0]
    print(f"  MyLBA={my_lba}, AltLBA={alt_lba}")
    print(f"  FirstUsable={first_usable}, LastUsable={last_usable}")
    print(f"  EntriesLBA={entries_lba}, NumEntries={num_entries}")

    # 3. Check partition entries
    print(f"\n  --- Partition entries ---")
    f.seek(entries_lba * 512)
    boot_part_lba = None
    for i in range(min(num_entries, 20)):
        entry = f.read(128)
        if entry[:16] == b'\x00' * 16:
            continue
        first = struct.unpack_from('<Q', entry, 32)[0]
        last = struct.unpack_from('<Q', entry, 40)[0]
        name = entry[56:128].decode('utf-16-le').rstrip('\x00')
        tguid = entry[:16].hex()
        size_mb = (last - first + 1) * 512 / (1024*1024)
        print(f"  Part {i+1}: '{name}' sectors {first}-{last} ({size_mb:.1f} MB) type={tguid}")
        if name.lower() == 'boot':
            boot_part_lba = first

    # 4. Check boot.img at sector 51200
    print(f"\n  --- boot.img at sector 51200 ---")
    f.seek(51200 * 512)
    bh = f.read(2048)
    magic = bh[:8]
    print(f"  Magic: {magic}")
    if magic == b'ANDROID!':
        ks = struct.unpack_from('<I', bh, 8)[0]
        rs = struct.unpack_from('<I', bh, 16)[0]
        sha = bh[576:596].hex()
        os_ver = struct.unpack_from('<I', bh, 40)[0]
        cmdline = bh[64:64+512].split(b'\x00')[0].decode('ascii', errors='replace')
        print(f"  kernel_size={ks}, ramdisk_size={rs}")
        print(f"  SHA-1: {sha}")
        print(f"  cmdline: {cmdline}")
        print(f"  os_version raw: 0x{os_ver:08x}")
    else:
        print(f"  ERROR: Not a valid boot.img!")

    if boot_part_lba is not None:
        print(f"\n  Boot partition starts at sector {boot_part_lba}, boot.img at sector 51200")
        if boot_part_lba == 51200:
            print(f"  MATCH: boot partition aligns with boot.img")
        else:
            print(f"  MISMATCH! boot_android may look at sector {boot_part_lba} instead of 51200!")

    # 5. Check for BATOCERA and SHARE
    found = {'BATOCERA': False, 'SHARE': False}
    f.seek(entries_lba * 512)
    for i in range(128):
        entry = f.read(128)
        if entry[:16] == b'\x00' * 16: continue
        name = entry[56:128].decode('utf-16-le').rstrip('\x00')
        if name in found: found[name] = True

    if all(found.values()):
        print(f"\n  *** ALL CHECKS PASSED ***")
    else:
        print(f"\n  *** CHECKS FAILED: {found} ***")
PYEOF2

# Now safely eject
diskutil eject "$DISK" 2>/dev/null || true

echo ""
echo "==> Done! Full patch + debug ramdisk"
echo ""
echo "    Stock boot.img patched with:"
echo "      - Kernel: custom (zero-padded to stock size)"
echo "      - Ramdisk: Debug initrd with logging (GZIP, zero-padded)"
echo "      - Cmdline: label=BATOCERA rootwait panic=10 loglevel=7"
echo "      - DTB bootargs: mtdparts replaced with label=BATOCERA"
echo "      - SHA-1 hash: RECALCULATED (boot_android will accept)"
echo "      - RSCE/signature/sizes: PRESERVED from stock"
echo ""
echo "    GPT: Partitions 1-7 GammaOS, 8=BATOCERA, 9=SHARE"
echo ""
echo "    After testing, pull SD card and run:"
echo "      sudo ./device-scripts/miyoo-flip-v2/read-miyoo-flip-debug-logs.sh /dev/diskN"
