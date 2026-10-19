#include "genesis.h"
#include "util.h"

uint16_t read_sram_w(uint32_t address, m68k_context * context)
{
	genesis_context * gen = context->system;
	address &= gen->save_ram_mask;
	uint16_t *word_storage = (uint16_t *)gen->save_storage;
	switch(gen->save_type)
	{
	case RAM_FLAG_BOTH:
		return word_storage[address >> 1];
	case RAM_FLAG_EVEN:
		return gen->save_storage[address >> 1] << 8 | 0xFF;
	case RAM_FLAG_ODD:
		return gen->save_storage[address >> 1] | 0xFF00;
	}
	return 0xFFFF;//We should never get here
}

uint16_t s32x_read_sram_w(uint32_t address, void * vcontext)
{
	m68k_context * context = vcontext;
	genesis_context * gen = context->system;
	s32x *mars = gen->mars;
	if (mars->regs[S32X_ADAPT_CTRL] & BIT_ADEN_M68K) {
		//32X hardware enabled
		if (!(mars->regs[S32X_DREQ_CTRL] & BIT_DREQ_RV)) {
			//cart is mapped high
			return 0xFFFF; // probably should return vector table
		}
	}
	return read_sram_w(address, context);
}

uint16_t s32x_read_bankable_w(uint32_t address, void * vcontext)
{
	m68k_context * context = vcontext;
	genesis_context * gen = context->system;
	s32x *mars = gen->mars;
	if (mars->regs[S32X_ADAPT_CTRL] & BIT_ADEN_M68K) {
		//32X hardware enabled
		if (!(mars->regs[S32X_DREQ_CTRL] & BIT_DREQ_RV)) {
			//cart is mapped high
			return read_sram_w(address, context);
		}
	}
	return 0xFFFF; // probably should return vector table
}

uint8_t read_sram_b(uint32_t address, m68k_context * context)
{
	genesis_context * gen = context->system;
	address &= gen->save_ram_mask;
	switch(gen->save_type)
	{
	case RAM_FLAG_BOTH:
		return gen->save_storage[address ^ 1];
	case RAM_FLAG_EVEN:
		if (address & 1) {
			return 0xFF;
		} else {
			return gen->save_storage[address >> 1];
		}
	case RAM_FLAG_ODD:
		if (address & 1) {
			return gen->save_storage[address >> 1];
		} else {
			return 0xFF;
		}
	}
	return 0xFF;//We should never get here
}

uint8_t s32x_read_sram_b(uint32_t address, void * vcontext)
{
	m68k_context * context = vcontext;
	genesis_context * gen = context->system;
	s32x *mars = gen->mars;
	if (mars->regs[S32X_ADAPT_CTRL] & BIT_ADEN_M68K) {
		//32X hardware enabled
		if (!(mars->regs[S32X_DREQ_CTRL] & BIT_DREQ_RV)) {
			//cart is mapped high
			return 0xFF; // probably should return vector table
		}
	}
	return read_sram_b(address, context);
}

uint8_t s32x_read_bankable_b(uint32_t address, void * vcontext)
{
	m68k_context * context = vcontext;
	genesis_context * gen = context->system;
	s32x *mars = gen->mars;
	if (mars->regs[S32X_ADAPT_CTRL] & BIT_ADEN_M68K) {
		//32X hardware enabled
		if (!(mars->regs[S32X_DREQ_CTRL] & BIT_DREQ_RV)) {
			//cart is mapped high
			return read_sram_b(address, context);
		}
	}
	return 0xFF; // probably should return vector table
}

m68k_context * write_sram_area_w(uint32_t address, m68k_context * context, uint16_t value)
{
	genesis_context * gen = context->system;
	if (gen->mapper_type == MAPPER_SEGA_MED_V2) {
		if (gen->bank_regs[8] & 0x20) {
			uint32_t bank = address >> 19;
			address &= 0x7FFFF;
			context->mem_pointers[gen->mapper_start_index + bank][address >> 1] = value;
		}
		return context;
	}
	if ((gen->bank_regs[0] & 0x3) == 1) {
		uint16_t *word_storage = (uint16_t *)gen->save_storage;
		address &= gen->save_ram_mask;
		switch(gen->save_type)
		{
		case RAM_FLAG_BOTH:
			word_storage[address >> 1] = value;
			break;
		case RAM_FLAG_EVEN:
			gen->save_storage[address >> 1] = value >> 8;
			break;
		case RAM_FLAG_ODD:
			gen->save_storage[address >> 1] = value;
			break;
		}
	}
	return context;
}

