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

// MARK: - Memory Access (GBA-specific)
//
// Direct reads of the emulated machine's address space via mGBA's bus.
// Returns 0 when no core is loaded. Deliberately NOT part of the
// EmulatorBridge protocol: this is GBA-only, and callers reach it through
// `(bridge as? MGBABridge)` (same pattern as MelonDSBridge's mic methods).
// Used by the in-game translation feature to read structured game state.
- (uint8_t)readMemory8:(uint32_t)address;
- (uint16_t)readMemory16:(uint32_t)address;
- (uint32_t)readMemory32:(uint32_t)address;

@end

NS_ASSUME_NONNULL_END
