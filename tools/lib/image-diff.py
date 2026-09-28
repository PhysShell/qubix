#!/usr/bin/env python3
"""Where two builds of one disk image differ, named by the structure there.

    image-diff.py vhdx A.vhdx B.vhdx   the container: header, region table,
                                       log, BAT, metadata item, payload block
    image-diff.py raw A.raw B.raw      the disk inside: GPT, then per partition
                                       the FAT or ext4 field, or the fs block

Used by tools/repro-census.sh.  It reads and names; it never writes.  The
layouts are the documented ones: [MS-VHDX] v1.0 for the container, UEFI 2.x
for GPT, and the ext4 and FAT on-disk formats for the superblock and boot
sector fields it can put a name to.
"""
import bisect
import hashlib
import os
import re
import struct
import sys
import uuid

CHUNK = 1 << 20
NONZERO = re.compile(rb"[^\x00]+")


def diff_runs(a_path, b_path):
    """Differing byte runs as (start, end) pairs: every byte in one differs.

    A MiB at a time; where two MiB differ, their XOR is scanned for non-zero
    runs by the regex engine rather than byte by byte in Python, which is the
    difference between seconds and an hour on an image that differs a lot.
    A generator, because such an image has tens of millions of runs.
    """
    run = None
    with open(a_path, "rb") as a, open(b_path, "rb") as b:
        pos = 0
        while True:
            # A hole in both files reads as zeros in both: skip to the next
            # data either of them has.  The raw images are mostly holes.
            ahead = [n for n in (next_data(a, pos), next_data(b, pos)) if n is not None]
            if not ahead:
                break
            nxt = min(ahead)
            if nxt >= pos + CHUNK:
                pos = nxt - nxt % CHUNK
            a.seek(pos)
            b.seek(pos)
            x = a.read(CHUNK)
            y = b.read(CHUNK)
            if not x and not y:
                break
            n = max(len(x), len(y))
            if x != y:
                z = (int.from_bytes(x.ljust(n, b"\0"), "little")
                     ^ int.from_bytes(y.ljust(n, b"\0"), "little")).to_bytes(n, "little")
                for m in NONZERO.finditer(z):
                    start, end = pos + m.start(), pos + m.end()
                    if run and start == run[1]:
                        run = (run[0], end)
                    else:
                        if run:
                            yield run
                        run = (start, end)
            pos += n
    if run:
        yield run


def next_data(f, pos):
    """Offset of the next non-hole byte at or after pos, None past the end."""
    try:
        return os.lseek(f.fileno(), pos, os.SEEK_DATA)
    except OSError:
        return None


def nonzero_blocks(path, start, end, size):
    """How many times each non-zero block's content occurs in [start, end)."""
    counts = {}
    with open(path, "rb") as f:
        pos = start
        while pos < end:
            data = next_data(f, pos)
            if data is None or data >= end:
                break
            pos = max(pos, data - (data - start) % size)
            f.seek(pos)
            chunk = f.read(min(CHUNK, end - pos))
            for i in range(0, len(chunk), size):
                blk = chunk[i:i + size]
                if blk.count(0) != len(blk):
                    key = hashlib.blake2b(blk, digest_size=16).digest()
                    counts[key] = counts.get(key, 0) + 1
            pos += len(chunk)
    return counts


def ms_guid(text):
    return uuid.UUID(text).bytes_le


# --- VHDX -----------------------------------------------------------------

KiB, MiB = 1024, 1 << 20
BAT_GUID = ms_guid("2DC27766-F623-4200-9D64-115E9BFD4A08")
META_GUID = ms_guid("8B7CA206-4790-4B9A-B8FE-575F050F886E")
META_ITEMS = {
    ms_guid("CAA16737-FA36-4D43-B3B6-33F0AA44E76B"): "file parameters",
    ms_guid("2FA54224-CD1B-4876-B211-5DBED83BF4B8"): "virtual disk size",
    ms_guid("BECA12AB-B2E6-4523-93EF-C309E000C746"): "page 83 data",
    ms_guid("8141BF1D-A96F-4709-BA47-F233A8FAAB5F"): "logical sector size",
    ms_guid("CDA348C7-445D-4471-9CC9-E9885251C556"): "physical sector size",
}
HEADER_FIELDS = [  # offset, length, name
    (0, 4, "signature"), (4, 4, "checksum"), (8, 8, "sequence number"),
    (16, 16, "file write GUID"), (32, 16, "data write GUID"),
    (48, 16, "log GUID"), (64, 2, "log version"), (66, 2, "version"),
    (68, 4, "log length"), (72, 8, "log offset"),
]


