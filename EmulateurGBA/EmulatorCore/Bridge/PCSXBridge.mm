//
//  PCSXBridge.mm
//  EmulateurGBA
//
//  ObjC++ implementation bridging PCSX-ReARMed (PlayStation) to Swift.
//
//  HOW THIS CORE IS DRIVEN, AND WHY IT IS THE ONLY ONE DRIVEN THROUGH AN API
//
//  The other three bridges each reach into their core's own C++ types, because
//  that is the only interface those cores offer. PCSX-ReARMed offers a
//  published one: it is built as a libretro core, and `frontend/libretro.c` is
//  the interface its maintainers test and ship. Two facts made that the right
//  side to bind, and both were checked rather than assumed:
//
//   1. Upstream carries a first-class `platform=ios-arm64` target that builds
//      exactly this frontend with the NEON software renderer and no dynarec.
//      It is the configuration RetroArch's own iOS build uses, so it is the one
//      with users on it. Binding libpcsxcore directly would mean maintaining a
//      frontend nobody else runs, against a core whose internals are free to
//      move because nothing outside promises they will not.
//   2. `retro_run()` is exactly one frame, by contract. That is the thing
//      MesenCE had to be PATCHED to do, and it is why Vendor/pcsx-ios/patches/
//      is empty: the API already has the shape our session wants.
//
//  THE ONE COST, and it shapes this whole file: libretro is a global C API with
//  a single implicit instance. There is no core handle to pass around, and the
//  callbacks it hands us are plain function pointers with no user-data
//  argument. So exactly one PCSXBridge may exist at a time and the callbacks
//  reach it through a file-static. That is not a shortcut around a better
//  design; there is no better design available on this side of the API, and one
//  game at a time is what the app does anyway.
//
//  WHAT THE FRONTEND HAS TO GET RIGHT, none of which the core warns about:
//
//  THE PIXEL FORMAT is a CORE OPTION, not a request. `pcsx_rearmed_rgb32_output`
//  defaults to "disabled", which means RGB565, and our Metal view consumes
//  32-bit. Answer that option "enabled" or the picture is garbage. See
//  `kCoreOptions` for the performance note that comes with it.
//
//  MEMORY CARD 2 defaults to "shared", one file behind EVERY PlayStation game.
//  That is the save model this app deliberately rejected: it is the shape where
//  one bad write costs every game at once, in an app whose most reported pain
//  is save loss. It is turned off here, explicitly.
//
//  THE MEMORY MAP is how RetroAchievements gets a working scratchpad. The
//  libretro SAVE_RAM/SYSTEM_RAM pair only exposes main RAM, but RA's
//  PlayStation regions also cover 0x1F800000, and the core publishes all three
//  through SET_MEMORY_MAPS. Capturing that map is what makes the third region
//  readable instead of silently zero.
//

// The core's sources live in a SUBMODULE, so a fresh clone or a pull that did
// not update submodules leaves Vendor/pcsx_rearmed empty and the include below
// fails with "file not found", which says nothing about the cause.
#if !__has_include("libretro.h")
#error "PCSX-ReARMed sources are missing. Run: git submodule update --init Vendor/pcsx_rearmed  (then Vendor/pcsx-ios/build.sh)"
#endif

#import "PCSXBridge.h"

#include <algorithm>   // std::fill, for the geometry-change buffer wipe
#include <atomic>
#include <cstring>
#include <ctime>
#include <mutex>
#include <string>
#include <strings.h>   // strcasecmp, for the core's controller-info names
#include <vector>

#include "libretro.h"

#import <os/log.h>

const NSInteger PS1MaxBufferWidth  = 1024;
const NSInteger PS1MaxBufferHeight = 512;

/// The PlayStation's own output is 4:3. Unlike the SNES and the NES, this is
/// not our reading of what a television did to a square-pixel framebuffer: the
/// core states it in `retro_get_system_av_info`, and the console genuinely
/// varied its pixel aspect per video mode to hit that one shape.
static const CGFloat kPS1DisplayAspect = 4.0 / 3.0;

/// Audio is fixed at 44100 Hz by the hardware and the core never varies it.
static const unsigned int kPS1SampleRate = 44100;

/// About a third of a second of stereo frames. Same purpose as the Mesen ring:
/// the core PUSHES samples during the frame and our audio engine PULLS them on
/// its own clock, so something has to sit between the two.
static const size_t kAudioRingFrames = 16384;

/// Rewind spacing, and the arithmetic behind it, because it is the one number
/// here that a later measurement could reasonably move.
///
/// `retro_serialize_size()` is a FIXED 0x440000 = 4,456,448 bytes, verified by
/// linking the built core and calling it rather than by reading the source
/// comment beside it (which quotes the state's CONTENT size, a range, and not
/// what the API returns).
///
/// At 4.25 MB a snapshot, whole snapshots at five-second spacing cost 4.25 MB
/// per five seconds of history. The Pro rewind maximum is thirty seconds, so a
/// full ring is seven snapshots and about 30 MB, which is the same order as the
/// 24 MB the DS ring already carries. The DS needed DELTAS to get there because
/// its states are 19 MB and seven of those is 133 MB; the PlayStation does not,
/// so it does not pay for the complexity. If the ceiling ever proves too high
/// on an old device, deltas are the known next step and MelonDSBridge has the
/// working implementation.
static const NSInteger kRewindSecondsPerSnapshot = 5;

/// Hard ceiling on the ring, independent of the seconds asked for. The session
/// asks for 35 seconds on every console and gates the usable depth by Pro at
/// rewind time, so without this the PlayStation would allocate an eighth
/// snapshot to serve five seconds nothing can reach.
static const size_t kRewindByteCeiling = 32u * 1024u * 1024u;

/// Diagnostics for bringing this console up.
///
/// DEBUG only, and at error level on purpose: the questions this console still
/// has (how fast is the interpreter on old silicon, does the core take our
/// framebuffer, what does it do at a resolution change) are only answerable
/// from a device, and a line that does not appear in the console is a line
/// nobody can paste back. Release builds log nothing extra.
#if DEBUG
#define PS1Diag(fmt, ...) os_log_error(PCSXLog(), "[PS1] " fmt, ##__VA_ARGS__)
#else
#define PS1Diag(fmt, ...) do { } while (0)
#endif

static os_log_t PCSXLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.retropal.emulateurgba", "pcsx"); });
    return log;
}

#pragma mark - Core options

/// Every core option this bridge answers, and the reason for each answer.
/// Anything not listed here is left to the core's own default on purpose: the
/// list is the set of decisions we are actually making, not a copy of the
/// core's configuration.
struct PCSXOption { const char *key; const char *value; };

