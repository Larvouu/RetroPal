//
//  PSPBridge.mm
//  EmulateurGBA
//
//  ObjC++ implementation bridging PPSSPP's own libretro port (PSP) to Swift.
//
//  HOW THIS CORE IS BUILT (the full reasons are in Vendor/ppsspp-ios/build.sh):
//  PPSSPP v1.20.4's libretro port, its CPU on the IR interpreter (the App Store
//  forbids JIT; the bridge answers GET_JIT_CAPABLE with no, and the port then
//  forces the interpreter), its picture drawn with Vulkan through MoltenVK.
//  The entry points are renamed psp_retro_* (psp_symbols.h, included first
//  below) so it can be linked beside PCSX-ReARMed, Mupen64Plus-Next and BlastEm.
//
//  THE PICTURE takes the Nintendo 64's path: the core asks for a Vulkan context
//  (SET_HW_RENDER), creates its device through ours, and names a Vulkan image
//  each frame; N64VulkanFrontend copies it into `_frameBuffer`, which every
//  frame consumer of the app reads. Unlike parallel-RDP, PPSSPP's port REQUIRES
//  a surface to create its device (it never presents to it), so the instance is
//  made with `Requirements::surface` and without parallel-RDP's storage check.
//  Proven on the host with the frontend compiled unchanged (Tools/psp-bench).
//
//  WHAT THE CORE DOES THAT NO OTHER CORE HERE DOES, each found on the host:
//   - IT BOOTS ASYNCHRONOUSLY. `retro_load_game` checks almost nothing and
//     answers true; the boot runs inside the first `retro_run` calls, and a
//     game the core cannot start fails THERE, by asking the frontend to shut
//     down (RETRO_ENVIRONMENT_SHUTDOWN). Calling `retro_run` after that runs
//     the CPU with no CPU core and crashes (a null MIPSComp::jit, seen in gdb).
//     So the bridge stops entering the core the moment it asks to shut down,
//     and tells the game screen (PSPBridgeBootFailedNotification). A reset
//     reboots the whole PSP and can fail the same way.
//   - IT READS A STATE WITHOUT A LENGTH. `retro_unserialize` ignores its size
//     argument and walks the buffer by the state's own structure, so a
//     truncated or damaged file is read past its end. Every slot this bridge
//     writes therefore carries our header (length and digest), and nothing
//     else is ever handed to the core.
//   - AFTER A STATE LOAD, ITS FIRST ONE OR TWO PICTURES ARE STALE (one seen
//     nowhere, one from early in the session; every later frame and all the
//     sound exact). Those frames are run but not shown (`_hideFrames`).
//   - ITS SAVES ARE A FOLDER: the memory stick, `PSP/SAVEDATA/<game id>/...`,
//     written by the game whenever it saves, not one battery file the bridge
//     flushes. The app gives it a folder per game (`setMemoryStickDirectory:`).
//

// The rename must come before ANY libretro header.
#include "psp_symbols.h"

#if !__has_include("libretro.h")
#error "libretro.h is missing. It comes from the PCSX-ReARMed submodule: git submodule update --init Vendor/pcsx_rearmed"
#endif

#import "PSPBridge.h"
#include "N64VulkanFrontend.h"

#include <atomic>
#include <cctype>
#include <cstdarg>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include <compression.h>
#import <os/log.h>
#include <os/proc.h>
#if DEBUG
#include <mach/mach.h>
#include <algorithm>
#endif

const NSInteger PSPMaxBufferWidth  = 480;
const NSInteger PSPMaxBufferHeight = 272;

/// The PSP's screen is 480x272 with square pixels, nearly 16:9.
static const CGFloat kPSPDisplayAspect = 480.0 / 272.0;

/// The core mixes the PSP's audio at 44.1 kHz itself (SAMPLERATE in the port).
static const unsigned int kPSPSampleRate = 44100;

static const size_t kAudioRingFrames = 16384;

/// After a state load, the frames that are run but not shown (see the header).
/// Two measured on five programs; MHFU's picture is right from the third.
static const int kStaleFramesAfterLoad = 2;

/// Rewind. The design and the measurements behind these numbers are in the
/// Rewind section at the end of the file.
static const NSInteger kRewindSecondsPerSnapshot = 5;
static const size_t kRewindBlock = 4096;
/// Ceiling on the packed history. Measured steps in play pack to about 1 MB
/// (MHFU), so this is a guard against a game nobody measured, not a working
/// figure: past it the OLDEST steps go, and the depth shrinks rather than the
/// memory grow.
static const size_t kRewindHistoryByteCeiling = 48u * 1024u * 1024u;
/// What the app must still have free (os_proc_available_memory) for the rewind
/// to hold memory at all, as on the N64. Below it the history is dropped and
/// no state buffer is allocated: a shorter rewind, never a jetsam.
static const size_t kRewindMemoryReserve = 128u * 1024u * 1024u;
/// A snapshot costs about 3 ms on the host (0.3 to measure, 2.5 to 3.7 to
/// write). It is taken after a frame that left at least this much of the
/// budget unused...
static const double kRewindSnapshotHeadroomMs = 6.0;
/// ...or after this many frames of waiting for one, whatever the cost.
static const NSInteger kRewindDueDeadlineFrames = 60;

/// One rewind step: the OLD contents of every block that changed between two
/// snapshots (or that the newer one does not reach), so that applying it to
/// the newer state gives back the older one, size included.
typedef struct {
    uint32_t *blocks;       // block indices, `count` of them, ascending
    uint8_t *packed;        // their old contents, LZ4 or as they were
    size_t packedLength;
    size_t rawLength;       // the old contents' length once unpacked
    size_t stateSize;       // the size of the state the step gives back
    uint32_t count;
    bool compressed;
} PSPRewindStep;

#if DEBUG
#define PSPDiag(fmt, ...) os_log_error(PSPLog(), "[PSP] " fmt, ##__VA_ARGS__)
#else
#define PSPDiag(fmt, ...) do { } while (0)
#endif

static os_log_t PSPLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.retropal.emulateurgba", "psp"); });
    return log;
}

NSNotificationName const PSPBridgeDisplayLostNotification = @"PSPBridgeDisplayLostNotification";
NSNotificationName const PSPBridgeBootFailedNotification = @"PSPBridgeBootFailedNotification";

#pragma mark - Core options

/// Every core option this bridge sets, and why. Anything not listed gets the
/// default the core declared (see `recordDeclaredOptions:`, the N64's lesson:
/// an option the frontend never answers stays at the C variable's zero).
struct PSPOption { const char *key; const char *value; };

static const PSPOption kCoreOptions[] = {
    // The IR interpreter: the App Store forbids a JIT. The core's own default
    // is "JIT"; it would also fall back here because GET_JIT_CAPABLE says no,
    // and it is stated rather than left to that fallback.
    { "ppsspp_cpu_core", "IR JIT" },

    // Vulkan, the one renderer this bridge has a frontend for. The default
    // "auto" asks GET_PREFERRED_HW_RENDER, which is answered too.
    { "ppsspp_backend", "vulkan" },

    // The PSP's own resolution. Higher ones multiply the GPU work and the
    // readback on a console whose first question is whether it holds speed.
    { "ppsspp_internal_resolution", "480x272" },

    // The cheat engine, which the app's cheat feature drives (CWCheat). Its
    // default is off.
    { "ppsspp_cheats", "enabled" },
};

static const char *PSPOptionValue(const char *key) {
    if (!key) return NULL;
    for (size_t i = 0; i < sizeof(kCoreOptions) / sizeof(kCoreOptions[0]); i++) {
        if (strcmp(kCoreOptions[i].key, key) == 0) return kCoreOptions[i].value;
    }
    return NULL;
}

/// The player's language for the PSP's system setting ("Automatic"), which
/// many games use for their own text, as a PSP set to that language would.
static unsigned PSPRetroLanguage(void) {
    NSString *code = NSLocale.preferredLanguages.firstObject ?: @"en";
    if ([code hasPrefix:@"ja"]) return RETRO_LANGUAGE_JAPANESE;
    if ([code hasPrefix:@"fr"]) return RETRO_LANGUAGE_FRENCH;
    if ([code hasPrefix:@"de"]) return RETRO_LANGUAGE_GERMAN;
    if ([code hasPrefix:@"es"]) return RETRO_LANGUAGE_SPANISH;
    if ([code hasPrefix:@"it"]) return RETRO_LANGUAGE_ITALIAN;
    if ([code hasPrefix:@"nl"]) return RETRO_LANGUAGE_DUTCH;
    if ([code hasPrefix:@"pt-BR"]) return RETRO_LANGUAGE_PORTUGUESE_BRAZIL;
    if ([code hasPrefix:@"pt"]) return RETRO_LANGUAGE_PORTUGUESE_PORTUGAL;
    if ([code hasPrefix:@"ko"]) return RETRO_LANGUAGE_KOREAN;
    if ([code hasPrefix:@"zh-Hant"]) return RETRO_LANGUAGE_CHINESE_TRADITIONAL;
    if ([code hasPrefix:@"zh"]) return RETRO_LANGUAGE_CHINESE_SIMPLIFIED;
    if ([code hasPrefix:@"ru"]) return RETRO_LANGUAGE_RUSSIAN;
    return RETRO_LANGUAGE_ENGLISH;
}

