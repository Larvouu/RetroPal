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

    _romLoaded = YES;
    NSLog(@"MelonDSBridge: ROM loaded successfully: %@", [path lastPathComponent]);
    return YES;
}

- (void)reset {
    if (!_nds || !_romLoaded) return;

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

- (void)flushSaveData {
    if (!_nds || !_romLoaded || _savePath.empty()) return;
    // melonDS writes save changes through Platform::WriteNDSSave as the game
    // saves (each call fopen/fwrite/fclose, so OS-flushed), but the cart flush
    // is deferred a few frames. Force the current save RAM to disk now (we are
    // paused). GetNDSSave is exactly the raw buffer setSavePath reads back, so
    // writing it round-trips cleanly; atomically:YES makes the write safe.
    const melonDS::u8 *saveMem = _nds->GetNDSSave();
    melonDS::u32 saveLen = _nds->GetNDSSaveLength();
    if (!saveMem || saveLen == 0) return;
    NSData *data = [NSData dataWithBytes:saveMem length:saveLen];
    [data writeToFile:[NSString stringWithUTF8String:_savePath.c_str()] atomically:YES];
}

// MARK: - Emulation

- (void)runFrame {
    if (!_nds || !_romLoaded) return;

    _nds->RunFrame();

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

- (void)initRewind:(NSInteger)seconds {
    // Rewind for NDS is handled at the session level via save state snapshots
    // (NDS states are too large for per-frame storage like mGBA's built-in rewind)
}

- (void)rewindAppend {
    // No-op: rewind managed at session level for NDS
}

- (BOOL)rewindFrames:(NSInteger)count {
    // No-op: rewind managed at session level for NDS
    return NO;
}

// MARK: - Lifecycle

- (void)shutdown {
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

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0) continue;

        // Parse "XXXXXXXX YYYYYYYY" format
        NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@" "];
        if (parts.count >= 2) {
            unsigned int cmd = 0, val = 0;
            sscanf([parts[0] UTF8String], "%X", &cmd);
            sscanf([parts[1] UTF8String], "%X", &val);
            arCode.Code.push_back(cmd);
            arCode.Code.push_back(val);
        }
    }

    if (arCode.Code.empty()) return NO;

    _nds->AREngine.Cheats.push_back(std::move(arCode));
    return YES;
}

- (void)clearCheats {
    if (!_nds) return;
    _nds->AREngine.Cheats.clear();
}

- (void)setCheatsEnabled:(BOOL)enabled {
    if (!_nds) return;
    for (auto& cheat : _nds->AREngine.Cheats) {
        cheat.Enabled = enabled;
    }
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
