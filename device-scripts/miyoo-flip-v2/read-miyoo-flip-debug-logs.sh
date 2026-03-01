#!/usr/bin/env bash
set -euo pipefail

# Read debug logs and partition info from the SD card.
# Usage: sudo ./read-miyoo-flip-debug-logs.sh /dev/disk4

DISK="${1:-}"
if [ -z "$DISK" ]; then
    echo "Usage: sudo $0 /dev/diskN"
    diskutil list external
    exit 1
fi

RDISK="${DISK/disk/rdisk}"
OUTDIR="/tmp/debug-miyoo-flip"
rm -rf "$OUTDIR" && mkdir -p "$OUTDIR"

echo "==> Reading SD card debug info from $DISK"
echo ""

# 1. Print GPT partition table
echo "=== GPT Partition Table ==="
sgdisk -p "$DISK" 2>&1 | tee "$OUTDIR/gpt.txt"
echo ""

# 2. Unmount everything
diskutil unmountDisk "$DISK" 2>/dev/null || true

# 3. Try to mount and read each potentially relevant partition
for p in 8 9 10 11 12 13 14 15; do
    DEV="${DISK}s${p}"
    MNT="/tmp/debug-miyoo-flip-p${p}"

    # Check if partition exists
    if ! diskutil info "$DEV" >/dev/null 2>&1; then
        continue
    fi

    echo "=== Partition $p ($DEV) ==="
    mkdir -p "$MNT"

    # Try FAT32 mount
    if mount_msdos -o ro "$DEV" "$MNT" 2>/dev/null; then
        echo "  Mounted as FAT32"
        echo "  Contents:"
        ls -la "$MNT"/ 2>&1

        # Check for debug logs
        if [ -f "$MNT/boot-debug.log" ]; then
            echo ""
            echo "  >>> FOUND boot-debug.log on partition $p <<<"
            cp "$MNT/boot-debug.log" "$OUTDIR/boot-debug-p${p}.log"
        fi
        if [ -f "$MNT/dmesg.log" ]; then
            echo "  >>> FOUND dmesg.log on partition $p <<<"
            cp "$MNT/dmesg.log" "$OUTDIR/dmesg-p${p}.log"
        fi

        # Check for boot files (BATOCERA partition)
        if [ -d "$MNT/boot" ]; then
            echo "  Boot dir contents:"
            ls -la "$MNT/boot/" 2>&1
        fi
        if [ -d "$MNT/extlinux" ]; then
            echo "  Extlinux dir:"
            ls -la "$MNT/extlinux/" 2>&1
            cat "$MNT/extlinux/extlinux.conf" 2>/dev/null
        fi
        if [ -f "$MNT/batocera-boot.conf" ]; then
            echo "  batocera-boot.conf:"
            cat "$MNT/batocera-boot.conf" 2>&1
        fi

        umount "$MNT" 2>/dev/null || true
    else
        # Try ext4
        if mount -t ext2 -o ro "$DEV" "$MNT" 2>/dev/null; then
            echo "  Mounted as ext2/3/4"
            echo "  Contents:"
            ls -la "$MNT"/ 2>&1

            if [ -f "$MNT/boot-debug.log" ]; then
                echo ""
                echo "  >>> FOUND boot-debug.log on partition $p <<<"
                cp "$MNT/boot-debug.log" "$OUTDIR/boot-debug-p${p}.log"
            fi
            if [ -f "$MNT/dmesg.log" ]; then
                echo "  >>> FOUND dmesg.log on partition $p <<<"
                cp "$MNT/dmesg.log" "$OUTDIR/dmesg-p${p}.log"
            fi

            umount "$MNT" 2>/dev/null || true
        else
            echo "  Could not mount (not FAT32 or ext2/3/4)"
            # Peek at first bytes to check filesystem
            echo "  First 16 bytes:"
            dd if="$RDISK" bs=512 skip=$(diskutil info "$DEV" 2>/dev/null | grep "Partition Offset" | awk '{print $NF/512}' || echo 0) count=1 2>/dev/null | xxd -l 16
        fi
    fi
    echo ""

    rmdir "$MNT" 2>/dev/null || true
done

# 4. Dump raw GPT entries for analysis
echo "=== Raw GPT dump (for analysis) ==="
dd if="$RDISK" bs=512 skip=0 count=66 of="$OUTDIR/gpt-raw.bin" 2>&1
python3 << PYEOF
import struct

with open('$OUTDIR/gpt-raw.bin', 'rb') as f:
    # LBA 1 = GPT header
    f.seek(512)
    gpt = f.read(512)
    sig = gpt[:8]
    print(f"GPT signature: {sig}")
    if sig != b'EFI PART':
        print("ERROR: Not a valid GPT!")
        exit(1)

    num_entries = struct.unpack_from('<I', gpt, 80)[0]
    entry_size = struct.unpack_from('<I', gpt, 84)[0]
    entries_lba = struct.unpack_from('<Q', gpt, 72)[0]
    print(f"Entries: {num_entries}, size: {entry_size}, entries at LBA: {entries_lba}")
    print()

    f.seek(entries_lba * 512)
    for i in range(min(num_entries, 20)):
        entry = f.read(entry_size)
        type_guid = entry[:16]
        if type_guid == b'\x00' * 16:
            continue
        first_lba = struct.unpack_from('<Q', entry, 32)[0]
        last_lba = struct.unpack_from('<Q', entry, 40)[0]
        name = entry[56:128].decode('utf-16-le').rstrip('\x00')
        size_sectors = last_lba - first_lba + 1
        size_mb = size_sectors * 512 / (1024*1024)
        print(f"  Part {i+1}: '{name}' sectors {first_lba}-{last_lba} ({size_mb:.1f} MB)")
PYEOF

echo ""
echo "=== Summary ==="
echo "All output saved to: $OUTDIR/"
ls -la "$OUTDIR/"

# Print any found logs
for logfile in "$OUTDIR"/boot-debug-*.log "$OUTDIR"/dmesg-*.log; do
    if [ -f "$logfile" ]; then
        echo ""
        echo "=========================================="
        echo "=== $(basename "$logfile") ==="
        echo "=========================================="
        cat "$logfile"
    fi
done

if ! ls "$OUTDIR"/boot-debug-*.log >/dev/null 2>&1; then
    echo ""
    echo "WARNING: No boot-debug.log found on any partition."
    echo "Possible reasons:"
    echo "  1. Kernel panicked before init ran (check if device rebooted after ~10s)"
    echo "  2. Init ran but couldn't mount any log partition"
    echo "  3. The SHARE partition wasn't created correctly"
fi
