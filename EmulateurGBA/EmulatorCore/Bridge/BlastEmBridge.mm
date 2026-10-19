//
//  BlastEmBridge.mm
//  EmulateurGBA
//
//  ObjC++ implementation bridging BlastEm (Mega Drive) to Swift.
//
//  HOW THIS CORE IS BUILT, in one paragraph (the full reasons are in
//  Vendor/blastem-ios/build.sh). BlastEm's 68000 and Z80 are interpreters
//  GENERATED IN C at build time from its CPU description files, which is the
//  only path BlastEm has off x86: no JIT, no assembly, nothing the App Store
//  forbids. Its libretro build is what we link, renamed md_retro_* and
//  prelinked into one object that exports nothing else. Measured on the host
//  before it reached a phone (Tools/md-bench): Sonic played through Green Hill
//  at about 1 ms a frame against 16.7, Titan's Overdrive 2 drawn correctly to
//  its end.
//
//  HOW IT IS DRIVEN. Through libretro, like PCSX-ReARMed and Mupen64Plus-Next,
//  and under the same constraint: one global core instance, callbacks without
//  a user-data pointer, so one BlastEmBridge at a time and a file-static to
//  reach it. `retro_run` is one frame by contract: the core runs until its VDP
//  hands over a finished picture, then returns.
//
//  WHAT THE CORE DOES NOT WARN ABOUT, all read in its libblastem.c:
//   - GET_OVERSCAN must be answered. The core declares a byte, asks, and reads
//     it whether or not we answered: an unanswered call leaves the crop
//     decided by whatever the stack held.
//   - `retro_get_system_av_info` is not a pure query. It re-initialises the
//     core's audio output at the console's real rate and re-tunes its
//     resampler, so it is called once after each load (as RetroArch does) and
//     never per frame; the figures it returns are cached.
//   - the picture arrives through `video_refresh` from the core's own buffer;
//     the core offers no way to draw into ours, so each frame is copied (320 x
//     224 x 4 bytes, about 0.3 MB, nothing beside the emulation).
//   - its cheat entry points are empty, so the cheats are ours: Pro Action
//     Replay codes, written into the 68000's RAM before every frame (see the
//     Cheats section). Game Genie codes patch the ROM, which the core keeps to
//     itself, so they are refused rather than pretended.
//

// The rename must come before ANY libretro header, so the declarations the
// headers make are the renamed ones.
#include "md_symbols.h"

#if !__has_include("libretro.h")
#error "libretro.h is missing. It comes from the PCSX-ReARMed submodule: git submodule update --init Vendor/pcsx_rearmed"
#endif

#import "BlastEmBridge.h"

#include <atomic>
#include <cmath>
#include <cstring>
#include <ctime>
#include <mutex>
#include <string>
#include <vector>

#include "libretro.h"

#import <os/log.h>

const NSInteger MDMaxBufferWidth  = 320;
const NSInteger MDMaxBufferHeight = 480;

/// The Mega Drive drew for a 4:3 television in both of its widths: H40 (320)
/// and H32 (256) fill the same screen, the narrower one with wider pixels. So
/// the shape is 4:3 whatever the game picks, as for the PlayStation and the
/// N64, and not the square-pixel frame the SNES and the NES show: a game can
/// switch width mid-session, and the space the app reserves for the picture
/// is one shape (`PresetLayoutResolver.displayAspect`, which must match).
static const CGFloat kMDDisplayAspect = 4.0 / 3.0;

/// The console's two controller ports, which is `PresetSystem.playerCount` for
/// the Mega Drive. The core plugs a six-button pad into both at load (its
/// default when no configuration names another device), and reads only these
/// two ports.
static const unsigned kMDPorts = 2;

/// About a third of a second of stereo frames, as in the other libretro
/// bridges: the core PUSHES samples during the frame and our audio engine
/// PULLS them on its own clock, so something has to sit between the two.
static const size_t kAudioRingFrames = 16384;

/// Rewind: one whole state a second, the SNES and NES arrangement and for the
/// same reason. A Mega Drive state is about 142 KB (Tools/md-bench), so the
/// thirty-five seconds the session asks for cost about 5 MB; deltas, which the
/// DS and the N64 need, would be complexity bought for nothing here.
static const NSInteger kRewindSecondsPerSnapshot = 1;

/// Hard ceiling on the ring, as on the other consoles. A state is about
/// 142 KB, so this only bites if a game's states turn out far larger.
static const size_t kRewindByteCeiling = 24u * 1024u * 1024u;

/// Diagnostics for bringing this console up. DEBUG only, at error level so the
/// lines reach the console a player can paste from; release builds log
/// nothing extra.
#if DEBUG
#define MDDiag(fmt, ...) os_log_error(BlastEmLog(), "[MD] " fmt, ##__VA_ARGS__)
#else
#define MDDiag(fmt, ...) do { } while (0)
#endif

static os_log_t BlastEmLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.retropal.emulateurgba", "blastem"); });
    return log;
}

#pragma mark - Audio ring

/// Push-to-pull adapter, identical in shape to PCSXBridge's, including the
/// overflow rule: drop the OLDEST frame, so a stall costs latency once instead
/// of accumulating a permanent offset.
class BlastEmAudioRing {
public:
    BlastEmAudioRing() { _ring.resize(kAudioRingFrames * 2, 0); }

    void Write(const int16_t *frames, size_t frameCount) {
        std::lock_guard<std::mutex> lock(_lock);
        for (size_t i = 0; i < frameCount; i++) {
            _ring[_write * 2]     = frames[i * 2];
            _ring[_write * 2 + 1] = frames[i * 2 + 1];
            _write = (_write + 1) % kAudioRingFrames;
            if (_write == _read) _read = (_read + 1) % kAudioRingFrames;
        }
    }

