//
//  MGBABridge.mm
//  EmulateurGBA
//
//  ObjC++ implementation bridging mGBA to Swift.
//

#import "MGBABridge.h"

// flags.h must be included first — it defines ENABLE_VFS, M_CORE_GBA, etc.
// that gate declarations in the other mGBA headers.
#include <mgba/flags.h>

#include <mgba/core/core.h>
#include <mgba/core/config.h>
#include <mgba/core/serialize.h>
#include <mgba/gba/core.h>
#include <mgba/gb/core.h>
#include <mgba/gba/interface.h>
#include <mgba/internal/gb/video.h>
#include <mgba-util/vfs.h>
#include <mgba-util/image.h>
#include <mgba/core/rewind.h>
#include <mgba/core/cheats.h>
#include <mgba/core/interface.h>
#include <mgba-util/audio-buffer.h>
// Internal headers for the explicit battery-save flush (flushSaveData):
// GBASavedataClean / GBSramClean and the GBA / GB board structs.
#include <mgba/internal/gba/gba.h>
#include <mgba/internal/gba/savedata.h>
#include <mgba/internal/gb/gb.h>

#include <fcntl.h>
#include <unistd.h>

const NSInteger GBAScreenWidth = GBA_VIDEO_HORIZONTAL_PIXELS;   // 240
const NSInteger GBAScreenHeight = GBA_VIDEO_VERTICAL_PIXELS;    // 160
const NSInteger GBScreenWidth = GB_VIDEO_HORIZONTAL_PIXELS;     // 160
const NSInteger GBScreenHeight = GB_VIDEO_VERTICAL_PIXELS;      // 144

// Wrapper struct so the C `mAVStream` callback can recover the owning bridge.
// `stream` must be the first field so a `struct mAVStream*` pointer received
// in the callback is reinterpretable as a `MGBAStreamContext*`. The `bridge`
// slot holds an unretained pointer back to the ObjC instance; lifetime is
// tied to the bridge itself, which calls `setAVStream(_core, NULL)` before
// `_core->deinit` to guarantee no late callbacks.
typedef struct MGBAStreamContext {
    struct mAVStream stream;
    void *bridge;
} MGBAStreamContext;

// Forward declaration. Definition lives below the implementation block so it
// can call into a bridge method that updates the pending-rate slot.
static void _mgbaAudioRateChangedTrampoline(struct mAVStream *stream, unsigned rate);

@implementation MGBABridge {
    struct mCore *_core;
    mColor *_videoBuffer;
    BOOL _romLoaded;
    struct mCoreRewindContext _rewindContext;
    BOOL _rewindInitialized;
    BOOL _cheatsInitialized;
    MGBAStreamContext _streamCtx;
    BOOL _streamInstalled;
    unsigned int _pendingAudioRate;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _core = NULL;
        _videoBuffer = NULL;
        _romLoaded = NO;
    }
    return self;
}

- (void)dealloc {
    [self shutdown];
}

- (BOOL)isROMLoaded {
    return _romLoaded;
}

- (NSInteger)screenWidth {
    if (!_core) return GBA_VIDEO_HORIZONTAL_PIXELS;
    unsigned w, h;
    _core->currentVideoSize(_core, &w, &h);
    return (NSInteger)w;
}

- (NSInteger)screenHeight {
    if (!_core) return GBA_VIDEO_VERTICAL_PIXELS;
    unsigned w, h;
    _core->currentVideoSize(_core, &w, &h);
    return (NSInteger)h;
}

- (NSInteger)bufferStride {
    if (!_core) return GBA_VIDEO_HORIZONTAL_PIXELS;
    unsigned w, h;
    _core->baseVideoSize(_core, &w, &h);
    return (NSInteger)w;
}

