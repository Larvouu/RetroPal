#include "genesis.h"

void* sft_wukong_write_b(uint32_t address, void *context, uint8_t value)
{
	if (!(address & 1)) {
		return context;
	}
	m68k_context *m68k = context;
	genesis_context *gen = m68k->system;
	printf("wukong mapper write: %X - %X\n", address, value);
	uint16_t *old = m68k->mem_pointers[gen->mapper_start_index];
	if (value & 0x80) {
		m68k->mem_pointers[gen->mapper_start_index] = gen->cart;
	} else {
		m68k->mem_pointers[gen->mapper_start_index] = gen->cart + 1 * 1024 * 1024;
	}
	if (old != m68k->mem_pointers[gen->mapper_start_index]) {
		m68k_invalidate_code_range(m68k, 0x200000, 0x3C0000);
	}

	return context;
}

void* sft_wukong_write_w(uint32_t address, void *context, uint16_t value)
{
	return sft_wukong_write_b(address | 1, context, value);
}