def vhdx_regions(path):
    """(start, end, name) for every structure of a VHDX file."""
    with open(path, "rb") as f:
        def at(off, n):
            f.seek(off)
            return f.read(n)

        if at(0, 8) != b"vhdxfile":
            sys.exit(f"{path}: not a VHDX file")
        regions = [(0, 64 * KiB, "file type identifier")]
        headers = []
        for i, off in enumerate((64 * KiB, 128 * KiB), 1):
            h = at(off, 4096)
            seq = struct.unpack_from("<Q", h, 8)[0]
            headers.append((seq, h))
            for fo, fl, name in HEADER_FIELDS:
                regions.append((off + fo, off + fo + fl, f"header {i}: {name}"))
            regions.append((off + 80, off + 64 * KiB, f"header {i}: reserved"))
        for i, off in enumerate((192 * KiB, 256 * KiB), 1):
            regions.append((off, off + 64 * KiB, f"region table {i}"))
        current = max(headers)[1]
        log_length, log_offset = struct.unpack_from("<IQ", current, 68)
        regions.append((log_offset, log_offset + log_length, "log"))

        table = at(192 * KiB, 64 * KiB)
        count = struct.unpack_from("<I", table, 8)[0]
        bat = meta = None
        for e in range(count):
            guid, off, length = struct.unpack_from("<16sQI", table, 16 + 32 * e)
            if guid == BAT_GUID:
                bat = (off, length)
            elif guid == META_GUID:
                meta = (off, length)
        regions.append((bat[0], bat[0] + bat[1], "BAT"))

        m = at(meta[0], meta[1])
        entries = struct.unpack_from("<H", m, 10)[0]
        regions.append((meta[0], meta[0] + 32 + 32 * entries, "metadata table"))
        items = {}
        for e in range(entries):
            item, off, length = struct.unpack_from("<16sII", m, 32 + 32 * e)
            name = META_ITEMS.get(item, f"metadata item {uuid.UUID(bytes_le=item)}")
            items[name] = (off, length)
            regions.append((meta[0] + off, meta[0] + off + length, f"metadata: {name}"))

        block = struct.unpack_from("<I", m, items["file parameters"][0])[0]
        sector = struct.unpack_from("<I", m, items["logical sector size"][0])[0]
        chunk = (1 << 23) * sector // block
        raw_bat = at(bat[0], bat[1])
        payload = 0
        for e in range(bat[1] // 8):
            entry = struct.unpack_from("<Q", raw_bat, 8 * e)[0]
            off = (entry >> 20) * MiB
            if (e + 1) % (chunk + 1) == 0:
                if off:
                    regions.append((off, off + MiB, "sector bitmap"))
                continue
            if entry & 7 in (6, 7) and off:
                regions.append((off, off + block, f"payload block {payload}"))
            payload += 1
    return sorted(regions)


# --- raw disk ---------------------------------------------------------------

SECTOR = 512
EXT4_SB_FIELDS = [  # offset in the superblock, length, name
    (0x2C, 4, "s_mtime"), (0x30, 4, "s_wtime"), (0x34, 2, "s_mnt_count"),
    (0x40, 4, "s_lastcheck"), (0x68, 16, "s_uuid"),
    (0xD0, 16, "s_journal_uuid"), (0xEC, 16, "s_hash_seed"),
    (0x108, 4, "s_mkfs_time"), (0x10C, 68, "s_jnl_blocks"),
    (0x178, 8, "s_kbytes_written"), (0x270, 4, "s_checksum_seed"),
    (0x3FC, 4, "s_checksum"),
]


def gpt_partitions(f):
    f.seek(SECTOR)
    h = f.read(SECTOR)
    if h[:8] != b"EFI PART":
        return []
    entry_lba, count, size = struct.unpack_from("<QII", h, 72)
    f.seek(entry_lba * SECTOR)
    table = f.read(count * size)
    parts = []
    for i in range(count):
        e = table[i * size:(i + 1) * size]
        if e[:16] == b"\0" * 16:
            continue
        first, last = struct.unpack_from("<QQ", e, 32)
        name = e[56:128].decode("utf-16-le").rstrip("\0")
        parts.append((first * SECTOR, (last + 1) * SECTOR, i + 1, name))
    return parts


def fs_regions(f, start, end, label):
    """Names inside one partition: the fields worth naming, then blocks."""
    f.seek(start)
    boot = f.read(4096)
    regions = []
    if boot[0x52:0x5A] == b"FAT32   ":
        regions.append((start + 0x43, start + 0x47, f"{label}: FAT32 volume ID"))
        regions.append((start, start + SECTOR, f"{label}: FAT32 boot sector"))
        backup = struct.unpack_from("<H", boot, 0x32)[0]
        if backup:
            b = start + backup * SECTOR
            regions.append((b + 0x43, b + 0x47, f"{label}: FAT32 backup volume ID"))
        return regions, "FAT32", 4096
    if boot[0x36:0x3B] in (b"FAT12", b"FAT16"):
        regions.append((start + 0x27, start + 0x2B, f"{label}: FAT volume ID"))
        regions.append((start, start + SECTOR, f"{label}: FAT boot sector"))
        return regions, "FAT", 4096
    sb = boot[1024:2048]
    if sb[0x38:0x3A] == b"\x53\xef":
        block = 1024 << struct.unpack_from("<I", sb, 0x18)[0]
        base = start + 1024
        for fo, fl, name in EXT4_SB_FIELDS:
            regions.append((base + fo, base + fo + fl, f"{label}: ext4 superblock {name}"))
        regions.append((base, base + 1024, f"{label}: ext4 superblock, other"))
        return regions, "ext4", block
    return regions, "unknown", 4096


def raw_regions(path):
    with open(path, "rb") as f:
        size = f.seek(0, 2)
        parts = gpt_partitions(f)
        if not parts:
            # A bare filesystem, like the home seed: no partition table.
            regions, kind, block = fs_regions(f, 0, size, "filesystem")
            return sorted(regions), [(0, size, f"filesystem, {kind}", block)]
        regions = [(0, SECTOR, "protective MBR"), (SECTOR, 2 * SECTOR, "GPT header"),
                   (2 * SECTOR, 34 * SECTOR, "GPT entries"),
                   (size - 33 * SECTOR, size, "backup GPT")]
        blocks = []
        for start, end, n, name in parts:
            label = f"partition {n} ({name})"
            named, kind, block = fs_regions(f, start, end, label)
            regions += named
            blocks.append((start, end, f"{label}, {kind}", block))
    return sorted(regions), blocks


# --- report -----------------------------------------------------------------

def segments(regions):
    """The regions cut into disjoint pieces, each named by the smallest region
    covering it: fields sit inside structures, and the field is the answer."""
    cuts = sorted({x for r in regions for x in r[:2]})
    pieces = []
    for lo, hi in zip(cuts, cuts[1:]):
        over = [r for r in regions if r[0] <= lo and hi <= r[1]]
        if over:
            pieces.append((lo, hi, min(over, key=lambda r: r[1] - r[0])[2]))
    return pieces


class Classifier:
    """Bytes per named region; what no name covers, by partition and block."""

    def __init__(self, regions, blocks=()):
        self.pieces = segments(regions)
        self.starts = [p[0] for p in self.pieces]
        self.blocks = blocks
        self.named, self.loose = {}, {}

    def unnamed(self, lo, hi):
        for b0, b1, name, bs in self.blocks:
            if b0 <= lo < b1:
                hi = min(hi, b1)
                agg = self.loose.setdefault(f"{name} data", [0, set()])
                agg[0] += hi - lo
                agg[1].update(range((lo - b0) // bs, (hi - 1 - b0) // bs + 1))
                return hi
        agg = self.loose.setdefault("unaccounted", [0, set()])
        agg[0] += hi - lo
        return hi

    def add(self, s, e):
        pieces = self.pieces
        pos = s
        i = max(bisect.bisect_right(self.starts, pos) - 1, 0)
        while pos < e:
            while i < len(pieces) and pieces[i][1] <= pos:
                i += 1
            if i < len(pieces) and pieces[i][0] <= pos:
                stop = min(e, pieces[i][1])
                name = pieces[i][2]
                self.named[name] = self.named.get(name, 0) + stop - pos
                pos = stop
            else:
                gap_end = min(e, pieces[i][0]) if i < len(pieces) else e
                pos = self.unnamed(pos, gap_end)


def report(kind, a, b):
    if kind == "vhdx":
        c = Classifier(vhdx_regions(a))
    else:
        regions, blocks = raw_regions(a)
        c = Classifier(regions, blocks)
    total = count = 0
    for s, e in diff_runs(a, b):
        total += e - s
        count += 1
        c.add(s, e)
    sizes = {os.path.getsize(a), os.path.getsize(b)}
    size = f"{sizes.pop()} bytes" if len(sizes) == 1 else "sizes differ"
    print(f"{kind} ({size}): {total} bytes differ in {count} runs")
    # One line for all payload blocks: which of them differ is the layout,
    # and a line each would bury the handful of fields that matter.
    payload = {name: n for name, n in c.named.items() if name.startswith("payload block ")}
    rows = [(n, name) for name, n in c.named.items() if name not in payload]
    if payload:
        rows.append((sum(payload.values()), f"payload, in {len(payload)} blocks"))
    rows += [(n, f"{name} in {len(blks)} blocks" if blks else name)
             for name, (n, blks) in c.loose.items()]
    for n, name in sorted(rows, reverse=True):
        print(f"  {n:>12}  {name}")
    if kind == "raw":
        # Different bytes, or the same bytes somewhere else?  Where a filesystem
        # differs in many blocks, count the non-zero blocks whose content the
        # other image also has, wherever it put them.
        for b0, b1, name, bs in blocks:
            n, blks = c.loose.get(f"{name} data", (0, ()))
            if len(blks) < 64:
                continue
            x, y = nonzero_blocks(a, b0, b1, bs), nonzero_blocks(b, b0, b1, bs)
            both = sum(min(k, y.get(h, 0)) for h, k in x.items())
            have = sum(x.values())
            print(f"  {name}: {both} of its {have} non-zero blocks ({100 * both / have:.1f}%)"
                  f" hold content the other build has too, at whatever offset")
    return total


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in ("vhdx", "raw"):
        sys.exit(__doc__)
    report(sys.argv[1], sys.argv[2], sys.argv[3])
