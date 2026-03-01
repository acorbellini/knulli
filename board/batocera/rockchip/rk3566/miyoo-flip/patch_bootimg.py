#!/usr/bin/env python3
"""
Patch a stock GammaOS boot.img with Knulli components for the Miyoo Flip.

This replaces the kernel, ramdisk, cmdline, and DTB bootargs in a stock
Android boot.img v2, then recalculates the SHA-1 hash so boot_android
accepts it. The X.509 signature is preserved at its original offset.

Usage:
    python3 patch-bootimg.py \
        --stock-bootimg gammaos-boot.img \
        --kernel boot/linux \
        --initrd boot/initrd.lz4 \
        --output patched-boot.img \
        [--cmdline 'label=BATOCERA rootwait ...'] \
        [--dtb-bootargs 'label=BATOCERA loglevel=7']

The initrd can be LZ4 or GZIP compressed. If LZ4, it will be decompressed
and re-compressed as GZIP (stock GammaOS ramdisk uses GZIP).
"""

import argparse
import gzip
import hashlib
import io
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile


DEFAULT_CMDLINE = b'label=BATOCERA rootwait loglevel=7 console=tty0 console=ttyFIQ0'
DEFAULT_DTB_BOOTARGS = b'label=BATOCERA loglevel=7'
DTB_BOOTARGS_NEEDLE = b'mtdparts=spi-nand0:'

# DTB properties to add/set in the embedded DTBs.
# Each entry: (node_path, property_name, type, value)
# type: 'u32' for integers, 'str' for strings
DTB_PROPERTY_PATCHES = [
    # Battery fuel gauge - missing properties cause dmesg warnings and
    # inaccurate battery percentage (fb_temperature defaults to 115C)
    ('/battery', 'fb_temperature', 'u32', 105),
    ('/battery', 'energy_mode', 'u32', 0),
    ('/battery', 'zero_reserve_dsoc', 'u32', 10),
    ('/battery', 'low_power_sleep', 'u32', 1),
    # Charger - sample_res must match battery node (10 mOhm)
    ('/charger', 'sample_res', 'u32', 10),
    ('/charger', 'power_dc2otg', 'u32', 0),
    ('/charger', 'otg5v_suspend_enable', 'u32', 1),
    # Audio - the stock GammaOS DTB has the speaker amplifier GPIO in the
    # wrong node (rk817-sound as spk-con-gpios) instead of the codec node
    # (spk-ctl-gpios). The rk817 codec driver only reads spk-ctl-gpios from
    # its own node to control the speaker amplifier enable pin.
    # GPIO4 pin 18 (phandle 0x41), active high.
    ('/codec', 'spk-ctl-gpios', 'cells', [0x41, 0x12, 0x00]),
    # Hall sensor polarity. The mh248 driver convention:
    # gpio_value != active_value → KEY_POWER (suspend),
    # gpio_value == active_value → KEY_WAKEUP (wake).
    # GPIO reads: 0=closed, 1=open. So active_value=1 gives:
    # close(0!=1)→suspend, open(1==1)→wake. Correct.
    ('/hall-mh248', 'hall-active', 'u32', 1),
]

# DTB properties to remove from the embedded DTBs.
# Each entry: (node_path, property_name)
DTB_PROPERTY_REMOVALS = [
    # Remove misplaced speaker GPIO from machine driver node - it gets claimed
    # as INPUT by the ASoC framework, blocking the codec driver from using it.
    ('/rk817-sound', 'spk-con-gpios'),
    # Remove existing hall-active so it can be re-added with the correct value.
    # Needed because update-miyoo-flip.sh re-patches the on-card boot.img,
    # which may already have a stale value from a prior flash.
    ('/hall-mh248', 'hall-active'),
]


FDT_MAGIC = b'\xd0\x0d\xfe\xed'


