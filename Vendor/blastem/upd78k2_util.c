#include <string.h>

//#define TIMER_DEBUG
//#define FETCH_DEBUG
void upd78k2_read_8(upd78k2_context *upd)
{
#ifdef FETCH_DEBUG
	uint32_t tmp = upd->scratch1;
#endif
	upd->scratch1 = read_byte(upd->scratch1, (void **)upd->mem_pointers, &upd->opts->gen, upd);
#ifdef FETCH_DEBUG
	if (tmp == upd->pc) {
		printf("uPD78K/II fetch %04X: %02X, AX=%02X%02X BC=%02X%02X DE=%02X%02X HL=%02X%02X SP=%04X\n", tmp, upd->scratch1,
			upd->main[1], upd->main[0], upd->main[3], upd->main[2], upd->main[5], upd->main[4], upd->main[7], upd->main[6], upd->sp);
	}
#endif
	//FIXME: cycle count
	upd->cycles += 2 * upd->opts->gen.clock_divider;
}

void upd78k2_write_8(upd78k2_context *upd)
{
	write_byte(upd->scratch2, upd->scratch1, (void **)upd->mem_pointers, &upd->opts->gen, upd);
	//FIXME: cycle count
	upd->cycles += 2 * upd->opts->gen.clock_divider;
}

#define CE0 0x08
#define CE1 0x08
#define CIF00 0x0010
#define CIF01 0x0020
#define CIF10 0x0040
#define CIF11 0x0080
#define CSIIF 0x8000

void upd78k2_update_timer0(upd78k2_context *upd)
{
	uint32_t diff = (upd->cycles - upd->tm0_cycle) / upd->opts->gen.clock_divider;
	upd->tm0_cycle += (diff & ~0xF) * upd->opts->gen.clock_divider;
	diff >>= 4;
	if (upd->tmc0 & CE0) {
		uint32_t tmp = upd->tm0 + diff;
		uint32_t cr00 = upd->cr00 | (tmp > 0xFFFF ? 0x10000 : 0);
		uint32_t cr01 = upd->cr01 | (tmp > 0xFFFF ? 0x10000 : 0);
		//TODO: the rest of the CR00/CR01 stuff
		if (upd->tm0 < cr00 && tmp >= cr00) {
			upd->if0 |= CIF00;
		}
		if (upd->tm0 < cr01 && tmp >= cr01) {
			upd->if0 |= CIF01;
			if (upd->crc0 & 8) {
				//CR01 clear is enabled
				if (upd->cr01) {
					while (tmp >= upd->cr01) {
						tmp -= upd->cr01;
					}
				} else {
					tmp = 0;
				}
			}
		}
		if (tmp > 0xFFFF) {
			upd->tmc0 |= 4;
		}
		upd->tm0 = tmp;
	}
}

uint8_t upd78k2_tm1_scale(upd78k2_context *upd)
{
	uint8_t scale = upd->prm1 & 7;
	if (scale < 2) {
		scale = 2;
	}
	scale += 3;
	return scale;
}

void upd78k2_update_timer1(upd78k2_context *upd)
{
	uint8_t scale = upd78k2_tm1_scale(upd);
	uint32_t diff = (upd->cycles - upd->tm1_cycle) / upd->opts->gen.clock_divider;
	upd->tm1_cycle += (diff & ~((1 << scale) - 1)) * upd->opts->gen.clock_divider;
	diff >>= scale;
	if (upd->tmc1 & CE1) {
		//tm1 count enabled
		uint32_t tmp = upd->tm1 + diff;
		uint32_t cr10 = upd->cr10 | (tmp > 0xFF ? 0x100 : 0);
		uint32_t cr11 = upd->cr11 | (tmp > 0xFF ? 0x100 : 0);
		if (upd->tm1 < cr10 && tmp >= cr10) {
			upd->if0 |= CIF10;
		}
		if (!(upd->crc1 & 4) && upd->tm1 < cr11 && tmp >= cr11) {
			upd->if0 |= CIF11;
		}
		uint8_t do_clr11 = 0;
		if (upd->crc1 & 2) {
			//clr10 enabled
			uint8_t do_clr10 = 1;
			if ((upd->crc1 & 0xC) == 8) {
				//clr11 also enabled
				if (upd->cr11 < upd->cr10) {
					do_clr10 = 0;
					do_clr11 = 1;
					
				}
			}
			if (do_clr10) {
				if (upd->cr10) {
					while (tmp >= upd->cr10) {
						tmp -= upd->cr10;
					}
				} else {
					tmp = 0;
				}
			}
		} else if ((upd->crc1 & 0xC) == 8) {
			do_clr11 = 1;
		}
		if (do_clr11) {
			if (upd->cr11) {
				while (tmp >= upd->cr11) {
					tmp -= upd->cr11;
				}
			} else {
				tmp = 0;
			}
		}
		if (tmp > 0xFF) {
			upd->tmc1 |= 4;
		}
		upd->tm1 = tmp;
	}
}

