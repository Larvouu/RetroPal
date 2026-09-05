//
//  PCSXBridge.h
//  EmulateurGBA
//
//  ObjC bridge to the PCSX-ReARMed core, serving the PlayStation.
//
//  This is the only layer that touches the core, and it is the first bridge in
//  the app that speaks a PUBLISHED API rather than a core's internals: mGBA,
//  melonDS and MesenCE are each driven through their own C/C++ types, while
//  PCSX-ReARMed is built as a libretro core and driven through libretro.h. The
//  reasons are in the implementation's header comment; the consequence worth
//  knowing here is that the API is a global C one with a single instance, so
//  exactly one PCSXBridge may exist at a time.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "EmulatorBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// The session's video texture, and the first console here whose picture size
/// is not fixed.
///
/// Every other console this app runs has one frame size, or two (the SNES
/// switches between an ordinary and a hi-res mode). The PlayStation has many:
/// 256x224 through 640x480, chosen by the game and changed mid-game, sometimes
/// between a menu and the field, sometimes for a single FMV.
///
/// So the buffer is allocated once at the core's own maximum and the live
/// picture occupies its top-left corner. `screenWidth` / `screenHeight` report
/// what is actually being drawn right now and move with the game;
/// `bufferStride` stays at the maximum, and the renderer samples the sub-rect
/// those two describe. Presenting at the maximum and scaling the small modes up
/// (the trick used for the SNES) is not affordable here: the SNES has one
/// integer ratio to apply, the PlayStation has a dozen non-integer ones and a
/// CPU that is already the binding constraint on this console.
///
/// 1024 rather than 640 because the core's NEON renderer is built with the 2x
/// enhancement available (`VOUT_MAX_WIDTH` is 1024 when `GPU_NEON` is defined).
/// The enhancement is off by default and costs CPU; the buffer is sized for it
/// so that turning it on later is a setting and not a re-architecture.
extern const NSInteger PS1MaxBufferWidth;    // 1024
extern const NSInteger PS1MaxBufferHeight;   // 512

/// A disc in a multi-disc game, for the pause menu's disc picker.
@interface PS1Disc : NSObject
/// Index the core knows this disc by, 0-based.
@property (nonatomic, readonly) NSUInteger index;
/// Label to show. The core's own, when it has one (it reads the `.m3u`'s
/// entries); otherwise the disc's 1-based number as bare text.
@property (nonatomic, readonly) NSString *label;
/// YES when `label` is that bare number rather than something the player wrote
/// in their `.m3u`. The caller needs this and cannot infer it: a playlist whose
/// entries really are named "1" and "2" is indistinguishable from no labels at
/// all once the string is in hand. Only the fallback gets wrapped in a
/// localized "Disc %@"; a player's own label is shown exactly as they wrote it.
@property (nonatomic, readonly) BOOL labelIsFallback;
@end

@interface PCSXBridge : NSObject <EmulatorBridge>

// MARK: - PlayStation-specific surface
//
// Everything below is declared here rather than in `EmulatorBridge` because it
// describes hardware no other console in the app has. The protocol stays the
// four cores' common contract, and the session reaches these through a cast,
// exactly as it already does for melonDS's microphone and GBA slot 2.

/// Where the app keeps this game's save data.
///
/// Set BEFORE `loadROMAtPath:`, because the core asks for it while loading. It
/// is not where memory card 1 is written (that card is ours, and travels
/// through the app's own save path), but refusing to answer made the core log
/// "Memory card saving might not work" on every single launch, which is
/// alarming and untrue.
- (void)setSaveDirectory:(NSString *)path;

/// Analog stick state for the DualShock, each axis -1.0...1.0, y positive DOWN
/// (the direction libretro reports and the direction UIKit uses, so nothing is
/// flipped on the way through).
///
/// Sending any analog input switches the emulated pad from the digital
/// controller to a DualShock, which is the pad the analog-only games require.
/// Both a physical controller and the on-screen sticks reach here: the cross
/// stays a cross beside them, as it does on the hardware, and the two sticks
/// are separate because their jobs are (the left one moves the character, the
/// right one moves the camera).
- (void)setLeftStickX:(float)x y:(float)y;
- (void)setRightStickX:(float)x y:(float)y;

/// Press the pad's ANALOG switch, the little button between SELECT and START.
///
/// On real hardware it toggles the controller between behaving as a digital
/// pad and behaving as a DualShock, and lights the LED. It matters more than
/// its obscurity suggests: some games only read the sticks with analog ON, and
/// a few misbehave unless it is OFF, which is exactly why Sony put a switch on
/// the pad rather than choosing for the player.
///
/// It also does something no stick can do on a touch screen. Analog otherwise
/// only ever engages when a physical stick moves, so a player on glass could
/// never reach a game's analog mode at all.
- (void)pressAnalogModeButton;

/// Whether the game the core loaded holds more than one disc (an `.m3u`, or a
/// single image the core found several sessions in).
@property (nonatomic, readonly) BOOL isMultiDisc;

/// The discs, in the order the core knows them. Empty for a single-disc game.
@property (nonatomic, readonly) NSArray<PS1Disc *> *discs;

/// Index of the disc currently in the drive.
@property (nonatomic, readonly) NSUInteger currentDiscIndex;

/// Swap the drive to another disc, which is the emulated equivalent of opening
/// the lid, changing the disc and closing it. Returns NO if the core refused,
/// or if the index is out of range. Safe to call while the game runs, which is
/// the only time it is ever useful.
- (BOOL)changeToDiscAtIndex:(NSUInteger)index;

@end

NS_ASSUME_NONNULL_END