    size_t Read(int16_t *out, size_t maxFrames) {
        std::lock_guard<std::mutex> lock(_lock);
        size_t count = 0;
        while (count < maxFrames && _read != _write) {
            out[count * 2]     = _ring[_read * 2];
            out[count * 2 + 1] = _ring[_read * 2 + 1];
            _read = (_read + 1) % kAudioRingFrames;
            count++;
        }
        return count;
    }

    void Clear() {
        std::lock_guard<std::mutex> lock(_lock);
        _read = _write = 0;
    }

private:
    std::vector<int16_t> _ring;
    size_t _read = 0;
    size_t _write = 0;
    std::mutex _lock;
};

#pragma mark - Save-state files

// What `retro_unserialize` is handed, checked before it is: BlastEm reads a
// state with no checks of its own that it can survive. Its `fatal_error`
// (util.c) ENDS THE PROCESS, and it is what a state of the wrong shape reaches:
// a section longer than what is left ("Section is bigger than remaining
// space"), a field read past its section's end, a work RAM or Z80 RAM larger
// than the console's. So a damaged, truncated or foreign file would close the
// app rather than fail to load. Plain C++ on bytes, so the check is testable
// off the phone (`isLoadableStateFile:`).
//
// THE FORMAT, as libblastem.c and serialize.c write it: the state's own length
// as a host size_t, then the state, then up to 64 bytes of slack (the size the
// core asks for is padded, because the video chip's FIFO can grow between the
// measure and the write). The state is a run of sections, each a big-endian
// 16-bit id and 32-bit length and that many bytes. A Mega Drive state always
// holds the 68000, the video chip and the work RAM (genesis_serialize).
//
// What it does not catch: a byte damaged INSIDE a section of the right length.
// Slots are written atomically by this app, so that takes a file damaged on
// disk; a digest would catch it, at the cost of a file format of our own.

static const uint16_t kMDSection68000 = 1;      // SECTION_68000
static const uint16_t kMDSectionVDP = 3;        // SECTION_VDP
static const uint16_t kMDSectionMainRAM = 10;   // SECTION_MAIN_RAM
static const uint16_t kMDSectionSoundRAM = 11;  // SECTION_SOUND_RAM
/// genesis.c writes the RAM sizes in KB as each section's first byte, and
/// fatals on a larger one: 64 KB of work RAM, 8 KB of Z80 RAM.
static const uint8_t kMDMainRAMKB = 64;
static const uint8_t kMDSoundRAMKB = 8;

static bool MDStateFileIsLoadable(const uint8_t *file, size_t length) {
    if (!file || length < sizeof(size_t)) return false;
    size_t inner = 0;
    memcpy(&inner, file, sizeof(size_t));
    // The core trusts this length without checking it against the buffer.
    if (inner == 0 || inner > length - sizeof(size_t)) return false;
    const uint8_t *p = file + sizeof(size_t);
    const uint8_t *end = p + inner;
    bool has68000 = false, hasVDP = false, hasMainRAM = false;
    while (p < end) {
        if ((size_t)(end - p) < 6) return false;
        const uint16_t sid = (uint16_t)(p[0] << 8 | p[1]);
        const uint32_t size = (uint32_t)p[2] << 24 | (uint32_t)p[3] << 16 | (uint32_t)p[4] << 8 | p[5];
        p += 6;
        if (size > (size_t)(end - p)) return false;
        if (sid == kMDSection68000) has68000 = true;
        if (sid == kMDSectionVDP) hasVDP = true;
        if (sid == kMDSectionMainRAM) {
            if (size < 1 || p[0] != kMDMainRAMKB) return false;
            hasMainRAM = true;
        }
        if (sid == kMDSectionSoundRAM && (size < 1 || p[0] > kMDSoundRAMKB)) return false;
        p += size;
    }
    return has68000 && hasVDP && hasMainRAM;
}

#pragma mark - Bridge

@interface BlastEmBridge ()
/// Called from the C callbacks below, which have no other way back to us.
- (void)handleVideo:(const void *)data width:(unsigned)width height:(unsigned)height pitch:(size_t)pitch;
- (void)handleAudio:(const int16_t *)frames count:(size_t)count;
- (bool)handleEnvironment:(unsigned)cmd data:(void *)data;
- (int16_t)inputStateForPort:(unsigned)port device:(unsigned)device buttonID:(unsigned)buttonID;
@end

/// The single live instance. UNRETAINED for the reason PCSXBridge gives (the
/// input callback fires a dozen times a frame, and a __weak read is a
/// retain/release pair each time); safe because `init` sets it, `shutdown`
/// clears it, `dealloc` calls `shutdown`, and the core only calls back from
/// inside `retro_run` or the load.
static __unsafe_unretained BlastEmBridge *sBridge = nil;

static bool BlastEmEnvironmentCallback(unsigned cmd, void *data) {
    BlastEmBridge *bridge = sBridge;
    return bridge ? [bridge handleEnvironment:cmd data:data] : false;
}

static void BlastEmVideoCallback(const void *data, unsigned width, unsigned height, size_t pitch) {
    [sBridge handleVideo:data width:width height:height pitch:pitch];
}

/// The core never sends single samples (its libretro.c leaves this setter
/// empty), but libretro requires the frontend to provide one.
static void BlastEmAudioSampleCallback(int16_t left, int16_t right) {
    int16_t frame[2] = { left, right };
    [sBridge handleAudio:frame count:1];
}

static size_t BlastEmAudioBatchCallback(const int16_t *data, size_t frames) {
    [sBridge handleAudio:data count:frames];
    return frames;
}

static void BlastEmInputPollCallback(void) {
    // Nothing to fetch: `setKeys:` already deposited the current state.
}

