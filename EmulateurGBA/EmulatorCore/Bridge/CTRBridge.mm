//
//  CTRBridge.mm
//  EmulateurGBA
//
//  ObjC++ implementation bridging Azahar's own libretro core (Nintendo 3DS) to
//  Swift.
//
//  HOW THIS CORE IS BUILT (the full reasons are in Vendor/azahar-ios/build.sh):
//  Azahar 2127.0-alpha2's libretro core (src/citra_libretro), its ARM11 CPU on
//  FastInterp (built with IOS defined, which takes the JIT out of the core's
//  options altogether), its picture drawn with Vulkan through MoltenVK, and NO
//  console keys compiled in (games must be decrypted, as Azahar requires). The
//  entry points are renamed ctr_retro_* (ctr_symbols.h, included first below)
//  so it can be linked beside the other libretro cores.
//
//  THE PICTURE takes the Nintendo 64's and the PSP's path: the core asks for a
//  Vulkan context (SET_HW_RENDER), creates its device through ours, and names
//  a Vulkan image each frame; N64VulkanFrontend copies it into `_frameBuffer`.
//  Azahar renders offscreen into its own output image, so the instance needs
//  neither a surface (the PSP's) nor parallel-RDP's storage features.
//  Proven on the host with the frontend compiled unchanged (Tools/3ds-bench),
//  Majora's Mask 3D (Europe) and a homebrew both drawn right, no keys.
//
//  WHAT THIS CORE DOES THAT THE OTHERS DO NOT, each found on the host:
//   - IT COMPOSES BOTH SCREENS ITSELF. With the "default" layout the image is
//     400x480: the top screen over the bottom one, the bottom one centred.
//     Phase 1 shows it as one picture (see CTRBridge.h).
//   - IT KEEPS ITS DATA IN <save directory>/Azahar/ (SD card, NAND, shader
//     cache) and FALLS BACK SILENTLY to the user's home when it cannot create
//     that folder; `setSystemDirectory:` creates the parent first.
//   - IT NEEDS ITS DISK SHADER CACHE ON. Measured with Majora's Mask on the
//     host: the first launch's worst frame 5.6 s while shaders compile, the
//     second launch's 121 ms with the cache warm. (Off, the core also crashed
//     at its first draw, the pipeline cache it never made.)
//   - A STATE LOAD REBUILDS THE WHOLE EMULATED SYSTEM, renderer included
//     (System::serialize: Shutdown then Init). Our patch 0002 makes the shader
//     cache come back with it (Vendor/azahar-ios/patches). The first picture
//     after a load is the new renderer's and is not shown (kStaleFramesAfterLoad).
//   - A STATE IS STAMPED WITH THE CORE'S EXACT VERSION and refused by any
//     other one (core/savestate.cpp): a state made before an Azahar update does
//     not load after it, which is the app's standing rule for save states
//     (battery saves survive updates, states are not update-proof).
//

// The rename must come before ANY libretro header.
#include "ctr_symbols.h"

#if !__has_include("libretro.h")
#error "libretro.h is missing. It comes from the PCSX-ReARMed submodule: git submodule update --init Vendor/pcsx_rearmed"
#endif

#import "CTRBridge.h"
#include "N64VulkanFrontend.h"
#include "../../Data/ROMParsing/CTRGameProbe.h"
#include "mic_blow.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <functional>
#include <cctype>
#include <cstdarg>
#include <cstring>
#include <cmath>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <compression.h>
#import <os/log.h>
#import <UIKit/UIKit.h>
#include <os/proc.h>
#include <mach/mach.h>

const NSInteger CTRPictureWidth  = 400;
const NSInteger CTRPictureHeight = 480;
const CGRect CTRBottomScreenRect = { { 40, 240 }, { 320, 240 } };

/// The 3DS's two screens as the core composes them: 400 wide, 480 high.
static const CGFloat kCTRDisplayAspect = 400.0 / 480.0;

/// The core mixes the 3DS's audio at 32,728 Hz (AudioCore::native_sample_rate,
/// the DSP's own rate), the figure it reports in retro_get_system_av_info.
static const unsigned int kCTRDefaultSampleRate = 32728;

static const size_t kAudioRingFrames = 16384;
/// One emulated frame: a 3DS screen refresh, FRAME_TICKS (4,481,136) cycles of
/// the ARM11's 268,111,856 Hz (Azahar's video_core/gpu.h, core_timing.h).
static const double kCTRFramesPerSecond = 268111856.0 / 4481136.0;

/// After a state load, the frames that are run but not shown. One measured on
/// the host (Craftus Reloaded, 300 frames replayed after a load: sound
/// identical throughout, the picture different only on the first frame, the
/// rebuilt renderer's).
static const int kStaleFramesAfterLoad = 1;

/// The rewind (see "Rewind" below).
static const NSInteger kRewindSecondsPerSnapshot = 5;
/// Ceiling on the packed history, as on the PSP.
static const size_t kRewindHistoryByteCeiling = 64u * 1024u * 1024u;
/// What the app must still have free for the rewind to keep or take memory.
static const size_t kRewindMemoryReserve = 256u * 1024u * 1024u;
/// A snapshot waits for a frame that left this much of its budget unused...
static const double kRewindSnapshotHeadroomMs = 6.0;
/// ...or this many frames, whatever the cost.
static const NSInteger kRewindDueDeadlineFrames = 60;
/// How long the rewind waits, after giving its memory back on a memory
/// warning, before it takes it again (if the app can then spare it).
static const NSInteger kRewindPressurePauseSeconds = 60;

#if DEBUG
#define CTRDiag(fmt, ...) os_log_error(CTRLog(), "[3DS] " fmt, ##__VA_ARGS__)
#else
#define CTRDiag(fmt, ...) do { } while (0)
#endif

#if DEBUG
/// The app's footprint (the figure jetsam judges) and what is left before
/// it, in MB, for the [3DS] lines: the first device run that loaded a shader
/// cache was killed for memory before its first frame (2026-10-19), and these
/// say at which stage the footprint climbs.
static void CTRMemory(double *footprint, double *left) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    *footprint = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS
        ? info.phys_footprint / 1048576.0 : -1;
    *left = (double)(os_proc_available_memory() >> 20);
}
#define CTRMemoryDiag(stage) do { double fp_, left_; CTRMemory(&fp_, &left_); \
    CTRDiag("memory %{public}s: app %.0f MB, %.0f MB left", stage, fp_, left_); } while (0)
#else
#define CTRMemoryDiag(stage) do { } while (0)
#endif

static os_log_t CTRLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.retropal.emulateurgba", "3ds"); });
    return log;
}

NSNotificationName const CTRBridgeDisplayLostNotification = @"CTRBridgeDisplayLostNotification";
NSNotificationName const CTRBridgeGameEndedNotification = @"CTRBridgeGameEndedNotification";

#pragma mark - Core options

/// Every core option this bridge sets, and why. Anything not listed gets the
/// default the core declared (`recordDeclaredOptions:`, the N64's lesson).
/// The core offers its options as v2 definitions, then v1, then plain
/// variables (core_settings.cpp, SetupCoreOptions), stopping at the first the
/// frontend accepts: v2 and v1 are both declined here (GET_CORE_OPTIONS_VERSION
/// false, SET_CORE_OPTIONS false), so they arrive through SET_VARIABLES, the
/// format `recordDeclaredOptions:` reads. Keys and values below checked against
/// the list the core declares (Tools/3ds-bench, BENCH_LIST_OPTIONS=1).
struct CTROption { const char *key; const char *value; };

static const CTROption kCoreOptions[] = {
    // FastInterp, stated rather than left to the default (which is the same):
    // the CPU option of an IOS build has no JIT to offer.
    { "citra_use_fastinterp", "enabled" },

    // Vulkan, the one renderer this bridge has a frontend for.
    { "citra_graphics_api", "Vulkan" },

    // The PICA shaders on the GPU (the default), and their disk cache ON: see
    // the file header (the cache is what makes a second launch smooth, and
    // the core crashes without it).
    { "citra_use_hw_shader", "enabled" },
    { "citra_use_disk_shader_cache", "enabled" },

    // A shader the game has never drawn with is compiled on worker threads and
    // the draws that need it are skipped until it is ready, instead of the
    // game stopping to wait (patch 0003 exposes the core's own setting). On
    // the phone, waiting stopped Majora's Mask 3D for 1 to 4 seconds at every
    // scene seen for the first time (2026-10-19); the cost is an object
    // missing for a few frames the first time it appears.
    { "citra_async_shader_compilation", "enabled" },

    // Small draws too (patch 0006): with async compilation on, the core still
    // STOPPED for a draw of six vertices or fewer until its pipeline was
    // built, and on the phone that is a whole Metal compile on the emulation
    // thread: the 0.3 to 1.1 s stops left at a new scene (2026-10-19, after
    // 0005). Measured on the host, every remaining wait was one of those
    // (53 in 25 s). The cost: a small object missing for a frame or two the
    // first time it appears.
    { "citra_async_small_draws", "enabled" },
    // And never a compile on the emulation thread at all (patch 0008): after
    // 0006 the phone still stopped 0.35 to 0.97 s at a new scene (2026-10-19,
    // run 5), each stop right after a Metal compile. The driver's "quick"
    // probe compiled a Metal pipeline state whenever the shader was already
    // cached, and software-processed draws always waited. Same cost as above.
    { "citra_async_never_waits", "enabled" },

    // The 3DS's own resolution. Higher ones multiply the GPU work and the
    // readback on a console whose first question is whether it holds speed.
    { "citra_resolution_factor", "1" },

    // Phase 1's one picture: the top screen over the bottom one.
    { "citra_layout_option", "default" },

    // The touch screen is fed from the app's touches (POINTER), never from a
    // mouse.
    { "citra_enable_touch_touchscreen", "enabled" },
    { "citra_enable_mouse_touchscreen", "disabled" },
    // The right stick is the New 3DS's C-stick and only that. The core's
    // default also moves its own touch-screen pointer with it, which would
    // press the bottom screen whenever a game's camera is turned.
    { "citra_analog_function", "c_stick" },

    // The region from the game itself (Auto); with it the system language
    // below is kept when the game's region offers it (cfg.cpp,
    // AdjustLanguageInfoBlock) and replaced by the region's own otherwise.
    { "citra_region_value", "Auto" },

    // The microphone is the bridge's (CTRMicOpen below: the recorded blow while
    // MIC is held), named rather than left to Auto's first choice.
    { "citra_input_type", "frontend" },
};

static const char *CTROptionValue(const char *key) {
    if (!key) return NULL;
    for (size_t i = 0; i < sizeof(kCoreOptions) / sizeof(kCoreOptions[0]); i++) {
        if (strcmp(kCoreOptions[i].key, key) == 0) return kCoreOptions[i].value;
    }
    return NULL;
}

