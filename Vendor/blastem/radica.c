#include "genesis.h"
#include "util.h"

static void radica_set_map_always(m68k_context *m68k, uint8_t mapper_value, genesis_context *gen)
{
	gen->bank_regs[0] = mapper_value;
	uint32_t address_or = mapper_value << 15;
	/*
		Properly matching hardware behavior would require 64 different bank pointers using my banking setup
		This feels rather excessive given the limited way this mapper is used in practice
		The following setup is a decent approximation and only requires 12
		
		000000 -> 64KB
		010000 -> 64KB
		020000 -> 128KB
		040000 -> 256KB
		080000 -> 512KB
		100000 -> 1MB
		200000 -> 1MB
		300000 -> 512KB
		380000 -> 256KB
		3C0000 -> 128KB
		3E0000 -> 64KB
		3F0000 -> 64KB
	*/
	uint32_t bank_size = 64 * 1024;
	uint32_t rom_size = nearest_pow2(gen->header.info.rom_size);
	uint8_t *rom = gen->header.info.rom;
	for (uint32_t bank_offset = 0, i = gen->mapper_start_index; bank_offset < 0x400000; bank_offset += bank_size, i++)
	{
		if (bank_offset > 0x10000 && bank_offset <= 0x100000) {
			bank_size += bank_size;
		} else if (bank_offset > 0x200000 && bank_offset < 0x3F0000) {
			bank_size >>= 1;
		}
		uint32_t rom_offset = (bank_offset | address_or);
		if (rom_offset > rom_size || rom_size - rom_offset < bank_size) {
			rom_offset = rom_size - bank_size;
		}
		m68k->mem_pointers[i] = (uint16_t *)(rom + rom_offset);
	}
	m68k_invalidate_code_range(m68k, 0, 0x400000);
}

static void radica_set_map(m68k_context *m68k, uint8_t mapper_value)
{
	genesis_context *gen = m68k->system;
	if (mapper_value == gen->bank_regs[0]) {
		return;
	}
	radica_set_map_always(m68k, mapper_value, gen);
}

void radica_reset(genesis_context *gen)
{
	radica_set_map_always(gen->m68k, 0, gen);
}

void radica_serialize(genesis_context *gen, serialize_buffer *buf)
{
	save_int8(buf, gen->bank_regs[0]);
	for (uint32_t i = 0; i < gen->m68k->opts->gen.memmap_chunks; i++)
	{
		if (gen->m68k->opts->gen.memmap[i].start == 0xA14444) {
			uint16_t *buffer = gen->m68k->opts->gen.memmap[i].buffer;
			save_int16(buf, *buffer);
			break;
		}
	}
}

void radica_deserialize(deserialize_buffer *buf, genesis_context *gen)
{
	gen->bank_regs[0] = (load_int8(buf)) & 0x7E;
	for (uint32_t i = 0; i < gen->m68k->opts->gen.memmap_chunks; i++)
	{
		if (gen->m68k->opts->gen.memmap[i].start == 0xA14444) {
			uint16_t *buffer = gen->m68k->opts->gen.memmap[i].buffer;
			*buffer = load_int16(buf);
			break;
		}
	}
	radica_set_map_always(gen->m68k, gen->bank_regs[0], gen);
}

static void radica_access(uint32_t address, void *context)
{
	m68k_context *m68k = context;
	radica_set_map(m68k, address & 0x7E);
}

void *radica_write_b(uint32_t address, void *context, uint8_t value)
{
	radica_access(address, context);
	return context;
}

void *radica_write_w(uint32_t address, void *context, uint16_t value)
{
	radica_access(address, context);
	return context;
}

uint8_t radica_read_b(uint32_t address, void *context)
{
	radica_access(address, context);
	return 0xFF;
}

uint16_t radica_read_w(uint32_t address, void *context)
{
	radica_access(address, context);
	return 0xFFFF;
}
