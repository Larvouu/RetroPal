# Save-state compatibility fixtures: wiring + capture

`SaveStateCompatibilityTests` guards Risk 2: a future core upgrade silently
breaking save states written by the previously shipped core. The test only does
its job once these fixtures are captured. Until then both cases no-op (green).

This is a one-time setup on the Mac (I cannot do it from the Linux dev box: no
Xcode, and the fixtures are binaries that must be captured by running the cores).

---

## Part 1. One-time test-target wiring (Xcode)

1. **Add the two source files to the test target** (they are in the repo but may
   not be in the `EmulateurGBATests` target yet): select
   `SaveStateCompatibilityTests.swift` and `EmulateurGBATests-Bridging-Header.h`
   in the Project navigator and tick `EmulateurGBATests` under Target Membership.

2. **Set the test target's bridging header:**
   `EmulateurGBATests` target > Build Settings > "Objective-C Bridging Header"
   (`SWIFT_OBJC_BRIDGING_HEADER`) =
   `EmulateurGBATests/EmulateurGBATests-Bridging-Header.h`

3. **If the `#import`s are not found,** add to the same target's "Header Search
   Paths" (`HEADER_SEARCH_PATHS`):
   `$(SRCROOT)/EmulateurGBA/EmulatorCore/Bridge`

   The concrete `MGBABridge` / `MelonDSBridge` classes resolve against the host
   app at link time (the test target already has `TEST_HOST` / `BUNDLE_LOADER`
   set), so no extra linking is needed.

4. **Run on the iOS Simulator (or any Mac-hosted run), not a physical device.**
   The test locates fixtures from the source tree via `#filePath`, which a device
   cannot read. (If you ever need device runs, add the fixtures to the test
   target's Copy Bundle Resources and switch the locator to `Bundle(for:)`.)

---

## Part 2. Capture a fixture (per core, per shipped version)

Do this on the build whose save-state format you want to protect, normally the
version that is currently in users' hands (or the build about to ship).

Homebrew ROMs to use (already in `Store/TestRom/`, all redistributable):
- mGBA family: `anguna.gba` (or `ucity.gbc`, `libbet.gb`).
- melonDS: `traffic-escape-ds.nds`.

Steps:
1. Run the shipped app on the Simulator. Import the homebrew ROM.
2. Play to a recognizable point. **If the game supports in-game saving, save in
   the game** so a battery `.sav` exists (that becomes the optional golden).
3. Make a **manual save state in slot 1**.
4. Pull the files out of the app container
   (Xcode > Window > Devices & Simulators, or the Simulator container on disk,
   or the Files app under "On My iPhone > Retro Pal"):
   - save state: `Documents/SaveStates/<romBasename>/slot1.state`
   - battery save (optional golden): `Documents/BatterySaves/<romBasename>.sav`
   `<romBasename>` is the ROM filename without its extension.
5. Drop them into the matching folder here, keeping the extensions:
   ```
   Fixtures/SaveStateCompat/mgba/
       anguna.gba            (the ROM, copied from Store/TestRom)
       anguna-readme.txt     (its license/readme, so the public repo stays clean)
       anguna.state          (slot1.state, renamed; the .state extension matters)
       anguna.sav            (optional golden, only if you saved in-game)
   Fixtures/SaveStateCompat/melonds/
       traffic-escape-ds.nds
       traffic-escape-ds-LICENSE.txt
       traffic-escape-ds.state
       traffic-escape-ds.sav (optional)
   ```
   The test finds files by extension, so exact names do not matter as long as
   there is one ROM, one `.state`, and at most one `.sav` per folder.

---

## Part 3. The discipline that makes this work

- The `.state` fixture represents the format of the version users are ON.
  **Recapture it ONLY when you deliberately accept a format break** (and then
  message users). **Never** recapture just to turn a red test green: that erases
  the warning.
- Optionally keep one fixture set per shipped version
  (`mgba-1.0/`, `mgba-1.1/`, ...) to test the real N -> N+1 hop. Minimally, keep
  the most recently shipped version's set.
- Use only redistributable homebrew and include each ROM's license file beside
  it. These fixtures ship to the public GPL repo with the tests.

---

## Part 4. When to run it

Before every release, and especially **any release that bumps the `Vendor/mgba`
or `Vendor/melonds` submodule**, make sure both cases are GREEN. A red case means
the core changed the save-state format: read the header of
`SaveStateCompatibilityTests.swift` before shipping. Battery (`.sav`) saves are
unaffected by any of this and remain the safety net. See the standing item in
`TODOS.md`.
