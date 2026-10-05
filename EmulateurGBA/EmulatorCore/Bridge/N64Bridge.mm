//
//  N64Bridge.mm
//  EmulateurGBA
//
//  ObjC++ implementation bridging Mupen64Plus-Next (Nintendo 64) to Swift.
//
//  HOW THIS CORE IS BUILT, in one paragraph, because every choice below rests
//  on it (the full reasons are in Vendor/n64-ios/build.sh). The CPU runs on
//  the cached interpreter, since the App Store forbids JIT. The picture is
//  drawn by parallel-RDP on the GPU through Vulkan, which MoltenVK provides on
//  Metal. The RSP runs on cxd4, a low-level interpreter, because a low-level
//  renderer needs one. GLideN64 is not in the binary (GPL-2.0-only, which
//  cannot ship beside our GPL-3.0 cores) and neither is angrylion (its licence
//  forbids commercial use).
//
//  HOW IT IS DRIVEN. Through libretro, like PCSX-ReARMed, and under the same
//  constraint: one global core instance, callbacks without a user-data pointer,
//  so one N64Bridge at a time and a file-static to reach it. Its entry points
//  are renamed n64_retro_* (n64_symbols.h, included first below) so that it and
//  PCSX-ReARMed can both be linked into the app.
//
//  WHAT IS DIFFERENT FROM EVERY OTHER BRIDGE: the core does not hand us pixels.
//  It asks for a Vulkan context when the game loads (SET_HW_RENDER), creates its
//  device through ours, and at each new frame names a Vulkan image. The bridge
//  copies that image into `_frameBuffer`, and from there the app's frame
//  consumers work exactly as they do for the other six consoles. The Vulkan
//  half lives in N64VulkanFrontend.
//
//  THE LOAD SEQUENCE the core expects, which libretro leaves to the frontend and
//  which fails silently if done out of order:
//    retro_load_game   the core asks for the Vulkan context (we create the
//                      instance and check the GPU right then, and refuse if it
//                      cannot run parallel-RDP), hands us its negotiation
//                      interface, and loads the cartridge
//    create device     through the core's negotiation interface
//    context_reset     the core fetches our interface and starts emulating
//  and at the end, context_destroy BEFORE the device is destroyed.
//
//  WHY A REFUSAL HAS TO HAPPEN DURING THE LOAD. Once `retro_load_game` has
//  returned true, the core can only be shut down by switching into its
//  emulation coroutine, and that coroutine crashes on its way out if the
//  machine never started (its failure paths return from the coroutine instead
//  of switching back). A GPU without what parallel-RDP needs is therefore
//  refused inside the load, where failing is clean. See `loadROMAtPath:` for
//  the one failure that can still come after it.
//
//  WHAT THE CORE DOES NOT WARN ABOUT:
//   - it copies the system directory's path without checking it was given
//     one, so GET_SYSTEM_DIRECTORY must always be answered (found by running
//     the core on the host, Vendor/n64-ios/host-check.c);
//   - its log callback is called unchecked in places, so the log interface
//     must be answered too;
//   - its default renderer is GLideN64 and its default CPU is the dynarec.
//     Our build redirects the first and cannot run the second, and both are
//     also answered explicitly in kCoreOptions.
//

// The rename must come before ANY libretro header, so the declarations the
// headers make are the renamed ones.
#include "n64_symbols.h"

#if !__has_include("libretro.h")
#error "libretro.h is missing. It comes from the PCSX-ReARMed submodule: git submodule update --init Vendor/pcsx_rearmed"
#endif

#import "N64Bridge.h"
#include "N64VulkanFrontend.h"

#include <atomic>
#include <cctype>
#include <cmath>
#include <cstring>
#include <ctime>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#import <os/log.h>

const NSInteger N64MaxBufferWidth  = 640;
const NSInteger N64MaxBufferHeight = 576;

/// The N64 drew for a 4:3 television, and the core says so in its geometry.
/// The pixels are not square: a progressive NTSC frame is 640x240.
static const CGFloat kN64DisplayAspect = 4.0 / 3.0;

/// The core resamples the game's audio to 44.1 kHz itself
/// (`retro_get_system_av_info`), so the rate never changes under us.
static const unsigned int kN64SampleRate = 44100;

/// About a third of a second of stereo frames, as on the other libretro core.
static const size_t kAudioRingFrames = 16384;

/// Four controller ports, which is what the console had (`PresetSystem.
/// playerCount`). The core keeps a pad present in every port from boot
/// (`pad_present` starts all ones), so no port needs plugging: an idle player
/// is a pad nobody presses, as in RetroArch.
static const unsigned kN64Ports = 4;

/// Rewind spacing and ceiling.
///
/// `retro_serialize_size()` is FIXED at 16,793,412 bytes, read in the core's
/// source (the RDRAM dominates it: 8 MB with the Expansion Pak, which is on).
/// Whole snapshots at five-second spacing therefore cost 16 MB per five
/// seconds. The ceiling below admits two, the present and five seconds back,
/// which is the "coarsest core's five seconds" floor the rewind depths are
/// built on. Reaching the Pro maximum of thirty seconds on this console needs
/// deltas between snapshots, as MelonDSBridge already does for the DS's 19 MB
/// states; whole snapshots would cost 118 MB.
static const NSInteger kRewindSecondsPerSnapshot = 5;
static const size_t kRewindByteCeiling = 34u * 1024u * 1024u;

/// Diagnostics for bringing this console up, DEBUG only (see PCSXBridge).
#if DEBUG
#define N64Diag(fmt, ...) os_log_error(N64Log(), "[N64] " fmt, ##__VA_ARGS__)
#else
#define N64Diag(fmt, ...) do { } while (0)
#endif

static os_log_t N64Log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.retropal.emulateurgba", "n64"); });
    return log;
}

#pragma mark - Core options

/// Every core option this bridge sets, and why. Anything not listed gets the
/// default the core itself declared for it (see `recordDeclaredOptions:`).
///
/// "The core's default" is NOT what a core falls back to on its own. A
/// libretro core declares its defaults to the frontend and reads every value
/// back from it; an option the frontend does not answer keeps whatever the C
/// variable was initialised to, usually 0. That is how the control stick went
/// dead in the first device test: the stick's sensitivity was never answered,
/// stayed 0, and the core scales every stick reading by it.
struct N64Option { const char *key; const char *value; };

