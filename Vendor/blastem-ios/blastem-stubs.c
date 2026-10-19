// Three functions BlastEm's libretro build calls and never defines.
//
// They belong to the standalone emulator's own UI: the oscilloscope window
// (oscilloscope.c) and the VDP debug windows (nuklear_ui/debug_ui.c), neither
// of which is part of the library objects (LIBOBJS in the Makefile). Every
// call site is unreachable from a libretro frontend: the sound chips call the
// scope only when one was attached, which only the standalone UI does, and the
// VDP opens a debug window only from its debugger. RetroArch loads cores with
// lazy binding, so upstream never meets the missing names; a static link into
// the app resolves every name at build time and fails on them.
//
// So these are the definitions a frontend without those windows needs, and
// they do nothing. Same signatures as oscilloscope.h and debug_ui.h.

#include <stdint.h>

typedef struct oscilloscope oscilloscope;
typedef void (*window_close_handler)(uint8_t which);

uint8_t scope_add_channel(oscilloscope *scope, const char *name, uint32_t sample_rate)
{
	(void)scope; (void)name; (void)sample_rate;
	return 0;
}

void scope_add_sample(oscilloscope *scope, uint8_t channel, int16_t value, uint8_t trigger)
{
	(void)scope; (void)channel; (void)value; (void)trigger;
}

uint8_t debug_create_window(uint8_t debug_type, char *caption, uint32_t width, uint32_t height, window_close_handler close_handler)
{
	(void)debug_type; (void)caption; (void)width; (void)height; (void)close_handler;
	return 0;
}