- (BOOL)loadROMAtPath:(NSString *)path {
    [self shutdown];

    // Auto-detect core type (GBA, GB, or GBC) from ROM file
    _core = mCoreFind([path UTF8String]);
    if (!_core) {
        NSLog(@"MGBABridge: Failed to detect core for: %@", path);
        return NO;
    }

    // Initialize core
    if (!_core->init(_core)) {
        NSLog(@"MGBABridge: Failed to init core");
        _core = NULL;
        return NO;
    }

    // Initialize config tables (must happen before any config access)
    mCoreInitConfig(_core, NULL);

    // Configure for iOS operation
    struct mCoreOptions opts = {};
    opts.skipBios = true;
    opts.useBios = false;
    opts.volume = 0x100; // Full volume
    opts.sampleRate = 32768;
    opts.audioBuffers = 1024;
    mCoreConfigLoadDefaults(&_core->config, &opts);

    // Disable SGB borders for GB games (renders at native 160x144 instead of 256x224)
    mCoreConfigSetValue(&_core->config, "sgb.borders", "0");

    // Allocate video buffer using base size (large enough for any mode)
    unsigned videoWidth, videoHeight;
    _core->baseVideoSize(_core, &videoWidth, &videoHeight);
    _videoBuffer = (mColor *)calloc(videoWidth * videoHeight, sizeof(mColor));
    if (!_videoBuffer) {
        NSLog(@"MGBABridge: Failed to allocate video buffer");
        _core->deinit(_core);
        _core = NULL;
        return NO;
    }
    _core->setVideoBuffer(_core, _videoBuffer, videoWidth);

    // Open ROM via VFile
    struct VFile *romVF = VFileOpen([path UTF8String], O_RDONLY);
    if (!romVF) {
        NSLog(@"MGBABridge: Failed to open ROM file: %@", path);
        [self shutdown];
        return NO;
    }

    // Load ROM
    if (!_core->loadROM(_core, romVF)) {
        NSLog(@"MGBABridge: Failed to load ROM");
        // Note: loadROM takes ownership of VFile on success.
        // On failure, we should close it.
        romVF->close(romVF);
        [self shutdown];
        return NO;
    }

    // Apply config to core (sets audio buffer size, maps options)
    mCoreLoadConfig(_core);

    // Install an mAVStream so we hear about post-reset SOUNDBIAS rewrites that
    // change the audio sample rate. mGBA's gba/audio.c fires this callback from
    // GBAAudioReset() and from GBAAudioWriteSOUNDBIAS(); we use it to detect
    // the rare mid-run rate change and let EmulatorSession rebuild its audio
    // engine on the next runFrame. GB/GBC's rate is constant (131,072 Hz) so
    // the callback effectively only matters for GBA, but installation is the
    // same code path for both.
    memset(&_streamCtx, 0, sizeof(_streamCtx));
    _streamCtx.stream.audioRateChanged = _mgbaAudioRateChangedTrampoline;
    _streamCtx.bridge = (__bridge void *)self;
    _core->setAVStream(_core, &_streamCtx.stream);
    _streamInstalled = YES;
    _pendingAudioRate = 0;

    _romLoaded = YES;
    NSLog(@"MGBABridge: ROM loaded successfully: %@", [path lastPathComponent]);
    return YES;
}

- (void)setSavePath:(NSString *)path {
    if (!_core || !_romLoaded) return;

    struct VFile *saveVf = VFileOpen([path UTF8String], O_RDWR | O_CREAT);
    if (saveVf) {
        _core->loadSave(_core, saveVf);
        // Note: VFile ownership is taken by the core, don't close it
    }
}

- (void)reset {
    if (_core && _romLoaded) {
        _core->reset(_core);
        // No explicit setAudioBufferSize here: the underlying mAudioBuffer is
        // allocated at AUDIO_BUFFER_SAMPLES (0x4000 = 16,384 stereo frames) by
        // GBAudioInit and is not resized by setAudioBufferSize — that call only
        // updates a threshold used by the (unregistered) postAudioBuffer path
        // and by mCoreSync's audio-side backpressure (a no-op under
        // DISABLE_THREADING=1). Removed to avoid implying a buffer-size knob
        // we don't actually own.
    }
}

- (void)runFrame {
    if (_core && _romLoaded) {
        _core->runFrame(_core);
    }
}

- (void)setKeys:(uint32_t)keys {
    if (_core) {
        _core->setKeys(_core, keys);
    }
}

- (const uint32_t *)frameBuffer {
    return (const uint32_t *)_videoBuffer;
}