static const N64Option kCoreOptions[] = {
    // The renderer, restated although our build can only give parallel-RDP:
    // the core's default is GLideN64, and the patch turning that request into
    // parallel-RDP is a safety net, not the way to choose.
    { "mupen64plus-rdp-plugin", "parallel" },

    // cxd4, the low-level RSP interpreter. The core would force it anyway: a
    // low-level renderer needs a low-level RSP, and the JIT one (parallel-RSP)
    // is not in our build. Asking for "hle" would be overridden to this.
    { "mupen64plus-rsp-plugin", "cxd4" },

    // The cached interpreter: the fastest CPU the App Store allows. The core's
    // default is the dynarec, which is not in our build and is JIT.
    { "mupen64plus-cpucore", "cached_interpreter" },

    // parallel-RDP at the console's own resolution. Upscaling multiplies the
    // GPU work and the readback by 4, 16 or 64, on a console whose question is
    // already whether it holds full speed.
    { "mupen64plus-parallel-rdp-upscaling", "1x" },

    // Synchronous RDP: the CPU sees frame buffers the RDP has actually
    // finished. Asynchronous is faster and breaks the games that read their
    // own frame buffer (motion blur, pause-screen captures, camera tricks).
    // Accuracy is the reason this renderer was chosen.
    { "mupen64plus-parallel-rdp-synchronous", "True" },

    // Every N64 button gets a libretro button of its own ("independent
    // C-button controls"). The default mode shares the face buttons between A/B
    // and the C buttons behind a held modifier, which is a RetroPad compromise
    // this app does not need: kButtonMap below names each button directly.
    { "mupen64plus-alt-map", "True" },

    // A Controller Pak in every controller: the memory card the games that
    // save to the pad need (Mario Kart 64's ghosts, many sports games). Its
    // contents travel in the battery save; see `flushSaveData`.
    { "mupen64plus-pak1", "memory" },
    { "mupen64plus-pak2", "memory" },
    { "mupen64plus-pak3", "memory" },
    { "mupen64plus-pak4", "memory" },
};

static const char *N64OptionValue(const char *key) {
    if (!key) return NULL;
    for (size_t i = 0; i < sizeof(kCoreOptions) / sizeof(kCoreOptions[0]); i++) {
        if (strcmp(kCoreOptions[i].key, key) == 0) return kCoreOptions[i].value;
    }
    return NULL;
}

#pragma mark - Audio ring

