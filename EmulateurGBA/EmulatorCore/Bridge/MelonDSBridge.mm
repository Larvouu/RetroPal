//
//  MelonDSBridge.mm
//  EmulateurGBA
//
//  ObjC++ implementation bridging melonDS to Swift.
//

#import "MelonDSBridge.h"

#include <memory>
#include <string>
#include <vector>
#include <cstring>

#include <melonds/NDS.h>
#include <melonds/NDSCart.h>
#include <melonds/GBACart.h>
#include <melonds/GPU.h>
#include <melonds/SPU.h>
#include <melonds/Args.h>
#include <melonds/Savestate.h>
#include <melonds/Platform.h>
#include <melonds/ARCodeFile.h>
#include <melonds/AREngine.h>
#include <melonds/SPI_Firmware.h>

const NSInteger NDSScreenWidth = 256;
const NSInteger NDSScreenHeight = 192;

// Forward declaration for platform save path helpers (defined in MelonDSPlatform.cpp)
namespace melonDS::Platform {
    void SetNDSSavePath(const std::string& path);
    void SetGBASavePath(const std::string& path);
}

// Forward declarations for platform mic functions (defined in MelonDSPlatform.cpp)
extern "C" void MelonDSMic_SetBlowActive(bool active);

/// Monotonic milliseconds. Defined with the rewind code below, declared here
/// because runFrame times itself to feed the rewind late-frame guard.
static double MelonNowMs(void);

#if DEBUG
#define RADebugLogNDS(fmt, ...) NSLog(@fmt, ##__VA_ARGS__)
#endif

/// Map iOS locale language code to NDS firmware language enum value.
/// Returns 1 (English) for unrecognized languages.
static int resolveNDSLanguageFromLocale(void) {
    NSString *langCode = [[NSLocale currentLocale] languageCode];
    if ([langCode isEqualToString:@"ja"]) return 0; // Japanese
    if ([langCode isEqualToString:@"en"]) return 1; // English
    if ([langCode isEqualToString:@"fr"]) return 2; // French
    if ([langCode isEqualToString:@"de"]) return 3; // German
    if ([langCode isEqualToString:@"it"]) return 4; // Italian
    if ([langCode isEqualToString:@"es"]) return 5; // Spanish
    if ([langCode isEqualToString:@"zh"]) return 6; // Chinese
    return 1; // Default to English
}

@implementation MelonDSBridge {
    std::unique_ptr<melonDS::NDS> _nds;
    BOOL _romLoaded;

    // Combined framebuffer: top (256x192) + bottom (256x192) = 256x384
    uint32_t _framebuffer[256 * 384];

    // Key mask: bits match NDS hardware (A=0, B=1, Select=2, Start=3,
    // Right=4, Left=5, Up=6, Down=7, R=8, L=9, X=10, Y=11)
    uint32_t _keyMask;

    // Save path for battery saves
    std::string _savePath;
    std::string _romName;

    // Slot-2 GBA cart (dual-slot), configured before loadROMAtPath:.
    // Kept for the bridge's lifetime: loadROMAtPath's internal shutdown must
    // not drop a configuration made just before it.
    NSString *_gbaSlotROMPath;
    NSString *_gbaSlotSavePath;
    // Mirror of the mounted cart's save path for flushSaveData (empty = no cart).
    std::string _gbaSavePath;

    // Rewind. See the implementation block for the design and its measurements.
    uint8_t *_rwCurrent;          // the latest snapshot, kept whole
    uint8_t *_rwScratch;          // receives each fresh serialize, then swapped in
    size_t _rwStateLength;        // bytes actually used (states measured 19.0 MB)
    NSInteger _rwFrameCounter;
    NSInteger _rwDepth;           // snapshots retained
    NSInteger _rwStored;          // snapshots currently held
    NSInteger _rwNewest;          // ring head
    void *_rwUndo;                // ring of RewindUndo, _rwDepth entries
    dispatch_queue_t _rwDiffQueue;
    _Atomic(BOOL) _rwDiffInFlight;
    double _rwFrameMsAccum;       // rolling emulation cost, drives the late guard
    NSInteger _rwFrameMsCount;
    double _rwFrameMsAverage;
    double _rwLastFrameMs;        // most recent frame, for opportunistic timing
    BOOL _rwPending;              // a snapshot is due and waiting for room
    NSInteger _rwPendingFrames;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _romLoaded = NO;
        _keyMask = 0xFFF; // All keys released (active-low)
        memset(_framebuffer, 0, sizeof(_framebuffer));
    }
    return self;
}

- (void)dealloc {
    [self shutdown];
}

// MARK: - EmulatorBridge Properties

- (BOOL)isROMLoaded {
    return _romLoaded;
}

- (NSInteger)screenWidth {
    return NDSScreenWidth;
}

- (NSInteger)screenHeight {
    return NDSScreenHeight;
}

- (NSInteger)bufferStride {
    return NDSScreenWidth;
}

- (NSInteger)totalBufferHeight {
    return NDSScreenHeight * 2; // 384 (top + bottom)
}

// Both screens, every frame, for the whole session: the texture is the picture.
- (NSInteger)maxBufferHeight {
    return self.totalBufferHeight;
}

