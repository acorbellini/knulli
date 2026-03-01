#!/usr/bin/env python3
"""
Build a flashable SD card image for the Miyoo Flip (RK3566).

Creates a complete disk image containing:
  - GammaOS proprietary data (bootloader partitions from first-64mb.bin)
  - Patched boot.img with Knulli kernel/initrd/cmdline at sector 51200
  - BATOCERA partition (FAT32) with rootfs and boot files
  - SHARE partition placeholder (expanded on first boot)
  - GPT partition table preserving GammaOS entries

Requires: mtools (mcopy, mmd), mkfs.fat or newfs_msdos, lz4 (if initrd is LZ4)

Usage:
    python3 create-disk-image.py \
        --gammaos-dump first-64mb.bin \
        --stock-bootimg gammaos-boot.img \
        --boot-dir /path/to/knulli/boot/ \
        --output knulli-miyoo-flip.img

    The --boot-dir should contain the standard Knulli boot tree:
        boot/linux, boot/initrd.lz4, boot/batocera, boot/rk3566-miyoo-flip.dtb,
        boot/batocera.board, batocera-boot.conf, extlinux/extlinux.conf
"""

import argparse
import binascii
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from patch_bootimg import patch_bootimg

SECTOR = 512
BOOT_SECTOR = 51200            # Stock GammaOS boot.img location
BATOCERA_START = 155648         # ~76MB, after GammaOS partitions + boot.img

# Microsoft Basic Data GUID (FAT32 partitions accessible from all OSes)
MSBASIC_GUID = bytes.fromhex('A2A0D0EB' + 'E5B9' + '3344' + '87C0' + '68B6B72699C7')


def parse_size(s):
    """Parse a size string like '4G', '512M', '1024K'."""
    s = s.strip().upper()
    multipliers = {'K': 1024, 'M': 1024**2, 'G': 1024**3}
    if s[-1] in multipliers:
        return int(float(s[:-1]) * multipliers[s[-1]])
    return int(s)


def make_gpt_entry(type_guid, first_lba, last_lba, name):
    entry = bytearray(128)
    entry[0:16] = type_guid
    entry[16:32] = uuid.uuid4().bytes_le
    struct.pack_into('<Q', entry, 32, first_lba)
    struct.pack_into('<Q', entry, 40, last_lba)
    name_bytes = name.encode('utf-16-le')[:72]
    entry[56:56 + len(name_bytes)] = name_bytes
    return entry


def make_gpt_header(my_lba, alt_lba, entries_lba, last_usable,
                    disk_guid, entries_crc):
    hdr = bytearray(512)
    hdr[0:8] = b'EFI PART'
    struct.pack_into('<I', hdr, 8, 0x00010000)
    struct.pack_into('<I', hdr, 12, 92)
    struct.pack_into('<Q', hdr, 24, my_lba)
    struct.pack_into('<Q', hdr, 32, alt_lba)
    struct.pack_into('<Q', hdr, 40, 34)
    struct.pack_into('<Q', hdr, 48, last_usable)
    hdr[56:72] = disk_guid
    struct.pack_into('<Q', hdr, 72, entries_lba)
    struct.pack_into('<I', hdr, 80, 128)
    struct.pack_into('<I', hdr, 84, 128)
    struct.pack_into('<I', hdr, 88, entries_crc)
    crc = binascii.crc32(bytes(hdr[:92])) & 0xFFFFFFFF
    struct.pack_into('<I', hdr, 16, crc)
    return hdr


def make_protective_mbr(disk_sectors):
    mbr = bytearray(512)
    mbr[446 + 4] = 0xEE
    mbr[446 + 5] = 0xFF
    mbr[446 + 6] = 0xFF
    mbr[446 + 7] = 0xFF
    struct.pack_into('<I', mbr, 446 + 8, 1)
    struct.pack_into('<I', mbr, 446 + 12, min(disk_sectors - 1, 0xFFFFFFFF))
    mbr[510] = 0x55
    mbr[511] = 0xAA
    return mbr


def create_fat32(path, size_bytes, label):
    """Create an empty FAT32 filesystem image file."""
    with open(path, 'wb') as f:
        f.truncate(size_bytes)
    try:
        subprocess.run(
            ['mkfs.fat', '-F', '32', '-n', label, path],
            check=True, capture_output=True
        )
        return
    except FileNotFoundError:
        pass
    try:
        subprocess.run(
            ['newfs_msdos', '-F', '32', '-v', label, path],
            check=True, capture_output=True
        )
        return
    except FileNotFoundError:
        pass
    raise RuntimeError(
        "Neither mkfs.fat nor newfs_msdos found. "
        "Install dosfstools (Linux) or use macOS."
    )