/// The player's language, as the 3DS's system setting: a game made for several
/// languages shows its text in it, as a 3DS set to that language would. Without
/// it the core boots every game in English (a European game in English is a
/// recurring App Store complaint about other 3DS emulators). Languages the 3DS
/// never had (Polish, Swedish, Romanian) keep English. The values are the
/// option's own (core_settings.cpp, `language_value`).
static const char *CTRSystemLanguage(void) {
    NSString *code = NSLocale.preferredLanguages.firstObject ?: @"en";
    if ([code hasPrefix:@"ja"]) return "Japanese";
    if ([code hasPrefix:@"fr"]) return "French";
    if ([code hasPrefix:@"es"]) return "Spanish";
    if ([code hasPrefix:@"de"]) return "German";
    if ([code hasPrefix:@"it"]) return "Italian";
    if ([code hasPrefix:@"nl"]) return "Dutch";
    if ([code hasPrefix:@"pt"]) return "Portuguese";
    if ([code hasPrefix:@"ru"]) return "Russian";
    if ([code hasPrefix:@"ko"]) return "Korean";
    if ([code hasPrefix:@"zh-Hant"]) return "Traditional Chinese";
    if ([code hasPrefix:@"zh"]) return "Simplified Chinese";
    return "English";
}

#pragma mark - Audio ring