/// The stacked pair, 256x384. Portrait geometry is built around this shape and
/// the landscape branch ignores the aspect entirely, so this is exactly the
/// expression the layout used to compute for itself.
- (CGFloat)displayAspect {
    return (CGFloat)NDSScreenWidth / (CGFloat)(NDSScreenHeight * 2);
}

/// melonDS writes XRGB8888: bytes in memory are B,G,R,X.
- (BOOL)usesBGRAPixelOrder {
    return YES;
}

/// Deliberately the GBA figure rather than the DS's own 59.826: it is what the
/// renderer has always paced this core at, and this change is about the two new
/// consoles, not about re-timing a shipped one.
- (double)framesPerSecond {
    return 16777216.0 / 280896.0;
}

- (BOOL)hasTouchScreen {
    return YES;
}

// MARK: - ROM Management

- (BOOL)loadROMAtPath:(NSString *)path {
    [self shutdown];

    // Create NDS instance with default args (FreeBIOS, software renderer)
    melonDS::NDSArgs args {};
    args.JIT = std::nullopt; // JIT disabled on iOS (code signing)

    _nds = std::make_unique<melonDS::NDS>(std::move(args));

    // Load ROM file into memory
    NSData *romData = [NSData dataWithContentsOfFile:path];
    if (!romData || romData.length == 0) {
        NSLog(@"MelonDSBridge: Failed to read ROM file: %@", path);
        _nds.reset();
        return NO;
    }

    // Parse ROM into a cart object
    auto cart = melonDS::NDSCart::ParseROM(
        (const melonDS::u8 *)romData.bytes,
        (melonDS::u32)romData.length
    );
    if (!cart) {
        NSLog(@"MelonDSBridge: Failed to parse ROM: %@", path);
        _nds.reset();
        return NO;
    }

    // Extract ROM name for direct boot
    _romName = [[[path lastPathComponent] stringByDeletingPathExtension] UTF8String];

    // Insert cart and reset
    _nds->SetNDSCart(std::move(cart));

    [self insertConfiguredGBACart];

    _romLoaded = YES;
    NSLog(@"MelonDSBridge: ROM loaded successfully: %@", [path lastPathComponent]);
    return YES;
}

- (void)configureGBASlotROMPath:(NSString *)romPath savePath:(NSString *)savePath {
    _gbaSlotROMPath = [romPath copy];
    _gbaSlotSavePath = [savePath copy];
}

/// Mount the configured GBA cart in slot 2 (no-op when none configured).
/// Failures never fail the NDS load — the game boots with an empty slot,
/// exactly as if no cart were inserted.
- (void)insertConfiguredGBACart {
    if (_gbaSlotROMPath.length == 0) return;

    NSData *gbaROM = [NSData dataWithContentsOfFile:_gbaSlotROMPath];
    if (!gbaROM || gbaROM.length == 0) {
        NSLog(@"MelonDSBridge: Slot-2 GBA ROM unreadable, booting with empty slot: %@", _gbaSlotROMPath);
        return;
    }
    // The GBA game's existing battery save, if any (Pal Park reads the party
    // out of it). A missing file is normal for a never-played game.
    NSData *gbaSave = nil;
    if (_gbaSlotSavePath.length > 0) {
        gbaSave = [NSData dataWithContentsOfFile:_gbaSlotSavePath];
    }
    auto gbaCart = melonDS::GBACart::ParseROM(
        (const melonDS::u8 *)gbaROM.bytes, (melonDS::u32)gbaROM.length,
        (const melonDS::u8 *)(gbaSave ? gbaSave.bytes : nullptr),
        (melonDS::u32)(gbaSave ? gbaSave.length : 0)
    );
    if (!gbaCart) {
        NSLog(@"MelonDSBridge: Slot-2 GBA ROM failed to parse, booting with empty slot: %@", _gbaSlotROMPath);
        return;
    }
    _nds->SetGBACart(std::move(gbaCart));
    // Write-through for in-play saves (Pal Park REMOVES migrated Pokémon from
    // the GBA save, so writes matter as much as reads).
    if (_gbaSlotSavePath.length > 0) {
        _gbaSavePath = [_gbaSlotSavePath UTF8String];
        melonDS::Platform::SetGBASavePath(_gbaSavePath);
    }
    NSLog(@"MelonDSBridge: Slot-2 GBA cart mounted: %@ (save: %@)",
          [_gbaSlotROMPath lastPathComponent], gbaSave ? @"loaded" : @"none yet");
}

- (void)reset {
    if (!_nds || !_romLoaded) return;

    [self invalidateRewindBuffer];   // same reason as loadStateFromPath:

    _nds->Reset();

    // Direct boot (skip firmware menu, no BIOS needed)
    if (_nds->NeedsDirectBoot()) {
        _nds->SetupDirectBoot(_romName);
    }

    // Apply language setting from UserDefaults before starting
    NSString *langPref = [[NSUserDefaults standardUserDefaults] stringForKey:@"ndsLanguage"];
    int langValue;
    if (!langPref || [langPref isEqualToString:@"auto"]) {
        langValue = resolveNDSLanguageFromLocale();
    } else {
        langValue = [langPref intValue];
    }
    [self setNDSLanguage:langValue];
    NSLog(@"MelonDSBridge: Language set to %d (pref=%@, locale=%@)", langValue, langPref ?: @"nil", [[NSLocale currentLocale] languageCode]);

    // Seed the real-time clock. _nds->Reset() above left it at melonDS's
    // 2000-01-01 default, so games that read the RTC (Pokémon HG/SS berries,
    // tides, daily events...) were stuck in the year 2000. Seed it here,
    // after Reset and before Start, the same point melonDS's own frontend
    // does it.
    [self seedRealTimeClock];

    _nds->Start();
}

