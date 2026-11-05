// Host harness for the 3DS core as Retro Pal would build it: Azahar's own
// libretro core (src/citra_libretro in Vendor/azahar), drawing through Vulkan,
// on the app's own Vulkan frontend (N64VulkanFrontend.mm, compiled unchanged
// but for its log line, see build.sh), driven in the bridge's order:
// beginFrame, then retro_run, whose video callback reads the picture back.
//
// It exists to PROVE on this machine, before any app code, that Azahar runs on
// the video path the Nintendo 64 and the PSP already ship, and to compare the
// CPU paths the App Store allows (FastInterp, and DynCom, the interpreter the
// other App Store 3DS emulators ship) with the JIT the App Store forbids, on
// the same program, the same frames and the same machine.
//
//   hash    run N frames, one line per frame: picture size and hash, sound hash
//           and sample count.
//   bench   the same run, timed: the core's time per frame (retro_run, the
//           readback included), mean and percentiles, after --warmup frames.
//           Host timings on lavapipe (Mesa's CPU Vulkan): only RATIOS between
//           CPU paths mean anything here; the phone's figures decide.
//   roundtrip  run to --rt-at, serialize, run --rt-len frames (A), unserialize,
//           run them again (B): A and B must be identical, picture and sound.
//   stateformat  run to --rt-at, serialize, and put the state through
//           CTRBridge's OWN file format (CTRStateFormatPack / Unpack, cut from
//           CTRBridge.mm by build.sh): packed, unpacked and compared byte for
//           byte, a damaged copy (one byte flipped) refused, and the unpacked
//           state loaded back into the core, which must run on.
//   reload  run --frames frames, then end the game exactly as a bridge does
//           when the player leaves it (context_destroy, retro_unload_game, the
//           frontend destroyed, retro_deinit: each game has its own bridge, and
//           the core stays linked for the app's whole life, where RetroArch
//           reloads the library), start the SAME program again in the same
//           process and run the same frames: both halves must be identical.
//           State the core keeps between games (Azahar's System is a global
//           singleton) is only visible here.
//
// resume  load --load-state right after the boot and one frame, as the app
//           resumes a game, and say how long it took and whether it was taken.
//
// Usage: 3ds-bench <hash|bench|roundtrip|reload|stateformat|resume> <program> --system DIR [options]
//   --system DIR        the core's system and save directory (it creates its
//                       3DS tree there: sdmc, nand, sysdata)
//   --cpu MODE          fastinterp (default, what the phone runs), dyncom, jit
//   --clock N           the emulated CPU's clock in percent (default 100)
//   --frames N          frames to run (default 1800)
//   --warmup N          bench: frames left out of the statistics (default 300)
//   --out FILE          hash: write the lines there instead of stdout
//   --shot N            also write frame N as a PPM (FILE.N.ppm, or shot.N.ppm)
//   --press MASK@A-B    hold a RetroPad mask on port 1 from frame A to frame B
//   --touch X,Y@A-B     touch the bottom screen at X,Y (its 320x240 pixels)
//   --rt-at N / --rt-len M  roundtrip: frame of the save, frames compared
//   --dump-state FILE   roundtrip: write the serialized state to FILE
//   --load-state FILE   relocate: the state to load (a --dump-state file), written
//                       under another --system directory: it must load here and
//                       the game's saves must land HERE, with no archive error
//
// relocate: the app's data folder moves on iOS (a reinstall gives it a new
// container), so a state written under one --system must work under another.
// Loads --load-state, runs --frames, counts the core's file-system errors (a
// save archive it cannot open, a folder it cannot create), saves the state
// again to --dump-state if given, and fails when any error was counted.
//
// Paths are arguments on purpose: games never enter the repository.

#include "N64VulkanFrontend.h"

// CTRBridge.mm's save-state format, cut out unchanged by build.sh.
#include "CTRStateFormat.inc"
// CTRBridge.mm's rewind data work, cut out unchanged by build.sh.
#include "CTRRewindData.inc"

#include <algorithm>
#include <chrono>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <functional>
#include <map>
#include <string>
#include <vector>
#include <cerrno>
#include <zstd.h>

// The rewind's raw states (patches 0014, 0015), renamed by ctr_symbols.h as the rest.
struct RetroCtrRegion { void *data; size_t size; };
extern "C" bool retro_ctr_rewind_capture(std::vector<uint8_t> *buffer, bool memory_outside,
                                         RetroCtrRegion *regions);
extern "C" bool retro_ctr_rewind_restore(const void *data, size_t size, bool memory_outside,
                                         RetroCtrRegion *regions);
#include <sys/stat.h>

