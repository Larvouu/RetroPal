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

@end

NS_ASSUME_NONNULL_END