/// Push-to-pull adapter, identical to the other libretro bridges'.
class CTRAudioRing {
public:
    CTRAudioRing() { _ring.resize(kAudioRingFrames * 2, 0); }

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

#pragma mark - Microphone

// The 3DS's microphone, as the DS's is here (MelonDSPlatform.cpp, Mic_ReadInput):
// no real microphone, a recorded blow while the MIC control is held and
// silence otherwise. The core asks the frontend for a microphone through
// libretro's interface (audio_core/libretro_input.cpp) and reads it once per
// frame (patch 0010: until the frontend's read comes back short). The device
// hands out at most one frame's worth of samples per frame, at the rate it
// opened (48 kHz, the core's choice), so the game's buffer advances at real
// time whether the blow plays or not.

struct retro_microphone {
    unsigned rate;
    bool active;
};

static retro_microphone sCTRMic { 48000, false };
static bool sCTRMicOpen = false;
static std::atomic<bool> sCTRMicBlow { false };
/// Samples the microphone may still hand out this frame (CTRMicNewFrame).
static size_t sCTRMicBudget = 0;
static size_t sCTRMicBlowPos = 0;
static constexpr size_t kCTRMicBlowLength = sizeof(mic_blow) / sizeof(int16_t);

static retro_microphone_t *CTRMicOpen(const retro_microphone_params_t *params) {
    if (sCTRMicOpen) return NULL;
    sCTRMic.rate = (params && params->rate) ? params->rate : 48000;
    sCTRMic.active = false;
    sCTRMicOpen = true;
    sCTRMicBudget = 0;
    return &sCTRMic;
}

static void CTRMicClose(retro_microphone_t *mic) {
    if (mic == &sCTRMic) sCTRMicOpen = false;
}

static bool CTRMicGetParams(const retro_microphone_t *mic, retro_microphone_params_t *params) {
    if (mic != &sCTRMic || !params) return false;
    params->rate = sCTRMic.rate;
    return true;
}

static bool CTRMicSetState(retro_microphone_t *mic, bool state) {
    if (mic != &sCTRMic) return false;
    sCTRMic.active = state;
    return true;
}

static bool CTRMicGetState(const retro_microphone_t *mic) {
    return mic == &sCTRMic && sCTRMic.active;
}

static int CTRMicRead(retro_microphone_t *mic, int16_t *samples, size_t count) {
    if (mic != &sCTRMic || !samples || !sCTRMic.active) return -1;
    const size_t n = count < sCTRMicBudget ? count : sCTRMicBudget;
    sCTRMicBudget -= n;
    if (sCTRMicBlow.load(std::memory_order_relaxed)) {
        for (size_t i = 0; i < n; i++) {
            samples[i] = mic_blow[sCTRMicBlowPos];
            sCTRMicBlowPos = (sCTRMicBlowPos + 1) % kCTRMicBlowLength;
        }
    } else {
        memset(samples, 0, n * sizeof(int16_t));
    }
    return (int)n;
}

/// Called before each retro_run, which is where the core reads: one frame's
/// samples become available.
static void CTRMicNewFrame(double framesPerSecond) {
    if (!sCTRMicOpen || !sCTRMic.active) { sCTRMicBudget = 0; return; }
    sCTRMicBudget = (size_t)((double)sCTRMic.rate / framesPerSecond + 0.5);
}

static const retro_microphone_interface kCTRMicInterface = {
    RETRO_MICROPHONE_INTERFACE_VERSION,
    CTRMicOpen, CTRMicClose, CTRMicGetParams, CTRMicSetState, CTRMicGetState, CTRMicRead,
};

#pragma mark - Motion

// The 3DS's accelerometer and gyroscope, from the phone's (CTRMotion.swift,
// CoreMotion), already turned to the 3DS's axes there. The core asks for them
// through libretro's sensor interface (citra_libretro/input/input_factory.cpp,
// LibRetroMotion): acceleration in g, rotation in radians per second, each
// scaled only by its motion sensitivity. A console lying still on a table
// reads (0, -1, 0) g: the 3DS's Y axis points up out of the lower screen.

static std::atomic<float> sCTRAccel[3] = { {0.0f}, {-1.0f}, {0.0f} };
static std::atomic<float> sCTRGyro[3] = { {0.0f}, {0.0f}, {0.0f} };

static bool CTRSensorSetState(unsigned port, enum retro_sensor_action action, unsigned rate) {
    (void)rate;
    if (port != 0) return false;
    // The phone's sensors run while the game does (CTRMotion); the core only
    // needs to hear that both exist.
    switch (action) {
    case RETRO_SENSOR_ACCELEROMETER_ENABLE:
    case RETRO_SENSOR_ACCELEROMETER_DISABLE:
    case RETRO_SENSOR_GYROSCOPE_ENABLE:
    case RETRO_SENSOR_GYROSCOPE_DISABLE:
        return true;
    default:
        return false;
    }
}

static float CTRSensorGetInput(unsigned port, unsigned id) {
    if (port != 0) return 0.0f;
    switch (id) {
    case RETRO_SENSOR_ACCELEROMETER_X: return sCTRAccel[0].load(std::memory_order_relaxed);
    case RETRO_SENSOR_ACCELEROMETER_Y: return sCTRAccel[1].load(std::memory_order_relaxed);
    case RETRO_SENSOR_ACCELEROMETER_Z: return sCTRAccel[2].load(std::memory_order_relaxed);
    case RETRO_SENSOR_GYROSCOPE_X: return sCTRGyro[0].load(std::memory_order_relaxed);
    case RETRO_SENSOR_GYROSCOPE_Y: return sCTRGyro[1].load(std::memory_order_relaxed);
    case RETRO_SENSOR_GYROSCOPE_Z: return sCTRGyro[2].load(std::memory_order_relaxed);
    default: return 0.0f;
    }
}

#pragma mark - Camera

// The 3DS's cameras from the phone's (patch 0012: the core's "libretro"
// camera). The core asks for libretro's camera interface when a game loads
// and gives its frame callback; it starts and stops the camera as games use
// it, and names the lens (inner or outer) through a private command just
// before. The bridge passes the three on to the app (CTRCamera.swift, which
// owns the capture session and the permission), and the app's frames back.

/// The rewind's raw states (patches 0014 and 0015, renamed by ctr_symbols.h):
/// the state without its compression and without the four emulated memories,
/// whose places `regions` receives.
struct CTRRewindRegion {
    void *data;
    size_t size;
};
extern "C" bool retro_ctr_rewind_capture(std::vector<uint8_t> *buffer, bool memory_outside,
                                         CTRRewindRegion *regions);
extern "C" bool retro_ctr_rewind_restore(const void *data, size_t size, bool memory_outside,
                                         CTRRewindRegion *regions);

/// Patch 0012's private command (libretro_camera.h): "inner" or "outer".
static constexpr unsigned kCTRSetCameraLens = RETRO_ENVIRONMENT_PRIVATE + 0x3D5;

static retro_camera_frame_raw_framebuffer_t sCTRCameraFrame = NULL;
static std::mutex sCTRCameraLock;

#pragma mark - Save-state files

/// A slot's file: this header, then the state. The core's own state is
/// already zstd-compressed behind its own header (magic "CSTx", the game's
/// title ID, the core's version), so it is STORED as it is: an LZFSE pass over
/// it never won (Majora's Mask 3D, 20.7 and 21.3 MB states, both stored) and
/// cost 200 ms on the host for every save, the auto-save the app writes as it
/// leaves the foreground included (2026-10-20). The header stays, for the
/// length and the digest a damaged file is told by; a packed file written
/// before still unpacks.
static const char kCTRStateMagic[8] = { 'R', 'P', 'C', 'T', 'R', 'Z', '1', 0 };
static const size_t kCTRStateHeader = sizeof(kCTRStateMagic) + 3 * sizeof(uint64_t);
static const uint64_t kCTRStateFlagPacked = 1;

/// The core's own first bytes (core/savestate.cpp, `header_magic_bytes`).
static const char kCTRCoreStateMagic[4] = { 'C', 'S', 'T', 0x1B };

static uint64_t CTRStateDigest(const uint8_t *bytes, size_t length) {
    uint64_t h = 0xcbf29ce484222325ULL;
    size_t i = 0;
    for (; i + sizeof(uint64_t) <= length; i += sizeof(uint64_t)) {
        uint64_t word;
        memcpy(&word, bytes + i, sizeof(word));
        h = (h ^ word) * 0x100000001b3ULL;
        h ^= h >> 29;
    }
    for (; i < length; i++) h = (h ^ bytes[i]) * 0x100000001b3ULL;
    return h;
}

static bool CTRStateFormatPack(const uint8_t *state, size_t stateLength, std::vector<uint8_t> &file) {
    file.clear();
    if (stateLength < sizeof(kCTRCoreStateMagic)
        || memcmp(state, kCTRCoreStateMagic, sizeof(kCTRCoreStateMagic)) != 0) {
        return false;
    }
    try { file.resize(kCTRStateHeader + stateLength); } catch (...) { file.clear(); return false; }
    uint8_t *out = file.data();
    const uint64_t flags = 0;
    const size_t payload = stateLength;
    memcpy(out + kCTRStateHeader, state, stateLength);
    const uint64_t length = (uint64_t)stateLength;
    const uint64_t digest = CTRStateDigest(state, stateLength);
    memcpy(out, kCTRStateMagic, sizeof(kCTRStateMagic));
    memcpy(out + sizeof(kCTRStateMagic), &length, sizeof(length));
    memcpy(out + sizeof(kCTRStateMagic) + 8, &digest, sizeof(digest));
    memcpy(out + sizeof(kCTRStateMagic) + 16, &flags, sizeof(flags));
    file.resize(kCTRStateHeader + payload);
    return true;
}

static bool CTRStateFormatUnpack(const uint8_t *in, size_t fileLength, std::vector<uint8_t> &state) {
    state.clear();
    if (!in || fileLength <= kCTRStateHeader
        || memcmp(in, kCTRStateMagic, sizeof(kCTRStateMagic)) != 0) {
        return false;
    }
    uint64_t length = 0, digest = 0, flags = 0;
    memcpy(&length, in + sizeof(kCTRStateMagic), sizeof(length));
    memcpy(&digest, in + sizeof(kCTRStateMagic) + 8, sizeof(digest));
    memcpy(&flags, in + sizeof(kCTRStateMagic) + 16, sizeof(flags));
    // A 3DS state is a few MB to tens of MB (zstd inside); past 512 MB the
    // header is damaged and nothing is allocated for it.
    if (length < sizeof(kCTRCoreStateMagic) || length > 512ull * 1024 * 1024) return false;
    const size_t payload = fileLength - kCTRStateHeader;

    if (flags == kCTRStateFlagPacked) {
        try { state.resize((size_t)length + 1); } catch (...) { state.clear(); return false; }
        const size_t unpacked = compression_decode_buffer(state.data(), (size_t)length + 1,
                                                          in + kCTRStateHeader, payload,
                                                          NULL, COMPRESSION_LZFSE);
        if (unpacked != (size_t)length) { state.clear(); return false; }
        state.resize((size_t)length);
    } else if (flags == 0) {
        if (payload != (size_t)length) return false;
        try { state.assign(in + kCTRStateHeader, in + kCTRStateHeader + length); }
        catch (...) { state.clear(); return false; }
    } else {
        return false;
    }
    if (CTRStateDigest(state.data(), state.size()) != digest
        || memcmp(state.data(), kCTRCoreStateMagic, sizeof(kCTRCoreStateMagic)) != 0) {
        state.clear();
        return false;
    }
    return true;
}

// CTR_STATE_FORMAT_END (the off-phone check compiles everything above this line)

#pragma mark - Rewind data
//
// The rewind's data work, plain C++ so Tools/3ds-bench compiles and runs this
// very text against the core (cut from here to CTR_REWIND_DATA_END): a step
// recorded from two snapshots, and a step applied backwards. The scheduling
// (when, on which thread) is the bridge's, in "Rewind" below.

/// One rewind step: what turns the newer snapshot back into the older one, the
/// older state's changed blocks and each memory's changed blocks, packed.
struct CTRRewindStep {
    size_t stateSize = 0;          // the older state's length
    uint8_t *packed = nullptr;     // the record, LZ4 when that paid
    size_t packedLength = 0;
    size_t rawLength = 0;
    bool compressed = false;
};

static const size_t kRewindDataBlock = 4096;
static const uint32_t kRewindStateEnd = 0xFFFFFFFFu;

static void CTRRewindFreeStep(CTRRewindStep &step) {
    free(step.packed);
    step = CTRRewindStep{};
}

/// The memories' pass of a snapshot: every 4 KiB block of `live[i]` that
/// differs from `copy[i]` is recorded as it WAS (region, offset, the old bytes)
/// and the copy takes the new one. `parallelFor(n, body)` runs body(0..n-1),
/// on every core on the phone. False when a record could not grow.
template <typename ParallelFor>
static bool CTRRewindRecordMemories(void *const live[4], const size_t liveSize[4], std::vector<uint8_t> copy[4],
                                    std::vector<std::vector<uint8_t>> &records, ParallelFor parallelFor) {
    struct Chunk { int region; size_t offset, length; };
    std::vector<Chunk> chunks;
    for (int i = 0; i < 4; i++) {
        if (liveSize[i] != copy[i].size()) return false;
        for (size_t off = 0; off < liveSize[i]; off += (size_t)4 << 20) {
            chunks.push_back({i, off, std::min((size_t)4 << 20, liveSize[i] - off)});
        }
    }
    records.assign(chunks.size(), {});
    std::atomic<bool> failed{false};
    parallelFor(chunks.size(), [&](size_t c) {
        const Chunk &chunk = chunks[c];
        uint8_t *old = copy[chunk.region].data() + chunk.offset;
        const uint8_t *now = (const uint8_t *)live[chunk.region] + chunk.offset;
        std::vector<uint8_t> &record = records[c];
        try {
            for (size_t off = 0; off < chunk.length; off += kRewindDataBlock) {
                const size_t len = std::min(kRewindDataBlock, chunk.length - off);
                if (memcmp(old + off, now + off, len) == 0) continue;
                const uint32_t header[2] = {(uint32_t)chunk.region, (uint32_t)(chunk.offset + off)};
                record.insert(record.end(), (const uint8_t *)header, (const uint8_t *)header + sizeof header);
                record.insert(record.end(), old + off, old + off + len);
                memcpy(old + off, now + off, len);
            }
        } catch (...) {
            failed = true;
        }
    });
    return !failed.load();
}

/// The step from the newer snapshot back to the older: the older state's
/// blocks the newer one lacks or holds differently (so undoing gives it
/// whole), then the memories' records. Packed with `algorithm` when that pays.
static bool CTRRewindBuildStep(const std::vector<uint8_t> &older, const std::vector<uint8_t> &newer,
                               const std::vector<std::vector<uint8_t>> &records,
                               compression_algorithm algorithm, CTRRewindStep &step) {
    std::vector<uint8_t> raw;
    try {
        const uint64_t olderSize = older.size();
        raw.insert(raw.end(), (const uint8_t *)&olderSize, (const uint8_t *)&olderSize + sizeof olderSize);
        for (size_t off = 0; off < older.size(); off += kRewindDataBlock) {
            const size_t len = std::min(kRewindDataBlock, older.size() - off);
            if (off + len <= newer.size() && memcmp(older.data() + off, newer.data() + off, len) == 0) continue;
            const uint32_t index = (uint32_t)(off / kRewindDataBlock);
            raw.insert(raw.end(), (const uint8_t *)&index, (const uint8_t *)&index + sizeof index);
            raw.insert(raw.end(), older.data() + off, older.data() + off + len);
        }
        raw.insert(raw.end(), (const uint8_t *)&kRewindStateEnd, (const uint8_t *)&kRewindStateEnd + 4);
        for (const auto &record : records) raw.insert(raw.end(), record.begin(), record.end());
    } catch (...) {
        return false;
    }
    step = CTRRewindStep{};
    step.stateSize = older.size();
    step.rawLength = raw.size();
    uint8_t *packed = (uint8_t *)malloc(raw.size());
    const size_t packedLength = packed
        ? compression_encode_buffer(packed, raw.size(), raw.data(), raw.size(), nullptr, algorithm) : 0;
    if (packedLength > 0 && packedLength < raw.size()) {
        uint8_t *shrunk = (uint8_t *)realloc(packed, packedLength);
        step.packed = shrunk ? shrunk : packed;
        step.packedLength = packedLength;
        step.compressed = true;
        return true;
    }
    free(packed);
    step.packed = (uint8_t *)malloc(raw.size());
    if (!step.packed) return false;
    memcpy(step.packed, raw.data(), raw.size());
    step.packedLength = raw.size();
    return true;
}

/// Writes a step's older blocks over `state` and `memories` (the anchor).
/// False, both untouched, when it cannot be unpacked or reads as damaged.
static bool CTRRewindApplyStep(const CTRRewindStep &step, compression_algorithm algorithm,
                               std::vector<uint8_t> &state, std::vector<uint8_t> memories[4]) {
    std::vector<uint8_t> unpacked;
    const uint8_t *raw = step.packed;
    if (step.compressed) {
        try { unpacked.resize(step.rawLength); } catch (...) { return false; }
        if (compression_decode_buffer(unpacked.data(), step.rawLength, step.packed, step.packedLength,
                                      nullptr, algorithm) != step.rawLength) return false;
        raw = unpacked.data();
    }
    const uint8_t *const begin = raw, *const end = raw + step.rawLength;
    // Read through once to check every record fits before writing anything.
    for (int pass = 0; pass < 2; pass++) {
        const uint8_t *at = begin;
        uint64_t olderSize = 0;
        if (end - at < 8) return false;
        memcpy(&olderSize, at, 8); at += 8;
        if (pass == 1) {
            try { state.resize((size_t)olderSize); } catch (...) { return false; }
        }
        for (;;) {
            if (end - at < 4) return false;
            uint32_t index;
            memcpy(&index, at, 4); at += 4;
            if (index == kRewindStateEnd) break;
            const size_t off = (size_t)index * kRewindDataBlock;
            if (off >= olderSize) return false;
            const size_t len = std::min(kRewindDataBlock, (size_t)olderSize - off);
            if ((size_t)(end - at) < len) return false;
            if (pass == 1) memcpy(state.data() + off, at, len);
            at += len;
        }
        while (at < end) {
            if (end - at < 8) return false;
            uint32_t header[2];
            memcpy(header, at, 8); at += 8;
            if (header[0] > 3) return false;
            std::vector<uint8_t> &memory = memories[header[0]];
            const size_t off = header[1];
            if (off >= memory.size()) return false;
            const size_t len = std::min(kRewindDataBlock, memory.size() - off);
            if ((size_t)(end - at) < len) return false;
            if (pass == 1) memcpy(memory.data() + off, at, len);
            at += len;
        }
    }
    return true;
}
// CTR_REWIND_DATA_END

#pragma mark - Bridge

@interface CTRBridge ()
- (void)handleVideo:(const void *)data width:(unsigned)width height:(unsigned)height;
- (void)handleAudio:(const int16_t *)frames count:(size_t)count;
- (bool)handleEnvironment:(unsigned)cmd data:(void *)data;
- (int16_t)inputStateForPort:(unsigned)port device:(unsigned)device index:(unsigned)index buttonID:(unsigned)buttonID;
- (void)cameraShouldRun:(BOOL)run;
@end

/// The single live instance, unretained, as on every libretro bridge.
static __unsafe_unretained CTRBridge *sCTRBridge = nil;

static bool CTRCameraStart(void) {
    [sCTRBridge cameraShouldRun:YES];
    return true;
}

static void CTRCameraStop(void) {
    [sCTRBridge cameraShouldRun:NO];
}

static bool CTREnvironmentCallback(unsigned cmd, void *data) {
    CTRBridge *bridge = sCTRBridge;
    return bridge ? [bridge handleEnvironment:cmd data:data] : false;
}

static void CTRVideoCallback(const void *data, unsigned width, unsigned height, size_t pitch) {
    (void)pitch;
    [sCTRBridge handleVideo:data width:width height:height];
}

static void CTRAudioSampleCallback(int16_t left, int16_t right) {
    int16_t frame[2] = { left, right };
    [sCTRBridge handleAudio:frame count:1];
}

static size_t CTRAudioBatchCallback(const int16_t *data, size_t frames) {
    [sCTRBridge handleAudio:data count:frames];
    return frames;
}

static void CTRInputPollCallback(void) {}

static int16_t CTRInputStateCallback(unsigned port, unsigned device, unsigned index, unsigned id) {
    CTRBridge *bridge = sCTRBridge;
    return bridge ? [bridge inputStateForPort:port device:device index:index buttonID:id] : 0;
}

static void CTRLogCallback(enum retro_log_level level, const char *fmt, ...) {
#if DEBUG
    // The core's INFO lines too (about 150 a session): with their timestamps
    // they time each step of a boot and of a state load on the phone (shader
    // caches read, pipelines rebuilt, driver pipeline cache loaded).
    if (level < RETRO_LOG_INFO) return;
#else
    if (level < RETRO_LOG_WARN) return;
#endif
    char line[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(line, sizeof(line), fmt, args);
    va_end(args);
    // A core line that repeats every frame (a save archive the game keeps
    // retrying, 2026-10-19: three errors a frame for minutes) would drown the
    // log and cost the emulation thread an os_log call each time. Counted by
    // where it comes from ("file:function:line", after the level): the first
    // CTRLogRepeatsShown are logged, then one in CTRLogRepeatEvery with the
    // running count, so nothing is hidden for good.
    static constexpr unsigned CTRLogRepeatsShown = 20;
    static constexpr unsigned CTRLogRepeatEvery = 1000;
    static std::mutex repeatsMutex;
    static std::map<std::string, unsigned> repeats;
    const char *where = strchr(line, '>');
    const char *whereEnd = where ? strstr(where, ": ") : nullptr;
    if (where && whereEnd) {
        unsigned seen;
        {
            std::lock_guard<std::mutex> lock(repeatsMutex);
            seen = ++repeats[std::string(where, whereEnd)];
        }
        if (seen > CTRLogRepeatsShown) {
            if (seen % CTRLogRepeatEvery == 0) {
                os_log_error(CTRLog(), "[core] (seen %u times) %{public}s", seen, line);
            }
            return;
        }
    }
    os_log_error(CTRLog(), "[core] %{public}s", line);
}

/// Our bitmask (GBAInput) mapped to the 3DS pad. The PlayStation's page
/// drives this console in phase 1, and its bits name the 3DS's own buttons,
/// which sit where that pad's did (A right, B bottom, X top, Y left), its
/// second shoulder pair ZL and ZR: the core reads RetroPad A as the 3DS's A,
/// L2 and R2 as ZL and ZR, and so on (citra_libretro.cpp, UpdateSettings).
static const struct { uint32_t ours; unsigned theirs; } kButtonMap[] = {
    { 0x001, RETRO_DEVICE_ID_JOYPAD_A      },
    { 0x002, RETRO_DEVICE_ID_JOYPAD_B      },
    { 0x400, RETRO_DEVICE_ID_JOYPAD_X      },
    { 0x800, RETRO_DEVICE_ID_JOYPAD_Y      },
    { 0x004, RETRO_DEVICE_ID_JOYPAD_SELECT },
    { 0x008, RETRO_DEVICE_ID_JOYPAD_START  },
    { 0x010, RETRO_DEVICE_ID_JOYPAD_RIGHT  },
    { 0x020, RETRO_DEVICE_ID_JOYPAD_LEFT   },
    { 0x040, RETRO_DEVICE_ID_JOYPAD_UP     },
    { 0x080, RETRO_DEVICE_ID_JOYPAD_DOWN   },
    { 0x200, RETRO_DEVICE_ID_JOYPAD_L      },
    { 0x100, RETRO_DEVICE_ID_JOYPAD_R      },
    { 0x1000, RETRO_DEVICE_ID_JOYPAD_L2    },   // ZL
    { 0x2000, RETRO_DEVICE_ID_JOYPAD_R2    },   // ZR
};

static int16_t CTRClampAxis(float v) {
    if (v >  1.0f) v =  1.0f;
    if (v < -1.0f) v = -1.0f;
    return (int16_t)(v * 32767.0f);
}

/// A position in the composed picture's pixels to libretro's pointer range
/// (-0x7fff...0x7fff across the whole picture), which the core maps back
/// through its own layout (input/mouse_tracker.cpp).
static int16_t CTRPointerAxis(int value, NSInteger extent) {
    if (value < 0) value = 0;
    if (value >= extent) value = (int)extent - 1;
    return (int16_t)(((2 * value + 1) * 0x7fff) / extent - 0x7fff);
}

@implementation CTRBridge {
    BOOL _romLoaded;
    BOOL _coreInitialised;
    BOOL _displayLostReported;
    /// The core said the game has ended (RETRO_ENVIRONMENT_SHUTDOWN, patch
    /// 0021): no frame and no save state from then on.
    std::atomic<bool> _gameEnded;
    std::string _romPath;
    /// The folder the core keeps <it>/Azahar/ in (setSystemDirectory:).
    std::string _systemDirectory;
    /// The last message the core displayed while loading: it says WHY a load
    /// failed (DisplayMessage, citra_libretro.cpp), which is the only channel.
    std::string _lastCoreMessage;

    std::vector<uint32_t> _frameBuffer;
    std::atomic<uint32_t> _liveWidth;
    std::atomic<uint32_t> _liveHeight;
    int _hideFrames;
    std::vector<uint32_t> _hiddenBuffer;

    CTRAudioRing _audio;
    unsigned int _sampleRate;

    std::atomic<uint32_t> _buttons;
    std::atomic<int16_t> _stickX, _stickY;
    /// The New 3DS's C-stick (the right stick).
    std::atomic<int16_t> _cStickX, _cStickY;
    /// Whether the game has a camera running, and which (cameraShouldRun:).
    BOOL _cameraRunning;
    BOOL _cameraInner;
    /// The rewind (see "Rewind").
    NSInteger _rwDepth;
    std::vector<CTRRewindStep> _rwSteps;
    NSInteger _rwNewest, _rwStored;
    size_t _rwHistoryBytes;
    std::vector<uint8_t> _rwState, _rwNextState;   // the anchor's state; the next one
    std::vector<uint8_t> _rwMemory[4];             // the anchor's four memories
    BOOL _rwHasAnchor, _rwDue, _rwRefused;
    NSInteger _rwDueFrames, _rwFrameCounter;
    double _rwLastFrameMs;
    dispatch_queue_t _rwPackQueue;
    std::atomic<bool> _rwPackInFlight;
    /// The pack queue could not make the anchor's buffers (`takeRewindSnapshot`).
    std::atomic<bool> _rwAllocationFailed;
    /// The memory warning's observer, while a rewind is set up.
    id _rwMemoryWarningObserver;
    /// Memory warnings this game's rewind has given its memory back for, and
    /// the frames it still waits before taking it again.
    NSInteger _rwPressureReleases, _rwPressureWaitFrames;
    /// The index the next cheat is set with (retro_cheat_set's first argument,
    /// which names it in the core's log). Atomic: set on the main thread,
    /// reset by a boot on the work queue, neither under the core lock.
    std::atomic<unsigned> _cheatCount;
    /// The touch screen, in the composed picture's pixels, and whether it is
    /// pressed.
    std::atomic<int> _touchX, _touchY;
    std::atomic<bool> _touching;

    N64VulkanFrontend _vulkan;
    retro_hw_render_callback _hwRender;
    BOOL _hasHWRender;
    BOOL _contextLive;
    const retro_hw_render_context_negotiation_interface_vulkan *_negotiation;

    double _framesPerSecond;   // kCTRFramesPerSecond once loaded
    std::map<std::string, std::string> _declaredDefaults;

    /// Whether a frame has run since the game booted. Before that, the game is
    /// exactly at power-on, and a reset would only boot it a second time.
    BOOL _hasRunFrame;

#if DEBUG
    uint64_t _perfWindowStartNs;
    uint64_t _perfFrames;
    uint64_t _perfRunNs;
    uint64_t _perfWorstNs;
    uint64_t _perfOverBudget;
#endif

    /// Held around every call that runs the emulation: retro_run,
    /// retro_serialize, retro_unserialize, retro_reset.
    std::mutex _coreLock;
}

- (instancetype)init {
    if ((self = [super init])) {
        if (sCTRBridge != nil && sCTRBridge != self) {
            os_log_error(CTRLog(), "[3DS] a second bridge was created; shutting the previous one down.");
            [sCTRBridge shutdown];
        }
        sCTRBridge = self;

        _romLoaded = NO;
        _coreInitialised = NO;
        _displayLostReported = NO;
        _gameEnded = false;
        _hasHWRender = NO;
        _contextLive = NO;
        _negotiation = NULL;
        memset(&_hwRender, 0, sizeof(_hwRender));
        _framesPerSecond = 60.0;
        _sampleRate = kCTRDefaultSampleRate;
        _liveWidth = (uint32_t)CTRPictureWidth;
        _liveHeight = (uint32_t)CTRPictureHeight;
        _hideFrames = 0;
        _buttons = 0;
        _stickX = _stickY = 0;
        _cStickX = _cStickY = 0;
        _touchX = _touchY = 0;
        _touching = false;
#if DEBUG
        _perfWindowStartNs = _perfFrames = _perfRunNs = _perfWorstNs = _perfOverBudget = 0;
#endif

        _frameBuffer.assign((size_t)(CTRPictureWidth * CTRPictureHeight), 0);
        _hiddenBuffer.assign(_frameBuffer.size(), 0);

        retro_set_environment(CTREnvironmentCallback);
        retro_set_video_refresh(CTRVideoCallback);
        retro_set_audio_sample(CTRAudioSampleCallback);
        retro_set_audio_sample_batch(CTRAudioBatchCallback);
        retro_set_input_poll(CTRInputPollCallback);
        retro_set_input_state(CTRInputStateCallback);
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
- (NSInteger)bufferStride { return CTRPictureWidth; }
- (NSInteger)totalBufferHeight { return (NSInteger)_liveHeight.load(); }
- (NSInteger)maxBufferHeight { return CTRPictureHeight; }
/// NO on purpose in phase 1: the app's two-screen path is the Nintendo DS's,
/// built on two equal 256x192 screens. See CTRBridge.h.
- (BOOL)hasTouchScreen { return NO; }
- (CGFloat)displayAspect { return kCTRDisplayAspect; }
/// R, G, B, A in memory, as the frontend's readback writes it.
- (BOOL)usesBGRAPixelOrder { return NO; }
- (double)framesPerSecond { return _framesPerSecond > 1.0 ? _framesPerSecond : 60.0; }

#pragma mark - Environment

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
    // Loudly, as on the N64 and the PSP: an override the core does not
    // declare, or whose value it does not offer, would be ignored silently.
    auto check = [&](const char *key, const char *value) {
        auto it = choices.find(key);
        if (it == choices.end()) {
            os_log_error(CTRLog(), "option %{public}s is set by the bridge but not declared by the core", key);
            return;
        }
        for (const std::string &v : it->second) if (v == value) return;
        os_log_error(CTRLog(), "option %{public}s=%{public}s is not a value the core offers", key, value);
    };
    for (const CTROption &option : kCoreOptions) check(option.key, option.value);
    check("citra_language_value", CTRSystemLanguage());
}

- (bool)handleEnvironment:(unsigned)cmd data:(void *)data {
    switch (cmd) {

    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        auto *var = (retro_variable *)data;
        if (!var || !var->key) return false;
        const char *value = strcmp(var->key, "citra_language_value") == 0 ? CTRSystemLanguage()
                                                                           : CTROptionValue(var->key);
        if (!value) {
            auto it = _declaredDefaults.find(var->key);
            if (it == _declaredDefaults.end()) return false;
            value = it->second.c_str();
        }
        var->value = value;
        return true;
    }

    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
        if (data) *(bool *)data = false;
        return true;

    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
        // Both the same folder: the core puts everything it writes in
        // <save directory>/Azahar/ (core_settings.cpp, ParseStorageOptions).
        if (_systemDirectory.empty()) return false;
        *(const char **)data = _systemDirectory.c_str();
        return true;

    case RETRO_ENVIRONMENT_GET_CAMERA_INTERFACE: {
        auto *camera = (retro_camera_callback *)data;
        if (!camera || !(camera->caps & (1 << RETRO_CAMERA_BUFFER_RAW_FRAMEBUFFER))
            || !camera->frame_raw_framebuffer) return false;
        {
            std::lock_guard<std::mutex> lock(sCTRCameraLock);
            sCTRCameraFrame = camera->frame_raw_framebuffer;
        }
        camera->start = CTRCameraStart;
        camera->stop = CTRCameraStop;
        return true;
    }

    case kCTRSetCameraLens: {
        const char *lens = (const char *)data;
        if (!lens) return false;
        const BOOL inner = strcmp(lens, "inner") == 0;
        void (^handler)(BOOL, BOOL) = self.cameraHandler;
        _cameraInner = inner;
        if (handler && _cameraRunning) handler(YES, inner);
        return true;
    }

    case RETRO_ENVIRONMENT_GET_SENSOR_INTERFACE: {
        auto *sensors = (retro_sensor_interface *)data;
        if (!sensors) return false;
        sensors->set_sensor_state = CTRSensorSetState;
        sensors->get_sensor_input = CTRSensorGetInput;
        return true;
    }

    case RETRO_ENVIRONMENT_GET_MICROPHONE_INTERFACE: {
        auto *mic = (retro_microphone_interface *)data;
        if (!mic || mic->interface_version != RETRO_MICROPHONE_INTERFACE_VERSION) return false;
        *mic = kCTRMicInterface;
        return true;
    }

    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: {
        auto *cb = (retro_log_callback *)data;
        if (cb) cb->log = CTRLogCallback;
        return true;
    }

    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
        return *(const enum retro_pixel_format *)data == RETRO_PIXEL_FORMAT_XRGB8888;

    case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
        if (data) *(bool *)data = true;
        return true;

    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
        if (data) *(bool *)data = true;
        return true;

    case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER:
        if (data) *(unsigned *)data = RETRO_HW_CONTEXT_VULKAN;
        return true;

    case RETRO_ENVIRONMENT_SET_HW_RENDER: {
        auto *cb = (retro_hw_render_callback *)data;
        if (!cb || cb->context_type != RETRO_HW_CONTEXT_VULKAN) return false;
        // Azahar renders offscreen: no surface, and none of parallel-RDP's
        // storage features.
        N64VulkanFrontend::Requirements requirements;
        requirements.parallelRDPStorage = false;
        if (!_vulkan.createInstance(requirements)) return false;
        _hwRender = *cb;
        _hasHWRender = YES;
        return true;
    }

    case RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE: {
        auto *iface = (const retro_hw_render_context_negotiation_interface *)data;
        if (!iface || iface->interface_type != RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN) return false;
        _negotiation = (const retro_hw_render_context_negotiation_interface_vulkan *)data;
        return true;
    }

    case RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE:
        if (!data || !_vulkan.isReady()) return false;
        *(const retro_hw_render_interface **)data = (const retro_hw_render_interface *)_vulkan.interface();
        return true;

    case RETRO_ENVIRONMENT_GET_JIT_CAPABLE:
        // No: the App Store forbids it (an IOS build of the core asks, and
        // has no JIT to use anyway).
        if (data) *(bool *)data = false;
        return true;

    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
        if (data) {
            const auto *info = (const retro_system_av_info *)data;
            // The core's 60 is not its frame rate (`kCTRFramesPerSecond`).
            if (info->timing.sample_rate > 1000.0) _sampleRate = (unsigned)info->timing.sample_rate;
        }
        return true;

    case RETRO_ENVIRONMENT_SET_VARIABLES:
        [self recordDeclaredOptions:(const retro_variable *)data];
        return true;

    case RETRO_ENVIRONMENT_SET_MESSAGE: {
        auto *m = (const retro_message *)data;
        if (m && m->msg) {
            _lastCoreMessage = m->msg;
            os_log_error(CTRLog(), "[core message] %{public}s", m->msg);
        }
        return true;
    }

    case RETRO_ENVIRONMENT_SET_MESSAGE_EXT: {
        auto *m = (const retro_message_ext *)data;
        if (m && m->msg) {
            _lastCoreMessage = m->msg;
            os_log_error(CTRLog(), "[core message] %{public}s", m->msg);
        }
        return true;
    }

    case RETRO_ENVIRONMENT_SET_GEOMETRY:
    case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS:
    case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK:
    case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL:
    case RETRO_ENVIRONMENT_SET_HW_SHARED_CONTEXT:
        return true;

    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL:
        // All declined, so the core falls back to SET_VARIABLES, the one
        // format `recordDeclaredOptions:` reads. Accepting v1 here without
        // reading it (the PSP's list) would stop the core at v1: no default
        // recorded, no override checked.
        return false;

    case RETRO_ENVIRONMENT_SHUTDOWN:
        // The game closed itself, or an in-game reboot left the console off
        // (patch 0021): retro_run returned without a frame and never will
        // again. Said once; the game screen pauses and offers to quit.
        if (!_gameEnded.exchange(true)) {
            os_log_error(CTRLog(), "the game has ended: %{public}s", _lastCoreMessage.c_str());
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:CTRBridgeGameEndedNotification
                                                                    object:self];
            });
        }
        return true;