static const PCSXOption kCoreOptions[] = {
    // 32-bit output, because EmulatorMetalView consumes 32-bit and the default
    // is RGB565. It is also the honest trade to record: the core's own
    // description warns this doubles memory bandwidth "even in 15bpp modes",
    // and CPU is the binding constraint on this console. RGB565 is the named
    // fallback if the device spike says the bandwidth matters, and it is not
    // free either: it needs a third pixel-format answer in EmulatorBridge,
    // which today is a BOOL covering two.
    { "pcsx_rearmed_rgb32_output", "enabled" },

    // BIOS: the core's own default, restated because it is a product decision
    // and should not rest on a default that could change. "auto" loads a real
    // Sony BIOS from the system directory if there is one and falls back to
    // high-level emulation otherwise, and we answer that there is no system
    // directory, so this resolves to HLE every time. Kept at "auto" rather
    // than pinned: if a BIOS ever becomes something the app offers, the option
    // is already correct and only the directory answer changes.
    { "pcsx_rearmed_bios", "auto" },

    // Memory card 1 is frontend-managed, which hands it to us as a 128 KB
    // RETRO_MEMORY_SAVE_RAM blob. That is what lets a PlayStation memory card
    // travel through the same battery-save path, the same canonical filename
    // and the same iCloud reconciler as every other console's save, instead of
    // being a second save model with its own bugs.
    { "pcsx_rearmed_memcard1", "libretro" },

    // Memory card 2 OFF, and this one overrides the core rather than agreeing
    // with it: the default is "shared", a single file behind every PlayStation
    // game at once. One card per game, invisible, was the decision.
    { "pcsx_rearmed_memcard2", "none" },

    // The 2x internal-resolution enhancement stays OFF. It is why the buffer is
    // sized 1024 wide rather than 640, so enabling it later is a setting; it is
    // also pure extra CPU on the one console where we have none to spare.
    { "pcsx_rearmed_neon_enhancement_enable", "disabled" },

    // No on-screen core messages. The app owns everything the player sees.
    { "pcsx_rearmed_show_bios_bootlogo", "disabled" },

    // How the core is told to flip the DualShock's analog switch. It watches
    // for a BUTTON COMBO rather than offering a call, so the frontend has to
    // speak one, and this names which.
    //
    // L3+R3 specifically, because it is the one combo our input can never
    // produce by accident: the stick clicks are not in `kButtonMap` at all, so
    // no arrangement of touch controls or remapped pad buttons can reach it.
    // The alternatives all start L1+R1, which a player holding both shoulders
    // in a driving game would trip over.
    { "pcsx_rearmed_analog_combo", "l3+r3" },
};

static const char *PCSXOptionValue(const char *key) {
    if (!key) return NULL;
    for (size_t i = 0; i < sizeof(kCoreOptions) / sizeof(kCoreOptions[0]); i++) {
        if (strcmp(kCoreOptions[i].key, key) == 0) return kCoreOptions[i].value;
    }
    return NULL;   // not ours to decide: the core keeps its own default
}

#pragma mark - Audio ring

