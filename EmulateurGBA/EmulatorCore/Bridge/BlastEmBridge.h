//
//  BlastEmBridge.h
//  EmulateurGBA
//
//  ObjC bridge to BlastEm, serving the Mega Drive.
//
//  The third bridge driven through libretro, after PCSXBridge and N64Bridge,
//  and it shares that API's one constraint: libretro is a global C interface
//  with a single implicit instance, so exactly one BlastEmBridge may exist at a
//  time. The three libretro cores do not see each other: this one's entry
//  points are renamed md_retro_* at build time (Vendor/blastem-ios/md_symbols.h)
//  and the rest of the core is hidden inside one prelinked object.
//
//  Cartridges only. BlastEm also runs the Mega-CD and the 32X, and both need
//  Sega's own BIOS files, which the app has no way to receive (the PlayStation
//  made the same choice, see PCSXBridge.mm); the importer never routes a disc
//  or a .32x here.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "EmulatorBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// The picture's allocation. The Mega Drive draws 320 pixels wide (H40, most
/// games) or 256 (H32), 224 lines tall in NTSC or 240 in PAL, and twice that
/// in its interlaced mode (Sonic 2's split screen), chosen by the game and
/// changed mid-game. So the buffer is allocated at the largest of them and the
/// live picture occupies its top-left corner, as on the PlayStation and the
/// N64. These are the core's figures with its overscan border cropped, which
/// is what the console's own television showed.
extern const NSInteger MDMaxBufferWidth;    // 320
extern const NSInteger MDMaxBufferHeight;   // 480

/// How the app's button mask reaches the Mega Drive's pad.
///
/// Chosen from where a CONTROLLER's buttons land with no mapping of its own
/// (`ControllerManager.buttonMask`): its bottom face sets 0x001, its right
/// face 0x002, its left face 0x800, its top face 0x400, its bumpers 0x200 and
/// 0x100, its Options button 0x004 and its Menu button 0x008. So:
///
///   0x800 left face   -> A        0x200 L bumper -> X
///   0x001 bottom face -> B        0x400 top face -> Y
///   0x002 right face  -> C        0x100 R bumper -> Z
///   0x004 Options     -> MODE     0x008 Menu     -> START
///
/// A, B and C, the three buttons nearly every game uses, take the left,
/// bottom and right faces, so they keep their order under one thumb; X, Y and
/// Z, which only six-button games read, take the left bumper, the top face
/// and the right bumper, the upper row in its order, left to right. The
/// on-screen pad draws the six buttons in the Mega Drive's own two rows and
/// sends these same bits. No new bit is needed: the console has fewer buttons
/// than the mask already names.

/// Nothing beyond the common contract for the session: a cartridge console
/// with one picture, a digital pad and battery-backed save RAM is exactly what
/// `EmulatorBridge` describes, so the session needs no cast to reach this one.
/// The one addition is the save-state check below, for the tests.
@interface BlastEmBridge : NSObject <EmulatorBridge>

/// Whether a slot file holds a state this core can be handed without the risk
/// of it ending the app: its length, its sections and the sizes the core would
/// otherwise stop on are checked (BlastEmBridge.mm, Save-state files). A class
/// method so the check can be tested without a running core.
+ (BOOL)isLoadableStateFile:(NSData *)file NS_SWIFT_NAME(isLoadableStateFile(_:));

@end

NS_ASSUME_NONNULL_END
