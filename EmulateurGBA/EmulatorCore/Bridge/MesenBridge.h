//
//  MesenBridge.h
//  EmulateurGBA
//
//  ObjC bridge to the MesenCE core, serving BOTH the Super Nintendo and the
//  NES. One bridge for two consoles because Mesen is one core for both: the
//  console is chosen by the ROM Mesen loads, and everything below (video,
//  audio, input, saves, cheats, memory) is console-agnostic apart from the
//  button and memory maps, which are two small tables in the implementation.
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

@interface MesenBridge : NSObject <EmulatorBridge>

@end

NS_ASSUME_NONNULL_END
