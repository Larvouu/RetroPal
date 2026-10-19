#include <string.h>
#ifdef DEBUG_DISASM
#include "68kinst.h"
#endif

void m68k_read_8(m68k_context *context)
{
	context->cycles += 4 * context->opts->gen.clock_divider;
#ifdef DEBUG_DISASM
	uint32_t tmp = context->scratch1;
#endif
	uint32_t address = context->scratch1 & context->opts->gen.address_mask;
	uint32_t index = address >> 16;
	context->scratch1 = context->read8[index](address, context, context->read8_data[index]);
#ifdef DEBUG_DISASM
	printf("Read.b %05X: %02X\n", tmp, context->scratch1);
#endif
}

uint16_t m68k_instruction_fetch(uint32_t address, void *vcontext)
{
	m68k_context *context = vcontext;
	return read_word(address, (void **)context->mem_pointers, &context->opts->gen, context);
}

void m68k_read_16(m68k_context *context)
{
	context->cycles += 4 * context->opts->gen.clock_divider;
#ifdef DEBUG_DISASM
	uint32_t tmp = context->scratch1;
#endif
	uint32_t address = context->scratch1 & context->opts->gen.address_mask;
	uint32_t index = address >> 16;
	context->scratch1 = context->read16[index](address, context, context->read16_data[index]);
#ifdef DEBUG_DISASM
	if (tmp == context->pc) {
		m68kinst inst;
		m68k_decode(debug_disasm_fetch, context, &inst, tmp);
		static char disasm_buf[256];
		m68k_disasm(&inst, disasm_buf);
		printf("Fetch %05X: %04X - %s, d0=%X, d1=%X, d2=%X, d3=%X, d4=%X, d6=%X, d7=%X, a3=%X, a7=%X, xflag=%d\n", 
			tmp, context->scratch1, disasm_buf, context->dregs[0], context->dregs[1], context->dregs[2], context->dregs[3], 
			context->dregs[4], context->dregs[6], context->dregs[7], context->aregs[3], context->aregs[7], context->xflag
		);
	} else {
		printf("Read %05X: %04X\n", tmp, context->scratch1);
	}
#endif
}

void m68k_write_8(m68k_context *context)
{
	context->cycles += 4 * context->opts->gen.clock_divider;
	uint32_t address = context->scratch2 & context->opts->gen.address_mask;
	uint32_t index = address >> 16;
	context->write8[index](address, context, context->scratch1, context->write8_data[index]);
#ifdef DEBUG_DISASM
	printf("Write.b %05X: %02X\n", context->scratch2, context->scratch1);
#endif
}

void m68k_rmw_writeback(m68k_context *context)
{
	if (context->opts->gen.flags & M68K_OPT_BROKEN_READ_MODIFY) {
		context->cycles += 4 * context->opts->gen.clock_divider;
	} else {
		m68k_write_8(context);
	}
}

void m68k_write_16(m68k_context *context)
{
	context->cycles += 4 * context->opts->gen.clock_divider;
	int32_t address = context->scratch2 & context->opts->gen.address_mask;
	uint32_t index = address >> 16;
	context->write16[index](address, context, context->scratch1, context->write16_data[index]);
#ifdef DEBUG_DISASM
	printf("Write %05X: %04X\n", context->scratch2, context->scratch1);
#endif
}

void m68k_sync_cycle(m68k_context *context, uint32_t target_cycle)
{
	context->sync_cycle = target_cycle; //why?
	context->sync_components(context, 0);
}

static void divu(m68k_context *context, uint32_t dividend_reg, uint32_t divisor)
{
	uint32_t dividend = context->dregs[dividend_reg];
	uint32_t divisor_shift = divisor << 16;
	uint16_t quotient = 0;
	uint8_t force = 0;
	uint16_t bit = 0;
	uint32_t cycles = 2;
	if (divisor_shift < dividend) {
		context->nflag = 128;
		context->zflag = 0;
		context->vflag = 128;
		context->cycles += 6 * context->opts->gen.clock_divider;
		return;
	}
	for (int i = 0; i < 16; i++)
	{
		force = dividend >> 31;
		quotient = quotient << 1 | bit;
		dividend = dividend << 1;

		if (force || dividend >= divisor_shift) {
			dividend -= divisor_shift;
			cycles += force ? 4 : 6;
			bit = 1;
		} else {
			bit = 0;
			cycles += 8;
		}
	}
	cycles += force ? 6 : bit ? 4 : 2;
	context->cycles += cycles * context->opts->gen.clock_divider;
	quotient = quotient << 1 | bit;
	context->dregs[dividend_reg] = dividend | quotient;
	context->vflag = 0;
	context->nflag = quotient >> 8 & 128;
	context->zflag = quotient == 0;
}

