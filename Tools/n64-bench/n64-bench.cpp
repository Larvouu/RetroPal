// Host harness for the Nintendo 64 core as Retro Pal builds it: the same core
// and patches (Vendor/n64-ios), the same core options as N64Bridge.mm, and the
// app's own Vulkan frontend (N64VulkanFrontend.mm, compiled unchanged but for
// its log line, see build.sh), driven in the bridge's order: beginFrame, then
// retro_run, whose video callback reads the picture back.
//
// It exists so that a change to the N64 core, a build flag or the frontend is
// PROVEN here before it reaches a phone, the way Tools/nds-bench is for the DS:
//
//   hash    run N frames and print one line per frame: the picture's size and a
//           hash of it, a hash of the sound the frame produced, and its sample
//           count. Two builds whose hash files are identical produced the same
//           picture and the same sound on every frame: the zero-regression gate
//           for a change meant to be invisible (speed, flags, threading).
//   bench   the same run, timed, and the sound counted. Host timings on
//           lavapipe (Mesa's CPU Vulkan), so only the RATIO between two builds
//           means anything, and only for the emulation thread's own CPU time
//           ("cpu" below): the "gpu" waits time lavapipe, not a phone's GPU.
//           The phone's pause-menu line and the bridge's DEBUG split are the
//           numbers that count.
//
// Usage: n64-bench <hash|bench> <rom.z64> [options]
//   --frames N          frames to run (default 1800)
//   --out FILE          hash: write the lines there instead of stdout
//   --press MASK@A-B    hold a libretro RetroPad mask on port 1 from frame A to
//                       frame B (repeatable), to drive a game past its menus
//   --save-to FILE      after the run, write a save state there with
//                       retro_serialize, exactly what N64Bridge writes
//   --load FILE         before the run, load that state (after one frame, as
//                       the app does), so a run can start from a saved moment
//   --snapshot-every N  ask for an in-frame snapshot (patch 0008) every N
//                       frames, as the rewind does, and throw it away: the
//                       hashes must not change because of it
//
// Paths are arguments on purpose: the games used to measure are the owner's
// own and never enter the repository.

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

extern "C" {
RETRO_API bool retro_serialize_in_frame(void *data, size_t size);
RETRO_API int retro_serialize_in_frame_result(void);
}

