//
//  MGBABridge.h
//  EmulateurGBA
//
//  ObjC bridge to mGBA emulator core.
//  This is the only layer that touches mGBA internals.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "EmulatorBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// GBA button flags matching GBA hardware register layout
typedef NS_OPTIONS(uint32_t, GBAButton) {
    GBAButtonA      = (1 << 0),
    GBAButtonB      = (1 << 1),
    GBAButtonSelect = (1 << 2),
    GBAButtonStart  = (1 << 3),
    GBAButtonRight  = (1 << 4),
    GBAButtonLeft   = (1 << 5),
    GBAButtonUp     = (1 << 6),
    GBAButtonDown   = (1 << 7),
    GBAButtonR      = (1 << 8),
    GBAButtonL      = (1 << 9),
};

/// Default GBA screen dimensions
extern const NSInteger GBAScreenWidth;
extern const NSInteger GBAScreenHeight;

/// GB/GBC screen dimensions
extern const NSInteger GBScreenWidth;
extern const NSInteger GBScreenHeight;

@interface MGBABridge : NSObject <EmulatorBridge>

@end

NS_ASSUME_NONNULL_END