- (CGImageRef)createFrameImage {
    if (!_videoBuffer || !_core) return NULL;

    NSInteger width = self.screenWidth;
    NSInteger height = self.screenHeight;
    // Use buffer stride (base width) for bytesPerRow, not display width.
    // The buffer may be wider than the display (e.g., SGB 256-wide buffer
    // with 160-wide GB display). Each row in memory is stride-wide.
    NSInteger bytesPerRow = self.bufferStride * sizeof(mColor);

    // mGBA XBGR8 format: bytes in memory are [R, G, B, X].
    // CGBitmapContext with Big endian + SkipLast interprets as RGBX:
    //   byte0=R, byte1=G, byte2=B, byte3=X(skipped)
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        _videoBuffer,
        width,
        height,
        8,
        bytesPerRow,
        colorSpace,
        (CGBitmapInfo)kCGBitmapByteOrder32Big | (CGBitmapInfo)kCGImageAlphaNoneSkipLast
    );

    CGImageRef image = NULL;
    if (context) {
        image = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
    } else {
        NSLog(@"MGBABridge: Failed to create CGBitmapContext for frame image");
    }
    CGColorSpaceRelease(colorSpace);

    return image;
}

- (CGImageRef)createDualScreenFrameImage {
    return NULL;  // Single-screen system — no dual-screen capture
}

- (BOOL)saveStateToPath:(NSString *)path {
    if (!_core || !_romLoaded) return NO;

    // Write to a sibling temp file, then atomically rename over the final
    // path. A crash or kill mid-write can then only ever leave the previous,
    // intact save state in place, never a half-written corrupt one. Writing
    // O_TRUNC directly onto the final path (the old behaviour) exposed exactly
    // that torn-write window. The temp lives in the same directory, so the
    // rename is a same-filesystem atomic swap.
    // O_RDWR required: mCoreSaveStateNamed uses mmap which needs read+write.
    NSString *tmp = [path stringByAppendingString:@".writing"];
    struct VFile *vf = VFileOpen([tmp UTF8String], O_RDWR | O_CREAT | O_TRUNC);
    if (!vf) return NO;

    bool success = mCoreSaveStateNamed(_core, vf, SAVESTATE_ALL);
    vf->close(vf);

    if (!success) {
        unlink([tmp UTF8String]);
        return NO;
    }
    if (rename([tmp UTF8String], [path UTF8String]) != 0) {
        unlink([tmp UTF8String]);
        return NO;
    }
    return YES;
}

- (void)setGBPalette:(const uint32_t *)colors {
    if (!_core) return;
    if (_core->platform(_core) != mPLATFORM_GB) return;
    char key[16];
    for (int i = 0; i < 12; ++i) {
        snprintf(key, sizeof(key), "gb.pal[%d]", i);
        mCoreConfigSetUIntValue(&_core->config, key, colors[i] & 0xFFFFFF);
    }
    // Re-reads the 12 keys into dmgPalette and, on a DMG-model game, rewrites
    // the live BGP/OBP0/OBP1 palette mapping in place — visible on the next
    // rendered frame, no reset needed. Resets re-read the same config keys,
    // so the choice survives them too.
    _core->reloadConfigOption(_core, "gb.pal", &_core->config);
}

- (BOOL)isDMGPaletteApplicable {
    if (!_core || !_romLoaded) return NO;
    if (_core->platform(_core) != mPLATFORM_GB) return NO;
    // Mirrors mGBA's own condition exactly (GBVideoWritePalette, video.c:797):
    // only `model < GB_MODEL_SGB` routes BGP/OBP writes through dmgPalette, so
    // only that model can be recoloured.
    //
    // The enum is NOT ordered by capability — DMG 0x00, SGB 0x20, MGB 0x40,
    // CGB 0x80 — so this passes for DMG alone, not "DMG and MGB" as an earlier
    // comment here claimed. That matches mGBA, whose palette write does nothing
    // at all on MGB.
    //
    // Consequence worth knowing: autodetect (gb.c:923) picks SGB for any cart
    // with sgb == 0x03 and oldLicensee == 0x33, which includes Pokemon Red and
    // Blue. Those are monochrome on a plain Game Boy but render through SGB
    // colours here, so palettes correctly report as inapplicable.
    struct GB *gb = (struct GB *)_core->board;
    return gb->model < GB_MODEL_SGB;
}

