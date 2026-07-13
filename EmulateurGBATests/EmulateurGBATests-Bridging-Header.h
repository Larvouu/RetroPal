//
//  EmulateurGBATests-Bridging-Header.h
//  EmulateurGBATests
//
//  Exposes the Objective-C emulator cores to the TEST target's Swift so
//  SaveStateCompatibilityTests can drive MGBABridge / MelonDSBridge directly.
//
//  WIRING (one-time, in Xcode, on the Mac):
//   1. Set this file as the test target's "Objective-C Bridging Header":
//      EmulateurGBATests target > Build Settings >
//      "Objective-C Bridging Header" (SWIFT_OBJC_BRIDGING_HEADER) =
//        EmulateurGBATests/EmulateurGBATests-Bridging-Header.h
//   2. Add the Bridge headers' folder to the test target's Header Search Paths
//      if the imports below are not found:
//      EmulateurGBATests target > Build Settings > "Header Search Paths" +=
//        $(SRCROOT)/EmulateurGBA/EmulatorCore/Bridge
//   The concrete classes link against the host app (the test target already has
//   TEST_HOST / BUNDLE_LOADER set), so no extra linking is required.
//

#import "EmulatorBridge.h"
#import "MGBABridge.h"
#import "MelonDSBridge.h"