/// Push-to-pull adapter. The core hands us samples inside `retro_run`; the
/// audio engine reads them from its own thread. Identical in shape to the ring
/// MesenBridge uses, including the overflow rule: drop the OLDEST frame, so a
/// stall costs latency once instead of accumulating a permanent offset.
class PCSXAudioRing {
public:
    PCSXAudioRing() { _ring.resize(kAudioRingFrames * 2, 0); }

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

#pragma mark - Disc

@interface PS1Disc ()
- (instancetype)initWithIndex:(NSUInteger)index
                        label:(NSString *)label
              labelIsFallback:(BOOL)labelIsFallback;
@end

@implementation PS1Disc
- (instancetype)initWithIndex:(NSUInteger)index
                        label:(NSString *)label
              labelIsFallback:(BOOL)labelIsFallback {
    if ((self = [super init])) {
        _index = index;
        _label = [label copy];
        _labelIsFallback = labelIsFallback;
    }
    return self;
}
@end

#pragma mark - Bridge

@interface PCSXBridge ()
/// Called from the C callbacks below, which have no other way back to us.
- (void)handleVideo:(const void *)data width:(unsigned)width height:(unsigned)height pitch:(size_t)pitch;
- (void)handleAudio:(const int16_t *)frames count:(size_t)count;
- (bool)handleEnvironment:(unsigned)cmd data:(void *)data;
- (int16_t)inputStateForPort:(unsigned)port device:(unsigned)device index:(unsigned)index buttonID:(unsigned)buttonID;
@end

/// The single live instance. See the file header: libretro's callbacks carry no
/// user-data pointer, so this is the only route from a C callback back to the
/// object, and it is why two PCSXBridges may not exist at once.
///
/// UNRETAINED rather than __weak, and the reason is the hot path: the input
/// callback fires several times per frame and the audio one at least once, and
/// every read of a __weak variable is a retain/release pair. This is the one
/// console where that is worth avoiding. It is safe because the lifetime is
/// bounded by hand at both ends: `init` sets it, `shutdown` clears it, and
/// `dealloc` calls `shutdown`. The core cannot call back into a dead bridge,
/// because callbacks only ever fire inside `retro_run`, and `shutdown` has
/// already unloaded the game before the object goes away.
static __unsafe_unretained PCSXBridge *sBridge = nil;

static bool PCSXEnvironmentCallback(unsigned cmd, void *data) {
    PCSXBridge *bridge = sBridge;
    return bridge ? [bridge handleEnvironment:cmd data:data] : false;
}

static void PCSXVideoCallback(const void *data, unsigned width, unsigned height, size_t pitch) {
    [sBridge handleVideo:data width:width height:height pitch:pitch];
}

static void PCSXAudioSampleCallback(int16_t left, int16_t right) {
    int16_t frame[2] = { left, right };
    [sBridge handleAudio:frame count:1];
}

static size_t PCSXAudioBatchCallback(const int16_t *data, size_t frames) {
    [sBridge handleAudio:data count:frames];
    return frames;
}

static void PCSXInputPollCallback(void) {
    // Nothing to do: `setKeys:` and the stick setters already deposited the
    // current state, so there is nothing to go and fetch. The core still has to
    // be given a poll function, because it calls it unconditionally.
}

static int16_t PCSXInputStateCallback(unsigned port, unsigned device, unsigned index, unsigned id) {
    PCSXBridge *bridge = sBridge;
    return bridge ? [bridge inputStateForPort:port device:device index:index buttonID:id] : 0;
}

static void PCSXLogCallback(enum retro_log_level level, const char *fmt, ...) {
    if (level < RETRO_LOG_WARN) return;   // the core is chatty at INFO
    // ONE message is suppressed, and only because we are the ones causing it.
    // The core warns about an "unusual pitch" every time it is handed a
    // framebuffer whose stride is wider than the picture, which is precisely
    // the arrangement that lets a console with a changing resolution draw into
    // a fixed texture. It is expected, it is per frame, and at sixty a second
    // it buries every other line in the log.
    if (fmt && strstr(fmt, "unusual pitch")) return;
    char line[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(line, sizeof(line), fmt, args);
    va_end(args);
    os_log_error(PCSXLog(), "[core] %{public}s", line);
}

/// Our bitmask, in `GBAInput` order, mapped to the PlayStation's pad.
///
/// EVERY FACE MAPPING HERE IS POSITIONAL, and that is the whole rule. Our
/// bitmask names buttons by where they sit, which is verifiable rather than a
/// convention we are asserting: MesenBridge maps 0x001 to the Super Nintendo's
/// A, and that is the RIGHT button of the diamond. libretro names its pad the
/// same way, and PCSX-ReARMed's own `retro_psx_map` turns JOYPAD_A into CIRCLE,
/// which is the right button of a PlayStation pad. So right meets right, bottom
/// meets bottom, and the mapping is the identity.
///
/// The first version of this table swapped A and B, on the reasoning that our A
/// is the "confirm" button and a Western PlayStation confirms with Cross. That
/// is a fact about GAMES, not about hardware, and acting on it would have put
/// Cross where the pad prints Circle. The player reads the symbol on the
/// button, which `PS1TouchControlsView` draws; they do not read our enum.
static const struct { uint32_t ours; unsigned theirs; } kButtonMap[] = {
    { 0x001, RETRO_DEVICE_ID_JOYPAD_A      },   // right  -> Circle
    { 0x002, RETRO_DEVICE_ID_JOYPAD_B      },   // bottom -> Cross
    { 0x004, RETRO_DEVICE_ID_JOYPAD_SELECT },
    { 0x008, RETRO_DEVICE_ID_JOYPAD_START  },
    { 0x010, RETRO_DEVICE_ID_JOYPAD_RIGHT  },
    { 0x020, RETRO_DEVICE_ID_JOYPAD_LEFT   },
    { 0x040, RETRO_DEVICE_ID_JOYPAD_UP     },
    { 0x080, RETRO_DEVICE_ID_JOYPAD_DOWN   },
    { 0x100, RETRO_DEVICE_ID_JOYPAD_R      },   // R      -> R1
    { 0x200, RETRO_DEVICE_ID_JOYPAD_L      },   // L      -> L1
    { 0x400, RETRO_DEVICE_ID_JOYPAD_X      },   // top    -> Triangle
    { 0x800, RETRO_DEVICE_ID_JOYPAD_Y      },   // left   -> Square
    { 0x1000, RETRO_DEVICE_ID_JOYPAD_L2    },   // the two the PlayStation adds
    { 0x2000, RETRO_DEVICE_ID_JOYPAD_R2    },
    // The stick clicks. Absent until 2026-08-24, which meant no player could
    // press them by any route: Tomb Raider 3's fire button and Ape Escape's
    // crawl were unreachable. The only thing that had ever sent them was
    // `pressAnalogModeButton`, synthesising the analog-toggle combo.
    { 0x4000, RETRO_DEVICE_ID_JOYPAD_L3    },
    { 0x8000, RETRO_DEVICE_ID_JOYPAD_R3    },
};

static int16_t PCSXClampAxis(float v) {
    if (v >  1.0f) v =  1.0f;
    if (v < -1.0f) v = -1.0f;
    return (int16_t)(v * 32767.0f);
}

@implementation PCSXBridge {
    BOOL _romLoaded;
    BOOL _coreInitialised;
    std::string _romPath;

    /// The session texture. Allocated once at the core's maximum; the live
    /// picture occupies its top-left corner. See PCSXBridge.h.
    std::vector<uint32_t> _frameBuffer;
    /// What the game is actually drawing right now, in pixels. Moves with the
    /// game, which is the thing no other console here does.
    std::atomic<uint32_t> _liveWidth;
    std::atomic<uint32_t> _liveHeight;
    /// Set when the core accepted our buffer through
    /// GET_CURRENT_SOFTWARE_FRAMEBUFFER, so `handleVideo:` knows the pixels are
    /// already where they belong and there is nothing to copy.
    BOOL _coreRendersInPlace;

    PCSXAudioRing _audio;

    /// Input. The bitmask is the touch and controller button state; the sticks
    /// are physical-controller only and switch the emulated pad to a DualShock.
    std::atomic<uint32_t> _buttons;
    std::atomic<int16_t> _stickLX, _stickLY, _stickRX, _stickRY;
    /// Whether the emulated pad is a DualShock. Atomic, and applied on the
    /// EMULATOR thread rather than where it is set: a stick moves on the UI
    /// thread, and `retro_set_controller_port_device` rewrites the core's pad
    /// table and calls `padChanged()`, which is not something to do underneath a
    /// running `retro_run`. Every other input here already obeys that rule --
    /// `setKeys:` and the stick setters only deposit values, and the core reads
    /// them from inside its own frame -- so the pad TYPE follows it too.
    std::atomic<bool> _analogPadActive;
    std::atomic<bool> _padTypeDirty;

    /// The geometry the core last asked our zero-copy buffer for, so the buffer
    /// can be wiped exactly when it changes. See the framebuffer case.
    unsigned _fbGeometryWidth;
    unsigned _fbGeometryHeight;

    /// The device id the core wants for a DualShock, learned from the core.
    ///
    /// This is NOT `RETRO_DEVICE_ANALOG`, and passing that is what unplugged the
    /// pad. libretro lets a core SUBCLASS the generic device types, and
    /// PCSX-ReARMed does: its DualShock is `RETRO_DEVICE_SUBCLASS(ANALOG, 1)`,
    /// and `retro_set_controller_port_device` sends everything it does not
    /// recognise to `default: in_type[port] = PSE_PAD_TYPE_NONE`. So the generic
    /// constant does not select an analog pad, it selects NO PAD AT ALL, for the
    /// rest of the session.
    ///
    /// Seeded with the subclass expression and then OVERWRITTEN from the list
    /// the core publishes through `SET_CONTROLLER_INFO`, because those ids live
    /// in the core's `libretro.c` rather than in any header we can include: a
    /// hard-coded copy would be a private constant we are not allowed to notice
    /// changing. The core names this entry "dualshock" and we match on that.
    unsigned _dualShockDevice;

    int _speedMultiplier;

    /// See `framesPerSecond`. NTSC discs run at 59.94 and PAL ones at 50, and
    /// the core is the only thing that knows which this disc is.
    double _framesPerSecond;

    /// Memory card 1, mirrored to the app's canonical save path, and the
    /// directory it lives in (which is what the core asks for by name).
    std::string _savePath;
    std::string _saveDirectory;

    /// Frames left to hold the analog-toggle combo. See `pressAnalogModeButton`.
    std::atomic<int> _analogComboFrames;

    /// Performance, for the one question this console still has.
    uint64_t _perfWindowStartNs;
    uint64_t _perfFrames;
    uint64_t _perfRunNs;
    uint32_t _lastLoggedWidth;
    uint32_t _lastLoggedHeight;

    /// The core's published memory map, captured for RetroAchievements.
    std::vector<retro_memory_descriptor> _memoryMap;

    /// Multi-disc, captured from the core's disk-control interface.
    retro_disk_control_ext_callback _diskControl;
    BOOL _hasDiskControl;

    /// libretro identifies a cheat by an INDEX the frontend assigns, not by its
    /// text, and offers no way to ask what is currently applied. So the bridge
    /// counts: each `addCheatCode:` takes the next index, and `clearCheats`
    /// resets both the core and the counter. That is exactly the
    /// clear-then-re-add contract the app's cheat manager already follows.
    unsigned _cheatCount;

    /// Rewind: whole states in a ring, newest last. See kRewindSecondsPerSnapshot.
    std::vector<std::vector<uint8_t>> _rwStates;
    NSInteger _rwCapacity;
    NSInteger _rwStored;
    NSInteger _rwNewest;
    NSInteger _rwFrameCounter;
    BOOL _rwSnapshotDue;
}

- (instancetype)init {
    if ((self = [super init])) {
        // libretro has ONE global core instance, so a second bridge cannot
        // coexist with a first. This used to assert, and asserting was the
        // wrong call: it turned a recoverable situation into a crash, and the
        // situation was real (SwiftUI re-ran the view body that built the
        // session, so a re-render constructed a second core mid-game).
        //
        // The cause is fixed where it belongs, in the launch path, which now
        // builds one session per launch. This stays as the backstop and RECOVERS
        // rather than dies: the older bridge is by definition the one being
        // discarded, so shutting it down is both safe and correct. Loud, because
        // if it ever fires again something upstream has regressed.
        if (sBridge != nil && sBridge != self) {
            os_log_error(PCSXLog(),
                         "[PS1] a second bridge was created; shutting the previous one down. "
                         "Something upstream is building a core more than once.");
            [sBridge shutdown];
        }
        sBridge = self;

        _romLoaded = NO;
        _coreInitialised = NO;
        _coreRendersInPlace = NO;
        _analogPadActive = false;
        _padTypeDirty = false;
        _fbGeometryWidth = 0;
        _fbGeometryHeight = 0;
        _dualShockDevice = RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_ANALOG, 1);
        _speedMultiplier = 1;
        _framesPerSecond = 59.94;
        _liveWidth = 320;
        _liveHeight = 240;
        _buttons = 0;
        _stickLX = _stickLY = _stickRX = _stickRY = 0;
        _hasDiskControl = NO;
        memset(&_diskControl, 0, sizeof(_diskControl));
        _cheatCount = 0;
        _analogComboFrames = 0;
        _perfWindowStartNs = 0;
        _perfFrames = 0;
        _perfRunNs = 0;
        _lastLoggedWidth = 0;
        _lastLoggedHeight = 0;
        _rwCapacity = _rwStored = _rwFrameCounter = 0;
        _rwNewest = -1;
        _rwSnapshotDue = NO;

        _frameBuffer.assign((size_t)(PS1MaxBufferWidth * PS1MaxBufferHeight), 0);

        // The environment callback must be installed BEFORE retro_init, because
        // the core reads options and directories during initialisation.
        retro_set_environment(PCSXEnvironmentCallback);
        retro_set_video_refresh(PCSXVideoCallback);
        retro_set_audio_sample(PCSXAudioSampleCallback);
        retro_set_audio_sample_batch(PCSXAudioBatchCallback);
        retro_set_input_poll(PCSXInputPollCallback);
        retro_set_input_state(PCSXInputStateCallback);
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
- (NSInteger)bufferStride { return PS1MaxBufferWidth; }
- (NSInteger)totalBufferHeight { return (NSInteger)_liveHeight.load(); }
/// The one console where this is not `totalBufferHeight`. See EmulatorBridge.h.
- (NSInteger)maxBufferHeight { return PS1MaxBufferHeight; }
- (BOOL)hasTouchScreen { return NO; }
- (CGFloat)displayAspect { return kPS1DisplayAspect; }

/// libretro's XRGB8888 is 0x00RRGGBB packed in a host uint32, so on a
/// little-endian machine the bytes in memory are B, G, R, X. That is the same
/// order melonDS and Mesen already report, which is what the renderer's
/// `.bgra8Unorm` path expects.
- (BOOL)usesBGRAPixelOrder { return YES; }

/// The core knows whether the disc is NTSC or PAL and reports the real rate,
/// so a PAL game paces at 50 rather than playing a fifth too fast. Before a
/// disc is loaded it answers 60, which is only ever used for one frame.
/// Cached, not asked. `rewindAppend` needs it on EVERY frame, and asking the
/// core each time means building a `retro_system_av_info` sixty times a second
/// on the one console with no cycles to spare. It is refreshed at load and
/// whenever the core announces new timing, which is the only time it moves.
- (double)framesPerSecond {
    return _framesPerSecond > 1.0 ? _framesPerSecond : 59.94;
}

- (void)refreshTiming {
    if (!_coreInitialised) return;
    retro_system_av_info info;
    memset(&info, 0, sizeof(info));
    retro_get_system_av_info(&info);
    if (info.timing.fps > 1.0) _framesPerSecond = info.timing.fps;
}

#pragma mark - Environment

- (bool)handleEnvironment:(unsigned)cmd data:(void *)data {
    switch (cmd) {

    // --- what we answer -----------------------------------------------------

    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        auto *var = (retro_variable *)data;
        if (!var) return false;
        const char *value = PCSXOptionValue(var->key);
        if (!value) return false;      // the core keeps its own default
        var->value = value;
        return true;
    }

    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
        // Our answers are compile-time constants, so they never change under
        // the core and it never has to re-read them.
        if (data) *(bool *)data = false;
        return true;

    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
        // Accept 32-bit only. Refusing anything else is not a preference: the
        // renderer's texture is .bgra8Unorm, so a 16-bit frame would be read
        // as half-width garbage rather than as wrong colours, and a loud
        // refusal here beats a silent misread there.
        auto fmt = *(enum retro_pixel_format *)data;
        if (fmt == RETRO_PIXEL_FORMAT_XRGB8888) {
            PS1Diag("pixel format XRGB8888 accepted");
            return true;
        }
        os_log_error(PCSXLog(), "core asked for pixel format %d, refused (we take XRGB8888)", (int)fmt);
        return false;
    }

    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
        // Deliberately unanswered, and the case stays rather than falling
        // through to `default:` so that this is a decision on the record and
        // not an omission.
        //
        // The system directory is where the core would look for a real Sony
        // BIOS. We do not offer one: high-level emulation is the thing that
        // always works, there is no path by which a BIOS file could reach the
        // app, and a setting that invited one would tell every player their
        // console is missing a part. Refusing is the honest answer to a
        // question we have chosen not to have.
        *(const char **)data = NULL;
        return false;

    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
        // Card 1 is frontend-managed, so the core writes no save file of its
        // own and nothing depends on this. It is still answered when we know
        // it, because refusing made the core log "Memory card saving might not
        // work" on every launch, which is alarming and untrue.
        *(const char **)data = _saveDirectory.empty() ? NULL : _saveDirectory.c_str();
        return !_saveDirectory.empty();

    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
        // Yes: a NULL frame means "the picture did not change", which is both
        // free and a precondition for the in-place framebuffer below.
        if (data) *(bool *)data = true;
        return true;

    case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
        // Yes: the core then asks for the whole pad in ONE call per frame
        // instead of one call per button. Free, on a console where the CPU
        // budget is the thing we are worried about.
        if (data) *(bool *)data = true;
        return true;

    case RETRO_ENVIRONMENT_GET_CURRENT_SOFTWARE_FRAMEBUFFER: {
        // The zero-copy path, and it is worth having: at 1024x512 a copied
        // frame is 2 MB, which is 120 MB/s of pure memmove at 60 fps on the one
        // console with no CPU headroom. Handing the core our own buffer lets it
        // draw straight into the texture's source.
        //
        // The pitch we hand back is the FULL buffer width, not the picture's,
        // which is how the live picture lands in the top-left corner with the
        // rest of the rows untouched. libretro allows it (the core logs it as
        // "unusual" and honours it), and it is the whole trick that makes a
        // variable-resolution console work against a fixed texture.
        auto *fb = (retro_framebuffer *)data;
        if (!fb) return false;
        if (fb->width > (unsigned)PS1MaxBufferWidth || fb->height > (unsigned)PS1MaxBufferHeight) {
            _coreRendersInPlace = NO;
            return false;
        }
        // WIPE THE BUFFER WHENEVER THE GEOMETRY CHANGES, and do it here rather
        // than when the frame arrives, because here is the last moment before
        // the core draws.
        //
        // The core clears the frame itself on a mode change, but only for the
        // width it thinks it has: `vout_flip` takes the `dstride != ll` branch
        // whenever the pitch is unusual, and ours always is, and that branch
        // clears the DRAWN height rather than the display height. The rows
        // between the picture's bottom edge and the bottom of the display area
        // are therefore never cleared by anyone. A PlayStation game centres a
        // shorter picture inside a taller display area all the time, so those
        // rows are visible, and after a 640x480 FMV they would hold whatever
        // the FMV left there.
        //
        // Once per mode change, not per frame: this is a couple of megabytes at
        // a scene transition, against a console with no CPU to spare.
        if (fb->width != _fbGeometryWidth || fb->height != _fbGeometryHeight) {
            _fbGeometryWidth = fb->width;
            _fbGeometryHeight = fb->height;
            std::fill(_frameBuffer.begin(), _frameBuffer.end(), 0u);
        }
        fb->data         = _frameBuffer.data();
        fb->pitch        = (size_t)PS1MaxBufferWidth * sizeof(uint32_t);
        fb->format       = RETRO_PIXEL_FORMAT_XRGB8888;
        fb->memory_flags = 0;
        if (!_coreRendersInPlace) {
            PS1Diag("zero-copy framebuffer taken by the core (%ux%u into %ldx%ld)",
                    fb->width, fb->height, (long)PS1MaxBufferWidth, (long)PS1MaxBufferHeight);
        }
        _coreRendersInPlace = YES;
        return true;
    }

    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: {
        auto *cb = (retro_log_callback *)data;
        if (cb) cb->log = PCSXLogCallback;
        return true;
    }

    case RETRO_ENVIRONMENT_SET_MEMORY_MAPS: {
        // RetroAchievements' third PlayStation region is the scratchpad at
        // 0x1F800000, which the libretro SYSTEM_RAM handle does not cover.
        // The core publishes all three areas here, so this is what makes
        // scratchpad achievements work instead of silently reading zero.
        auto *map = (const retro_memory_map *)data;
        _memoryMap.clear();
        if (map && map->descriptors) {
            _memoryMap.assign(map->descriptors, map->descriptors + map->num_descriptors);
        }
        return true;
    }

    case RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION:
        if (data) *(unsigned *)data = 1;
        return true;

    case RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE: {
        auto *cb = (const retro_disk_control_ext_callback *)data;
        if (cb) { _diskControl = *cb; _hasDiskControl = YES; }
        else    { memset(&_diskControl, 0, sizeof(_diskControl)); _hasDiskControl = NO; }
        return true;
    }

    case RETRO_ENVIRONMENT_SET_GEOMETRY:
        // The geometry the core is announcing is the same one it passes to
        // every `video_refresh`, and that is where it is read. Acknowledged
        // rather than refused, so the core does not log an error for something
        // we do handle.
        return true;

    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
        // This one carries TIMING as well as geometry, and timing is the half
        // we cannot read anywhere else: a PAL disc runs at 50 and would play a
        // fifth too fast, with a fifth more audio per second than the output
        // can take.
        if (data) {
            const auto *info = (const retro_system_av_info *)data;
            if (info->timing.fps > 1.0) _framesPerSecond = info->timing.fps;
        }
        return true;

    // --- accepted and ignored, each for its own reason ----------------------

    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
        // Human-readable button names for a remapping UI the frontend owns.
        // Ours is built from ControllerMapping, not from the core.
        return true;

    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO: {
        // The pad types the core supports, and the ONLY place the DualShock's
        // real device id is available to us: the ids are `#define`d inside the
        // core's `libretro.c`, not in a header. We choose between exactly two of
        // them (digital, DualShock) and choose by whether analog has moved.
        const struct retro_controller_info *ports =
            (const struct retro_controller_info *)data;
        if (!ports || !ports->types) return true;
        for (unsigned i = 0; i < ports->num_types; i++) {
            const char *name = ports->types[i].desc;
            if (name && strcasecmp(name, "dualshock") == 0) {
                _dualShockDevice = ports->types[i].id;
                PS1Diag("DualShock device id = %u", _dualShockDevice);
                break;
            }
        }
        return true;
    }

    case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL:
    case RETRO_ENVIRONMENT_SET_MINIMUM_AUDIO_LATENCY:
    case RETRO_ENVIRONMENT_SET_AUDIO_BUFFER_STATUS_CALLBACK:
        // Hints to a frontend that paces and buffers on the core's advice.
        // Ours paces itself, for all four cores, so these are noted and
        // dropped rather than half-honoured.
        return true;

    // NOT handled, and deliberately not invented:
    // RETRO_ENVIRONMENT_SET_SAVE_STATE_DISABLE_UNDO. The core does send it, but
    // only from inside an `#ifdef _3DS`, and it is absent from the libretro.h
    // we vendor — the core defines its own 0x800005 fallback when the header
    // lacks it. Writing that number here would mean hard-coding a private
    // constant for a call this platform cannot receive. This list was built by
    // reading which environment calls the core makes, which is the right method
    // and has this one blind spot: the core can name a constant its own header
    // does not define.

    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK:
        // Show and hide options in a settings menu the core assumes exists.
        // There is no core-options menu in this app by design: the options are
        // decisions we made once, in kCoreOptions, with the reasons written down.
        return true;

    case RETRO_ENVIRONMENT_SET_MESSAGE:
    case RETRO_ENVIRONMENT_SET_MESSAGE_EXT:
        // The core wants to put text on screen. It does not get to: every
        // string the player reads is ours and is localized in fifteen
        // languages. Anything worth surfacing arrives through the log instead.
        return true;

    case RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION:
        if (data) *(unsigned *)data = 0;
        return true;

    // --- declined -----------------------------------------------------------

    case RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE:
        // Declining is what makes the core stop asking. Controller haptics are
        // a real thing to add later, and it would be through GCController's own
        // haptics rather than this.
        return false;

    case RETRO_ENVIRONMENT_GET_VFS_INTERFACE:
        // The core falls back to stdio, which is correct inside our sandbox.
        return false;

    case RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE:
        // The version-1 interface, offered only if we had answered 0 to the
        // version query above. We answered 1, so this is the core covering a
        // case that cannot happen; taking it would leave two disc interfaces
        // registered and one of them stale.
        return false;

    default:
        return false;
    }
}

#pragma mark - ROM management

- (void)setSaveDirectory:(NSString *)path {
    _saveDirectory = path.length ? std::string(path.fileSystemRepresentation) : std::string();
}

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
    info.path = _romPath.c_str();
    // data stays NULL on purpose: the core declares need_fullpath, so it opens
    // the disc image itself. That is what we want for a format where one "game"
    // can be a cue pointing at a bin, or an m3u pointing at three of them.
    info.data = NULL;
    info.size = 0;