static int16_t BlastEmInputStateCallback(unsigned port, unsigned device, unsigned index, unsigned id) {
    BlastEmBridge *bridge = sBridge;
    return bridge ? [bridge inputStateForPort:port device:device buttonID:id] : 0;
}

/// Our bitmask (see BlastEmBridge.h for the positions) to the libretro buttons
/// BlastEm reads, through BlastEm's own table in `process_events`:
///   libretro B -> A, A -> B, R -> C, Y -> X, X -> Y, L -> Z,
///   SELECT -> MODE, START -> START.
/// So our 0x800, which is the Mega Drive's A, is sent as libretro B, and so
/// on down the list. The core asks one button at a time, from libretro B up
/// to R, on each of its two ports.
static const struct { uint32_t ours; unsigned theirs; } kButtonMap[] = {
    { 0x800, RETRO_DEVICE_ID_JOYPAD_B      },   // left face   -> A
    { 0x001, RETRO_DEVICE_ID_JOYPAD_A      },   // bottom face -> B
    { 0x002, RETRO_DEVICE_ID_JOYPAD_R      },   // right face  -> C
    { 0x200, RETRO_DEVICE_ID_JOYPAD_Y      },   // L bumper    -> X
    { 0x400, RETRO_DEVICE_ID_JOYPAD_X      },   // top face    -> Y
    { 0x100, RETRO_DEVICE_ID_JOYPAD_L      },   // R bumper    -> Z
    { 0x004, RETRO_DEVICE_ID_JOYPAD_SELECT },   //             -> MODE
    { 0x008, RETRO_DEVICE_ID_JOYPAD_START  },
    { 0x010, RETRO_DEVICE_ID_JOYPAD_RIGHT  },
    { 0x020, RETRO_DEVICE_ID_JOYPAD_LEFT   },
    { 0x040, RETRO_DEVICE_ID_JOYPAD_UP     },
    { 0x080, RETRO_DEVICE_ID_JOYPAD_DOWN   },
};

@implementation BlastEmBridge {
    BOOL _romLoaded;
    /// Set when a save on disk could not be read AND could not be moved aside:
    /// writing would then replace it, so nothing is written this session.
    BOOL _saveWritesBlocked;
    BOOL _coreInitialised;
    std::string _romPath;

    /// The session texture, allocated once at the console's maximum; the live
    /// picture occupies its top-left corner. See BlastEmBridge.h.
    std::vector<uint32_t> _frameBuffer;
    /// What the game is drawing right now: 320 or 256 wide, 224 or 240 tall,
    /// doubled in the interlaced mode.
    std::atomic<uint32_t> _liveWidth;
    std::atomic<uint32_t> _liveHeight;

    BlastEmAudioRing _audio;

    std::atomic<uint32_t> _buttons[kMDPorts];

    int _speedMultiplier;

    /// From `retro_get_system_av_info`, read once per load (see the file
    /// header for why never per frame). NTSC 59.92, PAL 49.70; the sample rate
    /// is the YM2612's own, about 53 kHz.
    double _framesPerSecond;
    unsigned int _sampleRate;

    std::string _savePath;

    /// Performance, for the device pass that decides this console.
    uint64_t _perfWindowStartNs;
    uint64_t _perfFrames;
    uint64_t _perfRunNs;
    uint64_t _perfWorstNs;
    uint32_t _lastLoggedWidth;
    uint32_t _lastLoggedHeight;

    /// Cheats: every RAM write of every enabled code, applied before each
    /// frame. Locked because codes are added from the main thread while the
    /// emulator thread applies them.
    struct MDCheatWrite { uint32_t offset; uint16_t value; bool isByte; };
    std::vector<MDCheatWrite> _cheatWrites;
    std::mutex _cheatLock;

    /// Rewind: whole states in a ring, newest last.
    std::vector<std::vector<uint8_t>> _rwStates;
    NSInteger _rwCapacity;
    NSInteger _rwStored;
    NSInteger _rwNewest;
    NSInteger _rwFrameCounter;
    BOOL _rwSnapshotDue;
}

- (instancetype)init {
    if ((self = [super init])) {
        // The same backstop PCSXBridge has: libretro has ONE global instance,
        // so an older bridge still alive is the one being discarded. Recover,
        // loudly, rather than crash.
        if (sBridge != nil && sBridge != self) {
            os_log_error(BlastEmLog(),
                         "[MD] a second bridge was created; shutting the previous one down. "
                         "Something upstream is building a core more than once.");
            [sBridge shutdown];
        }
        sBridge = self;

        _romLoaded = NO;
        _coreInitialised = NO;
        _speedMultiplier = 1;
        _framesPerSecond = 59.92;
        _sampleRate = 53267;
        _liveWidth = 320;
        _liveHeight = 224;
        for (unsigned p = 0; p < kMDPorts; p++) _buttons[p] = 0;
        _perfWindowStartNs = _perfFrames = _perfRunNs = _perfWorstNs = 0;
        _lastLoggedWidth = _lastLoggedHeight = 0;
        _rwCapacity = _rwStored = _rwFrameCounter = 0;
        _rwNewest = -1;
        _rwSnapshotDue = NO;

        _frameBuffer.assign((size_t)(MDMaxBufferWidth * MDMaxBufferHeight), 0);

        // Installed BEFORE retro_init. The core asks its first questions from
        // inside `retro_set_environment` itself (the system directory, the
        // content override), so the other callbacks go first and the
        // environment last, once `sBridge` can answer.
        retro_set_video_refresh(BlastEmVideoCallback);
        retro_set_audio_sample(BlastEmAudioSampleCallback);
        retro_set_audio_sample_batch(BlastEmAudioBatchCallback);
        retro_set_input_poll(BlastEmInputPollCallback);
        retro_set_input_state(BlastEmInputStateCallback);
        retro_set_environment(BlastEmEnvironmentCallback);
    }
    return self;
}

