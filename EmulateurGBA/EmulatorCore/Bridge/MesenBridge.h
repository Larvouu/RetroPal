//
//  MesenBridge.h
//  EmulateurGBA
//
//  ObjC bridge to the MesenCE core, serving the Super Nintendo, the NES, the
//  Master System and the Game Gear. One bridge for four consoles because Mesen
//  is one core for all of them: the console is chosen by the ROM Mesen loads,
//  and everything below (video, audio, input, saves, cheats, memory) is
//  console-agnostic apart from the button and memory maps, which are small
//  tables in the implementation. The Master System and the Game Gear are one
//  console to Mesen (`SmsConsole`, its model chosen by the `.gg` extension),
//  and one family here.
//
//  This is the only layer that touches Mesen internals.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "EmulatorBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// The session's fixed video buffer, per console.
///
/// SNES is presented at DOUBLE its normal resolution on purpose. The core sends
/// 256x224 for an ordinary frame and 512x448 when a game switches to hi-res
/// (menus and text in Kirby's Dream Land 3, Seiken Densetsu 3, RPM Racing), and
/// it can switch mid-game. Our renderer wants one texture size for the whole
/// session, so the bridge always presents the larger of the two and doubles the
/// pixels of ordinary frames, which is lossless and invisible. Sizing the other
/// way would mean throwing away the hi-res detail those games switch modes to
/// get.
///
/// NES has no such mode. It is presented at its native height and 8 columns
/// short of its native width: the leftmost 8 pixels are the ones the PPU can
/// blank and most games do (see `kNesOverscanLeft`), so they are cropped in the
/// core and never reach the texture.
extern const NSInteger SNESBufferWidth;    // 512
extern const NSInteger SNESBufferHeight;   // 448
extern const NSInteger NESBufferWidth;     // 248 (256 - 8 cropped columns)
extern const NSInteger NESBufferHeight;    // 240

/// The Master System and the Game Gear draw into the same 256x240 frame and
/// show a part of it: the Master System its 192 visible lines, the Game Gear
/// the 160x144 window of its own screen. The rest is cropped in the core (see
/// `kSmsOverscan` and `kGgOverscan`), so each texture is the picture alone.
extern const NSInteger SMSBufferWidth;     // 256
extern const NSInteger SMSBufferHeight;    // 192
extern const NSInteger GGBufferWidth;      // 160
extern const NSInteger GGBufferHeight;     // 144

@interface MesenBridge : NSObject <EmulatorBridge>

/// The eight digits Mesen reads from a Master System or Game Gear Pro Action
/// Replay code, whichever way it was printed (`00C0:0F05`, `00C0 0F05`,
/// `00C0-0F05`). A class method so it can be tested without a core.
+ (NSString *)sega8BitProActionReplayDigits:(NSString *)code NS_SWIFT_NAME(sega8BitProActionReplayDigits(_:));

@end

NS_ASSUME_NONNULL_END
