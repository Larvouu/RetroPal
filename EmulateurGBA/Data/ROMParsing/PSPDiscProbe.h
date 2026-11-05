//
//  PSPDiscProbe.h
//  EmulateurGBA
//
//  Whether a file is a PSP game, read from its bytes.
//
//  WHY THE BYTES AND NOT THE NAME. `.iso` and `.pbp` are the PlayStation's
//  extensions AND the PSP's: a PlayStation disc dumped as an `.iso`, a PSP
//  UMD dumped as an `.iso`; a PlayStation game repacked for the PSP's store
//  (an EBOOT.PBP holding a disc image) and a PSP game itself, in the same
//  container. The name cannot say which console a file belongs to; the
//  contents always can, and the PSP's own emulator decides by them
//  (`Identify_File`, PPSSPP Core/Loaders.cpp, v1.20.4). This answers with the
//  same tests, so the console the app files a game under is the one the core
//  that runs it would recognise.
//
//  ONE implementation, in C, read by both sides of the app: the Swift parser
//  (through the bridging header) and the RetroAchievements client (RAClient.mm),
//  which must not identify a PSP `.iso` as a PlayStation disc either.
//
//  Reads at most a few kilobytes, at fixed offsets: safe on a 1.8 GB image
//  (a `.chd` decompresses the one or two hunks those offsets fall in).
//

#ifndef PSPDiscProbe_h
#define PSPDiscProbe_h

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// What a file's bytes say about the PSP.
typedef enum {
    /// Not a PSP game: a PlayStation disc (its volume says "PLAYSTATION", or
    /// it is a CD image), a PlayStation game repacked as a `.pbp`, a file of
    /// another extension.
    PSPDiscProbeNotPSP = 0,
    /// A PSP game.
    PSPDiscProbePSP = 1,
    /// The bytes do not say: an `.iso` or a DVD `.chd` whose volume names some
    /// other system and carries no PSP_GAME folder, or a `.chd` / `.iso` that
    /// cannot be read. The importer asks the player (2026-10-12).
    PSPDiscProbeUndecided = 2,
} PSPDiscProbeAnswer;

/// The file's bytes alone, read with PPSSPP's own tests: `.iso`, `.cso`,
/// `.pbp`, and since 2026-10-12 `.chd` (a UMD made into a DVD `.chd`, which
/// was filed under the PlayStation unread). Never reads the player's answer.
PSPDiscProbeAnswer PSPDiscProbeRead(const char *path);

/// The name of the file, in a disc game's own folder, that records the
/// console the player chose when the bytes could not say: "psp" or "ps1".
/// Written by the importer, read by `PSPDiscProbeIsPSPGame`, so the core, the
/// pad and the achievements all follow the choice. Starts with a dot, so the
/// Files app does not show it.
#define PSP_DISC_PROBE_CHOICE_FILE ".retropal-console"

/// True when the file at `path` is a PSP game: what its bytes say, and when
/// they do not say, what the player chose at import (the choice file beside
/// it). False for every other file, including any file that cannot be read
/// and has no recorded choice.
///
/// THIS is what every part of the app asks (the importer, the session, the
/// pad, the achievements), so all of them agree on the console.
bool PSPDiscProbeIsPSPGame(const char *path);

/// What an `.iso` or flat `.chd` volume is, for telling apart the discs the
/// importer refuses (`RAClient.isOtherConsolesDisc`): a PlayStation 3 disc, a
/// UMD film or album with no game on it, or anything else. Telemetry only.
typedef enum {
    PSPDiscProbeVolumeOther = 0,
    PSPDiscProbeVolumePS3 = 1,
    PSPDiscProbeVolumeUMDMedia = 2,
} PSPDiscProbeVolume;
PSPDiscProbeVolume PSPDiscProbeReadVolume(const char *path);

/// The TITLE of a PBP's PARAM.SFO (an EBOOT: a PSP game sold on the store, or
/// a PSP program), UTF-8, into `out` (NUL-terminated, at most `outSize - 1`
/// bytes). False when the file is not a PBP or carries no title. Every EBOOT
/// is named `EBOOT.PBP`, so this is the only place its real name is written.
bool PSPDiscProbeReadPBPTitle(const char *path, char *out, size_t outSize);

#ifdef __cplusplus
}
#endif

#endif /* PSPDiscProbe_h */