/// Set the NDS real-time clock to the device's current local time, or to a
/// user-chosen date/time when "set date and time manually" is enabled in
/// Settings. melonDS's SetDateTime takes the full year (it clamps to the
/// DS's 2000-2099 range internally) and recomputes the day-of-week, so this
/// also fixes the wrong weekday the 2000 default produced.
- (void)seedRealTimeClock {
    if (!_nds) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDate *when = [NSDate date];
    if ([defaults boolForKey:@"ndsClockManual"]) {
        double epoch = [defaults doubleForKey:@"ndsManualClockEpoch"];
        if (epoch > 0) {
            when = [NSDate dateWithTimeIntervalSince1970:epoch];
        }
    }
    // The DS RTC stores local wall-clock time, so extract components in the
    // device's current calendar/time zone.
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *c = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                                           NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond)
                                 fromDate:when];
    _nds->RTC.SetDateTime((int)c.year, (int)c.month, (int)c.day,
                          (int)c.hour, (int)c.minute, (int)c.second);
}

+ (int)autoResolvedNDSLanguageIndex {
    return resolveNDSLanguageFromLocale();
}

- (void)setNDSLanguage:(int)language {
    if (!_nds) return;

    auto lang = static_cast<melonDS::Firmware::Language>(language);
    auto& userData = _nds->GetFirmware().GetUserData();

    // Update BOTH copies of UserData in firmware
    for (int i = 0; i < 2; i++) {
        userData[i].Settings &= ~0x07;  // Clear language bits 0-2
        userData[i].Settings |= static_cast<melonDS::u16>(lang);
        userData[i].UpdateChecksum();
    }
}

- (void)setSavePath:(NSString *)path {
    if (!_nds || !_romLoaded) return;
    _savePath = [path UTF8String];
    melonDS::Platform::SetNDSSavePath(_savePath);

    // Load existing save file if present
    NSData *saveData = [NSData dataWithContentsOfFile:path];
    if (saveData && saveData.length > 0) {
        melonDS::NDSCart::CartCommon* cart = _nds->GetNDSCart();
        if (cart) {
            melonDS::u8* saveMem = _nds->GetNDSSave();
            melonDS::u32 saveLen = _nds->GetNDSSaveLength();
            if (saveMem && saveLen > 0 && saveData.length <= saveLen) {
                memcpy(saveMem, saveData.bytes, saveData.length);
            }
        }
    }
}

- (void)setGBPalette:(const uint32_t *)colors {
    // NDS has no DMG palette; nothing to do.
}

- (BOOL)isDMGPaletteApplicable {
    return NO;
}

- (void)flushSaveData {
    if (!_nds || !_romLoaded) return;
    // melonDS writes save changes through Platform::WriteNDSSave as the game
    // saves (each call fopen/fwrite/fclose, so OS-flushed), but the cart flush
    // is deferred a few frames. Force the current save RAM to disk now (we are
    // paused). GetNDSSave is exactly the raw buffer setSavePath reads back, so
    // writing it round-trips cleanly; atomically:YES makes the write safe.
    const melonDS::u8 *saveMem = _nds->GetNDSSave();
    melonDS::u32 saveLen = _nds->GetNDSSaveLength();
    if (!_savePath.empty() && saveMem && saveLen > 0) {
        NSData *data = [NSData dataWithBytes:saveMem length:saveLen];
        [data writeToFile:[NSString stringWithUTF8String:_savePath.c_str()] atomically:YES];
    }
    // Same forced flush for the slot-2 GBA cart's save RAM, when one is
    // mounted (its writes go through Platform::WriteGBASave in play, with the
    // same deferred-flush caveat).
    if (!_gbaSavePath.empty()) {
        const melonDS::u8 *gbaMem = _nds->GetGBASave();
        melonDS::u32 gbaLen = _nds->GetGBASaveLength();
        if (gbaMem && gbaLen > 0) {
            NSData *gbaData = [NSData dataWithBytes:gbaMem length:gbaLen];
            [gbaData writeToFile:[NSString stringWithUTF8String:_gbaSavePath.c_str()] atomically:YES];
        }
    }
}

// MARK: - Emulation

- (void)runFrame {
    if (!_nds || !_romLoaded) return;

    // Cost of emulation ALONE, which is what decides whether a snapshot fits in
    // the remaining frame budget. Averaged over a second so one slow frame does
    // not disable rewind and one fast one does not re-enable it.
    double frameStart = MelonNowMs();

    _nds->RunFrame();

    _rwLastFrameMs = MelonNowMs() - frameStart;
    _rwFrameMsAccum += _rwLastFrameMs;
    if (++_rwFrameMsCount >= 60) {
        _rwFrameMsAverage = _rwFrameMsAccum / (double)_rwFrameMsCount;
        _rwFrameMsAccum = 0;
        _rwFrameMsCount = 0;
    }

    // Copy framebuffers into our combined buffer
    int frontBuffer = _nds->GPU.FrontBuffer;
    const melonDS::u32* topScreen = _nds->GPU.Framebuffer[frontBuffer][0].get();
    const melonDS::u32* botScreen = _nds->GPU.Framebuffer[frontBuffer][1].get();

    if (topScreen) {
        memcpy(_framebuffer, topScreen, 256 * 192 * sizeof(uint32_t));
    }
    if (botScreen) {
        memcpy(_framebuffer + (256 * 192), botScreen, 256 * 192 * sizeof(uint32_t));
    }
}

