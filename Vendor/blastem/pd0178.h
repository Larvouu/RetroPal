#ifndef PD0178_H_
#define PD0178_H_

#include <stdint.h>
#include "system.h"

typedef struct {
	system_media *media;
	uint32_t     cycle;
	uint32_t     next_shake;
	uint32_t     shake_high;
	uint32_t     head_pba;
	uint32_t     seek_pba;
	uint32_t     pause_pba;
	uint8_t      cmd[12];
	uint8_t      status[12];
	uint8_t      comm_index;
	uint8_t      shake;
} pd0178;

void pd0178_init(pd0178 *mecha, system_media *media);
uint8_t pd0178_transfer_byte(pd0178 *mecha, uint8_t to_mecha);
void pd0178_run(pd0178 *mecha, uint32_t to_cycle);
void pd0178_shake_high(pd0178 *mecha);

#endif //PD0178_H_