static void divs(m68k_context *context, uint32_t dividend_reg, uint32_t divisor)
{
	uint32_t dividend = context->dregs[dividend_reg];
	uint32_t divisor_shift = divisor << 16;
	uint32_t orig_divisor = divisor_shift, orig_dividend = dividend;
	if (divisor_shift & 0x80000000) {
		divisor_shift = 0 - divisor_shift;
	}

	uint32_t cycles = 8;
	if (dividend & 0x80000000) {
		//dvs10
		dividend = 0 - dividend;
		cycles += 2;
	}
	if (divisor_shift <= dividend) {
		context->vflag = 128;
		context->nflag = 128;
		context->zflag = 0;
		cycles += 4;
		context->cycles += cycles * context->opts->gen.clock_divider;
		return;
	}
	uint16_t quotient = 0;
	uint16_t bit = 0;
	for (int i = 0; i < 15; i++)
	{
		quotient = quotient << 1 | bit;
		dividend = dividend << 1;

		if (dividend >= divisor_shift) {
			dividend -= divisor_shift;
			cycles += 6;
			bit = 1;
		} else {
			bit = 0;
			cycles += 8;
		}
	}
	quotient = quotient << 1 | bit;
	dividend = dividend << 1;
	if (dividend >= divisor_shift) {
		dividend -= divisor_shift;
		quotient = quotient << 1 | 1;
	} else {
		quotient = quotient << 1;
	}
	cycles += 4;

	context->vflag = 0;
	if (orig_divisor & 0x80000000) {
		cycles += 16; //was 10
		if (orig_dividend & 0x80000000) {
			if (quotient & 0x8000) {
				context->vflag = 128;
				context->nflag = 128;
				context->zflag = 0;
				context->cycles += cycles * context->opts->gen.clock_divider;
				return;
			} else {
				dividend = -dividend;
			}
		} else {
			quotient = -quotient;
			if (quotient && !(quotient & 0x8000)) {
				context->vflag = 128;
			}
		}
	} else if (orig_dividend & 0x80000000) {
		cycles += 18; // was 12
		quotient = -quotient;
		if (quotient && !(quotient & 0x8000)) {
			context->vflag = 128;
		} else {
			dividend = -dividend;
		}
	} else {
		cycles += 14; //was 10
		if (quotient & 0x8000) {
			context->vflag= 128;
		}
	}
	if (context->vflag) {
		context->nflag = 128;
		context->zflag = 0;
		context->cycles += cycles * context->opts->gen.clock_divider;
		return;
	}
	context->nflag = (quotient & 0x8000) ? 128 : 0;
	context->zflag = quotient == 0;
	//V was cleared above, C is cleared by the generated machine code
	context->cycles += cycles * context->opts->gen.clock_divider;
	context->dregs[dividend_reg] = dividend | quotient;
}

static sync_fun *sync_comp_tmp;
static int_ack_fun int_ack_tmp;
void init_m68k_opts(m68k_options *opts, memmap_chunk * memmap, uint32_t num_chunks, uint32_t clock_divider, sync_fun *sync_components, int_ack_fun int_ack)
{
	memset(opts, 0, sizeof(*opts));
	opts->gen.memmap = memmap;
	opts->gen.memmap_chunks = num_chunks;
	opts->gen.address_mask = 0xFFFFFF;
	opts->gen.byte_swap = 1;
	opts->gen.max_address = 0x1000000;
	opts->gen.bus_cycles = 4;
	opts->gen.clock_divider = clock_divider;
	opts->gen.mem_ptr_off = offsetof(m68k_context, mem_pointers);
	sync_comp_tmp = sync_components;
	int_ack_tmp = int_ack;
}

m68k_context *init_68k_context(m68k_options * opts, m68k_reset_handler *reset_handler)
{
	m68k_context *context = calloc(1, sizeof(m68k_context));
	context->opts = opts;
	context->reset_handler = reset_handler;
	context->int_cycle = 0xFFFFFFFFU;
	context->int_pending = 255;
	context->sync_components = sync_comp_tmp;
	for (uint32_t i = 0; i < 256; i++)
	{
		context->read16[i] = get_interp_read_16(context, &opts->gen, i << 16, (i + 1) << 16, context->read16_data + i);
		context->read8[i] = get_interp_read_8(context, &opts->gen, i << 16, (i + 1) << 16, context->read8_data + i);
		context->write16[i] = get_interp_write_16(context, &opts->gen, i << 16, (i + 1) << 16, context->write16_data + i);
		context->write8[i] = get_interp_write_8(context, &opts->gen, i << 16, (i + 1) << 16, context->write8_data + i);
	}
	sync_comp_tmp = NULL;
	context->int_ack_handler = int_ack_tmp;
	int_ack_tmp = NULL;
	return context;
}

