#!/usr/bin/env python3
"""Writes a CISO v1 (`.cso`) from an ISO, the PSP's compressed format, for
Tools/disc-reader-test: the reader's `.cso` branch must hash a game exactly as
the ISO it was made from. Stdlib only.

    make_cso.py <in.iso> <out.cso> [--frame 2048] [--align 0]

Every frame is raw deflate unless that does not shrink it, in which case it is
stored plain with the index's high bit set, as maxcso and ciso.py write them, so
both kinds of frame are exercised. --frame and --align cover the header fields
PPSSPP reads (a frame of 2048 x 2^n, an index shift)."""
import argparse, struct, zlib

ap = argparse.ArgumentParser()
ap.add_argument("src"); ap.add_argument("dst")
ap.add_argument("--frame", type=int, default=2048)
ap.add_argument("--align", type=int, default=0)
a = ap.parse_args()

data_len = None
with open(a.src, "rb") as f:
    f.seek(0, 2); total = f.tell(); f.seek(0)
    frames = (total + a.frame - 1) // a.frame
    header = b"CISO" + struct.pack("<IQIBB2x", 0x18, total, a.frame, 1, a.align)
    index_bytes = (frames + 1) * 4
    with open(a.dst, "wb") as o:
        o.write(header); o.write(b"\0" * index_bytes)
        pos = len(header) + index_bytes
        index = []
        plain = packed = 0
        for _ in range(frames):
            if pos % (1 << a.align):
                pad = (1 << a.align) - pos % (1 << a.align)
                o.write(b"\0" * pad); pos += pad
            block = f.read(a.frame)
            block += b"\0" * (a.frame - len(block))
            c = zlib.compressobj(9, zlib.DEFLATED, -15)
            z = c.compress(block) + c.flush()
            if len(z) < len(block):
                index.append(pos >> a.align); o.write(z); pos += len(z); packed += 1
            else:
                index.append((pos >> a.align) | 0x80000000); o.write(block); pos += len(block); plain += 1
        if pos % (1 << a.align):
            pad = (1 << a.align) - pos % (1 << a.align)
            o.write(b"\0" * pad); pos += pad
        index.append(pos >> a.align)
        o.seek(len(header)); o.write(struct.pack("<%dI" % len(index), *index))
print(f"{a.dst}: {frames} frames of {a.frame}, {packed} deflated, {plain} plain, align {a.align}")