- (void)dealloc {
    [self shutdown];
}

#pragma mark - Properties

- (BOOL)isROMLoaded { return _romLoaded; }
- (NSInteger)screenWidth { return (NSInteger)_liveWidth.load(); }
- (NSInteger)screenHeight { return (NSInteger)_liveHeight.load(); }
- (NSInteger)bufferStride { return MDMaxBufferWidth; }
- (NSInteger)totalBufferHeight { return (NSInteger)_liveHeight.load(); }
/// Not `totalBufferHeight`: the live height moves (224, 240, and doubled when
/// a game turns interlace on), so the texture is allocated at the maximum.
- (NSInteger)maxBufferHeight { return MDMaxBufferHeight; }
- (BOOL)hasTouchScreen { return NO; }
- (CGFloat)displayAspect { return kMDDisplayAspect; }

/// libretro's XRGB8888 is 0x00RRGGBB in a host uint32, so B, G, R, X in memory
/// on a little-endian machine: the order the renderer's `.bgra8Unorm` takes.
- (BOOL)usesBGRAPixelOrder { return YES; }

/// The core's own figure, so a PAL cartridge paces at 49.70 and not a fifth
/// too fast. Cached at load (see the file header).
- (double)framesPerSecond {
    return _framesPerSecond > 1.0 ? _framesPerSecond : 59.92;
}

#pragma mark - Environment

- (bool)handleEnvironment:(unsigned)cmd data:(void *)data {
    switch (cmd) {

    // --- what we answer -----------------------------------------------------

    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
        // The core asks for XRGB8888 at every load, which is the only format
        // the renderer's texture can take. Refusing anything else is loud on
        // purpose: a 16-bit frame would be read as half-width garbage.
        const auto fmt = *(const enum retro_pixel_format *)data;
        if (fmt == RETRO_PIXEL_FORMAT_XRGB8888) return true;
        os_log_error(BlastEmLog(), "core asked for pixel format %d, refused (we take XRGB8888)", (int)fmt);
        return false;
    }

    case RETRO_ENVIRONMENT_GET_OVERSCAN:
        // FALSE: crop the border the core draws around the picture, which a
        // Mega Drive's own television hid behind its bezel. The core then
        // delivers 320 x 224 (NTSC) or 320 x 240 (PAL), the frame every game
        // was composed for. The core reads this as a byte, so one is written.
        if (data) *(uint8_t *)data = 0;
        return true;

    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
        // Deliberately unanswered. The core looks there for the Mega-CD and
        // 32X BIOS files, and this app runs cartridges only (see
        // BlastEmBridge.h); with no directory it configures no BIOS at all.
        if (data) *(const char **)data = NULL;
        return false;

    case RETRO_ENVIRONMENT_SET_GEOMETRY:
        // The new size arrives with the next `video_refresh`, which is where
        // it is read. Acknowledged so the change is not refused.
        return true;

    // --- accepted and ignored, each for its own reason ----------------------

    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
        // Button names for a remapping UI the frontend owns. Ours is built
        // from ControllerMapping, not from the core.
        return true;

    case RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE:
        // Tells a frontend which extensions it may hand over as bytes. We hand
        // over a path (see `loadROMAtPath:`), so there is nothing to change.
        return true;

    default:
        return false;
    }
}

#pragma mark - ROM management

- (BOOL)loadROMAtPath:(NSString *)path {
    if (!path.length) return NO;

    if (!_coreInitialised) {
        retro_init();
        _coreInitialised = YES;
    }
    if (_romLoaded) {
        retro_unload_game();
        _romLoaded = NO;
    }

    _romPath = std::string(path.fileSystemRepresentation);

    retro_game_info info;
    memset(&info, 0, sizeof(info));
    // A path and no bytes: the core declares need_fullpath and opens the file
    // itself, which is also how it reads a byte-interleaved .smd dump (it
    // recognises those by name and header and de-interleaves while loading).
    info.path = _romPath.c_str();

    if (!retro_load_game(&info)) {
        os_log_error(BlastEmLog(), "retro_load_game failed for %{public}s", path.lastPathComponent.UTF8String);
        return NO;
    }
    _romLoaded = YES;
    _saveWritesBlocked = NO;

    // Once per load, as RetroArch does: this is the call that sets the core's
    // audio output to the console's real rate (see the file header).
    retro_system_av_info av;
    memset(&av, 0, sizeof(av));
    retro_get_system_av_info(&av);
    if (av.timing.fps > 1.0) _framesPerSecond = av.timing.fps;
    if (av.timing.sample_rate > 1.0) _sampleRate = (unsigned int)llround(av.timing.sample_rate);
    _liveWidth  = av.geometry.base_width  ? MIN(av.geometry.base_width,  (unsigned)MDMaxBufferWidth)  : 320;
    _liveHeight = av.geometry.base_height ? MIN(av.geometry.base_height, (unsigned)MDMaxBufferHeight) : 224;

    [self invalidateRewind];
    _audio.Clear();
    [self loadSaveRAM];

    MDDiag("loaded %{public}s | %ux%u | %.4f fps (%{public}s) | %u Hz | state %zu bytes | save RAM %zu bytes",
           path.lastPathComponent.UTF8String,
           _liveWidth.load(), _liveHeight.load(), _framesPerSecond,
           _framesPerSecond < 55 ? "PAL" : "NTSC", _sampleRate,
           retro_serialize_size(), retro_get_memory_size(RETRO_MEMORY_SAVE_RAM));
    return YES;
}