- (void)setKeys:(uint32_t)keys {
    if (!_nds) return;
    // melonDS uses active-low key mask: bit=1 means released, bit=0 means pressed
    // Our protocol uses active-high: bit=1 means pressed
    // Also: melonDS SetKeyMask only handles bits 0-9 (GBA-style buttons)
    // X and Y are handled separately via bits 10-11 in the keyinput ext register
    _keyMask = ~keys & 0xFFF;
    _nds->SetKeyMask(_keyMask);
}

// MARK: - Video

- (const uint32_t *)frameBuffer {
    return _framebuffer;
}

- (CGImageRef)createFrameImage {
    if (!_romLoaded) return NULL;

    // Top screen only — used for save previews and library thumbnails
    NSInteger width = NDSScreenWidth;
    NSInteger height = NDSScreenHeight;
    NSInteger bytesPerRow = width * sizeof(uint32_t);

    // melonDS outputs XRGB8888 (byte order: B, G, R, X on little-endian)
    // Use kCGBitmapByteOrder32Little + AlphaNoneSkipFirst to read as XRGB
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        _framebuffer,
        width,
        height,
        8,
        bytesPerRow,
        colorSpace,
        kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst
    );

    CGImageRef image = NULL;
    if (context) {
        image = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
    }
    CGColorSpaceRelease(colorSpace);
    return image;
}

- (CGImageRef)createDualScreenFrameImage {
    if (!_romLoaded) return NULL;

    // Both screens stacked: 256x384
    NSInteger width = NDSScreenWidth;
    NSInteger height = NDSScreenHeight * 2;
    NSInteger bytesPerRow = width * sizeof(uint32_t);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        _framebuffer,
        width,
        height,
        8,
        bytesPerRow,
        colorSpace,
        kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst
    );

    CGImageRef image = NULL;
    if (context) {
        image = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
    }
    CGColorSpaceRelease(colorSpace);
    return image;
}

// MARK: - Save States

- (BOOL)saveStateToPath:(NSString *)path {
    if (!_nds || !_romLoaded) return NO;

    // Create a Savestate in save mode
    melonDS::Savestate state;
    // state defaults to Saving=true
    if (!_nds->DoSavestate(&state)) return NO;
    state.Finish();

    if (state.Error) return NO;

    // Write to file
    NSData *data = [NSData dataWithBytes:state.Buffer()
                                  length:state.Length()];
    return [data writeToFile:path atomically:YES];
}

- (BOOL)loadStateFromPath:(NSString *)path {
    if (!_nds || !_romLoaded) return NO;
    // Loading a state moves the console to a DIFFERENT timeline, so every
    // snapshot we hold now describes a past that no longer leads here.
    // Rewinding across that boundary would drop the player into the pre-load
    // game, which is not a shorter rewind but a wrong one. The session zeroes
    // its own frame counter, and that is not enough on its own: it gates how far
    // back you may ask, not which timeline the answer comes from.
    [self invalidateRewindBuffer];

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length == 0) return NO;

    // Create a Savestate in load mode from existing buffer
    // We need a mutable copy since melonDS takes void* (not const)
    void *buf = malloc(data.length);
    if (!buf) return NO;
    memcpy(buf, data.bytes, data.length);

    melonDS::Savestate state(buf, (melonDS::u32)data.length, false);
    bool success = _nds->DoSavestate(&state);
    free(buf);

    return success ? YES : NO;
}

// MARK: - Speed

- (void)setSpeedMultiplier:(int)multiplier {
    // Speed control is handled by the frame pacing in EmulatorMetalView
    // melonDS doesn't have a built-in speed multiplier API
}

// MARK: - Memory (RetroAchievements)

- (NSInteger)readMemoryAtAddress:(uint32_t)address into:(uint8_t *)buffer length:(NSInteger)length {
    // The RA layer has already translated the flat RA address to the real bus
    // address (rc_console_memory_regions, NDS): main RAM at 0x02000000 (the
    // DS's 4MB, mirrored via MainRAMMask) and the ARM9 DTCM at rcheevos'
    // 0x0E000000 PSEUDO-address — the DTCM is CPU-relocatable, so RA pins it
    // there and we serve the physical 16KB buffer directly. Plain array reads
    // on the emulation thread (rc_client_do_frame runs between frames, the
    // same thread as runFrame), read-only, no bus side effects.
    if (!_nds || !_romLoaded || !buffer || length <= 0) return 0;

    if (address >= 0x02000000u && address < 0x02400000u) {   // the RA region is the DS's 4MB
        const melonDS::u8 *ram = _nds->MainRAM;
        if (!ram) return 0;
        for (NSInteger i = 0; i < length; i++) {
            buffer[i] = ram[(address - 0x02000000u + (uint32_t)i) & _nds->MainRAMMask];
        }
        return length;
    }

    if (address >= 0x0E000000u && address < 0x0E000000u + melonDS::DTCMPhysicalSize) {
        const melonDS::u8 *dtcm = _nds->ARM9.DTCM;
        if (!dtcm) return 0;
        uint32_t offset = address - 0x0E000000u;
        NSInteger available = (NSInteger)(melonDS::DTCMPhysicalSize - offset);
        NSInteger toRead = length < available ? length : available;
        memcpy(buffer, dtcm + offset, (size_t)toRead);
        return toRead;
    }

    return 0;
}