    default:
        return false;
    }
}

#pragma mark - ROM management

- (void)setSystemDirectory:(NSString *)path {
    _systemDirectory = path.length ? std::string(path.fileSystemRepresentation) : std::string();
    if (path.length) {
        // Created here: the core makes <it>/Azahar/ but not <it>, and falls
        // back silently to the user's home when that fails (see the header).
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES
                                                      attributes:nil error:&error]) {
            os_log_error(CTRLog(), "the 3DS folder could not be created: %{public}s",
                         error.localizedDescription.UTF8String);
        }
    }
}

- (BOOL)loadROMAtPath:(NSString *)path {
    if (!path.length) return NO;
    if (![NSFileManager.defaultManager isReadableFileAtPath:path]) {
        os_log_error(CTRLog(), "cannot read %{public}s", path.lastPathComponent.UTF8String);
        return NO;
    }
    if (_romLoaded) {
        os_log_error(CTRLog(), "a second game was loaded into the same bridge; refused");
        return NO;
    }
    if (_systemDirectory.empty()) {
        // Never left to the core: it would choose the user's home.
        os_log_error(CTRLog(), "no 3DS folder set before the load; refused");
        return NO;
    }
    CTRMemoryDiag("before the load");
    if (!_coreInitialised) {
        retro_init();
        _coreInitialised = YES;
    }

    _romPath = std::string(path.fileSystemRepresentation);
    _hasHWRender = NO;
    _negotiation = NULL;
    _lastCoreMessage.clear();

    // An encrypted game is told from its own header first (CTRGameProbe, the
    // core's own test): the core refuses it too, but says "Failed to load ROM
    // metadata." on a .3ds (measured on the host), not why. The importer
    // refuses an encrypted game by name (ROMImportError.ctrEncrypted), so one
    // reaches this only if its file was replaced on disk since.
    const CTRGameProbeAnswer probe = CTRGameProbeRead(_romPath.c_str());
    if (probe != CTRGameProbeDecrypted) {
        os_log_error(CTRLog(), "%{public}s refused before the core: %{public}s",
                     path.lastPathComponent.UTF8String,
                     probe == CTRGameProbeEncrypted ? "encrypted" : "not a 3DS game");
        return NO;
    }

    retro_game_info info;
    memset(&info, 0, sizeof(info));
    info.path = _romPath.c_str();

    const bool loaded = retro_load_game(&info);
    CTRMemoryDiag("after retro_load_game");
    if (!loaded) {
        // A decrypted file the core still refuses: damaged, or of a kind it
        // does not read (a GBA Virtual Console title, for one). Its message,
        // logged above, says which.
        os_log_error(CTRLog(), "retro_load_game refused %{public}s: %{public}s",
                     path.lastPathComponent.UTF8String, _lastCoreMessage.c_str());
        retro_unload_game();
        _vulkan.destroy();
        return NO;
    }
    if (!_hasHWRender
        || !_vulkan.createDevice(_negotiation, (unsigned)CTRPictureWidth, (unsigned)CTRPictureHeight)) {
        os_log_error(CTRLog(), "no Vulkan device for %{public}s; the game cannot be drawn",
                     path.lastPathComponent.UTF8String);
        retro_unload_game();
        _vulkan.destroy();
        return NO;
    }
    // The core boots the game here, once its renderer exists
    // (citra_libretro.cpp, context_reset -> do_load_game); a failure there is
    // a game that loads no further.
    CTRMemoryDiag("Vulkan device made, before the boot");
#if DEBUG
    const uint64_t bootStartNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
#endif
    _lastCoreMessage.clear();
    if (_hwRender.context_reset) _hwRender.context_reset();
    _contextLive = YES;
    // The boot itself (do_load_game) runs inside context_reset, and its
    // failure is only a message (citra_libretro.cpp, every `return false`
    // there posts one; nothing else does during the reset): the core then runs
    // empty frames for ever, a black picture and no error (audit, 2026-10-20).
    // Refused here, the app says the game could not be loaded.
    if (!_lastCoreMessage.empty()) {
        os_log_error(CTRLog(), "%{public}s did not boot: %{public}s",
                     path.lastPathComponent.UTF8String, _lastCoreMessage.c_str());
        [self unloadGame];
        return NO;
    }
    CTRMemoryDiag("booted (shader caches loaded)");
    CTRDiag("boot took %.0f ms",
            (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - bootStartNs) / 1e6);

    _romLoaded = YES;
    // The cheat engine lives in the core's System, which outlives the game:
    // reopening the same title kept the last session's list (LoadCheatFile
    // skips a title already loaded), and the app's saved cheats were then set
    // on top, each running twice (audit, 2026-10-20). The app sets them again
    // after every load (`applySavedCheats`), from an empty list.
    retro_cheat_reset();
    _cheatCount = 0;
    _hasRunFrame = NO;
    _displayLostReported = NO;
    _gameEnded = false;
    _hideFrames = 0;
    _audio.Clear();

    retro_system_av_info av;
    memset(&av, 0, sizeof(av));
    retro_get_system_av_info(&av);
    // NOT the core's figure: Azahar's libretro port answers a round 60.0
    // (environment.cpp, retro_get_system_av_info), while a frame it emulates is
    // one 3DS screen refresh, FRAME_TICKS = 4,481,136 cycles of the 268,111,856
    // Hz ARM11 clock: 59.8312 Hz, and its sound is 32,728 Hz (547 samples a
    // frame). Paced at 60, the game made 92 samples a second more than were
    // played: the ring filled in three minutes, the sound fell half a second
    // behind and dropped samples every frame after (audit, 2026-10-20). The
    // DS's bridge declares its own exact 59.8261 the same way.
    (void)av.timing.fps;
    _framesPerSecond = kCTRFramesPerSecond;
    if (av.timing.sample_rate > 1000.0) _sampleRate = (unsigned)av.timing.sample_rate;
    CTRDiag("loaded %{public}s | %.4f fps | %u Hz | %ux%u | language %{public}s",
            path.lastPathComponent.UTF8String, _framesPerSecond, _sampleRate,
            av.geometry.base_width, av.geometry.base_height, CTRSystemLanguage());
    return YES;
}

