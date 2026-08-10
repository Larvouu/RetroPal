//
//  MelonDSBridge.h
//  EmulateurGBA
//
//  ObjC++ bridge to melonDS emulator core for Nintendo DS games.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "EmulatorBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// NDS screen dimensions
extern const NSInteger NDSScreenWidth;   // 256
extern const NSInteger NDSScreenHeight;  // 192 (single screen)

@interface MelonDSBridge : NSObject <EmulatorBridge>

/// Set the NDS firmware language (0=Japanese..6=Chinese). Pass -1 for auto-detect from device locale.
- (void)setNDSLanguage:(int)language;

/// The NDS firmware language index (0=Japanese..6=Chinese) that "auto"
/// resolves to for the current device locale, falling back to English (1)
/// when the device language is not one the DS firmware supports. Lets the
/// Settings UI label the auto option with the language it will actually use
/// (e.g. "Auto (Français)") instead of a vague "Auto (System)".
+ (int)autoResolvedNDSLanguageIndex;

/// Seed the NDS real-time clock from the device clock, or from the
/// "set date and time manually" setting when enabled. Called at game launch
/// and again after loading a save state (which would otherwise restore the
/// snapshot's stale clock).
- (void)seedRealTimeClock;

/// Activate/deactivate simulated microphone blow input
- (void)setMicBlowActive:(BOOL)active;

/// Configure a GBA cart to mount in slot 2 when the next ROM is loaded
/// (dual-slot: Pal Park, cross-game unlocks). Must be called BEFORE
/// `loadROMAtPath:` — the cart is inserted at boot, like on real hardware.
/// `savePath` is the GBA game's own battery save; the cart both reads it at
/// insert and writes back to it in play. Pass nil for both to clear.
- (void)configureGBASlotROMPath:(nullable NSString *)romPath savePath:(nullable NSString *)savePath;

@end

NS_ASSUME_NONNULL_END
