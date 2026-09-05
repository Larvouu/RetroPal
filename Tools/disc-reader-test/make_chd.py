#!/usr/bin/env python3
"""A minimal UNCOMPRESSED CHD v5 holding one CD data track.

Written from libchdr's own header parser and map reader, not from a spec
summary: v5 header at offset 0 (124 bytes), a raw map of big-endian uint32
hunk indices when compression[0] is CHD_CODEC_NONE, and a metadata chain whose
16-byte record is tag / (flags<<24 | length) / next.

The disc it builds is deliberately dull: 40 frames, each 2352 bytes of sector
plus 96 of subcode, with a recognisable pattern at sector 16 -- the sector
rcheevos sniffs for the sync pattern and "CD001".
"""
import struct, sys

SECTOR, SUB = 2352, 96
FRAME = SECTOR + SUB
FRAMES_PER_HUNK = 8
HUNKBYTES = FRAME * FRAMES_PER_HUNK
PREGAP = int(sys.argv[2]) if len(sys.argv) > 2 else 0
PLAYABLE = 40

SYNC = bytes([0x00] + [0xFF]*10 + [0x00])

def sector_bytes(lba):
    """MODE1/2352: 12 sync, 3 address, 1 mode, then 2048 of user data."""
    s = bytearray(SECTOR)
    s[0:12] = SYNC
    s[12], s[13], s[14], s[15] = 0, 0, lba & 0xFF, 1
    # User data: sector 16 carries a volume descriptor's CD001; every sector
    # also carries its own LBA so a misread lands on an obvious wrong number.
    body = bytearray(2048)
    body[0] = 1
    body[1:6] = b"CD001"
    body[6] = 1
    struct.pack_into(">i", body, 16, lba)
    label = b"LBA%+06d" % lba
    body[100:100+len(label)] = label
    assert len(body) == 2048, "a slice assignment of a different length RESIZES a bytearray"
    s[16:16+2048] = body
    assert len(s) == SECTOR, len(s)
    return bytes(s)

frames = []
for i in range(PREGAP + PLAYABLE):
    # The track's own sector 0 sits at CHD frame PREGAP, so the LBA a reader
    # should see is the frame index minus the pregap.
    lba = i - PREGAP
    frames.append(sector_bytes(lba) + bytes(SUB))

raw = b"".join(frames)
hunkcount = (len(raw) + HUNKBYTES - 1) // HUNKBYTES
raw += bytes(hunkcount * HUNKBYTES - len(raw))

HEADER = 124
mapoffset = HEADER
mapsize = hunkcount * 4
dataoffset = mapoffset + mapsize
# Hunk n lives at dataoffset + n*HUNKBYTES, and the map stores that position
# divided by hunkbytes, which is what libchdr multiplies back out.
assert dataoffset % HUNKBYTES != 0 or True
# libchdr computes blockoffs = mapentry * hunkbytes, so the data must start on a
# hunkbytes boundary. Pad the gap between the map and the data until it does.
pad = (-dataoffset) % HUNKBYTES
dataoffset += pad
first_index = dataoffset // HUNKBYTES
rawmap = b"".join(struct.pack(">I", first_index + n) for n in range(hunkcount))
metaoffset = dataoffset + hunkcount * HUNKBYTES

meta = ("TRACK:1 TYPE:MODE1_RAW SUBTYPE:NONE FRAMES:%d PREGAP:%d PGTYPE:MODE1_RAW "
        "PGSUB:NONE POSTGAP:0" % (PREGAP + PLAYABLE, PREGAP)).encode() + b"\x00"
meta_rec = struct.pack(">I", 0x43485432) + struct.pack(">I", len(meta)) + struct.pack(">Q", 0) + meta

header = bytearray(HEADER)
header[0:8] = b"MComprHD"
struct.pack_into(">I", header, 8, HEADER)
struct.pack_into(">I", header, 12, 5)
for i in range(4):
    struct.pack_into(">I", header, 16 + i*4, 0)      # CHD_CODEC_NONE
struct.pack_into(">Q", header, 32, hunkcount * HUNKBYTES)
struct.pack_into(">Q", header, 40, mapoffset)
struct.pack_into(">Q", header, 48, metaoffset)
struct.pack_into(">I", header, 56, HUNKBYTES)
struct.pack_into(">I", header, 60, FRAME)

out = bytearray()
out += header
out += rawmap
out += bytes(pad)
out += raw
out += meta_rec
open(sys.argv[1], "wb").write(bytes(out))
print("wrote %s: %d hunks, hunkbytes %d, pregap %d, %d bytes"
      % (sys.argv[1], hunkcount, HUNKBYTES, PREGAP, len(out)))