- (void)reset {
    if (!_romLoaded) return;
    retro_reset();
    [self invalidateRewind];
    _audio.Clear();
}

- (void)setSavePath:(NSString *)path {
    _savePath = path.length ? std::string(path.fileSystemRepresentation) : std::string();
    // The session may set the path after the load, so the save is read here
    // as well: a save read before the path is known would be an empty one,
    // later written back over the player's.
    [self loadSaveRAM];
}

/// The cartridge's battery save, as the app's canonical save file.
///
/// The core exposes it as RETRO_MEMORY_SAVE_RAM (SRAM or EEPROM, whichever
/// the cartridge has, sized by the core's own cartridge database) and never
/// writes a file of its own in this build, so it is read and written exactly
/// like the other consoles' save RAM. A game without a save answers NULL and
/// nothing is read or written.
- (void)loadSaveRAM {
    if (!_romLoaded || _savePath.empty()) return;
    void *ram = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    const size_t size = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!ram || !size) return;

    NSData *stored = [NSData dataWithContentsOfFile:@(_savePath.c_str())];
    if (!stored) return;
    if (stored.length != size) {
        // Left unread rather than half-copied: a different size is a save from
        // another emulator's layout or another game, and a partial copy would
        // be a corrupt save the game then writes back.
        //
        // And MOVED ASIDE, which it was not until 2026-10-09: the save
        // importer accepts ten Mega Drive sizes and this cartridge reads one,
        // so an imported save of another size (Genesis Plus GX writes 64 KB)
        // was skipped here and then replaced, at the next pause, by the empty
        // save the game started with. Kept beside the canonical file under a
        // name the battery-save sync does not read; if it cannot be moved,
        // nothing is written this session, so it is never overwritten.
        NSString *canonical = @(_savePath.c_str());
        NSString *aside = [NSString stringWithFormat:@"%@.unread-%lld", canonical,
                           (long long)[NSDate date].timeIntervalSince1970];
        NSError *moveError = nil;
        if (![[NSFileManager defaultManager] moveItemAtPath:canonical toPath:aside error:&moveError]) {
            _saveWritesBlocked = YES;
            os_log_error(BlastEmLog(), "save is %lu bytes, the cartridge has %zu; could not move it aside (%{public}s), save writes blocked",
                         (unsigned long)stored.length, size, moveError.localizedDescription.UTF8String);
            return;
        }
        os_log_error(BlastEmLog(), "save is %lu bytes, the cartridge has %zu; kept unread as %{public}s",
                     (unsigned long)stored.length, size, aside.lastPathComponent.UTF8String);
        return;
    }
    memcpy(ram, stored.bytes, size);
    MDDiag("save RAM: loaded %zu bytes", size);
}

- (void)flushSaveData {
    if (!_romLoaded || _savePath.empty() || _saveWritesBlocked) return;
    const void *ram = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    const size_t size = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!ram || !size) return;
    NSData *data = [NSData dataWithBytes:ram length:size];
    NSError *error = nil;
    if (![data writeToFile:@(_savePath.c_str()) options:NSDataWritingAtomic error:&error]) {
        os_log_error(BlastEmLog(), "save write failed: %{public}s", error.localizedDescription.UTF8String);
    }
}

#pragma mark - Emulation

- (void)runFrame {
    if (!_romLoaded) return;
    [self applyCheats];
#if DEBUG
    const uint64_t before = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    retro_run();
    const uint64_t after = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    [self notePerformance:after - before at:after];
#else
    retro_run();
#endif
}

#if DEBUG
/// Frames per second and the time one frame costs, every two seconds, with
/// the worst frame of the window: the line the first device pass reads, in
/// Low Power Mode as for the N64. Above the budget the console cannot hold
/// full speed.
- (void)notePerformance:(uint64_t)elapsedNs at:(uint64_t)nowNs {
    if (_perfWindowStartNs == 0) { _perfWindowStartNs = nowNs; return; }
    _perfFrames++;
    _perfRunNs += elapsedNs;
    if (elapsedNs > _perfWorstNs) _perfWorstNs = elapsedNs;

    const uint64_t window = nowNs - _perfWindowStartNs;
    if (window < 2000000000ULL) return;

    const double seconds = (double)window / 1e9;
    const double fps = (double)_perfFrames / seconds;
    const double avgMs = _perfFrames ? (double)_perfRunNs / (double)_perfFrames / 1e6 : 0;
    MDDiag("%.1f fps emulated | %.2f ms per frame, worst %.2f | budget %.2f ms | %{public}s",
           fps, avgMs, (double)_perfWorstNs / 1e6, 1000.0 / _framesPerSecond,
           avgMs * _framesPerSecond > 1000.0 ? "OVER BUDGET" : "within budget");
    _perfWindowStartNs = nowNs;
    _perfFrames = 0;
    _perfRunNs = 0;
    _perfWorstNs = 0;
}
#endif

// `awaitDisplayFrame` is not implemented: `video_refresh` is called from
// inside `retro_run`, so the picture is in our buffer when the call returns.

- (void)setKeys:(uint32_t)keys {
    _buttons[0] = keys;
}

/// Player 2's buttons reach port 2; the console had no third port without an
/// adapter.
- (void)setKeys:(uint32_t)keys player:(NSInteger)player {
    if (player < 0 || player >= (NSInteger)kMDPorts) return;
    _buttons[player] = keys;
}

#pragma mark - Input

- (int16_t)inputStateForPort:(unsigned)port device:(unsigned)device buttonID:(unsigned)buttonID {
    if (port >= kMDPorts || device != RETRO_DEVICE_JOYPAD) return 0;
    const uint32_t keys = _buttons[port].load();
    for (const auto &m : kButtonMap) {
        if (buttonID == m.theirs) return (keys & m.ours) ? 1 : 0;
    }
    return 0;
}

