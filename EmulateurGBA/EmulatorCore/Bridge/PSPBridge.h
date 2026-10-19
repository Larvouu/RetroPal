//
//  PSPBridge.h
//  EmulateurGBA
//
//  ObjC bridge to PPSSPP's own libretro port, serving the PSP.
//
//  The fourth bridge driven through libretro, and the second that draws on the
//  GPU: PPSSPP renders with Vulkan through the same frontend as the Nintendo 64
//  (N64VulkanFrontend, on MoltenVK), and the finished frame is copied back into
//  an ordinary framebuffer, so the Metal view, the share cards, the clips and
//  the save previews read it as they read every other console's. One instance
//  at a time, as every libretro bridge; the entry points are renamed
//  psp_retro_* at build time (Vendor/ppsspp-ios/psp_symbols.h). See PSPBridge.mm.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "EmulatorBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// The picture's allocation: the PSP's own 480x272 at the core's 1x
/// resolution, which is the only resolution this bridge asks for.
extern const NSInteger PSPMaxBufferWidth;    // 480
extern const NSInteger PSPMaxBufferHeight;   // 272

/// Posted on the main thread, once per game, when the picture can no longer be
/// updated (the GPU did not deliver a frame within a second). Same contract as
/// N64BridgeDisplayLostNotification.
FOUNDATION_EXPORT NSNotificationName const PSPBridgeDisplayLostNotification;

/// Posted on the main thread, once, when the game could not be started.
///
/// PPSSPP boots ASYNCHRONOUSLY: `loadROMAtPath:` only checks the file and
/// starts the boot, which finishes inside the first frames; a game the core
/// cannot run (a damaged image, an encrypted one, a file that is not a PSP
/// game) fails THERE, after the load has answered YES. The bridge then stops
/// running the core (calling it again crashes it) and posts this, so the game
/// screen can say so instead of showing a black picture.
FOUNDATION_EXPORT NSNotificationName const PSPBridgeBootFailedNotification;

@interface PSPBridge : NSObject <EmulatorBridge>

// MARK: - PSP-specific surface
//
// Declared here rather than in `EmulatorBridge`, like the PlayStation's and the
// N64's: the session reaches it through a cast.

/// The analog nub, each axis -1.0...1.0, y positive DOWN (libretro's and
/// UIKit's direction). The core applies its own dead zone and sensitivity.
- (void)setStickX:(float)x y:(float)y;

/// Where the game's own saves live: the PSP memory stick, a FOLDER
/// (`PSP/SAVEDATA/<game id>/...`), not one battery file. Set BEFORE
/// `loadROMAtPath:`; the core reads it while it initialises.
- (void)setMemoryStickDirectory:(NSString *)path;

// MARK: - Save-state files
//
// Class methods so the format can be tested without a running core.

/// The bytes to write for `state` as the core produced it: packed with LZFSE
/// behind a header of ours, or `state` itself when packing does not pay.
+ (NSData *)stateFileDataFromState:(NSData *)state NS_SWIFT_NAME(stateFileData(fromState:));

/// The state a slot file holds, or nil when it holds none. Unlike the N64's, a
/// PSP state has no fixed size; what is checked is the core's own header
/// ("SaveStart") and, for a packed file, its length and digest.
+ (nullable NSData *)stateFromStateFileData:(NSData *)file NS_SWIFT_NAME(state(fromStateFile:));

@end

NS_ASSUME_NONNULL_END