void *s32x_write_sram_area_w(uint32_t address, void *vcontext, uint16_t value)
{
	m68k_context *context = vcontext;
	genesis_context * gen = context->system;
	s32x *mars = gen->mars;
	if (mars->regs[S32X_ADAPT_CTRL] & BIT_ADEN_M68K) {
		//32X hardware enabled
		if (!(mars->regs[S32X_DREQ_CTRL] & BIT_DREQ_RV)) {
			//cart is mapped high
			return vcontext;
		}
	}
	return write_sram_area_w(address, context, value);
}

void *s32x_write_bankable_w(uint32_t address, void *vcontext, uint16_t value)
{
	m68k_context *context = vcontext;
	genesis_context * gen = context->system;
	s32x *mars = gen->mars;
	if (mars->regs[S32X_ADAPT_CTRL] & BIT_ADEN_M68K) {
		//32X hardware enabled
		if (!(mars->regs[S32X_DREQ_CTRL] & BIT_DREQ_RV)) {
			//cart is mapped high
			if ((mars->regs[S32X_CART_BANK] & S32X_BANK_MASK) >= 2) {
				return write_sram_area_w(address, context, value);
			}
		}
	}
	return vcontext;
}


m68k_context * write_sram_area_b(uint32_t address, m68k_context * context, uint8_t value)
{
	genesis_context * gen = context->system;
	if ((gen->bank_regs[0] & 0x3) == 1) {
		address &= gen->save_ram_mask;
		switch(gen->save_type)
		{
		case RAM_FLAG_BOTH:
			gen->save_storage[address ^ 1] = value;
			break;
		case RAM_FLAG_EVEN:
			if (!(address & 1)) {
				gen->save_storage[address >> 1] = value;
			}
			break;
		case RAM_FLAG_ODD:
			if (address & 1) {
				gen->save_storage[address >> 1] = value;
			}
			break;
		}
	}
	return context;
}

void *s32x_write_sram_area_b(uint32_t address, void *vcontext, uint8_t value)
{
	m68k_context *context = vcontext;
	genesis_context * gen = context->system;
	s32x *mars = gen->mars;
	if (mars->regs[S32X_ADAPT_CTRL] & BIT_ADEN_M68K) {
		//32X hardware enabled
		if (!(mars->regs[S32X_DREQ_CTRL] & BIT_DREQ_RV)) {
			//cart is mapped high
			return vcontext;
		}
	}
	return write_sram_area_b(address, context, value);
}

void *s32x_write_bankable_b(uint32_t address, void *vcontext, uint8_t value)
{
	m68k_context *context = vcontext;
	genesis_context * gen = context->system;
	s32x *mars = gen->mars;
	if (mars->regs[S32X_ADAPT_CTRL] & BIT_ADEN_M68K) {
		//32X hardware enabled
		if (!(mars->regs[S32X_DREQ_CTRL] & BIT_DREQ_RV)) {
			//cart is mapped high
			if ((mars->regs[S32X_CART_BANK] & S32X_BANK_MASK) >= 2) {
				return write_sram_area_b(address, context, value);
			}
		}
	}
	return vcontext;
}

static void* write_med_ram_w(uint32_t address, void *vcontext, uint16_t value, uint16_t bank)
{
	m68k_context *context = vcontext;
	genesis_context * gen = context->system;
	if (gen->bank_regs[8] & 0x20) {
		context->mem_pointers[gen->mapper_start_index + bank][address >> 1] = value;
		address += bank * 0x80000;
		m68k_invalidate_code_range(gen->m68k, address, address + 2);
	}
	return vcontext;
}

void* write_med_ram0_w(uint32_t address, void *vcontext, uint16_t value)
{
	return write_med_ram_w(address, vcontext, value, 0);
}

void* write_med_ram1_w(uint32_t address, void *vcontext, uint16_t value)
{
	return write_med_ram_w(address, vcontext, value, 1);
}

void* write_med_ram2_w(uint32_t address, void *vcontext, uint16_t value)
{
	return write_med_ram_w(address, vcontext, value, 2);
}

void* write_med_ram3_w(uint32_t address, void *vcontext, uint16_t value)
{
	return write_med_ram_w(address, vcontext, value, 3);
}