- (void)flushSaveData {
    if (!_core || !_romLoaded) return;

    // mGBA only syncs the battery save (SRAM/flash/EEPROM) to disk
    // mSAVEDATA_CLEANUP_THRESHOLD (15) frames after the last in-game write.
    // If iOS suspends and kills the app inside that window, a fresh boot
    // would read a slightly stale .sav. Force the sync now (we are paused,
    // so no frame runs concurrently). GBASavedataClean / GBSramClean only
    // write the live, valid save buffer to the file, so this can never
    // corrupt the save; worst case it is a no-op when nothing is dirty.
    //
    // The clean functions gate on the dirt having aged past the 15-frame
    // threshold. Call twice with very high, increasing pseudo-frame counts:
    // the first promotes a just-dirtied buffer to "seen", the second (100
    // "frames" later) trips the age gate and performs the sync. The fixed
    // constants stay well above any realistic real frame count (0xF0000000
    // frames is years of continuous play), so no underflow.
    const uint32_t f1 = 0xF0000000u;
    const uint32_t f2 = f1 + 100u;
    switch (_core->platform(_core)) {
        case mPLATFORM_GBA: {
            struct GBASavedata *sd = &((struct GBA *)_core->board)->memory.savedata;
            GBASavedataClean(sd, f1);
            GBASavedataClean(sd, f2);
            break;
        }
        case mPLATFORM_GB: {
            struct GB *gb = (struct GB *)_core->board;
            GBSramClean(gb, f1);
            GBSramClean(gb, f2);
            break;
        }
        default:
            break;
    }
}

- (BOOL)loadStateFromPath:(NSString *)path {
    if (!_core || !_romLoaded) return NO;

    struct VFile *vf = VFileOpen([path UTF8String], O_RDONLY);
    if (!vf) return NO;

    bool success = mCoreLoadStateNamed(_core, vf, SAVESTATE_ALL);
    vf->close(vf);
    return success ? YES : NO;
}

- (void)setSpeedMultiplier:(int)multiplier {
    if (!_core) return;
    // For speed control, we'll handle frame pacing in the Swift layer.
    // mGBA's fast-forward works by running multiple frames per display frame.
}

// MARK: - Memory (RetroAchievements)

- (NSInteger)readMemoryAtAddress:(uint32_t)address into:(uint8_t *)buffer length:(NSInteger)length {
    if (!_core || !_romLoaded || !buffer || length <= 0) return 0;
    // mGBA's busRead8 reads the real system bus, so the GBA work-RAM and SRAM
    // regions (0x02000000 / 0x03000000 / 0x0E000000) and the GB/GBC base
    // address space (0x0000–0xFFFF) resolve directly to the live RAM the
    // RetroAchievements triggers watch. The caller has already mapped the RA
    // flat address to this real bus address, so we just walk bytes. A read is
    // side-effect-free on the CPU state (no DMA/IO trigger for plain RAM/SRAM).
    for (NSInteger i = 0; i < length; i++) {
        buffer[i] = (uint8_t)(_core->busRead8(_core, address + (uint32_t)i) & 0xFF);
    }
    return length;
}

- (unsigned int)audioSampleRate {
    if (!_core) return 0;
    return _core->audioSampleRate(_core);
}

- (NSInteger)readAudioSamples:(int16_t *)buffer count:(NSInteger)count {
    if (!_core) return 0;

    struct mAudioBuffer *audioBuf = _core->getAudioBuffer(_core);
    if (!audioBuf) return 0;

    size_t available = mAudioBufferAvailable(audioBuf);
    size_t toRead = (size_t)count < available ? (size_t)count : available;
    if (toRead == 0) return 0;

    return (NSInteger)mAudioBufferRead(audioBuf, buffer, toRead);
}

- (unsigned int)consumePendingAudioRate {
    // Called from EmulatorSession.runFrame() on the same thread that drives
    // mGBA's runFrame, so the read/clear pair is implicitly serialized with
    // the trampoline write. No atomics required.
    unsigned int rate = _pendingAudioRate;
    _pendingAudioRate = 0;
    return rate;
}

// Called from the mAVStream trampoline below. Stores the latest reported rate
// so EmulatorSession can pick it up after the current runFrame returns.
- (void)_setPendingAudioRate:(unsigned int)rate {
    _pendingAudioRate = rate;
}

- (void)initRewind:(NSInteger)seconds {
    if (!_core || !_romLoaded) return;

    if (_rewindInitialized) {
        mCoreRewindContextDeinit(&_rewindContext);
    }

    // ~60 frames per second, store one entry per frame
    size_t entries = (size_t)(seconds * 60);
    mCoreRewindContextInit(&_rewindContext, entries, false);
    _rewindInitialized = YES;

    // Capture initial state
    mCoreRewindAppend(&_rewindContext, _core);
}