/// Push-to-pull adapter, identical to PCSXBridge's: the core pushes samples
/// inside `retro_run`, the audio engine pulls on its own clock, and an overflow
/// drops the OLDEST frame.
class N64AudioRing {
public:
    N64AudioRing() { _ring.resize(kAudioRingFrames * 2, 0); }

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

#pragma mark - Bridge

@interface N64Bridge ()
- (void)handleVideo:(const void *)data width:(unsigned)width height:(unsigned)height pitch:(size_t)pitch;
- (void)handleAudio:(const int16_t *)frames count:(size_t)count;
- (bool)handleEnvironment:(unsigned)cmd data:(void *)data;
- (int16_t)inputStateForPort:(unsigned)port device:(unsigned)device index:(unsigned)index buttonID:(unsigned)buttonID;
@end

/// The single live instance, unretained for the same reasons as PCSXBridge's:
/// the callbacks carry no user data, fire several times per frame, and only
/// ever fire inside `retro_run`, which `shutdown` has stopped before the object
/// goes away.
static __unsafe_unretained N64Bridge *sN64Bridge = nil;

/// Set when a load failed at the one point the core cannot be unwound from
/// (see `loadROMAtPath:`). From then on the core is never entered again in this
/// run of the app: no frame, no unload, no deinit.
static bool sN64CoreUnusable = false;

static bool N64EnvironmentCallback(unsigned cmd, void *data) {
    N64Bridge *bridge = sN64Bridge;
    return bridge ? [bridge handleEnvironment:cmd data:data] : false;
}

static void N64VideoCallback(const void *data, unsigned width, unsigned height, size_t pitch) {
    [sN64Bridge handleVideo:data width:width height:height pitch:pitch];
}

static void N64AudioSampleCallback(int16_t left, int16_t right) {
    // The core only ever uses the batch callback; this is here because libretro
    // requires one of each.
    int16_t frame[2] = { left, right };
    [sN64Bridge handleAudio:frame count:1];
}

static size_t N64AudioBatchCallback(const int16_t *data, size_t frames) {
    [sN64Bridge handleAudio:data count:frames];
    return frames;
}

static void N64InputPollCallback(void) {
    // Nothing to fetch: `setKeys:` and the stick setters deposit the state.
}

static int16_t N64InputStateCallback(unsigned port, unsigned device, unsigned index, unsigned id) {
    N64Bridge *bridge = sN64Bridge;
    return bridge ? [bridge inputStateForPort:port device:device index:index buttonID:id] : 0;
}

static void N64LogCallback(enum retro_log_level level, const char *fmt, ...) {
    if (level < RETRO_LOG_WARN) return;   // the core is chatty at INFO
    char line[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(line, sizeof(line), fmt, args);
    va_end(args);
    os_log_error(N64Log(), "[core] %{public}s", line);
}

/// Our bitmask mapped to the N64 pad, through the core's "independent
/// C-button" layout (see kCoreOptions), in which every N64 button has a
/// libretro button of its own. The core's own table, in
/// emulate_game_controller_via_libretro.c, is what each right-hand side is
/// read from.
///
/// The bits are the N64's OWN buttons, not positions borrowed from another
/// pad: the console has its own controls (N64TouchControlsView), whose A and
/// B send our 0x001 and 0x002, and a physical controller reaches the same bits
/// through the N64 branch of `ControllerManager.buttonMask` (bottom button A,
/// left button B, as the core's own RetroPad layout has them). Z is 0x1000,
/// the bit the PlayStation calls L2. The C buttons have bits of their own
/// (N64InputBits).
static const struct { uint32_t ours; unsigned theirs; } kButtonMap[] = {
    { 0x001,          RETRO_DEVICE_ID_JOYPAD_B      },   // A
    { 0x002,          RETRO_DEVICE_ID_JOYPAD_Y      },   // B
    { 0x008,          RETRO_DEVICE_ID_JOYPAD_START  },
    { 0x010,          RETRO_DEVICE_ID_JOYPAD_RIGHT  },   // the D-pad
    { 0x020,          RETRO_DEVICE_ID_JOYPAD_LEFT   },
    { 0x040,          RETRO_DEVICE_ID_JOYPAD_UP     },
    { 0x080,          RETRO_DEVICE_ID_JOYPAD_DOWN   },
    { 0x1000,         RETRO_DEVICE_ID_JOYPAD_L2     },   // Z
    { 0x200,          RETRO_DEVICE_ID_JOYPAD_SELECT },   // L
    { 0x100,          RETRO_DEVICE_ID_JOYPAD_R2     },   // R
    { N64InputCUp,    RETRO_DEVICE_ID_JOYPAD_X      },
    { N64InputCDown,  RETRO_DEVICE_ID_JOYPAD_A      },
    { N64InputCLeft,  RETRO_DEVICE_ID_JOYPAD_L      },
    { N64InputCRight, RETRO_DEVICE_ID_JOYPAD_R      },
};

static int16_t N64ClampAxis(float v) {
    if (v >  1.0f) v =  1.0f;
    if (v < -1.0f) v = -1.0f;
    return (int16_t)(v * 32767.0f);
}

/// Whether a state is safe to hand to the core at all.
///
/// The core does NOT check: it reads a full-size state from the pointer
/// whatever `size` says, so a truncated file is a read past the end of the
/// buffer, and it returns true even when it rejects the state inside. So the
/// two things that make the read safe are checked here: the exact size, which
/// is fixed for this core, and the "M64+SAVE" magic at the start.
///
/// What is NOT checked is the game: the header also carries the cartridge's
/// MD5, and the core refuses a state from another game (while still answering
/// true). The app never offers one, since states are stored per game, so the
/// cost of reproducing the core's own hash of the byte-swapped cartridge is
/// not paid for a case that cannot be reached.
static BOOL N64StateLooksValid(NSData *data) {
    static const char kMagic[8] = { 'M', '6', '4', '+', 'S', 'A', 'V', 'E' };
    return data.length == retro_serialize_size()
        && memcmp(data.bytes, kMagic, sizeof(kMagic)) == 0;
}

NSNotificationName const N64BridgeDisplayLostNotification = @"N64BridgeDisplayLostNotification";

@implementation N64Bridge {
    BOOL _romLoaded;
    /// The display-lost notification has been posted for this game.
    BOOL _displayLostReported;
    BOOL _coreInitialised;
    std::string _romPath;
    std::string _systemDirectory;

    /// The picture, at the core's 1x maximum; the live frame occupies the
    /// top-left corner. Written by the readback, read by every frame consumer.
    std::vector<uint32_t> _frameBuffer;
    std::atomic<uint32_t> _liveWidth;
    std::atomic<uint32_t> _liveHeight;

    N64AudioRing _audio;

    /// Input, per port. See kN64Ports.
    std::atomic<uint32_t> _buttons[kN64Ports];
    std::atomic<int16_t> _stickX[kN64Ports], _stickY[kN64Ports];
    std::atomic<int16_t> _cStickX[kN64Ports], _cStickY[kN64Ports];

    /// The Vulkan context and what the core registered to use it.
    N64VulkanFrontend _vulkan;
    retro_hw_render_callback _hwRender;
    BOOL _hasHWRender;
    BOOL _contextLive;
    const retro_hw_render_context_negotiation_interface_vulkan *_negotiation;

    int _speedMultiplier;
    double _framesPerSecond;

    std::string _savePath;

    /// The default of every option the core declared, keyed by option name.
    /// The core's declaration buffers are freed after the call, so the strings
    /// are copied; the map's nodes do not move, so the pointers GET_VARIABLE
    /// hands out stay valid for the bridge's life.
    std::map<std::string, std::string> _declaredDefaults;

    /// Performance, for the question this console opens with.
    uint64_t _perfWindowStartNs;
    uint64_t _perfFrames;
    uint64_t _perfRunNs;
    /// The split of `_perfRunNs`, and the frame that matters for stutter: an
    /// average of 8 ms hides one frame of 150 ms, which is what a player feels.
    uint64_t _perfDrainNs;      // waiting for the previous frame's GPU work (beginFrame)
    uint64_t _perfReadbackNs;   // waiting for this frame's picture and copying it (readFrame)
    uint64_t _perfWorstNs;
    uint64_t _perfOverBudget;
    /// True only inside runFrame's retro_run: the hidden frames that save
    /// states and rewind snapshots run also read back, and are not timed frames.
    BOOL _perfInRun;

    /// libretro identifies a cheat by the index the frontend gives it.
    unsigned _cheatCount;

    /// Held around every call that can run the emulation.
    ///
    /// On this core that is more calls than it looks. `retro_run` runs the
    /// machine, obviously, but so do `retro_serialize` and `retro_unserialize`:
    /// the state is taken inside the emulator's own coroutine, so they switch
    /// into it and run until the next video interrupt (see libretro.c). libco is
    /// built without per-thread contexts, so there is ONE active-coroutine slot
    /// for the whole process. The app saves states on its save queue while the
    /// main thread draws, and if both switched into the coroutine at once, the
    /// two contexts would overwrite each other. With the lock the second caller
    /// waits a frame instead. Other cores tolerate that overlap (it tears a
    /// state at worst); this one would crash.
    std::mutex _coreLock;

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
        // One libretro instance: recover rather than crash if a second bridge
        // is ever built, exactly as PCSXBridge does and for the same reason.
        if (sN64Bridge != nil && sN64Bridge != self) {
            os_log_error(N64Log(),
                         "[N64] a second bridge was created; shutting the previous one down. "
                         "Something upstream is building a core more than once.");
            [sN64Bridge shutdown];
        }
        sN64Bridge = self;

        _romLoaded = NO;
        _coreInitialised = NO;
        _hasHWRender = NO;
        _contextLive = NO;
        _negotiation = NULL;
        memset(&_hwRender, 0, sizeof(_hwRender));
        _speedMultiplier = 1;
        _framesPerSecond = 60.0;
        _liveWidth = 640;
        _liveHeight = 240;
        for (unsigned p = 0; p < kN64Ports; p++) {
            _buttons[p] = 0;
            _stickX[p] = _stickY[p] = 0;
            _cStickX[p] = _cStickY[p] = 0;
        }
        _cheatCount = 0;
        _perfWindowStartNs = 0;
        _perfFrames = 0;
        _perfRunNs = 0;
        _rwCapacity = _rwStored = _rwFrameCounter = 0;
        _rwNewest = -1;
        _rwSnapshotDue = NO;

        _frameBuffer.assign((size_t)(N64MaxBufferWidth * N64MaxBufferHeight), 0);
        _systemDirectory = [self makeSystemDirectory];

        retro_set_environment(N64EnvironmentCallback);
        retro_set_video_refresh(N64VideoCallback);
        retro_set_audio_sample(N64AudioSampleCallback);
        retro_set_audio_sample_batch(N64AudioBatchCallback);
        retro_set_input_poll(N64InputPollCallback);
        retro_set_input_state(N64InputStateCallback);
    }
    return self;
}

- (void)dealloc {
    [self shutdown];
}

/// Where the core keeps its own files: the game-compatibility database it
/// writes out at start (mupen64plus.ini) and, if a player ever supplies one,
/// the optional PIF boot ROM. Private to the app and rebuilt at will, so it
/// lives in Application Support rather than beside the player's saves.
- (std::string)makeSystemDirectory {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *support = [fm URLForDirectory:NSApplicationSupportDirectory
                                inDomain:NSUserDomainMask
                       appropriateForURL:nil
                                  create:YES
                                   error:nil];
    NSURL *dir = [(support ?: [NSURL fileURLWithPath:NSTemporaryDirectory()])
                  URLByAppendingPathComponent:@"Mupen64Plus" isDirectory:YES];
    NSError *error = nil;
    if (![fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&error]) {
        os_log_error(N64Log(), "could not create the core's system directory: %{public}s",
                     error.localizedDescription.UTF8String);
    }
    return std::string(dir.fileSystemRepresentation);
}

#pragma mark - Properties

- (BOOL)isROMLoaded { return _romLoaded; }
- (NSInteger)screenWidth { return (NSInteger)_liveWidth.load(); }
- (NSInteger)screenHeight { return (NSInteger)_liveHeight.load(); }
- (NSInteger)bufferStride { return N64MaxBufferWidth; }
- (NSInteger)totalBufferHeight { return (NSInteger)_liveHeight.load(); }
- (NSInteger)maxBufferHeight { return N64MaxBufferHeight; }
- (BOOL)hasTouchScreen { return NO; }
- (CGFloat)displayAspect { return kN64DisplayAspect; }

/// The readback copies Vulkan's R8G8B8A8 bytes as they are: R, G, B, A in
/// memory, which is mGBA's order and the renderer's `.rgba8Unorm` path.
- (BOOL)usesBGRAPixelOrder { return NO; }

/// 60 for an NTSC cartridge, 50 for a PAL one, as the core reports it. Cached
/// for the same reason as on the PlayStation: rewind asks every frame.
- (double)framesPerSecond {
    return _framesPerSecond > 1.0 ? _framesPerSecond : 60.0;
}

#pragma mark - Environment

/// Records the default of every option the core declares, from the
/// SET_VARIABLES list: `{ key, "Description; default|other|other" }`, ended by
/// a NULL key. The default is the first value after "; ".
///
/// Then checks kCoreOptions against the declaration, loudly: an override whose
/// key the core never declared, or whose value is not one of the choices the
/// core offers, is ignored by the core without a word, which is exactly the
/// silent failure this table must not have.
- (void)recordDeclaredOptions:(const retro_variable *)vars {
    if (!vars) return;
    std::map<std::string, std::vector<std::string>> choices;
    for (const retro_variable *v = vars; v->key; v++) {
        if (!v->value) continue;
        const char *list = strstr(v->value, "; ");
        if (!list) continue;
        list += 2;
        std::vector<std::string> values;
        const char *start = list;
        for (const char *c = list; ; c++) {
            if (*c == '|' || *c == '\0') {
                values.emplace_back(start, (size_t)(c - start));
                if (*c == '\0') break;
                start = c + 1;
            }
        }
        if (values.empty() || values.front().empty()) continue;
        _declaredDefaults[v->key] = values.front();
        choices[v->key] = values;
    }

    for (const N64Option &option : kCoreOptions) {
        auto it = choices.find(option.key);
        if (it == choices.end()) {
            os_log_error(N64Log(), "option %{public}s is set by the bridge but not declared by the core",
                         option.key);
            continue;
        }
        bool offered = false;
        for (const std::string &value : it->second) {
            if (value == option.value) { offered = true; break; }
        }
        if (!offered) {
            os_log_error(N64Log(), "option %{public}s=%{public}s is not a value the core offers",
                         option.key, option.value);
        }
    }
}

- (bool)handleEnvironment:(unsigned)cmd data:(void *)data {
    switch (cmd) {

    // --- what we answer -----------------------------------------------------

    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        auto *var = (retro_variable *)data;
        if (!var || !var->key) return false;
        const char *value = N64OptionValue(var->key);
        if (!value) {
            auto it = _declaredDefaults.find(var->key);
            if (it == _declaredDefaults.end()) return false;
            value = it->second.c_str();
        }
        var->value = value;
        return true;
    }

    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
        // Our answers are constants, so the core never has to re-read them.
        if (data) *(bool *)data = false;
        return true;

    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
        // REQUIRED: the core copies this path without checking it received
        // one (see the file header).
        *(const char **)data = _systemDirectory.c_str();
        return true;

    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: {
        // Also required: some of the core's log calls are unchecked.
        auto *cb = (retro_log_callback *)data;
        if (cb) cb->log = N64LogCallback;
        return true;
    }

    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
        // Sent at init by habit. The picture arrives as a Vulkan image, not in
        // this format, so accepting it changes nothing; refusing would make the
        // core log a failure that is not one.
        return *(const enum retro_pixel_format *)data == RETRO_PIXEL_FORMAT_XRGB8888;

    case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
        // The whole pad in one call per frame. The core asks with NULL data,
        // so the answer is the return value alone.
        if (data) *(bool *)data = true;
        return true;

    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
        if (data) *(bool *)data = true;
        return true;

    case RETRO_ENVIRONMENT_SET_HW_RENDER: {
        // The core wants a Vulkan context. The instance is created and the GPU
        // checked NOW, while refusing still fails the load cleanly (see the
        // file header); the device follows once the load returns. The two
        // callbacks are kept: `context_reset` is what starts the emulation.
        auto *cb = (retro_hw_render_callback *)data;
        if (!cb || cb->context_type != RETRO_HW_CONTEXT_VULKAN) return false;
        if (!_vulkan.createInstance()) return false;
        _hwRender = *cb;
        _hasHWRender = YES;
        return true;
    }

    case RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE: {
        // How the core creates the device itself. The pointer is to a static
        // inside the core, valid for as long as the core is loaded.
        auto *iface = (const retro_hw_render_context_negotiation_interface *)data;
        if (!iface || iface->interface_type != RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN) {
            return false;
        }
        _negotiation = (const retro_hw_render_context_negotiation_interface_vulkan *)data;
        return true;
    }

    case RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE: {
        if (!data || !_vulkan.isReady()) return false;
        *(const retro_hw_render_interface **)data =
            (const retro_hw_render_interface *)_vulkan.interface();
        return true;
    }

    case RETRO_ENVIRONMENT_GET_JIT_CAPABLE:
        // No: the App Store forbids it, and the only thing the core would do
        // with a yes is pick parallel-RSP, which is not in our build.
        if (data) *(bool *)data = false;
        return true;

    case RETRO_ENVIRONMENT_SET_GEOMETRY:
        // Read from every video_refresh instead.
        return true;

    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
        if (data) {
            const auto *info = (const retro_system_av_info *)data;
            if (info->timing.fps > 1.0) _framesPerSecond = info->timing.fps;
        }
        return true;

    // --- accepted and ignored, each for its own reason ----------------------

    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
        // Button names and pad types for a remapping UI the frontend owns.
        // Ours is ControllerMapping.
        return true;

    case RETRO_ENVIRONMENT_SET_VARIABLES:
        // The core declaring its options, each with its default. Recorded,
        // because the defaults are only ever applied by the frontend's answers.
        [self recordDeclaredOptions:(const retro_variable *)data];
        return true;

    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK:
        // Never sent: GET_CORE_OPTIONS_VERSION is declined below, so the core
        // declares its options through SET_VARIABLES instead. Acknowledged in
        // case a later core sends one anyway.
        return true;

    case RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO:
        // The 64DD disk drive, loaded as a "subsystem". Not offered.
        return true;

    case RETRO_ENVIRONMENT_SET_MESSAGE:
    case RETRO_ENVIRONMENT_SET_MESSAGE_EXT:
        // Every string the player reads is ours, in fifteen languages.
        return true;

    case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL:
    case RETRO_ENVIRONMENT_SET_MINIMUM_AUDIO_LATENCY:
    case RETRO_ENVIRONMENT_SET_AUDIO_BUFFER_STATUS_CALLBACK:
        return true;

    // --- declined -----------------------------------------------------------

    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
        // Declined, so the core declares its options through the plain
        // SET_VARIABLES above, the one format `recordDeclaredOptions:` reads.
        return false;

    case RETRO_ENVIRONMENT_GET_LANGUAGE:
    case RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE:
    case RETRO_ENVIRONMENT_GET_PERF_INTERFACE:
    case RETRO_ENVIRONMENT_GET_VFS_INTERFACE:
        // Option-menu translations; rumble (a Rumble Pak is a later feature,
        // through GCController's haptics); a performance counter the core only
        // uses to log; file I/O, where stdio is right inside our sandbox.
        return false;

    default:
        // Includes the RetroArch-private commands the core defines for its
        // threaded GLideN64 mode, which our build cannot enter.
        return false;
    }
}

