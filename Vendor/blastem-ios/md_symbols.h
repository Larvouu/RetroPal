/*
 * Renames the libretro API of the Mega Drive core (BlastEm), so it can live in
 * the same binary as PCSX-ReARMed and Mupen64Plus-Next.
 *
 * All three are libretro cores linked statically into the app, and all three
 * define retro_run, retro_init and the rest under the same names. The linker
 * cannot hold two definitions of one symbol, so this core's entry points are
 * given an md_ prefix, as n64_symbols.h does for the Nintendo 64. The header is
 * force-included into every translation unit of the core by
 * Vendor/blastem-ios/build.sh (through CC, see there), and the bridge includes
 * it before libretro.h, so the core and the bridge see the same names.
 *
 * Renaming the entry points is half of the job. The core also carries its own
 * zlib, zstd, lzma and a hundred generic globals (config, current_system,
 * render_*), which would collide the same way; build.sh pre-links the whole
 * core into one object that exports ONLY the names below, so every other
 * symbol becomes private. build.sh reads this file to build that export list:
 * a libretro function missing from here would stay private and fail to link
 * from the bridge, loudly, rather than collide silently.
 *
 * The list is every RETRO_API function libblastem.c defines.
 */
#ifndef RETRO_PAL_MD_SYMBOLS_H
#define RETRO_PAL_MD_SYMBOLS_H

#define retro_api_version                md_retro_api_version
#define retro_cheat_reset                md_retro_cheat_reset
#define retro_cheat_set                  md_retro_cheat_set
#define retro_deinit                     md_retro_deinit
#define retro_get_memory_data            md_retro_get_memory_data
#define retro_get_memory_size            md_retro_get_memory_size
#define retro_get_region                 md_retro_get_region
#define retro_get_system_av_info         md_retro_get_system_av_info
#define retro_get_system_info            md_retro_get_system_info
#define retro_init                       md_retro_init
#define retro_load_game                  md_retro_load_game
#define retro_load_game_special          md_retro_load_game_special
#define retro_reset                      md_retro_reset
#define retro_run                        md_retro_run
#define retro_serialize                  md_retro_serialize
#define retro_serialize_size             md_retro_serialize_size
#define retro_set_audio_sample           md_retro_set_audio_sample
#define retro_set_audio_sample_batch     md_retro_set_audio_sample_batch
#define retro_set_controller_port_device md_retro_set_controller_port_device
#define retro_set_environment            md_retro_set_environment
#define retro_set_input_poll             md_retro_set_input_poll
#define retro_set_input_state            md_retro_set_input_state
#define retro_set_video_refresh          md_retro_set_video_refresh
#define retro_unload_game                md_retro_unload_game
#define retro_unserialize                md_retro_unserialize

#endif /* RETRO_PAL_MD_SYMBOLS_H */