#pragma mark - Video

- (void)handleVideo:(const void *)data width:(unsigned)width height:(unsigned)height pitch:(size_t)pitch {
    // NULL would mean "the picture did not change". The core never sends one,
    // and the buffer would already hold the right pixels if it did.
    if (!data || width == 0 || height == 0) return;
    if (width > (unsigned)MDMaxBufferWidth)   width  = (unsigned)MDMaxBufferWidth;
    if (height > (unsigned)MDMaxBufferHeight) height = (unsigned)MDMaxBufferHeight;

    if (width != _lastLoggedWidth || height != _lastLoggedHeight) {
        MDDiag("resolution %ux%u -> %ux%u", _lastLoggedWidth, _lastLoggedHeight, width, height);
        _lastLoggedWidth = width;
        _lastLoggedHeight = height;
    }

    const uint8_t *src = (const uint8_t *)data;
    uint32_t *dst = _frameBuffer.data();
    const size_t rowBytes = (size_t)width * sizeof(uint32_t);
    for (unsigned y = 0; y < height; y++) {
        memcpy(dst + (size_t)y * MDMaxBufferWidth, src + (size_t)y * pitch, rowBytes);
    }
    // Published after the pixels, so a reader that sees the new size also
    // finds the rows it describes.
    _liveWidth  = width;
    _liveHeight = height;
}

- (const uint32_t *)frameBuffer {
    return _romLoaded ? _frameBuffer.data() : NULL;
}