// MARK: - Audio

- (unsigned int)audioSampleRate {
    if (!_nds) return 0;
    // melonDS SPU outputs at the rate configured in NDSArgs (default 48000)
    return 48000;
}

- (NSInteger)readAudioSamples:(int16_t *)buffer count:(NSInteger)count {
    if (!_nds || !_romLoaded) return 0;
    return (NSInteger)_nds->SPU.ReadOutput(buffer, (int)count);
}

- (unsigned int)consumePendingAudioRate {
    // NDS's SPU rate is fixed at 48,000 Hz for the life of a session, so no
    // runtime rate changes are possible. Always return 0.
    return 0;
}

// MARK: - Rewind
//
// mGBA appends a full state every frame and diffs it, which is affordable for a
// GBA because its states are small. A DS state is 19.0 MB (measured, stable):
// NDS::DoSavestate writes main RAM at MainRAMMaxSize, 16 MB, the DSi figure,
// whatever the console actually is. Per-frame appends would move about a
// gigabyte a second, which is why NDS had no rewind.
//
// What makes it possible here is our own UI rather than a trick: the rewind
// button is a single discrete jump from the pause menu, never a scrub, so no
// intermediate frame is ever shown and per-frame granularity is invisible.
//
// Measured on an iPhone 14 Pro, SoulSilver, in play:
//   serialize 4.3 ms, diff 1.0 ms, delta 0.33-0.53 MB of a 19.0 MB state
// and with Low Power Mode on, as a stand-in for older silicon:
//   serialize 8.4 ms, diff 1.9 ms, same deltas
//
// The aggregate is trivial, 1% of a core. The hazard is that it lands inside ONE
// frame of a 16.6 ms budget. Hence the two decisions below.
//
// SPACING IS FIVE SECONDS, not one. After 30 seconds of play the button only
// ever asks for exactly 5 (free) or exactly 30 (Pro), both multiples of five, so
// five-second spacing is EXACT on the only two targets that matter while
// producing five times fewer hitches and six snapshots instead of thirty. The
// approximation it introduces exists only in the first 30 seconds of a session.
//
// THE DIFF RUNS OFF-THREAD. Only the serialize has to be inline, because it
// reads live emulator state; comparing two buffers we own does not.
//
// Memory: two 19 MB buffers, one holding the current state and one receiving
// each serialize, because you cannot diff against a state you have already
// overwritten. Plus an undo log of the OLD bytes of changed blocks, roughly
// 0.5 MB per snapshot. Allocated lazily on the first snapshot, so a session that
// never reaches five seconds never pays.

static const size_t kRewindBlock = 4096;
static const NSInteger kRewindSecondsPerSnapshot = 5;
static const size_t kRewindBufferCapacity = 24 * 1024 * 1024;   // states measure 19.0 MB
// Snapshot scheduling, tuned from device measurements rather than guessed.
//
// The first version was a yes/no guard at 9 ms and it was wrong in a way the
// arithmetic hid. In Low Power Mode emulation alone averages 11.5 ms, so the
// guard fired on every single snapshot and rewind silently never recorded
// anything. The guard was factually correct — 11.5 + 8.4 does not fit in
// 16.6 ms — but a feature that quietly does not exist is worse than the hitch it
// was avoiding, and "depth degrades" only sounds acceptable until the depth is
// zero.
//
// So the snapshot is SCHEDULED rather than gated. When one falls due it waits
// for a frame with room for it, and takes it anyway if no such frame arrives
// within a second. Normal devices snapshot immediately and never notice; a
// throttled one snapshots at the cheapest moment available and, failing that,
// spends a single late frame roughly every six seconds. The feature works
// everywhere, and only the exact moment of the snapshot moves.

/// Emulation cost that still leaves room for an 8.4 ms serialize inside a
/// 16.6 ms frame. Below this, take the snapshot now.
static const double kRewindFrameHeadroomMs = 8.0;
/// Take it regardless after this long waiting. A snapshot one second late is
/// worth far more than no snapshot at all.
static const NSInteger kRewindPendingDeadlineFrames = 60;
/// The one case still worth refusing outright: emulation ALONE is already at the
/// frame budget, so the game is dropping frames on its own and a serialize would
/// only deepen it. Here, and only here, depth is the right thing to sacrifice.
static const double kRewindSkipAboveFrameMs = 15.0;

/// One snapshot's worth of undo information: the PREVIOUS contents of every
/// block that changed. Walking these backwards turns the current state into an
/// older one without keeping older states whole.
typedef struct {
    uint32_t *blocks;   // block indices, `count` of them
    uint8_t *data;      // count * kRewindBlock bytes of the OLD contents
    uint32_t count;
} RewindUndo;