void upd78k2_update_sio(upd78k2_context *upd)
{
	if (!upd->sio_divider) {
		upd->sio_cycle = upd->cycles;
		return;
	}
	while (upd->sio_cycle < upd->cycles)
	{
		upd->sio_cycle += upd->sio_divider;
		if (upd->sio_counter) {
			upd->sio_counter--;
			if (!upd->sio_counter) {
				upd->if0 |= CSIIF;
				if (upd->sio_handler) {
					upd->sio_handler(upd);
				}
			}
		}
	}
}

void upd78k2_update_edge(upd78k2_context *upd)
{
	for (int i = 0; i < 7; i++)
	{
		while (upd->cycles >= upd->edge_cycles[i]) {
			if (upd->edge_value[i]) {
				upd->port_input[2] |= 1 << i;
			} else {
				upd->port_input[2] &= ~(1 << i);
			}
			if (upd->edge_int[i]) {
				if (i) {
					if (i < 5) {
						upd->if0 |= 1 << (i - 1);
					} else {
						upd->if0 |= 1 << (i + 5);
					}
				} else {
					//TODO: NMI
				}
				printf("P2.%d edge %d with int @ %u\n", i, upd->edge_value[i], upd->edge_cycles[i]);
			} else {
				printf("P2.%d edge %d @ %u\n", i, upd->edge_value[i], upd->edge_cycles[i]);
			}
			if (i == 1 && (upd->crc1 & 4)) {
				upd78k2_update_timer1(upd);
				upd->cr11 = upd->tm1;
				if (upd->crc1 & 8) {
					upd->tm1 = 0;
				}
			} else if (i == 4) {
				upd78k2_update_timer0(upd);
				upd->cr02 = upd->tm0;
			}
			uint32_t edge_cycle = upd->edge_cycles[i];
			upd->edge_cycles[i] = 0xFFFFFFFF;
			upd->edge_int[i] = 0;
			if (upd->edge_next[i]) {
				upd->edge_next[i](upd, i, edge_cycle);
			}
		}
	}
}

void upd78k2_update_peripherals(upd78k2_context *upd)
{
	upd78k2_update_timer0(upd);
	upd78k2_update_timer1(upd);
	upd78k2_update_sio(upd);
	upd78k2_update_edge(upd);
}

#define CMK00 CIF00
#define CMK01 CIF01
#define CMK10 CIF10
#define CMK11 CIF11
#define CSIMK CSIIF

void upd78k2_calc_next_int(upd78k2_context *upd)
{
	uint32_t next_int = 0xFFFFFFFF;
	if (!upd->int_enable) {
		//maskable interrupts disabled
		//TODO: NMIs
		upd->int_cycle = next_int;
		return;
	}
	uint16_t mask = ~upd->mk0;
	if (!upd->int_priority_flag) {
		//only high priority interrupts are enabled
		mask &= ~upd->pr0;
	}
	if (upd->if0 & mask) {
		//unmasked interrupt is pending
		upd->int_cycle = upd->cycles;
		return;
	}
	uint32_t cycle;
	if ((mask & CMK00) && (upd->tmc0 & CE0)) {
		//TODO: account for clear function
		cycle =  ((uint16_t)(upd->cr00 - upd->tm0)) << 4;
		cycle *= upd->opts->gen.clock_divider;
		cycle += upd->tm0_cycle;
		if (cycle < next_int) {
			next_int = cycle;
		}
	}
	if ((mask & CMK01) && (upd->tmc0 & CE0)) {
		//TODO: account for clear function
		cycle = ((uint16_t)(upd->cr01 - upd->tm0)) << 4;
		cycle *= upd->opts->gen.clock_divider;
		cycle += upd->tm0_cycle;
		if (cycle < next_int) {
			next_int = cycle;
		}
	}
	uint8_t scale = upd78k2_tm1_scale(upd);
	if ((mask & CMK10) && (upd->tmc1 & CE1)) {
		//TODO: account for clear function
		cycle = ((uint8_t)(upd->cr10 - upd->tm1)) << scale;
		cycle *= upd->opts->gen.clock_divider;
		cycle += upd->tm1_cycle;
		if (cycle < next_int) {
			next_int = cycle;
		}
	}
	if ((mask & CMK11) && (upd->tmc1 & CE1)) {
		//TODO: account for clear function
		cycle = ((uint8_t)(upd->cr11 - upd->tm1)) << scale;
		cycle *= upd->opts->gen.clock_divider;
		cycle += upd->tm1_cycle;
		if (cycle < next_int) {
			next_int = cycle;
		}
	}
	if ((mask & CSIMK) && upd->sio_counter && upd->sio_divider) {
		cycle = upd->sio_cycle + upd->sio_counter * upd->sio_divider;
		if (cycle < next_int) {
			next_int = cycle;
		}
	}
	//TODO: NMI
	for (int i = 1; i < 7; i++)
	{
		if ((mask & (1 << (i-1))) && upd->edge_int[i] && upd->edge_cycles[i] < next_int) {
			next_int = cycle;
		}
	}
#ifdef FETCH_DEBUG
	if (next_int != upd->int_cycle) {
		printf("UPD78K/II int cycle: %u, cur cycle %u\n", next_int, upd->cycles);
	}
#endif
	upd->int_cycle = next_int;
}