#pragma mark - ROM management

- (BOOL)loadROMAtPath:(NSString *)path {
    if (!path.length) return NO;

    if (sN64CoreUnusable) {
        os_log_error(N64Log(), "the core is in an unrecoverable state from an earlier load; "
                     "restart the app to play Nintendo 64 games");
        return NO;
    }
    // The core does not open the file itself (need_fullpath is false): it
    // takes the bytes, in any of the three byte orders cartridges are dumped
    // in (.z64, .v64, .n64), and normalises them. Read BEFORE the core is
    // started, so an unreadable file never leaves a started core without a
    // game.
    NSData *rom = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!rom.length) {
        os_log_error(N64Log(), "could not read %{public}s", path.lastPathComponent.UTF8String);
        return NO;
    }

    if (_romLoaded) {
        // One game per bridge, which is how the app uses every bridge (one
        // session per launch). This core cannot do better: `retro_unload_game`
        // does not stop the machine or close the cartridge, so a second load
        // would fail at the core's ROM open and leave the cartridge open for
        // the rest of the run. Refused loudly rather than attempted.
        os_log_error(N64Log(), "a second game was loaded into the same bridge; refused");
        return NO;
    }
    if (!_coreInitialised) {
        retro_init();
        _coreInitialised = YES;
    }

    _romPath = std::string(path.fileSystemRepresentation);
    _hasHWRender = NO;
    _negotiation = NULL;

    retro_game_info info;
    memset(&info, 0, sizeof(info));
    info.path = _romPath.c_str();
    info.data = rom.bytes;
    info.size = rom.length;

    if (!retro_load_game(&info)) {
        // Includes the refusal in SET_HW_RENDER on a GPU parallel-RDP cannot
        // use, whose reason N64VulkanFrontend has logged.
        retro_unload_game();
        _vulkan.destroy();
        os_log_error(N64Log(), "retro_load_game failed for %{public}s", path.lastPathComponent.UTF8String);
        return NO;
    }

    // The device, through the core, then the reset that starts the emulation.
    // See the load sequence in the file header.
    if (!_hasHWRender
        || !_vulkan.createDevice(_negotiation, (unsigned)N64MaxBufferWidth, (unsigned)N64MaxBufferHeight)) {
        // The one failure that can still happen after a successful load (the
        // GPU passed the feature check, then device creation failed: out of
        // memory, most likely). The core now holds a loaded game it can only
        // release by running its coroutine, which would crash (file header).
        // So it is left exactly as it is, never entered again, and every later
        // N64 load in this run of the app is refused with a message, rather
        // than the app crashing now or at the next launch of a game.
        os_log_error(N64Log(), "no Vulkan device for %{public}s; the game cannot be drawn",
                     path.lastPathComponent.UTF8String);
        _vulkan.destroy();
        sN64CoreUnusable = true;
        return NO;
    }
    if (_hwRender.context_reset) _hwRender.context_reset();
    _contextLive = YES;

    _romLoaded = YES;
    _displayLostReported = NO;
    [self invalidateRewind];
    _audio.Clear();

    retro_system_av_info av;
    memset(&av, 0, sizeof(av));
    retro_get_system_av_info(&av);
    if (av.timing.fps > 1.0) _framesPerSecond = av.timing.fps;

    N64Diag("loaded %{public}s | %.2f fps (%{public}s) | state %zu bytes",
            path.lastPathComponent.UTF8String, _framesPerSecond,
            _framesPerSecond < 55 ? "PAL" : "NTSC", retro_serialize_size());
    return YES;
}