static double MelonNowMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

- (void)initRewind:(NSInteger)seconds {
    [self teardownRewind];
    if (seconds <= 0) return;
    // Buffers are NOT allocated here. A session that never reaches the first
    // snapshot should cost a DS player nothing at all.
    _rwDepth = MAX(1, seconds / kRewindSecondsPerSnapshot);
    _rwFrameCounter = 0;
    _rwStored = 0;
    _rwNewest = -1;
    // NOT marked pending here, deliberately, unlike the invalidation path below.
    // The first snapshot is what allocates 48 MB of buffers and serializes 19 MB,
    // and doing that on frame one would put both on the busiest frame of the
    // session and charge them to a player who quits after five seconds. The
    // deferral above is a design decision, not an oversight: a session that never
    // reaches the first snapshot costs a DS player nothing at all. Invalidation
    // is a different case and can afford to be eager, because it only ever fires
    // when those buffers already exist.
}

- (BOOL)ensureRewindAllocated {
    if (_rwCurrent) return YES;
    _rwCurrent = (uint8_t *)malloc(kRewindBufferCapacity);
    _rwScratch = (uint8_t *)malloc(kRewindBufferCapacity);
    _rwUndo = calloc((size_t)_rwDepth, sizeof(RewindUndo));
    if (!_rwCurrent || !_rwScratch || !_rwUndo) {
        [self teardownRewind];
        NSLog(@"MelonDSBridge: rewind allocation failed, feature stays off for this session");
        return NO;
    }
    _rwDiffQueue = dispatch_queue_create("retropal.nds.rewind", DISPATCH_QUEUE_SERIAL);
    return YES;
}

- (void)teardownRewind {
    if (_rwDiffQueue) {
        // Never free a buffer a diff is still reading.
        dispatch_sync(_rwDiffQueue, ^{});
        _rwDiffQueue = nil;
    }
    if (_rwUndo) {
        RewindUndo *ring = (RewindUndo *)_rwUndo;
        for (NSInteger i = 0; i < _rwDepth; i++) {
            free(ring[i].blocks);
            free(ring[i].data);
        }
        free(_rwUndo);
        _rwUndo = NULL;
    }
    free(_rwCurrent); _rwCurrent = NULL;
    free(_rwScratch); _rwScratch = NULL;
    _rwStateLength = 0;
    _rwStored = 0;
    _rwNewest = -1;
    _rwFrameCounter = 0;
    _rwDiffInFlight = NO;
    _rwFrameMsAccum = 0;
    _rwFrameMsCount = 0;
    _rwFrameMsAverage = 0;
    _rwLastFrameMs = 0;
    _rwPending = NO;
    _rwPendingFrames = 0;
}

/// Drop every snapshot without giving up the allocation.
///
/// Also removes a second, quieter problem: the first diff after a timeline jump
/// would compare two unrelated states, find nearly every block changed, and
/// allocate an undo entry close to the size of the state itself. After this it
/// is simply a fresh first snapshot with nothing to diff against.
- (void)invalidateRewindBuffer {
    if (!_rwCurrent) return;
    if (_rwDiffQueue) dispatch_sync(_rwDiffQueue, ^{});   // never race a running diff
    RewindUndo *ring = (RewindUndo *)_rwUndo;
    if (ring) {
        for (NSInteger i = 0; i < _rwDepth; i++) {
            free(ring[i].blocks); ring[i].blocks = NULL;
            free(ring[i].data); ring[i].data = NULL;
            ring[i].count = 0;
        }
    }
    _rwStateLength = 0;
    _rwStored = 0;
    _rwNewest = -1;
    // The jump we just took IS a rewind target: the state at the load or the
    // reset point. Taking it now, and restarting the interval from here,
    // stops the five seconds after a jump from being a hole where the rewind
    // button does nothing at all. It cannot reach back across the jump: this
    // snapshot is the first of the new timeline, not the last of the old one.
    _rwFrameCounter = 0;
    _rwPending = YES;
    _rwPendingFrames = 0;
}