uint8_t upd78237_sfr_read(uint32_t address, void *context)
{
	upd78k2_context *upd = context;
	switch (address)
	{
	case 0x00:
	case 0x04:
	case 0x05:
	case 0x06:
		return upd->port_data[address];
	case 0x02:
	case 0x07:
		//input only
		if (address == 2) {
			upd78k2_update_edge(upd);
		}
		if (upd->io_read) {
			upd->io_read(upd, address);
		}
		return upd->port_input[address];
		break;
	case 0x01:
	case 0x03:
		if (upd->io_read) {
			upd->io_read(upd, address);
		}
		return (upd->port_input[address] & upd->port_mode[address]) | (upd->port_data[address] & ~upd->port_mode[address]);
	case 0x10:
		return upd->cr00;
	case 0x11:
		return upd->cr00 >> 8;
	case 0x12:
		return upd->cr01;
	case 0x13:
		return upd->cr01 >> 8;
	case 0x14:
		return upd->cr10;
	case 0x1C:
		return upd->cr11;
	case 0x21:
	case 0x26:
		return upd->port_mode[address & 0x7];
	case 0x5D:
		upd78k2_update_timer0(upd);
		printf("TMC0 Read: %02X\n", upd->tmc0);
		return upd->tmc0;
	case 0x5F:
		upd78k2_update_timer1(upd);
		printf("TMC1 Read: %02X\n", upd->tmc1);
		return upd->tmc1;
	case 0x80:
		return upd->csim;
	case 0x86:
		upd78k2_update_sio(upd);
		return upd->sio;
	case 0xC4:
		return upd->mm;
	case 0xE0:
		upd78k2_update_peripherals(upd);
		return upd->if0;
	case 0xE1:
		upd78k2_update_peripherals(upd);
		return upd->if0 >> 8;
	case 0xE4:
		return upd->mk0;
	case 0xE5:
		return upd->mk0 >> 8;
	case 0xE8:
		return upd->pr0;
	case 0xE9:
		return upd->pr0 >> 8;
	case 0xEC:
		return upd->ism0;
	case 0xED:
		return upd->ism0 >> 8;
	case 0xF4:
		return upd->intm0;
	case 0xF5:
		return upd->intm1;
	case 0xF8:
		return upd->ist;
	default:
		fprintf(stderr, "Unhandled uPD78237 SFR read %02X\n", address);
		return 0xFF;
	}
}