    if (!retro_load_game(&info)) {
        // Unload after a FAILED load, which reads like a contradiction and is
        // not: libretro's contract is that the core may have taken resources
        // before deciding it cannot use this file, and a disc gives it far more
        // chances to get partway than a cartridge ever did. Leaving that behind
        // means the next load, or `retro_deinit` at shutdown, works on a core
        // holding half a game.
        //
        // Found on device: an archive was imported as its fifty-eight separate
        // parts, and launching one of the audio tracks crashed the app rather
        // than saying it could not be read.
        retro_unload_game();
        os_log_error(PCSXLog(), "retro_load_game failed for %{public}s", path.lastPathComponent.UTF8String);
        return NO;
    }

    _romLoaded = YES;
    _coreRendersInPlace = NO;
    // Applied directly rather than flagged: this runs during the load, before
    // the emulator thread's run loop exists, and the first frame has to find
    // the pad already plugged in.
    _analogPadActive = false;
    [self applyPadType];
    [self invalidateRewind];
    _audio.Clear();

    retro_system_av_info av;
    memset(&av, 0, sizeof(av));
    retro_get_system_av_info(&av);
    _liveWidth  = av.geometry.base_width  ? av.geometry.base_width  : 320;
    _liveHeight = av.geometry.base_height ? av.geometry.base_height : 240;
    if (av.timing.fps > 1.0) _framesPerSecond = av.timing.fps;

