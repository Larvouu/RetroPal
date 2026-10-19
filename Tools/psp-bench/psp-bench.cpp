// Host harness for the PSP core as Retro Pal would build it: PPSSPP's own
// libretro port (libretro/ in the PPSSPP tree, v1.20.4), drawing through
// Vulkan, on the app's own Vulkan frontend (N64VulkanFrontend.mm, compiled
// unchanged but for its log line, see build.sh), driven in the bridge's order:
// beginFrame, then retro_run, whose video callback reads the picture back.
//
// It exists to PROVE on this machine, before any app code, that PPSSPP runs on
// the video path the Nintendo 64 already ships (the same frontend, the same
// readback), and to measure what the PSP costs: the frame, the readback, the
// size and the time of a state.
//
//   hash    run N frames, one line per frame: picture size and hash, sound hash
//           and sample count. Two runs with identical files are deterministic.
//   bench   the same run, timed. Host timings on lavapipe (Mesa's CPU Vulkan):
//           only ratios mean anything; the phone's figures decide.
//   roundtrip  run to --rt-at, serialize, run --rt-len frames (A), unserialize,
//           run them again (B): A and B must be identical, picture and sound.
//   cheat   the bridge's cheat path, proved: after the boot, retro_cheat_reset
//           names the game's cheat file (PSP/Cheats/<ID>.ini on the memory
//           stick); it is rewritten with one CWCheat code writing --cheat-value
//           at user offset --cheat-offset, reloaded, and the PSP's RAM read
//           back through retro_get_memory_data (RETRO_MEMORY_SYSTEM_RAM).
//   capture the save-state fixture (EmulateurGBATests/Fixtures/SaveStateCompat/
//           psp): run --frames frames with the --press script, then write a
//           slot file exactly as PSPBridge's saveStateToPath does (the core's
//           used length, packed by the bridge's OWN PSPStateFormatPack, compiled
//           from PSPBridge.mm by build.sh). Made once, from the core a release
//           SHIPS.
//   verify  a core against that file, in a fresh process, on the test's path:
//           boot, one frame, load (before the boot has completed the port
//           keeps the state and applies it when the boot ends, as on the
//           phone), then --rt-len frames with the --press script resumed from
//           the saved frame (--rt-at). Each frame's line is the hash of the
//           PSP's RAM and of its sound, compared with --expect FILE; the
//           picture is counted, not required (a blinking cursor's phase is a
//           presentation detail). Exit 0 only if every line matches. With
//           --record it WRITES --expect FILE instead, once, with the core the
//           state came from.
//   rewind  the bridge's rewind design, measured: a snapshot every --rw-every
//           frames, each kept as the OLD contents of the 4 KB blocks that
//           changed (packed with LZ4 to size it), then every step undone from
//           the newest snapshot back, each rebuilt state compared with the one
//           taken at that moment, and the game replayed from the oldest one
//           and compared, frame by frame, with the original run.
//
// Usage: psp-bench <hash|bench|roundtrip|rewind|cheat|capture|verify> <game> --assets DIR [options]
//   --assets DIR        PPSSPP's assets folder (the core reads <system>/PPSSPP)
//   --frames N          frames to run (default 1800)
//   --out FILE          hash: write the lines there instead of stdout
//   --press MASK@A-B    hold a RetroPad mask on port 1 from frame A to frame B
//   --rt-at N / --rt-len M  roundtrip: frame of the save, frames compared
//   --scale N           internal resolution, 1 (480x272) or 2 (960x544)
//   --shot N            hash: also write frame N as a PPM next to --out
//   --rw-every N        rewind: frames between snapshots (default 300, 5 s)
//   --cheat-offset X / --cheat-value Y   cheat: the 32-bit write (hex)
//   --state FILE        capture / verify: the slot file
//   --expect FILE       verify: one line per frame after the load
//   --record            verify: write --expect FILE rather than compare with it
//   --load-first        verify: load before the first frame, during the boot
//   --peek ADDR,N       verify: print N words of RAM at real address ADDR (hex)
//                       once the state is in, as the test reads them
//
// Paths are arguments on purpose: games never enter the repository.

#include "N64VulkanFrontend.h"

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <map>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
#include <dlfcn.h>

// PSPBridge.mm's save-state format, cut out unchanged by build.sh.
#include "PSPStateFormat.inc"

