//
//  N64Bridge.h
//  EmulateurGBA
//
//  ObjC bridge to Mupen64Plus-Next, serving the Nintendo 64.
//
//  The second bridge driven through libretro, after PCSXBridge, and it shares
//  that API's one constraint: libretro is a global C interface with a single
//  implicit instance, so exactly one N64Bridge may exist at a time. The two
//  libretro cores do not see each other: this one's entry points are renamed
//  n64_retro_* at build time (Vendor/n64-ios/n64_symbols.h).
//
//  What is new here is the picture. The N64 core draws on the GPU through
//  parallel-RDP, which speaks Vulkan; the bridge runs Vulkan on MoltenVK and
//  copies each finished frame back into an ordinary framebuffer, so the Metal
//  view, the share cards, the clips and the save previews read it exactly as
//  they read every other console's. See N64Bridge.mm.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "EmulatorBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// The picture's allocation. The N64's video interface scans out 640 pixels
/// wide and 240, 288, 480 or 576 lines tall (NTSC or PAL, progressive or
/// interlaced), chosen by the game and changed mid-game, so the buffer is
/// allocated at the largest of them and the live picture occupies its top-left
/// corner, as on the PlayStation. The core's own upscaling is off; these are
/// its 1x maximums.
extern const NSInteger N64MaxBufferWidth;    // 640
extern const NSInteger N64MaxBufferHeight;   // 576

/// The bits the N64 adds to the app's button mask, beside the ones every
/// console shares. `GBAInput` in TouchControlsView.swift carries the same
/// values (`cUp` and so on); if one moves, both move.
///
/// The shared bits name the N64's own buttons: 0x001 is A, 0x002 is B,
/// 0x200/0x100 are L and R, 0x1000 (the bit the PlayStation calls L2) is Z,
/// 0x008 START and the four direction bits the D-pad. The C buttons have no
/// counterpart on any other console, so they get bits of their own.
typedef NS_OPTIONS(uint32_t, N64InputBits) {
    N64InputCUp    = 0x10000,
    N64InputCDown  = 0x20000,
    N64InputCLeft  = 0x40000,
    N64InputCRight = 0x80000,
};

/// Posted on the main thread, once per game, when the picture can no longer be
/// updated: the GPU did not deliver a frame within a second, and the readback
/// is abandoned for the session rather than reused while the GPU may still
/// hold it. The game screen pauses and tells the player (2026-09-27): before,
/// this was only in the log, and the player saw a frozen picture with the game
/// still running under it.
FOUNDATION_EXPORT NSNotificationName const N64BridgeDisplayLostNotification;

@interface N64Bridge : NSObject <EmulatorBridge>

// MARK: - Nintendo 64-specific surface
//
// Declared here rather than in `EmulatorBridge`, like the PlayStation's: the
// session reaches it through a cast.

/// The control stick, each axis -1.0...1.0, y positive DOWN (the direction
/// libretro and UIKit use, so nothing is flipped on the way through). The core
/// applies its own dead zone and scales the rest to the N64 stick's range.
/// Per player, 0-based, like `setKeys:player:`.
- (void)setStickX:(float)x y:(float)y player:(NSInteger)player;

/// The C buttons as a stick, each axis -1.0...1.0, y positive DOWN. This is how
/// a modern controller's right stick reaches them: the core turns a push past
/// half-way into the C button in that direction. The C buttons are ALSO
/// ordinary buttons in the mask (`N64InputBits`); either route presses them.
/// Per player, 0-based, like `setKeys:player:`.
- (void)setCStickX:(float)x y:(float)y player:(NSInteger)player;

@end

NS_ASSUME_NONNULL_END