namespace {

struct Press { int16_t mask; int from, to; };

struct Options {
    std::string mode, rom, out, saveTo, load;
    int frames = 1800;
    int snapshotEvery = 0;
    std::vector<Press> presses;
};

[[noreturn]] void die(const char *msg) {
    fprintf(stderr, "n64-bench: %s\n", msg);
    exit(2);
}

// N64Bridge.mm's kCoreOptions, verbatim. Everything else gets the default the
// core declares, as in the bridge.
const char *kCoreOptions[][2] = {
    { "mupen64plus-rdp-plugin", "parallel" },
    { "mupen64plus-rsp-plugin", "cxd4" },
    { "mupen64plus-cpucore", "cached_interpreter" },
    { "mupen64plus-parallel-rdp-upscaling", "1x" },
    { "mupen64plus-parallel-rdp-synchronous", "True" },
    { "mupen64plus-alt-map", "True" },
    { "mupen64plus-pak1", "memory" },
    { "mupen64plus-pak2", "memory" },
    { "mupen64plus-pak3", "memory" },
    { "mupen64plus-pak4", "memory" },
};

N64VulkanFrontend gVulkan;
retro_hw_render_callback gHW;
bool gHasHW = false;
const retro_hw_render_context_negotiation_interface_vulkan *gNegotiation = nullptr;
std::map<std::string, std::string> gDefaults;
std::string gSystemDir;
Options gOpt;
int gFrame = 0;

std::vector<uint32_t> gPicture(640 * 576);
unsigned gWidth = 0, gHeight = 0;
bool gNewPicture = false;
std::vector<int16_t> gFrameAudio;

uint64_t gReadNs = 0;

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
        for (auto &o : kCoreOptions) if (!strcmp(o[0], v->key)) { v->value = o[1]; return true; }
        auto it = gDefaults.find(v->key);
        if (it == gDefaults.end()) return false;
        v->value = it->second.c_str();
        return true;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE: if (data) *(bool *)data = false; return true;
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY: *(const char **)data = gSystemDir.c_str(); return true;
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: ((retro_log_callback *)data)->log = logCallback; return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: return *(const retro_pixel_format *)data == RETRO_PIXEL_FORMAT_XRGB8888;
    case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS: if (data) *(bool *)data = true; return true;
    case RETRO_ENVIRONMENT_GET_CAN_DUPE: if (data) *(bool *)data = true; return true;
    case RETRO_ENVIRONMENT_SET_HW_RENDER: {
        auto *cb = (retro_hw_render_callback *)data;
        if (!cb || cb->context_type != RETRO_HW_CONTEXT_VULKAN) return false;
        if (!gVulkan.createInstance()) return false;
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
    if (w > 640) w = 640;
    if (h > 576) h = 576;
    const uint64_t t = nowNs(CLOCK_MONOTONIC);
    if (gVulkan.readFrame(w, h, gPicture.data(), 640)) {
        gWidth = w;
        gHeight = h;
        gNewPicture = true;
    }
    gReadNs += nowNs(CLOCK_MONOTONIC) - t;
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
int16_t inputState(unsigned port, unsigned device, unsigned, unsigned id) {
    if (port != 0 || device != RETRO_DEVICE_JOYPAD) return 0;
    const int16_t m = heldMask();
    if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return m;
    return (m >> id) & 1;
}

Options parse(int argc, char **argv) {
    if (argc < 3) die("usage: n64-bench <hash|bench> <rom.z64> [--frames N] [--out FILE] [--press MASK@A-B] [--snapshot-every N] [--save-to FILE] [--load FILE]");
    Options o;
    o.mode = argv[1];
    o.rom = argv[2];
    for (int i = 3; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> std::string { if (i + 1 >= argc) die("missing value"); return argv[++i]; };
        if (a == "--frames") o.frames = atoi(next().c_str());
        else if (a == "--out") o.out = next();
        else if (a == "--snapshot-every") o.snapshotEvery = atoi(next().c_str());
        else if (a == "--save-to") o.saveTo = next();
        else if (a == "--load") o.load = next();
        else if (a == "--press") {
            Press p{};
            int mask = 0;
            if (sscanf(next().c_str(), "%i@%d-%d", &mask, &p.from, &p.to) != 3) die("--press MASK@A-B");
            p.mask = (int16_t)mask;
            o.presses.push_back(p);
        } else die(("unknown option " + a).c_str());
    }
    if (o.mode != "hash" && o.mode != "bench") die("mode is hash or bench");
    return o;
}

}  // namespace

int main(int argc, char **argv) {
    gOpt = parse(argc, argv);

    char dir[] = "/tmp/n64-bench-sys-XXXXXX";
    if (!mkdtemp(dir)) die("mkdtemp");
    gSystemDir = dir;

    FILE *f = fopen(gOpt.rom.c_str(), "rb");
    if (!f) die("cannot open the rom");
    fseek(f, 0, SEEK_END);
    std::vector<uint8_t> rom((size_t)ftell(f));
    fseek(f, 0, SEEK_SET);
    if (fread(rom.data(), 1, rom.size(), f) != rom.size()) die("short read");
    fclose(f);

    retro_set_environment(environment);
    retro_set_video_refresh(video);
    retro_set_audio_sample(audioSample);
    retro_set_audio_sample_batch(audioBatch);
    retro_set_input_poll(inputPoll);
    retro_set_input_state(inputState);
    retro_init();

    retro_game_info info{};
    info.path = gOpt.rom.c_str();
    info.data = rom.data();
    info.size = rom.size();
    if (!retro_load_game(&info)) die("retro_load_game failed");
    if (!gHasHW || !gVulkan.createDevice(gNegotiation, 640, 576)) die("no Vulkan device");
    if (gHW.context_reset) gHW.context_reset();

    retro_system_av_info av{};
    retro_get_system_av_info(&av);
    const double fps = av.timing.fps;

    FILE *out = stdout;
    if (!gOpt.out.empty() && !(out = fopen(gOpt.out.c_str(), "w"))) die("cannot write --out");

    std::vector<uint8_t> snapshot(gOpt.snapshotEvery ? retro_serialize_size() : 0);
    bool snapshotQueued = false;

    // Timed from frame 120 on: the boot and the first shader compiles are not
    // what is being compared.
    const int warmup = gOpt.frames > 240 ? 120 : 0;
    uint64_t wallNs = 0, cpuNs = 0, drainNs = 0, worstNs = 0, samples = 0;
    gReadNs = 0;

    if (!gOpt.load.empty()) {
        // The bridge loads a state into a running machine: one frame first.
        gVulkan.beginFrame();
        retro_run();
        FILE *sf = fopen(gOpt.load.c_str(), "rb");
        if (!sf) die("cannot open --load");
        std::vector<uint8_t> state(retro_serialize_size());
        if (fread(state.data(), 1, state.size(), sf) != state.size()) die("--load: not a state of this core's size");
        fclose(sf);
        gVulkan.beginFrame();
        if (!retro_unserialize(state.data(), state.size())) die("retro_unserialize refused the state");
    }

    for (gFrame = 0; gFrame < gOpt.frames; gFrame++) {
        gFrameAudio.clear();
        gNewPicture = false;
        if (gFrame == warmup) gReadNs = 0;

        const uint64_t w0 = nowNs(CLOCK_MONOTONIC);
        const uint64_t c0 = nowNs(CLOCK_THREAD_CPUTIME_ID);
        gVulkan.beginFrame();
        const uint64_t w1 = nowNs(CLOCK_MONOTONIC);
        retro_run();
        const uint64_t w2 = nowNs(CLOCK_MONOTONIC);
        const uint64_t c2 = nowNs(CLOCK_THREAD_CPUTIME_ID);

        if (snapshotQueued && retro_serialize_in_frame_result() != 0) snapshotQueued = false;
        if (gOpt.snapshotEvery && !snapshotQueued && gFrame % gOpt.snapshotEvery == 0) {
            snapshotQueued = retro_serialize_in_frame(snapshot.data(), snapshot.size());
        }

        if (gFrame >= warmup) {
            wallNs += w2 - w0;
            cpuNs += c2 - c0;
            drainNs += w1 - w0;
            if (w2 - w0 > worstNs) worstNs = w2 - w0;
            samples += gFrameAudio.size() / 2;
        }

        if (gOpt.mode == "hash") {
            uint64_t h = 1469598103934665603ull;
            if (gNewPicture) for (unsigned y = 0; y < gHeight; y++) h = fnv(&gPicture[(size_t)y * 640], (size_t)gWidth * 4, h);
            fprintf(out, "%d %ux%u %016llx %016llx %zu\n", gFrame,
                    gNewPicture ? gWidth : 0, gNewPicture ? gHeight : 0,
                    gNewPicture ? (unsigned long long)h : 0ull,
                    (unsigned long long)fnv(gFrameAudio.data(), gFrameAudio.size() * 2),
                    gFrameAudio.size() / 2);
        }
    }

    if (!gOpt.saveTo.empty()) {
        std::vector<uint8_t> state(retro_serialize_size());
        gVulkan.beginFrame();
        if (!retro_serialize(state.data(), state.size())) die("retro_serialize failed");
        FILE *sf = fopen(gOpt.saveTo.c_str(), "wb");
        if (!sf || fwrite(state.data(), 1, state.size(), sf) != state.size()) die("cannot write --save-to");
        fclose(sf);
    }

    if (gOpt.mode == "bench") {
        const double n = (double)(gOpt.frames - warmup);
        printf("frames %d (timed %d) at %.4f fps\n", gOpt.frames, (int)n, fps);
        printf("wall %.3f ms/frame | emulation thread cpu %.3f | beginFrame drain %.3f | readback %.3f | worst %.2f ms\n",
               wallNs / n / 1e6, cpuNs / n / 1e6, drainNs / n / 1e6, gReadNs / n / 1e6, worstNs / 1e6);
        printf("audio %.2f samples/frame = %.1f Hz at the core's fps (the bridge plays 44100)\n",
               samples / n, samples / n * fps);
    }
    if (out != stdout) fclose(out);
    // Exit without the teardown, like the scratch harness: the bench measures
    // frames, and the core's shutdown path is not under test here.
    fflush(stdout);
    _exit(0);
}