    [self loadMemoryCard];

    PS1Diag("loaded %{public}s | %ux%u | %.2f fps (%{public}s) | state %zu bytes | HLE BIOS",
            path.lastPathComponent.UTF8String,
            _liveWidth.load(), _liveHeight.load(), _framesPerSecond,
            _framesPerSecond < 55 ? "PAL" : "NTSC",
            retro_serialize_size());
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
    _saveDirectory = path.length
        ? std::string(path.stringByDeletingLastPathComponent.fileSystemRepresentation)
        : std::string();
    // Called before `reset` by the session, and on this console it is also
    // called AFTER loadROM, so the card is read here as well as at load: a card
    // read before the path is known would be an empty one written back over the
    // player's saves.
    [self loadMemoryCard];
}

/// Memory card 1 as the app's canonical battery save.
///
/// In frontend-managed mode the core exposes the card as a plain 128 KB block
/// through RETRO_MEMORY_SAVE_RAM and never touches a file, so the card is read
/// and written exactly like a cartridge's save RAM. Everything the app already
/// does for saves then applies unchanged: the canonical filename, the export in
/// Game Details, the iCloud mirror and its live-session guard.
- (void)loadMemoryCard {
    if (!_romLoaded || _savePath.empty()) return;
    void *card = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t size = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!card || !size) return;

    NSData *stored = [NSData dataWithContentsOfFile:@(_savePath.c_str())];
    if (!stored) {
        PS1Diag("memory card: none on disk yet, the core formatted a blank %zu-byte one", size);
        return;
    }
    if (stored.length != size) {
        os_log_error(PCSXLog(), "memory card is %lu bytes, expected %zu - left alone",
                     (unsigned long)stored.length, size);
        return;
    }
    memcpy(card, stored.bytes, size);
    PS1Diag("memory card: loaded %lu bytes", (unsigned long)stored.length);
}