void* write_med_ram4_w(uint32_t address, void *vcontext, uint16_t value)
{
	return write_med_ram_w(address, vcontext, value, 4);
}

void* write_med_ram5_w(uint32_t address, void *vcontext, uint16_t value)
{
	return write_med_ram_w(address, vcontext, value, 5);
}

void* write_med_ram6_w(uint32_t address, void *vcontext, uint16_t value)
{
	return write_med_ram_w(address, vcontext, value, 6);
}

void* write_med_ram7_w(uint32_t address, void *vcontext, uint16_t value)
{
	return write_med_ram_w(address, vcontext, value, 7);
}

static void* write_med_ram_b(uint32_t address, void *vcontext, uint8_t value, uint16_t bank)
{
	m68k_context *context = vcontext;
	genesis_context * gen = context->system;
	if (gen->bank_regs[8] & 0x20) {
		((uint8_t*)context->mem_pointers[gen->mapper_start_index + bank])[address ^ 1] = value;
		address += bank * 0x80000;
		m68k_invalidate_code_range(gen->m68k, address, address + 1);
	}
	return vcontext;
}

void* write_med_ram0_b(uint32_t address, void *vcontext, uint8_t value)
{
	return write_med_ram_b(address, vcontext, value, 0);
}

void* write_med_ram1_b(uint32_t address, void *vcontext, uint8_t value)
{
	return write_med_ram_b(address, vcontext, value, 1);
}

void* write_med_ram2_b(uint32_t address, void *vcontext, uint8_t value)
{
	return write_med_ram_b(address, vcontext, value, 2);
}

void* write_med_ram3_b(uint32_t address, void *vcontext, uint8_t value)
{
	return write_med_ram_b(address, vcontext, value, 3);
}

void* write_med_ram4_b(uint32_t address, void *vcontext, uint8_t value)
{
	return write_med_ram_b(address, vcontext, value, 4);
}

void* write_med_ram5_b(uint32_t address, void *vcontext, uint8_t value)
{
	return write_med_ram_b(address, vcontext, value, 5);
}

void* write_med_ram6_b(uint32_t address, void *vcontext, uint8_t value)
{
	return write_med_ram_b(address, vcontext, value, 6);
}

void* write_med_ram7_b(uint32_t address, void *vcontext, uint8_t value)
{
	return write_med_ram_b(address, vcontext, value, 7);
}

m68k_context * write_bank_reg_w(uint32_t address, m68k_context * context, uint16_t value)
{
	genesis_context * gen = context->system;
	if (gen->mapper_type == MAPPER_SEGA_MED_V2 && (address & 0xF0) < 0xF0) {
		// ignore writes to other MED extended registers for now
		return context;
	}
	address &= 0xE;
	address >>= 1;
	if (!address) {
		if (gen->mapper_type == MAPPER_SEGA_MED_V2) {
			if (!(value & 0x8000)) {
				//writes without protection bit set are ignored
				return context;
			}
			gen->bank_regs[8] = value >> 8;
			void *new_ptr = gen->cart + 0x40000*(value & 0x1F);
			if (context->mem_pointers[gen->mapper_start_index] != new_ptr) {
				m68k_invalidate_code_range(gen->m68k, 0, 0x80000);
				context->mem_pointers[gen->mapper_start_index] = new_ptr;
			}
		} else if (value & 1) {
			//Used for games that only use the mapper for SRAM
			if (context->mem_pointers[gen->mapper_start_index]) {
				gen->mapper_temp = context->mem_pointers[gen->mapper_start_index];
			}
			context->mem_pointers[gen->mapper_start_index] = NULL;
			//For games that need more than 4MB
			for (int i = 4; i < 8; i++)
			{
				context->mem_pointers[gen->mapper_start_index + i] = NULL;
			}
		} else {
			//Used for games that only use the mapper for SRAM
			if (!context->mem_pointers[gen->mapper_start_index]) {
				context->mem_pointers[gen->mapper_start_index] = gen->mapper_temp;
			}
			//For games that need more than 4MB
			for (int i = 4; i < 8; i++)
			{
				context->mem_pointers[gen->mapper_start_index + i] = gen->cart + 0x40000*gen->bank_regs[i];
			}
		}
	} else if (gen->mapper_type != MAPPER_SEGA_SRAM) {
		uint32_t mask = ((gen->mapper_type == MAPPER_SEGA_MED_V2 ? (16 *1024 * 1024) : nearest_pow2(gen->header.info.rom_size)) >> 1) - 1;
		void *new_ptr = gen->cart + ((0x40000*value) & mask);
		if (context->mem_pointers[gen->mapper_start_index + address] != new_ptr) {
			m68k_invalidate_code_range(gen->m68k, address * 0x80000, (address + 1) * 0x80000);
			context->mem_pointers[gen->mapper_start_index + address] = new_ptr;
		}
	}
	gen->bank_regs[address] = value;
	return context;
}

