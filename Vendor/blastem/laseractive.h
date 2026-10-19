#ifndef LASERACTIVE_H_
#define LASERACTIVE_H_

#include "pd0178.h"
#include "upd78k2.h"

typedef struct {
	system_header   header;
	upd78k2_context *upd;
	pd0178          mecha;
	uint32_t        ir_counter;
	uint32_t        pd0093a_buffer_pos;
	uint16_t        ir_code;
	uint16_t        ir_hold;
	uint8_t         upd_pram[768];
	uint8_t         upd_rom[0xE000]; //ROM is actually 64K, but only first 56K are mapped in
	uint8_t         pd0093a_buffer[256];
	uint8_t         pd0093a_expect_offset;
} laseractive;

laseractive *alloc_laseractive(system_media *media, uint32_t opts);

#endif //LASERACTIVE_H_