def mcopy_tree(fat32_path, source_dir):
    """Copy a directory tree into a FAT32 image using mtools."""
    for root, dirs, files in os.walk(source_dir):
        rel = os.path.relpath(root, source_dir)
        if rel == '.':
            fat_dir = '::'
        else:
            fat_dir = '::/' + rel.replace(os.sep, '/')
            subprocess.run(
                ['mmd', '-i', fat32_path, fat_dir],
                capture_output=True  # ignore errors if dir exists
            )

        for fname in files:
            src = os.path.join(root, fname)
            dst = fat_dir + '/' + fname
            subprocess.run(
                ['mcopy', '-i', fat32_path, '-o', src, dst],
                check=True, capture_output=True
            )


def create_disk_image(gammaos_dump, stock_bootimg, boot_dir, output,
                      batocera_sectors, share_sectors, verbose=True):
    batocera_end = BATOCERA_START + batocera_sectors - 1
    share_start = batocera_end + 1 + 2048  # 1MB gap
    share_end = share_start + share_sectors - 1
    total_sectors = share_end + 34 + 1  # backup GPT
    total_bytes = total_sectors * SECTOR

    if verbose:
        print(f"Image layout:")
        print(f"  Total:    {total_bytes / (1024**3):.2f} GB ({total_sectors} sectors)")
        print(f"  GammaOS:  first {os.path.getsize(gammaos_dump) / (1024**2):.0f} MB")
        print(f"  boot.img: sector {BOOT_SECTOR}")
        print(f"  BATOCERA: sectors {BATOCERA_START}-{batocera_end} "
              f"({batocera_sectors * SECTOR / (1024**3):.1f} GB)")
        print(f"  SHARE:    sectors {share_start}-{share_end} "
              f"({share_sectors * SECTOR / (1024**2):.0f} MB)")
        print()

    with tempfile.TemporaryDirectory() as tmpdir:
        # Step 1: Create sparse output image
        if verbose:
            print("Step 1/6: Creating sparse image file...")
        with open(output, 'wb') as f:
            f.truncate(total_bytes)

        # Step 2: Write GammaOS dump (first ~64MB)
        if verbose:
            print("Step 2/6: Writing GammaOS proprietary data...")
        with open(gammaos_dump, 'rb') as src:
            with open(output, 'r+b') as dst:
                dst.write(src.read())

        # Step 3: Patch boot.img and write at sector 51200
        if verbose:
            print("Step 3/6: Patching boot.img with Knulli components...")
        kernel_path = os.path.join(boot_dir, 'boot', 'linux')
        initrd_path = os.path.join(boot_dir, 'boot', 'initrd.lz4')
        patched = os.path.join(tmpdir, 'patched-boot.img')

        patch_bootimg(
            stock_path=stock_bootimg,
            kernel_path=kernel_path,
            initrd_path=initrd_path,
            output_path=patched,
            verbose=verbose,
        )

        bootimg_size = os.path.getsize(patched)
        with open(patched, 'rb') as src:
            with open(output, 'r+b') as dst:
                dst.seek(BOOT_SECTOR * SECTOR)
                dst.write(src.read())
        if verbose:
            print(f"  Written {bootimg_size} bytes at sector {BOOT_SECTOR}")

        # Step 4: Create BATOCERA FAT32 partition
        if verbose:
            print(f"\nStep 4/6: Creating BATOCERA partition "
                  f"({batocera_sectors * SECTOR / (1024**3):.1f} GB FAT32)...")
        fat32 = os.path.join(tmpdir, 'batocera.fat32')
        create_fat32(fat32, batocera_sectors * SECTOR, 'BATOCERA')
        mcopy_tree(fat32, boot_dir)

        with open(fat32, 'rb') as src:
            with open(output, 'r+b') as dst:
                dst.seek(BATOCERA_START * SECTOR)
                # Copy in chunks to avoid loading 2+GB into memory
                while True:
                    chunk = src.read(16 * 1024 * 1024)  # 16MB chunks
                    if not chunk:
                        break
                    dst.write(chunk)
        if verbose:
            print(f"  Written at sector {BATOCERA_START}")

        # Step 5: Create empty SHARE FAT32 placeholder
        if verbose:
            print("Step 5/6: Creating SHARE partition placeholder...")
        share = os.path.join(tmpdir, 'share.fat32')
        create_fat32(share, share_sectors * SECTOR, 'SHARE')

        with open(share, 'rb') as src:
            with open(output, 'r+b') as dst:
                dst.seek(share_start * SECTOR)
                while True:
                    chunk = src.read(16 * 1024 * 1024)
                    if not chunk:
                        break
                    dst.write(chunk)
        if verbose:
            print(f"  Written at sector {share_start}")

    # Step 6: Write GPT partition table
    if verbose:
        print("Step 6/6: Writing GPT partition table...")

    with open(output, 'r+b') as f:
        # Read GammaOS partition entries from the dump's GPT
        f.seek(2 * SECTOR)
        existing_entries = f.read(128 * 128)

    gammaos_entries = []
    for i in range(7):
        entry = existing_entries[i * 128:(i + 1) * 128]
        if entry[:16] == b'\x00' * 16:
            break
        gammaos_entries.append(bytearray(entry))
        if verbose:
            first = struct.unpack_from('<Q', entry, 32)[0]
            last = struct.unpack_from('<Q', entry, 40)[0]
            name = entry[56:128].decode('utf-16-le').rstrip('\x00')
            print(f"  GammaOS: '{name}' sectors {first}-{last}")

    # Build full entry table: GammaOS partitions + BATOCERA + SHARE
    entries = bytearray(128 * 128)
    for i, e in enumerate(gammaos_entries):
        entries[i * 128:(i + 1) * 128] = e

    n = len(gammaos_entries)
    entries[n * 128:(n + 1) * 128] = make_gpt_entry(
        MSBASIC_GUID, BATOCERA_START, batocera_end, 'BATOCERA')
    entries[(n + 1) * 128:(n + 2) * 128] = make_gpt_entry(
        MSBASIC_GUID, share_start, share_end, 'SHARE')

    if verbose:
        print(f"  BATOCERA: sectors {BATOCERA_START}-{batocera_end}")
        print(f"  SHARE:    sectors {share_start}-{share_end}")

    entries_crc = binascii.crc32(bytes(entries)) & 0xFFFFFFFF
    disk_guid = uuid.uuid4().bytes_le
    last_usable = total_sectors - 34
    backup_hdr_lba = total_sectors - 1
    backup_entries_lba = backup_hdr_lba - 32

    primary = make_gpt_header(
        1, backup_hdr_lba, 2, last_usable, disk_guid, entries_crc)
    backup = make_gpt_header(
        backup_hdr_lba, 1, backup_entries_lba, last_usable,
        disk_guid, entries_crc)
    mbr = make_protective_mbr(total_sectors)

    with open(output, 'r+b') as f:
        f.seek(0)
        f.write(mbr)
        f.seek(SECTOR)
        f.write(primary)
        f.seek(2 * SECTOR)
        f.write(entries)
        f.seek(backup_entries_lba * SECTOR)
        f.write(entries)
        f.seek(backup_hdr_lba * SECTOR)
        f.write(backup)

    if verbose:
        final_size = os.path.getsize(output)
        print(f"\nDisk image created: {output}")
        print(f"  Size: {final_size / (1024**3):.2f} GB")
        print(f"  Compress: pigz {output}")
        print(f"  Flash:    dd if={output} of=/dev/sdX bs=4M status=progress")
        print(f"  Or use balenaEtcher / Rufus")