/// The reverse of the load sequence: the core lets go of the device, then the
/// game is unloaded, then the device goes.
- (void)unloadGame {
    // context_destroy frees every resource the core holds, some possibly still
    // referenced by a Metal command buffer that has not completed: drained
    // first, for the reason given at N64VulkanFrontend::GetSyncIndex.
    _vulkan.drainQueue();
    if (_contextLive && _hwRender.context_destroy) _hwRender.context_destroy();
    _contextLive = NO;
    retro_unload_game();
    _vulkan.destroy();
    _romLoaded = NO;
}

- (void)reset {
    if (!_romLoaded) return;
    std::lock_guard<std::mutex> lock(_coreLock);
    // Before the first frame the core refuses a reset (the machine is not
    // running yet), which is harmless: there is nothing to reset.
    _vulkan.beginFrame();
    retro_reset();
    [self invalidateRewind];
    _audio.Clear();
}

- (void)setSavePath:(NSString *)path {
    _savePath = path.length ? std::string(path.fileSystemRepresentation) : std::string();
    [self loadBatterySave];
}

/// The battery save, as one block.
///
/// The core exposes every kind of N64 save memory in one
/// RETRO_MEMORY_SAVE_RAM struct, whichever the cartridge uses: EEPROM (2 KB),
/// the four Controller Paks (32 KB each), SRAM (32 KB) and FlashRAM (128 KB),
/// 296,960 bytes in that order. It is the same `.srm` layout RetroArch writes,
/// so a player's RetroArch save imports as it is. The app then treats it like
/// any other battery save: one canonical file, exportable, mirrored to iCloud.
- (void)loadBatterySave {
    if (!_romLoaded || _savePath.empty()) return;
    void *memory = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t size = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!memory || !size) return;

    NSData *stored = [NSData dataWithContentsOfFile:@(_savePath.c_str())];
    if (!stored) {
        N64Diag("battery save: none on disk yet");
        return;
    }
    if (stored.length != size) {
        // Left alone rather than half-copied: a file of another size is not a
        // save this core wrote, and truncating it into the struct would put
        // bytes meant for one kind of memory into another.
        os_log_error(N64Log(), "battery save is %lu bytes, expected %zu - left alone",
                     (unsigned long)stored.length, size);
        return;
    }
    memcpy(memory, stored.bytes, size);
    N64Diag("battery save: loaded %lu bytes", (unsigned long)stored.length);
}

