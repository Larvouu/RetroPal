// Host harness for the Mega Drive core (BlastEm, libretro build) as Retro Pal
// would ship it: the generated C interpreters (NEW_CORE, the only path BlastEm
// has off x86, so the phone's path), loaded from a shared object through its
// libretro entry points, exactly as a bridge would call them. It exists so the
// core is measured and proven on this machine before it reaches a phone:
//
//   hash       run N frames and print one line per frame: the frame's size, a
//              hash of its picture and of the sound it produced. Two runs (or
//              two builds) with identical files produced the same picture and
//              sound on every frame: the gate for any change meant to be
//              invisible, and the proof that a run is deterministic.
//   bench      the same run, timed: mean, median, p95, p99 and worst
//              milliseconds per retro_run. Host timings, so only RATIOS mean
//              anything; the phone's own figure is the number that decides.
//   roundtrip  run N frames, serialize, run M frames (A), unserialize, run M
//              frames again (B): A and B must be identical. Proves a state
//              written by this build restores exactly (what rewind and save
//              slots rely on). Also prints the state size.
//   shot       run N frames and write PNG-ready PPM pictures of the frames
//              listed by --shots, to look at what the run actually shows.
//   reload     run N frames, then shut the core down exactly as the app does
//              between two games (retro_unload_game, retro_deinit, the
//              callbacks set again, retro_init), load the game again in the
//              same process and run N frames: both halves must be identical.
//              The app keeps the core linked for its whole life and loads game
//              after game into it, where RetroArch reloads the library, so
//              state the core keeps between games is only visible here.
//   capture    the save-state fixture (EmulateurGBATests/Fixtures/
//              SaveStateCompat/md): run N frames, then write retro_serialize's
//              bytes to --state FILE exactly as BlastEmBridge's saveStateToPath
//              does. Made once, from the core a release SHIPS.
//   verify     a core against that state, in a fresh process, the app's and
//              the test's own path: boot the game, run one frame, load --state
//              FILE with BlastEmBridge's own length check, run --rt-len frames
//              and compare each line with --expect FILE. With --play the input
//              script goes on from the frame the state was saved at (--rt-at),
//              so those frames are play, with its sound. Exit 0
//              only if every frame matches, picture and sound. With --record
//              it WRITES --expect FILE instead: run that once, with the core
//              the state was captured from, so the reference is that core
//              taking this very path (a run that played into the save does not
//              match it: BlastEm's resampler phase is not in the state, so the
//              sound after a load differs from an unbroken run by ~7 us).
//
// Usage: md-bench <mode> <core.so> <rom> [options]
//   --frames N       frames to run (default 3600, one minute at 60 fps)
//   --play           scripted input instead of none: Start on the title, then
//                    run right and jump, which scrolls the level (Sonic's first
//                    act). Without it the game plays its own attract demo.
//   --snapshot-every N  serialize a state every N frames and throw it away, as
//                    a rewind does; the hashes must not change because of it
//   --shots a,b,c    shot: the frames to write (ppm, into --out-dir)
//   --out-dir DIR    shot: where the pictures go (default .)
//   --rt-at N        roundtrip: frame of the save (default 1800)
//   --rt-len M       roundtrip: frames compared after it (default 600)
//   --by-path        hand the core the file's PATH only, as the app does
//                    (the core declares need_fullpath), not its bytes
//   --state FILE     capture / verify: the state file
//   --expect FILE    verify: the frames after the load, one line each
//   --record         verify: write --expect FILE rather than compare with it
//   --poke AAAAAA:VV[VV]  a Pro Action Replay code, written into work RAM
//                    before every frame exactly as BlastEmBridge's cheats do
//                    (two digits a byte, four a word; at an odd address 00YY
//                    a byte, any other four the word below); repeatable up to 8
//
// Paths are arguments on purpose: the games used to measure are the owner's
// own and never enter the repository.

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "libretro.h"

static void die(const char *msg) {
    fprintf(stderr, "md-bench: %s\n", msg);
    exit(2);
}

// ---------------------------------------------------------------- the core

