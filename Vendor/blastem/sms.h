#ifndef SMS_H_
#define SMS_H_

#include "system.h"
#include "vdp.h"
#include "psg.h"
#ifdef NEW_CORE
#include "z80.h"
#else
#include "z80_to_x86.h"
#endif
#include "io.h"
#include "i8255.h"
#include "wave.h"

#define SMS_RAM_SIZE (8*1024)
#define SMS_CART_RAM_SIZE (32*1024)

typedef struct {
	system_header header;
	z80_context   *z80;
	vdp_context   *vdp;
	psg_context   *psg;
	sega_io       io;
	i8255         *i8255;
	uint16_t      *keystate;
	uint8_t       *rom;
	system_media  *cassette;
	uint32_t      rom_size;
	uint32_t      master_clock;
	uint32_t      normal_clock;
	uint32_t      last_frame;
	uint32_t      last_paste_cycle;
	uint8_t       should_return;
	uint8_t       start_button_region;
	uint8_t       ram[SMS_RAM_SIZE];
	uint8_t       bank_regs[4];
	uint8_t       cart_ram[SMS_CART_RAM_SIZE];
	uint8_t       kb_mux;
	uint8_t       paste_toggle;
	uint8_t       paste_state;
	uint8_t       cassette_state;
	uint32_t      cassette_offset;
	uint32_t      cassette_cycle;
	wave_header   cassette_wave;
} sms_context;

sms_context *alloc_configure_sms(system_media *media, system_type stype, uint32_t opts, uint8_t force_region);

#endif //SMS_H_