namespace {

struct Press { int16_t mask; int from, to; };

struct Options {
    std::string mode, rom, out, assets;
    int frames = 1800;
    int rtAt = 900, rtLen = 300;
    int scale = 1;
    int shot = -1;
    int rwEvery = 300;
    unsigned cheatOffset = 0x01700000, cheatValue = 0x5A5AA5A5;
    // The app's own sequence: the session resets every core right after
    // loading it. "raw" sends the reset to the core as it is; "guarded" holds
    // it until the boot is complete, as PSPBridge does (2026-10-09: the raw
    // reset aborted the app on the first device run).
    std::string resetAfterLoad;
    std::string state, expect;
    bool record = false;
    bool loadFirst = false;
    uint32_t peekAddress = 0;
    int peekWords = 0;
    std::vector<Press> presses;
};

[[noreturn]] void die(const char *msg) {
    fprintf(stderr, "psp-bench: %s\n", msg);
    exit(2);
}

// The options a bridge would set: Vulkan, the IR interpreter (the App Store
// forbids a JIT; the core also forces it when GET_JIT_CAPABLE says no), the
// PSP's own resolution, no network. Everything else is the core's default.
std::string gResolution = "480x272";
const char *kCoreOptions[][2] = {
    { "ppsspp_backend", "vulkan" },
    { "ppsspp_cpu_core", "IR JIT" },
    { "ppsspp_internal_resolution", nullptr },  // gResolution
    { "ppsspp_enable_wlan", "disabled" },
    { "ppsspp_enable_upnp", "disabled" },
    { "ppsspp_cheats", nullptr },  // gCheats: "enabled" as in the bridge for the cheat mode
};
std::string gCheats = "disabled";

N64VulkanFrontend gVulkan;
retro_hw_render_callback gHW;
bool gHasHW = false;
const retro_hw_render_context_negotiation_interface_vulkan *gNegotiation = nullptr;
std::map<std::string, std::string> gDefaults;
std::string gSystemDir;
Options gOpt;
int gFrame = 0;

// Two times the PSP's 480x272 at most (the --scale option).
constexpr unsigned kMaxW = 960, kMaxH = 544;
std::vector<uint32_t> gPicture(kMaxW * kMaxH);
unsigned gWidth = 0, gHeight = 0;
bool gNewPicture = false;
// Set by RETRO_ENVIRONMENT_SHUTDOWN. PPSSPP boots ASYNCHRONOUSLY: retro_load_game
// only starts the boot and returns true; the boot finishes inside the first
// retro_run calls, and if it fails there the core asks to shut down. Calling
// retro_run after that runs the CPU with no CPU core object and crashes
// (MIPSState::RunLoopUntil through a null MIPSComp::jit, seen in gdb). The
// bridge must honour it the same way.
bool gShutdown = false;
std::vector<int16_t> gFrameAudio;

uint64_t gReadNs = 0;
char *gPre = nullptr;
std::string gShotTag;
size_t gPreLen = 0;

uint64_t nowNs(clockid_t clock) {
    timespec t;
    clock_gettime(clock, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

uint64_t fnv(const void *data, size_t n, uint64_t h = 1469598103934665603ull) {
    const uint8_t *p = (const uint8_t *)data;
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ull; }
    return h;
}

void logCallback(enum retro_log_level level, const char *fmt, ...) {
    if (level < RETRO_LOG_WARN) return;
    va_list a;
    va_start(a, fmt);
    fprintf(stderr, "[core] ");
    vfprintf(stderr, fmt, a);
    va_end(a);
}

bool environment(unsigned cmd, void *data) {
    switch (cmd) {
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        auto *v = (retro_variable *)data;
        if (!v || !v->key) return false;
        for (auto &o : kCoreOptions) if (!strcmp(o[0], v->key)) {
            v->value = o[1] ? o[1] : !strcmp(o[0], "ppsspp_cheats") ? gCheats.c_str() : gResolution.c_str();
            return true;
        }
        auto it = gDefaults.find(v->key);
        if (it == gDefaults.end()) return false;
        v->value = it->second.c_str();
        return true;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE: if (data) *(bool *)data = false; return true;
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
        *(const char **)data = gSystemDir.c_str();
        return true;
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: ((retro_log_callback *)data)->log = logCallback; return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: return *(const retro_pixel_format *)data == RETRO_PIXEL_FORMAT_XRGB8888;
    case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER: if (data) *(unsigned *)data = RETRO_HW_CONTEXT_VULKAN; return true;
    case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS: if (data) *(bool *)data = true; return true;
    case RETRO_ENVIRONMENT_GET_CAN_DUPE: if (data) *(bool *)data = true; return true;
    case RETRO_ENVIRONMENT_SET_HW_RENDER: {
        auto *cb = (retro_hw_render_callback *)data;
        if (!cb || cb->context_type != RETRO_HW_CONTEXT_VULKAN) return false;
        // PPSSPP's libretro Vulkan port requires a surface and not
        // parallel-RDP's storage features (N64VulkanFrontend::Requirements).
        N64VulkanFrontend::Requirements req;
        req.parallelRDPStorage = false;
        req.surface = true;
        if (!gVulkan.createInstance(req)) return false;
        gHW = *cb;
        gHasHW = true;
        return true;
    }
    case RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE: {
        auto *i = (const retro_hw_render_context_negotiation_interface *)data;
        if (!i || i->interface_type != RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN) return false;
        gNegotiation = (const retro_hw_render_context_negotiation_interface_vulkan *)data;
        return true;
    }
    case RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE:
        if (!data || !gVulkan.isReady()) return false;
        *(const retro_hw_render_interface **)data = (const retro_hw_render_interface *)gVulkan.interface();
        return true;
    case RETRO_ENVIRONMENT_GET_JIT_CAPABLE: if (data) *(bool *)data = false; return true;
    case RETRO_ENVIRONMENT_SHUTDOWN: gShutdown = true; return true;
    case RETRO_ENVIRONMENT_SET_VARIABLES:
        // The bridge's recordDeclaredOptions: the first value after "; ".
        for (auto *v = (const retro_variable *)data; v && v->key; v++) {
            if (!v->value) continue;
            const char *list = strstr(v->value, "; ");
            if (!list) continue;
            list += 2;
            const char *end = strchr(list, '|');
            gDefaults[v->key] = end ? std::string(list, (size_t)(end - list)) : std::string(list);
        }
        return true;
    case RETRO_ENVIRONMENT_SET_GEOMETRY:
    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK:
    case RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO:
    case RETRO_ENVIRONMENT_SET_MESSAGE:
    case RETRO_ENVIRONMENT_SET_MESSAGE_EXT:
    case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL:
    case RETRO_ENVIRONMENT_SET_MINIMUM_AUDIO_LATENCY:
    case RETRO_ENVIRONMENT_SET_AUDIO_BUFFER_STATUS_CALLBACK:
        return true;
    default:
        return false;
    }
}

void video(const void *data, unsigned w, unsigned h, size_t) {
    if (!data || !w || !h || data != RETRO_HW_FRAME_BUFFER_VALID) return;
    if (w > kMaxW) w = kMaxW;
    if (h > kMaxH) h = kMaxH;
    const uint64_t t = nowNs(CLOCK_MONOTONIC);
    if (gVulkan.readFrame(w, h, gPicture.data(), kMaxW)) {
        gWidth = w;
        gHeight = h;
        gNewPicture = true;
    }
    gReadNs += nowNs(CLOCK_MONOTONIC) - t;
}

void audioSample(int16_t l, int16_t r) { gFrameAudio.push_back(l); gFrameAudio.push_back(r); }
int gFirstAudioBatchFrame = -1;  // the frame the boot completed on (see PSPBridge)
size_t audioBatch(const int16_t *d, size_t frames) {
    if (gFirstAudioBatchFrame < 0) gFirstAudioBatchFrame = gFrame;
    gFrameAudio.insert(gFrameAudio.end(), d, d + frames * 2);
    return frames;
}
void inputPoll() {}

int16_t heldMask() {
    int16_t m = 0;
    for (auto &p : gOpt.presses) if (gFrame >= p.from && gFrame <= p.to) m |= p.mask;
    return m;
}
int16_t inputState(unsigned port, unsigned device, unsigned, unsigned id) {
    if (port != 0 || device != RETRO_DEVICE_JOYPAD) return 0;
    const int16_t m = heldMask();
    if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return m;
    return (m >> id) & 1;
}

Options parse(int argc, char **argv) {
    if (argc < 3) die("usage: psp-bench <hash|bench|roundtrip|rewind|cheat|capture|verify> <game> --assets DIR [--frames N] [--out FILE] [--press MASK@A-B] [--rt-at N] [--rt-len M] [--scale 1|2]");
    Options o;
    o.mode = argv[1];
    o.rom = argv[2];
    for (int i = 3; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> std::string { if (i + 1 >= argc) die("missing value"); return argv[++i]; };
        if (a == "--frames") o.frames = atoi(next().c_str());
        else if (a == "--out") o.out = next();
        else if (a == "--assets") o.assets = next();
        else if (a == "--rt-at") o.rtAt = atoi(next().c_str());
        else if (a == "--rt-len") o.rtLen = atoi(next().c_str());
        else if (a == "--scale") o.scale = atoi(next().c_str());
        else if (a == "--shot") o.shot = atoi(next().c_str());
        else if (a == "--rw-every") o.rwEvery = atoi(next().c_str());
        else if (a == "--cheat-offset") o.cheatOffset = (unsigned)strtoul(next().c_str(), nullptr, 16);
        else if (a == "--cheat-value") o.cheatValue = (unsigned)strtoul(next().c_str(), nullptr, 16);
        else if (a == "--reset-after-load") o.resetAfterLoad = next();
        else if (a == "--state") o.state = next();
        else if (a == "--expect") o.expect = next();
        else if (a == "--record") o.record = true;
        else if (a == "--load-first") o.loadFirst = true;
        else if (a == "--peek") {
            if (sscanf(next().c_str(), "%x,%d", &o.peekAddress, &o.peekWords) != 2) die("--peek ADDR,N");
        }
        else if (a == "--press") {
            Press p{};
            int mask = 0;
            if (sscanf(next().c_str(), "%i@%d-%d", &mask, &p.from, &p.to) != 3) die("--press MASK@A-B");
            p.mask = (int16_t)mask;
            o.presses.push_back(p);
        } else die(("unknown option " + a).c_str());
    }
    if (o.mode != "hash" && o.mode != "bench" && o.mode != "roundtrip" && o.mode != "rewind" && o.mode != "cheat"
        && o.mode != "capture" && o.mode != "verify") die("mode is hash, bench, roundtrip, rewind, cheat, capture or verify");
    if (o.assets.empty()) die("--assets DIR is required");
#ifdef PSP_BENCH_NO_STATE_FORMAT
    if (o.mode == "capture" || o.mode == "verify")
        die("capture and verify need PSPBridge's state format: rebuild with build.sh's third argument (an lzfse clone)");
#endif
    if (o.scale != 1 && o.scale != 2) die("--scale is 1 or 2");
    return o;
}

/// One frame; its line goes to `out` when given.
void step(FILE *out) {
    if (gShutdown) die("the core asked to shut down (its boot failed); not calling retro_run again");
    gFrameAudio.clear();
    gNewPicture = false;
    gVulkan.beginFrame();
    retro_run();
    if (out) {
        uint64_t h = 1469598103934665603ull;
        // The colour the player sees: R, G, B of each pixel. The fourth byte is
        // the framebuffer's alpha, which the app never shows (the Metal view
        // draws the picture opaque) and which PPSSPP leaves as whatever the
        // last draw wrote: hashing it made identical pictures differ.
        if (gNewPicture) for (unsigned y = 0; y < gHeight; y++)
            for (unsigned x = 0; x < gWidth; x++) h = fnv(&gPicture[(size_t)y * kMaxW + x], 3, h);
        fprintf(out, "%d %ux%u %016llx %016llx %zu\n", gFrame,
                gNewPicture ? gWidth : 0, gNewPicture ? gHeight : 0,
                gNewPicture ? (unsigned long long)h : 0ull,
                (unsigned long long)fnv(gFrameAudio.data(), gFrameAudio.size() * 2),
                gFrameAudio.size() / 2);
    }
    if (gFrame == gOpt.shot && gNewPicture && !gOpt.out.empty()) {
        FILE *p = fopen((gOpt.out + gShotTag + ".ppm").c_str(), "wb");
        if (p) {
            fprintf(p, "P6\n%u %u\n255\n", gWidth, gHeight);
            for (unsigned y = 0; y < gHeight; y++)
                for (unsigned x = 0; x < gWidth; x++) {
                    // The frontend writes R, G, B, A bytes (N64VulkanFrontend.h).
                    const uint8_t *px = (const uint8_t *)&gPicture[(size_t)y * kMaxW + x];
                    fwrite(px, 1, 3, p);
                }
            fclose(p);
        }
    }
    gFrame++;
}


// The PSP's RAM as rcheevos and the bridge read it: RETRO_MEMORY_SYSTEM_RAM
// starts at the kernel base, 0x08000000; a CWCheat address is an offset from
// the user base, 0x08800000.
uint32_t ramWord(size_t userOffset) {
    const uint8_t *ram = (const uint8_t *)retro_get_memory_data(RETRO_MEMORY_SYSTEM_RAM);
    const size_t size = retro_get_memory_size(RETRO_MEMORY_SYSTEM_RAM);
    const size_t at = 0x800000 + userOffset;
    if (!ram || at + 4 > size) die("RAM not exposed or offset out of range");
    uint32_t v;
    memcpy(&v, ram + at, 4);
    return v;
}

std::string findCheatFile(const std::string &dir) {
    std::string found;
    FILE *ls = popen(("find '" + dir + "' -path '*PSP/Cheats/*.ini' 2>/dev/null").c_str(), "r");
    char line[1024];
    while (ls && fgets(line, sizeof line, ls)) { found = line; if (!found.empty() && found.back() == '\n') found.pop_back(); }
    if (ls) pclose(ls);
    return found;
}

void runCheat() {
    while (gFirstAudioBatchFrame < 0 && gFrame < 3000) step(nullptr);
    for (int i = 0; i < 600; i++) step(nullptr);
    fprintf(stderr, "psp-bench: boot complete at frame %d, now frame %d\n", gFirstAudioBatchFrame, gFrame);
    printf("RAM %zu bytes exposed; user word at +0x%x = %08x before\n",
           retro_get_memory_size(RETRO_MEMORY_SYSTEM_RAM), gOpt.cheatOffset, ramWord(gOpt.cheatOffset));

    // 1. The core names the file: retro_cheat_reset writes "_S <ID>" into it.
    retro_cheat_reset();
    const std::string file = findCheatFile(gSystemDir);
    if (file.empty()) die("retro_cheat_reset wrote no PSP/Cheats/<ID>.ini");
    FILE *f = fopen(file.c_str(), "rb");
    char head[256] = {0};
    if (f) { fread(head, 1, sizeof head - 1, f); fclose(f); }
    printf("cheat file %s holds: %s", file.c_str() + gSystemDir.size(), head);

    // 2. The bridge's sequence, each time its list changes: retro_cheat_reset
    // (which writes "_S <ID>" and asks the engine to reload), then the whole
    // file rewritten before the next retro_run, where the reload happens.
    std::string id = file.substr(file.rfind('/') + 1);
    id = id.substr(0, id.size() - 4);
    auto apply = [&](const char *body) {
        retro_cheat_reset();
        FILE *w = fopen(file.c_str(), "wb");
        fprintf(w, "_S %s\n%s", id.c_str(), body);
        fclose(w);
    };
    auto settle = [&](uint32_t want) {
        for (int i = 0; i < 120; i++) { step(nullptr); if (ramWord(gOpt.cheatOffset) == want) return i; }
        return -1;
    };
    char one[128];
    snprintf(one, sizeof one, "_C1 a\n_L 0x2%07X 0x%08X\n", gOpt.cheatOffset, gOpt.cheatValue);
    apply(one);
    printf("add: applied after %d frames\n", settle(gOpt.cheatValue));

    // The game writes nothing there, so a cleared cheat leaves the value; the
    // proof of a clear is that a second value is NOT overwritten back.
    apply("");
    uint8_t *ram = (uint8_t *)retro_get_memory_data(RETRO_MEMORY_SYSTEM_RAM);
    const uint32_t poke = 0x11223344;
    memcpy(ram + 0x800000 + gOpt.cheatOffset, &poke, 4);
    for (int i = 0; i < 120; i++) step(nullptr);
    printf("clear: %s\n", ramWord(gOpt.cheatOffset) == poke ? "the cheat no longer writes" : "STILL WRITING");

    // Two cheats, the second over the next word, with a multi-line code.
    char two[256];
    snprintf(two, sizeof two, "_C1 a\n_L 0x2%07X 0x%08X\n_C1 b\n_L 0x2%07X 0x00000001\n_L 0x2%07X 0x00000002\n",
             gOpt.cheatOffset, gOpt.cheatValue, gOpt.cheatOffset + 4, gOpt.cheatOffset + 8);
    apply(two);
    const int t = settle(gOpt.cheatValue);
    printf("two cheats: first after %d frames, second's words %08x %08x\n", t,
           ramWord(gOpt.cheatOffset + 4), ramWord(gOpt.cheatOffset + 8));

    // A state round trip keeps cheats applying (the engine is not in the state).
    gVulkan.beginFrame();
    const size_t sz = retro_serialize_size();
    std::vector<uint8_t> st(sz);
    retro_serialize(st.data(), sz);
    memcpy(ram + 0x800000 + gOpt.cheatOffset, &poke, 4);
    gVulkan.beginFrame();
    retro_unserialize(st.data(), sz);
    printf("after a state load: applied again after %d frames\n", settle(gOpt.cheatValue));
    printf("now %08x\n", ramWord(gOpt.cheatOffset));
}

// LZ4 from the system's liblz4, loaded at run time only for this mode: the
// phone packs with Apple's LZ4 (COMPRESSION_LZ4, its own framing over the same
// algorithm), so the sizes here are the phone's to within the framing.
int lz4Bound(int n) { return n + n / 255 + 16; }
int lz4Pack(const uint8_t *src, size_t n, std::vector<uint8_t> &dst) {
    using Fn = int (*)(const char *, char *, int, int);
    static Fn fn = nullptr;
    if (!fn) {
        void *lib = dlopen("liblz4.so.1", RTLD_NOW);
        if (!lib || !(fn = (Fn)dlsym(lib, "LZ4_compress_default"))) die("liblz4.so.1 is needed for rewind");
    }
    dst.resize((size_t)lz4Bound((int)n));
    return fn((const char *)src, (char *)dst.data(), (int)n, (int)dst.size());
}

struct RwStep { std::vector<uint32_t> blocks; std::vector<uint8_t> old; size_t packed = 0; size_t oldSize = 0; };
constexpr size_t kBlock = 4096;

std::vector<uint8_t> snapshot(size_t &bufferSize) {
    gVulkan.beginFrame();
    // Measured every time, as the bridge must: the core writes the whole state
    // whatever size it is told, and the state's size moves during play.
    const uint64_t m0 = nowNs(CLOCK_MONOTONIC);
    bufferSize = retro_serialize_size();
    const uint64_t t0 = nowNs(CLOCK_MONOTONIC);
    std::vector<uint8_t> s(bufferSize);
    const uint64_t a0 = nowNs(CLOCK_MONOTONIC);
    if (!retro_serialize(s.data(), bufferSize)) die("retro_serialize failed");
    fprintf(stderr, "  serialize %.1f ms (measuring %.1f ms before it)\n",
            (nowNs(CLOCK_MONOTONIC) - a0) / 1e6, (t0 - m0) / 1e6);
    return s;
}

// The design PSPBridge uses, and its proof: undoing the steps newest first
// must give back, byte for byte, each snapshot the run took, and a game
// restored from the oldest must run exactly as it ran the first time.
void runRewind(FILE *out) {
    (void)out;
    // Booted first: no state exists before (retro_serialize_size is a
    // placeholder until the GPU is up).
    while (gFirstAudioBatchFrame < 0 && gFrame < 3000) step(nullptr);
    fprintf(stderr, "psp-bench: boot complete at frame %d\n", gFirstAudioBatchFrame);

    std::vector<std::vector<uint8_t>> taken;   // every snapshot, for the check
    std::vector<int> takenAt;
    std::vector<RwStep> steps;                 // steps[i] turns taken[i+1] into taken[i]
    char *run = nullptr; size_t runLen = 0;
    FILE *log = open_memstream(&run, &runLen);
    size_t size = 0, previousSize = 0;
    std::vector<uint8_t> current;
    size_t historyPacked = 0, historyRaw = 0;
    int layoutBreaks = 0;
    const int firstLogged = gFrame;            // `run`'s first line
    while (gFrame < gOpt.frames) {
        if ((gFrame - gFirstAudioBatchFrame) % gOpt.rwEvery == 0) {
            std::vector<uint8_t> next = snapshot(size);
            if (!current.empty()) {
                // The state's size moves during play (MHFU: 40 MB of buffer
                // in town, 56 MB on the way into the world). A step therefore
                // describes the OLDER state whole: its size, and each of its
                // blocks that the newer one lacks or holds differently.
                RwStep st;
                st.oldSize = previousSize;
                if (size != previousSize) {
                    layoutBreaks++;
                    printf("snapshot at frame %d: buffer %zu -> %zu bytes\n", gFrame, previousSize, size);
                }
                for (size_t b = 0; b * kBlock < previousSize; b++) {
                    const size_t off = b * kBlock, len = std::min(kBlock, previousSize - off);
                    if (off + len > size || memcmp(current.data() + off, next.data() + off, len)) {
                        st.blocks.push_back((uint32_t)b);
                        st.old.insert(st.old.end(), current.begin() + off, current.begin() + off + len);
                    }
                }
                std::vector<uint8_t> packed;
                st.packed = st.old.empty() ? 0 : (size_t)lz4Pack(st.old.data(), st.old.size(), packed);
                historyPacked += st.packed; historyRaw += st.old.size();
                size_t used = size; while (used && next[used - 1] == 0) used--;
                printf("snapshot at frame %d: state %.2f MB used of a %.0f MB buffer | %zu blocks changed = %.2f MB, "
                       "%.2f MB packed\n", gFrame, used / 1048576.0, size / 1048576.0, st.blocks.size(),
                       st.old.size() / 1048576.0, st.packed / 1048576.0);
                steps.push_back(std::move(st));
            }
            taken.push_back(next);
            takenAt.push_back(gFrame);
            current = std::move(next);
            previousSize = size;
        }
        step(log);
    }
    fclose(log);
    printf("history: %zu steps, %.2f MB raw, %.2f MB packed; %d buffer-size changes crossed\n",
           steps.size(), historyRaw / 1048576.0, historyPacked / 1048576.0, layoutBreaks);

    // Undo, newest first, checking every state reached.
    // The buffer as the bridge keeps it: as large as the largest state seen,
    // holding the current one in its first `stateSize` bytes.
    size_t largest = 0;
    for (auto &t : taken) largest = std::max(largest, t.size());
    std::vector<uint8_t> state(largest, 0);
    memcpy(state.data(), current.data(), current.size());
    size_t stateSize = current.size();
    int exact = 0;
    for (size_t k = steps.size(); k-- > 0;) {
        const RwStep &st = steps[k];
        size_t at = 0;
        for (uint32_t b : st.blocks) {
            const size_t off = (size_t)b * kBlock, len = std::min(kBlock, st.oldSize - off);
            memcpy(state.data() + off, st.old.data() + at, len);
            at += len;
        }
        stateSize = st.oldSize;
        if (stateSize == taken[k].size() && !memcmp(state.data(), taken[k].data(), stateSize)) exact++;
        else printf("  step %zu: the rebuilt state differs from the one taken at frame %d\n", k, takenAt[k]);
    }
    printf("undo: %d of %zu rebuilt states identical to the snapshot taken then\n", exact, steps.size());

    // Replay from the oldest rebuilt state and compare with the run's lines.
    std::vector<std::string> original;
    for (char *x = run; x && *x;) { char *e = strchr(x, '\n'); if (!e) break; original.emplace_back(x, e); x = e + 1; }
    const int from = takenAt.front();
    gVulkan.beginFrame();
    if (!retro_unserialize(state.data(), stateSize)) die("retro_unserialize refused the rebuilt state");
    gFrame = from;
    char *rep = nullptr; size_t repLen = 0;
    FILE *r = open_memstream(&rep, &repLen);
    const int replay = std::min(gOpt.frames - from, 1200);
    for (int i = 0; i < replay; i++) step(r);
    fclose(r);
    int same = 0, sameSound = 0, n = 0;
    auto field = [](const std::string &l, int k) { size_t p = 0; for (int i = 0; i < k; i++) p = l.find(' ', p) + 1; return l.substr(p, l.find(' ', p) - p); };
    int i = 0;
    for (char *x = rep; x && *x; i++) {
        char *e = strchr(x, '\n'); if (!e) break;
        std::string line(x, e); x = e + 1;
        const size_t o = (size_t)(from - firstLogged + i);
        if (i < 2 || o >= original.size()) continue;   // the two hidden frames
        n++;
        if (line == original[o]) same++;
        if (field(line, 3) == field(original[o], 3)) sameSound++;
    }
    printf("replay from the oldest rebuilt state (frame %d), frames +2..+%d: %d of %d lines identical, sound %d of %d\n",
           from, replay - 1, same, n, sameSound, n);
}

// The PSP's RAM as the bridge exposes it (RETRO_MEMORY_SYSTEM_RAM, 32 MB from
// the kernel base), hashed a word at a time.
uint64_t ramHash() {
    const uint8_t *ram = (const uint8_t *)retro_get_memory_data(RETRO_MEMORY_SYSTEM_RAM);
    const size_t size = retro_get_memory_size(RETRO_MEMORY_SYSTEM_RAM);
    if (!ram || !size) return 0;
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i + 8 <= size; i += 8) {
        uint64_t w;
        memcpy(&w, ram + i, 8);
        h = (h ^ w) * 1099511628211ull;
    }
    return h;
}

// One frame of verify: RAM after it and its sound; the picture's hash rides
// along in the line's last field, which the comparison leaves out.
std::string verifyLine(int frame) {
    uint64_t pic = 1469598103934665603ull;
    if (gNewPicture) for (unsigned y = 0; y < gHeight; y++)
        for (unsigned x = 0; x < gWidth; x++) pic = fnv(&gPicture[(size_t)y * kMaxW + x], 3, pic);
    char line[160];
    snprintf(line, sizeof line, "%d %016llx %016llx %zu %016llx", frame,
             (unsigned long long)ramHash(), (unsigned long long)fnv(gFrameAudio.data(), gFrameAudio.size() * 2),
             gFrameAudio.size() / 2, gNewPicture ? (unsigned long long)pic : 0ull);
    return line;
}

void runCapture() {
    if (gOpt.state.empty()) die("capture wants --state FILE");
    while (gFrame < gOpt.frames) step(nullptr);
    if (gFirstAudioBatchFrame < 0) die("the boot has not completed; no state to save (PSPBridge refuses too)");
    // PSPBridge's saveStateToPath: measured, serialized, the zero padding cut,
    // packed by the bridge's own format code.
    gVulkan.beginFrame();
    const size_t size = retro_serialize_size();
    std::vector<uint8_t> buffer(size);
    if (!size || !retro_serialize(buffer.data(), size)) die("retro_serialize failed");
    const size_t used = PSPUsedLength(buffer.data(), size);
    std::vector<uint8_t> file;
    if (!PSPStateFormatPack(buffer.data(), used, file)) die("PSPStateFormatPack refused the core's state");
    FILE *f = fopen(gOpt.state.c_str(), "wb");
    if (!f || fwrite(file.data(), 1, file.size(), f) != file.size()) die("cannot write the state");
    fclose(f);
    // Read back through the bridge's own unpack, as a load would.
    std::vector<uint8_t> back;
    if (!PSPStateFormatUnpack(file.data(), file.size(), back) || back.size() != used
        || memcmp(back.data(), buffer.data(), used) != 0) die("the written file does not unpack to the state");
    printf("capture: boot complete at frame %d; state at frame %d: buffer %zu, used %zu, file %zu bytes (packed %.1fx)\n",
           gFirstAudioBatchFrame, gFrame, size, used, file.size(), (double)used / (double)file.size());
    // For reading only: a load does NOT give this hash back, the JIT's block
    // markers in the game's code being rewritten (CAPTURE.md, PPSSPP).
    printf("capture: RAM %zu bytes, hash %016llx\n", retro_get_memory_size(RETRO_MEMORY_SYSTEM_RAM),
           (unsigned long long)ramHash());
}

int runVerify() {
    if (gOpt.state.empty() || gOpt.expect.empty()) die("verify wants --state FILE and --expect FILE");
    // The test's path: one frame (no input), then the load. --load-first
    // loads before any frame, so the port must keep the state through the
    // boot (the phone's case when its boot outlasts the first frame).
    std::vector<Press> script = gOpt.presses;
    gOpt.presses.clear();
    if (!gOpt.loadFirst) step(nullptr);
    FILE *sf = fopen(gOpt.state.c_str(), "rb");
    if (!sf) die("cannot open the state");
    fseek(sf, 0, SEEK_END);
    const size_t len = (size_t)ftell(sf);
    fseek(sf, 0, SEEK_SET);
    std::vector<uint8_t> file(len);
    if (fread(file.data(), 1, len, sf) != len) die("cannot read the state");
    fclose(sf);
    std::vector<uint8_t> state;
    if (!PSPStateFormatUnpack(file.data(), len, state)) die("PSPStateFormatUnpack refused the file, as the bridge would");
    const bool beforeBoot = gFirstAudioBatchFrame < 0;
    gVulkan.beginFrame();
    if (!retro_unserialize(state.data(), state.size())) die("retro_unserialize refused the state");
    if (!beforeBoot) printf("verify: RAM right after the load, hash %016llx\n", (unsigned long long)ramHash());
    gOpt.presses = script;
    // Frames until the game runs from the state: before the boot has completed
    // the port applies the state in the frame the boot ends, which is then the
    // first frame after the save. Lines of frames that are still boot are dropped.
    std::vector<std::string> got;
    int bootFrames = 0;
    // --peek ADDR,N: N 32-bit words of the PSP's RAM at real address ADDR
    // (0x08000000 + the offset into RETRO_MEMORY_SYSTEM_RAM, as PSPBridge's
    // readMemoryAtAddress reads), printed on the first frame played from the
    // state: what the test reads on the phone after the load.
    auto peek = [&]() {
        if (gOpt.peekWords <= 0) return;
        const uint8_t *ram = (const uint8_t *)retro_get_memory_data(RETRO_MEMORY_SYSTEM_RAM);
        const size_t size = retro_get_memory_size(RETRO_MEMORY_SYSTEM_RAM);
        const size_t at = gOpt.peekAddress - 0x08000000u;
        if (!ram || gOpt.peekAddress < 0x08000000u || at + 4 * (size_t)gOpt.peekWords > size) die("--peek out of RAM");
        printf("verify: RAM at 0x%08x:", gOpt.peekAddress);
        for (int k = 0; k < gOpt.peekWords; k++) { int32_t w; memcpy(&w, ram + at + 4 * k, 4); printf(" %d", w); }
        printf("\n");
    };
    if (!beforeBoot) peek();
    for (int i = 0; i < gOpt.rtLen;) {
        gFrame = gOpt.rtAt + i;
        // A frame that STARTS during the boot is boot, the one the boot ends
        // in included: the port applies the kept state there and that frame
        // gives no picture and no sound (measured: dropping it lines the run
        // up with a load after the boot, frame for frame).
        const bool wasBooting = gFirstAudioBatchFrame < 0;
        step(nullptr);
        if (wasBooting) {
            if (++bootFrames > 3000) die("the boot never completed after the load");
            continue;
        }
        if (got.empty() && beforeBoot) peek();
        got.push_back(verifyLine(gOpt.rtAt + i));
        i++;
    }
    if (gOpt.record) {
        FILE *ef = fopen(gOpt.expect.c_str(), "w");
        if (!ef) die("cannot write --expect");
        for (auto &l : got) fprintf(ef, "%s\n", l.c_str());
        fclose(ef);
        printf("verify --record: file %zu bytes, state %zu, loaded %s the boot completed (%d boot frames after it), %zu lines written\n",
               len, state.size(), beforeBoot ? "before" : "after", bootFrames, got.size());
        return 0;
    }
    std::vector<std::string> want;
    FILE *ef = fopen(gOpt.expect.c_str(), "r");
    if (!ef) die("cannot open --expect");
    char buf[256];
    while (fgets(buf, sizeof buf, ef)) { std::string l(buf); while (!l.empty() && l.back() == '\n') l.pop_back(); want.push_back(l); }
    fclose(ef);
    auto upToPicture = [](const std::string &l) { return l.substr(0, l.rfind(' ')); };
    auto field = [](const std::string &l, int n) {
        size_t a = 0;
        for (int k = 0; k < n && a != std::string::npos; k++) { a = l.find(' ', a); if (a != std::string::npos) a++; }
        if (a == std::string::npos) return std::string();
        const size_t e = l.find(' ', a);
        return l.substr(a, e == std::string::npos ? std::string::npos : e - a);
    };
    int same = 0, samePicture = 0, sound = 0, firstDiff = -1;
    for (size_t i = 0; i < got.size() && i < want.size(); i++) {
        if (upToPicture(got[i]) == upToPicture(want[i])) same++;
        else if (firstDiff < 0) { firstDiff = (int)i; printf("  got  %s\n  want %s\n", got[i].c_str(), want[i].c_str()); }
        if (got[i] == want[i]) samePicture++;
        if (field(got[i], 2) == field(want[i], 2) && field(got[i], 3) == field(want[i], 3)) sound++;
    }
    printf("verify: file %zu bytes, loaded %s the boot completed; %d of %zu frames identical in RAM and sound "
           "(picture too: %d; sound alone: %d)",
           len, beforeBoot ? "before" : "after", same, want.size(), samePicture, sound);
    if (firstDiff >= 0) printf(", first difference %d frames after the load", firstDiff);
    printf("\n");
    return (same == (int)want.size() && got.size() == want.size()) ? 0 : 1;
}

}  // namespace