- (void)rewindAppend {
    if (_rwDepth <= 0 || !_nds || !_romLoaded) return;

    // A snapshot falls due every five seconds, but does not have to be taken on
    // that exact frame.
    if (++_rwFrameCounter >= kRewindSecondsPerSnapshot * 60) {
        _rwFrameCounter = 0;
        _rwPending = YES;
        _rwPendingFrames = 0;
    }
    if (!_rwPending) return;
    _rwPendingFrames++;

    // Already busy with the previous diff: leave it pending, do not queue work.
    if (_rwDiffInFlight) return;

    // The game is already missing frames without our help. This is the only case
    // where dropping the snapshot is the right answer.
    if (_rwFrameMsAverage > kRewindSkipAboveFrameMs) {
#if DEBUG
        NSLog(@"[REWIND] skipped, emulation alone averaging %.1f ms/frame", _rwFrameMsAverage);
#endif
        _rwPending = NO;
        return;
    }

    // Wait for a frame with room, but not forever.
    BOOL roomNow = (_rwLastFrameMs <= kRewindFrameHeadroomMs);
    BOOL deadline = (_rwPendingFrames >= kRewindPendingDeadlineFrames);
    if (!roomNow && !deadline) return;
    _rwPending = NO;
#if DEBUG
    if (deadline && !roomNow) {
        NSLog(@"[REWIND] no spare frame in %ld, taking it anyway (last frame %.1f ms)",
              (long)_rwPendingFrames, _rwLastFrameMs);
    }
#endif

    if (![self ensureRewindAllocated]) { _rwDepth = 0; return; }

    double t0 = MelonNowMs();
    melonDS::Savestate state(_rwScratch, (melonDS::u32)kRewindBufferCapacity, true);
    if (!_nds->DoSavestate(&state) || state.Error) return;
    state.Finish();
    size_t length = (size_t)state.Length();
    double serializeMs = MelonNowMs() - t0;

    // The very first snapshot has nothing to diff against: it just becomes the
    // current state.
    if (_rwStateLength == 0 || _rwStateLength != length) {
        memcpy(_rwCurrent, _rwScratch, length);
        _rwStateLength = length;
        _rwStored = 0;
        _rwNewest = -1;
#if DEBUG
        NSLog(@"[REWIND] first snapshot %.1f MB | serialize %.1f ms | frame avg %.1f ms",
              length / 1048576.0, serializeMs, _rwFrameMsAverage);
#endif
        return;
    }

    _rwDiffInFlight = YES;
    dispatch_async(_rwDiffQueue, ^{
        double d0 = MelonNowMs();
        size_t blocks = (self->_rwStateLength + kRewindBlock - 1) / kRewindBlock;

        // Pass one counts, pass two records. Two passes over 19 MB still costs
        // less than allocating for the worst case every time.
        uint32_t changed = 0;
        for (size_t b = 0; b < blocks; b++) {
            size_t off = b * kRewindBlock;
            size_t len = MIN(kRewindBlock, self->_rwStateLength - off);
            if (memcmp(self->_rwCurrent + off, self->_rwScratch + off, len) != 0) changed++;
        }

        RewindUndo *ring = (RewindUndo *)self->_rwUndo;
        NSInteger slot = (self->_rwNewest + 1) % self->_rwDepth;
        RewindUndo *entry = &ring[slot];
        free(entry->blocks); free(entry->data);
        entry->blocks = changed ? (uint32_t *)malloc(changed * sizeof(uint32_t)) : NULL;
        entry->data = changed ? (uint8_t *)malloc((size_t)changed * kRewindBlock) : NULL;
        entry->count = 0;

        if (changed && (!entry->blocks || !entry->data)) {
            free(entry->blocks); entry->blocks = NULL;
            free(entry->data); entry->data = NULL;
            self->_rwDiffInFlight = NO;
            return;   // this snapshot is simply lost; depth shrinks, nothing breaks
        }

        for (size_t b = 0; b < blocks; b++) {
            size_t off = b * kRewindBlock;
            size_t len = MIN(kRewindBlock, self->_rwStateLength - off);
            if (memcmp(self->_rwCurrent + off, self->_rwScratch + off, len) == 0) continue;
            entry->blocks[entry->count] = (uint32_t)b;
            memcpy(entry->data + (size_t)entry->count * kRewindBlock, self->_rwCurrent + off, len);
            entry->count++;
            memcpy(self->_rwCurrent + off, self->_rwScratch + off, len);   // current catches up
        }

        self->_rwNewest = slot;
        if (self->_rwStored < self->_rwDepth) self->_rwStored++;
        double diffMs = MelonNowMs() - d0;
#if DEBUG
        NSLog(@"[REWIND] snapshot %.1f MB | serialize %.1f ms | delta %u blocks = %.2f MB | diff %.1f ms (off-thread) | frame avg %.1f ms | depth %ld/%ld",
              length / 1048576.0, serializeMs, entry->count,
              (entry->count * kRewindBlock) / 1048576.0, diffMs,
              self->_rwFrameMsAverage, (long)self->_rwStored, (long)self->_rwDepth);
#endif
        self->_rwDiffInFlight = NO;
    });
}

