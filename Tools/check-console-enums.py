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
    "ROMSystemType":   (["gba", "gb", "gbc", "nds", "snes", "nes", "ps1"], ["n64"]),
    # The N64 has its own preset system and controls since 1.3.3's controls
    # phase, its dress (DressKind) and its custom-skin palette (SkinPalette)
    # since 2026-09-27.
    "PresetSystem":    (["gba", "gbc", "nds", "snes", "nes", "ps1"], ["n64"]),
    "DressKind":       (["gbc", "gba", "nds", "snes", "nes", "ps1"], ["n64"]),
    "SkinPalette":     (["gbc", "gba", "nds", "snes", "nes", "ps1"], ["n64"]),
    "PreviewSystem":   (["gba", "gbc", "nds", "snes", "nes", "ps1"], ["n64"]),
    "ControlElement":  (["dpad", "btnA", "btnB", "btnL", "btnR", "btnStart",
                         "btnSelect", "btnMenu", "btnClip", "btnX", "btnY",
                         "btnMic", "btnL2", "btnR2", "btnMode",
                         "stickLeft", "stickRight", "btnL3", "btnR3"],
                        ["btnCUp", "btnCDown", "btnCLeft", "btnCRight"]),
    "RemappableInput": (["a", "b", "x", "y", "l", "r", "select", "start",
                         "l2", "r2", "l3", "r3"], ["cUp", "cDown", "cLeft", "cRight"]),
    "GBAInput":        (["a", "b", "select", "start", "right", "left", "up",
                         "down", "r", "l", "x", "y", "l2", "r2", "l3", "r3"],
                        ["cUp", "cDown", "cLeft", "cRight"]),
}

# The console enums share most of their member names, so a switch cannot be
# told apart by those alone. Where an enum has a member no other has, it is
# named here and a switch must mention it to count as a switch over that enum:
# `.gb` exists only in ROMSystemType (the preset systems fold GB into GBC).
SIGNATURE = {
    "ROMSystemType": "gb",
}

# Enums whose members READ like console names but which are not console enums,
# or which are deliberately not extended. `PixelConsole` draws the onboarding
# grid and is art rather than behaviour: it gains its case with the drawing.
SKIP_FILES = {
    "ConsoleIconRow.swift": "PixelConsole, the onboarding drawing (art, not behaviour)",
}


# Enums that share member names with the console enums above and are NOT being
# extended, so a switch over one of them must not be reported under another.
# `DressVariant` wraps the palettes; a switch over it names `.nostalgia`,
# `.retroPal` and `.custom(.gbc(...))`, and reads like a console switch.
OTHER_ENUMS = {"DressVariant",
               # The N64 C button's triangle direction: up/down/left/right, the
               # same names as GBAInput's four directions.
               "N64Arrow"}


def switched_type(lines, i):
    """The type a switch is over, when the source says so plainly: the
    enclosing type for `switch self`, the declared type of a parameter or
    property for `switch name`. None when it cannot tell, which keeps the
    switch in the check: an unresolved switch is reported, never skipped.

    This is what tells `switch self` inside `extension DressKind` apart from a
    switch over `PresetSystem`. The two enums share every member name, so the
    case labels alone cannot, and before this the checker reported every
    DressKind, DressVariant and SkinPalette switch as a missing console case
    (13 false alarms when the Nintendo 64 got its preset system)."""
    m = re.search(r'switch\s+(\w+)\s*\{', lines[i])
    if not m:
        return None
    subject = m.group(1)
    if subject == "self":
        indent = len(lines[i]) - len(lines[i].lstrip())
        for j in range(i - 1, -1, -1):
            d = re.match(r'^(\s*)(?:[\w@]+\s+)*(?:enum|extension|struct|class)\s+(\w+)', lines[j])
            if d and len(d.group(1)) < indent:
                return d.group(2)
        return None
    for j in range(i - 1, max(-1, i - 60), -1):
        d = re.search(r'\b' + re.escape(subject) + r'\s*:\s*(\w+)', lines[j])
        if d:
            return d.group(1)
        # `guard let arrow = n64Arrow`: follow the binding to the property's
        # declared type, once. Enough for the unwrap-then-switch idiom.
        b = re.search(r'\blet\s+' + re.escape(subject) + r'\s*=\s*(\w+)\b', lines[j])
        if b:
            source = b.group(1)
            for k in range(len(lines)):
                t = re.search(r'\bvar\s+' + re.escape(source) + r'\s*:\s*(\w+)', lines[k])
                if t:
                    return t.group(1)
            return None
    return None


def switch_bodies(src):
    """(line number, header, body, type) for every switch, by brace depth."""
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
        yield i + 1, line.strip(), "\n".join(body), switched_type(lines, i)


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
        for line_no, header, body, over in switch_bodies(src):
            # Either kind of catch-all makes a switch exhaustive already. The
            # `case .custom:` form is the one that produced five false alarms
            # the first time this was attempted by hand.
            if re.search(r'^\s*default\s*:', body, re.M):
                continue
            if re.search(r'^\s*case\s+\.custom\s*:', body, re.M):
                continue
            for enum, (existing, added) in ENUMS.items():
                if enum in SIGNATURE and not mentions(body, SIGNATURE[enum]):
                    continue
                # Over a DIFFERENT known enum: its own row (or OTHER_ENUMS)
                # answers for it, not this one.
                if over and over != enum and (over in ENUMS or over in OTHER_ENUMS):
                    continue
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