int main(int argc, char **argv) {
    gOpt = parse(argc, argv);
    gResolution = gOpt.scale == 2 ? "960x544" : "480x272";
    if (gOpt.mode == "cheat") gCheats = "enabled";

    // The core reads <system>/PPSSPP; a fresh directory holding a link to the
    // assets, so its config and memory stick land in a throwaway place.
    char dir[] = "/tmp/psp-bench-sys-XXXXXX";
    if (!mkdtemp(dir)) die("mkdtemp");
    gSystemDir = dir;
    if (symlink(gOpt.assets.c_str(), (gSystemDir + "/PPSSPP").c_str()) != 0) die("cannot link the assets");

    retro_set_environment(environment);
    retro_set_video_refresh(video);
    retro_set_audio_sample(audioSample);
    retro_set_audio_sample_batch(audioBatch);
    retro_set_input_poll(inputPoll);
    retro_set_input_state(inputState);
    retro_init();

    retro_game_info info{};
    info.path = gOpt.rom.c_str();  // need_fullpath: the core opens the file
    const uint64_t loadT0 = nowNs(CLOCK_MONOTONIC);
    if (!retro_load_game(&info)) die("retro_load_game failed");
    if (!gHasHW || !gVulkan.createDevice(gNegotiation, kMaxW, kMaxH)) die("no Vulkan device");
    if (gHW.context_reset) gHW.context_reset();
    fprintf(stderr, "psp-bench: loaded in %.0f ms\n", (nowNs(CLOCK_MONOTONIC) - loadT0) / 1e6);

    retro_system_av_info av{};
    retro_get_system_av_info(&av);
    const double fps = av.timing.fps;
    fprintf(stderr, "psp-bench: %.4f fps, %.0f Hz, base %ux%u, max %ux%u\n", fps, av.timing.sample_rate,
            av.geometry.base_width, av.geometry.base_height, av.geometry.max_width, av.geometry.max_height);

    FILE *out = stdout;
    if (!gOpt.out.empty() && !(out = fopen(gOpt.out.c_str(), "w"))) die("cannot write --out");

    if (gOpt.resetAfterLoad == "raw") {
        fprintf(stderr, "psp-bench: reset right after the load, as the session did\n");
        gVulkan.beginFrame();
        retro_reset();
    } else if (gOpt.resetAfterLoad == "guarded") {
        // PSPBridge: skipped while the boot runs; sent once it completed.
        int ran = 0;
        while (gFirstAudioBatchFrame < 0 && ran < 2000) { step(nullptr); ran++; }
        fprintf(stderr, "psp-bench: boot complete at frame %d (first audio batch); now the reset\n",
                gFirstAudioBatchFrame);
        gVulkan.beginFrame();
        retro_reset();
        fprintf(stderr, "psp-bench: reset returned, shutdown=%d\n", (int)gShutdown);
    }

    if (gOpt.mode == "hash") {
        while (gFrame < gOpt.frames) step(out);
    } else if (gOpt.mode == "bench") {
        const int warmup = gOpt.frames > 240 ? 120 : 0;
        uint64_t wallNs = 0, cpuNs = 0, drainNs = 0, worstNs = 0, samples = 0;
        for (; gFrame < gOpt.frames;) {
            if (gFrame == warmup) gReadNs = 0;
            gFrameAudio.clear();
            gNewPicture = false;
            const uint64_t w0 = nowNs(CLOCK_MONOTONIC);
            const uint64_t c0 = nowNs(CLOCK_THREAD_CPUTIME_ID);
            if (gShutdown) die("the core asked to shut down (its boot failed); not calling retro_run again");
            gVulkan.beginFrame();
            const uint64_t w1 = nowNs(CLOCK_MONOTONIC);
            retro_run();
            const uint64_t w2 = nowNs(CLOCK_MONOTONIC);
            const uint64_t c2 = nowNs(CLOCK_THREAD_CPUTIME_ID);
            if (gFrame >= warmup) {
                wallNs += w2 - w0;
                cpuNs += c2 - c0;
                drainNs += w1 - w0;
                if (w2 - w0 > worstNs) worstNs = w2 - w0;
                samples += gFrameAudio.size() / 2;
            }
            gFrame++;
        }
        const double n = (double)(gOpt.frames - warmup);
        printf("frames %d (timed %d) at %.4f fps\n", gOpt.frames, (int)n, fps);
        printf("wall %.3f ms/frame | emulation thread cpu %.3f | beginFrame drain %.3f | readback %.3f | worst %.2f ms\n",
               wallNs / n / 1e6, cpuNs / n / 1e6, drainNs / n / 1e6, gReadNs / n / 1e6, worstNs / 1e6);
        printf("audio %.2f samples/frame = %.1f Hz at the core's fps\n", samples / n, samples / n * fps);
    } else if (gOpt.mode == "rewind") {
        runRewind(out);
    } else if (gOpt.mode == "cheat") {
        runCheat();
    } else if (gOpt.mode == "capture") {
        runCapture();
    } else if (gOpt.mode == "verify") {
        const int rc = runVerify();
        fflush(stdout);
        _exit(rc);
    } else {
        FILE *pre = open_memstream(&gPre, &gPreLen);
        while (gFrame < gOpt.rtAt) step(pre);
        fclose(pre);
        gVulkan.beginFrame();
        const size_t size = retro_serialize_size();
        std::vector<uint8_t> state(size);
        const uint64_t s0 = nowNs(CLOCK_MONOTONIC);
        if (!retro_serialize(state.data(), size)) die("retro_serialize failed");
        const uint64_t s1 = nowNs(CLOCK_MONOTONIC);
        printf("state buffer %zu bytes, serialized in %.1f ms\n", size, (s1 - s0) / 1e6);
        // What a slot would actually hold: the core pads its measured state to
        // the next 8 MB, and the tail is zeroes. The used length is where the
        // last non-zero byte is (a PPSSPP state is a chunk stream with its own
        // header, so the bridge can store exactly that).
        {
            size_t used = size;
            while (used > 0 && state[used - 1] == 0) used--;
            printf("state used %zu bytes (%.1f MB)\n", used, used / 1048576.0);
            if (!gOpt.out.empty()) {
                FILE *sf = fopen((gOpt.out + ".state").c_str(), "wb");
                if (sf) { fwrite(state.data(), 1, used, sf); fclose(sf); }
            }
        }
        char *pa = nullptr, *pb = nullptr;
        size_t la = 0, lb = 0;
        const int start = gFrame;
        gShotTag = ".A";
        FILE *a = open_memstream(&pa, &la);
        for (int i = 0; i < gOpt.rtLen; i++) step(a);
        fclose(a);
        gVulkan.beginFrame();
        const uint64_t u0 = nowNs(CLOCK_MONOTONIC);
        if (!retro_unserialize(state.data(), size)) die("retro_unserialize refused the state");
        printf("unserialized in %.1f ms\n", (nowNs(CLOCK_MONOTONIC) - u0) / 1e6);
        gFrame = start;
        gShotTag = ".B";
        FILE *b = open_memstream(&pb, &lb);
        for (int i = 0; i < gOpt.rtLen; i++) step(b);
        fclose(b);
        int same = 0, sameVideo = 0, firstDiff = -1, blank = 0;
        char *sa = pa, *sb = pb;
        for (int i = 0; i < gOpt.rtLen; i++) {
            char *ea = strchr(sa, '\n'), *eb = strchr(sb, '\n');
            if (!ea || !eb) break;
            if (ea - sa == eb - sb && !memcmp(sa, sb, (size_t)(ea - sa))) same++;
            else if (firstDiff < 0) {
                firstDiff = start + i;
                printf("  A %.*s\n  B %.*s\n", (int)(ea - sa), sa, (int)(eb - sb), sb);
            }
            // picture = the first three fields
            char *va = sa, *vb = sb;
            for (int k = 0; k < 3 && va && vb; k++) { va = strchr(va, ' '); vb = strchr(vb, ' '); if (va) va++; if (vb) vb++; }
            if (va && vb && va - sa == vb - sb && !memcmp(sa, sb, (size_t)(va - sa))) sameVideo++;
            if (strstr(sa, " 0x0 ") && strstr(sa, " 0x0 ") < ea) blank++;
            sa = ea + 1;
            sb = eb + 1;
        }
        // Where the differences are, as frame offsets after the load: a GPU
        // that presents a frame late shows ONE stale picture right after it.
        {
            char *xa = pa, *xb = pb;
            // What the differing pictures ARE: matched against every picture of
        // the run up to the end of A, so a stale frame names its frame.
        {
            std::map<std::string, int> seen;
            auto hashOf = [](const char *line) {
                const char *p = line;
                for (int k = 0; k < 2 && p; k++) { p = strchr(p, ' '); if (p) p++; }
                return p ? std::string(p, 16) : std::string();
            };
            for (char *x = gPre; x && *x;) { char *e = strchr(x, '\n'); if (!e) break; seen.emplace(hashOf(x), atoi(x)); x = e + 1; }
            for (char *x = pa; x && *x;) { char *e = strchr(x, '\n'); if (!e) break; seen.emplace(hashOf(x), atoi(x)); x = e + 1; }
            char *xb = pb;
            for (int i = 0; i < 2; i++) {
                char *eb = strchr(xb, '\n');
                if (!eb) break;
                auto it = seen.find(hashOf(xb));
                if (it != seen.end()) printf("  B +%d shows the picture of frame %d\n", i, it->second);
                else printf("  B +%d shows a picture seen nowhere in the run\n", i);
                xb = eb + 1;
            }
        }
        // B's lines against A's NEIGHBOURS: a run shifted by one frame (a
        // picture that is A's previous or next) is a phase, not a divergence.
        {
            std::vector<std::string> va, vb;
            for (char *x = pa; x && *x;) { char *e = strchr(x, '\n'); if (!e) break; va.emplace_back(x, e); x = e + 1; }
            for (char *x = pb; x && *x;) { char *e = strchr(x, '\n'); if (!e) break; vb.emplace_back(x, e); x = e + 1; }
            auto pic = [](const std::string &l) { size_t a = l.find(' '); a = l.find(' ', a + 1); return l.substr(a + 1, 16); };
            int same = 0, prev = 0, next = 0, none = 0;
            for (size_t i = 2; i < va.size() && i < vb.size(); i++) {
                if (pic(vb[i]) == pic(va[i])) same++;
                else if (pic(vb[i]) == pic(va[i - 1])) prev++;
                else if (i + 1 < va.size() && pic(vb[i]) == pic(va[i + 1])) next++;
                else none++;
            }
            printf("from +2: same %d, A's previous %d, A's next %d, neither %d\n", same, prev, next, none);
        }
        printf("differing frames after the load:");
            int shown = 0;
            for (int i = 0; i < gOpt.rtLen && shown < 12; i++) {
                char *ea = strchr(xa, '\n'), *eb = strchr(xb, '\n');
                if (!ea || !eb) break;
                if (!(ea - xa == eb - xb && !memcmp(xa, xb, (size_t)(ea - xa)))) { printf(" +%d", i); shown++; }
                xa = ea + 1; xb = eb + 1;
            }
            printf("\n");
        }
        printf("roundtrip: %d of %d frames identical after the load (picture alone: %d, frames with no new picture: %d)",
               same, gOpt.rtLen, sameVideo, blank);
        if (firstDiff >= 0) printf(", first difference at frame %d", firstDiff);
        printf("\n");
        fflush(stdout);
        _exit(same == gOpt.rtLen ? 0 : 1);
    }
    if (out != stdout) fclose(out);
    fflush(stdout);
    _exit(0);
}