- (void)unloadGame {
    // The camera's way in goes first, under the lock every frame takes: after
    // the unload, a frame already on its way refilled the core's buffer the
    // camera's shutdown had just emptied, and the next game's camera started
    // on this one's picture (audit, 2026-10-20).
    {
        std::lock_guard<std::mutex> lock(sCTRCameraLock);
        sCTRCameraFrame = NULL;
    }
    _vulkan.drainQueue();
    if (_contextLive && _hwRender.context_destroy) _hwRender.context_destroy();
    _contextLive = NO;
    retro_unload_game();
    _vulkan.destroy();
    _romLoaded = NO;
    _cheatCount = 0;
    if (_cameraRunning) [self cameraShouldRun:NO];
}

- (void)reset {
    if (!_romLoaded) return;
    // NOT before the first frame. The session resets every core right after
    // loading it (for the cartridge cores that is what reads the battery
    // save; the 3DS has none, its saves are files the game reads itself),
    // and here a reset is a whole second boot: Azahar's retro_reset shuts the
    // system down and loads the game again, GPU, renderer and every cached
    // pipeline rebuilt (System::Shutdown, do_load_game). On the phone that
    // was two of the seconds before a resumed game appeared (2026-10-19).
    // Skipped, nothing is lost: the game is exactly where a reset would put
    // it. As PSPBridge does for the same call.
    if (!_hasRunFrame) {
        CTRDiag("reset skipped: the game has just booted");
        return;
    }
    std::lock_guard<std::mutex> lock(_coreLock);
    // A full reboot of the game (citra_libretro.cpp: Shutdown, then load).
    _vulkan.beginFrame();
    retro_reset();
    _hideFrames = kStaleFramesAfterLoad;
    _audio.Clear();
    [self invalidateRewind];
}