namespace {

struct Press { int16_t mask; int from, to; };
struct Touch { int x, y, from, to; };

struct Options {
    std::string mode, rom, out, system;
    std::string cpu = "fastinterp";
    int clock = 100;
    int frames = 1800, warmup = 300;
    int shot = -1;
    int rtAt = 900, rtLen = 300;
    std::vector<Press> presses;
    std::vector<Touch> touches;
    /// Answer option negotiation as CTRBridge does: the options version and
    /// the v1 / v2 definitions DECLINED, so the core falls back to
    /// SET_VARIABLES, whose declared values are checked against every
    /// override (the bridge's kCoreOptions and its system language).
    std::string bridgeLanguage;
    bool bridgeOptions = false;
    bool asyncShaders = false;
    std::string dumpState;
    std::string loadState;
};

[[noreturn]] void die(const char *msg) {
    fprintf(stderr, "3ds-bench: %s\n", msg);
    exit(2);
}

Options gOpt;
std::string gClock;

// The options a bridge would set. Vulkan, the hardware shader path, no shader
// JIT (an iOS build of the core has none: core_settings.cpp forces it off),
// the 3DS's own resolution, the top screen over the bottom one, the disk
// shader cache ON (a game's second launch must not recompile its shaders; and
// at 2127.0-alpha2 the core crashes with it OFF: the pipeline cache's
// curr_disk_cache is only made by LoadDefaultDiskResources, which the libretro
// core calls only when the option is on, citra_libretro.cpp do_load_game).
// The CPU path is the one under test. Everything else is the core's default.
std::map<std::string, std::string> fixedOptions() {
    std::map<std::string, std::string> o = {
        { "citra_graphics_api", "Vulkan" },
        { "citra_use_hw_shader", "enabled" },
        { "citra_use_shader_jit", "disabled" },
        { "citra_resolution_factor", "1" },
        { "citra_layout_option", "default" },
        { "citra_use_disk_shader_cache", "enabled" },
        { "citra_cpu_clock_percentage", gClock },
    };
    if (gOpt.bridgeOptions) {
        // CTRBridge.mm's kCoreOptions, the same keys and values, plus its
        // language: what the phone sets. Checked below against the core.
        o["citra_enable_touch_touchscreen"] = "enabled";
        o["citra_enable_mouse_touchscreen"] = "disabled";
        o["citra_region_value"] = "Auto";
        o["citra_language_value"] = gOpt.bridgeLanguage;
        o["citra_async_shader_compilation"] = "enabled";
        o["citra_async_small_draws"] = "enabled";
        o["citra_async_never_waits"] = "enabled";
        // Missing until 2026-10-20 (audit): the C-stick on the right stick
        // only, and the microphone through the frontend.
        o["citra_analog_function"] = "c_stick";
        o["citra_input_type"] = "frontend";
    }
    // Patch 0003's option, alone, for an A/B against the core's default (off).
    if (gOpt.asyncShaders) o["citra_async_shader_compilation"] = "enabled";
    if (gOpt.cpu == "jit") { o["citra_use_cpu_jit"] = "enabled"; o["citra_use_fastinterp"] = "disabled"; }
    else if (gOpt.cpu == "fastinterp") { o["citra_use_cpu_jit"] = "disabled"; o["citra_use_fastinterp"] = "enabled"; }
    else { o["citra_use_cpu_jit"] = "disabled"; o["citra_use_fastinterp"] = "disabled"; }
    return o;
}
std::map<std::string, std::string> gFixed;

N64VulkanFrontend gVulkan;
retro_hw_render_callback gHW;
bool gHasHW = false;
const retro_hw_render_context_negotiation_interface_vulkan *gNegotiation = nullptr;
std::map<std::string, std::string> gDefaults;
std::map<std::string, std::vector<std::string>> gChoices;
bool gSawVariables = false;
std::vector<std::string> gUnknownKeys;
int gFrame = 0;
bool gShutdown = false;

// Both screens at the 3DS's own size, top over bottom: 400 x 480. Room for
// twice that if a layout or a scale asks for it.
constexpr unsigned kMaxW = 800, kMaxH = 960;
std::vector<uint32_t> gPicture(kMaxW * kMaxH);
unsigned gWidth = 0, gHeight = 0;
bool gNewPicture = false;
std::vector<int16_t> gFrameAudio;
uint64_t gReadNs = 0;

// The calling thread's CPU time: the emulated 3DS CPU runs on this thread
// (retro_run), while lavapipe renders on its own, so this isolates the
// interpreter's cost from the host's software GPU, which the phone does not have.
uint64_t threadNs() {
    timespec t;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

uint64_t nowNs() {
    timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

uint64_t fnv(const void *data, size_t n, uint64_t h = 1469598103934665603ull) {
    const uint8_t *p = (const uint8_t *)data;
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ull; }
    return h;
}

int gFsErrors = 0;

void logCallback(enum retro_log_level level, const char *fmt, ...) {
    // relocate counts what the core says when it cannot reach a save: the
    // archive it fails to open, the folder it fails to create.
    if (level >= RETRO_LOG_ERROR && fmt) {
        char line[512];
        va_list c;
        va_start(c, fmt);
        vsnprintf(line, sizeof line, fmt, c);
        va_end(c);
        if (strstr(line, "failed to get a handle for archive") || strstr(line, "mkdir failed")) gFsErrors++;
    }
    if (level < (getenv("BENCH_LOG_INFO") ? RETRO_LOG_INFO : RETRO_LOG_WARN)) return;
    va_list a;
    va_start(a, fmt);
    fprintf(stderr, "[core] ");
    vfprintf(stderr, fmt, a);
    va_end(a);
}

void recordDefaults(const char *key, const char *value) {
    if (key && value) gDefaults[key] = value;
}

std::vector<retro_memory_descriptor> gMemory;

bool environment(unsigned cmd, void *data) {
    switch (cmd) {
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        auto *v = (retro_variable *)data;
        if (!v || !v->key) return false;
        auto f = gFixed.find(v->key);
        if (f != gFixed.end()) { v->value = f->second.c_str(); return true; }
        auto it = gDefaults.find(v->key);
        if (it == gDefaults.end()) {
            if (std::find(gUnknownKeys.begin(), gUnknownKeys.end(), v->key) == gUnknownKeys.end())
                gUnknownKeys.push_back(v->key);
            return false;
        }
        v->value = it->second.c_str();
        return true;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE: if (data) *(bool *)data = false; return true;
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
        *(const char **)data = gOpt.system.c_str();
        return true;
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: ((retro_log_callback *)data)->log = logCallback; return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: return *(const retro_pixel_format *)data == RETRO_PIXEL_FORMAT_XRGB8888;
    case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER: if (data) *(unsigned *)data = RETRO_HW_CONTEXT_VULKAN; return true;
    case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS: if (data) *(bool *)data = true; return true;
    case RETRO_ENVIRONMENT_GET_CAN_DUPE: if (data) *(bool *)data = true; return true;
    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
        if (gOpt.bridgeOptions) return false;
        if (data) *(unsigned *)data = 2;
        return true;
    case RETRO_ENVIRONMENT_SET_HW_RENDER: {
        auto *cb = (retro_hw_render_callback *)data;
        if (!cb || cb->context_type != RETRO_HW_CONTEXT_VULKAN) return false;
        // Azahar renders offscreen into its own output image, handed over with
        // set_image: no surface, and none of parallel-RDP's storage features.
        N64VulkanFrontend::Requirements req;
        req.parallelRDPStorage = false;
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
    case RETRO_ENVIRONMENT_GET_JIT_CAPABLE: if (data) *(bool *)data = (gOpt.cpu == "jit"); return true;
    case RETRO_ENVIRONMENT_SHUTDOWN: gShutdown = true; return true;
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS:
        if (gOpt.bridgeOptions) return false;
        if (cmd == RETRO_ENVIRONMENT_SET_CORE_OPTIONS) {
            for (auto *d = (const retro_core_option_definition *)data; d && d->key; d++) recordDefaults(d->key, d->default_value);
            return true;
        }
        {
        auto *o = (const retro_core_options_v2 *)data;
        for (auto *d = o ? o->definitions : nullptr; d && d->key; d++) {
            recordDefaults(d->key, d->default_value);
            // BENCH_LIST_OPTIONS=1 prints every option the core declares, with
            // its values, for the bridge's kCoreOptions to be checked against.
            if (getenv("BENCH_LIST_OPTIONS")) {
                fprintf(stderr, "option %s =", d->key);
                for (auto *v = d->values; v->value; v++) fprintf(stderr, " [%s]", v->value);
                fprintf(stderr, " default %s\n", d->default_value ? d->default_value : "-");
            }
        }
        return true;
    }
    case RETRO_ENVIRONMENT_SET_VARIABLES:
        gSawVariables = true;
        for (auto *v = (const retro_variable *)data; v && v->key; v++) {
            if (!v->value) continue;
            const char *list = strstr(v->value, "; ");
            if (!list) continue;
            list += 2;
            const char *end = strchr(list, '|');
            gDefaults[v->key] = end ? std::string(list, (size_t)(end - list)) : std::string(list);
            std::string all = list;
            size_t from = 0;
            for (;;) {
                const size_t bar = all.find('|', from);
                gChoices[v->key].push_back(all.substr(from, bar == std::string::npos ? std::string::npos : bar - from));
                if (bar == std::string::npos) break;
                from = bar + 1;
            }
        }
        return true;
    case RETRO_ENVIRONMENT_SET_MESSAGE: {
        auto *m = (const retro_message *)data;
        if (m && m->msg) fprintf(stderr, "[core message] %s\n", m->msg);
        return true;
    }
    case RETRO_ENVIRONMENT_SET_MESSAGE_EXT: {
        auto *m = (const retro_message_ext *)data;
        if (m && m->msg) fprintf(stderr, "[core message] %s\n", m->msg);
        return true;
    }
    case RETRO_ENVIRONMENT_SET_GEOMETRY:
    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK:
    case RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO:
    case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL:
    case RETRO_ENVIRONMENT_SET_MINIMUM_AUDIO_LATENCY:
    case RETRO_ENVIRONMENT_SET_AUDIO_BUFFER_STATUS_CALLBACK:
    case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS:
        return true;
    case RETRO_ENVIRONMENT_SET_MEMORY_MAPS: {
        // Kept for the cheat mode: the game's heap, where its counter lives.
        const auto *map = (const retro_memory_map *)data;
        gMemory.clear();
        if (map) for (unsigned i = 0; i < map->num_descriptors; i++) gMemory.push_back(map->descriptors[i]);
        return true;
    }
    default:
        return false;
    }
}

void video(const void *data, unsigned w, unsigned h, size_t) {
    if (!data || !w || !h || data != RETRO_HW_FRAME_BUFFER_VALID) return;
    if (w > kMaxW) w = kMaxW;
    if (h > kMaxH) h = kMaxH;
    const uint64_t t = nowNs();
    if (gVulkan.readFrame(w, h, gPicture.data(), kMaxW)) {
        gWidth = w;
        gHeight = h;
        gNewPicture = true;
    }
    gReadNs += nowNs() - t;
}

void audioSample(int16_t l, int16_t r) { gFrameAudio.push_back(l); gFrameAudio.push_back(r); }
size_t audioBatch(const int16_t *d, size_t frames) {
    gFrameAudio.insert(gFrameAudio.end(), d, d + frames * 2);
    return frames;
}
void inputPoll() {}

int16_t heldMask() {
    int16_t m = 0;
    for (auto &p : gOpt.presses) if (gFrame >= p.from && gFrame <= p.to) m |= p.mask;
    return m;
}
const Touch *activeTouch() {
    for (auto &t : gOpt.touches) if (gFrame >= t.from && gFrame <= t.to) return &t;
    return nullptr;
}
// The pointer device in libretro's coordinates (-0x7fff..0x7fff over the whole
// picture). The default layout puts the 320x240 bottom screen centred under the
// 400x240 top one, so its X starts at 40 and its Y at 240 of a 400x480 picture.
int16_t toPointer(int v, int extent) { return (int16_t)((v * 2 + 1) * 0x7fff / extent - 0x7fff); }
int16_t inputState(unsigned port, unsigned device, unsigned, unsigned id) {
    if (port != 0) return 0;
    if (device == RETRO_DEVICE_JOYPAD) {
        const int16_t m = heldMask();
        if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return m;
        return (m >> id) & 1;
    }
    if (device == RETRO_DEVICE_POINTER) {
        const Touch *t = activeTouch();
        if (!t) return 0;
        if (id == RETRO_DEVICE_ID_POINTER_PRESSED) return 1;
        if (id == RETRO_DEVICE_ID_POINTER_X) return toPointer(40 + t->x, 400);
        if (id == RETRO_DEVICE_ID_POINTER_Y) return toPointer(240 + t->y, 480);
    }
    return 0;
}

Options parse(int argc, char **argv) {
    if (argc < 3) die("usage: 3ds-bench <hash|bench|roundtrip|reload|stateformat> <program> --system DIR [--cpu fastinterp|dyncom|jit] [--clock N] [--frames N] [--warmup N] [--out FILE] [--shot N] [--press MASK@A-B] [--touch X,Y@A-B] [--async-shaders] [--rt-at N] [--rt-len M] [--dump-state FILE]");
    Options o;
    o.mode = argv[1];
    o.rom = argv[2];
    for (int i = 3; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> std::string { if (i + 1 >= argc) die("missing value"); return argv[++i]; };
        if (a == "--frames") o.frames = atoi(next().c_str());
        else if (a == "--warmup") o.warmup = atoi(next().c_str());
        else if (a == "--out") o.out = next();
        else if (a == "--system") o.system = next();
        else if (a == "--cpu") o.cpu = next();
        else if (a == "--clock") o.clock = atoi(next().c_str());
        else if (a == "--shot") o.shot = atoi(next().c_str());
        else if (a == "--rt-at") o.rtAt = atoi(next().c_str());
        else if (a == "--rt-len") o.rtLen = atoi(next().c_str());
        else if (a == "--press") {
            Press p{};
            int mask = 0;
            if (sscanf(next().c_str(), "%i@%d-%d", &mask, &p.from, &p.to) != 3) die("--press MASK@A-B");
            p.mask = (int16_t)mask;
            o.presses.push_back(p);
        } else if (a == "--touch") {
            Touch t{};
            if (sscanf(next().c_str(), "%d,%d@%d-%d", &t.x, &t.y, &t.from, &t.to) != 4) die("--touch X,Y@A-B");
            o.touches.push_back(t);
        } else if (a == "--dump-state") {
            o.dumpState = next();
        } else if (a == "--load-state") {
            o.loadState = next();
        } else if (a == "--async-shaders") {
            o.asyncShaders = true;
        } else if (a == "--bridge-options") {
            o.bridgeOptions = true;
            o.bridgeLanguage = next();
        } else die(("unknown option " + a).c_str());
    }
    if (o.mode != "hash" && o.mode != "bench" && o.mode != "roundtrip" && o.mode != "reload"
        && o.mode != "resume"
        && o.mode != "stateformat" && o.mode != "relocate" && o.mode != "cheat" && o.mode != "rewind" && o.mode != "rewindbridge")
        die("mode is hash, bench, roundtrip, reload, stateformat, relocate, cheat, rewind or rewindbridge");
    if (o.mode == "relocate" && o.loadState.empty()) die("relocate needs --load-state FILE");
    if (o.mode == "resume" && o.loadState.empty()) die("resume needs --load-state FILE");
    if (o.system.empty()) die("--system DIR is required");
    if (o.cpu != "fastinterp" && o.cpu != "dyncom" && o.cpu != "jit") die("--cpu is fastinterp, dyncom or jit");
    if (o.clock < 5 || o.clock > 400) die("--clock is 5 to 400");
    return o;
}

void writeShot() {
    const std::string name = (gOpt.out.empty() ? std::string("shot") : gOpt.out) + "." + std::to_string(gFrame) + ".ppm";
    FILE *p = fopen(name.c_str(), "wb");
    if (!p) return;
    fprintf(p, "P6\n%u %u\n255\n", gWidth, gHeight);
    for (unsigned y = 0; y < gHeight; y++)
        for (unsigned x = 0; x < gWidth; x++) {
            // The frontend writes R, G, B, A bytes (N64VulkanFrontend.h).
            const uint8_t *px = (const uint8_t *)&gPicture[(size_t)y * kMaxW + x];
            fwrite(px, 1, 3, p);
        }
    fclose(p);
    fprintf(stderr, "3ds-bench: wrote %s (%ux%u)\n", name.c_str(), gWidth, gHeight);
}

/// One frame, timed; its line goes to `out` when given. Returns the frame's ns.
uint64_t step(FILE *out) {
    if (gShutdown) die("the core asked to shut down; not calling retro_run again");
    gFrameAudio.clear();
    gNewPicture = false;
    const uint64_t t0 = nowNs();
    gVulkan.beginFrame();
    retro_run();
    const uint64_t ns = nowNs() - t0;
    if (out) {
        uint64_t h = 1469598103934665603ull;
        // The colour the player sees: R, G, B of each pixel, never the alpha.
        if (gNewPicture) for (unsigned y = 0; y < gHeight; y++)
            for (unsigned x = 0; x < gWidth; x++) h = fnv(&gPicture[(size_t)y * kMaxW + x], 3, h);
        fprintf(out, "%d %ux%u %016llx %016llx %zu\n", gFrame,
                gNewPicture ? gWidth : 0, gNewPicture ? gHeight : 0,
                gNewPicture ? (unsigned long long)h : 0ull,
                (unsigned long long)fnv(gFrameAudio.data(), gFrameAudio.size() * 2),
                gFrameAudio.size() / 2);
    }
    if (gFrame == gOpt.shot && gNewPicture) writeShot();
    gFrame++;
    return ns;
}

double percentile(std::vector<uint64_t> v, double p) {
    if (v.empty()) return 0;
    std::sort(v.begin(), v.end());
    const size_t i = std::min(v.size() - 1, (size_t)(p * (v.size() - 1) + 0.5));
    return v[i] / 1e6;
}

void runBench() {
    std::vector<uint64_t> times, thread;
    uint64_t readAtWarmup = 0;
    const uint64_t wall0 = nowNs();
    for (int i = 0; i < gOpt.frames; i++) {
        if (gFrame == gOpt.warmup) readAtWarmup = gReadNs;
        const uint64_t c0 = threadNs();
        const uint64_t ns = step(nullptr);
        const uint64_t c = threadNs() - c0;
        if (gFrame > gOpt.warmup) { times.push_back(ns); thread.push_back(c); }
        // The stops a player feels: every measured frame over 50 ms, by number.
        if (gFrame > gOpt.warmup && ns > 50000000ull)
            printf("slow frame %d: %.1f ms (emulation thread CPU %.1f ms)\n", gFrame, ns / 1e6, c / 1e6);
    }
    const double wall = (nowNs() - wall0) / 1e9;
    double sum = 0;
    for (auto t : times) sum += t / 1e6;
    const double mean = times.empty() ? 0 : sum / times.size();
    printf("cpu=%s clock=%d%% frames=%d (measured %zu after %d warmup) wall=%.1fs\n",
           gOpt.cpu.c_str(), gOpt.clock, gOpt.frames, times.size(), gOpt.warmup, wall);
    printf("frame ms: mean %.2f  p50 %.2f  p90 %.2f  p99 %.2f  max %.2f   (60 fps budget 16.67)\n",
           mean, percentile(times, 0.5), percentile(times, 0.9), percentile(times, 0.99), percentile(times, 1.0));
    printf("speed if this machine were the phone: %.0f%% of a real 3DS\n", mean > 0 ? 16.6667 / mean * 100 : 0);
    double tsum = 0;
    for (auto t : thread) tsum += t / 1e6;
    const double tmean = thread.empty() ? 0 : tsum / thread.size();
    printf("emulation thread CPU ms (the 3DS CPU and the core's own work, not lavapipe's threads): mean %.2f  p50 %.2f  p99 %.2f\n",
           tmean, percentile(thread, 0.5), percentile(thread, 0.99));
    printf("readback ms per measured frame: %.3f\n", times.empty() ? 0 : (gReadNs - readAtWarmup) / 1e6 / times.size());
}

void runHash() {
    FILE *out = gOpt.out.empty() ? stdout : fopen(gOpt.out.c_str(), "w");
    if (!out) die("cannot write --out");
    for (int i = 0; i < gOpt.frames; i++) step(out);
    if (out != stdout) fclose(out);
}

void runRoundtrip() {
    while (gFrame < gOpt.rtAt) step(nullptr);
    gVulkan.beginFrame();
    const size_t size = retro_serialize_size();
    if (!size) die("retro_serialize_size returned 0");
    std::vector<uint8_t> state(size);
    gVulkan.beginFrame();
    if (!retro_serialize(state.data(), size)) die("retro_serialize failed");
    printf("state: %zu bytes (%.1f MB) at frame %d\n", size, size / 1048576.0, gFrame);
    // --dump-state FILE: the core's state as it is, for measuring what it
    // holds (its zstd frame states the uncompressed size).
    if (!gOpt.dumpState.empty()) {
        FILE *d = fopen(gOpt.dumpState.c_str(), "wb");
        if (!d || fwrite(state.data(), 1, size, d) != size) die("--dump-state: cannot write");
        fclose(d);
    }
    const int at = gFrame;
    char *a = nullptr, *b = nullptr; size_t al = 0, bl = 0;
    FILE *fa = open_memstream(&a, &al);
    for (int i = 0; i < gOpt.rtLen; i++) step(fa);
    fclose(fa);
    gVulkan.beginFrame();
    const uint64_t load0 = nowNs();
    if (!retro_unserialize(state.data(), size)) die("retro_unserialize failed");
    printf("state load: %.0f ms\n", (nowNs() - load0) / 1e6);
    gFrame = at;
    FILE *fb = open_memstream(&b, &bl);
    for (int i = 0; i < gOpt.rtLen; i++) step(fb);
    fclose(fb);
    const bool same = al == bl && !memcmp(a, b, al);
    printf("roundtrip over %d frames: %s\n", gOpt.rtLen, same ? "IDENTICAL (picture and sound)" : "DIFFERENT");
    if (!same) {
        // Per column, how many of the frames differ: a picture that differs
        // while the sound is identical is a presentation difference (the
        // first frames after a load are redrawn from a rebuilt renderer); a
        // sound that differs is the game's state.
        int lines = 0, picDiff = 0, sndDiff = 0, lastPicDiff = -1;
        for (char *pa = a, *pb = b; *pa && *pb; lines++) {
            char *ea = strchr(pa, '\n'), *eb = strchr(pb, '\n');
            if (!ea || !eb) break;
            char fa[5][40] = {}, fb[5][40] = {};
            sscanf(pa, "%39s %39s %39s %39s %39s", fa[0], fa[1], fa[2], fa[3], fa[4]);
            sscanf(pb, "%39s %39s %39s %39s %39s", fb[0], fb[1], fb[2], fb[3], fb[4]);
            if (strcmp(fa[2], fb[2])) { picDiff++; lastPicDiff = atoi(fa[0]); }
            if (strcmp(fa[3], fb[3]) || strcmp(fa[4], fb[4])) sndDiff++;
            pa = ea + 1; pb = eb + 1;
        }
        printf("  of %d frames: picture differs in %d (last at frame %d), sound in %d\n",
               lines, picDiff, lastPicDiff, sndDiff);
        // The first line that differs, to see whether picture or sound moved.
        char *pa = a, *pb = b;
        while (*pa && *pb) {
            char *ea = strchr(pa, '\n'), *eb = strchr(pb, '\n');
            if (!ea || !eb) break;
            if ((ea - pa) != (eb - pb) || memcmp(pa, pb, (size_t)(ea - pa))) {
                printf("  A: %.*s\n  B: %.*s\n", (int)(ea - pa), pa, (int)(eb - pb), pb);
                break;
            }
            pa = ea + 1; pb = eb + 1;
        }
    }
    free(a); free(b);
}

/// What a bridge does to start a game: the callbacks, retro_init, the load,
/// the Vulkan device through the core's negotiation, context_reset.
void startGame() {
    gHasHW = false;
    gNegotiation = nullptr;
    gShutdown = false;
    retro_set_environment(environment);
    retro_set_video_refresh(video);
    retro_set_audio_sample(audioSample);
    retro_set_audio_sample_batch(audioBatch);
    retro_set_input_poll(inputPoll);
    retro_set_input_state(inputState);
    retro_init();

    retro_game_info info{};
    info.path = gOpt.rom.c_str();
    if (!retro_load_game(&info)) die("retro_load_game refused the program");
    if (gOpt.bridgeOptions) {
        if (!gSawVariables) die("bridge options: the core never fell back to SET_VARIABLES");
        int bad = 0;
        for (auto &kv : gFixed) {
            auto it = gChoices.find(kv.first);
            if (it == gChoices.end()) { fprintf(stderr, "bridge option %s: NOT DECLARED by the core\n", kv.first.c_str()); bad++; continue; }
            if (std::find(it->second.begin(), it->second.end(), kv.second) == it->second.end()) {
                fprintf(stderr, "bridge option %s=%s: NOT A VALUE the core offers\n", kv.first.c_str(), kv.second.c_str()); bad++;
            }
        }
        if (bad) die("bridge options rejected");
        fprintf(stderr, "3ds-bench: bridge options: %zu overrides, every one declared with that value (SET_VARIABLES)\n", gFixed.size());
    }
    if (!gHasHW || !gNegotiation) die("the core did not ask for Vulkan hardware rendering");
    if (!gVulkan.createDevice(gNegotiation, kMaxW, kMaxH)) die("device creation failed");
    gHW.context_reset();
}

/// What a bridge does when the player leaves the game (PSPBridge unloadGame,
/// then shutdown): the queue drained, context_destroy, retro_unload_game, the
/// frontend destroyed, retro_deinit.
void endGame() {
    gVulkan.drainQueue();
    gHW.context_destroy();
    retro_unload_game();
    gVulkan.destroy();
    retro_deinit();
}

int runStateFormat() {
    while (gFrame < gOpt.rtAt) step(nullptr);
    gVulkan.beginFrame();
    const auto t0 = std::chrono::steady_clock::now();
    const size_t size = retro_serialize_size();
    if (!size) die("retro_serialize_size returned 0");
    std::vector<uint8_t> state(size);
    if (!retro_serialize(state.data(), size)) die("retro_serialize failed");
    const auto t1 = std::chrono::steady_clock::now();
    std::vector<uint8_t> file, back;
    if (!CTRStateFormatPack(state.data(), state.size(), file)) die("CTRStateFormatPack refused the core's own state");
    const auto t2 = std::chrono::steady_clock::now();
    printf("state %zu bytes -> file %zu bytes (%s)\n", state.size(), file.size(),
           file.size() < state.size() ? "packed" : "stored as it is");
    // What a save costs the app (CTRBridge.saveStateToPath): the core's state, then the file.
    printf("save cost: core state %.0f ms, file format %.0f ms\n",
           std::chrono::duration<double, std::milli>(t1 - t0).count(),
           std::chrono::duration<double, std::milli>(t2 - t1).count());
    if (!CTRStateFormatUnpack(file.data(), file.size(), back) || back != state) die("unpack did not give the state back");
    printf("unpacked: identical, byte for byte\n");
    std::vector<uint8_t> damaged = file;
    damaged[damaged.size() / 2] ^= 0x40;
    std::vector<uint8_t> refused;
    printf("damaged copy: %s\n", CTRStateFormatUnpack(damaged.data(), damaged.size(), refused) ? "ACCEPTED (bad)" : "refused");
    std::vector<uint8_t> truncated(file.begin(), file.begin() + (long)file.size() / 2);
    printf("truncated copy: %s\n", CTRStateFormatUnpack(truncated.data(), truncated.size(), refused) ? "ACCEPTED (bad)" : "refused");
    for (int i = 0; i < 120; i++) step(nullptr);
    gVulkan.beginFrame();
    if (!retro_unserialize(back.data(), back.size())) die("the core refused the unpacked state");
    for (int i = 0; i < 300; i++) step(nullptr);
    printf("loaded back into the core and ran 300 frames on\n");
    endGame();
    return 0;
}

int runRelocate() {
    FILE *f = fopen(gOpt.loadState.c_str(), "rb");
    if (!f) die("--load-state: cannot read");
    std::vector<uint8_t> state;
    uint8_t buf[1 << 16];
    for (size_t n; (n = fread(buf, 1, sizeof buf, f)) > 0;) state.insert(state.end(), buf, buf + n);
    fclose(f);
    while (gFrame < 60) step(nullptr);
    gVulkan.beginFrame();
    if (!retro_unserialize(state.data(), state.size())) die("the core refused --load-state");
    gFsErrors = 0;
    for (int i = 0; i < gOpt.frames; i++) step(nullptr);
    if (!gOpt.dumpState.empty()) {
        gVulkan.beginFrame();
        const size_t size = retro_serialize_size();
        std::vector<uint8_t> again(size);
        if (!size || !retro_serialize(again.data(), size)) die("retro_serialize failed");
        FILE *d = fopen(gOpt.dumpState.c_str(), "wb");
        if (!d || fwrite(again.data(), 1, size, d) != size) die("--dump-state: cannot write");
        fclose(d);
    }
    printf("relocate: loaded a %zu-byte state, ran %d frames, %d file-system errors\n",
           state.size(), gOpt.frames, gFsErrors);
    endGame();
    return gFsErrors == 0 ? 0 : 1;
}

/// A resume as the app does it (EmulatorViewController.loadAndStart): the game
/// booted, one frame run (EmulatorSession.loadROM), the state loaded, then played. Reports how
/// long the load took and whether the core took it.
int runResume() {
    FILE *f = fopen(gOpt.loadState.c_str(), "rb");
    if (!f) die("--load-state: cannot read");
    std::vector<uint8_t> state;
    uint8_t buf[1 << 16];
    for (size_t n; (n = fread(buf, 1, sizeof buf, f)) > 0;) state.insert(state.end(), buf, buf + n);
    fclose(f);
    // The app runs one frame between the boot and the load (EmulatorSession.loadROM).
    step(nullptr);
    gVulkan.beginFrame();
    const auto t0 = std::chrono::steady_clock::now();
    const bool ok = retro_unserialize(state.data(), state.size());
    const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    printf("resume: load after the boot and one frame %s in %.0f ms\n", ok ? "TAKEN" : "REFUSED", ms);
    for (int i = 0; i < gOpt.frames; i++) step(nullptr);
    endGame();
    return ok ? 0 : 1;
}

/// Cheats through retro_cheat_set / retro_cheat_reset (patch 0011), counted:
/// a Gateway code that adds 1 to a word of the game's heap each time the
/// engine runs it (D9 load, D4 add, D6 store). The engine runs every 50 M
/// ARM11 ticks, about 5.4 times a second; each count below is over the same
/// number of frames, so a state load that doubled the engine's event would
/// double the count after it.
int runCheat() {
    while (gFrame < 120) step(nullptr);
    // The core maps what the process has at load: on a homebrew that is the
    // main thread's stack (0x0FFFC000, 16 KiB, flagged SYSTEM_RAM), not yet a
    // heap. The counter is the stack's LOWEST word, the deepest a call chain
    // would ever reach: a game write there would show as a count that is not
    // a multiple of the runs, which none of the runs below showed.
    const retro_memory_descriptor *ram = nullptr;
    for (auto &d : gMemory)
        if ((d.flags & RETRO_MEMDESC_SYSTEM_RAM) && d.ptr && d.len >= 8) { ram = &d; break; }
    if (!ram) die("cheat: no system RAM in the memory maps");
    const uint32_t addr = (uint32_t)ram->start;
    auto counter = [&]() -> uint32_t & { return *(uint32_t *)ram->ptr; };
    printf("cheat: counter at 0x%08X (region of 0x%llx bytes)\n", addr, (unsigned long long)ram->len);
    char code[160];
    snprintf(code, sizeof code, "D9000000 %08X\nD4000000 00000001\nD6000000 %08X\nD2000000 00000000", addr, addr);
    const int span = gOpt.frames;
    auto run = [&](const char *what) {
        counter() = 0;
        for (int i = 0; i < span; i++) step(nullptr);
        printf("cheat: %-34s %u runs in %d frames\n", what, counter(), span);
        return counter();
    };
    retro_cheat_set(0, true, "not a code");
    const uint32_t refused = run("an invalid code only");
    retro_cheat_reset();
    retro_cheat_set(0, true, code);
    const uint32_t first = run("after retro_cheat_set");
    gVulkan.beginFrame();
    const size_t size = retro_serialize_size();
    std::vector<uint8_t> state(size);
    if (!size || !retro_serialize(state.data(), size)) die("retro_serialize failed");
    uint32_t loads[3];
    for (int i = 0; i < 3; i++) {
        gVulkan.beginFrame();
        if (!retro_unserialize(state.data(), state.size())) die("retro_unserialize failed");
        char what[40]; snprintf(what, sizeof what, "after state load %d", i + 1);
        loads[i] = run(what);
    }
    retro_cheat_reset();
    const uint32_t cleared = run("after retro_cheat_reset");
    endGame();
    const bool ok = refused == 0 && first > 0 && cleared == 0
        && loads[2] <= first + first / 4 && loads[2] + first / 4 >= first;
    printf("cheat: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

/// The rewind's snapshot as CTRBridge takes it: the state without the four
/// emulated memories (patch 0015), and a copy of the memories kept here.
struct RewindSnapshot {
    std::vector<uint8_t> state;
    std::vector<uint8_t> memory[4];
};

/// Takes a snapshot; returns the milliseconds spent in the core (on the
/// emulation thread) and, separately, copying the memories (which the bridge
/// does on a worker, against its previous copy).
static void takeSnapshot(RewindSnapshot &snap, double &coreMs, double &copyMs, size_t *changedBlocks) {
    RetroCtrRegion regions[4];
    gVulkan.beginFrame();
    uint64_t t0 = nowNs();
    if (!retro_ctr_rewind_capture(&snap.state, true, regions)) die("retro_ctr_rewind_capture failed");
    coreMs = (nowNs() - t0) / 1e6;
    t0 = nowNs();
    size_t changed = 0;
    for (int i = 0; i < 4; i++) {
        auto &copy = snap.memory[i];
        const uint8_t *live = (const uint8_t *)regions[i].data;
        if (copy.size() != regions[i].size) { copy.assign(live, live + regions[i].size); changed += regions[i].size / 4096; continue; }
        for (size_t off = 0; off < copy.size(); off += 4096) {
            const size_t len = std::min<size_t>(4096, copy.size() - off);
            if (memcmp(copy.data() + off, live + off, len)) { memcpy(copy.data() + off, live + off, len); changed++; }
        }
    }
    copyMs = (nowNs() - t0) / 1e6;
    if (changedBlocks) *changedBlocks = changed;
}

static double restoreSnapshot(const RewindSnapshot &snap) {
    RetroCtrRegion regions[4];
    gVulkan.beginFrame();
    const uint64_t t0 = nowNs();
    if (!retro_ctr_rewind_restore(snap.state.data(), snap.state.size(), true, regions))
        die("retro_ctr_rewind_restore failed");
    for (int i = 0; i < 4; i++) {
        if (regions[i].size != snap.memory[i].size()) die("rewind: a memory changed size across the restore");
        memcpy(regions[i].data, snap.memory[i].data(), regions[i].size);
    }
    return (nowNs() - t0) / 1e6;
}

/// The rewind as CTRBridge does it, measured and checked. Every --rt-len frames
/// from --rt-at a snapshot is taken (the core's part timed apart from the
/// memory copy). Then a snapshot and a full compressed state taken at the same
/// frame are each restored and played --rt-len frames: the two must give the
/// same picture and sound (a rewind is a state load, no less).
int runRewindCost() {
    while (gFrame < gOpt.rtAt) step(nullptr);
    RewindSnapshot snap;
    double coreMax = 0, coreSum = 0, copyMax = 0, copySum = 0; int n = 0;
    while (gFrame < gOpt.rtAt + gOpt.frames) {
        double core, copy; size_t changed;
        takeSnapshot(snap, core, copy, &changed);
        printf("rewind: frame %d: state %.1f MB in %.1f ms (core), memories %.1f ms, %zu blocks changed\n",
               gFrame, snap.state.size() / 1048576.0, core, copy, changed);
        if (n > 0) { coreMax = std::max(coreMax, core); coreSum += core; copyMax = std::max(copyMax, copy); copySum += copy; }
        n++;
        for (int i = 0; i < gOpt.rtLen; i++) step(nullptr);
    }
    // The same moment, two ways.
    double core, copy;
    takeSnapshot(snap, core, copy, nullptr);
    gVulkan.beginFrame();
    const size_t size = retro_serialize_size();
    std::vector<uint8_t> full(size);
    if (!size || !retro_serialize(full.data(), size)) die("retro_serialize failed");
    const int at = gFrame;
    for (int i = 0; i < 120; i++) step(nullptr);   // move away first
    double restoreMax = 0, restoreSum = 0;
    char *a = nullptr, *b = nullptr; size_t al = 0, bl = 0;
    for (int round = 0; round < 3; round++) {
        const double ms = restoreSnapshot(snap);
        restoreMax = std::max(restoreMax, ms); restoreSum += ms;
        gFrame = at;
        if (round == 0) {
            FILE *fa = open_memstream(&a, &al);
            for (int i = 0; i < gOpt.rtLen; i++) step(fa);
            fclose(fa);
        } else {
            for (int i = 0; i < 60; i++) step(nullptr);
        }
    }
    gVulkan.beginFrame();
    if (!retro_unserialize(full.data(), full.size())) die("retro_unserialize failed");
    gFrame = at;
    FILE *fb = open_memstream(&b, &bl);
    for (int i = 0; i < gOpt.rtLen; i++) step(fb);
    fclose(fb);
    int lines = 0, pic = 0, snd = 0;
    for (char *pa = a, *pb = b; *pa && *pb; lines++) {
        char *ea = strchr(pa, '\n'), *eb = strchr(pb, '\n');
        if (!ea || !eb) break;
        char fa[5][40] = {}, fbv[5][40] = {};
        sscanf(pa, "%39s %39s %39s %39s %39s", fa[0], fa[1], fa[2], fa[3], fa[4]);
        sscanf(pb, "%39s %39s %39s %39s %39s", fbv[0], fbv[1], fbv[2], fbv[3], fbv[4]);
        if (strcmp(fa[2], fbv[2])) pic++;
        if (strcmp(fa[3], fbv[3]) || strcmp(fa[4], fbv[4])) snd++;
        pa = ea + 1; pb = eb + 1;
    }
    printf("rewind: %d snapshots; core part mean %.1f max %.1f ms; memories mean %.1f max %.1f ms; "
           "restore mean %.0f max %.0f ms\n", n - 1, coreSum / std::max(1, n - 1), coreMax,
           copySum / std::max(1, n - 1), copyMax, restoreSum / 3, restoreMax);
    printf("rewind: restored snapshot vs restored full state over %d frames: picture differs in %d, sound in %d\n",
           lines, pic, snd);
    // --out FILE: both runs' frame lines, to compare one core build with another.
    if (!gOpt.out.empty()) {
        FILE *f = fopen((gOpt.out + ".snapshot.txt").c_str(), "w"); if (f) { fputs(a, f); fclose(f); }
        f = fopen((gOpt.out + ".full.txt").c_str(), "w"); if (f) { fputs(b, f); fclose(f); }
    }
    free(a); free(b);
    endGame();
    return snd == 0 ? 0 : 1;
}

/// CTRBridge's rewind, its own recording and applying (CTRRewindData.inc, cut
/// from the bridge): a snapshot every --rt-len frames from --rt-at, each also
/// taken as an ordinary full state. Then the rewind goes back 1 step, and from
/// there 2 more, and each time the console restored that way must play on
/// exactly as the full state of that same moment restored the ordinary way.
int runRewindBridge() {
    std::vector<uint8_t> state, nextState, memory[4];
    std::vector<CTRRewindStep> steps;
    std::vector<std::vector<uint8_t>> fulls;   // the full state of each snapshot
    auto parallelFor = [](size_t n, const std::function<void(size_t)> &body) {
        for (size_t i = 0; i < n; i++) body(i);
    };
    auto capture = [&](std::vector<uint8_t> &target, RetroCtrRegion regions[4]) {
        gVulkan.beginFrame();
        if (!retro_ctr_rewind_capture(&target, true, regions)) die("capture failed");
        const size_t size = retro_serialize_size();
        std::vector<uint8_t> full(size);
        if (!size || !retro_serialize(full.data(), size)) die("retro_serialize failed");
        fulls.push_back(std::move(full));
    };
    while (gFrame < gOpt.rtAt) step(nullptr);
    RetroCtrRegion regions[4];
    capture(state, regions);
    for (int i = 0; i < 4; i++) {
        const uint8_t *b = (const uint8_t *)regions[i].data;
        memory[i].assign(b, b + regions[i].size);
    }
    const int snapshots = gOpt.frames / gOpt.rtLen;
    for (int n = 0; n < snapshots; n++) {
        for (int i = 0; i < gOpt.rtLen; i++) step(nullptr);
        capture(nextState, regions);
        void *live[4]; size_t sizes[4];
        for (int i = 0; i < 4; i++) { live[i] = regions[i].data; sizes[i] = regions[i].size; }
        std::vector<std::vector<uint8_t>> records;
        if (!CTRRewindRecordMemories(live, sizes, memory, records, parallelFor)) die("record failed");
        CTRRewindStep st;
        if (!CTRRewindBuildStep(state, nextState, records, COMPRESSION_LZ4, st)) die("build failed");
        printf("rewindbridge: step %d: %.2f MB raw, %.2f MB packed\n", n + 1, st.rawLength / 1048576.0,
               st.packedLength / 1048576.0);
        steps.push_back(st);
        state.swap(nextState);
    }
    // Back, and compare with the ordinary full state of the same moment.
    auto play = [&](std::string &out) {
        char *buf = nullptr; size_t len = 0;
        FILE *f = open_memstream(&buf, &len);
        for (int i = 0; i < gOpt.rtLen; i++) step(f);
        fclose(f);
        // drop the frame numbers: the two runs start from the same moment
        out.clear();
        for (char *p = buf; *p;) { char *e = strchr(p, '\n'); if (!e) break; char *sp = strchr(p, ' ');
            out.append(sp ? sp : p, e - (sp ? sp : p) + 1); p = e + 1; }
        free(buf);
    };
    int failures = 0;
    for (int back : {1, 2}) {
        for (int k = 0; k < back; k++) {
            if (!CTRRewindApplyStep(steps.back(), COMPRESSION_LZ4, state, memory)) die("apply failed");
            CTRRewindFreeStep(steps.back());
            steps.pop_back();
        }
        const size_t at = steps.size();          // the snapshot the anchor now is
        gVulkan.beginFrame();
        if (!retro_ctr_rewind_restore(state.data(), state.size(), true, regions)) die("restore failed");
        for (int i = 0; i < 4; i++) memcpy(regions[i].data, memory[i].data(), regions[i].size);
        std::string viaRewind, viaFull;
        play(viaRewind);
        gVulkan.beginFrame();
        if (!retro_unserialize(fulls[at].data(), fulls[at].size())) die("retro_unserialize failed");
        play(viaFull);
        // after the full-state run the console is elsewhere: bring it back to
        // the anchor for the next round, the rewind's way.
        gVulkan.beginFrame();
        if (!retro_ctr_rewind_restore(state.data(), state.size(), true, regions)) die("restore failed");
        for (int i = 0; i < 4; i++) memcpy(regions[i].data, memory[i].data(), regions[i].size);
        int lines = 0, pic = 0, snd = 0;
        for (const char *a = viaRewind.c_str(), *b = viaFull.c_str(); *a && *b; lines++) {
            const char *ea = strchr(a, '\n'), *eb = strchr(b, '\n');
            char fa[4][40] = {}, fb[4][40] = {};
            sscanf(a, "%39s %39s %39s %39s", fa[0], fa[1], fa[2], fa[3]);
            sscanf(b, "%39s %39s %39s %39s", fb[0], fb[1], fb[2], fb[3]);
            if (strcmp(fa[1], fb[1])) pic++;
            if (strcmp(fa[2], fb[2]) || strcmp(fa[3], fb[3])) snd++;
            a = ea + 1; b = eb + 1;
        }
        printf("rewindbridge: back to snapshot %zu: vs its full state over %d frames, picture differs in %d, sound in %d\n",
               at, lines, pic, snd);
        if (snd) failures++;
    }
    for (auto &st : steps) CTRRewindFreeStep(st);
    endGame();
    printf("rewindbridge: %s\n", failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}

int runReload() {
    char *a = nullptr, *b = nullptr; size_t al = 0, bl = 0;
    FILE *fa = open_memstream(&a, &al);
    for (int i = 0; i < gOpt.frames; i++) step(fa);
    fclose(fa);
    endGame();
    gFrame = 0;
    startGame();
    // The second half's shot, apart from the first's.
    if (!gOpt.out.empty()) gOpt.out += ".again";
    FILE *fb = open_memstream(&b, &bl);
    for (int i = 0; i < gOpt.frames; i++) step(fb);
    fclose(fb);
    int lines = 0, same = 0, firstDiff = -1;
    for (char *pa = a, *pb = b; *pa && *pb; lines++) {
        char *ea = strchr(pa, '\n'), *eb = strchr(pb, '\n');
        if (!ea || !eb) break;
        if ((ea - pa) == (eb - pb) && !memcmp(pa, pb, (size_t)(ea - pa))) same++;
        else if (firstDiff < 0) {
            firstDiff = lines;
            printf("  first %.*s\n  again %.*s\n", (int)(ea - pa), pa, (int)(eb - pb), pb);
        }
        pa = ea + 1; pb = eb + 1;
    }
    // Not expected to be all identical: the 3DS clock is the host's time at
    // boot (the libretro core has no clock option), so the second boot starts
    // later and anything a game draws from the clock moves. Measured
    // 2026-10-16 with Craftus Reloaded, 2400 frames with movement: from frame
    // 18 the pictures differ by 29 pixels of 192 000, all in the drifting
    // clouds of the top screen; world, HUD and bottom screen identical, sound
    // identical. A leak between games would move the camera or the terrain.
    // Read the --shot pictures of both halves (FILE.N.ppm, FILE.again.N.ppm).
    printf("reload: %d of %d frames identical on the second load", same, lines);
    if (firstDiff >= 0) printf(", first difference at frame %d", firstDiff);
    printf("\n");
    free(a); free(b);
    endGame();
    return same == lines && lines == gOpt.frames ? 0 : 1;
}

}  // namespace

int main(int argc, char **argv) {
    gOpt = parse(argc, argv);
    // The core makes <system>/Azahar but not <system> itself, and when it
    // cannot it falls back SILENTLY to the user's home (~/.local/share/
    // azahar-emu on Linux; on iOS, outside what the app controls). Seen on the
    // host 2026-10-16. The bridge must create the directory first, as here.
    if (mkdir(gOpt.system.c_str(), 0755) != 0 && errno != EEXIST) die("cannot create --system DIR");
    gClock = std::to_string(gOpt.clock);
    gFixed = fixedOptions();

    startGame();
    if (gOpt.mode == "bench") runBench();
    else if (gOpt.mode == "hash") runHash();
    else if (gOpt.mode == "roundtrip") runRoundtrip();
    else if (gOpt.mode == "stateformat") return runStateFormat();
    else if (gOpt.mode == "relocate") return runRelocate();
    else if (gOpt.mode == "cheat") return runCheat();
    else if (gOpt.mode == "rewind") return runRewindCost();
    else if (gOpt.mode == "rewindbridge") return runRewindBridge();
    else if (gOpt.mode == "resume") return runResume();
    else return runReload();

    if (!gUnknownKeys.empty()) {
        fprintf(stderr, "3ds-bench: options the core asked for that nothing answered:");
        for (auto &k : gUnknownKeys) fprintf(stderr, " %s", k.c_str());
        fprintf(stderr, "\n");
    }
    endGame();
    return 0;
}