void *upd78237_sfr_write(uint32_t address, void *context, uint8_t value)
{
	upd78k2_context *upd = context;
	switch (address)
	{
	case 0x00:
	case 0x01:
	case 0x03:
	case 0x04:
	case 0x05:
	case 0x06:
		upd78k2_update_sio(upd);
		printf("P%X: %02X\n", address & 7, value);
		if (upd->io_write) {
			upd->io_write(upd, address, value, upd->port_mode[address & 7]);
		}
		upd->port_data[address & 7] = value;
		break;
	case 0x10:
		upd78k2_update_timer0(upd);
		upd->cr00 &= 0xFF00;
		upd->cr00 |= value;
#ifdef TIMER_DEBUG
		printf("CR00: %04X\n", upd->cr00);
#endif
		upd78k2_calc_next_int(upd);
		break;
	case 0x11:
		upd78k2_update_timer0(upd);
		upd->cr00 &= 0xFF;
		upd->cr00 |= value << 8;
#ifdef TIMER_DEBUG
		printf("CR00: %04X\n", upd->cr00);
#endif
		upd78k2_calc_next_int(upd);
		break;
	case 0x12:
		upd78k2_update_timer0(upd);
		upd->cr01 &= 0xFF00;
		upd->cr01 |= value;
#ifdef TIMER_DEBUG
		printf("CR01: %04X\n", upd->cr01);
#endif
		upd78k2_calc_next_int(upd);
		break;
	case 0x13:
		upd78k2_update_timer0(upd);
		upd->cr01 &= 0xFF;
		upd->cr01 |= value << 8;
#ifdef TIMER_DEBUG
		printf("CR01: %04X\n", upd->cr01);
#endif
		upd78k2_calc_next_int(upd);
		break;
	case 0x14:
		upd78k2_update_timer1(upd);
		upd->cr10 = value;
#ifdef TIMER_DEBUG
		printf("CR10: %02X\n", value);
#endif
		upd78k2_calc_next_int(upd);
		break;
	case 0x1C:
		upd78k2_update_timer1(upd);
		upd->cr11 = value;
#ifdef TIMER_DEBUG
		printf("CR11: %02X\n", value);
#endif
		upd78k2_calc_next_int(upd);
		break;
	case 0x20:
	case 0x21:
	case 0x23:
	case 0x25:
	case 0x26:
		printf("PM%X: %02X\n", address & 0x7, value);
		if (upd->io_write) {
			upd->io_write(upd, address & 7, upd->port_data[address & 7], value);
		}
		upd->port_mode[address & 7] = value;
		break;
	case 0x30:
		upd78k2_update_timer0(upd);
		upd->crc0 = value;
		printf("CRC0 CLR01: %X, MOD: %X, Other: %X\n", value >> 3 & 1, value >> 6, value & 0x37);
		upd78k2_calc_next_int(upd);
		break;
	case 0x32:
		upd78k2_update_timer1(upd);
		upd->crc1 = value;
		printf("CRC1 CLR11: %X, CM: %X, CLR10: %X\n", value >> 3 & 1, value >> 2 & 1, value >> 1 & 1);
		upd78k2_calc_next_int(upd);
		break;
	case 0x40:
		upd->puo = value;
		printf("PUO: %02X\n", value);
		break;
	case 0x43:
		upd->pmc3 = value;
		printf("PMC3 TO: %X, SO: %X, SCK: %X, TxD: %X, RxD: %X\n", value >> 4, value >> 3 & 1, value >> 2 & 1, value >> 1 & 1, value & 1);
		break;
	case 0x5D:
		upd78k2_update_timer0(upd);
		upd->tmc0 = value;
		printf("TMC0 CE0: %X, OVF0: %X - TM3 CE3: %X\n", value >> 3 & 1, value >> 2 & 1, value >> 7 & 1);
		if (!(value & 0x8)) {
			upd->tm0 = 0;
		}
		upd78k2_calc_next_int(upd);
		break;
	case 0x5E:
		upd78k2_update_timer1(upd);
		upd->prm1 = value;
		printf("PRM1: %02X\n", value);
		upd78k2_calc_next_int(upd);
		break;
	case 0x5F:
		upd78k2_update_timer1(upd);
		upd->tmc1 = value;
		if (!(value & 0x8)) {
			upd->tm1 = 0;
		}
		printf("TMC1 CE2: %X, OVF2: %X, CMD2: %X, CE1: %X, OVF1: %X\n", value >> 7, value >> 6 & 1, value >> 5 & 1, value >> 3 & 1, value >> 2 & 1);
		upd78k2_calc_next_int(upd);
		break;
	case 0x80:
		upd78k2_update_sio(upd);
		printf("CSIM CTXE: %X, CRXE: %X, WUP: %X, MOD1: %X, CLS: %X\n", value >> 7, value >> 6 & 1, value >> 5 & 1, value >> 3 & 1, value & 3);
		switch (value & 3)
		{
		case 0:
			if (upd->sio_extclock) {
				upd->sio_extclock(upd);
			}
			break;
		case 1:
			fputs("Timer 3 mode for SIO not yet supported!", stderr);
		case 2:
			upd->sio_divider = 64 * upd->opts->gen.clock_divider;
			break;
		case 3:
			upd->sio_divider = 16 * upd->opts->gen.clock_divider;
			break;
		}
		if ((value & 0x40) && !(upd->csim & 0x40)) {
			//reception enabled start reception (and maybe transmission)
			upd->sio_counter = 8;
		} else if ((upd->csim & 0xC0) && !(value & 0xC0)) {
			//stop transmission/reception
			upd->sio_counter = 0;
		}
		upd->csim = value;
		upd78k2_calc_next_int(upd);
		break;
	case 0x86:
		upd78k2_update_sio(upd);
		upd->sio = value;
		if (upd->csim & 0x80) {
			upd->sio_counter = 8;
			if (!(upd->csim & 3)&& upd->sio_extclock) {
				upd->sio_extclock(upd);
			}
		}
		upd78k2_calc_next_int(upd);
		break;
	case 0xC4:
		upd->mm = value;
		break;
	case 0xE0:
		upd78k2_update_peripherals(upd);
		upd->if0 &= 0xFF00;
		upd->if0 |= value;
		upd78k2_calc_next_int(upd);
		break;
	case 0xE1:
		upd78k2_update_peripherals(upd);
		upd->if0 &= 0xFF;
		upd->if0 |= value << 8;
		upd78k2_calc_next_int(upd);
		break;
	case 0xE4:
		upd78k2_update_peripherals(upd);
		upd->mk0 &= 0xFF00;
		upd->mk0 |= value;
		printf("MK0: %04X (low: %02X)\n", upd->mk0, value);
		upd78k2_calc_next_int(upd);
		break;
	case 0xE5:
		upd78k2_update_peripherals(upd);
		upd->mk0 &= 0xFF;
		upd->mk0 |= value << 8;
		printf("MK0: %04X (hi: %02X)\n", upd->mk0, value);
		upd78k2_calc_next_int(upd);
		break;
	case 0xE8:
		upd78k2_update_peripherals(upd);
		upd->pr0 &= 0xFF00;
		upd->pr0 |= value;
		printf("PR0: %04X\n", upd->pr0);
		upd78k2_calc_next_int(upd);
		break;
	case 0xE9:
		upd78k2_update_peripherals(upd);
		upd->pr0 &= 0xFF;
		upd->pr0 |= value << 8;
		printf("PR0: %04X\n", upd->pr0);
		upd78k2_calc_next_int(upd);
		break;
	case 0xEC:
		upd->ism0 &= 0xFF00;
		upd->ism0 |= value;
		printf("ISM0: %04X\n", upd->ism0);
		break;
	case 0xED:
		upd->ism0 &= 0xFF;
		upd->ism0 |= value << 8;
		printf("ISM0: %04X\n", upd->ism0);
		break;
	case 0xF4:
		upd78k2_update_edge(upd);
		printf("INTM0: %02X\n", value);
		{
			uint8_t changes = upd->intm0 ^ value;
			for (int i = 0; i < 4; i++)
			{
				if (upd->edge_cycles[i] != 0xFFFFFFFF && (changes & (3 << (i * 2)))) {
					uint8_t edge_mode = (value >> (2 * i)) & 3;
					if (!i) {
						edge_mode &= 1;
					}
					upd->edge_int[i] = edge_mode == 3 || edge_mode == upd->edge_value[i];
				}
			}
		}
		upd->intm0 = value;
		upd78k2_calc_next_int(upd);
		break;
	case 0xF5:
		upd78k2_update_edge(upd);
		printf("INTM1: %02X\n", value);
		{
			uint8_t changes = upd->intm1 ^ value;
			for (int i = 4; i < 7; i++)
			{
				if (upd->edge_cycles[i] != 0xFFFFFFFF && (changes & (3 << ((i - 4) * 2)))) {
					uint8_t edge_mode = (value >> (2 * i - 8)) & 3;
					upd->edge_int[i] = edge_mode == 3 || edge_mode == upd->edge_value[i];
				}
			}
		}
		upd->intm1 = value;
		upd78k2_calc_next_int(upd);
		break;
	case 0xF8:
		upd->ist = value;
		break;
	default:
		fprintf(stderr, "Unhandled uPD78237 SFR write %02X: %02X\n", address, value);
		break;
	}
	return context;
}