/// The 3DS's saves are files the game writes into its own save data on the
/// emulated SD card / NAND (<system>/Azahar/sdmc, nand), as it writes them:
/// there is no battery buffer for the bridge to load or flush.
- (void)setSavePath:(NSString *)path { (void)path; }
- (void)flushSaveData {}

#pragma mark - Emulation

- (void)runFrame {
    if (!_romLoaded || _gameEnded) return;
    std::lock_guard<std::mutex> lock(_coreLock);
    const uint64_t before = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    _vulkan.beginFrame();
    CTRMicNewFrame(self.framesPerSecond);
    retro_run();
    _hasRunFrame = YES;
    if (_hideFrames > 0) _hideFrames--;
    const uint64_t after = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    // What a rewind snapshot waits on: a frame that left room in its budget.
    _rwLastFrameMs = (double)(after - before) / 1e6;
#if DEBUG
    [self notePerformance:after - before at:after];
#endif
}

#if DEBUG
/// Emulated frames per second and a frame's cost, every two seconds: the
/// question this console opens with (Majora's Mask 3D in Low Power Mode).
- (void)notePerformance:(uint64_t)elapsedNs at:(uint64_t)nowNs {
    const double budgetMs = 1000.0 / self.framesPerSecond;
    if (_perfWindowStartNs == 0) {
        _perfWindowStartNs = nowNs;
        return;
    }
    _perfFrames++;
    _perfRunNs += elapsedNs;
    if (elapsedNs > _perfWorstNs) _perfWorstNs = elapsedNs;
    if ((double)elapsedNs / 1e6 > budgetMs) _perfOverBudget++;
    const uint64_t window = nowNs - _perfWindowStartNs;
    if (window < 2000000000ULL) return;
    const double n = _perfFrames ? (double)_perfFrames : 1.0;
    double footprint, left;
    CTRMemory(&footprint, &left);
    CTRDiag("%.1f fps emulated | %.2f ms per frame | worst %.1f ms | %llu of %llu frames over the %.1f ms budget | app %.0f MB, %.0f MB left",
            (double)_perfFrames / ((double)window / 1e9), (double)_perfRunNs / n / 1e6,
            (double)_perfWorstNs / 1e6, _perfOverBudget, _perfFrames, budgetMs, footprint, left);
    _perfWindowStartNs = nowNs;
    _perfFrames = _perfRunNs = _perfWorstNs = _perfOverBudget = 0;
}
#endif

- (void)setKeys:(uint32_t)keys { _buttons = keys; }

- (void)setStickX:(float)x y:(float)y {
    _stickX = CTRClampAxis(x);
    _stickY = CTRClampAxis(y);
}

- (void)setCStickX:(float)x y:(float)y {
    _cStickX = CTRClampAxis(x);
    _cStickY = CTRClampAxis(y);
}

#pragma mark - Input

- (int16_t)inputStateForPort:(unsigned)port device:(unsigned)device index:(unsigned)index buttonID:(unsigned)buttonID {
    // One player: the 3DS had one pad.
    if (port != 0) return 0;
    if (device == RETRO_DEVICE_JOYPAD) {
        const uint32_t keys = _buttons.load();
        if (buttonID == RETRO_DEVICE_ID_JOYPAD_MASK) {
            int16_t mask = 0;
            for (auto &m : kButtonMap) if (keys & m.ours) mask |= (int16_t)(1 << m.theirs);
            return mask;
        }
        for (auto &m : kButtonMap) if (buttonID == m.theirs) return (keys & m.ours) ? 1 : 0;
        return 0;
    }
    if (device == RETRO_DEVICE_ANALOG && index == RETRO_DEVICE_INDEX_ANALOG_LEFT) {
        // The circle pad, from the page's stick or a controller's left stick.
        // The cross is the 3DS's D-pad and only that (kButtonMap).
        return buttonID == RETRO_DEVICE_ID_ANALOG_X ? _stickX.load() : _stickY.load();
    }
    if (device == RETRO_DEVICE_ANALOG && index == RETRO_DEVICE_INDEX_ANALOG_RIGHT) {
        // The C-stick (citra_analog_function above).
        return buttonID == RETRO_DEVICE_ID_ANALOG_X ? _cStickX.load() : _cStickY.load();
    }
    if (device == RETRO_DEVICE_POINTER) {
        if (!_touching.load()) return 0;
        switch (buttonID) {
        case RETRO_DEVICE_ID_POINTER_PRESSED: return 1;
        case RETRO_DEVICE_ID_POINTER_X: return CTRPointerAxis(_touchX.load(), CTRPictureWidth);
        case RETRO_DEVICE_ID_POINTER_Y: return CTRPointerAxis(_touchY.load(), CTRPictureHeight);
        default: return 0;
        }
    }
    return 0;
}

- (void)setAccelerationX:(float)ax y:(float)ay z:(float)az
               rotationX:(float)gx y:(float)gy z:(float)gz {
    sCTRAccel[0].store(ax, std::memory_order_relaxed);
    sCTRAccel[1].store(ay, std::memory_order_relaxed);
    sCTRAccel[2].store(az, std::memory_order_relaxed);
    sCTRGyro[0].store(gx, std::memory_order_relaxed);
    sCTRGyro[1].store(gy, std::memory_order_relaxed);
    sCTRGyro[2].store(gz, std::memory_order_relaxed);
}

- (void)cameraShouldRun:(BOOL)run {
    _cameraRunning = run;
    void (^handler)(BOOL, BOOL) = self.cameraHandler;
    if (handler) handler(run, _cameraInner);
}

- (void)deliverCameraFrame:(const void *)pixels width:(NSInteger)width height:(NSInteger)height
               bytesPerRow:(NSInteger)bytesPerRow {
    if (!pixels || width <= 0 || height <= 0) return;
    std::lock_guard<std::mutex> lock(sCTRCameraLock);
    if (sCTRCameraFrame) {
        sCTRCameraFrame((const uint32_t *)pixels, (unsigned)width, (unsigned)height, (size_t)bytesPerRow);
    }
}

- (void)setMicBlowActive:(BOOL)active {
    sCTRMicBlow.store(active, std::memory_order_relaxed);
    if (!active) sCTRMicBlowPos = 0;
}

#pragma mark - Touch screen

/// A touch at (x, y) in the composed picture's pixels (0...399, 0...479).
/// Only the bottom screen (`CTRBottomScreenRect`) is a touch screen; the core
/// itself ignores a press outside it (mouse_tracker.cpp, IsWithinTouchscreen).
- (void)touchScreenAtX:(int)x y:(int)y {
    _touchX = x;
    _touchY = y;
    _touching = true;
}

- (void)touchScreenRelease {
    _touching = false;
}

#pragma mark - Video

- (void)handleVideo:(const void *)data width:(unsigned)width height:(unsigned)height {
    if (!data || width == 0 || height == 0 || data != RETRO_HW_FRAME_BUFFER_VALID) return;
    if (width > (unsigned)CTRPictureWidth)   width  = (unsigned)CTRPictureWidth;
    if (height > (unsigned)CTRPictureHeight) height = (unsigned)CTRPictureHeight;

    uint32_t *target = _hideFrames > 0 ? _hiddenBuffer.data() : _frameBuffer.data();
    if (_vulkan.readFrame(width, height, target, (size_t)CTRPictureWidth)) {
        if (_hideFrames > 0) return;
        _liveWidth = width;
        _liveHeight = height;
    } else if (_vulkan.readbackLost() && !_displayLostReported) {
        _displayLostReported = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:CTRBridgeDisplayLostNotification
                                                                object:self];
        });
    }
}

- (const uint32_t *)frameBuffer {
    return _romLoaded ? _frameBuffer.data() : NULL;
}

