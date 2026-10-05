/*
 * Renames the libretro API of the Nintendo 64 core, so it can live in the same
 * binary as PCSX-ReARMed.
 *
 * Both cores are libretro cores linked statically into the app, and both
 * define retro_run, retro_init and the rest under the same names. The linker
 * cannot hold two definitions of one symbol, so this core's entry points are
 * given an n64_ prefix. The header is force-included into every translation
 * unit of the core by Vendor/n64-ios/build.sh (CPPFLAGS=-include), and
 * N64Bridge.mm includes it before libretro.h, so the core and the bridge see
 * the same names and nothing else has to change.
 *
 * Renaming the entry points is half of the job. The core also carries its own
 * zlib, libpng, libretro-common and C++ internals, which would collide with
 * PCSX's copies the same way; build.sh pre-links the whole core into one object
 * that exports ONLY the names below, so every other symbol becomes private.
 * build.sh reads this file to build that export list, which makes this list
 * the single source of truth for what the core exposes: a libretro function
 * missing from here would stay private and fail to link from the bridge,
 * loudly, rather than collide silently.
 */
#ifndef RETRO_PAL_N64_SYMBOLS_H
#define RETRO_PAL_N64_SYMBOLS_H

#define retro_api_version                n64_retro_api_version
#define retro_cheat_reset                n64_retro_cheat_reset
#define retro_cheat_set                  n64_retro_cheat_set
#define retro_deinit                     n64_retro_deinit
#define retro_get_memory_data            n64_retro_get_memory_data
#define retro_get_memory_size            n64_retro_get_memory_size
#define retro_get_region                 n64_retro_get_region
#define retro_get_system_av_info         n64_retro_get_system_av_info
#define retro_get_system_info            n64_retro_get_system_info
#define retro_init                       n64_retro_init
#define retro_load_game                  n64_retro_load_game
#define retro_load_game_special          n64_retro_load_game_special
#define retro_reset                      n64_retro_reset
#define retro_run                        n64_retro_run
#define retro_serialize                  n64_retro_serialize
#define retro_serialize_size             n64_retro_serialize_size
#define retro_set_audio_sample           n64_retro_set_audio_sample
#define retro_set_audio_sample_batch     n64_retro_set_audio_sample_batch
#define retro_set_controller_port_device n64_retro_set_controller_port_device
#define retro_set_environment            n64_retro_set_environment
#define retro_set_input_poll             n64_retro_set_input_poll
#define retro_set_input_state            n64_retro_set_input_state
#define retro_set_video_refresh          n64_retro_set_video_refresh
#define retro_unload_game                n64_retro_unload_game
#define retro_unserialize                n64_retro_unserialize

#endif /* RETRO_PAL_N64_SYMBOLS_H */