static struct {
    void (*set_environment)(retro_environment_t);
    void (*set_video_refresh)(retro_video_refresh_t);
    void (*set_audio_sample)(retro_audio_sample_t);
    void (*set_audio_sample_batch)(retro_audio_sample_batch_t);
    void (*set_input_poll)(retro_input_poll_t);
    void (*set_input_state)(retro_input_state_t);
    void (*init)(void);
    void (*deinit)(void);
    void (*get_system_av_info)(struct retro_system_av_info *);
    bool (*load_game)(const struct retro_game_info *);
    void (*unload_game)(void);
    void (*run)(void);
    size_t (*serialize_size)(void);
    bool (*serialize)(void *, size_t);
    bool (*unserialize)(const void *, size_t);
    void *(*get_memory_data)(unsigned);
    size_t (*get_memory_size)(unsigned);
} core;

// The shipped build renames the API to md_retro_* (Vendor/blastem-ios/md_symbols.h);
// a plain upstream build keeps retro_*. Either is accepted.
static void *sym(void *h, const char *name) {
    char renamed[64];
    snprintf(renamed, sizeof renamed, "md_%s", name);
    void *p = dlsym(h, renamed);
    if (!p) p = dlsym(h, name);
    if (!p) {
        fprintf(stderr, "md-bench: missing %s\n", name);
        exit(2);
    }
    return p;
}

static void load_core(const char *path) {
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        fprintf(stderr, "md-bench: %s\n", dlerror());
        exit(2);
    }
    *(void **)&core.set_environment = sym(h, "retro_set_environment");
    *(void **)&core.set_video_refresh = sym(h, "retro_set_video_refresh");
    *(void **)&core.set_audio_sample = sym(h, "retro_set_audio_sample");
    *(void **)&core.set_audio_sample_batch = sym(h, "retro_set_audio_sample_batch");
    *(void **)&core.set_input_poll = sym(h, "retro_set_input_poll");
    *(void **)&core.set_input_state = sym(h, "retro_set_input_state");
    *(void **)&core.init = sym(h, "retro_init");
    *(void **)&core.get_memory_data = sym(h, "retro_get_memory_data");
    *(void **)&core.get_memory_size = sym(h, "retro_get_memory_size");
    *(void **)&core.deinit = sym(h, "retro_deinit");
    *(void **)&core.get_system_av_info = sym(h, "retro_get_system_av_info");
    *(void **)&core.load_game = sym(h, "retro_load_game");
    *(void **)&core.unload_game = sym(h, "retro_unload_game");
    *(void **)&core.run = sym(h, "retro_run");
    *(void **)&core.serialize_size = sym(h, "retro_serialize_size");
    *(void **)&core.serialize = sym(h, "retro_serialize");
    *(void **)&core.unserialize = sym(h, "retro_unserialize");
}

// ---------------------------------------------------------------- callbacks

static unsigned g_pixel_format = RETRO_PIXEL_FORMAT_0RGB1555;
static const char *g_sysdir = ".";
static int g_frame;
// Added to g_frame for the input script only, so after a load the script goes
// on from the frame the state was saved at while the lines count from 0.
static int g_input_base;
static bool g_play;
static bool g_by_path;
static struct { uint32_t offset; uint16_t value; bool is_byte; } g_pokes[8];
static int g_poke_count;

// BlastEmBridge's `applyCheats`, line for line: work RAM is 16-bit words in
// the host's order, a byte at an even 68000 address is a word's high half.
static void apply_pokes(void) {
    if (!g_poke_count) return;
    uint16_t *ram = core.get_memory_data(RETRO_MEMORY_SYSTEM_RAM);
    if (!ram || core.get_memory_size(RETRO_MEMORY_SYSTEM_RAM) < 0x10000) return;
    for (int i = 0; i < g_poke_count; i++) {
        uint16_t *word = &ram[g_pokes[i].offset >> 1];
        if (!g_pokes[i].is_byte) *word = g_pokes[i].value;
        else if (g_pokes[i].offset & 1) *word = (*word & 0xFF00) | (g_pokes[i].value & 0xFF);
        else *word = (*word & 0x00FF) | ((g_pokes[i].value & 0xFF) << 8);
    }
}

// The last picture, kept for hashing and shots.
static const void *g_video;
static unsigned g_width, g_height;
static size_t g_pitch;
static uint64_t g_audio_hash;
static size_t g_audio_frames;

