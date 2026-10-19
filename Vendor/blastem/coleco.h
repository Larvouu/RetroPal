#ifndef COLECO_H_
#define COLECO_H_

#include "system.h"
#include "vdp.h"
#include "psg.h"
#ifdef NEW_CORE
#include "z80.h"
#else
#include "z80_to_x86.h"
#endif

#define COLECO_BIOS_SIZE (8 * 1024)
#define COLECO_RAM_SIZE (1 * 1024)

typedef struct {
	system_header header;
	z80_context   *z80;
	vdp_context   *vdp;
	psg_context   *psg;
	uint8_t       *rom;
	uint32_t      rom_size;
	uint32_t      normal_clock;
	uint32_t      master_clock;
	uint32_t      last_frame;
	uint8_t       ram[COLECO_RAM_SIZE];
	uint8_t       bios[COLECO_BIOS_SIZE];
	uint8_t       controller_state[4];
	uint8_t       controller_select;
	uint8_t       should_return;
} coleco_context;

coleco_context *alloc_configure_coleco(system_media *media);

#endif //COLECO_H_