#pragma mark - Audio ring

/// Push-to-pull adapter, identical to the other libretro bridges'.
class PSPAudioRing {
public:
    PSPAudioRing() { _ring.resize(kAudioRingFrames * 2, 0); }

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

/// A slot's file: this header, then the state, packed with LZFSE when that
/// pays and as it is otherwise (`flags` says which). Always written, packed or
/// not, because the header is what makes a PSP state safe to load: the core
/// reads a state with no length (see the file header), so the length and the
/// digest are checked here before the core sees a byte.
///
/// Measured on the host: a state is about 38.7 MB (the PSP's 32 MB of RAM and
/// its video memory); MHFU's packs to about 7 MB, a demo's to about 1 MB.
static const char kPSPStateMagic[8] = { 'R', 'P', 'P', 'S', 'P', 'Z', '1', 0 };
static const size_t kPSPStateHeader = sizeof(kPSPStateMagic) + 3 * sizeof(uint64_t);
static const uint64_t kPSPStateFlagPacked = 1;

/// The core's own first bytes: its top-level section is named "SaveStart".
static const char kPSPCoreStateMagic[9] = { 'S', 'a', 'v', 'e', 'S', 't', 'a', 'r', 't' };

/// 64 bits over the state, as on the N64: tells a damaged file from a good one.
static uint64_t PSPStateDigest(const uint8_t *bytes, size_t length) {
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

/// The used length of what the core wrote: it pads its measured size up to
/// the next 8 MB, and the padding is zeroes.
static size_t PSPUsedLength(const uint8_t *bytes, size_t length) {
    while (length > 0 && bytes[length - 1] == 0) length--;
    return length;
}

// The format itself is plain C++ on byte buffers (PSPStateFormat, below the
// header constants) so it can be compiled and checked off the phone: the
// ObjC wrappers only move bytes in and out of NSData.

/// Packs `state` into `file` (cleared first). False when `state` is not a
/// PPSSPP state (its own magic missing) or memory runs out.
static bool PSPStateFormatPack(const uint8_t *state, size_t stateLength, std::vector<uint8_t> &file) {
    file.clear();
    if (stateLength < sizeof(kPSPCoreStateMagic)
        || memcmp(state, kPSPCoreStateMagic, sizeof(kPSPCoreStateMagic)) != 0) {
        return false;
    }
    try { file.resize(kPSPStateHeader + stateLength); } catch (...) { file.clear(); return false; }
    uint8_t *out = file.data();
    const size_t packed = compression_encode_buffer(out + kPSPStateHeader, stateLength,
                                                    state, stateLength, NULL, COMPRESSION_LZFSE);
    uint64_t flags = 0;
    size_t payload = stateLength;
    if (packed > 0 && packed < stateLength) {
        flags = kPSPStateFlagPacked;
        payload = packed;
    } else {
        memcpy(out + kPSPStateHeader, state, stateLength);
    }
    // Little-endian on every Apple CPU, the only ones this file is read on.
    const uint64_t length = (uint64_t)stateLength;
    const uint64_t digest = PSPStateDigest(state, stateLength);
    memcpy(out, kPSPStateMagic, sizeof(kPSPStateMagic));
    memcpy(out + sizeof(kPSPStateMagic), &length, sizeof(length));
    memcpy(out + sizeof(kPSPStateMagic) + 8, &digest, sizeof(digest));
    memcpy(out + sizeof(kPSPStateMagic) + 16, &flags, sizeof(flags));
    file.resize(kPSPStateHeader + payload);
    return true;
}

/// Unpacks `file` into `state` (cleared first), checked: our header, the
/// declared length, the digest, the core's own magic. False for anything
/// else, which then never reaches the core.
static bool PSPStateFormatUnpack(const uint8_t *in, size_t fileLength, std::vector<uint8_t> &state) {
    state.clear();
    if (!in || fileLength <= kPSPStateHeader
        || memcmp(in, kPSPStateMagic, sizeof(kPSPStateMagic)) != 0) {
        return false;
    }
    uint64_t length = 0, digest = 0, flags = 0;
    memcpy(&length, in + sizeof(kPSPStateMagic), sizeof(length));
    memcpy(&digest, in + sizeof(kPSPStateMagic) + 8, sizeof(digest));
    memcpy(&flags, in + sizeof(kPSPStateMagic) + 16, sizeof(flags));
    // A PSP state is tens of MB; a declared length past 256 MB is a damaged
    // header, not a state, and is refused before anything is allocated for it.
    if (length < sizeof(kPSPCoreStateMagic) || length > 256ull * 1024 * 1024) return false;
    const size_t payload = fileLength - kPSPStateHeader;

    if (flags == kPSPStateFlagPacked) {
        // One byte of room, so a payload that unpacks to MORE than the
        // declared length (a damaged file) is told apart from an exact one.
        try { state.resize((size_t)length + 1); } catch (...) { state.clear(); return false; }
        const size_t unpacked = compression_decode_buffer(state.data(), (size_t)length + 1,
                                                          in + kPSPStateHeader, payload,
                                                          NULL, COMPRESSION_LZFSE);
        if (unpacked != (size_t)length) { state.clear(); return false; }
        state.resize((size_t)length);
    } else if (flags == 0) {
        if (payload != (size_t)length) return false;
        try { state.assign(in + kPSPStateHeader, in + kPSPStateHeader + length); }
        catch (...) { state.clear(); return false; }
    } else {
        return false;
    }
    if (PSPStateDigest(state.data(), state.size()) != digest
        || memcmp(state.data(), kPSPCoreStateMagic, sizeof(kPSPCoreStateMagic)) != 0) {
        state.clear();
        return false;
    }
    return true;
}

// PSP_STATE_FORMAT_END (the off-phone check compiles everything above this line)

static NSData *_Nullable PSPPackState(const uint8_t *state, size_t stateLength) {
    std::vector<uint8_t> file;
    if (!PSPStateFormatPack(state, stateLength, file)) return nil;
    return [NSData dataWithBytes:file.data() length:file.size()];
}

static NSData *_Nullable PSPUnpackState(NSData *file) {
    if (!file) return nil;
    std::vector<uint8_t> state;
    if (!PSPStateFormatUnpack((const uint8_t *)file.bytes, file.length, state)) return nil;
    return [NSData dataWithBytes:state.data() length:state.size()];
}

#pragma mark - Bridge

@interface PSPBridge ()
- (void)handleVideo:(const void *)data width:(unsigned)width height:(unsigned)height pitch:(size_t)pitch;
- (void)handleAudio:(const int16_t *)frames count:(size_t)count;
- (void)noteBootComplete;
- (bool)handleEnvironment:(unsigned)cmd data:(void *)data;
- (int16_t)inputStateForPort:(unsigned)port device:(unsigned)device index:(unsigned)index buttonID:(unsigned)buttonID;
@end

/// The single live instance, unretained, as on every libretro bridge.
static __unsafe_unretained PSPBridge *sPSPBridge = nil;

static bool PSPEnvironmentCallback(unsigned cmd, void *data) {
    PSPBridge *bridge = sPSPBridge;
    return bridge ? [bridge handleEnvironment:cmd data:data] : false;
}

static void PSPVideoCallback(const void *data, unsigned width, unsigned height, size_t pitch) {
    [sPSPBridge handleVideo:data width:width height:height pitch:pitch];
}

static void PSPAudioSampleCallback(int16_t left, int16_t right) {
    int16_t frame[2] = { left, right };
    [sPSPBridge handleAudio:frame count:1];
}

static size_t PSPAudioBatchCallback(const int16_t *data, size_t frames) {
    [sPSPBridge noteBootComplete];
    [sPSPBridge handleAudio:data count:frames];
    return frames;
}

static void PSPInputPollCallback(void) {}

static int16_t PSPInputStateCallback(unsigned port, unsigned device, unsigned index, unsigned id) {
    PSPBridge *bridge = sPSPBridge;
    return bridge ? [bridge inputStateForPort:port device:device index:index buttonID:id] : 0;
}

#if DEBUG
/// The owner of a region, from its VM_MEMORY_* tag (values from xnu's
/// osfmk/mach/vm_statistics.h). 0 is untagged: a plain mmap or vm_allocate,
/// which is what PPSSPP itself and most cores' large buffers get.
static const char *PSPMemoryTagName(unsigned tag) {
    switch (tag) {
    case 0:   return "untagged mmap/vm_allocate";
    case 1:   return "malloc";
    case 2:   return "malloc small";
    case 3:   return "malloc large";
    case 4:   return "malloc huge";
    case 7:   return "malloc tiny";
    case 8:   return "malloc large reusable";
    case 9:   return "malloc large reused";
    case 11:  return "malloc nano";
    case 12:  return "malloc medium";
    case 21:  return "IOKit";
    case 30:  return "stack";
    case 31:  return "guard";
    case 33:  return "dylib";
    case 42:  return "CoreGraphics";
    case 51:  return "LayerKit (Core Animation)";
    case 52:  return "CGImage";
    case 60:  return "dyld";
    case 61:  return "dyld malloc";
    case 68:  return "CoreImage";
    case 70:  return "ImageIO";
    case 74:  return "libdispatch";
    case 82:  return "Swift runtime";
    case 88:  return "IOSurface";
    case 90:  return "audio";
    case 100: return "IOAccelerator (Metal)";
    default:  return "other";
    }
}

/// What occupies the window PPSSPP searches for the PSP's memory, logged when a
/// boot fails (and once when one succeeds, to compare). On iOS PPSSPP does not
/// let the system choose an address: it tries a base every 8 MB from 4 GB to
/// 6 GB (Vendor/ppsspp/Core/MemMap.cpp, MemoryMap_Setup) and maps its views at
/// fixed offsets from it, the highest needing up to base + 0x0E000000 (the 64 MB
/// models' extra RAM at 0x0BE00000; Memory_TryBase, kernel views skipped on
/// iOS). A boot fails when every base meets a region already there. This says
/// how many bases were still free, then every region in the window with its
/// owner tag (malloc, IOKit/IOSurface for Metal, a mapped file...), so a failure
/// after other consoles tells which memory took the place. Debug only.
/// Runs on the emulation thread (SHUTDOWN, or the first audio batch): one
/// walk of the address space, a few hundred regions, once per game.
static void PSPLogMemoryWindow(const char *when) {
    // vm_address_t / vm_size_t are 64-bit on arm64. iOS ships no
    // <mach/mach_vm.h> (its mach_vm_* calls are macOS only), so the
    // vm_region_recurse_64 call from <mach/vm_map.h> walks the map.
    const vm_address_t windowStart = 0x100000000ULL;
    const vm_address_t windowEnd = 0x1FFFF0000ULL;            // PPSSPP's max_base_addr + 2 GB
    const vm_address_t lastBase = 0x1FFFF0000ULL - 0x80000000ULL;
    const vm_address_t stride = 0x800000;
    const vm_address_t span = 0x0E000000;

    struct Region { vm_address_t start, end; unsigned tag; };
    std::vector<Region> regions;
    vm_address_t address = 0;
    for (;;) {
        vm_size_t size = 0;
        natural_t depth = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &address, &size, &depth,
                                 (vm_region_recurse_info_t)&info, &count) != KERN_SUCCESS) break;
        if (address >= windowEnd + span) break;
        regions.push_back({address, address + size, info.user_tag});
        address += size;
    }

