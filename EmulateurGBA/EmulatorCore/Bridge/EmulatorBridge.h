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

/// Rendered width / rendered height of the game as it should be DISPLAYED,
/// which is not always the buffer's own ratio.
///
/// It matches the buffer for the three original cores (GBA 3:2, GB/GBC 10:9,
/// NDS 256x384 stacked), and it deliberately does not for SNES/NES: those
/// consoles drew for a 4:3 television and their artists compensated for the
/// stretch, while the buffer is 8:7 and, on SNES, double-height so a hi-res
/// frame fits without resizing the texture mid-game.
@property (nonatomic, readonly) CGFloat displayAspect;

/// Byte order of `frameBuffer`: YES = B,G,R,A in memory (melonDS, Mesen),
/// NO = R,G,B,A (mGBA). The renderer picks its Metal pixel format from this.
///
/// It used to be inferred from `hasTouchScreen`, which happened to be right
/// while the DS was the only BGRA core and is not a fact about touch screens.
@property (nonatomic, readonly) BOOL usesBGRAPixelOrder;

/// Frames per second the loaded game actually runs at.
///
/// The renderer used to pace every console at the GBA's 59.7275 fps, which is
/// right for GBA and GB/GBC and near enough for the DS. It is not near enough
/// for a PAL SNES or NES cartridge, which runs at 50: those would play a fifth
/// too fast and produce a fifth more audio per second than the output can
/// consume. Only Mesen reports a real figure; the two original cores return the
/// constant the renderer already used, so their pacing is untouched.
@property (nonatomic, readonly) double framesPerSecond;

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

/// Block until the picture produced by the LAST `runFrame` is readable through
/// `frameBuffer`, then return. Called once per drawn frame, just before the
/// buffer is uploaded — NOT once per emulated frame.
///
/// mGBA and melonDS write their picture inside `runFrame` and hand back that
/// same buffer, so for them this is a no-op and the default below is the whole
/// implementation. MesenCE does not: its PPU parks the finished frame on a
/// decode thread, so without this the upload takes the PREVIOUS frame and the
/// console runs a frame behind the other three.
///
/// It is separate from `runFrame` on purpose. Fast-forward and catch-up run
/// several emulated frames per drawn one and throw all but the last picture
/// away; waiting inside `runFrame` would have paid for every one of them, which
/// is a throughput cost for latency nobody sees.
@optional
- (void)awaitDisplayFrame;
@required
- (void)setKeys:(uint32_t)keys;

// MARK: - Video

/// Override the Game Boy DMG palette with 12 0xRRGGBB colors (BG 4, OBJ0 4,
/// OBJ1 4, each lightest→darkest). Applies live (next rendered frame) on a
/// running DMG-mode game and persists across resets for the session. No-op on
/// systems without a DMG palette (GBA, NDS) and ignored by CGB-mode games,
/// which define their own colors.
- (void)setGBPalette:(const uint32_t *)colors;

/// Whether the running game actually renders through the DMG palette (GB
/// platform, DMG model). CGB-mode games return NO: they carry their own
/// colors and ignore the override. NO until a ROM is loaded.
- (BOOL)isDMGPaletteApplicable;

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
/// no side effects on emulation. SNES = 0x7E0000 work RAM plus the synthetic
/// addresses rcheevos uses for cartridge RAM; NES = 0x0000 internal RAM and
/// 0x6000 cartridge RAM. Every console the app ships serves this.
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

// Applying a cheat set is CLEAR then re-add the enabled ones (see
// `CheatManagerView.reapplyAll`), which is the only shape MesenCE can honour:
// it has no global enable flag. There is therefore no per-set enable here.
- (BOOL)addCheatCode:(NSString *)code type:(int)type;
- (void)clearCheats;

// MARK: - Touch Screen (NDS)

/// Press the touch screen at the given coordinates (no-op for non-touch systems)
- (void)touchScreenAtX:(int)x y:(int)y;

/// Release the touch screen (no-op for non-touch systems)
- (void)touchScreenRelease;

@end

NS_ASSUME_NONNULL_END