void m68k_reset(m68k_context *context)
{
	//read initial SP
	context->scratch1 = 0;
	m68k_read_16(context);
	context->aregs[7] = context->scratch1 << 16;
	context->scratch1 = 2;
	m68k_read_16(context);
	context->aregs[7] |= context->scratch1;
	
	//read initial PC
	context->scratch1 = 4;
	m68k_read_16(context);
	context->pc = context->scratch1 << 16;
	context->scratch1 = 6;
	m68k_read_16(context);
	context->pc |= context->scratch1;
	
	context->scratch1 = context->pc;
	m68k_read_16(context);
	context->prefetch = context->scratch1;
	context->pc += 2;
	
	context->status = 0x27;
}

void m68k_print_regs(m68k_context *context)
{
	printf("XNZVC\n%d%d%d%d%d\n", context->xflag != 0, context->nflag != 0, context->zflag != 0, context->vflag != 0, context->cflag != 0);
	for (int i = 0; i < 8; i++) {
		printf("d%d: %X\n", i, context->dregs[i]);
	}
	for (int i = 0; i < 8; i++) {
		printf("a%d: %X\n", i, context->aregs[i]);
	}
}

void m68k_serialize(m68k_context *context, uint32_t pc, serialize_buffer *buf)
{
	for (int i = 0; i < 8; i++)
	{
		save_int32(buf, context->dregs[i]);
	}
	for (int i = 0; i < 8; i++)
	{
		save_int32(buf, context->aregs[i]);
	}
	save_int32(buf, context->other_sp);
	//old core saves the address of hte instruction that will execute upon resume
	//in this field so we need to adjust PC here for compatibility
	save_int32(buf, context->pc - 2);
	uint16_t sr = context->status << 8;
	if (context->xflag) { sr |= 0x10; }
	if (context->nflag) { sr |= 0x08; }
	if (context->zflag) { sr |= 0x04; }
	if (context->vflag) { sr |= 0x02; }
	if (context->cflag) { sr |= 0x1; }
	save_int16(buf, sr);
	save_int32(buf, context->cycles);
	save_int32(buf, context->int_cycle);
	save_int8(buf, context->int_priority); //int_num on old core, but it's the priority level
	save_int8(buf, context->int_pending);
	save_int8(buf, context->trace_pending);
	//remaining fields have no equivalent in old core
	save_int16(buf, context->prefetch);
	save_int8(buf, context->stopped);
	save_int8(buf, context->int_num);
	save_int8(buf, context->int_pending_num);
}

void m68k_deserialize(deserialize_buffer *buf, void *vcontext)
{
	m68k_context *context = vcontext;
	for (int i = 0; i < 8; i++)
	{
		context->dregs[i] = load_int32(buf);
	}
	for (int i = 0; i < 8; i++)
	{
		context->aregs[i] = load_int32(buf);
	}
	context->other_sp = load_int32(buf);
	context->pc = load_int32(buf);
	uint16_t sr = load_int16(buf);
	context->status = sr >> 8;
	context->xflag = sr & 0x10;
	context->nflag = sr & 0x08;
	context->zflag = sr & 0x04;
	context->vflag = sr & 0x02;
	context->cflag = sr & 0x01;
	context->cycles = load_int32(buf);
	context->int_cycle = load_int32(buf);
	context->int_priority = load_int8(buf); //int_num on old core, but it's the priority level
	context->int_pending = load_int8(buf);
	context->trace_pending = load_int8(buf);
	if (buf->cur_pos < buf->size) {
		context->prefetch = load_int16(buf);
		context->stopped = load_int8(buf);
		context->int_num = load_int8(buf);
		context->int_pending_num = load_int8(buf);
	} else {
		context->prefetch = read_word(context->pc, (void**)context->mem_pointers, &context->opts->gen, context);
		context->stopped = 0;
		context->int_num = context->int_pending_num = 0;
	}
	//adjust for compatibility with old core
	context->pc += 2;
}

void start_68k_context(m68k_context *context, uint32_t pc)
{
	context->scratch1 = context->pc = pc;
	m68k_read_16(context);
	context->prefetch = context->scratch1;
	context->pc += 2;
}

void insert_breakpoint(m68k_context *context, uint32_t address, debug_handler handler)
{
	char buf[6];
	address &= context->opts->gen.address_mask;
	tern_int_key(address, buf);
	//tern_insert_ptr assumes that any existing value is heap allocated and that it's
	//safe to call free on it to avoid leaking. That isn't the case here, so delete explicitly
	tern_delete(&context->breakpoints, buf, NULL);
	context->breakpoints = tern_insert_ptr(context->breakpoints, buf, handler);
}

void remove_breakpoint(m68k_context *context, uint32_t address)
{
	char buf[6];
	address &= context->opts->gen.address_mask;
	tern_delete(&context->breakpoints, tern_int_key(address, buf), NULL);
}