static uint64_t fnv(uint64_t h, const void *data, size_t len) {
    const uint8_t *p = data;
    for (size_t i = 0; i < len; i++) {
        h ^= p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

static bool environment(unsigned cmd, void *data) {
    switch (cmd) {
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
        *(const char **)data = g_sysdir;
        return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
        g_pixel_format = *(const unsigned *)data;
        return true;
    case RETRO_ENVIRONMENT_GET_OVERSCAN:
        *(bool *)data = false;
        return true;
    case RETRO_ENVIRONMENT_SET_GEOMETRY:
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE:
        return true;
    default:
        return false;
    }
}

static void video_refresh(const void *data, unsigned w, unsigned h, size_t pitch) {
    if (!data) return; // a duplicated frame
    g_video = data;
    g_width = w;
    g_height = h;
    g_pitch = pitch;
}

static void audio_sample(int16_t l, int16_t r) {
    int16_t s[2] = {l, r};
    g_audio_hash = fnv(g_audio_hash, s, sizeof s);
    g_audio_frames++;
}

static size_t audio_batch(const int16_t *data, size_t frames) {
    g_audio_hash = fnv(g_audio_hash, data, frames * 4);
    g_audio_frames += frames;
    return frames;
}

static void input_poll(void) {}

// --play: Start twice to leave the SEGA logo and the title, then run right
// and jump every 70 frames, so the level scrolls (the expensive case for the
// VDP and the 68K both) instead of the attract demo's fixed script.
static int16_t input_state(unsigned port, unsigned device, unsigned index, unsigned id) {
    (void)index;
    if (!g_play || port != 0 || device != RETRO_DEVICE_JOYPAD) return 0;
    int f = g_frame + g_input_base;
    if (id == RETRO_DEVICE_ID_JOYPAD_START)
        return (f >= 300 && f < 310) || (f >= 500 && f < 510);
    if (f < 700) return 0;
    if (id == RETRO_DEVICE_ID_JOYPAD_RIGHT) return 1;
    if (id == RETRO_DEVICE_ID_JOYPAD_B) return (f % 70) < 20; // BlastEm's "A"
    return 0;
}

// ---------------------------------------------------------------- helpers

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static unsigned bytes_per_pixel(void) {
    return g_pixel_format == RETRO_PIXEL_FORMAT_XRGB8888 ? 4 : 2;
}

static uint64_t picture_hash(void) {
    uint64_t h = 0xcbf29ce484222325ULL;
    if (!g_video) return h;
    const uint8_t *row = g_video;
    for (unsigned y = 0; y < g_height; y++, row += g_pitch)
        h = fnv(h, row, (size_t)g_width * bytes_per_pixel());
    return h;
}

static void write_ppm(const char *dir, int frame) {
    if (!g_video) return;
    char path[1024];
    snprintf(path, sizeof path, "%s/frame-%05d.ppm", dir, frame);
    FILE *f = fopen(path, "wb");
    if (!f) die("cannot write a shot");
    fprintf(f, "P6\n%u %u\n255\n", g_width, g_height);
    const uint8_t *row = g_video;
    for (unsigned y = 0; y < g_height; y++, row += g_pitch) {
        for (unsigned x = 0; x < g_width; x++) {
            uint8_t rgb[3];
            if (bytes_per_pixel() == 4) {
                uint32_t p = ((const uint32_t *)row)[x];
                rgb[0] = p >> 16; rgb[1] = p >> 8; rgb[2] = p;
            } else {
                uint16_t p = ((const uint16_t *)row)[x];
                if (g_pixel_format == RETRO_PIXEL_FORMAT_RGB565) {
                    rgb[0] = ((p >> 11) & 31) << 3; rgb[1] = ((p >> 5) & 63) << 2; rgb[2] = (p & 31) << 3;
                } else {
                    rgb[0] = ((p >> 10) & 31) << 3; rgb[1] = ((p >> 5) & 31) << 3; rgb[2] = (p & 31) << 3;
                }
            }
            fwrite(rgb, 1, 3, f);
        }
    }
    fclose(f);
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

// One emulated frame, with its picture/sound line when `out` is given.
static void step(FILE *out) {
    g_audio_hash = 0xcbf29ce484222325ULL;
    g_audio_frames = 0;
    apply_pokes();
    core.run();
    if (out)
        fprintf(out, "%d %ux%u %016llx %016llx %zu\n", g_frame, g_width, g_height,
                (unsigned long long)picture_hash(), (unsigned long long)g_audio_hash, g_audio_frames);
    g_frame++;
}

// ---------------------------------------------------------------- main

int main(int argc, char **argv) {
    if (argc < 4) die("usage: md-bench <hash|bench|roundtrip|shot|reload|capture|verify> <core.so> <rom> [options]");
    const char *mode = argv[1], *core_path = argv[2], *rom = argv[3];
    int frames = 3600, snapshot_every = 0, rt_at = 1800, rt_len = 600;
    const char *shots = "", *out_dir = ".", *state_path = NULL, *expect_path = NULL;
    bool record = false;
    for (int i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "--frames") && i + 1 < argc) frames = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--play")) g_play = true;
        else if (!strcmp(argv[i], "--snapshot-every") && i + 1 < argc) snapshot_every = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--shots") && i + 1 < argc) shots = argv[++i];
        else if (!strcmp(argv[i], "--out-dir") && i + 1 < argc) out_dir = argv[++i];
        else if (!strcmp(argv[i], "--rt-at") && i + 1 < argc) rt_at = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--rt-len") && i + 1 < argc) rt_len = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--by-path")) g_by_path = true;
        else if (!strcmp(argv[i], "--state") && i + 1 < argc) state_path = argv[++i];
        else if (!strcmp(argv[i], "--expect") && i + 1 < argc) expect_path = argv[++i];
        else if (!strcmp(argv[i], "--record")) record = true;
        else if (!strcmp(argv[i], "--poke") && i + 1 < argc && g_poke_count < 8) {
            unsigned addr = 0, val = 0;
            const char *arg = argv[++i];
            const char *colon = strchr(arg, ':');
            if (!colon || sscanf(arg, "%x:%x", &addr, &val) != 2) die("--poke wants AAAAAA:VV or AAAAAA:VVVV");
            // BlastEmBridge's addCheatCode: two digits a byte; four a word,
            // except at an odd address, where 00YY is a byte there and any
            // other value the word at the even address below (GPGX's rule).
            bool is_byte = strlen(colon + 1) == 2;
            if (!is_byte && (addr & 1)) {
                if (val <= 0xFF) is_byte = true;
                else addr &= ~1u;
            }
            g_pokes[g_poke_count].offset = addr & 0xFFFF;
            g_pokes[g_poke_count].value = (uint16_t)val;
            g_pokes[g_poke_count].is_byte = is_byte;
            g_poke_count++;
        }
        else die("unknown option");
    }

    load_core(core_path);
    core.set_environment(environment);
    core.set_video_refresh(video_refresh);
    core.set_audio_sample(audio_sample);
    core.set_audio_sample_batch(audio_batch);
    core.set_input_poll(input_poll);
    core.set_input_state(input_state);
    core.init();

    struct retro_game_info game = {.path = rom};
    FILE *rf = fopen(rom, "rb");
    if (!rf) die("cannot open the rom");
    fseek(rf, 0, SEEK_END);
    game.size = ftell(rf);
    fseek(rf, 0, SEEK_SET);
    void *buf = malloc(game.size);
    if (fread(buf, 1, game.size, rf) != game.size) die("cannot read the rom");
    fclose(rf);
    game.data = buf;
    if (g_by_path) { game.data = NULL; game.size = 0; }
    if (!core.load_game(&game)) die("retro_load_game refused the rom");

    struct retro_system_av_info av;
    core.get_system_av_info(&av);
    fprintf(stderr, "md-bench: %.4f fps, %.0f Hz, base %ux%u, pixel format %u\n", av.timing.fps,
            av.timing.sample_rate, av.geometry.base_width, av.geometry.base_height, g_pixel_format);

    void *snap = NULL;
    size_t snap_size = 0;
    if (snapshot_every > 0) {
        snap_size = core.serialize_size();
        snap = malloc(snap_size);
    }

    if (!strcmp(mode, "hash")) {
        while (g_frame < frames) {
            step(stdout);
            if (snap && g_frame % snapshot_every == 0 && !core.serialize(snap, snap_size)) die("serialize failed");
        }
    } else if (!strcmp(mode, "bench")) {
        double *t = malloc(sizeof(double) * frames);
        double snap_total = 0;
        int snaps = 0;
        for (int i = 0; i < frames; i++) {
            double a = now_ms();
            step(NULL);
            t[i] = now_ms() - a;
            if (snap && g_frame % snapshot_every == 0) {
                double s = now_ms();
                if (!core.serialize(snap, snap_size)) die("serialize failed");
                snap_total += now_ms() - s;
                snaps++;
            }
        }
        // The first second boots the console; it is reported apart.
        int skip = frames > 120 ? 60 : 0;
        int n = frames - skip;
        double sum = 0;
        for (int i = skip; i < frames; i++) sum += t[i];
        qsort(t + skip, n, sizeof(double), cmp_double);
        printf("frames %d (timed %d) at %.4f fps, budget %.2f ms\n", frames, n, av.timing.fps, 1000.0 / av.timing.fps);
        printf("mean %.3f ms | median %.3f | p95 %.3f | p99 %.3f | worst %.3f\n", sum / n, t[skip + n / 2],
               t[skip + (int)(n * 0.95)], t[skip + (int)(n * 0.99)], t[frames - 1]);
        if (snaps) printf("snapshot %zu bytes, %.3f ms each (%d taken)\n", snap_size, snap_total / snaps, snaps);
    } else if (!strcmp(mode, "roundtrip")) {
        while (g_frame < rt_at) step(NULL);
        size_t size = core.serialize_size();
        void *state = malloc(size);
        if (!core.serialize(state, size)) die("serialize failed");
        printf("state %zu bytes at frame %d\n", size, g_frame);
        char *pa = NULL, *pb = NULL;
        size_t la = 0, lb = 0;
        FILE *a = open_memstream(&pa, &la);
        int start = g_frame;
        for (int i = 0; i < rt_len; i++) step(a);
        fclose(a);
        if (!core.unserialize(state, size)) die("unserialize failed");
        g_frame = start;
        FILE *b = open_memstream(&pb, &lb);
        for (int i = 0; i < rt_len; i++) step(b);
        fclose(b);
        // Line by line, so the first differing frame is named, and the picture
        // apart from the sound (the picture is the first three fields).
        int same = 0, same_video = 0, first_diff = -1;
        char *sa = pa, *sb = pb;
        for (int i = 0; i < rt_len; i++) {
            char *ea = strchr(sa, '\n'), *eb = strchr(sb, '\n');
            if (!ea || !eb) break;
            if (ea - sa == eb - sb && !memcmp(sa, sb, ea - sa)) same++;
            else {
                if (first_diff < 0) {
                    first_diff = start + i;
                    printf("  A %.*s\n  B %.*s\n", (int)(ea - sa), sa, (int)(eb - sb), sb);
                }
            }
            char *va = sa, *vb = sb;
            for (int k = 0; k < 3 && va && vb; k++) {
                va = strchr(va, ' ');
                vb = strchr(vb, ' ');
                if (va) va++;
                if (vb) vb++;
            }
            if (va && vb && va - sa == vb - sb && !memcmp(sa, sb, va - sa)) same_video++;
            sa = ea + 1;
            sb = eb + 1;
        }
        printf("roundtrip: %d of %d frames identical after the load (picture alone: %d)", same, rt_len, same_video);
        if (first_diff >= 0) printf(", first difference at frame %d", first_diff);
        printf("\n");
        return same == rt_len ? 0 : 1;
    } else if (!strcmp(mode, "reload")) {
        char *pa = NULL, *pb = NULL;
        size_t la = 0, lb = 0;
        FILE *a = open_memstream(&pa, &la);
        while (g_frame < frames) step(a);
        fclose(a);
        core.unload_game();
        core.deinit();
        core.set_video_refresh(video_refresh);
        core.set_audio_sample(audio_sample);
        core.set_audio_sample_batch(audio_batch);
        core.set_input_poll(input_poll);
        core.set_input_state(input_state);
        core.set_environment(environment);
        core.init();
        if (!core.load_game(&game)) die("retro_load_game refused the rom the second time");
        core.get_system_av_info(&av);
        g_frame = 0;
        FILE *b = open_memstream(&pb, &lb);
        while (g_frame < frames) step(b);
        fclose(b);
        int same = 0, first_diff = -1;
        char *sa = pa, *sb = pb;
        for (int i = 0; i < frames; i++) {
            char *ea = strchr(sa, '\n'), *eb = strchr(sb, '\n');
            if (!ea || !eb) break;
            if (ea - sa == eb - sb && !memcmp(sa, sb, ea - sa)) same++;
            else if (first_diff < 0) {
                first_diff = i;
                printf("  first %.*s\n  again %.*s\n", (int)(ea - sa), sa, (int)(eb - sb), sb);
            }
            sa = ea + 1;
            sb = eb + 1;
        }
        printf("reload: %d of %d frames identical on the second load", same, frames);
        if (first_diff >= 0) printf(", first difference at frame %d", first_diff);
        printf("\n");
        return same == frames ? 0 : 1;
    } else if (!strcmp(mode, "capture")) {
        if (!state_path) die("capture wants --state FILE");
        while (g_frame < frames) step(NULL);
        size_t size = core.serialize_size();
        void *state = malloc(size);
        if (!core.serialize(state, size)) die("serialize failed");
        FILE *sf = fopen(state_path, "wb");
        if (!sf || fwrite(state, 1, size, sf) != size) die("cannot write the state");
        fclose(sf);
        printf("capture: state %zu bytes at frame %d\n", size, g_frame);
    } else if (!strcmp(mode, "verify")) {
        if (!state_path || !expect_path) die("verify wants --state FILE and --expect FILE");
        // One frame before the load, as the app and the test do, with no
        // input: the input script, if any, resumes at the saved frame.
        bool play = g_play;
        g_play = false;
        step(NULL);
        g_play = play;
        FILE *sf = fopen(state_path, "rb");
        if (!sf) die("cannot open the state");
        fseek(sf, 0, SEEK_END);
        size_t len = ftell(sf);
        fseek(sf, 0, SEEK_SET);
        void *state = malloc(len);
        if (fread(state, 1, len, sf) != len) die("cannot read the state");
        fclose(sf);
        // BlastEmBridge's own refusal: the state starts with its length.
        size_t inner = 0;
        if (len < sizeof inner) die("state too short");
        memcpy(&inner, state, sizeof inner);
        if (inner == 0 || inner > len - sizeof inner) die("state length header refused, as the bridge would");
        if (!core.unserialize(state, len)) die("unserialize refused the state");
        g_input_base = rt_at;
        if (record) {
            FILE *ef = fopen(expect_path, "wb");
            if (!ef) die("cannot write the expected frames");
            g_frame = 0;
            for (int i = 0; i < rt_len; i++) step(ef);
            fclose(ef);
            printf("verify --record: state %zu bytes loaded, %d frames written\n", len, rt_len);
            return 0;
        }
        char *got = NULL;
        size_t got_len = 0;
        FILE *g = open_memstream(&got, &got_len);
        g_frame = 0;
        for (int i = 0; i < rt_len; i++) step(g);
        fclose(g);
        FILE *ef = fopen(expect_path, "rb");
        if (!ef) die("cannot open the expected frames");
        char *want = NULL;
        size_t want_len = 0;
        FILE *w = open_memstream(&want, &want_len);
        char chunk[4096];
        size_t n;
        while ((n = fread(chunk, 1, sizeof chunk, ef)) > 0) fwrite(chunk, 1, n, w);
        fclose(w);
        fclose(ef);
        int same = 0, first_diff = -1;
        char *sa = got, *sb = want;
        for (int i = 0; i < rt_len; i++) {
            char *ea = strchr(sa, '\n'), *eb = strchr(sb, '\n');
            if (!ea || !eb) break;
            if (ea - sa == eb - sb && !memcmp(sa, sb, ea - sa)) same++;
            else if (first_diff < 0) {
                first_diff = i;
                printf("  got  %.*s\n  want %.*s\n", (int)(ea - sa), sa, (int)(eb - sb), sb);
            }
            sa = ea + 1;
            sb = eb + 1;
        }
        printf("verify: state %zu bytes loaded, %d of %d frames after it identical to the capture", len, same, rt_len);
        if (first_diff >= 0) printf(", first difference at frame %d", first_diff);
        printf("\n");
        return same == rt_len ? 0 : 1;
    } else if (!strcmp(mode, "shot")) {
        while (g_frame < frames) {
            step(NULL);
            char key[32];
            snprintf(key, sizeof key, ",%d,", g_frame - 1);
            char list[4096];
            snprintf(list, sizeof list, ",%s,", shots);
            if (strstr(list, key)) write_ppm(out_dir, g_frame - 1);
        }
    } else {
        die("unknown mode");
    }

    core.unload_game();
    core.deinit();
    return 0;
}
