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

// RetroAchievements (rc_client) ObjC++ wrapper, exposed to Swift.
#import "../../Data/RetroAchievements/RAClient.h"

#endif /* EmulateurGBA_Bridging_Header_h */