def main():
    parser = argparse.ArgumentParser(
        description='Build a flashable disk image for the Miyoo Flip (RK3566)'
    )
    parser.add_argument('--gammaos-dump', required=True,
                        help='Path to first-64mb.bin (GammaOS SD dump)')
    parser.add_argument('--stock-bootimg', required=True,
                        help='Path to stock GammaOS boot.img')
    parser.add_argument('--boot-dir', required=True,
                        help='Path to Knulli boot directory tree')
    parser.add_argument('--output', required=True,
                        help='Output .img file path')
    parser.add_argument('--batocera-size', default='2G',
                        help='BATOCERA partition size (default: 2G)')
    parser.add_argument('--share-size', default='128M',
                        help='SHARE partition size (default: 128M)')
    parser.add_argument('--quiet', action='store_true',
                        help='Suppress verbose output')

    args = parser.parse_args()

    for path, name in [(args.gammaos_dump, 'GammaOS dump'),
                       (args.stock_bootimg, 'stock boot.img'),
                       (args.boot_dir, 'boot directory')]:
        if not os.path.exists(path):
            print(f"Error: {name} not found: {path}", file=sys.stderr)
            sys.exit(1)

    for tool in ['mcopy', 'mmd']:
        if shutil.which(tool) is None:
            print(f"Error: '{tool}' not found. Install mtools "
                  f"(apt install mtools / brew install mtools).",
                  file=sys.stderr)
            sys.exit(1)

    if not (shutil.which('mkfs.fat') or shutil.which('newfs_msdos')):
        print("Error: Neither mkfs.fat nor newfs_msdos found. "
              "Install dosfstools.", file=sys.stderr)
        sys.exit(1)

    create_disk_image(
        gammaos_dump=args.gammaos_dump,
        stock_bootimg=args.stock_bootimg,
        boot_dir=args.boot_dir,
        output=args.output,
        batocera_sectors=parse_size(args.batocera_size) // SECTOR,
        share_sectors=parse_size(args.share_size) // SECTOR,
        verbose=not args.quiet,
    )


if __name__ == '__main__':
    main()
