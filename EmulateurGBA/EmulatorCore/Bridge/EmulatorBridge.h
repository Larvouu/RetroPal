//
//  EmulatorBridge.h
//  EmulateurGBA
//
//  Protocol defining the interface between the emulator session
//  and any emulator core (mGBA, melonDS, etc.).
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@protocol EmulatorBridge <NSObject>

/// Whether a ROM is currently loaded and ready
@property (nonatomic, readonly) BOOL isROMLoaded;

/// Screen width in pixels (e.g., 240 for GBA, 256 for NDS)
@property (nonatomic, readonly) NSInteger screenWidth;

/// Screen height in pixels for a single screen (e.g., 160 for GBA, 192 for NDS)
@property (nonatomic, readonly) NSInteger screenHeight;

/// Video buffer stride in pixels (may be larger than screenWidth)
@property (nonatomic, readonly) NSInteger bufferStride;

/// Total height of the video buffer (screenHeight for single-screen, 384 for NDS dual-screen)
@property (nonatomic, readonly) NSInteger totalBufferHeight;

/// Whether this system has a touch screen (e.g., NDS bottom screen)
@property (nonatomic, readonly) BOOL hasTouchScreen;

// MARK: - ROM Management

- (BOOL)loadROMAtPath:(NSString *)path;
- (void)reset;
- (void)setSavePath:(NSString *)path;
/// Force the battery save (in-game SRAM/flash/EEPROM) to be written to disk
/// now. Called when the app backgrounds so a suspended-then-killed app does
/// not leave the .sav stale. Safe to call while paused; writes only the live
/// save buffer, so it can never corrupt the save.
- (void)flushSaveData;

// MARK: - Emulation

- (void)runFrame;
- (void)setKeys:(uint32_t)keys;

// MARK: - Video

- (nullable const uint32_t *)frameBuffer;
/// Create an image of the primary screen (top screen only for NDS). Used for thumbnails and save previews.
- (nullable CGImageRef)createFrameImage CF_RETURNS_RETAINED;
/// Create an image of both screens (NDS only). Returns nil for single-screen systems.
- (nullable CGImageRef)createDualScreenFrameImage CF_RETURNS_RETAINED;

// MARK: - Save States

- (BOOL)saveStateToPath:(NSString *)path;
- (BOOL)loadStateFromPath:(NSString *)path;

// MARK: - Memory (RetroAchievements)

/// Read `length` bytes from the core's real address bus starting at `address`
/// into `buffer`; returns the number of bytes actually read (0 = unreadable /
/// unmapped address). `address` is a REAL console bus address, NOT a flat
/// RetroAchievements address: GBA = 0x03000000 IWRAM / 0x02000000 EWRAM /
/// 0x0E000000 SRAM; GB/GBC = 0x0000–0xFFFF. The RetroAchievements runtime
/// translates RA flat addresses to these via `rc_console_memory_regions()`
/// before calling, so the bridge stays core-generic and RA-agnostic. Read-only;
/// no side effects on emulation. NDS returns 0 (RA support deferred).
- (NSInteger)readMemoryAtAddress:(uint32_t)address into:(uint8_t *)buffer length:(NSInteger)length;

// MARK: - Speed

- (void)setSpeedMultiplier:(int)multiplier;

// MARK: - Audio

- (unsigned int)audioSampleRate;
- (NSInteger)readAudioSamples:(int16_t *)buffer count:(NSInteger)count;

/// If the core has reported a new audio sample rate since the last call,
/// return it and clear the pending state. Otherwise return 0.
///
/// GBA games can change the audio rate at runtime by writing the SOUNDBIAS
/// register's Resolution field (32,768 / 65,536 / 131,072 / 262,144 Hz). mGBA
/// surfaces this through `mAVStream.audioRateChanged`. The host calls this
/// poll after each `runFrame` and rebuilds its audio engine on a non-zero
/// return. Cores without a runtime-variable rate (e.g. melonDS, GB/GBC) may
/// return 0 unconditionally.
- (unsigned int)consumePendingAudioRate;

// MARK: - Rewind

- (void)initRewind:(NSInteger)seconds;
- (void)rewindAppend;
- (BOOL)rewindFrames:(NSInteger)count;

// MARK: - Lifecycle

- (void)shutdown;

// MARK: - Cheat Codes

- (BOOL)addCheatCode:(NSString *)code type:(int)type;
- (void)clearCheats;
- (void)setCheatsEnabled:(BOOL)enabled;

// MARK: - Touch Screen (NDS)

/// Press the touch screen at the given coordinates (no-op for non-touch systems)
- (void)touchScreenAtX:(int)x y:(int)y;

/// Release the touch screen (no-op for non-touch systems)
- (void)touchScreenRelease;

@end

NS_ASSUME_NONNULL_END