    int freeBases = 0, bases = 0;
    for (vm_address_t base = windowStart; base < lastBase; base += stride) {
        bases++;
        bool clear = true;
        for (const Region &r : regions) {
            if (r.start < base + span && r.end > base) { clear = false; break; }
        }
        if (clear) freeBases++;
    }
    os_log_error(PSPLog(), "[PSP-MEM] %{public}s: %d of %d bases free in 4-6 GB | app %zu MB left",
                 when, freeBases, bases, os_proc_available_memory() >> 20);

    // Every region inside the window, merged by owner tag so the list stays
    // readable: tag, how many regions, total MB, lowest and highest address.
    std::map<unsigned, std::vector<const Region *>> byTag;
    for (const Region &r : regions) {
        if (r.end <= windowStart || r.start >= windowEnd) continue;
        byTag[r.tag].push_back(&r);
    }
    for (const auto &entry : byTag) {
        vm_address_t total = 0, low = UINTPTR_MAX, high = 0;
        for (const Region *r : entry.second) {
            total += r->end - r->start;
            low = std::min(low, r->start);
            high = std::max(high, r->end);
        }
        os_log_error(PSPLog(), "[PSP-MEM]   tag %u (%{public}s): %zu regions, %.1f MB, 0x%llx-0x%llx",
                     entry.first, PSPMemoryTagName(entry.first), entry.second.size(), total / 1048576.0,
                     (unsigned long long)low, (unsigned long long)high);
    }
}
#endif

static void PSPLogCallback(enum retro_log_level level, const char *fmt, ...) {
    if (level < RETRO_LOG_WARN) return;
    char line[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(line, sizeof(line), fmt, args);
    va_end(args);
    os_log_error(PSPLog(), "[core] %{public}s", line);
}

/// Our bitmask mapped to the PSP pad, through the port's own table
/// (libretro.cpp, `retro_input`): RetroPad A is Circle, B Cross, X Triangle,
/// Y Square, exactly as in PCSX-ReARMed's port. So this table is the
/// PlayStation's (`kButtonMap` in PCSXBridge.mm), bit for bit: the app's
/// `GBAInput` bits are positions (a the RIGHT face, b the BOTTOM, x the TOP,
/// y the LEFT), and PS1TouchControlsView, which draws this console's pad too,
/// prints Circle on a, Cross on b, Triangle on x and Square on y.
/// (Corrected 2026-10-09 before the bridge ever ran: the first table read
/// 0x001 as Cross and crossed every face with its neighbour.)
static const struct { uint32_t ours; unsigned theirs; } kButtonMap[] = {
    { 0x001, RETRO_DEVICE_ID_JOYPAD_A      },   // right  -> Circle
    { 0x002, RETRO_DEVICE_ID_JOYPAD_B      },   // bottom -> Cross
    { 0x400, RETRO_DEVICE_ID_JOYPAD_X      },   // top    -> Triangle
    { 0x800, RETRO_DEVICE_ID_JOYPAD_Y      },   // left   -> Square
    { 0x004, RETRO_DEVICE_ID_JOYPAD_SELECT },
    { 0x008, RETRO_DEVICE_ID_JOYPAD_START  },
    { 0x010, RETRO_DEVICE_ID_JOYPAD_RIGHT  },
    { 0x020, RETRO_DEVICE_ID_JOYPAD_LEFT   },
    { 0x040, RETRO_DEVICE_ID_JOYPAD_UP     },
    { 0x080, RETRO_DEVICE_ID_JOYPAD_DOWN   },
    { 0x200, RETRO_DEVICE_ID_JOYPAD_L      },
    { 0x100, RETRO_DEVICE_ID_JOYPAD_R      },
};

static int16_t PSPClampAxis(float v) {
    if (v >  1.0f) v =  1.0f;
    if (v < -1.0f) v = -1.0f;
    return (int16_t)(v * 32767.0f);
}

@implementation PSPBridge {
    BOOL _romLoaded;
    BOOL _coreInitialised;
    /// The core asked to shut down (its boot or a reboot failed): it is never
    /// entered again for this game. See the file header.
    std::atomic<bool> _shutdownRequested;
    /// The asynchronous boot has finished: the core ran a whole frame. Read
    /// off the port's own control flow (libretro.cpp, `retro_run`): while the
    /// boot is pending it returns before `upload_output_audio_buffer()`, so the
    /// audio batch callback is reached for the first time on the first frame
    /// of a booted game. Until then a reset must not reach the core: it would
    /// start a second boot while the first one's loader thread still runs, and
    /// PPSSPP asserts on that (`PSP_InitStart`: !g_loadingThread.joinable()),
    /// which ended the app on the first device run (2026-10-09).
    std::atomic<bool> _bootComplete;
    BOOL _bootFailedReported;
    BOOL _displayLostReported;
    std::string _romPath;
    std::string _systemDirectory;
    std::string _memoryStickDirectory;

    std::vector<uint32_t> _frameBuffer;
    std::atomic<uint32_t> _liveWidth;
    std::atomic<uint32_t> _liveHeight;
    /// Frames still to run unseen after a state load (kStaleFramesAfterLoad).
    int _hideFrames;
    /// The picture's own buffer while frames are hidden, so the stale ones
    /// land in it and the screen keeps the last good picture.
    std::vector<uint32_t> _hiddenBuffer;

    PSPAudioRing _audio;

    std::atomic<uint32_t> _buttons;
    std::atomic<int16_t> _stickX, _stickY;

    N64VulkanFrontend _vulkan;
    retro_hw_render_callback _hwRender;
    BOOL _hasHWRender;
    BOOL _contextLive;
    const retro_hw_render_context_negotiation_interface_vulkan *_negotiation;

    double _framesPerSecond;
    std::map<std::string, std::string> _declaredDefaults;

    /// The player's cheats, each a list of CWCheat lines ("0x2XXXXXXX 0xYYYYYYYY"),
    /// written to the core's cheat file by `writeCheatFile`. See Cheats.
    std::vector<std::vector<std::string>> _cheats;
    /// The list changed and the file is still to be written (before the boot
    /// completes, there is no game ID to name it by).
    BOOL _cheatsDirty;

    /// Rewind. See the Rewind section for the design.
    uint8_t *_rwCurrent;            // the newest snapshot, whole: what the steps apply to
    uint8_t *_rwScratch;            // where the next one is written
    size_t _rwStateSize;            // the size `_rwCurrent` holds (it moves, see the section)
    size_t _rwBufferSize;           // what the two buffers can hold
    BOOL _rwHasAnchor;              // _rwCurrent holds a snapshot of this timeline
    std::vector<PSPRewindStep> _rwSteps;   // ring of _rwDepth, newest at _rwNewest
    NSInteger _rwDepth;
    NSInteger _rwStored;
    NSInteger _rwNewest;
    size_t _rwHistoryBytes;         // packed bytes the ring holds
    NSInteger _rwFrameCounter;
    BOOL _rwDue;                    // a snapshot is to be taken
    NSInteger _rwDueFrames;         // frames it has waited for a frame with room
    BOOL _rwRefused;                // no memory for it: rewind off for this game
    std::atomic<bool> _rwDiffInFlight;
    dispatch_queue_t _rwDiffQueue;
    /// The last frame's cost, in every build: the snapshot scheduler reads it.
    double _rwLastFrameMs;

#if DEBUG
    uint64_t _perfWindowStartNs;
    uint64_t _perfFrames;
    uint64_t _perfRunNs;
    uint64_t _perfWorstNs;
    uint64_t _perfOverBudget;
#endif

    /// Held around every call that runs the emulation: retro_run,
    /// retro_serialize, retro_unserialize, retro_reset. The app saves states on
    /// its save queue while the main thread runs frames.
    std::mutex _coreLock;
}

- (instancetype)init {
    if ((self = [super init])) {
        if (sPSPBridge != nil && sPSPBridge != self) {
            os_log_error(PSPLog(), "[PSP] a second bridge was created; shutting the previous one down.");
            [sPSPBridge shutdown];
        }
        sPSPBridge = self;

        _romLoaded = NO;
        _coreInitialised = NO;
        _shutdownRequested = false;
        _bootFailedReported = NO;
        _displayLostReported = NO;
        _hasHWRender = NO;
        _contextLive = NO;
        _negotiation = NULL;
        memset(&_hwRender, 0, sizeof(_hwRender));
        _framesPerSecond = 60.0 / 1.001;
        _liveWidth = (uint32_t)PSPMaxBufferWidth;
        _liveHeight = (uint32_t)PSPMaxBufferHeight;
        _hideFrames = 0;
        _buttons = 0;
        _stickX = _stickY = 0;
        _rwCurrent = _rwScratch = NULL;
        _rwStateSize = _rwBufferSize = 0;
        _rwHasAnchor = _rwDue = _rwRefused = NO;
        _rwDepth = _rwStored = _rwDueFrames = _rwFrameCounter = 0;
        _rwNewest = -1;
        _rwHistoryBytes = 0;
        _rwDiffInFlight = false;
        _rwDiffQueue = nil;
        _rwLastFrameMs = 0;
        _cheatsDirty = NO;
#if DEBUG
        _perfWindowStartNs = _perfFrames = _perfRunNs = _perfWorstNs = _perfOverBudget = 0;
#endif

        _frameBuffer.assign((size_t)(PSPMaxBufferWidth * PSPMaxBufferHeight), 0);
        _hiddenBuffer.assign(_frameBuffer.size(), 0);
        _systemDirectory = [self makeSystemDirectory];

        retro_set_environment(PSPEnvironmentCallback);
        retro_set_video_refresh(PSPVideoCallback);
        retro_set_audio_sample(PSPAudioSampleCallback);
        retro_set_audio_sample_batch(PSPAudioBatchCallback);
        retro_set_input_poll(PSPInputPollCallback);
        retro_set_input_state(PSPInputStateCallback);
    }
    return self;
}

- (void)dealloc {
    [self shutdown];
}

/// The core's system directory: it reads `<system>/PPSSPP` (compat.ini, the
/// flash0 fonts, shaders, language files). Those are PPSSPP's assets, shipped
/// in the app bundle as the folder reference `PPSSPP`; the bundle's resource
/// directory is answered, so `<it>/PPSSPP` is that folder, read-only.
- (std::string)makeSystemDirectory {
    NSString *resources = NSBundle.mainBundle.resourcePath;
    NSString *assets = [resources stringByAppendingPathComponent:@"PPSSPP"];
    if (![NSFileManager.defaultManager fileExistsAtPath:[assets stringByAppendingPathComponent:@"compat.ini"]]) {
        os_log_error(PSPLog(), "PPSSPP's assets are not in the app bundle (PPSSPP/compat.ini missing); "
                     "games that use the PSP's system fonts will show no text");
    }
    return std::string(resources.fileSystemRepresentation);
}

#pragma mark - Properties

- (BOOL)isROMLoaded { return _romLoaded; }
- (NSInteger)screenWidth { return (NSInteger)_liveWidth.load(); }
- (NSInteger)screenHeight { return (NSInteger)_liveHeight.load(); }
- (NSInteger)bufferStride { return PSPMaxBufferWidth; }
- (NSInteger)totalBufferHeight { return (NSInteger)_liveHeight.load(); }
- (NSInteger)maxBufferHeight { return PSPMaxBufferHeight; }
- (BOOL)hasTouchScreen { return NO; }
- (CGFloat)displayAspect { return kPSPDisplayAspect; }
/// R, G, B, A in memory, as the frontend's readback writes it.
- (BOOL)usesBGRAPixelOrder { return NO; }
- (double)framesPerSecond { return _framesPerSecond > 1.0 ? _framesPerSecond : 60.0 / 1.001; }

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
    // Loudly, as on the N64: an override the core does not declare, or whose
    // value it does not offer, would be ignored without a word.
    for (const PSPOption &option : kCoreOptions) {
        auto it = choices.find(option.key);
        if (it == choices.end()) {
            os_log_error(PSPLog(), "option %{public}s is set by the bridge but not declared by the core", option.key);
            continue;
        }
        bool offered = false;
        for (const std::string &value : it->second) if (value == option.value) { offered = true; break; }
        if (!offered) {
            os_log_error(PSPLog(), "option %{public}s=%{public}s is not a value the core offers",
                         option.key, option.value);
        }
    }
}

