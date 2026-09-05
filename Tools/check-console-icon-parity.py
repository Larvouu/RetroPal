#!/usr/bin/env python3
"""Hold each console drawing's SVG and its in-app Canvas copy to the same shape.

WHY THIS EXISTS. These drawings exist FOUR times: the SVG source, the exported
PNGs, the `PixelConsole` Canvas in ConsoleIconRow.swift, and the website. The
PNGs are generated, so they cannot drift. The website is a separate repository
and moves at release. The two that can silently disagree are the SVG and the
Canvas, both edited by hand, and on 2026-08-17 they did: a fix went into one of
them and shipped looking like a fix to the bug.

WHAT IT CHECKS. Geometry, not colour. The Canvas measures from the drawing's own
bounding box while the SVG measures from its viewBox, so the two differ by a
constant translation; the check solves for that translation from one shape and
then requires EVERY other shape to agree under it. A single shape moved in one
copy and not the other cannot survive that, which is the failure worth catching.

WHAT IT DOES NOT CHECK. Colours (the SVG names hex, the Canvas names constants),
stroke widths (both are 2 by construction), and the four handhelds. Those four
are not drawn from these SVGs at all: their Canvas coordinates were ported from
the website's own icon component, so there is no second copy here to compare
against.

Usage:  python3 Tools/check-console-icon-parity.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWIFT = os.path.join(ROOT, "EmulateurGBA", "Features", "Library", "ConsoleIconRow.swift")
CONSOLES = {"snes": "console-snes.svg", "nes": "console-nes.svg", "ps1": "console-ps1.svg"}

NUM = r"-?[\d.]+"


def svg_shapes(path):
    """Every rect, circle and path vertex in the drawing, label group excluded."""
    text = open(path, encoding="utf-8").read()
    text = re.sub(r'<g id="label">.*?</g>', "", text, flags=re.S)
    rects = {(float(a), float(b), float(c), float(d))
             for a, b, c, d in re.findall(
                 r'<rect\s+x="({0})"\s+y="({0})"\s+width="({0})"\s+height="({0})"'.format(NUM), text)}
    circles = {(float(a), float(b), float(c))
               for a, b, c in re.findall(
                   r'<circle\s+cx="({0})"\s*\n?\s*cy="({0})"\s*r="({0})"'.format(NUM),
                   re.sub(r'\s+', ' ', text))}
    verts = []
    for d in re.findall(r'<path\s+d="([^"]+)"', text):
        x = y = 0.0
        for token in re.findall(r"[MHVLZ][^MHVLZ]*", d):
            head, rest = token[0], token[1:].strip()
            n = [float(v) for v in rest.replace(",", " ").split()] if rest else []
            if head == "M":
                x, y = n
            elif head == "H":
                x = n[0]
            elif head == "V":
                y = n[0]
            elif head == "L":
                x, y = n
            else:
                continue
            verts.append((x, y))
    return rects, circles, verts


def swift_shapes(console):
    """The same, read out of the `case .<console>:` block of the Canvas switch."""
    text = open(SWIFT, encoding="utf-8").read()
    start = text.index("            case .%s:" % console)
    rest = text[start + 1:]
    stop = re.search(r"\n            (case \.|\}\n)", rest)
    block = rest[: stop.start()] if stop else rest
    block = re.sub(r"//.*", "", block)
    rects = {tuple(float(v) for v in m)
             for m in re.findall(
                 r"(?:rect|frame)\(\s*({0}),\s*({0}),\s*({0}),\s*({0})".format(NUM), block)}
    circles = {tuple(float(v) for v in m)
               for m in re.findall(r"dot\(\s*({0}),\s*({0}),\s*({0})".format(NUM), block)}
    verts = []
    poly = re.search(r"poly\(\[(.*?)\]", block, re.S)
    if poly:
        verts = [(float(a), float(b))
                 for a, b in re.findall(r"\(\s*({0}),\s*({0})\s*\)".format(NUM), poly.group(1))]
    return rects, circles, verts


def check(console, filename):
    sr, sc, sv = svg_shapes(os.path.join(ROOT, "Store", "components", filename))
    wr, wc, wv = swift_shapes(console)

    if len(sr) != len(wr) or len(sc) != len(wc) or len(sv) != len(wv):
        print("  %-5s COUNTS DIFFER: svg %d rects %d circles %d vertices, "
              "swift %d / %d / %d" % (console, len(sr), len(sc), len(sv),
                                      len(wr), len(wc), len(wv)))
        return False

    # The offset, solved from the widest rect: it is the same shape in both and
    # picking it by size rather than by document order means neither file's
    # ordering can choose it.
    widest_svg = max(sr, key=lambda r: (r[2], r[3]))
    widest_swift = max(wr, key=lambda r: (r[2], r[3]))
    dx = widest_swift[0] - widest_svg[0]
    dy = widest_swift[1] - widest_svg[1]

    moved_r = {(x + dx, y + dy, w, h) for x, y, w, h in sr}
    moved_c = {(x + dx, y + dy, r) for x, y, r in sc}
    moved_v = [(x + dx, y + dy) for x, y in sv]
    ok = moved_r == wr and moved_c == wc and moved_v == wv
    print("  %-5s offset (%+g, %+g)  %d rects, %d circles, %d vertices  %s"
          % (console, dx, dy, len(sr), len(sc), len(sv), "match" if ok else "MISMATCH"))
    if not ok:
        for label, a, b in (("rect", moved_r, wr), ("circle", moved_c, wc)):
            for shape in sorted(a - b):
                print("      only in the SVG:   %s %s" % (label, shape))
            for shape in sorted(b - a):
                print("      only in the Swift: %s %s" % (label, shape))
        for i, (a, b) in enumerate(zip(moved_v, wv)):
            if a != b:
                print("      vertex %d: svg %s, swift %s" % (i, a, b))
    return ok


if __name__ == "__main__":
    print("Console icon parity (SVG source vs the app's Canvas copy):")
    if all(check(c, f) for c, f in sorted(CONSOLES.items())):
        print("\nThe drawings agree.")
    else:
        sys.exit("\nA drawing was changed in one copy and not the other.")
