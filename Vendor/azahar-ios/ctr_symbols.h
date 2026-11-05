/*
 * Renames the libretro API of the 3DS core (Azahar's own libretro core,
 * src/citra_libretro), so it can live in the same binary as PCSX-ReARMed,
 * Mupen64Plus-Next, BlastEm and PPSSPP.
 *
 * All of them are libretro cores linked statically into the app, and all
 * define retro_run, retro_init and the rest under the same names. This core's
 * entry points get a ctr_ prefix (CTR is the 3DS's own hardware code name), as
 * n64_symbols.h, md_symbols.h and psp_symbols.h do. The header is
 * force-included into every translation unit of the core by
 * Vendor/azahar-ios/build.sh (through CMAKE_C_FLAGS / CMAKE_CXX_FLAGS), and the
 * bridge includes it before libretro.h, so the core and the bridge see the
 * same names.
 *
 * Renaming the entry points is half of the job. Azahar also carries its own
 * glslang, SPIRV-Tools, zstd, fmt, boost, cryptopp, libressl, libretro-common
 * (whose helpers PCSX, the N64 and the PSP carry too) and thousands of generic
 * globals; build.sh pre-links the whole core into one object that exports ONLY
 * the names below, so every other symbol becomes private. build.sh reads this
 * file to build that export list: a libretro function missing from here stays
 * private and fails to link from the bridge, loudly, rather than collide
 * silently.
 *
 * The list is every RETRO_API function src/citra_libretro defines, the same 25
 * as its own export list for Apple, libretro.osx.def (2127.0-alpha2), and the
 * two a rewind uses, which patch 0014 adds (retro_ctr_rewind_capture and
 * retro_ctr_rewind_restore: the state without its compression).
 */
#ifndef RETRO_PAL_CTR_SYMBOLS_H
#define RETRO_PAL_CTR_SYMBOLS_H

#define retro_api_version                ctr_retro_api_version
#define retro_cheat_reset                ctr_retro_cheat_reset
#define retro_cheat_set                  ctr_retro_cheat_set
#define retro_ctr_rewind_capture         ctr_retro_ctr_rewind_capture
#define retro_ctr_rewind_restore         ctr_retro_ctr_rewind_restore
#define retro_deinit                     ctr_retro_deinit
#define retro_get_memory_data            ctr_retro_get_memory_data
#define retro_get_memory_size            ctr_retro_get_memory_size
#define retro_get_region                 ctr_retro_get_region
#define retro_get_system_av_info         ctr_retro_get_system_av_info
#define retro_get_system_info            ctr_retro_get_system_info
#define retro_init                       ctr_retro_init
#define retro_load_game                  ctr_retro_load_game
#define retro_load_game_special          ctr_retro_load_game_special
#define retro_reset                      ctr_retro_reset
#define retro_run                        ctr_retro_run
#define retro_serialize                  ctr_retro_serialize
#define retro_serialize_size             ctr_retro_serialize_size
#define retro_set_audio_sample           ctr_retro_set_audio_sample
#define retro_set_audio_sample_batch     ctr_retro_set_audio_sample_batch
#define retro_set_controller_port_device ctr_retro_set_controller_port_device
#define retro_set_environment            ctr_retro_set_environment
#define retro_set_input_poll             ctr_retro_set_input_poll
#define retro_set_input_state            ctr_retro_set_input_state
#define retro_set_video_refresh          ctr_retro_set_video_refresh
#define retro_unload_game                ctr_retro_unload_game
#define retro_unserialize                ctr_retro_unserialize

#endif /* RETRO_PAL_CTR_SYMBOLS_H */