- (bool)handleEnvironment:(unsigned)cmd data:(void *)data {
    switch (cmd) {

    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        auto *var = (retro_variable *)data;
        if (!var || !var->key) return false;
        const char *value = PSPOptionValue(var->key);
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
        *(const char **)data = _systemDirectory.c_str();
        return true;

    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
        // The memory stick. The core reads it once, at retro_init.
        if (_memoryStickDirectory.empty()) return false;
        *(const char **)data = _memoryStickDirectory.c_str();
        return true;

    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: {
        auto *cb = (retro_log_callback *)data;
        if (cb) cb->log = PSPLogCallback;
        return true;
    }

    case RETRO_ENVIRONMENT_GET_LANGUAGE:
        if (data) *(unsigned *)data = PSPRetroLanguage();
        return true;

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
        // PPSSPP's port requires a surface and not parallel-RDP's features.
        N64VulkanFrontend::Requirements requirements;
        requirements.parallelRDPStorage = false;
        requirements.surface = true;
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
        // No: the App Store forbids it. The port then forces the IR interpreter.
        if (data) *(bool *)data = false;
        return true;

    case RETRO_ENVIRONMENT_SHUTDOWN:
        // The boot (or a reboot) failed. Never call the core again for this
        // game, and say so once. See the file header.
        _shutdownRequested = true;
        if (!_bootFailedReported) {
            _bootFailedReported = YES;
            os_log_error(PSPLog(), "the core could not start %{public}s",
                         [@(_romPath.c_str()) lastPathComponent].UTF8String);
#if DEBUG
            PSPLogMemoryWindow(_bootComplete ? "reboot failed" : "boot failed");
#endif
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:PSPBridgeBootFailedNotification
                                                                    object:self];
            });
        }
        return true;

    case RETRO_ENVIRONMENT_SET_GEOMETRY:
        return true;

    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
        if (data) {
            const auto *info = (const retro_system_av_info *)data;
            if (info->timing.fps > 1.0) _framesPerSecond = info->timing.fps;
        }
        return true;

    case RETRO_ENVIRONMENT_SET_VARIABLES:
        [self recordDeclaredOptions:(const retro_variable *)data];
        return true;

    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK:
    case RETRO_ENVIRONMENT_SET_MESSAGE:
    case RETRO_ENVIRONMENT_SET_MESSAGE_EXT:
    case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL:
        // Every string the player reads is ours; option menus are ours too.
        return true;

    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
        // Declined, so the options come through SET_VARIABLES, the one format
        // `recordDeclaredOptions:` reads (as on the N64).
        return false;

    case RETRO_ENVIRONMENT_GET_USERNAME:
    case RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION:
    case RETRO_ENVIRONMENT_GET_VFS_INTERFACE:
    case RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE:
    case RETRO_ENVIRONMENT_GET_PERF_INTERFACE:
    default:
        return false;
    }
}

#pragma mark - ROM management

- (void)setMemoryStickDirectory:(NSString *)path {
    _memoryStickDirectory = path.length ? std::string(path.fileSystemRepresentation) : std::string();
    if (path.length) {
        [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES
                                                 attributes:nil error:nil];
    }
}

