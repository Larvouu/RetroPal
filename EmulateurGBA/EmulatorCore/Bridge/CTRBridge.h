//
//  CTRBridge.h
//  EmulateurGBA
//
//  ObjC bridge to Azahar's own libretro core, serving the Nintendo 3DS (CTR is
//  the console's hardware code name).
//
//  The fifth bridge driven through libretro and the third that draws on the
//  GPU: Azahar renders with Vulkan through the same frontend as the Nintendo 64
//  and the PSP (N64VulkanFrontend, on MoltenVK), its CPU on FastInterp (the
//  App Store forbids a JIT), and the finished frame is copied back into an
//  ordinary framebuffer that every frame consumer of the app reads. One
//  instance at a time, as every libretro bridge; the entry points are renamed
//  ctr_retro_* at build time (Vendor/azahar-ios/ctr_symbols.h). See CTRBridge.mm.
//
//  PHASE 1 (2026-10-19): ONE PICTURE. The core composes both screens into one
//  image itself, the 400x240 top screen over the 320x240 bottom one, centred
//  (Azahar's "default" layout, 400x480). The bridge hands that image to the
//  app as a single-screen console, so none of the Nintendo DS's two-screen
//  code (two equal 256x192 screens) is used with the wrong geometry; the 3DS
//  answers `hasTouchScreen` NO for that reason, and its touch screen is the
//  rectangle `CTRBottomScreenRect` inside the picture, driven through
//  `touchScreenAtX:y:` in the picture's own pixels. Its own two-screen layouts
//  come with its own page.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "EmulatorBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// The composed picture: the top screen (400x240) over the bottom one
/// (320x240, centred), at the core's 1x resolution.
extern const NSInteger CTRPictureWidth;     // 400
extern const NSInteger CTRPictureHeight;    // 480

/// The bottom (touch) screen inside the composed picture, in its pixels:
/// x 40...360, y 240...480. What a touch view over the picture maps to.
extern const CGRect CTRBottomScreenRect;

/// Posted on the main thread, once per game, when the picture can no longer be
/// updated (the GPU did not deliver a frame in time). Same contract as
/// PSPBridgeDisplayLostNotification.
FOUNDATION_EXPORT NSNotificationName const CTRBridgeDisplayLostNotification;

/// Posted on the main thread, once per game, when the game has ended: it closed
/// itself, or an in-game reboot could not start the console again. No frame
/// runs and no state is saved from then on; the game screen offers to quit.
FOUNDATION_EXPORT NSNotificationName const CTRBridgeGameEndedNotification;

@interface CTRBridge : NSObject <EmulatorBridge>

// MARK: - 3DS-specific surface
//
// Declared here rather than in `EmulatorBridge`, like the PSP's: the session
// reaches it through a cast.

/// The circle pad, each axis -1.0...1.0, y positive DOWN (libretro's and
/// UIKit's direction).
- (void)setStickX:(float)x y:(float)y;

/// The New 3DS's C-stick, from the page's right stick or a controller's: same
/// axes and direction as the circle pad.
- (void)setCStickX:(float)x y:(float)y;

/// The microphone: a recorded blow while YES, silence otherwise, as the DS's
/// (MelonDSBridge's `setMicBlowActive:`).
- (void)setMicBlowActive:(BOOL)active;

/// The console's motion, in the 3DS's own axes (CTRMotion.swift turns the
/// phone's into them): acceleration in g (lying still on a table is
/// 0, -1, 0), rotation in radians per second.
- (void)setAccelerationX:(float)ax y:(float)ay z:(float)az
               rotationX:(float)gx y:(float)gy z:(float)gz;

/// The game's camera: called with YES when a game starts a camera (and again
/// when it switches between the inner and the outer ones), NO when it stops.
/// From the emulation thread. Set before `loadROMAtPath:` (CTRCamera.swift).
/// Atomic: it is read on the work queue while a game unloads, and cleared by
/// `CTRCamera.deinit` on the camera's own queue at that same moment; a
/// nonatomic getter could hand back a block the setter had just released
/// (audit, 2026-10-29).
@property (atomic, copy, nullable) void (^cameraHandler)(BOOL run, BOOL inner);

/// A camera frame for the game, 32-bit pixels whose bytes are B, G, R and A
/// in memory (kCVPixelFormatType_32BGRA, which libretro's XRGB8888 reads as
/// it is). Any thread; the core keeps a copy.
- (void)deliverCameraFrame:(const void *)pixels width:(NSInteger)width height:(NSInteger)height
               bytesPerRow:(NSInteger)bytesPerRow;

/// Where the emulated 3DS keeps everything the game writes (its SD card, its
/// NAND, the save data) and the core's shader cache: one folder for the
/// console, under the app's Application Support (never a cache iOS may purge:
/// the shader cache is what makes a game's second launch smooth). Set BEFORE
/// `loadROMAtPath:`; created if missing (the core falls back to a folder in
/// the user's home when it cannot create it, which on iOS is no place at all).
- (void)setSystemDirectory:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