def pages(size, page_size):
    return ((size + page_size - 1) // page_size) * page_size


def find_dtb_offsets(data, start=0):
    """Find all FDT (device tree blob) offsets in binary data."""
    offsets = []
    pos = start
    while True:
        idx = data.find(FDT_MAGIC, pos)
        if idx < 0:
            break
        # Read totalsize from FDT header (big-endian u32 at offset 4)
        if idx + 8 <= len(data):
            total_size = struct.unpack_from('>I', data, idx + 4)[0]
            if 1024 < total_size < 1024 * 1024:  # sanity: 1KB-1MB
                offsets.append((idx, total_size))
        pos = idx + 4
    return offsets


def patch_dtb_properties(data, dtb_offset, dtb_size, patches,
                         removals=None, verbose=True):
    """Patch properties in an embedded DTB using dtc decompile/recompile.

    Extracts the DTB, decompiles to DTS text, removes unwanted properties,
    adds missing properties, recompiles with dtc -p 0 (no padding),
    and writes it back.

    Returns (modified_data, new_dtb_size). The caller is responsible for
    updating any external size references (e.g., RSCE entry) if the DTB grew.
    """
    dtb_data = data[dtb_offset:dtb_offset + dtb_size]

    with tempfile.NamedTemporaryFile(suffix='.dtb', delete=False) as f:
        f.write(dtb_data)
        dtb_path = f.name

    dts_path = dtb_path + '.dts'
    new_dtb_path = dtb_path + '.new'

    try:
        # Decompile DTB to DTS
        result = subprocess.run(
            ['dtc', '-q', '-I', 'dtb', '-O', 'dts', '-o', dts_path, dtb_path],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            if verbose:
                print(f"  dtc decompile failed, skipping DTB property patches")
            return data, dtb_size

        with open(dts_path, 'r') as f:
            dts_text = f.read()

        # Remove unwanted properties
        total_removed = 0
        if removals:
            removals_by_node = {}
            for node_suffix, prop in removals:
                node_name = node_suffix.lstrip('/')
                removals_by_node.setdefault(node_name, []).append(prop)
            for node_name, props in removals_by_node.items():
                dts_text, count = _remove_properties_from_node(
                    dts_text, node_name, props)
                total_removed += count

        # Group patches by node name
        patches_by_node = {}
        for node_suffix, prop, ptype, value in patches:
            node_name = node_suffix.lstrip('/')
            patches_by_node.setdefault(node_name, []).append((prop, ptype, value))

        # Add properties to each target node
        total_added = 0
        for node_name, props in patches_by_node.items():
            dts_text, count = _add_properties_to_node(dts_text, node_name, props)
            total_added += count

        if total_added == 0 and total_removed == 0:
            if verbose:
                print(f"  No properties to patch in DTB at offset {dtb_offset}")
            return data, dtb_size

        # Write modified DTS
        with open(dts_path, 'w') as f:
            f.write(dts_text)

        # Recompile with no extra padding
        result = subprocess.run(
            ['dtc', '-q', '-I', 'dts', '-O', 'dtb', '-p', '0',
             '-o', new_dtb_path, dts_path],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            if verbose:
                print(f"  dtc recompile failed: {result.stderr.strip()}")
            return data, dtb_size

        with open(new_dtb_path, 'rb') as f:
            new_dtb = f.read()

        # Write patched DTB back (may be larger than original - caller
        # handles RSCE size update; overflow into adjacent bitmaps is
        # acceptable since they're just U-Boot splash screens)
        data = bytearray(data)
        data[dtb_offset:dtb_offset + len(new_dtb)] = new_dtb
        if len(new_dtb) < dtb_size:
            # Pad to original size
            data[dtb_offset + len(new_dtb):dtb_offset + dtb_size] = \
                b'\x00' * (dtb_size - len(new_dtb))
        data = bytes(data)

        if verbose:
            total_changes = total_added + total_removed
            delta = len(new_dtb) - dtb_size
            if delta > 0:
                print(f"  Patched DTB at offset {dtb_offset} "
                      f"(+{total_added}/-{total_removed} props): "
                      f"{dtb_size} -> {len(new_dtb)} bytes (grew by {delta})")
            else:
                print(f"  Patched DTB at offset {dtb_offset} "
                      f"(+{total_added}/-{total_removed} props): "
                      f"{dtb_size} -> {len(new_dtb)} bytes "
                      f"({-delta} bytes to spare)")

        return data, len(new_dtb)

    finally:
        for p in [dtb_path, dts_path, new_dtb_path]:
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


RSCE_MAGIC = b'RSCE'
RSCE_ENTRY_MAGIC = b'ENTR'


def update_rsce_dtb_size(data, rsce_offset, new_size, verbose=True):
    """Update the rk-kernel.dtb entry size in the RSCE (Rockchip Resource Image).

    Scans the RSCE entry table for the DTB entry and updates its content_size
    field so U-Boot reads the full (possibly enlarged) DTB.

    Each RSCE entry is 512 bytes:
      - 4 bytes: "ENTR" magic
      - 256 bytes: filename (null-terminated)
      - 4 bytes: content_offset (in 512-byte blocks from RSCE start)
      - 4 bytes: content_size (in bytes)
    """
    data = bytearray(data)

    # Scan for ENTR markers in the RSCE header area (first ~64KB)
    pos = rsce_offset + 512  # entries start after 512-byte RSCE header
    end = min(rsce_offset + 65536, len(data))

    while pos < end:
        if data[pos:pos + 4] != RSCE_ENTRY_MAGIC:
            pos += 512
            continue

        name = data[pos + 4:pos + 4 + 256].split(b'\x00')[0].decode('ascii', errors='replace')
        size_offset = pos + 4 + 256 + 4  # skip ENTR + name + offset
        old_size = struct.unpack_from('<I', data, size_offset)[0]

        if name == 'rk-kernel.dtb':
            struct.pack_into('<I', data, size_offset, new_size)
            if verbose:
                print(f"  RSCE: updated '{name}' size {old_size} -> {new_size}")
            return bytes(data)

        pos += 512

    if verbose:
        print(f"  RSCE: rk-kernel.dtb entry not found, cannot update size")
    return bytes(data)


def _add_properties_to_node(dts_text, node_name, properties):
    """Add missing properties to a named node in DTS text.

    Finds the node by name (e.g., 'battery'), checks which properties
    are already present, and inserts missing ones before the closing '};'.

    Returns (modified_text, count_of_added_properties).
    """
    pattern = re.compile(
        r'^(\s*)' + re.escape(node_name) + r'(?:@[0-9a-fA-F]+)?\s*\{',
        re.MULTILINE
    )

    match = pattern.search(dts_text)
    if not match:
        return dts_text, 0

    indent = match.group(1)
    prop_indent = indent + '\t'

    # Find the matching closing brace
    start = match.end()
    depth = 1
    pos = start
    while pos < len(dts_text) and depth > 0:
        if dts_text[pos] == '{':
            depth += 1
        elif dts_text[pos] == '}':
            depth -= 1
        pos += 1

    if depth != 0:
        return dts_text, 0

    # Extract just this node's content (for property existence check)
    close_brace_pos = pos - 1
    node_content = dts_text[match.start():close_brace_pos]

    # Filter out properties that already exist
    new_props = []
    for prop, ptype, value in properties:
        prop_re = re.compile(r'^\s+' + re.escape(prop) + r'\s*=', re.MULTILINE)
        if not prop_re.search(node_content):
            new_props.append((prop, ptype, value))

    if not new_props:
        return dts_text, 0

    # Build property lines
    prop_lines = []
    for prop, ptype, value in new_props:
        if ptype == 'u32':
            prop_lines.append(f'{prop_indent}{prop} = <{value:#x}>;')
        elif ptype == 'cells':
            cells = ' '.join(f'{v:#x}' for v in value)
            prop_lines.append(f'{prop_indent}{prop} = <{cells}>;')
        else:
            prop_lines.append(f'{prop_indent}{prop} = "{value}";')

    insert_text = '\n'.join(prop_lines) + '\n'
    dts_text = dts_text[:close_brace_pos] + insert_text + dts_text[close_brace_pos:]

    return dts_text, len(new_props)


def _remove_properties_from_node(dts_text, node_name, properties):
    """Remove properties from a named node in DTS text.

    Returns (modified_text, count_of_removed_properties).
    """
    pattern = re.compile(
        r'^(\s*)' + re.escape(node_name) + r'(?:@[0-9a-fA-F]+)?\s*\{',
        re.MULTILINE
    )

    match = pattern.search(dts_text)
    if not match:
        return dts_text, 0

    # Find the matching closing brace
    start = match.end()
    depth = 1
    pos = start
    while pos < len(dts_text) and depth > 0:
        if dts_text[pos] == '{':
            depth += 1
        elif dts_text[pos] == '}':
            depth -= 1
        pos += 1

    if depth != 0:
        return dts_text, 0

    close_brace_pos = pos - 1
    node_content = dts_text[match.start():close_brace_pos]

    count = 0
    for prop in properties:
        prop_re = re.compile(r'^\s+' + re.escape(prop) + r'\s*=\s*[^;]*;\n?',
                             re.MULTILINE)
        node_content, n = prop_re.subn('', node_content)
        count += n

    if count == 0:
        return dts_text, 0

    dts_text = dts_text[:match.start()] + node_content + dts_text[close_brace_pos:]
    return dts_text, count


def read_header(data):
    """Parse an Android boot.img v2 header (first 2048 bytes)."""
    if data[:8] != b'ANDROID!':
        raise ValueError(f"Not an Android boot image (magic: {data[:8]})")

    h = {}
    h['kernel_size'] = struct.unpack_from('<I', data, 8)[0]
    h['kernel_addr'] = struct.unpack_from('<I', data, 12)[0]
    h['ramdisk_size'] = struct.unpack_from('<I', data, 16)[0]
    h['ramdisk_addr'] = struct.unpack_from('<I', data, 20)[0]
    h['second_size'] = struct.unpack_from('<I', data, 24)[0]
    h['page_size'] = struct.unpack_from('<I', data, 36)[0]
    h['header_version'] = struct.unpack_from('<I', data, 40)[0]
    h['cmdline'] = data[64:576].split(b'\x00')[0]
    h['sha1'] = data[576:596].hex()
    h['extra_cmdline'] = data[608:1632].split(b'\x00')[0]
    h['recovery_dtbo_size'] = struct.unpack_from('<I', data, 1632)[0]
    h['dtb_size'] = struct.unpack_from('<I', data, 1648)[0]
    return h


def prepare_gzip_ramdisk(initrd_path):
    """Convert an initrd to GZIP format. Handles LZ4, GZIP, and CPIO inputs."""
    with open(initrd_path, 'rb') as f:
        magic = f.read(4)

    if magic[:2] == b'\x1f\x8b':
        # Already GZIP
        with open(initrd_path, 'rb') as f:
            return f.read()

    if magic == b'\x04\x22\x4d\x18' or magic == b'\x02\x21\x4c\x18':
        # LZ4 frame format (04224d18) or LZ4 legacy format (02214c18)
        result = subprocess.run(
            ['lz4', '-d', initrd_path, '-c'],
            capture_output=True, check=True
        )
        cpio_data = result.stdout
    elif magic[:2] == b'\x30\x37':
        # Raw CPIO (starts with "07" in ASCII = 0x30 0x37)
        with open(initrd_path, 'rb') as f:
            cpio_data = f.read()
    else:
        raise ValueError(
            f"Unknown initrd format (magic: {magic.hex()}). "
            f"Expected LZ4 (04224d18), GZIP (1f8b), or CPIO (3037)."
        )

    # Compress as GZIP (matching stock GammaOS ramdisk format)
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode='wb', compresslevel=9, mtime=0) as gz:
        gz.write(cpio_data)
    return buf.getvalue()


def patch_bootimg(stock_path, kernel_path, initrd_path, output_path,
                  cmdline=None, dtb_bootargs=None, verbose=True):
    """
    Patch a stock boot.img with new kernel, ramdisk, cmdline, and DTB bootargs.

    Returns a dict with patching details for logging/verification.
    """
    if cmdline is None:
        cmdline = DEFAULT_CMDLINE
    if isinstance(cmdline, str):
        cmdline = cmdline.encode()
    if dtb_bootargs is None:
        dtb_bootargs = DEFAULT_DTB_BOOTARGS
    if isinstance(dtb_bootargs, str):
        dtb_bootargs = dtb_bootargs.encode()

    result = {}

    # Copy stock boot.img to output
    shutil.copy2(stock_path, output_path)

    # Prepare GZIP ramdisk
    if verbose:
        print(f"  Preparing ramdisk from {initrd_path}...")
    gzip_ramdisk = prepare_gzip_ramdisk(initrd_path)
    result['ramdisk_gz_size'] = len(gzip_ramdisk)

    # Read kernel
    with open(kernel_path, 'rb') as f:
        kernel_data = f.read()
    result['kernel_size'] = len(kernel_data)

    with open(output_path, 'r+b') as f:
        header = bytearray(f.read(2048))
        h = read_header(header)
        page_size = h['page_size']

        # Offsets
        kernel_offset = page_size
        ramdisk_offset = kernel_offset + pages(h['kernel_size'], page_size)

        # 1. Patch kernel
        if len(kernel_data) > h['kernel_size']:
            raise ValueError(
                f"Kernel too large: {len(kernel_data)} > {h['kernel_size']} "
                f"({len(kernel_data) - h['kernel_size']} bytes over)"
            )
        f.seek(kernel_offset)
        f.write(kernel_data)
        if len(kernel_data) < h['kernel_size']:
            f.write(b'\x00' * (h['kernel_size'] - len(kernel_data)))
        if verbose:
            print(f"  Kernel: {len(kernel_data)} bytes (stock: {h['kernel_size']}, "
                  f"{h['kernel_size'] - len(kernel_data)} spare)")

        # 2. Patch ramdisk
        if len(gzip_ramdisk) > h['ramdisk_size']:
            raise ValueError(
                f"Ramdisk too large: {len(gzip_ramdisk)} > {h['ramdisk_size']} "
                f"({len(gzip_ramdisk) - h['ramdisk_size']} bytes over)"
            )
        f.seek(ramdisk_offset)
        f.write(gzip_ramdisk)
        if len(gzip_ramdisk) < h['ramdisk_size']:
            f.write(b'\x00' * (h['ramdisk_size'] - len(gzip_ramdisk)))
        if verbose:
            print(f"  Ramdisk: {len(gzip_ramdisk)} bytes (stock: {h['ramdisk_size']}, "
                  f"{h['ramdisk_size'] - len(gzip_ramdisk)} spare)")

        # 3. Patch cmdline in header bytearray
        header[64:64 + len(cmdline)] = cmdline
        header[64 + len(cmdline):576] = b'\x00' * (512 - len(cmdline))
        header[608:1632] = b'\x00' * 1024  # Clear extra_cmdline
        result['cmdline'] = cmdline.decode()
        if verbose:
            print(f"  Cmdline: {cmdline.decode()}")

        # 4. Patch DTB bootargs (replace mtdparts= with our bootargs)
        rsce_offset = ramdisk_offset + pages(h['ramdisk_size'], page_size)
        patch_count = 0
        search_start = rsce_offset

        while True:
            f.seek(0)
            full_data = f.read()
            ba_idx = full_data.find(DTB_BOOTARGS_NEEDLE, search_start)
            if ba_idx < 0:
                break
            ba_end = full_data.index(b'\x00', ba_idx)
            old_len = ba_end - ba_idx
            padded = dtb_bootargs + b' ' * (old_len - len(dtb_bootargs))
            f.seek(ba_idx)
            f.write(padded)
            patch_count += 1
            search_start = ba_idx + len(padded)

        result['dtb_patches'] = patch_count
        if verbose:
            print(f"  DTB bootargs: patched {patch_count} instance(s)")

        # 4b. Patch DTB properties (battery/charger, audio, hall sensor)
        if DTB_PROPERTY_PATCHES or DTB_PROPERTY_REMOVALS:
            if verbose:
                print(f"  Patching DTB properties...")
            f.seek(0)
            full_data = f.read()
            dtb_offsets = find_dtb_offsets(full_data, rsce_offset)
            prop_patch_count = 0
            for dtb_off, dtb_sz in dtb_offsets:
                full_data, new_sz = patch_dtb_properties(
                    full_data, dtb_off, dtb_sz,
                    DTB_PROPERTY_PATCHES,
                    removals=DTB_PROPERTY_REMOVALS,
                    verbose=verbose,
                )
                # If the DTB grew and it's inside the RSCE section,
                # update the RSCE entry size so U-Boot reads the full DTB
                if new_sz > dtb_sz and rsce_offset <= dtb_off:
                    full_data = update_rsce_dtb_size(
                        full_data, rsce_offset, new_sz, verbose=verbose
                    )
                prop_patch_count += 1
            # Write back the full patched data
            f.seek(0)
            f.write(full_data)
            result['dtb_prop_patches'] = prop_patch_count

        # 5. Recalculate SHA-1 hash
        second_offset = rsce_offset
        recovery_dtbo_offset = second_offset + pages(h['second_size'], page_size)
        dtb_offset = recovery_dtbo_offset + pages(h['recovery_dtbo_size'], page_size)

        f.seek(kernel_offset)
        k_data = f.read(h['kernel_size'])
        f.seek(ramdisk_offset)
        r_data = f.read(h['ramdisk_size'])
        f.seek(second_offset)
        s_data = f.read(h['second_size'])
        rd_data = b''
        if h['recovery_dtbo_size'] > 0:
            f.seek(recovery_dtbo_offset)
            rd_data = f.read(h['recovery_dtbo_size'])
        f.seek(dtb_offset)
        d_data = f.read(h['dtb_size'])

        sha = hashlib.sha1()
        sha.update(k_data)
        sha.update(struct.pack('<I', h['kernel_size']))
        sha.update(r_data)
        sha.update(struct.pack('<I', h['ramdisk_size']))
        sha.update(s_data)
        sha.update(struct.pack('<I', h['second_size']))
        sha.update(rd_data)
        sha.update(struct.pack('<I', h['recovery_dtbo_size']))
        sha.update(d_data)
        sha.update(struct.pack('<I', h['dtb_size']))
        new_sha = sha.digest()

        old_sha = bytes(header[576:596])
        header[576:596] = new_sha
        header[596:608] = b'\x00' * 12

        # Write updated header (with cmdline + SHA-1)
        f.seek(0)
        f.write(header)

        result['old_sha1'] = old_sha.hex()
        result['new_sha1'] = new_sha.hex()
        result['output_size'] = os.path.getsize(output_path)
        result['stock_size'] = os.path.getsize(stock_path)

        if verbose:
            print(f"  SHA-1: {old_sha.hex()} -> {new_sha.hex()}")
            print(f"  Output: {output_path} ({result['output_size']} bytes, "
                  f"matches stock: {result['output_size'] == result['stock_size']})")

    return result


def main():
    parser = argparse.ArgumentParser(
        description='Patch a stock GammaOS boot.img with Knulli components'
    )
    parser.add_argument('--stock-bootimg', required=True,
                        help='Path to stock GammaOS boot.img')
    parser.add_argument('--kernel', required=True,
                        help='Path to Knulli kernel (Image)')
    parser.add_argument('--initrd', required=True,
                        help='Path to Knulli initrd (LZ4 or GZIP)')
    parser.add_argument('--output', required=True,
                        help='Output path for patched boot.img')
    parser.add_argument('--cmdline', default=None,
                        help=f'Kernel cmdline (default: {DEFAULT_CMDLINE.decode()})')
    parser.add_argument('--dtb-bootargs', default=None,
                        help=f'DTB bootargs replacement (default: {DEFAULT_DTB_BOOTARGS.decode()})')
    parser.add_argument('--quiet', action='store_true',
                        help='Suppress verbose output')

    args = parser.parse_args()

    for path, name in [(args.stock_bootimg, 'stock boot.img'),
                       (args.kernel, 'kernel'),
                       (args.initrd, 'initrd')]:
        if not os.path.isfile(path):
            print(f"Error: {name} not found: {path}", file=sys.stderr)
            sys.exit(1)

    result = patch_bootimg(
        stock_path=args.stock_bootimg,
        kernel_path=args.kernel,
        initrd_path=args.initrd,
        output_path=args.output,
        cmdline=args.cmdline,
        dtb_bootargs=args.dtb_bootargs,
        verbose=not args.quiet,
    )

    if not args.quiet:
        print("  Done!")


if __name__ == '__main__':
    main()