- (BOOL)loadROMAtPath:(NSString *)path {
    if (!path.length) return NO;
    // The port opens the file itself (need_fullpath) and finds a missing or
    // unreadable one only during the asynchronous boot; checked here first so
    // the common failure is a clean NO.
    if (![NSFileManager.defaultManager isReadableFileAtPath:path]) {
        os_log_error(PSPLog(), "cannot read %{public}s", path.lastPathComponent.UTF8String);
        return NO;
    }
    if (_romLoaded) {
        os_log_error(PSPLog(), "a second game was loaded into the same bridge; refused");
        return NO;
    }
    if (!_coreInitialised) {
        retro_init();
        _coreInitialised = YES;
    }

    _romPath = std::string(path.fileSystemRepresentation);
    _hasHWRender = NO;
    _negotiation = NULL;
    _shutdownRequested = false;
    _bootComplete = false;
    _bootFailedReported = NO;

    retro_game_info info;
    memset(&info, 0, sizeof(info));
    info.path = _romPath.c_str();

    if (!retro_load_game(&info)) {
        retro_unload_game();
        _vulkan.destroy();
        os_log_error(PSPLog(), "retro_load_game failed for %{public}s", path.lastPathComponent.UTF8String);
        return NO;
    }
    if (!_hasHWRender
        || !_vulkan.createDevice(_negotiation, (unsigned)PSPMaxBufferWidth, (unsigned)PSPMaxBufferHeight)) {
        os_log_error(PSPLog(), "no Vulkan device for %{public}s; the game cannot be drawn",
                     path.lastPathComponent.UTF8String);
        retro_unload_game();
        _vulkan.destroy();
        return NO;
    }
    if (_hwRender.context_reset) _hwRender.context_reset();
    _contextLive = YES;

    _romLoaded = YES;
    _displayLostReported = NO;
    _hideFrames = 0;
    [self invalidateRewind];
    _audio.Clear();

    retro_system_av_info av;
    memset(&av, 0, sizeof(av));
    retro_get_system_av_info(&av);
    if (av.timing.fps > 1.0) _framesPerSecond = av.timing.fps;
    PSPDiag("loaded %{public}s | %.4f fps | %ux%u", path.lastPathComponent.UTF8String,
            _framesPerSecond, av.geometry.base_width, av.geometry.base_height);
    return YES;
}

- (void)unloadGame {
    _vulkan.drainQueue();
    if (_contextLive && _hwRender.context_destroy) _hwRender.context_destroy();
    _contextLive = NO;
    retro_unload_game();
    _vulkan.destroy();
    _romLoaded = NO;
}

- (void)reset {
    if (!_romLoaded || _shutdownRequested) return;
    // NOT before the boot has finished (`_bootComplete`). The session resets
    // every core right after loading it (for the cartridge cores that is what
    // reads the battery save); here the game is already at power-on, its boot
    // still running on PPSSPP's loader thread, and a reboot then is a second
    // boot over the first, which PPSSPP asserts against. Skipped, nothing is
    // lost: the game is exactly where a reset would put it.
    if (!_bootComplete) {
        PSPDiag("reset skipped: the boot is still running");
        return;
    }
    std::lock_guard<std::mutex> lock(_coreLock);
    // A reboot of the whole PSP, which can fail like the first boot (it then
    // asks to shut down, handled in the environment callback). Synchronous in
    // the port (`PSP_Init` polls the loader to the end), so the next frame
    // runs a booted game.
    _vulkan.beginFrame();
    retro_reset();
    [self invalidateRewind];
    _audio.Clear();
}

- (void)noteBootComplete {
    if (!_bootComplete.exchange(true)) {
        PSPDiag("boot complete");
#if DEBUG
        PSPLogMemoryWindow("boot complete");
#endif
    }
}

/// The PSP saves into its memory stick folder by itself (setMemoryStickDirectory:);
/// there is no battery file for the bridge to load or write.
- (void)setSavePath:(NSString *)path { (void)path; }
- (void)flushSaveData {}

#pragma mark - Emulation

- (void)runFrame {
    if (!_romLoaded || _shutdownRequested) return;
    std::lock_guard<std::mutex> lock(_coreLock);
    // The GPU wait in beginFrame is timed with the frame, as on the N64: it is
    // the previous frame's GPU work, a real part of what a frame costs.
    const uint64_t before = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    _vulkan.beginFrame();
    retro_run();
    if (_hideFrames > 0) _hideFrames--;
    // Cheats added before the boot completed: their file is written now.
    if (_cheatsDirty && _bootComplete) [self writeCheatFile];
    const uint64_t after = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    _rwLastFrameMs = (double)(after - before) / 1e6;
#if DEBUG
    [self notePerformance:after - before at:after];
#endif
}

#if DEBUG
/// Emulated frames per second and a frame's cost, every two seconds, for the
/// speed question this console opens with (Low Power Mode on the 14 Pro).
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
    PSPDiag("%.1f fps emulated | %.2f ms per frame | worst %.1f ms | %llu of %llu frames over the %.1f ms budget",
            (double)_perfFrames / ((double)window / 1e9), (double)_perfRunNs / n / 1e6,
            (double)_perfWorstNs / 1e6, _perfOverBudget, _perfFrames, budgetMs);
    _perfWindowStartNs = nowNs;
    _perfFrames = _perfRunNs = _perfWorstNs = _perfOverBudget = 0;
}
#endif

- (void)setKeys:(uint32_t)keys { _buttons = keys; }

- (void)setStickX:(float)x y:(float)y {
    _stickX = PSPClampAxis(x);
    _stickY = PSPClampAxis(y);
}

#pragma mark - Input

- (int16_t)inputStateForPort:(unsigned)port device:(unsigned)device index:(unsigned)index buttonID:(unsigned)buttonID {
    // One player: the PSP had one pad.
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
        return buttonID == RETRO_DEVICE_ID_ANALOG_X ? _stickX.load() : _stickY.load();
    }
    return 0;
}

#pragma mark - Video

- (void)handleVideo:(const void *)data width:(unsigned)width height:(unsigned)height pitch:(size_t)pitch {
    (void)pitch;
    if (!data || width == 0 || height == 0 || data != RETRO_HW_FRAME_BUFFER_VALID) return;
    if (width > (unsigned)PSPMaxBufferWidth)   width  = (unsigned)PSPMaxBufferWidth;
    if (height > (unsigned)PSPMaxBufferHeight) height = (unsigned)PSPMaxBufferHeight;

    // While frames are hidden after a state load, the stale picture is read
    // into a buffer nobody shows, and the screen keeps its last good frame.
    uint32_t *target = _hideFrames > 0 ? _hiddenBuffer.data() : _frameBuffer.data();
    if (_vulkan.readFrame(width, height, target, (size_t)PSPMaxBufferWidth)) {
        if (_hideFrames > 0) return;
        _liveWidth = width;
        _liveHeight = height;
    } else if (_vulkan.readbackLost() && !_displayLostReported) {
        _displayLostReported = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:PSPBridgeDisplayLostNotification
                                                                object:self];
        });
    }
}

- (const uint32_t *)frameBuffer {
    return _romLoaded ? _frameBuffer.data() : NULL;
}