- (void)rewindAppend {
    if (_rewindInitialized && _core) {
        mCoreRewindAppend(&_rewindContext, _core);
    }
}

- (BOOL)rewindFrames:(NSInteger)count {
    if (!_rewindInitialized || !_core) return NO;
    return mCoreRewindRestore(&_rewindContext, _core, (unsigned)count) ? YES : NO;
}

- (void)shutdown {
    _cheatsInitialized = NO;

    if (_rewindInitialized) {
        mCoreRewindContextDeinit(&_rewindContext);
        _rewindInitialized = NO;
    }

    if (_core) {
        if (_streamInstalled) {
            // Detach our mAVStream before deinit so no late callback can land
            // on a half-torn-down core. Belt-and-suspenders: deinit shouldn't
            // fire audio callbacks anyway.
            _core->setAVStream(_core, NULL);
            _streamInstalled = NO;
        }
        if (_romLoaded) {
            _core->unloadROM(_core);
        }
        _core->deinit(_core);
        _core = NULL;
    }
    _pendingAudioRate = 0;

    if (_videoBuffer) {
        free(_videoBuffer);
        _videoBuffer = NULL;
    }

    _romLoaded = NO;
}

// MARK: - Cheat Codes

- (void)ensureCheatDevice {
    if (_cheatsInitialized || !_core) return;
    // mGBA exposes cheats via core->cheatDevice(), not a standalone attach function
    struct mCheatDevice *device = _core->cheatDevice(_core);
    if (device) {
        _cheatsInitialized = YES;
    }
}

- (BOOL)addCheatCode:(NSString *)code type:(int)type {
    if (!_core || !_romLoaded) return NO;
    [self ensureCheatDevice];

    struct mCheatDevice *device = _core->cheatDevice(_core);
    if (!device) return NO;

    struct mCheatSet *set = device->createSet(device, [code UTF8String]);
    if (!set) return NO;

    // Parse each line (codes may have multiple lines separated by newlines or +)
    NSArray *lines = [code componentsSeparatedByCharactersInSet:
                      [NSCharacterSet characterSetWithCharactersInString:@"\n+"]];
    BOOL anyAdded = NO;
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0) continue;
        if (mCheatAddLine(set, [trimmed UTF8String], type)) {
            anyAdded = YES;
        }
    }

    if (anyAdded) {
        set->enabled = true;
        mCheatAddSet(device, set);
        mCheatRefresh(device, set);
        return YES;
    } else {
        set->deinit(set);
        return NO;
    }
}

- (void)clearCheats {
    if (!_cheatsInitialized || !_core) return;
    struct mCheatDevice *device = _core->cheatDevice(_core);
    if (device) {
        mCheatDeviceClear(device);
    }
}

- (void)setCheatsEnabled:(BOOL)enabled {
    if (!_cheatsInitialized || !_core) return;
    struct mCheatDevice *device = _core->cheatDevice(_core);
    if (!device) return;
    for (size_t i = 0; i < mCheatSetsSize(&device->cheats); i++) {
        struct mCheatSet *set = *mCheatSetsGetPointer(&device->cheats, i);
        set->enabled = enabled;
        mCheatRefresh(device, set);
    }
}

// MARK: - EmulatorBridge (NDS stubs)

- (NSInteger)totalBufferHeight {
    return self.screenHeight;
}

- (BOOL)hasTouchScreen {
    return NO;
}

- (void)touchScreenAtX:(int)x y:(int)y {
    // No-op: GBA/GB have no touch screen
}

- (void)touchScreenRelease {
    // No-op: GBA/GB have no touch screen
}

@end

// mGBA hands us back the `mAVStream*` it was given. Because `stream` is the
// first field of `MGBAStreamContext`, that pointer is bit-identical to a
// `MGBAStreamContext*`, and we can recover the owning bridge by cast. This is
// the container-of pattern, simplified by mAVStream's lack of a userData slot.
static void _mgbaAudioRateChangedTrampoline(struct mAVStream *stream, unsigned rate) {
    if (!stream) return;
    MGBAStreamContext *ctx = (MGBAStreamContext *)stream;
    MGBABridge *bridge = (__bridge MGBABridge *)ctx->bridge;
    [bridge _setPendingAudioRate:rate];
}