/// Rewind by `count` frames, or as far back as the ring actually reaches.
///
/// `_rwStored == 0` is a REWIND, not a refusal. The ring holds undo deltas off
/// `_rwCurrent`, and `_rwCurrent` is itself a complete state: the moment of the
/// most recent snapshot. So with no deltas stored there is still exactly one
/// place to go, the last snapshot, and applying zero undos before the load is
/// what goes there. That case is the whole first interval of a session and the
/// whole first interval after a state load or a reset, which used to be a
/// window where the rewind button did nothing at all and said nothing about it.
- (BOOL)rewindFrames:(NSInteger)count {
    if (!_rwCurrent || _rwStateLength == 0) return NO;
    if (!_nds || !_romLoaded) return NO;

    // Let any in-flight diff finish first: it owns _rwCurrent and the ring.
    if (_rwDiffQueue) dispatch_sync(_rwDiffQueue, ^{});

    // Frames to snapshots, rounded to the NEAREST rather than down, so a request
    // for 30 s lands on 30 and not 25. Clamped to what we actually hold, which
    // may be less than asked for if the late guard skipped snapshots.
    NSInteger framesPerSnapshot = kRewindSecondsPerSnapshot * 60;
    NSInteger steps = (count + framesPerSnapshot / 2) / framesPerSnapshot;
    // Clamp DOWN to what is stored, and the order matters: `MAX(1, MIN(steps,
    // _rwStored))` would return 1 when nothing is stored, and the loop below
    // would then read `ring[_rwNewest]` with `_rwNewest` still -1. At least one
    // step when there is anything to step through, and exactly zero when the
    // anchor is all we have.
    steps = MIN(MAX((NSInteger)1, steps), _rwStored);

    RewindUndo *ring = (RewindUndo *)_rwUndo;
    for (NSInteger i = 0; i < steps; i++) {
        RewindUndo *entry = &ring[_rwNewest];
        for (uint32_t k = 0; k < entry->count; k++) {
            size_t off = (size_t)entry->blocks[k] * kRewindBlock;
            size_t len = MIN(kRewindBlock, _rwStateLength - off);
            memcpy(_rwCurrent + off, entry->data + (size_t)k * kRewindBlock, len);
        }
        free(entry->blocks); entry->blocks = NULL;
        free(entry->data); entry->data = NULL;
        entry->count = 0;
        _rwNewest = (_rwNewest - 1 + _rwDepth) % _rwDepth;
        _rwStored--;
    }

    // Load from a COPY: melonDS's loading Savestate takes a non-const buffer, and
    // _rwCurrent has to stay intact as the anchor for the next snapshot.
    void *copy = malloc(_rwStateLength);
    if (!copy) return NO;
    memcpy(copy, _rwCurrent, _rwStateLength);
    melonDS::Savestate loader(copy, (melonDS::u32)_rwStateLength, false);
    bool ok = _nds->DoSavestate(&loader) && !loader.Error;
    free(copy);

#if DEBUG
    NSLog(@"[REWIND] restored %ld snapshots (%ld s), %ld left, ok=%d",
          (long)steps, (long)(steps * kRewindSecondsPerSnapshot), (long)_rwStored, ok);
#endif
    // The buffer no longer describes the running console if the load failed.
    if (!ok) { _rwStored = 0; _rwStateLength = 0; }
    return ok ? YES : NO;
}


// MARK: - Lifecycle

- (void)shutdown {
    [self teardownRewind];

    if (_nds) {
        if (_romLoaded) {
            _nds->Stop(melonDS::Platform::StopReason::External);
        }
        _nds.reset();
    }
    _romLoaded = NO;
    _savePath.clear();
    _romName.clear();
    melonDS::Platform::SetNDSSavePath("");
    // Release the slot-2 save path but keep the configured request
    // (_gbaSlotROMPath/_gbaSlotSavePath): loadROMAtPath: shuts down first,
    // and must still find the configuration when it re-mounts the cart.
    _gbaSavePath.clear();
    melonDS::Platform::SetGBASavePath("");
}

// MARK: - Cheat Codes

- (BOOL)addCheatCode:(NSString *)code type:(int)type {
    if (!_nds || !_romLoaded) return NO;

    // Parse Action Replay DS codes
    // Format: XXXXXXXX YYYYYYYY (8-char pairs separated by space or newline)
    NSString *cleaned = [[code stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]]
                         uppercaseString];

    // Split into lines
    NSArray<NSString *> *lines = [cleaned componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet newlineCharacterSet]];

    melonDS::ARCode arCode;
    arCode.Parent = nullptr;
    arCode.Name = "Cheat";
    arCode.Enabled = true;

    // Same rule as the GBA bridge, and for the same reason: a line this bridge
    // cannot read means the WHOLE code is refused, never a partial one.
    //
    // Two silent-garbage paths closed here. A line with fewer than two blocks
    // used to be skipped, so a four-line code with one malformed line installed
    // as a three-line code. And sscanf's result was never checked, so a line of
    // non-hex parsed as the pair 0x00000000 / 0x00000000 and was pushed into
    // the code as if it were real. Both failed with no error of any kind.
    // Decided 2026-08-11: reject outright.
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0) continue;

        // Parse "XXXXXXXX YYYYYYYY" format
        NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@" "];
        unsigned int cmd = 0, val = 0;
        if (parts.count < 2 ||
            sscanf([parts[0] UTF8String], "%X", &cmd) != 1 ||
            sscanf([parts[1] UTF8String], "%X", &val) != 1) {
            return NO;
        }
        arCode.Code.push_back(cmd);
        arCode.Code.push_back(val);
    }

    if (arCode.Code.empty()) return NO;

    _nds->AREngine.Cheats.push_back(std::move(arCode));
    return YES;
}

- (void)clearCheats {
    if (!_nds) return;
    _nds->AREngine.Cheats.clear();
}

// MARK: - Touch Screen

- (void)touchScreenAtX:(int)x y:(int)y {
    if (!_nds) return;
    // Clamp to valid NDS touch screen range
    x = MAX(0, MIN(x, 255));
    y = MAX(0, MIN(y, 191));
    _nds->TouchScreen((melonDS::u16)x, (melonDS::u16)y);
}

- (void)touchScreenRelease {
    if (!_nds) return;
    _nds->ReleaseScreen();
}

// MARK: - Microphone

- (void)setMicBlowActive:(BOOL)active {
    MelonDSMic_SetBlowActive(active);
}

@end
