#!/usr/bin/env bash
set -euo pipefail

# Fix the SHARE partition GPT entry to fill the remaining disk space.
# Use this when the SHARE partition was recreated with a small size
# but the data is still on disk.
#
# Usage: sudo ./fix-share-partition.sh /dev/disk4

DISK="${1:-}"
if [ -z "$DISK" ]; then
    echo "Usage: sudo $0 /dev/diskN"
    diskutil list external
    exit 1
fi

RDISK="${DISK/disk/rdisk}"

DISK_SECTORS=$(diskutil info "$DISK" | grep -oE 'exactly [0-9]+' | awk '{print $2}')
if [ -z "$DISK_SECTORS" ]; then
    echo "Error: Could not determine disk size"
    exit 1
fi

echo "==> Fixing SHARE partition on $DISK ($DISK_SECTORS sectors)"
diskutil unmountDisk force "$DISK" 2>/dev/null || true

python3 << PYEOF
import struct, binascii

DISK = '${RDISK}'
SECTOR = 512
disk_sectors = ${DISK_SECTORS}

with open(DISK, 'rb') as f:
    f.seek(SECTOR)
    gpt_header = bytearray(f.read(SECTOR))
    f.seek(2 * SECTOR)
    entries = bytearray(f.read(128 * 128))

# Find SHARE partition (last Microsoft Basic Data partition)
share_idx = None
for i in range(128):
    e = entries[i*128:(i+1)*128]
    if e[:16] == b'\x00' * 16:
        break
    name = e[56:128].decode('utf-16-le').rstrip('\x00')
    if name == 'SHARE':
        share_idx = i
        break

if share_idx is None:
    print("ERROR: SHARE partition not found in GPT!")
    exit(1)

share_first = struct.unpack_from('<Q', entries, share_idx*128 + 32)[0]
share_last = struct.unpack_from('<Q', entries, share_idx*128 + 40)[0]
print(f'Current SHARE: sectors {share_first}-{share_last} ({(share_last-share_first+1)*512/(1024**3):.1f} GB)')

# Expand to fill disk (minus 34 sectors for backup GPT)
new_last = disk_sectors - 34
struct.pack_into('<Q', entries, share_idx*128 + 40, new_last)
print(f'New SHARE:     sectors {share_first}-{new_last} ({(new_last-share_first+1)*512/(1024**3):.1f} GB)')

# Recalculate GPT CRCs and write
entries_crc = binascii.crc32(bytes(entries)) & 0xFFFFFFFF

gpt_header[16:20] = b'\x00\x00\x00\x00'
struct.pack_into('<I', gpt_header, 88, entries_crc)
header_crc = binascii.crc32(bytes(gpt_header[:92])) & 0xFFFFFFFF
struct.pack_into('<I', gpt_header, 16, header_crc)

backup_header = bytearray(gpt_header)
struct.pack_into('<Q', backup_header, 24, disk_sectors - 1)
struct.pack_into('<Q', backup_header, 32, 1)
struct.pack_into('<Q', backup_header, 72, disk_sectors - 33)
backup_header[16:20] = b'\x00\x00\x00\x00'
backup_crc = binascii.crc32(bytes(backup_header[:92])) & 0xFFFFFFFF
struct.pack_into('<I', backup_header, 16, backup_crc)

with open(DISK, 'r+b') as f:
    f.seek(SECTOR)
    f.write(gpt_header)
    f.seek(2 * SECTOR)
    f.write(entries)
    f.seek((disk_sectors - 33) * SECTOR)
    f.write(entries)
    f.seek((disk_sectors - 1) * SECTOR)
    f.write(backup_header)

print('GPT updated (primary + backup)')
PYEOF

echo ""
echo "==> Done. SHARE partition expanded."
echo "    Insert the card and boot — your data should be there."