/// A still of the top screen (the 3DS's main picture), for save previews and
/// the library, as the DS's is its top screen.
- (CGImageRef)createFrameImage {
    if (!_romLoaded) return NULL;
    const uint32_t w = _liveWidth.load();
    const uint32_t h = _liveHeight.load();
    if (!w || !h) return NULL;
    const size_t topHeight = MIN((size_t)h, (size_t)CTRBottomScreenRect.origin.y);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(_frameBuffer.data(), w, topHeight, 8,
                                             (size_t)CTRPictureWidth * sizeof(uint32_t), colorSpace,
                                             (CGBitmapInfo)kCGBitmapByteOrder32Big
                                             | (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGImageRef image = NULL;
    if (ctx) {
        image = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(colorSpace);
    return image;
}

/// Both screens, the whole composed picture (the top screen over the bottom
/// one, centred, black either side of it), for the share cards and the clips:
/// what the player sees, the touch screen included (audit, 2026-10-20: they
/// showed the top screen alone). Its size is the grid the share cards' video
/// filters draw on (`EmulatorSession.screenshotPixelGrid`), which a top-screen
/// still was not. The save previews and the library keep the top screen
/// (`createFrameImage`), as the DS's do.
- (CGImageRef)createDualScreenFrameImage {
    if (!_romLoaded) return NULL;
    const uint32_t w = _liveWidth.load();
    const uint32_t h = _liveHeight.load();
    if (!w || !h) return NULL;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(_frameBuffer.data(), w, h, 8,
                                             (size_t)CTRPictureWidth * sizeof(uint32_t), colorSpace,
                                             (CGBitmapInfo)kCGBitmapByteOrder32Big
                                             | (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGImageRef image = NULL;
    if (ctx) {
        image = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(colorSpace);
    return image;
}
- (void)setGBPalette:(const uint32_t *)colors { (void)colors; }
- (BOOL)isDMGPaletteApplicable { return NO; }

#pragma mark - Save states

- (BOOL)saveStateToPath:(NSString *)path {
    // A game that has ended is not saved: its state is the console closing
    // (or off), and the quit's auto-save must not replace a good one with it.
    if (!_romLoaded || _gameEnded) return NO;
    std::vector<uint8_t> state;
    {
        std::lock_guard<std::mutex> lock(_coreLock);
        // Measured every time: the size varies (the core declares
        // RETRO_SERIALIZATION_QUIRK_CORE_VARIABLE_SIZE). Measuring also
        // serializes (the core keeps the bytes for retro_serialize).
        _vulkan.beginFrame();
        const size_t size = retro_serialize_size();
        if (!size) return NO;
        try { state.resize(size); } catch (...) { return NO; }
        if (!retro_serialize(state.data(), size)) return NO;
    }
    std::vector<uint8_t> file;
    if (!CTRStateFormatPack(state.data(), state.size(), file)) {
        os_log_error(CTRLog(), "state %{public}s not written: the core produced no Azahar state",
                     path.lastPathComponent.UTF8String);
        return NO;
    }
    CTRDiag("state %{public}s: %zu bytes, file %zu", path.lastPathComponent.UTF8String, state.size(), file.size());
    return [[NSData dataWithBytes:file.data() length:file.size()] writeToFile:path atomically:YES];
}

- (BOOL)loadStateFromPath:(NSString *)path {
    if (!_romLoaded) return NO;
    NSData *file = [NSData dataWithContentsOfFile:path];
    std::vector<uint8_t> state;
    if (!file || !CTRStateFormatUnpack((const uint8_t *)file.bytes, file.length, state)) {
        os_log_error(CTRLog(), "state %{public}s refused: not a 3DS state this app wrote, or damaged",
                     path.lastPathComponent.UTF8String);
        return NO;
    }
    std::lock_guard<std::mutex> lock(_coreLock);
    _vulkan.beginFrame();
#if DEBUG
    const uint64_t loadStartNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
#endif
    // The core refuses a state of another game or another core version
    // (core/savestate.cpp) and says so in its log.
    if (!retro_unserialize(state.data(), state.size())) return NO;
    CTRDiag("state load took %.0f ms (the console rebuilt, the renderer kept: patch 0016)",
            (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - loadStartNs) / 1e6);
    _hideFrames = kStaleFramesAfterLoad;
    _audio.Clear();
    [self invalidateRewind];
    return YES;
}

#pragma mark - Memory (RetroAchievements)

/// RetroAchievements has no Nintendo 3DS set: nothing reads this.
- (NSInteger)readMemoryAtAddress:(uint32_t)address into:(uint8_t *)buffer length:(NSInteger)length {
    (void)address; (void)buffer; (void)length;
    return 0;
}

#pragma mark - Speed

- (void)setSpeedMultiplier:(int)multiplier { (void)multiplier; }

#pragma mark - Audio

- (unsigned int)audioSampleRate { return _sampleRate; }

- (void)handleAudio:(const int16_t *)frames count:(size_t)count {
    if (frames && count) _audio.Write(frames, count);
}

- (NSInteger)readAudioSamples:(int16_t *)buffer count:(NSInteger)count {
    if (!buffer || count <= 0) return 0;
    return (NSInteger)_audio.Read(buffer, (size_t)count);
}

- (unsigned int)consumePendingAudioRate { return 0; }

#pragma mark - Rewind
//
// MEASURED ON THE HOST first (Tools/3ds-bench rewind, Majora's Mask 3D and
// Craftus Reloaded, 2026-10-20). A New 3DS state is 296 MB, nearly all of it
// the four emulated memories (VRAM, FCRAM, the New 3DS's extra RAM, the DSP's
// RAM); taken the ordinary way it cost 590 to 860 ms (the compression) and
// loading it back a full rebuild of the console. So, three patches to the core:
//   0014  the state raw, without its compression, into a buffer kept here;
//   0015  without the four memories (the bridge keeps its own copy of them and
//         writes it back after a restore), and the page tables as runs:
//         the core's part of a snapshot 12 to 16 ms instead of 136;
//   0016  a load that keeps the renderer: a restore ~100 ms instead of ~300 to
//         500 (on the phone the renderer was most of a 4.3 s load).
// Every restore was checked against the ordinary state of the same moment:
// the same picture and sound, frame after frame.
//
// A SNAPSHOT, every five seconds of emulated time, after a frame that left
// kRewindSnapshotHeadroomMs of its budget (or after kRewindDueDeadlineFrames):
//   - on the emulation thread, the core lock held: the state without the
//     memories (~12 ms on the host), and the four memories compared with the
//     bridge's copy in 4 KiB blocks on every core at once (dispatch_apply,
//     ~11 ms on the host for 296 MB, memory-bound): each block that changed
//     goes into the step as it WAS, then the copy takes the new one;
//   - off the emulation thread: the older state compared with the newer in
//     4 KiB blocks, the step packed with LZ4 and put in the ring.
// A STEP turns the newer snapshot back into the older one: its state blocks
// and its memory blocks, as they were. Rewinding applies the newest steps to
// the anchor, restores the state (the core rebuilds what is not the memories)
// and writes the bridge's copy of the memories into the core's.
//
// MEMORY. The copy of the memories is the whole of them (296 MB for a New 3DS
// game, 140 for an Old 3DS one) and the two states 2 x 8 to 15 MB: taken only
// when the app can spare them with kRewindMemoryReserve over; the history has a
// ceiling, oldest steps first; and under the reserve during play the history is
// dropped. The rewind gets shorter, the game is never killed for it.
//
// ON A MEMORY WARNING (2026-10-20): everything the rewind holds is given back,
// the copy of the memories included, which the reserve checks above never
// freed: they run only when a snapshot is taken, so a game paused or in the
// background kept its 296 MB through any warning. The rewind starts again
// kRewindPressurePauseSeconds later if the app can spare it then (a new
// anchor, its buffers made off the emulation thread as at boot); a second
// warning in the same game turns it off for that game, so it never loops
// between taking memory and giving it back.

- (void)initRewind:(NSInteger)seconds {
    std::lock_guard<std::mutex> lock(_coreLock);
    [self teardownRewind];
    if (seconds <= 0 || !_romLoaded) return;
    _rwDepth = MAX((NSInteger)1, seconds / kRewindSecondsPerSnapshot);
    _rwSteps.assign((size_t)_rwDepth, CTRRewindStep{});
    _rwNewest = -1;
    _rwStored = 0;
    _rwDue = YES;
    _rwDueFrames = 0;
    // Posted on the main thread, which runs the frames: the release waits for
    // the core lock on a queue of its own instead (a state save holds it for
    // seconds on the session's work queue).
    __weak CTRBridge *weakSelf = self;
    _rwMemoryWarningObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:nil
                usingBlock:^(NSNotification *note) {
        (void)note;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [weakSelf releaseRewindForMemoryWarning];
        });
    }];
}

/// On a memory warning: see "Rewind" above.
- (void)releaseRewindForMemoryWarning {
    std::lock_guard<std::mutex> lock(_coreLock);
    if (_rwDepth <= 0 || _rwRefused) return;
    [self waitForRewindPacking];
    size_t held = _rwHistoryBytes + _rwState.capacity() + _rwNextState.capacity();
    for (const auto &memory : _rwMemory) held += memory.capacity();
    // Nothing held (already given back, iOS warns in bursts): nothing to do,
    // and it is not a second warning. One counts only once the rewind has
    // taken its memory again after the first (his log, 10-20: two warnings in
    // one second turned it off for good).
    if (held == 0) return;
    if (_rwPressureReleases > 0) {
        os_log_error(CTRLog(), "rewind off for this game: a second memory warning, %zu MB given back",
                     held >> 20);
        [self refuseRewind];
        return;
    }
    _rwPressureReleases++;
    [self dropRewindHistory];
    std::vector<uint8_t>().swap(_rwState);
    std::vector<uint8_t>().swap(_rwNextState);
    for (auto &memory : _rwMemory) std::vector<uint8_t>().swap(memory);
    _rwHasAnchor = NO;
    _rwDue = NO;
    _rwPressureWaitFrames = (NSInteger)llround(self.framesPerSecond * kRewindPressurePauseSeconds);
    os_log_error(CTRLog(), "rewind paused on a memory warning: %zu MB given back, again in %ld s if it can be spared",
                 held >> 20, (long)kRewindPressurePauseSeconds);
}

- (void)dropRewindHistory {
    for (CTRRewindStep &step : _rwSteps) CTRRewindFreeStep(step);
    _rwStored = 0;
    _rwNewest = -1;
    _rwHistoryBytes = 0;
}

- (void)dropOldestRewindStep {
    if (_rwStored <= 0) return;
    const NSInteger oldest = (_rwNewest - _rwStored + 1 + _rwDepth) % _rwDepth;
    _rwHistoryBytes -= _rwSteps[(size_t)oldest].packedLength;
    CTRRewindFreeStep(_rwSteps[(size_t)oldest]);
    _rwStored--;
}

- (void)waitForRewindPacking {
    if (_rwPackQueue) dispatch_sync(_rwPackQueue, ^{});
}

- (void)teardownRewind {
    [self waitForRewindPacking];
    [self dropRewindHistory];
    _rwSteps.clear();
    std::vector<uint8_t>().swap(_rwState);
    std::vector<uint8_t>().swap(_rwNextState);
    for (auto &memory : _rwMemory) std::vector<uint8_t>().swap(memory);
    _rwDepth = 0;
    _rwHasAnchor = NO;
    _rwDue = NO;
    _rwDueFrames = 0;
    _rwFrameCounter = 0;
    _rwRefused = NO;
    _rwPressureReleases = 0;
    _rwPressureWaitFrames = 0;
    if (_rwMemoryWarningObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_rwMemoryWarningObserver];
        _rwMemoryWarningObserver = nil;
    }
}

/// No rewind for the rest of this game, and its memory given back.
- (void)refuseRewind {
    [self waitForRewindPacking];
    [self dropRewindHistory];
    std::vector<uint8_t>().swap(_rwState);
    std::vector<uint8_t>().swap(_rwNextState);
    for (auto &memory : _rwMemory) std::vector<uint8_t>().swap(memory);
    _rwHasAnchor = NO;
    _rwDue = NO;
    _rwRefused = YES;
}

/// A state load or a reset: another timeline. The jump is the first place
/// the new one can rewind to.
- (void)invalidateRewind {
    [self waitForRewindPacking];
    [self dropRewindHistory];
    _rwHasAnchor = NO;
    _rwFrameCounter = 0;
    if (_rwDepth > 0 && !_rwRefused) {
        _rwDue = YES;
        _rwDueFrames = 0;
    }
}

/// After every frame, on the emulation thread.
- (void)rewindAppend {
    if (_rwDepth <= 0 || _rwRefused || !_romLoaded || !_hasRunFrame) return;
    std::lock_guard<std::mutex> lock(_coreLock);

    // After a memory warning: nothing held, nothing taken until the pause ends.
    if (_rwPressureWaitFrames > 0) {
        if (--_rwPressureWaitFrames > 0) return;
        _rwFrameCounter = 0;
        _rwDue = YES;
        _rwDueFrames = 0;
    }
    const NSInteger interval = (NSInteger)llround(self.framesPerSecond * kRewindSecondsPerSnapshot);
    if (++_rwFrameCounter >= interval) {
        _rwFrameCounter = 0;
        if (!_rwDue) {
            _rwDue = YES;
            _rwDueFrames = 0;
        }
    }
    if (!_rwDue) return;
    _rwDueFrames++;
    if (_rwPackInFlight.load()) return;
    const double budgetMs = 1000.0 / self.framesPerSecond;
    if (_rwLastFrameMs > budgetMs - kRewindSnapshotHeadroomMs && _rwDueFrames < kRewindDueDeadlineFrames) return;
    _rwDue = NO;
    [self takeRewindSnapshot];
}

/// Whether the app can spare `bytes` more and still keep the reserve.
static BOOL CTRRewindCanSpare(size_t bytes) {
    const size_t available = os_proc_available_memory();
    return available == 0 || available >= bytes + kRewindMemoryReserve;
}

/// With the core lock held, on the emulation thread.
- (void)takeRewindSnapshot {
#if DEBUG
    const uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
#endif
    CTRRewindRegion regions[4] = {};
    _vulkan.beginFrame();
    // The first snapshot needs the memories' copy too: room for it first,
    // counting only what is still to be allocated. The buffers made on the
    // pack queue for this very anchor, or kept across a state load, are
    // already in the app's footprint: counted again, they turned the rewind
    // off on a phone with 576 to 842 MB free (audit, 2026-10-20).
    size_t held = _rwState.capacity() + _rwNextState.capacity();
    for (const auto &memory : _rwMemory) held += memory.capacity();
    const size_t anchorBytes = 320u * 1024u * 1024u;
    if (!_rwHasAnchor && !CTRRewindCanSpare(anchorBytes > held ? anchorBytes - held : 0)) {
        // After a memory warning: not now, rather than never.
        if (_rwPressureReleases > 0) {
            os_log_error(CTRLog(), "rewind still paused: %zu MB free, it needs ~320 MB plus a reserve",
                         os_proc_available_memory() >> 20);
            _rwPressureWaitFrames = (NSInteger)llround(self.framesPerSecond * kRewindPressurePauseSeconds);
            return;
        }
        os_log_error(CTRLog(), "rewind off for this game: %zu MB free, it needs ~320 MB plus a reserve",
                     os_proc_available_memory() >> 20);
        [self refuseRewind];
        return;
    }
    std::vector<uint8_t> &target = _rwHasAnchor ? _rwNextState : _rwState;
    if (!retro_ctr_rewind_capture(&target, true, regions)) {
        os_log_error(CTRLog(), "rewind snapshot failed in the core");
        return;
    }
#if DEBUG
    const uint64_t t1 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
#endif
    void *live[4];
    size_t liveSize[4];
    for (int i = 0; i < 4; i++) { live[i] = regions[i].data; liveSize[i] = regions[i].size; }

    if (!_rwHasAnchor) {
        // The anchor: the memories copied whole, into buffers made ready
        // beforehand. Allocated here, on the emulation thread, the copy took
        // 1.3 s on an iPhone 14 Pro (Pokémon Sun, 266 MB, 2026-10-20): every
        // page of a fresh buffer is mapped and zeroed as the copy first touches
        // it, and the game stood still for it. So the first time, the buffers
        // are made on the pack queue, every page touched there, the anchor
        // stays due, and the next attempt (once the queue is idle) is a plain
        // copy into pages already there. A state load keeps the buffers.
        if (_rwAllocationFailed.exchange(false)) {
            os_log_error(CTRLog(), "rewind off for this game: the memories' copy could not be allocated");
            [self refuseRewind];
            return;
        }
        bool ready = true;
        for (int i = 0; i < 4; i++) ready = ready && _rwMemory[i].size() == liveSize[i];
        if (!ready) {
            _rwDue = YES;
            _rwPackInFlight = true;
            if (!_rwPackQueue) _rwPackQueue = dispatch_queue_create("retropal.ctr.rewind", DISPATCH_QUEUE_SERIAL);
            const std::array<size_t, 4> sizes = { liveSize[0], liveSize[1], liveSize[2], liveSize[3] };
            dispatch_async(_rwPackQueue, ^{
                bool made = true;
                try {
                    for (int i = 0; i < 4; i++) {
                        // resize writes zeros through every page: they are mapped here.
                        std::vector<uint8_t>().swap(self->_rwMemory[i]);
                        self->_rwMemory[i].resize(sizes[(size_t)i]);
                    }
                } catch (...) {
                    made = false;
                }
                if (!made) {
                    for (auto &memory : self->_rwMemory) std::vector<uint8_t>().swap(memory);
                    // Refused at the next attempt, on the emulation thread.
                    self->_rwAllocationFailed = true;
                }
                self->_rwPackInFlight = false;
            });
            return;
        }
        for (int i = 0; i < 4; i++) memcpy(_rwMemory[i].data(), live[i], liveSize[i]);
        _rwHasAnchor = YES;
        CTRDiag("[REWIND] anchor | state %.1f MB in %.1f ms | memories %.1f MB copied in %.1f ms",
                _rwState.size() / 1048576.0, (t1 - t0) / 1e6,
                (_rwMemory[0].size() + _rwMemory[1].size() + _rwMemory[2].size() + _rwMemory[3].size()) / 1048576.0,
                (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - t1) / 1e6);
        return;
    }

    // The memories' pass, on every core at once, while the game waits.
    auto records = std::make_shared<std::vector<std::vector<uint8_t>>>();
    const bool recorded = CTRRewindRecordMemories(live, liveSize, _rwMemory, *records,
        [](size_t n, const std::function<void(size_t)> &body) {
            dispatch_apply(n, DISPATCH_APPLY_AUTO, ^(size_t c) { body(c); });
        });
#if DEBUG
    const uint64_t t2 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
#endif
    if (!recorded) {
        // The copy is now partly newer than the anchor's state: start again.
        os_log_error(CTRLog(), "rewind: a step could not be recorded, history dropped");
        [self invalidateRewind];
        return;
    }

    // The rest off the emulation thread: the state compared, the step packed.
    _rwPackInFlight = true;
    if (!_rwPackQueue) _rwPackQueue = dispatch_queue_create("retropal.ctr.rewind", DISPATCH_QUEUE_SERIAL);
#if DEBUG
    const double coreMs = (t1 - t0) / 1e6, memoryMs = (t2 - t1) / 1e6;
#endif
    dispatch_async(_rwPackQueue, ^{
        CTRRewindStep step{};
        const bool kept = CTRRewindCanSpare(0)
            && CTRRewindBuildStep(self->_rwState, self->_rwNextState, *records, COMPRESSION_LZ4, step);
        if (!kept) {
            // A missing step would make every older one land wrong.
            CTRRewindFreeStep(step);
            [self dropRewindHistory];
            os_log_error(CTRLog(), "rewind history dropped: %zu MB free", os_proc_available_memory() >> 20);
        } else {
            if (self->_rwStored == self->_rwDepth) [self dropOldestRewindStep];
            while (self->_rwStored > 0 && self->_rwHistoryBytes + step.packedLength > kRewindHistoryByteCeiling) {
                [self dropOldestRewindStep];
            }
            const NSInteger slot = (self->_rwNewest + 1) % self->_rwDepth;
            self->_rwSteps[(size_t)slot] = step;
            self->_rwNewest = slot;
            self->_rwStored++;
            self->_rwHistoryBytes += step.packedLength;
        }
        // The newer state is the anchor's now.
        self->_rwState.swap(self->_rwNextState);
#if DEBUG
        CTRDiag("[REWIND] snapshot | state %.1f ms, memories %.1f ms (on the emulation thread) | step %.2f MB, "
                "%.2f MB packed | %ld of %ld steps, %.1f MB",
                coreMs, memoryMs, step.rawLength / 1048576.0, step.packedLength / 1048576.0,
                (long)self->_rwStored, (long)self->_rwDepth, self->_rwHistoryBytes / 1048576.0);
#endif
        self->_rwPackInFlight = false;
    });
}

/// Rewinds `count` sixtieths of a second (what EmulatorViewController asks),
/// to the nearest snapshot the ring holds; with no step stored, to the anchor.
- (BOOL)rewindFrames:(NSInteger)count {
    std::lock_guard<std::mutex> lock(_coreLock);
    if (!_romLoaded) return NO;
    [self waitForRewindPacking];
    if (!_rwHasAnchor) {
        CTRDiag("[REWIND] refused: no anchor (depth %ld, refused %d, paused %ld frames)",
                (long)_rwDepth, _rwRefused, (long)_rwPressureWaitFrames);
        return NO;
    }
#if DEBUG
    const uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
#endif
    const NSInteger perSnapshot = kRewindSecondsPerSnapshot * 60;
    NSInteger steps = (count + perSnapshot / 2) / perSnapshot;
    steps = MIN(MAX((NSInteger)1, steps), _rwStored);
    NSInteger applied = 0;
    while (applied < steps) {
        CTRRewindStep &step = _rwSteps[(size_t)_rwNewest];
        if (!CTRRewindApplyStep(step, COMPRESSION_LZ4, _rwState, _rwMemory)) break;
        _rwHistoryBytes -= step.packedLength;
        CTRRewindFreeStep(step);
        _rwNewest = (_rwNewest - 1 + _rwDepth) % _rwDepth;
        _rwStored--;
        applied++;
    }
    CTRRewindRegion regions[4] = {};
    _vulkan.beginFrame();
    const bool ok = retro_ctr_rewind_restore(_rwState.data(), _rwState.size(), true, regions);
    if (ok) {
        for (int i = 0; i < 4; i++) {
            if (regions[i].size == _rwMemory[i].size()) memcpy(regions[i].data, _rwMemory[i].data(), regions[i].size);
        }
    }
    CTRDiag("[REWIND] restored %ld of %ld steps (%ld s), %ld left, ok=%d, %.0f ms",
            (long)applied, (long)steps, (long)(applied * kRewindSecondsPerSnapshot), (long)_rwStored, ok,
            (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - t0) / 1e6);
    if (!ok) {
        [self invalidateRewind];
        return NO;
    }
    _rwFrameCounter = 0;
    _rwDue = NO;
    _hideFrames = kStaleFramesAfterLoad;
    _audio.Clear();
    return YES;
}

#pragma mark - Cheats
//
// Gateway codes ("XXXXXXXX YYYYYYYY", one per line), the 3DS's own format,
// into the core's Gateway engine through retro_cheat_set and
// retro_cheat_reset (patch 0011; they were empty). The engine runs the
// enabled cheats about five times a second, as Luma3DS does, and keeps them
// across a state load, which no longer doubles them (0011, Tools/3ds-bench
// cheat). A code with any line that is not Gateway is refused whole.

/// Every line eight hex digits, a space, eight hex digits: what the engine
/// accepts (GatewayCheat::CheatLine), checked here so a refusal reaches the
/// player rather than the core's log.
static bool CTRIsGatewayCode(NSString *code, std::string &out) {
    out.clear();
    bool any = false;
    for (NSString *raw in [code componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!line.length) continue;
        const char *c = line.UTF8String;
        if (strlen(c) != 17 || c[8] != ' ') return false;
        for (int i = 0; i < 17; i++) {
            if (i == 8) continue;
            if (!isxdigit((unsigned char)c[i])) return false;
        }
        out += c;
        out += '\n';
        any = true;
    }
    return any;
}

- (BOOL)addCheatCode:(NSString *)code type:(int)type {
    // One format: the session tries types 0 to 4 in turn, and 0 answers.
    if (type != 0 || !_romLoaded || !code.length) return NO;
    std::string lines;
    if (!CTRIsGatewayCode(code, lines)) return NO;
    // Not under the core lock: the cheat engine has its own
    // (cheats_list_mutex: a change takes it whole, the run inside a frame
    // shared), and a state save never touches the list. Under the core lock,
    // adding the first code waited on the main thread for the backup save the
    // cheat sheet had just started on the work queue (audit, 2026-10-20).
    retro_cheat_set(_cheatCount++, true, lines.c_str());
    return YES;
}

- (void)clearCheats {
    if (!_romLoaded) return;
    // Not under the core lock either (`addCheatCode`).
    retro_cheat_reset();
    _cheatCount = 0;
}

#pragma mark - Lifecycle

- (void)shutdown {
    std::lock_guard<std::mutex> lock(_coreLock);
    [self teardownRewind];
    if (_romLoaded) [self unloadGame];
    if (_coreInitialised) retro_deinit();
    _coreInitialised = NO;
    _frameBuffer.clear();
    _hiddenBuffer.clear();
    _audio.Clear();
    if (sCTRBridge == self) sCTRBridge = nil;
}

@end
