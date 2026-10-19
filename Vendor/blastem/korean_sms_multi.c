#include "sms.h"

void* super_game_30_write(uint32_t address, void *context, uint8_t value)
{
	z80_context *z80 = context;
	sms_context *sms = z80->system;
	address &= 0xF;
	sms->ram[SMS_RAM_SIZE - 0x10 + address] = value;
	switch (address)
	{
	case 0:
		sms->bank_regs[0] = value;
		sms->bank_regs[1] = 0;
		sms->bank_regs[2] = 1;
		z80->mem_pointers[0] = sms->rom + ((value << 15) & (sms->rom_size-1));
		z80->mem_pointers[1] = sms->rom + (((value << 15) + 0x4000) & (sms->rom_size-1));
		z80->mem_pointers[2] = z80->mem_pointers[0];
		z80_invalidate_code_range(z80, 0, 0xC000);
		break;
	case 0xE:
		value &= 0xF;
		sms->bank_regs[1] = value;
		z80->mem_pointers[1] = sms->rom + (((sms->bank_regs[0] << 15) + (value << 14)) & (sms->rom_size-1));
		z80_invalidate_code_range(z80, 0x4000, 0x8000);
		break;
	case 0xF:
		value &= 0xF;
		sms->bank_regs[2] = value;
		z80->mem_pointers[2] = sms->rom + (((sms->bank_regs[0] << 15) + (value << 14)) & (sms->rom_size-1));
		z80_invalidate_code_range(z80, 0x8000, 0xC000);
		break;
	}
	return context;
}

void super_game_30_init(sms_context *sms)
{
	sms->z80->mem_pointers[0] = sms->rom;
	sms->z80->mem_pointers[1] = sms->rom + (0x4000 & (sms->rom_size - 1));
	sms->z80->mem_pointers[2] = sms->rom;
}

void* super_game_138_write(uint32_t address, void *context, uint8_t value)
{
	z80_context *z80 = context;
	sms_context *sms = z80->system;
	if (address >= 0xC000) {
		sms->ram[address & (SMS_RAM_SIZE-1)] = value;
		z80_invalidate_code_range(z80, address, address + 1);
	}
	switch (address & 0xBFEF)
	{
	case 0xBFE5:
		sms->bank_regs[0] = value;
		sms->bank_regs[1] = sms->bank_regs[2] = 1;
		z80->mem_pointers[0] = sms->rom + ((value << 15) & (sms->rom_size-1));
		z80->mem_pointers[1] = sms->rom + (((value << 15) + 0x4000) & (sms->rom_size-1));
		z80->mem_pointers[2] = z80->mem_pointers[0];
		z80_invalidate_code_range(z80, 0, 0xC000);
		break;
	case 0xBFEE:
		value &= (sms->bank_regs[0] & 0xF0) ? 0x1F : 0x0F;
		sms->bank_regs[1] = value;
		z80->mem_pointers[1] = sms->rom + (((sms->bank_regs[0] << 15) + (value << 14)) & (sms->rom_size-1));
		z80_invalidate_code_range(z80, 0x4000, 0x8000);
		break;
	case 0xBFEF:
		value &= (sms->bank_regs[0] & 0xF0) ? 0x1F : 0x0F;
		sms->bank_regs[2] = value;
		z80->mem_pointers[2] = sms->rom + (((sms->bank_regs[0] << 15) + (value << 14)) & (sms->rom_size-1));
		z80_invalidate_code_range(z80, 0x8000, 0xC000);
		break;
	}
	return context;
}

void super_game_138_init(sms_context *sms)
{
	sms->z80->mem_pointers[0] = sms->rom;
	sms->z80->mem_pointers[1] = sms->rom + (0x4000 & (sms->rom_size - 1));
	sms->z80->mem_pointers[2] = sms->rom;
}
