//
//  EmulateurGBA-Bridging-Header.h
//  EmulateurGBA
//
//  Bridging header: every core bridge, and the RetroAchievements wrapper.
//  A bridge that is not listed here compiles perfectly and is then invisible
//  to Swift, which reads as "cannot find X in scope" at the call site rather
//  than as anything to do with this file.
//

#ifndef EmulateurGBA_Bridging_Header_h
#define EmulateurGBA_Bridging_Header_h

#import "EmulatorBridge.h"
#import "MGBABridge.h"
#import "MelonDSBridge.h"
#import "MesenBridge.h"
#import "PCSXBridge.h"
#import "N64Bridge.h"
#import "BlastEmBridge.h"
#import "PSPBridge.h"
#import "CTRBridge.h"

// Whether a file is a PSP game, read from its bytes (`.iso` and `.pbp` are the
// PlayStation's too). C, so the RetroAchievements client can ask it as well.
#import "../../Data/ROMParsing/PSPDiscProbe.h"

// Whether a 3DS game is encrypted, read from its bytes (Retro Pal ships no keys
// and the core reads decrypted games only). C, so CTRBridge reads it as well.
#import "../../Data/ROMParsing/CTRGameProbe.h"

// The archives other than .zip (.7z, .rar, .tar, .gz, .xz), read through
// libarchive (Vendor/archive-ios). C, with plain C types (`GameArchive`).
#import "../../Data/FileStorage/GameArchiveReader.h"

// RetroAchievements (rc_client) ObjC++ wrapper, exposed to Swift.
#import "../../Data/RetroAchievements/RAClient.h"

#endif /* EmulateurGBA_Bridging_Header_h */
