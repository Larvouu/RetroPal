#!/usr/bin/env python3
"""Find switches that a newly added console will break, before the compiler does.

WHY THIS EXISTS. Adding a console means adding a case to several enums that do
not know about each other, and every exhaustive switch over one of them stops
compiling. That is the design working: the compiler names the sites instead of
letting the console half-work. The problem is the ROUND TRIP. Each missed site
costs a full Mac build, and during the PlayStation work four separate rounds
were spent on switches a grep had not thought to look for:

  * `case .custom(.nes(let p))` -- the palette nested inside a DressVariant,
    which a search for `case .nes` does not match.
  * `PreviewSystem` -- the debug gallery's OWN console enum, not PresetSystem.
  * `ControlElement` -- extended with L2/R2, an enum nobody was scanning at all
    because the attention was on the console enums.

So this does not try to be clever about types. It reads every switch, and for
each enum listed below asks: does this switch mention at least two members that
existed BEFORE, carry no `default:`, and mention none of the members added? If
so it is a switch the compiler is about to reject.

USAGE
    python3 Tools/check-console-enums.py           # from the repo root
Exit status is 1 when something is missing, so it can gate a commit.

WHEN ADDING THE NEXT CONSOLE: put its new members in the `added` column below
and run this before the first Mac build. When that console ships, move them
into `existing` so the table describes the enum as it now stands.
"""

import re
import sys
import glob

# enum -> (members that existed before the console being added, members added)
ENUMS = {
    "ROMSystemType":   (["gba", "gb", "gbc", "nds", "snes", "nes"], ["ps1"]),
    "PresetSystem":    (["gba", "gbc", "nds", "snes", "nes"], ["ps1"]),
    "DressKind":       (["gbc", "gba", "nds", "snes", "nes"], ["ps1"]),
    "SkinPalette":     (["gbc", "gba", "nds", "snes", "nes"], ["ps1"]),
    "PreviewSystem":   (["gba", "gbc", "nds", "snes", "nes"], ["ps1"]),
    "ControlElement":  (["dpad", "btnA", "btnB", "btnL", "btnR", "btnStart",
                         "btnSelect", "btnMenu", "btnClip", "btnX", "btnY",
                         "btnMic"], ["btnL2", "btnR2", "btnMode",
                                     "stickLeft", "stickRight",
                                     "btnL3", "btnR3"]),
    "RemappableInput": (["a", "b", "x", "y", "l", "r", "select", "start"],
                        ["l2", "r2", "l3", "r3"]),
    "GBAInput":        (["a", "b", "select", "start", "right", "left", "up",
                         "down", "r", "l", "x", "y"], ["l2", "r2", "l3", "r3"]),
}

# Enums whose members READ like console names but which are not console enums,
# or which are deliberately not extended. `PixelConsole` draws the onboarding
# grid and is art rather than behaviour: it gains its case with the drawing.
SKIP_FILES = {
    "ConsoleIconRow.swift": "PixelConsole, the onboarding drawing (art, not behaviour)",
}


def switch_bodies(src):
    """(line number, header, body) for every switch, by brace depth."""
    lines = src.split("\n")
    for i, line in enumerate(lines):
        if not re.search(r'(^|\s)switch\s', line):
            continue
        depth = line.count("{") - line.count("}")
        body, j = [], i
        while j + 1 < len(lines) and depth > 0:
            j += 1
            body.append(lines[j])
            depth += lines[j].count("{") - lines[j].count("}")
        yield i + 1, line.strip(), "\n".join(body)


def mentions(body, member):
    """`.member` used as a case label, bare or with a payload or nested."""
    return re.search(r'case[^\n:]*\.' + re.escape(member) + r'\b', body) is not None


def main():
    flagged = []
    for path in sorted(glob.glob("EmulateurGBA/**/*.swift", recursive=True)
                       + glob.glob("EmulateurGBATests/*.swift")):
        name = path.split("/")[-1]
        if name in SKIP_FILES:
            continue
        src = open(path, encoding="utf-8").read()
        for line_no, header, body in switch_bodies(src):
            # Either kind of catch-all makes a switch exhaustive already. The
            # `case .custom:` form is the one that produced five false alarms
            # the first time this was attempted by hand.
            if re.search(r'^\s*default\s*:', body, re.M):
                continue
            if re.search(r'^\s*case\s+\.custom\s*:', body, re.M):
                continue
            for enum, (existing, added) in ENUMS.items():
                # Two members, not one: a lone `.a` or `.l` is noise.
                if sum(mentions(body, m) for m in existing) < 2:
                    continue
                # EVERY added member, not any of them. "Any" was wrong the
                # moment a second wave of additions arrived: a switch already
                # carrying btnL2 from the first wave would be waved through
                # while still missing btnMode from the second, which is exactly
                # the site this tool exists to find.
                if all(mentions(body, m) for m in added):
                    continue
                flagged.append((enum, path, line_no, header))
                break

    for enum, path, line_no, header in flagged:
        print(f"MISSING  {enum:16} {path}:{line_no}  {header[:60]}")
    if flagged:
        print(f"\n{len(flagged)} switch(es) will not compile. Add the case, "
              f"with a real answer rather than a default.")
        return 1
    print(f"All switches over the {len(ENUMS)} extended enums carry their new cases.")
    for name, why in SKIP_FILES.items():
        print(f"  (skipped {name}: {why})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
