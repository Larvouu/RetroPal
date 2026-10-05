/*
 * Host check for the Nintendo 64 core, built and run by `HOST=1 ./build.sh`.
 *
 * It answers three questions without a device and without a GPU:
 *   1. The pre-linked core links on its own and is callable through the
 *      renamed n64_retro_* API (this file is compiled with n64_symbols.h
 *      force-included, exactly like N64Bridge.mm).
 *   2. The core reports what the bridge expects of it: the libretro API
 *      version, the file extensions it accepts, and whether it wants a path or
 *      the bytes of the game.
 *   3. A load with no Vulkan context fails cleanly. The core's default renderer
 *      request is GLideN64, which the patch redirects to parallel-RDP; with no
 *      Vulkan the load must return false, not crash in code that was compiled
 *      out.
 *   4. The core can be started and stopped a second time in the same process,
 *      which is what the app does from one game to the next (patch 0002).
 *
 * Exit code 0 means every check passed.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libretro.h"

static int failures = 0;

static void check(int ok, const char *what)
{
    printf("  [%s] %s\n", ok ? "ok" : "FAIL", what);
    if (!ok)
        failures++;
}

static int hw_render_requested = 0;
static char system_dir[64] = "/tmp/n64-host-check-XXXXXX";

/* The core calls its log callback without checking it was given one, so a
 * frontend must supply it (N64Bridge does). Only warnings and errors print. */
static void core_log(enum retro_log_level level, const char *fmt, ...)
{
    va_list args;
    if (level < RETRO_LOG_WARN)
        return;
    va_start(args, fmt);
    printf("  core: ");
    vprintf(fmt, args);
    va_end(args);
}

/* A frontend that offers only what the core cannot start without: a log and a
 * system directory (retro_init copies the directory's path without checking
 * it was given one, and writes its mupen64plus.ini there). No variables and no
 * hardware rendering. The one thing recorded is whether the core asked for
 * Vulkan. */
static bool environment(unsigned cmd, void *data)
{
    switch (cmd)
    {
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
            *(const char **)data = system_dir;
            return true;
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
            ((struct retro_log_callback *)data)->log = core_log;
            return true;
        case RETRO_ENVIRONMENT_SET_HW_RENDER:
            hw_render_requested = 1;
            return false;
        default:
            return false;
    }
}

static void video_refresh(const void *data, unsigned width, unsigned height, size_t pitch)
{
    (void)data; (void)width; (void)height; (void)pitch;
}
static void audio_sample(int16_t left, int16_t right) { (void)left; (void)right; }
static size_t audio_sample_batch(const int16_t *data, size_t frames) { (void)data; return frames; }
static void input_poll(void) {}
static int16_t input_state(unsigned port, unsigned device, unsigned index, unsigned id)
{
    (void)port; (void)device; (void)index; (void)id;
    return 0;
}

int main(void)
{
    struct retro_system_info info;
    struct retro_game_info game;
    const size_t rom_size = 8 * 1024 * 1024;
    unsigned char *rom;
    bool loaded;

    printf("host-check: Mupen64Plus-Next, renamed and pre-linked\n");

    check(retro_api_version() == RETRO_API_VERSION, "libretro API version matches libretro.h");

    memset(&info, 0, sizeof(info));
    retro_get_system_info(&info);
    printf("  library: %s %s\n", info.library_name ? info.library_name : "(null)",
           info.library_version ? info.library_version : "(null)");
    printf("  extensions: %s\n", info.valid_extensions ? info.valid_extensions : "(null)");
    printf("  need_fullpath: %s\n", info.need_fullpath ? "yes" : "no");
    check(info.valid_extensions != NULL && strstr(info.valid_extensions, "z64") != NULL,
          "accepts .z64");

    if (!mkdtemp(system_dir))
    {
        printf("  [FAIL] could not create a system directory\n");
        return 1;
    }

    retro_set_environment(environment);
    retro_set_video_refresh(video_refresh);
    retro_set_audio_sample(audio_sample);
    retro_set_audio_sample_batch(audio_sample_batch);
    retro_set_input_poll(input_poll);
    retro_set_input_state(input_state);
    retro_init();

    /* A zero-filled cartridge-sized buffer: enough to reach the renderer
     * choice, which happens before the ROM is parsed. */
    rom = calloc(1, rom_size);
    if (!rom)
    {
        printf("  [FAIL] could not allocate the test buffer\n");
        return 1;
    }
    memset(&game, 0, sizeof(game));
    game.path = "host-check.z64";
    game.data = rom;
    game.size = rom_size;

    loaded = retro_load_game(&game);
    check(hw_render_requested, "the core asked for a hardware (Vulkan) context");
    check(!loaded, "without Vulkan the load fails cleanly");
    retro_unload_game();
    retro_deinit();

    /* The second session, as the app starts one for the next game. */
    hw_render_requested = 0;
    retro_init();
    loaded = retro_load_game(&game);
    check(hw_render_requested && !loaded, "a second session starts and fails the same way");
    retro_unload_game();
    retro_deinit();
    check(1, "the core stopped twice without crashing");

    free(rom);

    printf("host-check: %s\n", failures ? "FAILED" : "all checks passed");
    return failures ? 1 : 0;
}