void init_upd78k2_opts(upd78k2_options *opts, memmap_chunk const *chunks, uint32_t num_chunks)
{
	memset(opts, 0, sizeof(*opts));
	opts->gen.memmap = chunks;
	opts->gen.memmap_chunks = num_chunks;
	opts->gen.address_mask = 0xFFFFF;
	opts->gen.max_address = 0xFFFFF;
	opts->gen.clock_divider = 1;
}

upd78k2_context *init_upd78k2_context(upd78k2_options *opts)
{
	upd78k2_context *context = calloc(1, sizeof(upd78k2_context));
	context->opts = opts;
	memset(context->port_mode, 0xFF, sizeof(context->port_mode));
	context->crc0 = 0x10;
	context->mm = 0x20;
	context->mk0 = 0xFFFF;
	context->pr0 = 0xFFFF;
	context->int_priority_flag = 1;
	for (int i = 0; i < 7; i++)
	{
		context->edge_cycles[i] = 0xFFFFFFFF;
	}
	return context;
}

void upd78k2_sync_cycle(upd78k2_context *upd, uint32_t target_cycle)
{
	upd78k2_update_peripherals(upd);
	upd->sync_cycle = target_cycle;
	upd78k2_calc_next_int(upd);
}

void upd78k2_calc_vector(upd78k2_context *upd)
{
	uint32_t pending_enabled = upd->scratch1;
	uint32_t new_priority = upd->pr0;
	uint32_t vector = 0x6;
	uint32_t bit = 1;
	while (pending_enabled)
	{
		if (pending_enabled & 1) {
			upd->if0 &= ~bit;
			upd->int_priority_flag = new_priority & 1;
			upd->scratch1 = vector;
			return;
		}
		bit <<= 1;
		pending_enabled >>= 1;
		new_priority >>= 1;
		vector += 2;
		if (vector == 0xE) {
			vector = 0x14;
		} else if (vector == 0x20) {
			vector = 0xE;
		} else if (vector == 0x14) {
			vector = 0x20;
		}
	}
	fatal_error("upd78k2_calc_vector: %X\n", upd->scratch1);
}