- (void)flushSaveData {
    if (!_romLoaded || _savePath.empty()) return;
    const void *card = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t size = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!card || !size) return;
    NSData *data = [NSData dataWithBytes:card length:size];
    NSError *error = nil;
    if (![data writeToFile:@(_savePath.c_str()) options:NSDataWritingAtomic error:&error]) {
        os_log_error(PCSXLog(), "memory card write failed: %{public}s",
                     error.localizedDescription.UTF8String);
    }
}

#pragma mark - Emulation

- (void)runFrame {
    if (!_romLoaded) return;
    // The pad type is changed HERE, on this thread, and only between frames.
    if (_padTypeDirty.exchange(false)) [self applyPadType];
    if (_analogComboFrames > 0) _analogComboFrames--;
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
/// Report emulated frames per second and the time one frame costs, once every
/// two seconds.
///
/// This is the measurement the whole PlayStation plan left open: the App Store
/// forbids JIT, so this core runs its interpreter, and nobody publishes what
/// that costs on an A11. `avg` is the honest half. Frames per second is capped
/// by the display and by our own pacing, so a game that is struggling can still
/// read near 60 for a moment; the milliseconds a frame actually takes cannot
/// flatter itself. Above about 16.6 ms the console cannot hold full speed.
- (void)notePerformance:(uint64_t)elapsedNs at:(uint64_t)nowNs {
    if (_perfWindowStartNs == 0) { _perfWindowStartNs = nowNs; return; }
    _perfFrames++;
    _perfRunNs += elapsedNs;

    const uint64_t window = nowNs - _perfWindowStartNs;
    if (window < 2000000000ULL) return;

    const double seconds = (double)window / 1e9;
    const double fps = (double)_perfFrames / seconds;
    const double avgMs = _perfFrames ? (double)_perfRunNs / (double)_perfFrames / 1e6 : 0;
    PS1Diag("%.1f fps emulated | %.2f ms per frame | budget %.2f ms | %{public}s",
            fps, avgMs, 1000.0 / _framesPerSecond,
            avgMs * _framesPerSecond > 1000.0 ? "OVER BUDGET" : "within budget");
    _perfWindowStartNs = nowNs;
    _perfFrames = 0;
    _perfRunNs = 0;
}
#endif

// `awaitDisplayFrame` is deliberately NOT implemented, and it is the optional
// method precisely so this can be true: libretro calls `video_refresh`
// synchronously from inside `retro_run`, so by the time the call above returns
// the picture is already in our buffer. MesenCE needs the wait because its PPU
// parks the finished frame on a decode thread; nothing here does.

- (void)setKeys:(uint32_t)keys {
    _buttons = keys;
}

#pragma mark - Input

- (int16_t)inputStateForPort:(unsigned)port device:(unsigned)device index:(unsigned)index buttonID:(unsigned)buttonID {
    if (port != 0) return 0;   // one pad; a second port is a later feature

    const uint32_t keys = _buttons.load();

    // While the ANALOG press is in flight the pad reports EXACTLY the combo and
    // nothing else, because the core compares for equality: a face button held
    // at the same moment would make the mask "combo plus something" and the
    // toggle would silently not happen.
    if (_analogComboFrames > 0 && device == RETRO_DEVICE_JOYPAD) {
        const int16_t combo = (int16_t)((1 << RETRO_DEVICE_ID_JOYPAD_L3)
                                        | (1 << RETRO_DEVICE_ID_JOYPAD_R3));
        if (buttonID == RETRO_DEVICE_ID_JOYPAD_MASK) return combo;
        return (buttonID == RETRO_DEVICE_ID_JOYPAD_L3
                || buttonID == RETRO_DEVICE_ID_JOYPAD_R3) ? 1 : 0;
    }

    if (device == RETRO_DEVICE_JOYPAD) {
        if (buttonID == RETRO_DEVICE_ID_JOYPAD_MASK) {
            // The whole pad in one answer, which is what GET_INPUT_BITMASKS
            // bought us.
            int16_t mask = 0;
            for (auto &m : kButtonMap) if (keys & m.ours) mask |= (1 << m.theirs);
            return mask;
        }
        for (auto &m : kButtonMap) if (buttonID == m.theirs) return (keys & m.ours) ? 1 : 0;
        return 0;
    }

    if (device == RETRO_DEVICE_ANALOG) {
        if (index == RETRO_DEVICE_INDEX_ANALOG_LEFT) {
            return buttonID == RETRO_DEVICE_ID_ANALOG_X ? _stickLX.load() : _stickLY.load();
        }
        if (index == RETRO_DEVICE_INDEX_ANALOG_RIGHT) {
            return buttonID == RETRO_DEVICE_ID_ANALOG_X ? _stickRX.load() : _stickRY.load();
        }
        // RETRO_DEVICE_INDEX_ANALOG_BUTTON: pressure-sensitive face buttons,
        // which no game we care about needs and no controller we support sends.
        return 0;
    }

    return 0;
}

- (void)setLeftStickX:(float)x y:(float)y {
    _stickLX = PCSXClampAxis(x);
    _stickLY = PCSXClampAxis(y);
    [self noteAnalogInput];
}

- (void)setRightStickX:(float)x y:(float)y {
    _stickRX = PCSXClampAxis(x);
    _stickRY = PCSXClampAxis(y);
    [self noteAnalogInput];
}

/// The pad's ANALOG switch, expressed the only way the core accepts.
///
/// It has no call for this: `update_input` watches the button mask for an exact
/// combo and calls `padToggleAnalog` when it sees one. So the press becomes a
/// few frames during which our mask IS that combo and nothing else, which is
/// what "exact" means here. Three frames rather than one because the core polls
/// once per frame and a single frame would be lost to any hitch; it latches
/// `in_dualshock_toggling` after the first, so holding longer cannot toggle
/// twice.
///
/// The pad is switched to a DualShock first, and it really is first: the switch
/// is applied at the top of `runFrame`, before that frame polls input, so the
/// combo is never seen by a digital pad. The toggle is ignored on one, which
/// would make the button quietly do nothing for the exact player it exists for:
/// someone on touch controls, who has no stick to move and so never triggers
/// the automatic switch.
- (void)pressAnalogModeButton {
    if (!_romLoaded) return;
    if (!_analogPadActive.exchange(true)) _padTypeDirty = true;
    _analogComboFrames = 3;
    PS1Diag("ANALOG pressed");
}

/// The emulated pad becomes a DualShock the first time a stick moves, and stays
/// one for the session.
///
/// Switching on first movement rather than on "a controller is connected" is
/// deliberate. A DualShock reports itself differently on the wire, and a
/// handful of games behave worse when one is present than when it is not
/// (the digital pad is what they were tested against). A player who never
/// touches a stick therefore never gets a pad they did not ask for, and a
/// player who does gets the one their game needs, without a setting.
- (void)noteAnalogInput {
    if (!_romLoaded) return;
    if (!_analogPadActive.exchange(true)) _padTypeDirty = true;
}

- (void)applyPadType {
    if (!_romLoaded) return;
    // RETRO_DEVICE_JOYPAD is right for the digital pad: the core matches it
    // explicitly. Only the analog side needs the subclass.
    retro_set_controller_port_device(0, _analogPadActive.load() ? _dualShockDevice
                                                                : RETRO_DEVICE_JOYPAD);
}

#pragma mark - Video

- (void)handleVideo:(const void *)data width:(unsigned)width height:(unsigned)height pitch:(size_t)pitch {
    if (width == 0 || height == 0) return;
    if (width > (unsigned)PS1MaxBufferWidth)   width  = (unsigned)PS1MaxBufferWidth;
    if (height > (unsigned)PS1MaxBufferHeight) height = (unsigned)PS1MaxBufferHeight;

    if (width != _lastLoggedWidth || height != _lastLoggedHeight) {
        PS1Diag("resolution %ux%u -> %ux%u", _lastLoggedWidth, _lastLoggedHeight, width, height);
        _lastLoggedWidth = width;
        _lastLoggedHeight = height;
    }
    _liveWidth  = width;
    _liveHeight = height;

    // NULL means "the picture did not change", which we asked for by answering
    // GET_CAN_DUPE. The buffer already holds the right pixels.
    if (!data) return;

    // Already ours: the core drew straight into the buffer through
    // GET_CURRENT_SOFTWARE_FRAMEBUFFER and there is nothing to move. The
    // pointer comparison is the check rather than the flag alone, because the
    // core is allowed to fall back to its own buffer at any frame and this
    // notices when it does.
    if (data == _frameBuffer.data()) return;

    const uint8_t *src = (const uint8_t *)data;
    uint32_t *dst = _frameBuffer.data();
    const size_t rowBytes = (size_t)width * sizeof(uint32_t);
    for (unsigned y = 0; y < height; y++) {
        memcpy(dst + (size_t)y * PS1MaxBufferWidth, src + (size_t)y * pitch, rowBytes);
    }
}

- (const uint32_t *)frameBuffer {
    return _romLoaded ? _frameBuffer.data() : NULL;
}

/// A still of the live picture, AT THE SHAPE IT IS DISPLAYED IN, which on this
/// console is not the shape of its pixels.
///
/// Every other console here has square pixels, so the framebuffer's own ratio
/// was the picture's ratio and a raw capture was already right. The PlayStation
/// does not: it draws 256x224, 320x240, 368x240, 512x240 and 640x480 and shows
/// all of them as 4:3, varying the pixel aspect per video mode to do it. A raw
/// 512x240 capture handed to a thumbnail is a picture more than twice as wide as
/// it is tall, and every surface that shows one (the save-slot rows, the library
/// cover fallback, the widget, the share cards) inherits the error from here.
///
/// So the still is rescaled once, at the source, and the app keeps its single
/// answer to "what did this frame look like". The box is the SMALLEST 4:3 one
/// that contains the picture, so the correction is always an upscale along one
/// axis and never throws away a column the game drew.
- (CGImageRef)createFrameImage {
    if (!_romLoaded) return NULL;
    const uint32_t w = _liveWidth.load();
    const uint32_t h = _liveHeight.load();
    if (!w || !h) return NULL;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    // The stride is the FULL buffer width, not the picture's, so the context
    // reads the live sub-rect out of the corner it lives in.
    CGContextRef ctx = CGBitmapContextCreate(_frameBuffer.data(), w, h, 8,
                                             (size_t)PS1MaxBufferWidth * sizeof(uint32_t),
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
        if (aspect > 0) {
            const size_t byAspect = (size_t)llround((double)w / aspect);
            if (byAspect >= h) outH = byAspect;                       // widen vertically
            else               outW = (size_t)llround((double)h * aspect);
        }
        if (outW != w || outH != h) {
            CGContextRef scaled = CGBitmapContextCreate(NULL, outW, outH, 8, 0, colorSpace,
                                                        kCGBitmapByteOrder32Little
                                                        | kCGImageAlphaNoneSkipFirst);
            if (scaled) {
                // No interpolation: this is a pixel picture being stretched, and
                // the app draws it with `.interpolation(.none)` everywhere else.
                // Smoothing here would make the still softer than the game.
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
    // A loaded state is a different timeline, so every snapshot in the ring
    // describes a past that no longer leads here. Invalidating in the BRIDGE
    // and not at the call sites is the lesson the DS shipped as a bug: the
    // session's frame counter gates how FAR back you may ask, never which
    // timeline the answer comes from.
    [self invalidateRewind];

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return NO;
    return retro_unserialize(data.bytes, data.length) ? YES : NO;
}

#pragma mark - Memory (RetroAchievements)

/// Reads through the map the core published, which covers all three regions
/// RetroAchievements defines for the PlayStation: main RAM at 0x00000000,
/// the scratchpad at 0x1F800000, and the BIOS ROM at 0x1FC00000. `select` and
/// `disconnect` are ignored on purpose: they describe the mirrors the console
/// exposes the same memory at, and rcheevos always asks at the canonical
/// address.
- (NSInteger)readMemoryAtAddress:(uint32_t)address into:(uint8_t *)buffer length:(NSInteger)length {
    if (!_romLoaded || !buffer || length <= 0) return 0;

    for (const auto &d : _memoryMap) {
        if (!d.ptr || !d.len) continue;
        if (address < d.start || address >= d.start + d.len) continue;
        const size_t offset = (size_t)(address - d.start) + d.offset;
        const size_t available = d.len - (size_t)(address - d.start);
        const size_t count = MIN((size_t)length, available);
        memcpy(buffer, (const uint8_t *)d.ptr + offset, count);
        return (NSInteger)count;
    }

    // Falling back to the libretro SYSTEM_RAM handle covers the case where a
    // future core stops publishing a map. It reaches main RAM only, which is
    // where the overwhelming majority of achievements read.
    if (address < 0x200000) {
        const uint8_t *ram = (const uint8_t *)retro_get_memory_data(RETRO_MEMORY_SYSTEM_RAM);
        const size_t ramSize = retro_get_memory_size(RETRO_MEMORY_SYSTEM_RAM);
        if (ram && address < ramSize) {
            const size_t count = MIN((size_t)length, ramSize - address);
            memcpy(buffer, ram + address, count);
            return (NSInteger)count;
        }
    }
    return 0;
}

#pragma mark - Speed

/// Recorded, not passed to the core, exactly as MesenBridge does. How many
/// frames run per display refresh is our loop's decision for all four cores;
/// handing the core a speed as well would put a second pacer on the same frames.
- (void)setSpeedMultiplier:(int)multiplier {
    _speedMultiplier = MAX(1, multiplier);
}

#pragma mark - Audio

- (unsigned int)audioSampleRate { return kPS1SampleRate; }

- (void)handleAudio:(const int16_t *)frames count:(size_t)count {
    if (frames && count) _audio.Write(frames, count);
}

- (NSInteger)readAudioSamples:(int16_t *)buffer count:(NSInteger)count {
    if (!buffer || count <= 0) return 0;
    return (NSInteger)_audio.Read(buffer, (size_t)count);
}

/// The PlayStation's SPU runs at a fixed 44.1 kHz and the core resamples to it,
/// so there is never a rate change to report.
- (unsigned int)consumePendingAudioRate { return 0; }

#pragma mark - Rewind

- (void)initRewind:(NSInteger)seconds {
    [self teardownRewind];
    if (seconds <= 0 || !_coreInitialised) return;

    const size_t stateSize = retro_serialize_size();
    if (!stateSize) return;

    // One snapshot every five seconds, plus the one at "now", capped by the
    // byte ceiling. See kRewindSecondsPerSnapshot for the arithmetic.
    NSInteger wanted = (seconds / kRewindSecondsPerSnapshot) + 1;
    NSInteger affordable = (NSInteger)(kRewindByteCeiling / stateSize);
    _rwCapacity = MIN(wanted, affordable);
    if (_rwCapacity < 2) { _rwCapacity = 0; return; }

    // Allocated lazily, one snapshot at a time, so a session where nobody ever
    // rewinds never pays for the ring at all.
    _rwStates.resize((size_t)_rwCapacity);
    _rwStored = 0;
    _rwNewest = -1;
    _rwFrameCounter = 0;
    _rwSnapshotDue = YES;
}

- (void)teardownRewind {
    _rwStates.clear();
    _rwCapacity = 0;
    _rwStored = 0;
    _rwNewest = -1;
    _rwFrameCounter = 0;
    _rwSnapshotDue = NO;
}

/// Drop the whole history without dropping the ring. Used wherever the timeline
/// jumps: a reset, a loaded state, a disc change.
- (void)invalidateRewind {
    _rwStored = 0;
    _rwNewest = -1;
    _rwFrameCounter = 0;
    _rwSnapshotDue = YES;
}

- (void)rewindAppend {
    if (_rwCapacity <= 0 || !_romLoaded) return;

    const NSInteger framesPerSnapshot =
        (NSInteger)(self.framesPerSecond * kRewindSecondsPerSnapshot);
    if (!_rwSnapshotDue && ++_rwFrameCounter < framesPerSnapshot) return;
    _rwSnapshotDue = NO;
    _rwFrameCounter = 0;

    const size_t size = retro_serialize_size();
    if (!size) return;

    _rwNewest = (_rwNewest + 1) % _rwCapacity;
    auto &slot = _rwStates[(size_t)_rwNewest];
    if (slot.size() != size) slot.resize(size);
    if (!retro_serialize(slot.data(), size)) {
        // Leave the ring's count alone: a slot we failed to fill must not be
        // counted as a place the player can rewind to.
        _rwNewest = (_rwNewest - 1 + _rwCapacity) % _rwCapacity;
        return;
    }
    if (_rwStored < _rwCapacity) _rwStored++;
}

- (BOOL)rewindFrames:(NSInteger)count {
    if (!_romLoaded || _rwStored <= 0 || _rwNewest < 0) return NO;

    // The caller counts frames; we hold one snapshot every five seconds. Round
    // UP to the snapshot at or before the requested point, so a rewind never
    // lands the player somewhere they had already got past.
    const NSInteger framesPerSnapshot =
        (NSInteger)(self.framesPerSecond * kRewindSecondsPerSnapshot);
    if (framesPerSnapshot <= 0) return NO;
    NSInteger steps = (count + framesPerSnapshot - 1) / framesPerSnapshot;
    if (steps < 1) steps = 1;
    if (steps > _rwStored - 1) steps = _rwStored - 1;
    if (steps < 1) return NO;

    const NSInteger index = (_rwNewest - steps + _rwCapacity * 2) % _rwCapacity;
    auto &slot = _rwStates[(size_t)index];
    if (slot.empty()) return NO;
    if (!retro_unserialize(slot.data(), slot.size())) return NO;

    // Everything newer than where we landed is now a future that did not
    // happen, so it leaves the ring.
    _rwNewest = index;
    _rwStored -= steps;
    _rwFrameCounter = 0;
    _rwSnapshotDue = YES;
    _audio.Clear();
    return YES;
}

#pragma mark - Cheats

/// Applying a set is CLEAR then re-add the enabled ones, which is the shape the
/// app already uses (see `CheatManagerView.reapplyAll`) and the one libretro
/// expects: `retro_cheat_set` takes an index and an enabled flag, with no way
/// to ask what is currently applied.
- (BOOL)addCheatCode:(NSString *)code type:(int)type {
    if (!_romLoaded || !code.length) return NO;
    retro_cheat_set(_cheatCount, true, code.UTF8String);
    _cheatCount++;
    return YES;
}

- (void)clearCheats {
    if (!_coreInitialised) return;
    retro_cheat_reset();
    _cheatCount = 0;
}

#pragma mark - Discs

- (BOOL)isMultiDisc {
    return _hasDiskControl && _diskControl.get_num_images && _diskControl.get_num_images() > 1;
}

- (NSUInteger)currentDiscIndex {
    if (!_hasDiskControl || !_diskControl.get_image_index) return 0;
    return _diskControl.get_image_index();
}

- (NSArray<PS1Disc *> *)discs {
    if (!self.isMultiDisc) return @[];
    const unsigned count = _diskControl.get_num_images();
    NSMutableArray<PS1Disc *> *result = [NSMutableArray arrayWithCapacity:count];
    for (unsigned i = 0; i < count; i++) {
        char label[256] = {0};
        BOOL gotLabel = _diskControl.get_image_label &&
                        _diskControl.get_image_label(i, label, sizeof(label)) &&
                        label[0] != '\0';
        // The fallback is a number and not a filename: the core's label comes
        // from the .m3u the player wrote, and if there is none, a bare "Disc 2"
        // reads better than a dump's filename. It is localized by the caller.
        // `@(label)` is stringWithUTF8String:, which returns nil for bytes
        // that are not UTF-8, and `label` is nonnull on the Swift side: a
        // playlist line the core cut mid-character at its 255-byte buffer, or
        // one it read from a non-UTF-8 file, crashed the app the moment the
        // pause menu asked for the disc list. Latin-1 decodes every byte, so
        // the row shows something rather than nothing; a label that still
        // comes back empty falls through to the number.
        NSString *labelText = nil;
        if (gotLabel) {
            labelText = [NSString stringWithUTF8String:label]
                     ?: [NSString stringWithCString:label encoding:NSISOLatin1StringEncoding];
        }
        BOOL hasLabel = labelText.length > 0;
        NSString *text = hasLabel ? labelText : [NSString stringWithFormat:@"%u", i + 1];
        [result addObject:[[PS1Disc alloc] initWithIndex:i
                                                   label:text
                                         labelIsFallback:!hasLabel]];
    }
    return result;
}

/// Open the lid, change the disc, close the lid. All three steps are required:
/// a game watches for the lid, and swapping the image underneath it without the
/// eject sequence is a change the game never sees.
- (BOOL)changeToDiscAtIndex:(NSUInteger)index {
    if (!self.isMultiDisc) return NO;
    if (index >= _diskControl.get_num_images()) return NO;
    if (!_diskControl.set_eject_state || !_diskControl.set_image_index) return NO;

    if (!_diskControl.set_eject_state(true)) return NO;
    const bool set = _diskControl.set_image_index((unsigned)index);
    const bool closed = _diskControl.set_eject_state(false);
    if (!set || !closed) {
        os_log_error(PCSXLog(), "disc change to %lu failed (set=%d closed=%d)",
                     (unsigned long)index, set, closed);
        return NO;
    }
    // The disc that is spinning is part of the state, so history taken against
    // the previous one cannot be rewound into.
    [self invalidateRewind];
    return YES;
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
    _memoryMap.clear();
    _frameBuffer.clear();
    _audio.Clear();
    memset(&_diskControl, 0, sizeof(_diskControl));
    _hasDiskControl = NO;
    if (sBridge == self) sBridge = nil;
}

@end