m68k_context * write_bank_reg_b(uint32_t address, m68k_context * context, uint8_t value)
{
	genesis_context * gen = context->system;
	if (gen->mapper_type == MAPPER_SEGA_MED_V2) {
		if ((address & 0xFF) == 0xF0) {
			write_bank_reg_w(address, context, value << 8 | gen->bank_regs[0]);
		} else if (address > 2 && (address & 1)) {
			write_bank_reg_w(address, context, value);
		}
	} else if (address & 1) {
		write_bank_reg_w(address, context, value);
	}
	return context;
}

void *s32x_write_bank_reg_w(uint32_t address, void *vcontext, uint16_t value)
{
	m68k_context *context = vcontext;
	genesis_context *gen = context->system;
	s32x *mars = gen->mars;
	address &= 0xE;
	address >>= 1;
	gen->bank_regs[address] = value;
	if (address) {
		//TODO: implement full sega mapper/MED extension for 32X
		return vcontext;
	}
	uint8_t cart_mapped_high = (mars->regs[S32X_ADAPT_CTRL] & BIT_ADEN_M68K) && !(mars->regs[S32X_DREQ_CTRL] & BIT_DREQ_RV);
	if (cart_mapped_high && (mars->regs[S32X_CART_BANK] & S32X_BANK_MASK) < 2) {
		//SRAM area not currently mapped, nothing to do 
		return vcontext;
	}
	uint16_t start_index = cart_mapped_high ? gen->mapper_start_index - 1 : gen->mapper_start_index;
	if (value & 1) {
		//Used for games that only use the mapper for SRAM
		if (context->mem_pointers[start_index]) {
			gen->mapper_temp = context->mem_pointers[start_index];				
			context->mem_pointers[start_index] = NULL;
		}
	} else {
		//Used for games that only use the mapper for SRAM
		if (!context->mem_pointers[start_index]) {
			context->mem_pointers[start_index] = gen->mapper_temp;
			gen->mapper_temp = NULL;
		}
	}
	return vcontext;
}

void *s32x_write_bank_reg_b(uint32_t address, void *vcontext, uint8_t value)
{
	if (!(address & 1)) {
		return vcontext;
	}
	return s32x_write_bank_reg_w(address, vcontext, value);
}

uint16_t med_reg_read_w(uint32_t address, void *vcontext)
{
	m68k_context *context = vcontext;
	switch (address & 0xFE)
	{
	case 0xE4:
		//ensure USB serial read returns "not-ready" status
		return 0x02;
	default:
#ifdef NEW_CORE
		return context->prefetch;
#else
		return read_word(context->last_prefetch_address, (void **)context->mem_pointers, &context->opts->gen, context);
#endif
	}
}

uint8_t med_reg_read_b(uint32_t address, void *vcontext)
{
	uint16_t value = med_reg_read_w(address, vcontext);
	if (address & 1) {
		return value;
	}
	return value >> 8;
}

void sega_mapper_serialize(genesis_context *gen, serialize_buffer *buf)
{
	save_buffer8(buf, gen->bank_regs, gen->mapper_type == MAPPER_SEGA_MED_V2 ? sizeof(gen->bank_regs) : sizeof(gen->bank_regs) - 1);
}

void sega_mapper_deserialize(deserialize_buffer *buf, genesis_context *gen)
{
	if (gen->mapper_type == MAPPER_SEGA_MED_V2) {
		uint16_t reg0 = load_int8(buf);
		for (int i = 1; i < sizeof(gen->bank_regs) - 1; i++)
		{
			write_bank_reg_w(i * 2, gen->m68k, load_int8(buf));
		}
		reg0 |= load_int8(buf) << 8;
		write_bank_reg_w(0, gen->m68k, reg0);
	} else {
		for (int i = 0; i < sizeof(gen->bank_regs) - 1; i++)
		{
			write_bank_reg_w(i * 2, gen->m68k, load_int8(buf));
		}
	}
}