void upd78k2_adjust_cycles(upd78k2_context *upd, uint32_t deduction)
{
	upd78k2_update_timer0(upd);
	upd78k2_update_timer1(upd);
	if (upd->cycles <= deduction) {
		upd->cycles = 0;
	} else {
		upd->cycles -= deduction;
	}
	if (upd->tm0_cycle <= deduction) {
		upd->tm0_cycle = 0;
	} else {
		upd->tm0_cycle -= deduction;
	}
	if (upd->tm1_cycle <= deduction) {
		upd->tm1_cycle = 0;
	} else {
		upd->tm1_cycle -= deduction;
	}
	if (upd->sio_cycle <= deduction) {
		upd->sio_cycle = 0;
	} else {
		upd->sio_cycle -= deduction;
	}
	for (int i = 0; i < 7; i++)
	{
		if (upd->edge_cycles[i] != 0xFFFFFFFF) {
			if (upd->edge_cycles[i] <= deduction) {
				upd->edge_cycles[i] = 0;
			} else {
				upd->edge_cycles[i] -= deduction;
			}
		}
	}
}

void upd78k2_schedule_port2_transition(upd78k2_context *upd, uint32_t cycle, uint8_t bit, uint8_t level, upd_edge_fun *next_transition)
{
	uint8_t mask = 1 << bit;
	uint8_t value = level ? mask : 0;
	if ((upd->port_input[2] & mask) == value) {
		//no change, call next transition immediately
		if (next_transition) {
			next_transition(upd, bit, upd->cycles);
		}
		return;
	}
	upd->edge_cycles[bit] = cycle;
	upd->edge_value[bit] = level;
	upd->edge_next[bit] = next_transition;
	uint8_t edge_mode = (bit >= 4 ? upd->intm1 >> (2 * bit - 8) : upd->intm0 >> (2 * bit)) & 3;
	if (!bit) {
		edge_mode &= 1;
	}
	upd->edge_int[bit] = edge_mode == 3 || edge_mode == level;
	upd78k2_update_edge(upd);
	upd78k2_calc_next_int(upd);
}

void upd78k2_insert_breakpoint(upd78k2_context *upd, uint32_t address, upd_fun *handler)
{
	char buf[6];
	address &= upd->opts->gen.address_mask & 0xFFFF;
	upd->breakpoints = tern_insert_ptr(upd->breakpoints, tern_int_key(address, buf), handler);
}

void upd78k2_remove_breakpoint(upd78k2_context *upd, uint32_t address)
{
	char buf[6];
	address &= upd->opts->gen.address_mask & 0xFFFF;
	tern_delete(&upd->breakpoints, tern_int_key(address, buf), NULL);
}