- (void)flushSaveData {
    if (!_romLoaded || _savePath.empty()) return;
    const void *memory = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t size = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!memory || !size) return;
    NSData *data = [NSData dataWithBytes:memory length:size];
    NSError *error = nil;
    if (![data writeToFile:@(_savePath.c_str()) options:NSDataWritingAtomic error:&error]) {
        os_log_error(N64Log(), "battery save write failed: %{public}s",
                     error.localizedDescription.UTF8String);
    }
}

#pragma mark - Emulation

- (void)runFrame {
    if (!_romLoaded) return;
    std::lock_guard<std::mutex> lock(_coreLock);
    // The GPU wait (see N64VulkanFrontend::beginFrame) is timed with the
    // frame: it is the previous frame's GPU work, a real part of what a frame
    // costs.
#if DEBUG
    const uint64_t before = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    _vulkan.beginFrame();
    _perfDrainNs += clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - before;
    _perfInRun = YES;
    retro_run();
    _perfInRun = NO;
    const uint64_t after = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    [self notePerformance:after - before at:after];
#else
    _vulkan.beginFrame();
    retro_run();
#endif
}

#if DEBUG
/// Emulated frames per second and the time one frame costs, every two
/// seconds: the number this console's spike exists to read. Includes the GPU
/// readback, because the readback happens inside `retro_run`.
- (void)notePerformance:(uint64_t)elapsedNs at:(uint64_t)nowNs {
    const double budgetMs = 1000.0 / _framesPerSecond;
    if (_perfWindowStartNs == 0) {
        _perfWindowStartNs = nowNs;
        _perfDrainNs = _perfReadbackNs = _perfWorstNs = _perfOverBudget = 0;
        return;
    }
    _perfFrames++;
    _perfRunNs += elapsedNs;
    if (elapsedNs > _perfWorstNs) _perfWorstNs = elapsedNs;
    if ((double)elapsedNs / 1e6 > budgetMs) _perfOverBudget++;

    const uint64_t window = nowNs - _perfWindowStartNs;
    if (window < 2000000000ULL) return;

    const double seconds = (double)window / 1e9;
    const double fps = (double)_perfFrames / seconds;
    const double n = _perfFrames ? (double)_perfFrames : 1.0;
    const double avgMs = (double)_perfRunNs / n / 1e6;
    const double drainMs = (double)_perfDrainNs / n / 1e6;
    const double readMs = (double)_perfReadbackNs / n / 1e6;
    // "core" is everything else inside retro_run: the CPU interpreter, the
    // RSP, parallel-RDP recording and submitting its work, audio.
    const double coreMs = avgMs - drainMs - readMs;
    N64Diag("%.1f fps emulated | %.2f ms per frame (core %.2f, gpu wait %.2f, readback %.2f) | "
            "worst %.1f ms | %llu of %llu frames over the %.1f ms budget",
            fps, avgMs, coreMs, drainMs, readMs, (double)_perfWorstNs / 1e6,
            _perfOverBudget, _perfFrames, budgetMs);
    _perfWindowStartNs = nowNs;
    _perfFrames = 0;
    _perfRunNs = 0;
    _perfDrainNs = _perfReadbackNs = _perfWorstNs = _perfOverBudget = 0;
}
#endif

// `awaitDisplayFrame` is not implemented: the readback completes inside the
// video callback, inside `retro_run`, so the picture is in `_frameBuffer` by
// the time `runFrame` returns.

- (void)setKeys:(uint32_t)keys {
    _buttons[0] = keys;
}

- (void)setKeys:(uint32_t)keys player:(NSInteger)player {
    if (player < 0 || player >= (NSInteger)kN64Ports) return;
    _buttons[player] = keys;
}

#pragma mark - Input