/// A still of the live picture. The PSP's pixels are square, so it needs no
/// reshaping (unlike the PS1's and the N64's).
- (CGImageRef)createFrameImage {
    if (!_romLoaded) return NULL;
    const uint32_t w = _liveWidth.load();
    const uint32_t h = _liveHeight.load();
    if (!w || !h) return NULL;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(_frameBuffer.data(), w, h, 8,
                                             (size_t)PSPMaxBufferWidth * sizeof(uint32_t), colorSpace,
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

- (CGImageRef)createDualScreenFrameImage { return NULL; }
- (void)setGBPalette:(const uint32_t *)colors { (void)colors; }
- (BOOL)isDMGPaletteApplicable { return NO; }

#pragma mark - Save states

- (BOOL)saveStateToPath:(NSString *)path {
    if (!_romLoaded || _shutdownRequested) return NO;
    // No machine to save before the boot has completed, and the core does not
    // answer zero then: it answers a 128 MB placeholder (libretro.cpp,
    // `retro_serialize_size` with no GPU yet), which would be allocated and
    // zeroed beside the game's own memory only for `retro_serialize` to refuse.
    // A quit or a background in the first seconds of a game is exactly then.
    if (!_bootComplete) return NO;
    NSMutableData *buffer = nil;
    size_t used = 0;
    {
        std::lock_guard<std::mutex> lock(_coreLock);
        const size_t size = retro_serialize_size();
        if (!size) return NO;
        buffer = [NSMutableData dataWithLength:size];
        if (!buffer) return NO;
        _vulkan.beginFrame();
        if (!retro_serialize(buffer.mutableBytes, size)) return NO;
        used = PSPUsedLength((const uint8_t *)buffer.bytes, size);
    }
    // Packed outside the lock: the core is free to run the next frame.
#if DEBUG
    const uint64_t packStart = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
#endif
    NSData *file = PSPPackState((const uint8_t *)buffer.bytes, used);
    if (!file) {
        os_log_error(PSPLog(), "state %{public}s not written: the core produced no PPSSPP state",
                     path.lastPathComponent.UTF8String);
        return NO;
    }
#if DEBUG
    PSPDiag("state %{public}s: %zu bytes packed to %lu (%.1fx) in %.1f ms",
            path.lastPathComponent.UTF8String, used, (unsigned long)file.length,
            (double)used / (double)MAX((NSUInteger)1, file.length),
            (double)(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - packStart) / 1e6);
#endif
    return [file writeToFile:path atomically:YES];
}

+ (NSData *)stateFileDataFromState:(NSData *)state {
    return PSPPackState((const uint8_t *)state.bytes, state.length) ?: [NSData data];
}

+ (nullable NSData *)stateFromStateFileData:(NSData *)file {
    return PSPUnpackState(file);
}

- (BOOL)loadStateFromPath:(NSString *)path {
    if (!_romLoaded || _shutdownRequested) return NO;
    NSData *state = PSPUnpackState([NSData dataWithContentsOfFile:path]);
    if (!state) {
        os_log_error(PSPLog(), "state %{public}s refused: not a PSP state this app wrote, or damaged",
                     path.lastPathComponent.UTF8String);
        return NO;
    }
    std::lock_guard<std::mutex> lock(_coreLock);
    // A loaded state is another timeline (the lesson the DS shipped as a bug).
    [self invalidateRewind];
    _vulkan.beginFrame();
    // Before the boot has completed the port keeps a copy and applies it when
    // the boot ends (libretro.cpp); after, it loads at once.
    if (!retro_unserialize(state.bytes, state.length)) return NO;
    _hideFrames = kStaleFramesAfterLoad;
    _audio.Clear();
    return YES;
}

#pragma mark - Memory (RetroAchievements)

/// RetroAchievements reads the PSP's RAM. rcheevos places it at real addresses
/// 0x08000000 (kernel RAM), 0x08800000 (the game's, from 8 MB in) and
/// 0x0A000000 (the PSP-2000's extra 32 MB) (`consoleinfo.c`,
/// `_rc_memory_regions_psp`), and `RAClient.readRAAddress` hands down those real
/// addresses. The port publishes the same RAM as RETRO_MEMORY_SYSTEM_RAM from
/// 0x08000000 (`retro_get_memory_data`: the kernel memory base), 32 MB, or
/// 64 MB on a game that asks for the extra RAM, so a real address is an offset
/// from 0x08000000 into that block, and past its size reads nothing.
///
/// NOT BEFORE THE BOOT HAS COMPLETED. PPSSPP maps the PSP's memory during its
/// asynchronous boot; before that `retro_get_memory_data` answers an offset
/// from a null base, a pointer that is not NULL and must not be read. The
/// session starts achievements only once `isMemoryReadable` says so.
- (BOOL)isMemoryReadable {
    return _romLoaded && !_shutdownRequested && _bootComplete;
}

- (NSInteger)readMemoryAtAddress:(uint32_t)address into:(uint8_t *)buffer length:(NSInteger)length {
    if (!buffer || length <= 0 || ![self isMemoryReadable]) return 0;
    const uint8_t *ram = (const uint8_t *)retro_get_memory_data(RETRO_MEMORY_SYSTEM_RAM);
    const size_t ramSize = retro_get_memory_size(RETRO_MEMORY_SYSTEM_RAM);
    if (!ram || address < 0x08000000u) return 0;
    const size_t offset = address - 0x08000000u;
    if (offset >= ramSize) return 0;
    const size_t count = MIN((size_t)length, ramSize - offset);
    memcpy(buffer, ram + offset, count);
    return (NSInteger)count;
}

#pragma mark - Speed

- (void)setSpeedMultiplier:(int)multiplier { (void)multiplier; }

#pragma mark - Audio

- (unsigned int)audioSampleRate { return kPSPSampleRate; }

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
// The Nintendo 64's design (N64Bridge.mm, Rewind), for a state more than twice
// its size: one whole snapshot, the newest, and for each five seconds before
// it the OLD contents of the 4 KB blocks that changed. Applying the steps
// newest first turns the newest state back into an older one.
//
// MEASURED ON THE HOST before it was written (Tools/psp-bench, mode rewind,
// MHFU from boot through character creation into the village, 13,800 frames,
// a snapshot every 300): a state is 38.7 MB in town and 48.1 MB on the way
// into the world; a step in play changes 0.6 to 2.2 MB of blocks and packs to
// 0.5 to 1.6 MB with LZ4. Every one of 44 states rebuilt by undoing the steps
// was identical, byte for byte, to the snapshot taken at that moment, the two
// size changes included. A snapshot costs 0.3 ms to measure and 2.5 to 3.7 ms
// to write (host), against MHFU's 5.2 ms frame of 16.7 on the phone.
//
// THE STATE'S SIZE MOVES DURING PLAY, unlike the N64's: 40 MB of buffer in
// MHFU's town, 56 MB in its intro to the world, then 40 again. So the size is
// measured before every snapshot (the core writes a whole state whatever it is
// told, so a buffer it outgrew would be overrun), the two buffers grow to the
// largest state seen and never shrink, and a step records the size of the
// state it gives back, carrying every block of the older state that the newer
// one lacks or holds differently. A step across a size change is the large
// one (12.8 MB packed in MHFU, once), and the rewind still crosses it: a
// history that restarted at each change would quietly lose the rewind at the
// moment a player changes area.
//
// REPLAY. A rewound game runs on from the restored state as from a loaded
// save state, which is what it is. It does not always replay the frames it
// first played identically: PPSSPP's own save loaded after a long session
// drifts the same way (host: the core's state from frame 300, loaded at frame
// 11,000, diverged after 427 frames), so that is the core's, not the
// rewind's, and harmless to a player.
//
// WHEN. A snapshot falls due every five seconds of emulated time and is taken
// after a frame that left kRewindSnapshotHeadroomMs of its budget unused, or
// after kRewindDueDeadlineFrames of waiting regardless. Never before the
// asynchronous boot has completed: there is no state before it (the core
// answers a 128 MB placeholder size and refuses to serialize).
//
// THE DIFF AND THE PACKING RUN OFF THE EMULATION THREAD, on `_rwDiffQueue`.
// While one runs it owns both buffers and the ring: no snapshot is taken, and
// everything else that touches them waits for it first.
//
// MEMORY, as on the N64. The buffers are allocated on the first snapshot, and
// not at all if the app has less than kRewindMemoryReserve to spare beyond
// them; the packed history has a ceiling, past which the oldest steps go; and
// if free memory falls under the reserve during play, the history is
// dropped. The rewind gets shorter, the game is never killed for it.

- (void)initRewind:(NSInteger)seconds {
    std::lock_guard<std::mutex> lock(_coreLock);
    [self teardownRewind];
    if (seconds <= 0 || !_romLoaded) return;
    _rwDepth = MAX((NSInteger)1, seconds / kRewindSecondsPerSnapshot);
    _rwSteps.assign((size_t)_rwDepth, PSPRewindStep{});
    // The first snapshot is the anchor, taken as soon as the boot allows, so
    // the rewind works from the start.
    _rwDue = YES;
    _rwDueFrames = 0;
}

/// Makes both buffers hold at least `size` bytes, keeping `_rwCurrent`'s
/// contents. Refuses, for the rest of this game, when the app could not spare
/// them. Only with the diff queue idle.
- (BOOL)ensureRewindBuffers:(size_t)size {
    if (_rwCurrent && size <= _rwBufferSize) return YES;
    if (_rwRefused) return NO;
    const size_t growth = 2 * (size - (_rwCurrent ? _rwBufferSize : 0));
    const size_t available = os_proc_available_memory();
    if (available != 0 && available < growth + kRewindMemoryReserve) {
        os_log_error(PSPLog(), "rewind off for this game: %zu MB free, it needs %zu MB more plus a reserve of %zu MB",
                     available >> 20, growth >> 20, kRewindMemoryReserve >> 20);
        [self refuseRewind];
        return NO;
    }
    const size_t was = _rwCurrent ? _rwBufferSize : 0;
    uint8_t *current = (uint8_t *)realloc(_rwCurrent, size);
    if (current) _rwCurrent = current;
    uint8_t *scratch = current ? (uint8_t *)realloc(_rwScratch, size) : NULL;
    if (scratch) _rwScratch = scratch;
    if (!current || !scratch) {
        os_log_error(PSPLog(), "rewind off for this game: the state buffers could not be allocated");
        [self refuseRewind];
        return NO;
    }
    // The core writes only the state's measured length and leaves the rest of
    // the padded size as it finds it (MeasureAndSavePtr), so the new room
    // starts as zeroes, never as whatever the allocator held. Harmless to the
    // core either way (it reads a state by its own structure); it keeps the
    // diffs to what the game changed.
    memset(_rwCurrent + was, 0, size - was);
    memset(_rwScratch + was, 0, size - was);
    _rwBufferSize = size;
    if (!_rwDiffQueue) _rwDiffQueue = dispatch_queue_create("retropal.psp.rewind", DISPATCH_QUEUE_SERIAL);
    return YES;
}

/// No rewind for the rest of this game, and its memory given back.
- (void)refuseRewind {
    [self dropRewindHistory];
    free(_rwCurrent); _rwCurrent = NULL;
    free(_rwScratch); _rwScratch = NULL;
    _rwBufferSize = _rwStateSize = 0;
    _rwHasAnchor = NO;
    _rwDue = NO;
    _rwRefused = YES;
}

static void PSPFreeStep(PSPRewindStep &step) {
    free(step.blocks);
    free(step.packed);
    step = PSPRewindStep{};
}

/// Frees every step and keeps the anchor. Only with the diff queue idle.
- (void)dropRewindHistory {
    for (PSPRewindStep &step : _rwSteps) PSPFreeStep(step);
    _rwStored = 0;
    _rwNewest = -1;
    _rwHistoryBytes = 0;
}

- (void)dropOldestStep {
    if (_rwStored <= 0) return;
    const NSInteger oldest = (_rwNewest - _rwStored + 1 + _rwDepth) % _rwDepth;
    _rwHistoryBytes -= _rwSteps[(size_t)oldest].packedLength;
    PSPFreeStep(_rwSteps[(size_t)oldest]);
    _rwStored--;
}

- (void)teardownRewind {
    if (_rwDiffQueue) {
        dispatch_sync(_rwDiffQueue, ^{});   // never free a buffer a diff is reading
        _rwDiffQueue = nil;
    }
    [self dropRewindHistory];
    _rwSteps.clear();
    free(_rwCurrent); _rwCurrent = NULL;
    free(_rwScratch); _rwScratch = NULL;
    _rwBufferSize = _rwStateSize = 0;
    _rwDepth = 0;
    _rwHasAnchor = NO;
    _rwDue = NO;
    _rwDueFrames = 0;
    _rwFrameCounter = 0;
    _rwRefused = NO;
}

/// A load, a reset or a new game: another timeline. Every step describes the
/// old one, and so does the anchor. The jump itself is the first place the new
/// timeline can rewind to, so a snapshot falls due at once.
- (void)invalidateRewind {
    if (_rwDiffQueue) dispatch_sync(_rwDiffQueue, ^{});
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
    if (_rwDepth <= 0 || _rwRefused || !_romLoaded || _shutdownRequested) return;
    std::lock_guard<std::mutex> lock(_coreLock);
    // No state exists until the boot has completed.
    if (!_bootComplete) return;

    // Five seconds of emulated time.
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
    if (_rwDiffInFlight.load()) return;

    const double budgetMs = 1000.0 / self.framesPerSecond;
    const BOOL room = _rwLastFrameMs <= budgetMs - kRewindSnapshotHeadroomMs;
    const BOOL deadline = _rwDueFrames >= kRewindDueDeadlineFrames;
    if (!room && !deadline) return;

    // Measured every time: the size moves during play (see above).
    const size_t size = retro_serialize_size();
    if (!size || ![self ensureRewindBuffers:size]) return;
    _vulkan.beginFrame();
    if (!retro_serialize(_rwScratch, size)) {
        os_log_error(PSPLog(), "rewind snapshot failed in the core; asking again");
        _rwDueFrames = 0;
        return;
    }
    _rwDue = NO;
    [self recordSnapshotOfSize:size];
}

/// `_rwScratch` holds a snapshot of `size` bytes the core has just written.
/// Called with `_coreLock` held, on the emulation thread.
- (void)recordSnapshotOfSize:(size_t)size {
#if DEBUG
    const double frameMs = _rwLastFrameMs;
#endif
    if (!_rwHasAnchor) {
        std::swap(_rwCurrent, _rwScratch);
        _rwStateSize = size;
        _rwHasAnchor = YES;
#if DEBUG
        PSPDiag("[REWIND] anchor | 2 x %.1f MB of state buffers | after a %.1f ms frame%{public}s",
                _rwBufferSize / 1048576.0, frameMs, [self rewindMemoryLine].UTF8String);
#endif
        return;
    }

    _rwDiffInFlight = true;
    const size_t olderSize = _rwStateSize;
    dispatch_async(_rwDiffQueue, ^{
#if DEBUG
        const double started = (double)clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e6;
#endif
        const size_t blocks = (olderSize + kRewindBlock - 1) / kRewindBlock;
        const uint8_t *older = self->_rwCurrent;
        const uint8_t *newer = self->_rwScratch;
        // A block of the older state that the newer one does not reach is
        // kept whole: undoing the step must give back the older state entire.
        auto differs = [&](size_t off, size_t len) {
            return off + len > size || memcmp(older + off, newer + off, len) != 0;
        };

        // Pass one counts, pass two records, as on the N64.
        uint32_t changed = 0;
        size_t rawLength = 0;
        for (size_t b = 0; b < blocks; b++) {
            const size_t off = b * kRewindBlock;
            const size_t len = MIN(kRewindBlock, olderSize - off);
            if (differs(off, len)) {
                changed++;
                rawLength += len;
            }
        }

        PSPRewindStep step{};
        step.stateSize = olderSize;
        BOOL kept = YES;
        const size_t available = os_proc_available_memory();
        if (available != 0 && available < kRewindMemoryReserve) {
            kept = NO;
            os_log_error(PSPLog(), "rewind history dropped: %zu MB free, under the %zu MB reserve",
                         available >> 20, kRewindMemoryReserve >> 20);
        } else if (changed) {
            step.blocks = (uint32_t *)malloc(changed * sizeof(uint32_t));
            uint8_t *raw = (uint8_t *)malloc(rawLength);
            if (!step.blocks || !raw) {
                free(raw);
                kept = NO;
            } else {
                size_t at = 0;
                for (size_t b = 0; b < blocks; b++) {
                    const size_t off = b * kRewindBlock;
                    const size_t len = MIN(kRewindBlock, olderSize - off);
                    if (!differs(off, len)) continue;
                    step.blocks[step.count++] = (uint32_t)b;
                    memcpy(raw + at, older + off, len);
                    at += len;
                }
                step.rawLength = rawLength;
                // Packed when it pays; kept as it is when LZ4 cannot shrink it
                // or the second buffer cannot be had.
                uint8_t *packed = (uint8_t *)malloc(rawLength);
                const size_t packedLength = packed
                    ? compression_encode_buffer(packed, rawLength, raw, rawLength, NULL, COMPRESSION_LZ4)
                    : 0;
                if (packedLength > 0 && packedLength < rawLength) {
                    free(raw);
                    uint8_t *shrunk = (uint8_t *)realloc(packed, packedLength);
                    step.packed = shrunk ? shrunk : packed;
                    step.packedLength = packedLength;
                    step.compressed = true;
                } else {
                    free(packed);
                    step.packed = raw;
                    step.packedLength = rawLength;
                }
            }
        }

        if (!kept) {
            // The history cannot grow, so it starts again from this snapshot:
            // a step that is missing would make every older one land wrong.
            PSPFreeStep(step);
            [self dropRewindHistory];
        } else {
            // Room in the ring and under the ceiling, oldest first.
            if (self->_rwStored == self->_rwDepth) [self dropOldestStep];
            while (self->_rwStored > 0
                   && self->_rwHistoryBytes + step.packedLength > kRewindHistoryByteCeiling) {
                [self dropOldestStep];
            }
            const NSInteger slot = (self->_rwNewest + 1) % self->_rwDepth;
            self->_rwSteps[(size_t)slot] = step;
            self->_rwNewest = slot;
            self->_rwStored++;
            self->_rwHistoryBytes += step.packedLength;
        }
        // The new snapshot becomes the anchor; the old anchor's buffer receives
        // the next one.
        std::swap(self->_rwCurrent, self->_rwScratch);
        self->_rwStateSize = size;

#if DEBUG
        const double diffMs = (double)clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e6 - started;
        PSPDiag("[REWIND] snapshot | after a %.1f ms frame | state %.1f MB | %u blocks changed = %.2f MB, "
                "%.2f MB packed | diff+pack %.1f ms off-thread | %ld of %ld steps, %.2f MB%{public}s",
                frameMs, size / 1048576.0, changed, rawLength / 1048576.0, step.packedLength / 1048576.0,
                diffMs, (long)self->_rwStored, (long)self->_rwDepth, self->_rwHistoryBytes / 1048576.0,
                [self rewindMemoryLine].UTF8String);
#endif
        self->_rwDiffInFlight = false;
    });
}

#if DEBUG
/// The memory side of the [REWIND] lines: everything the rewind holds, the
/// app's footprint (the figure jetsam judges), and what is left before it.
- (NSString *)rewindMemoryLine {
    const double held = ((_rwCurrent ? _rwBufferSize : 0) + (_rwScratch ? _rwBufferSize : 0)
                         + _rwHistoryBytes) / 1048576.0;
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    const double footprint = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS
        ? info.phys_footprint / 1048576.0 : -1;
    return [NSString stringWithFormat:@" | rewind holds %.1f MB | app %.0f MB, %zu MB left",
            held, footprint, os_proc_available_memory() >> 20];
}
#endif

/// Unpacks one step and writes its old blocks over `_rwCurrent`, which then
/// holds a state of `step.stateSize` bytes. NO, with `_rwCurrent` untouched,
/// if the unpacking buffer cannot be had.
- (BOOL)applyRewindStep:(const PSPRewindStep &)step {
    const uint8_t *raw = step.packed;
    uint8_t *unpacked = NULL;
    if (step.compressed) {
        unpacked = (uint8_t *)malloc(step.rawLength);
        if (!unpacked) return NO;
        if (compression_decode_buffer(unpacked, step.rawLength, step.packed, step.packedLength,
                                      NULL, COMPRESSION_LZ4) != step.rawLength) {
            free(unpacked);
            return NO;
        }
        raw = unpacked;
    }
    size_t at = 0;
    for (uint32_t k = 0; k < step.count; k++) {
        const size_t off = (size_t)step.blocks[k] * kRewindBlock;
        const size_t len = MIN(kRewindBlock, step.stateSize - off);
        memcpy(_rwCurrent + off, raw + at, len);
        at += len;
    }
    free(unpacked);
    _rwStateSize = step.stateSize;
    return YES;
}

/// Rewinds `count` sixtieths of a second (what EmulatorViewController asks),
/// to the nearest snapshot the ring holds. With no step stored there is still
/// one place to go, the anchor, as on the N64 and the DS.
- (BOOL)rewindFrames:(NSInteger)count {
    std::lock_guard<std::mutex> lock(_coreLock);
    if (!_romLoaded || _shutdownRequested) return NO;
    if (_rwDiffQueue) dispatch_sync(_rwDiffQueue, ^{});
    if (!_rwHasAnchor) return NO;

    // To the NEAREST snapshot, so 30 s lands on 30 and not on 25.
    const NSInteger perSnapshot = kRewindSecondsPerSnapshot * 60;
    NSInteger steps = (count + perSnapshot / 2) / perSnapshot;
    steps = MIN(MAX((NSInteger)1, steps), _rwStored);

    NSInteger applied = 0;
    while (applied < steps) {
        PSPRewindStep &step = _rwSteps[(size_t)_rwNewest];
        // Out of memory to unpack: stop at the state reached so far, which is
        // whole, rather than load a half-rewound one.
        if (![self applyRewindStep:step]) break;
        _rwHistoryBytes -= step.packedLength;
        PSPFreeStep(step);
        _rwNewest = (_rwNewest - 1 + _rwDepth) % _rwDepth;
        _rwStored--;
        applied++;
    }

    // Loaded from the spare buffer, so `_rwCurrent` stays the anchor of what
    // follows: the core reads the state and the next snapshot diffs against it.
    memcpy(_rwScratch, _rwCurrent, _rwStateSize);
    _vulkan.beginFrame();
    const bool ok = retro_unserialize(_rwScratch, _rwStateSize);
    PSPDiag("[REWIND] restored %ld of %ld steps (%ld s), %ld left, state %.1f MB, ok=%d",
            (long)applied, (long)steps, (long)(applied * kRewindSecondsPerSnapshot), (long)_rwStored,
            _rwStateSize / 1048576.0, ok);
    if (!ok) {
        // The anchor no longer describes the running console.
        [self invalidateRewind];
        return NO;
    }
    // The next snapshot comes a full interval after this point, so the steps
    // stay five seconds apart; the stale pictures a load leaves are not shown.
    _rwFrameCounter = 0;
    _rwDue = NO;
    _hideFrames = kStaleFramesAfterLoad;
    _audio.Clear();
    return YES;
}

#pragma mark - Cheats
//
// CWCheat, the PSP's own format, the one every PSP code list prints:
//   _L 0x2XXXXXXX 0xYYYYYYYY
// a command and an address offset, then a value, one pair per line. The engine
// is PPSSPP's (Core/CwCheat.cpp); it reads its codes from a file of the memory
// stick, PSP/Cheats/<game ID>.ini, and re-reads it when asked to reload.
//
// THE PORT'S OWN retro_cheat_set IS NOT USED. It splits a pasted code on
// spaces only, so a code of several lines lands as one broken line, and it
// rebuilds the file from its own previous output with an index arithmetic that
// overwrites earlier cheats once there are two. So the bridge keeps the list
// itself and writes the whole file, which is what the engine reads:
//   1. retro_cheat_reset(), which names the file from the running game's ID
//      ("_S <ID>", the one thing the bridge cannot know, PPSSPP's internals
//      not being linked) and asks the engine to reload;
//   2. the file rewritten at once with every enabled cheat, before the next
//      retro_run, inside which the reload happens.
// Proved on the host against MHFU (Tools/psp-bench, mode cheat): a 32-bit write
// applied within 3 frames, a cleared list stops writing, two cheats with one of
// two lines both apply, and a state load leaves them applying.
//
// Before the boot completes there is no game ID: the list is kept and written
// after the first booted frame (`_cheatsDirty`). The app applies a game's
// saved cheats right after loading it, which is always that case.

/// One cheat's lines, each normalised to "0xAAAAAAAA 0xVVVVVVVV", or empty when
/// the text holds anything else. Accepts the lines as code lists print them
/// (`_L 0x20000000 0x00000001`, with or without the `_L` and the `0x`), and
/// skips a `_C` title line copied along with them. Refused rather than guessed:
/// the cheat manager then says the code was not recognised.
static std::vector<std::string> PSPCheatLines(NSString *code) {
    std::vector<std::string> lines;
    // A code pasted as code lists store it, its lines joined by spaces on one
    // line ("_L 0x... 0x... _L 0x... 0x..."), is split before each "_L" that a
    // space follows, so it reads as the lines it is.
    NSRegularExpression *lineStart = [NSRegularExpression regularExpressionWithPattern:@"(?<=\\S)[ \\t]+(?=_[Ll][ \\t])"
                                                                               options:0 error:nil];
    code = [lineStart stringByReplacingMatchesInString:code options:0 range:NSMakeRange(0, code.length)
                                          withTemplate:@"\n"];
    for (NSString *raw in [code componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!line.length) continue;
        NSString *upper = line.uppercaseString;
        if ([upper hasPrefix:@"_C"]) continue;              // a title line, copied along
        if ([upper hasPrefix:@"_L"]) upper = [upper substringFromIndex:2];
        NSArray<NSString *> *words = [[upper stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                                      componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSString *w in words) if (w.length) [parts addObject:w];
        if (parts.count != 2) return {};
        unsigned values[2];
        for (NSUInteger k = 0; k < 2; k++) {
            NSString *hex = [parts[k] hasPrefix:@"0X"] ? [parts[k] substringFromIndex:2] : parts[k];
            if (hex.length == 0 || hex.length > 8) return {};
            for (NSUInteger c = 0; c < hex.length; c++) {
                if (!isxdigit([hex characterAtIndex:c])) return {};
            }
            values[k] = (unsigned)strtoul(hex.UTF8String, NULL, 16);
        }
        char normalised[32];
        snprintf(normalised, sizeof normalised, "0x%08X 0x%08X", values[0], values[1]);
        lines.emplace_back(normalised);
    }
    return lines;
}

- (BOOL)addCheatCode:(NSString *)code type:(int)type {
    (void)type;
    if (!_romLoaded || _shutdownRequested || !code.length) return NO;
    std::vector<std::string> lines = PSPCheatLines(code);
    if (lines.empty()) {
        os_log_error(PSPLog(), "cheat refused: not CWCheat lines (_L 0xAAAAAAAA 0xVVVVVVVV)");
        return NO;
    }
    // Every line "0x00000000 0x00000000": a section header copied from a code
    // list, not a cheat. Type 0 is an 8-bit write, so it would put 0 in the
    // first byte of the game's memory. A null line among others is part of
    // the code (the data word of a multi-write) and stays.
    bool allNull = true;
    for (const std::string &line : lines) if (line != "0x00000000 0x00000000") { allNull = false; break; }
    if (allNull) {
        os_log_error(PSPLog(), "cheat refused: a null line only (a code list's section header)");
        return NO;
    }
    std::lock_guard<std::mutex> lock(_coreLock);
    _cheats.push_back(std::move(lines));
    _cheatsDirty = YES;
    if (_bootComplete) [self writeCheatFile];
    return YES;
}

- (void)clearCheats {
    if (!_romLoaded || _shutdownRequested) return;
    std::lock_guard<std::mutex> lock(_coreLock);
    _cheats.clear();
    _cheatsDirty = YES;
    if (_bootComplete) [self writeCheatFile];
}

/// The cheat file of the running game, written whole. With `_coreLock` held,
/// after the boot has completed.
- (void)writeCheatFile {
    _cheatsDirty = NO;
    if (_memoryStickDirectory.empty()) return;
    // Names the file from the game's ID and asks the engine to reload it.
    retro_cheat_reset();
    NSString *folder = [@(_memoryStickDirectory.c_str()) stringByAppendingPathComponent:@"PSP/Cheats"];
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil];
    NSString *file = nil;
    for (NSString *name in names) {
        if (![name.pathExtension.lowercaseString isEqualToString:@"ini"]) continue;
        NSString *path = [folder stringByAppendingPathComponent:name];
        if (!file) { file = path; continue; }
        // Only one game ever runs on this stick, so one file; if another were
        // there, the newest is the one just written.
        NSDate *a = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate;
        NSDate *b = [NSFileManager.defaultManager attributesOfItemAtPath:file error:nil].fileModificationDate;
        if (a && b && [a compare:b] == NSOrderedDescending) file = path;
    }
    if (!file) {
        os_log_error(PSPLog(), "cheats not applied: the core named no cheat file");
        return;
    }
    NSString *gameID = file.lastPathComponent.stringByDeletingPathExtension;
    std::string text = std::string("_S ") + gameID.UTF8String + "\n";
    for (size_t i = 0; i < _cheats.size(); i++) {
        text += "_C1 Cheat " + std::to_string(i + 1) + "\n";
        for (const std::string &line : _cheats[i]) text += "_L " + line + "\n";
    }
    NSData *data = [NSData dataWithBytes:text.data() length:text.size()];
    if (![data writeToFile:file atomically:YES]) {
        os_log_error(PSPLog(), "cheats not applied: %{public}s could not be written", file.lastPathComponent.UTF8String);
        return;
    }
    PSPDiag("cheats: %zu written to %{public}s", _cheats.size(), file.lastPathComponent.UTF8String);
}

#pragma mark - Touch screen

- (void)touchScreenAtX:(int)x y:(int)y { (void)x; (void)y; }
- (void)touchScreenRelease {}

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
    if (sPSPBridge == self) sPSPBridge = nil;
}

@end