/// A still of the live picture at the shape it is displayed in: 4:3, which
/// neither 320 x 224 nor 256 x 224 is. Rescaled once here, at the source, for
/// the same reason PCSXBridge gives: every surface that shows a still (the
/// save-slot rows, the library cover fallback, the widget, the share cards)
/// would otherwise inherit the wrong shape. The box is the SMALLEST 4:3 one
/// containing the picture, so the correction only ever adds pixels.
- (CGImageRef)createFrameImage {
    if (!_romLoaded) return NULL;
    const uint32_t w = _liveWidth.load();
    const uint32_t h = _liveHeight.load();
    if (!w || !h) return NULL;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(_frameBuffer.data(), w, h, 8,
                                             (size_t)MDMaxBufferWidth * sizeof(uint32_t),
                                             colorSpace,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
    CGImageRef image = NULL;
    if (ctx) {
        image = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
    }

    if (image) {
        const CGFloat aspect = [self displayAspect];
        size_t outW = w, outH = h;
        const size_t byAspect = (size_t)llround((double)w / aspect);
        if (byAspect >= h) outH = byAspect;
        else               outW = (size_t)llround((double)h * aspect);
        if (outW != w || outH != h) {
            CGContextRef scaled = CGBitmapContextCreate(NULL, outW, outH, 8, 0, colorSpace,
                                                        kCGBitmapByteOrder32Little
                                                        | kCGImageAlphaNoneSkipFirst);
            if (scaled) {
                // No interpolation, as everywhere the app draws a game.
                CGContextSetInterpolationQuality(scaled, kCGInterpolationNone);
                CGContextDrawImage(scaled, CGRectMake(0, 0, outW, outH), image);
                CGImageRef corrected = CGBitmapContextCreateImage(scaled);
                CGContextRelease(scaled);
                if (corrected) {
                    CGImageRelease(image);
                    image = corrected;
                }
            }
        }
    }

    CGColorSpaceRelease(colorSpace);
    return image;
}

- (CGImageRef)createDualScreenFrameImage { return NULL; }

- (void)setGBPalette:(const uint32_t *)colors {}
- (BOOL)isDMGPaletteApplicable { return NO; }

#pragma mark - Save states

- (BOOL)saveStateToPath:(NSString *)path {
    if (!_romLoaded) return NO;
    const size_t size = retro_serialize_size();
    if (!size) return NO;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (!retro_serialize(data.mutableBytes, size)) return NO;
    return [data writeToFile:path atomically:YES];
}

- (BOOL)loadStateFromPath:(NSString *)path {
    if (!_romLoaded) return NO;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (![BlastEmBridge isLoadableStateFile:data ?: [NSData data]]) {
        os_log_error(BlastEmLog(), "save state %{public}s is not one this core wrote, refused",
                     path.lastPathComponent.UTF8String);
        return NO;
    }
    // A loaded state is a different timeline: drop the history in the BRIDGE,
    // the lesson the DS shipped as a bug. After the check, so a refused file
    // leaves the history of the game still running.
    [self invalidateRewind];
    if (!retro_unserialize(data.bytes, data.length)) return NO;
    _audio.Clear();
    return YES;
}

+ (BOOL)isLoadableStateFile:(NSData *)file {
    return MDStateFileIsLoadable((const uint8_t *)file.bytes, file.length) ? YES : NO;
}

#pragma mark - Memory (RetroAchievements)

/// rcheevos's Mega Drive regions, translated by RAClient to the real bus:
/// System RAM is the 68000's 64 KB at 0xFF0000, and Cartridge RAM is given the
/// real address 0x000000 (rcheevos's own convention, since the cartridge's
/// save RAM has no fixed place on the bus). Work RAM is handed over as the
/// core holds it, 16-bit words in the host's byte order, which is the layout
/// RetroAchievements' Mega Drive sets are written against (the libretro
/// convention every Mega Drive core follows).
- (NSInteger)readMemoryAtAddress:(uint32_t)address into:(uint8_t *)buffer length:(NSInteger)length {
    if (!_romLoaded || !buffer || length <= 0) return 0;

    unsigned which;
    size_t offset;
    if (address >= 0xFF0000u) {
        which = RETRO_MEMORY_SYSTEM_RAM;
        offset = address - 0xFF0000u;
    } else if (address < 0x10000u) {
        which = RETRO_MEMORY_SAVE_RAM;
        offset = address;
    } else {
        return 0;
    }

    const uint8_t *base = (const uint8_t *)retro_get_memory_data(which);
    const size_t size = retro_get_memory_size(which);
    if (!base || offset >= size) return 0;
    const size_t count = MIN((size_t)length, size - offset);
    memcpy(buffer, base + offset, count);
    return (NSInteger)count;
}

#pragma mark - Speed

/// Recorded, not passed to the core: how many frames run per display refresh
/// is our loop's decision for every core.
- (void)setSpeedMultiplier:(int)multiplier {
    _speedMultiplier = MAX(1, multiplier);
}

#pragma mark - Audio

- (unsigned int)audioSampleRate { return _sampleRate; }

- (void)handleAudio:(const int16_t *)frames count:(size_t)count {
    if (frames && count) _audio.Write(frames, count);
}

- (NSInteger)readAudioSamples:(int16_t *)buffer count:(NSInteger)count {
    if (!buffer || count <= 0) return 0;
    return (NSInteger)_audio.Read(buffer, (size_t)count);
}

/// The rate is the console's (NTSC or PAL) and is fixed for a cartridge's
/// whole session; it is read at load, before the audio engine asks for it.
- (unsigned int)consumePendingAudioRate { return 0; }

#pragma mark - Rewind

- (NSInteger)framesPerSnapshot {
    return MAX((NSInteger)1, (NSInteger)llround(self.framesPerSecond * kRewindSecondsPerSnapshot));
}

- (void)initRewind:(NSInteger)seconds {
    [self teardownRewind];
    if (seconds <= 0) return;
    // One snapshot a second plus the one at "now". The ring is a vector of
    // empty vectors until each slot is first written, and the byte ceiling is
    // applied at the first snapshot, when the real state size is known.
    _rwCapacity = seconds / kRewindSecondsPerSnapshot + 1;
    _rwStates.resize((size_t)_rwCapacity);
    _rwSnapshotDue = YES;
}

- (void)teardownRewind {
    _rwStates.clear();
    _rwStates.shrink_to_fit();
    _rwCapacity = 0;
    _rwStored = 0;
    _rwNewest = -1;
    _rwFrameCounter = 0;
    _rwSnapshotDue = NO;
}

/// Drop the history, keep the ring. Used wherever the timeline jumps: a reset,
/// a loaded state. The jump point itself is taken as the first new snapshot.
- (void)invalidateRewind {
    _rwStored = 0;
    _rwNewest = -1;
    _rwFrameCounter = 0;
    _rwSnapshotDue = (_rwCapacity > 0);
}

- (void)rewindAppend {
    if (_rwCapacity <= 0 || !_romLoaded) return;
    if (!_rwSnapshotDue && ++_rwFrameCounter < [self framesPerSnapshot]) return;
    _rwSnapshotDue = NO;
    _rwFrameCounter = 0;

    const size_t size = retro_serialize_size();
    if (!size) return;

    if (_rwStored == 0 && _rwNewest < 0) {
        // The first snapshot of a ring decides how deep it can be within the
        // ceiling. A shorter ring is visible to the player through what the
        // rewind offers, which is why depth shrinks rather than memory grows.
        const NSInteger affordable = (NSInteger)(kRewindByteCeiling / size);
        if (affordable < _rwCapacity) {
            _rwCapacity = MAX((NSInteger)2, affordable);
            _rwStates.resize((size_t)_rwCapacity);
        }
    }

    const NSInteger slotIndex = (_rwNewest + 1) % _rwCapacity;
    auto &slot = _rwStates[(size_t)slotIndex];
    if (slot.size() != size) slot.resize(size);
    if (!retro_serialize(slot.data(), size)) {
        // Not counted: a slot we failed to fill is not a place to rewind to.
        // And emptied: BlastEm writes the state's real length into the first
        // bytes BEFORE it finds the state too big for the buffer (a state
        // grows with the video chip's FIFO), and retro_unserialize trusts that
        // length. With the ring full this slot is the OLDEST snapshot, so left
        // as it is, a rewind to it would read past its end. It leaves the
        // count with its contents.
        slot.clear();
        if (_rwStored == _rwCapacity) _rwStored--;
        return;
    }
    _rwNewest = slotIndex;
    if (_rwStored < _rwCapacity) _rwStored++;
}

- (BOOL)rewindFrames:(NSInteger)count {
    if (!_romLoaded || _rwStored <= 0 || _rwNewest < 0) return NO;

    // The caller counts sixtieths of a second (EmulatorViewController asks
    // `seconds * 60` whatever the cartridge's rate), and we hold one snapshot
    // a second of play. Read in the cartridge's own frames, a PAL game's 5 s
    // was 300 / 50 = 6 snapshots and its 30 s was 35. Round UP to the
    // snapshot at or before the requested point, so a rewind never lands the
    // player somewhere they had already got past.
    const NSInteger perSnapshot = kRewindSecondsPerSnapshot * 60;
    NSInteger steps = (count + perSnapshot - 1) / perSnapshot;
    if (steps < 1) steps = 1;
    if (steps > _rwStored - 1) steps = _rwStored - 1;
    if (steps < 1) return NO;

    const NSInteger index = (_rwNewest - steps + _rwCapacity * 2) % _rwCapacity;
    auto &slot = _rwStates[(size_t)index];
    if (slot.empty()) return NO;
    if (!retro_unserialize(slot.data(), slot.size())) return NO;

    // Everything newer than where we landed is a future that did not happen.
    _rwNewest = index;
    _rwStored -= steps;
    _rwFrameCounter = 0;
    _rwSnapshotDue = NO;
    _audio.Clear();
    return YES;
}

#pragma mark - Cheats

// BlastEm's `retro_cheat_set` and `retro_cheat_reset` are empty in its libretro
// build, so the Mega Drive's cheats are applied here, the way a Pro Action
// Replay applied them: a value written to the console's RAM, held there by
// writing it again before every frame.
//
// THE FORMAT. One code per line, a six-digit address and a value, the address
// and value separated by a colon as the code lists print them (FFFE20:0063),
// or by a space, or by nothing (the app's formatter writes the colon). The
// address must be in the 68000's 64 KB of work RAM, 0xFF0000 to 0xFFFFFF, or
// one of its mirrors down to 0xE00000, which the console decodes to the same
// RAM. A two-digit value writes a byte, at either address. A four-digit value
// writes a word at an even address. At an ODD address a four-digit value is
// read the way Genesis Plus GX reads it (libretro/libretro.c, RAMCheatUpdate:
// a value whose high byte is zero is a byte, any other a word at the address
// rounded down to even), because the code lists libretro ships were written
// for it: `00YY` writes the byte YY at that very address (FFFE21:00E0, Sonic 2's
// "224 rings (official code)", and every "(On An Actual System)" twin), and
// FFF761:6411 writes the word at FFF760 (Sonic's "Super Speed!"). At an EVEN
// address `00YY` stays a word, where GPGX would write a byte: checked on the
// core (Tools/md-bench --poke, Sonic 1), the word is what most of the codes at
// even addresses mean (FFFE20:00C8 "Infinite Rings" is the word; as a byte it
// fills the ring counter's high half and the HUD shows garbage), and it keeps
// every code the app accepted before writing exactly what it wrote.
// Anything else is refused, the WHOLE entry with it, so a list never holds a
// code that half works: an address below 0xE00000 is the cartridge's ROM or a
// device register, and a ROM patch is what a Game Genie code is: the core keeps
// the ROM to itself, so it cannot be applied.
//
// THE MEMORY. The core holds work RAM as 32,768 16-bit words in the host's byte
// order (RETRO_MEMORY_SYSTEM_RAM), so a word goes in whole, and a byte at an
// EVEN 68000 address is the HIGH half of its word and the one at the odd
// address the low half.

- (BOOL)addCheatCode:(NSString *)code type:(int)type {
    // The session tries types 0 to 4 in turn; this console has one format,
    // so it answers on the first and refuses the rest without re-parsing.
    if (!_romLoaded || type != 0 || !code.length) return NO;
    std::vector<MDCheatWrite> writes;
    for (NSString *rawLine in [code componentsSeparatedByString:@"\n"]) {
        NSMutableString *line = [NSMutableString string];
        for (NSUInteger i = 0; i < rawLine.length; i++) {
            unichar c = [rawLine characterAtIndex:i];
            if (c == ' ' || c == ':' || c == '-') continue;
            [line appendFormat:@"%C", c];
        }
        if (!line.length) continue;
        if (line.length != 10 && line.length != 8) return NO;
        unsigned long long parsed = 0;
        NSScanner *scanner = [NSScanner scannerWithString:line];
        if (![scanner scanHexLongLong:&parsed] || !scanner.isAtEnd) return NO;
        const bool twoDigits = (line.length == 8);
        uint32_t address = (uint32_t)(twoDigits ? parsed >> 8 : parsed >> 16) & 0xFFFFFF;
        uint16_t value = (uint16_t)(twoDigits ? (parsed & 0xFF) : (parsed & 0xFFFF));
        if (address < 0xE00000) return NO;
        bool isByte = twoDigits;
        if (!twoDigits && (address & 1)) {
            // An odd address, GPGX's rule: 00YY a byte there, else the word
            // at the even address below (see the comment above).
            if (value <= 0xFF) isByte = true;
            else address &= ~1u;
        }
        writes.push_back({ address & 0xFFFF, value, isByte });
    }
    if (writes.empty()) return NO;
    std::lock_guard<std::mutex> lock(_cheatLock);
    _cheatWrites.insert(_cheatWrites.end(), writes.begin(), writes.end());
    return YES;
}

- (void)clearCheats {
    std::lock_guard<std::mutex> lock(_cheatLock);
    _cheatWrites.clear();
}

/// Called on the emulator thread before every frame.
- (void)applyCheats {
    std::lock_guard<std::mutex> lock(_cheatLock);
    if (_cheatWrites.empty()) return;
    uint16_t *ram = (uint16_t *)retro_get_memory_data(RETRO_MEMORY_SYSTEM_RAM);
    const size_t size = retro_get_memory_size(RETRO_MEMORY_SYSTEM_RAM);
    if (!ram || size < 0x10000) return;
    for (const auto &w : _cheatWrites) {
        uint16_t &word = ram[w.offset >> 1];
        if (!w.isByte) {
            word = w.value;
        } else if (w.offset & 1) {
            word = (uint16_t)((word & 0xFF00) | (w.value & 0xFF));
        } else {
            word = (uint16_t)((word & 0x00FF) | ((w.value & 0xFF) << 8));
        }
    }
}

#pragma mark - Touch screen

- (void)touchScreenAtX:(int)x y:(int)y {}
- (void)touchScreenRelease {}

#pragma mark - Lifecycle

- (void)shutdown {
    if (_romLoaded) {
        [self flushSaveData];
        retro_unload_game();
        _romLoaded = NO;
    }
    if (_coreInitialised) {
        retro_deinit();
        _coreInitialised = NO;
    }
    [self teardownRewind];
    _frameBuffer.clear();
    _audio.Clear();
    if (sBridge == self) sBridge = nil;
}

@end