- (int16_t)inputStateForPort:(unsigned)port device:(unsigned)device index:(unsigned)index buttonID:(unsigned)buttonID {
    if (port >= kN64Ports) return 0;

    if (device == RETRO_DEVICE_JOYPAD) {
        const uint32_t keys = _buttons[port].load();
        if (buttonID == RETRO_DEVICE_ID_JOYPAD_MASK) {
            int16_t mask = 0;
            for (auto &m : kButtonMap) if (keys & m.ours) mask |= (int16_t)(1 << m.theirs);
            return mask;
        }
        for (auto &m : kButtonMap) if (buttonID == m.theirs) return (keys & m.ours) ? 1 : 0;
        return 0;
    }

    if (device == RETRO_DEVICE_ANALOG) {
        if (index == RETRO_DEVICE_INDEX_ANALOG_LEFT) {
            return buttonID == RETRO_DEVICE_ID_ANALOG_X ? _stickX[port].load() : _stickY[port].load();
        }
        if (index == RETRO_DEVICE_INDEX_ANALOG_RIGHT) {
            return buttonID == RETRO_DEVICE_ID_ANALOG_X ? _cStickX[port].load() : _cStickY[port].load();
        }
        return 0;
    }

    return 0;
}

- (void)setStickX:(float)x y:(float)y player:(NSInteger)player {
    if (player < 0 || player >= (NSInteger)kN64Ports) return;
    _stickX[player] = N64ClampAxis(x);
    _stickY[player] = N64ClampAxis(y);
}

- (void)setCStickX:(float)x y:(float)y player:(NSInteger)player {
    if (player < 0 || player >= (NSInteger)kN64Ports) return;
    _cStickX[player] = N64ClampAxis(x);
    _cStickY[player] = N64ClampAxis(y);
}

#pragma mark - Video

- (void)handleVideo:(const void *)data width:(unsigned)width height:(unsigned)height pitch:(size_t)pitch {
    (void)pitch;
    // NULL: the picture did not change (the game is between two of its own
    // frames, which for most N64 games is every other refresh or more). The
    // buffer already holds the right pixels.
    if (!data || width == 0 || height == 0) return;

    if (data != RETRO_HW_FRAME_BUFFER_VALID) {
        // A software frame. parallel-RDP never sends one; only the renderers our
        // build leaves out would. Noted rather than drawn, since its format is
        // not one this bridge negotiated.
        N64Diag("unexpected software frame %ux%u ignored", width, height);
        return;
    }

    if (width > (unsigned)N64MaxBufferWidth)   width  = (unsigned)N64MaxBufferWidth;
    if (height > (unsigned)N64MaxBufferHeight) height = (unsigned)N64MaxBufferHeight;
#if DEBUG
    const uint64_t readStart = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    const bool read = _vulkan.readFrame(width, height, _frameBuffer.data(), (size_t)N64MaxBufferWidth);
    if (_perfInRun) _perfReadbackNs += clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - readStart;
    if (read) {
#else
    if (_vulkan.readFrame(width, height, _frameBuffer.data(), (size_t)N64MaxBufferWidth)) {
#endif
        if (width != _liveWidth.load() || height != _liveHeight.load()) {
            N64Diag("resolution %ux%u -> %ux%u", _liveWidth.load(), _liveHeight.load(), width, height);
        }
        _liveWidth = width;
        _liveHeight = height;
    } else if (_vulkan.readbackLost() && !_displayLostReported) {
        _displayLostReported = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:N64BridgeDisplayLostNotification
                                                                object:self];
        });
    }
}

- (const uint32_t *)frameBuffer {
    return _romLoaded ? _frameBuffer.data() : NULL;
}

