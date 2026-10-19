/*
 * Renames the libretro API of the PSP core (PPSSPP's own libretro port), so it
 * can live in the same binary as PCSX-ReARMed, Mupen64Plus-Next and BlastEm.
 *
 * All four are libretro cores linked statically into the app, and all define
 * retro_run, retro_init and the rest under the same names. This core's entry
 * points get a psp_ prefix, as n64_symbols.h and md_symbols.h do. The header
 * is force-included into every translation unit of the core by
 * Vendor/ppsspp-ios/build.sh (through CMAKE_C_FLAGS / CMAKE_CXX_FLAGS), and the
 * bridge includes it before libretro.h, so the core and the bridge see the
 * same names.
 *
 * Renaming the entry points is half of the job. PPSSPP also carries its own
 * rcheevos (the app has one), zstd, glslang, SPIRV-Cross (MoltenVK has one),
 * libretro-common (whose retro_vfs_* helpers PCSX and the N64 carry too) and
 * thousands of generic globals; build.sh pre-links the whole core into one
 * object that exports ONLY the names below, so every other symbol becomes
 * private. build.sh reads this file to build that export list: a libretro
 * function missing from here stays private and fails to link from the bridge,
 * loudly, rather than collide silently.
 *
 * The list is every RETRO_API function libretro/libretro.cpp defines (v1.20.4).
 */
#ifndef RETRO_PAL_PSP_SYMBOLS_H
#define RETRO_PAL_PSP_SYMBOLS_H

#define retro_api_version                psp_retro_api_version
#define retro_cheat_reset                psp_retro_cheat_reset
#define retro_cheat_set                  psp_retro_cheat_set
#define retro_deinit                     psp_retro_deinit
#define retro_get_memory_data            psp_retro_get_memory_data
#define retro_get_memory_size            psp_retro_get_memory_size
#define retro_get_region                 psp_retro_get_region
#define retro_get_system_av_info         psp_retro_get_system_av_info
#define retro_get_system_info            psp_retro_get_system_info
#define retro_init                       psp_retro_init
#define retro_load_game                  psp_retro_load_game
#define retro_load_game_special          psp_retro_load_game_special
#define retro_reset                      psp_retro_reset
#define retro_run                        psp_retro_run
#define retro_serialize                  psp_retro_serialize
#define retro_serialize_size             psp_retro_serialize_size
#define retro_set_audio_sample           psp_retro_set_audio_sample
#define retro_set_audio_sample_batch     psp_retro_set_audio_sample_batch
#define retro_set_controller_port_device psp_retro_set_controller_port_device
#define retro_set_environment            psp_retro_set_environment
#define retro_set_input_poll             psp_retro_set_input_poll
#define retro_set_input_state            psp_retro_set_input_state
#define retro_set_video_refresh          psp_retro_set_video_refresh
#define retro_unload_game                psp_retro_unload_game
#define retro_unserialize                psp_retro_unserialize

#endif /* RETRO_PAL_PSP_SYMBOLS_H */