/// A still of the live picture at the shape it is displayed in, 4:3. The N64's
/// pixels are not square (a progressive NTSC frame is 640x240), so, as on the
/// PlayStation, the still is rescaled once here to the smallest 4:3 box that
/// contains the picture, and every thumbnail and share card inherits the
/// right shape.
- (CGImageRef)createFrameImage {
    if (!_romLoaded) return NULL;
    const uint32_t w = _liveWidth.load();
    const uint32_t h = _liveHeight.load();
    if (!w || !h) return NULL;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    // Bytes are R, G, B, A (see usesBGRAPixelOrder); the alpha the core writes
    // is not a transparency, so it is skipped, as mGBA's is.
    CGContextRef ctx = CGBitmapContextCreate(_frameBuffer.data(), w, h, 8,
                                             (size_t)N64MaxBufferWidth * sizeof(uint32_t),
                                             colorSpace,
                                             (CGBitmapInfo)kCGBitmapByteOrder32Big
                                             | (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGImageRef image = NULL;
    if (ctx) {
        image = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
    }

    if (image) {
        size_t outW = w, outH = h;
        const size_t byAspect = (size_t)llround((double)w / kN64DisplayAspect);
        if (byAspect >= h) outH = byAspect;
        else               outW = (size_t)llround((double)h * kN64DisplayAspect);
        if (outW != w || outH != h) {
            CGContextRef scaled = CGBitmapContextCreate(NULL, outW, outH, 8, 0, colorSpace,
                                                        (CGBitmapInfo)kCGBitmapByteOrder32Big
                                                        | (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
            if (scaled) {
                // No interpolation, as everywhere a game picture is drawn.
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
    {
        std::lock_guard<std::mutex> lock(_coreLock);
        // False before the first frame has run: the core has no machine to
        // save. Note what it costs: the state is written at the end of the
        // current interrupt and the core then finishes that frame, so the
        // game advances by one frame, as on real hardware between two looks.
        // A frame, so the same GPU wait as runFrame's.
        _vulkan.beginFrame();
        if (!retro_serialize(data.mutableBytes, size)) return NO;
    }
    return [data writeToFile:path atomically:YES];
}

- (BOOL)loadStateFromPath:(NSString *)path {
    if (!_romLoaded) return NO;
    // A loaded state is another timeline; invalidated in the bridge, as on
    // every core (the lesson the DS shipped as a bug).
    [self invalidateRewind];

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!N64StateLooksValid(data)) {
        os_log_error(N64Log(), "state %{public}s refused: %lu bytes, not a Mupen64Plus state of %zu",
                     path.lastPathComponent.UTF8String, (unsigned long)data.length, retro_serialize_size());
        return NO;
    }
    std::lock_guard<std::mutex> lock(_coreLock);
    _vulkan.beginFrame();
    return retro_unserialize(data.bytes, data.length) ? YES : NO;
}

#pragma mark - Memory (RetroAchievements)

/// RetroAchievements reads the N64's RDRAM, 8 MB with the Expansion Pak.
///
/// THE ADDRESS IS A BUS ADDRESS, as on every bridge. rcheevos places this
/// console's RDRAM at 0x80000000 (KSEG0, its cached view: `consoleinfo.c`,
/// `_rc_memory_regions_n64`), and `RAClient.readRAAddress` hands that real
/// address down. Both CPU windows onto RDRAM, KSEG0 and KSEG1 (0xA0000000, the
/// uncached one the core's own memory map uses), are therefore folded to the
/// physical offset here. Reading the address as an offset from 0 answered 0 for
/// every read, and rcheevos marks an achievement whose address reads 0 at load
/// as UNSUPPORTED: a whole set that could never unlock, silently.
///
/// The bytes are read RAW, in the core's host order, with no swap. That is not
/// a guess: the core publishes RDRAM to RetroArch as this same `dram` pointer
/// without RETRO_MEMDESC_BIGENDIAN (`device.c`, `mm_rdram`), and rcheevos'
/// libretro glue never swaps (`rc_libretro.c`), so these are the bytes the N64
/// sets are written against. The device test is an achievement that triggers.
///
/// The pointer only exists once the machine has started, inside the first
/// `retro_run`. `EmulatorSession` runs a frame before it starts the
/// RetroAchievements session, so it exists by the time rcheevos validates.
- (NSInteger)readMemoryAtAddress:(uint32_t)address into:(uint8_t *)buffer length:(NSInteger)length {
    if (!_romLoaded || !buffer || length <= 0) return 0;
    const uint8_t *ram = (const uint8_t *)retro_get_memory_data(RETRO_MEMORY_SYSTEM_RAM);
    const size_t ramSize = retro_get_memory_size(RETRO_MEMORY_SYSTEM_RAM);
    // KSEG0 (0x80000000-0x9FFFFFFF) and KSEG1 (0xA0000000-0xBFFFFFFF) both map
    // the low 512 MB of physical space; RDRAM starts at physical 0.
    if (address >= 0x80000000u && address < 0xC0000000u) address &= 0x1FFFFFFFu;
    if (!ram || address >= ramSize) return 0;
    const size_t count = MIN((size_t)length, ramSize - address);
    memcpy(buffer, ram + address, count);
    return (NSInteger)count;
}

#pragma mark - Speed

/// Recorded, not passed to the core: our loop decides how many frames run per
/// refresh, for every core.
- (void)setSpeedMultiplier:(int)multiplier {
    _speedMultiplier = MAX(1, multiplier);
}

#pragma mark - Audio

- (unsigned int)audioSampleRate { return kN64SampleRate; }

- (void)handleAudio:(const int16_t *)frames count:(size_t)count {
    if (frames && count) _audio.Write(frames, count);
}

- (NSInteger)readAudioSamples:(int16_t *)buffer count:(NSInteger)count {
    if (!buffer || count <= 0) return 0;
    return (NSInteger)_audio.Read(buffer, (size_t)count);
}

- (unsigned int)consumePendingAudioRate { return 0; }

#pragma mark - Rewind

- (void)initRewind:(NSInteger)seconds {
    [self teardownRewind];
    if (seconds <= 0 || !_coreInitialised) return;

    const size_t stateSize = retro_serialize_size();
    if (!stateSize) return;

    NSInteger wanted = (seconds / kRewindSecondsPerSnapshot) + 1;
    NSInteger affordable = (NSInteger)(kRewindByteCeiling / stateSize);
    _rwCapacity = MIN(wanted, affordable);
    if (_rwCapacity < 2) { _rwCapacity = 0; return; }

    // Allocated lazily, one snapshot at a time.
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
    // The same hidden frame as a save state (see saveStateToPath:), once
    // every five seconds: the price of whole snapshots on this core.
    std::lock_guard<std::mutex> lock(_coreLock);
    _vulkan.beginFrame();
    if (!retro_serialize(slot.data(), size)) {
        _rwNewest = (_rwNewest - 1 + _rwCapacity) % _rwCapacity;
        return;
    }
    if (_rwStored < _rwCapacity) _rwStored++;
}

- (BOOL)rewindFrames:(NSInteger)count {
    if (!_romLoaded || _rwStored <= 0 || _rwNewest < 0) return NO;

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
    {
        std::lock_guard<std::mutex> lock(_coreLock);
        _vulkan.beginFrame();
        if (!retro_unserialize(slot.data(), slot.size())) return NO;
    }

    _rwNewest = index;
    _rwStored -= steps;
    _rwFrameCounter = 0;
    _rwSnapshotDue = YES;
    _audio.Clear();
    return YES;
}

#pragma mark - Cheats

/// GameShark codes, "XXXXXXXX YYYY", one or several lines per cheat.
///
/// The core splits the text on anything that is not hexadecimal and pairs the
/// groups as address, value. It does both into fixed arrays of 256 without a
/// bound, and silently drops an unpaired last group, so a code is checked here
/// first: an even number of groups, at most 256. A code that fails is refused
/// rather than half-applied, and the cheat manager tells the player.
- (BOOL)addCheatCode:(NSString *)code type:(int)type {
    (void)type;
    if (!_romLoaded || !code.length) return NO;

    const char *text = code.UTF8String;
    if (!text) return NO;
    NSUInteger groups = 0;
    BOOL inGroup = NO;
    for (const char *c = text; *c; c++) {
        const BOOL hex = isxdigit((unsigned char)*c) != 0;
        if (hex && !inGroup) groups++;
        inGroup = hex;
    }
    if (groups < 2 || groups % 2 != 0 || groups > 256) {
        os_log_error(N64Log(), "cheat refused: %lu hexadecimal groups, expected address/value pairs",
                     (unsigned long)groups);
        return NO;
    }

    std::lock_guard<std::mutex> lock(_coreLock);
    retro_cheat_set(_cheatCount, true, text);
    _cheatCount++;
    return YES;
}

- (void)clearCheats {
    // Guarded on a LOADED game, not an initialised core: the core's cheat
    // list is only set up when a cartridge is opened, and resetting it before
    // that walks an empty list head.
    if (!_romLoaded) return;
    std::lock_guard<std::mutex> lock(_coreLock);
    retro_cheat_reset();
    _cheatCount = 0;
}

#pragma mark - Touch screen

- (void)touchScreenAtX:(int)x y:(int)y {}
- (void)touchScreenRelease {}

#pragma mark - Lifecycle

- (void)shutdown {
    std::lock_guard<std::mutex> lock(_coreLock);
    if (_romLoaded) {
        [self flushSaveData];
        [self unloadGame];
    }
    // Not after an unrecoverable load: `retro_deinit` switches into the
    // emulation coroutine, which is exactly what must not happen then.
    if (_coreInitialised && !sN64CoreUnusable) {
        retro_deinit();
    }
    _coreInitialised = NO;
    [self teardownRewind];
    _frameBuffer.clear();
    _audio.Clear();
    if (sN64Bridge == self) sN64Bridge = nil;
}

@end
