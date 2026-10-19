#include <string.h>
#include <stdlib.h>
#include "sh7095.h"

#ifdef DO_DEBUG_PRINT
#define dprintf printf
#else
#define dprintf
#endif

static void sh7095_reset(sh2_context *sh2)
{
	memset(sh2->peripherals, 0, sizeof(sh2->peripherals));
	sh2->peripherals[SH_BRR] = 0xFF;
	sh2->peripherals[SH_TDR] = 0xFF;
	sh2->peripherals[SH_SSR] = 0x84;
	sh2->peripherals[SH_TIER] = 0x01;
	sh2->peripherals[SH_TOCR] = 0xE0;
	sh2->peripherals[SH_WTCSR] = 0x18;
	sh2->peripherals[SH_RSTCSR] = 0x1F;
	sh2->peripherals[SH_BCR1 + 2] = sh2->main ? 0x03 : 0x83;
	sh2->peripherals[SH_BCR1 + 3] = 0xF0;
	sh7095_periph *p = sh2->periph_state;
	p->ocra = p->ocrb = 0xFFFF;
	sh2->peripherals[SH_OCRH] = p->ocra >> 8;
	sh2->peripherals[SH_OCRL] = p->ocra;
	p->frc_counter = 8;
}

static uint32_t sh7095_periph32(uint32_t reg, sh2_context *sh2)
{
	return sh2->peripherals[reg] << 24 | sh2->peripherals[reg + 1] << 16 |
		sh2->peripherals[reg + 2] << 8 | sh2->peripherals[reg + 3];
}

static void sh7095_setperiph32(uint32_t reg, sh2_context *sh2, uint32_t value)
{
	sh2->peripherals[reg] = value >> 24;
	sh2->peripherals[reg + 1] = value >> 16;
	sh2->peripherals[reg + 2] = value >> 8;
	sh2->peripherals[reg + 3] = value;
}

static void start_transmit(sh2_context *sh2)
{
	sh7095_periph *p = sh2->periph_state;
	uint32_t counter;
	switch (sh2->peripherals[SH_SMR] & MASK_SMR_CKS)
	{
	case 0: counter = 16; break;
	case 1: counter = 64; break;
	case 2: counter = 256; break;
	case 3: counter = 1024; break;
	}
	uint32_t bits = 8;
	if (!(sh2->peripherals[SH_SMR] & BIT_SMR_CA)) {
		counter *= 8;
		if (sh2->peripherals[SH_SMR] & BIT_SMR_CHR) {
			bits--;
		}
		if (sh2->peripherals[SH_SMR] & BIT_SMR_PE) {
			bits++;
		}
		if (sh2->peripherals[SH_SMR] & BIT_SMR_STOP) {
			bits += 2;
		} else {
			bits++;
		}
	}
	p->transmit_counter = counter * (sh2->peripherals[SH_BRR] + 1) * bits * sh2->opts->gen.clock_divider;
}

void sh7095_sci_to_sh7095_sci(void *data, uint32_t cycle, uint8_t byte)
{
	sh2_context *other_sh2 = data;
	sh2_run(other_sh2, cycle);
	sh7095_periph *p = other_sh2->periph_state;
	if (other_sh2->peripherals[SH_SCR] & BIT_SCR_RE) {
		if (other_sh2->peripherals[SH_SSR] & BIT_SSR_RDRF) {
			dprintf("SCI received %X, setting ORER SH2: %p\n", byte, other_sh2);
			other_sh2->peripherals[SH_SSR] |= BIT_SSR_ORER;
			if (other_sh2->peripherals[SH_SCR] & BIT_SCR_RIE) {
				p->eri_pending = 1;
				other_sh2->calc_next_interrupt(other_sh2);
			}
		} else {
			dprintf("SCI received %X, setting RDRF SH2: %p\n", byte, other_sh2);
			other_sh2->peripherals[SH_RDR] = byte;
			other_sh2->peripherals[SH_SSR] |= BIT_SSR_RDRF;
			if (other_sh2->peripherals[SH_SCR] & BIT_SCR_RIE) {
				p->ri_pending = 1;
				other_sh2->calc_next_interrupt(other_sh2);
			}
		}
	}
}

static void sh7095_check_start_dma(sh2_context *sh2, int which)
{
	sh7095_periph *p = sh2->periph_state;
	if (!sh2->peripherals[SH_DMAOR+3] & BIT_DMAOR_DMIE) {
		p->dmac0_run = p->dmac1_run = 0;
		return;
	}
	uint8_t running = 0;
	if ((sh2->peripherals[SH_CHCR0 + which + 3] & (BIT_CHCR_TE|BIT_CHCR_DE)) == 1) {

		if (sh2->peripherals[SH_CHCR0 + which + 2] & 2) {
			//auto-request mode i.e. no peripheral involved
			running = 1;
		} else if (sh2->peripherals[SH_DRCR0 + !!which] & 3) {
			//TODO: implement SCI DMA
		} else {
			running = which ? p->dreq1 : p->dreq0;
		}
	}

	if (which) {
		p->dmac1_run = running;
	} else {
		p->dmac0_run = running;
	}
}

void sh7095_assert_dreq0(sh2_context *sh2)
{
	sh7095_periph *p = sh2->periph_state;
	//TODO: level vs edge and polarity
	p->dreq0 = 1;
	sh7095_check_start_dma(sh2, 0);
}

void sh7095_assert_dreq1(sh2_context *sh2)
{
	sh7095_periph *p = sh2->periph_state;
	//TODO: level vs edge and polarity
	p->dreq1 = 1;
	sh7095_check_start_dma(sh2, SH_SAR1 - SH_SAR0);
}

void sh7095_clear_dreq0(sh2_context *sh2)
{
	sh7095_periph *p = sh2->periph_state;
	//TODO: level vs edge and polarity
	p->dreq0 = 0;
	sh7095_check_start_dma(sh2, 0);
}

void sh7095_clear_dreq1(sh2_context *sh2)
{
	sh7095_periph *p = sh2->periph_state;
	//TODO: level vs edge and polarity
	p->dreq1 = 0;
	sh7095_check_start_dma(sh2, SH_SAR1 - SH_SAR0);
}

static uint32_t sh7095_dmac_transfer(sh2_context *sh2, uint32_t *src, uint32_t *dst, uint32_t ts, int32_t src_delta, int32_t dst_delta, uint32_t *tcr)
{
	//TODO: real cycles
	//TODO: test how 16-byte burst mode behaves on 16-bit bus
	uint32_t cycles;
	uint8_t val8;
	uint16_t val16;
	uint32_t cycles_start = sh2->cycles;
	switch (ts)
	{
	case 1:
		val8 = sh2->read8[1](*src, sh2);
		sh2->write8[1](*dst, sh2, val8);
		*src += src_delta;
		*dst += dst_delta;
		--*tcr;
		break;
	case 2:
		val16 = sh2->read16[1](*src, sh2);
		sh2->write16[1](*dst, sh2, val16);
		*src += src_delta;
		*dst += dst_delta;
		--*tcr;
		break;

	case 16:
#if defined(X86_32) | defined(X86_64)
	{
		//GCC won't actually give us our requested alignemnt on the stack unless it's <= system stack alignemnt
		//Windows only guarantees 4-byte alignment in its 32-bit ABI so this will crash there if not static
		static uint32_t data[4] __attribute__((aligned(16)));
		sh2->burst_read(*src, sh2, data);
		for (int i = 0; i < 4 && *tcr; i++, --*tcr)
		{
			sh2->write16[1](*dst, sh2, data[i] >> 16);
			sh2->write16[1](*dst + 2, sh2, data[i]);
			*dst += dst_delta;
		}
		*src += 4 * src_delta;
		break;
	}
#endif
	case 4:
		val16 = sh2->read16[1](*src, sh2);
		sh2->write16[1](*dst, sh2, val16);
		val16 = sh2->read16[1](*src + 2, sh2);
		sh2->write16[1](*dst + 2, sh2, val16);
		*src += src_delta;
		*dst += dst_delta;
		--*tcr;
		break;
	}
	cycles = sh2->cycles - cycles_start;
	sh2->cycles = cycles_start;
	return cycles;
}

static int32_t sh7095_dmac_src_delta(uint8_t sm, int32_t ts)
{
	if (ts == 16) {
		return 4;
	}
	int32_t src_delta;
	switch (sm & 0x30)
	{
	default:
	case 0: src_delta = 0; break;
	case 0x10: src_delta = ts; break;
	case 0x20: src_delta = -ts; break;
	}
	return src_delta;
}

static int32_t sh7095_dmac_dst_delta(uint8_t dm, int32_t ts)
{
	if (ts == 16) {
		ts = 4;
	}
	int32_t dst_delta;
	switch (dm & 0xC0)
	{
	default:
	case 0: dst_delta = 0; break;
	case 0x40: dst_delta = ts; break;
	case 0x80: dst_delta = -ts; break;
	}
	return dst_delta;
}

static const uint32_t frc_counter_values[] = {8, 32, 128, 0};
static const uint32_t wdt_counter_values[] = {2, 64, 128, 256, 512, 1024, 4096, 8192};
static void sh7095_run(sh2_context *sh2)
{
	sh7095_periph *p = sh2->periph_state;
	if (sh2->cycles > p->cycle) {
		uint32_t delta = sh2->cycles - p->cycle;

		if (p->divide_counter) {
			if (delta >= p->divide_counter) {
				p->divide_counter = 0;
				p->divu_loaded = 0;
				if (p->div_overflow) {
					//TODO: overflow interrupts
					sh2->peripherals[SH_DVCR + 3] |= 1;
					sh7095_setperiph32(SH_DVDNTL, sh2, p->quotient);
				} else {
					sh7095_setperiph32(SH_DVDNTH, sh2, p->remainder);
					sh7095_setperiph32(SH_DVDNTL, sh2, p->quotient);
				}
			} else {
				p->divide_counter -= delta;
			}
		}
		if (p->transmit_counter) {
			uint32_t transmit_delta = delta;
			while (transmit_delta >= p->transmit_counter && p->transmit_counter)
			{
				transmit_delta -= p->transmit_counter;
				if (p->transmit_handler) {
					p->transmit_handler(p->sci_handler_data, p->cycle + p->transmit_counter, p->tsr);
				}
				if (sh2->peripherals[SH_SSR] & BIT_SSR_TDRE) {
					sh2->peripherals[SH_SSR] |= BIT_SSR_TEND;
					if (sh2->peripherals[SH_SCR] & BIT_SCR_TEIE) {
						p->tei_pending = 1;
						sh2->calc_next_interrupt(sh2);
					}
					p->transmit_counter = 0;
				} else {
					p->tsr = sh2->peripherals[SH_TDR];
					sh2->peripherals[SH_SSR] |= BIT_SSR_TDRE;
					if (sh2->peripherals[SH_SCR] & BIT_SCR_TIE) {
						p->ti_pending = 1;
						sh2->calc_next_interrupt(sh2);
					}
					start_transmit(sh2);
				}
			}
			if (transmit_delta && p->transmit_counter)
			{
				p->transmit_counter -= transmit_delta;
			}
		}
		if (p->frc_counter) {
			uint32_t frc_delta = delta;
			uint16_t frc = sh2->peripherals[SH_FRCH] << 8 | sh2->peripherals[SH_FRCL];
			uint32_t cks = frc_counter_values[sh2->peripherals[SH_TCR] & 3] * sh2->opts->gen.clock_divider;
			while (frc_delta >= p->frc_counter && p->frc_counter) {
				frc++;
				//TODO: FRC interrupts
				if (!frc) {
					sh2->peripherals[SH_FTCSR] |= BIT_FTCSR_OVF;
				}
				if (frc == p->ocrb) {
					sh2->peripherals[SH_FTCSR] |= BIT_FTCSR_OCFB;
				}
				if (frc == p->ocra) {
					sh2->peripherals[SH_FTCSR] |= BIT_FTCSR_OCFA;
					if (sh2->peripherals[SH_FTCSR] & BIT_FTCSR_CCLRA) {
						frc = 0;
					}
				}
				frc_delta -= p->frc_counter;
				p->frc_counter = cks;
			}
			if (frc_delta && p->frc_counter)
			{
				p->frc_counter -= frc_delta;
			}
			sh2->peripherals[SH_FRCH] = frc >> 8;
			sh2->peripherals[SH_FRCL] = frc;
		}
		if (p->wdt_counter) {
			uint32_t wdt_delta = delta;
			uint32_t cks = wdt_counter_values[sh2->peripherals[SH_WTCSR] & 7] * sh2->opts->gen.clock_divider;
			uint8_t overflow = 0;
			while (wdt_delta >= p->wdt_counter)
			{
				sh2->peripherals[SH_WTCNT]++;
				overflow = !sh2->peripherals[SH_WTCNT];
				wdt_delta -= p->wdt_counter;
				p->wdt_counter = cks;
			}
			if (wdt_delta)
			{
				p->wdt_counter -= wdt_delta;
			}
			if (overflow) {
				if (sh2->peripherals[SH_WTCSR] & BIT_WTCSR_WTIT) {
					//TODO: trigger !WDTOVF and or reset chip
					sh2->peripherals[SH_RSTCSR] |= BIT_RSTCSR_WOVF;
				} else {
					sh2->peripherals[SH_WTCSR] |= BIT_WTCSR_OVF;
					p->iti_pending = 1;
				}
			}
		}
		if (p->dmac0_run || p->dmac1_run)
		{
			uint32_t dmac_delta = delta;
			uint32_t tcr0 = sh2->peripherals[SH_TCR0+1] << 16 | sh2->peripherals[SH_TCR0+2] << 8 | sh2->peripherals[SH_TCR0+3];
			uint32_t tcr1 = sh2->peripherals[SH_TCR1+1] << 16 | sh2->peripherals[SH_TCR1+2] << 8 | sh2->peripherals[SH_TCR1+3];
			uint32_t sar0 = sh7095_periph32(SH_SAR0, sh2);
			uint32_t sar1 = sh7095_periph32(SH_SAR1, sh2);
			uint32_t dar0 = sh7095_periph32(SH_DAR0, sh2);
			uint32_t dar1 = sh7095_periph32(SH_DAR1, sh2);
			uint8_t chcr0_mdsz = sh2->peripherals[SH_CHCR0+2];
			uint32_t chcr0_ts = 1 << (chcr0_mdsz >> 2 & 3);
			if (chcr0_ts == 8) {
				chcr0_ts = 16;
			}
			int32_t src_delta0 = sh7095_dmac_src_delta(chcr0_mdsz, chcr0_ts);
			int32_t dst_delta0 = sh7095_dmac_dst_delta(chcr0_mdsz, chcr0_ts);
			uint8_t ar0 = chcr0_mdsz & 2;
			uint8_t chcr1_mdsz = sh2->peripherals[SH_CHCR1+2];
			uint32_t chcr1_ts = 1 << (chcr1_mdsz >> 2 & 3);
			if (chcr1_ts == 8) {
				chcr1_ts = 16;
			}
			int32_t src_delta1 = sh7095_dmac_src_delta(chcr1_mdsz, chcr1_ts);
			int32_t dst_delta1 = sh7095_dmac_dst_delta(chcr1_mdsz, chcr1_ts);
			uint8_t ar1 = chcr1_mdsz & 2;

			//TODO: DMAC/CPU contention
			if (sh2->peripherals[SH_DMAOR+3] & BIT_DMAOR_PR) {
				while (dmac_delta && p->dmac0_run && p->dmac1_run)
				{
					uint32_t cycles;
					if (p->dmac_which) {
						cycles = sh7095_dmac_transfer(sh2, &sar1, &dar1, chcr1_ts, src_delta1, dst_delta1, &tcr1);
						if (!tcr1) {
							p->dmac1_run = 0;
							sh2->peripherals[SH_CHCR1+3] |= BIT_CHCR_TE;
							if (sh2->peripherals[SH_CHCR1+3] & BIT_CHCR_IE) {
								p->dmac1_pending = 1;
								sh2->calc_next_interrupt(sh2);
 							}
						} else if (!ar0 && !p->dreq1) { //TODO: SCI DMA
							p->dmac1_run = 0;
						}
					} else {
						cycles = sh7095_dmac_transfer(sh2, &sar0, &dar0, chcr0_ts, src_delta0, dst_delta0, &tcr0);
						if (!tcr0) {
							p->dmac0_run = 0;
							sh2->peripherals[SH_CHCR0+3] |= BIT_CHCR_TE;
							if (sh2->peripherals[SH_CHCR0+3] & BIT_CHCR_IE) {
								p->dmac0_pending = 1;
								sh2->calc_next_interrupt(sh2);
 							}
						} else if (!ar1 && !p->dreq0) { //TODO: SCI DMA
							p->dmac0_run = 0;
						}
					}
					if (cycles > dmac_delta) {
						dmac_delta = 0;
					} else {
						dmac_delta -= cycles;
					}
					p->dmac_which = !p->dmac_which;

				}
			}
			while (dmac_delta && p->dmac0_run)
			{
				uint32_t cycles = sh7095_dmac_transfer(sh2, &sar0, &dar0, chcr0_ts, src_delta0, dst_delta0, &tcr0);
				if (!tcr0) {
					p->dmac0_run = 0;
					sh2->peripherals[SH_CHCR0+3] |= BIT_CHCR_TE;
					if (sh2->peripherals[SH_CHCR0+3] & BIT_CHCR_IE) {
						p->dmac0_pending = 1;
						sh2->calc_next_interrupt(sh2);
					}
				} else if (!ar0 && !p->dreq0) { //TODO: SCI DMA
					p->dmac0_run = 0;
				}
				if (cycles > dmac_delta) {
					dmac_delta = 0;
				} else {
					dmac_delta -= cycles;
				}
			}
			while (dmac_delta && p->dmac1_run)
			{
				uint32_t cycles = sh7095_dmac_transfer(sh2, &sar1, &dar1, chcr1_ts, src_delta1, dst_delta1, &tcr1);
				if (!tcr1) {
					p->dmac1_run = 0;
					sh2->peripherals[SH_CHCR1+3] |= BIT_CHCR_TE;
					if (sh2->peripherals[SH_CHCR1+3] & BIT_CHCR_IE) {
						p->dmac1_pending = 1;
						sh2->calc_next_interrupt(sh2);
					}
				} else if (!ar1 && !p->dreq1) { //TODO: SCI DMA
					p->dmac1_run = 0;
				}
				if (cycles > dmac_delta) {
					dmac_delta = 0;
				} else {
					dmac_delta -= cycles;
				}

			}
			sh2->peripherals[SH_TCR0+1] = tcr0 >> 16;
			sh2->peripherals[SH_TCR0+2] = tcr0 >> 8;
			sh2->peripherals[SH_TCR0+3] = tcr0;
			sh7095_setperiph32(SH_SAR0, sh2, sar0);
			sh7095_setperiph32(SH_DAR0, sh2, dar0);
			sh2->peripherals[SH_TCR1+1] = tcr1 >> 16;
			sh2->peripherals[SH_TCR1+2] = tcr1 >> 8;
			sh2->peripherals[SH_TCR1+3] = tcr1;
			sh7095_setperiph32(SH_SAR1, sh2, sar1);
			sh7095_setperiph32(SH_DAR1, sh2, dar1);
		}

		p->cycle = sh2->cycles;
	}
}

static uint8_t write_masks[512];
static uint8_t did_write_mask_setup;

static void sh7095_write_byte(uint32_t reg, sh2_context *sh2, uint8_t value)
{
	sh7095_periph *p = sh2->periph_state;
	uint8_t mask = write_masks[reg];
	uint8_t old = sh2->peripherals[reg];
	uint8_t changes;
	if (reg == SH_FTCSR) {
		mask |= (value ^ 0x8E);
	}
	sh2->peripherals[reg] = (old & ~mask) | (value & mask);
	switch (reg)
	{
	case SH_FRCH:
		sh2->peripherals[reg] = old;
		p->frc_temp = value;
		break;
	case SH_FRCL:
		sh2->peripherals[SH_FRCH] = p->frc_temp;
		break;
	case SH_OCRH:
		//keep opra/oprb in sync with reg array
		if (sh2->peripherals[SH_TOCR] & BIT_TOCR_OCRS) {
			p->ocrb &= 0xFF;
			p->ocrb |= value << 8;
		} else {
			p->ocra &= 0xFF;
			p->ocra |= value << 8;
		}
		break;
	case SH_OCRL:
		//keep opra/oprb in sync with reg array
		if (sh2->peripherals[SH_TOCR] & BIT_TOCR_OCRS) {
			p->ocrb &= 0xFF00;
			p->ocrb |= value;
		} else {
			p->ocra &= 0xFF00;
			p->ocra |= value;
		}
		break;
	case SH_TCR:
		if (!p->frc_counter) {
			p->frc_counter = frc_counter_values[sh2->peripherals[SH_TCR] & 3] * sh2->opts->gen.clock_divider;;
		}
		break;
	case SH_WTCSR:
		changes = old ^ value;
		if (changes & BIT_WTCSR_TME) {
			if (value & BIT_WTCSR_TME) {
				p->wdt_counter = wdt_counter_values[value & 7] * sh2->opts->gen.clock_divider;
			} else {
				sh2->peripherals[SH_WTCNT] = 0;
				p->wdt_counter = 0;
			}
		}
		if (changes & (BIT_WTCSR_TME|BIT_WTCSR_WTIT)) {
			sh2->calc_next_interrupt(sh2);
		}
		break;
	case SH_WTCNT:
		changes = old ^ value;
		if (changes) {
			sh2->calc_next_interrupt(sh2);
		}
		break;
	case SH_CCR:
		changes = old ^ value;
		sh2->current_way_off = value & 0xC0;
		sh2->cache_tw = value & BIT_CCR_TW;
		sh2->cache_od = value & BIT_CCR_OD;
		sh2->cache_id = value & BIT_CCR_ID;
		if (changes & BIT_CCR_CE) {
			sh2_set_cache_enabled(sh2, value & BIT_CCR_CE);
		}
		if (value & BIT_CCR_CP) {
			memset(sh2->cache_lru, 0, sizeof(sh2->cache_lru));
			//does this clear addresses or just valid bit
			memset(sh2->cache_address, 0, sizeof(sh2->cache_address));
			//does the cache data array need to be cleared too?
		}
		break;
	}
}

static void start_divide(sh2_context *sh2, sh7095_periph *p)
{
	int32_t divisor = sh7095_periph32(SH_DVSR, sh2);
	if (divisor == 0) {
		p->divide_counter = 6 * sh2->opts->gen.clock_divider;
		p->div_overflow = 1;
		p->quotient = INT32_MAX;
		//TODO: overflow interrupts
	} else {
		int64_t dividend = ((uint64_t)sh7095_periph32(SH_DVDNTH, sh2)) << 32 | sh7095_periph32(SH_DVDNTL, sh2);
		int64_t quotient = dividend / divisor;
		if (quotient > INT32_MAX || quotient < INT32_MIN) {
			p->divide_counter = 6 * sh2->opts->gen.clock_divider;
			p->div_overflow = 1;
			p->quotient = quotient > 0 ? INT32_MAX : INT32_MIN;
			//TODO: overflow interrupts
		} else {
			p->divide_counter = 39 * sh2->opts->gen.clock_divider;
			p->div_overflow = 0;
			p->quotient = quotient;
			p->remainder = dividend % divisor;
		}
	}
}

static void sh7095_write_32(uint32_t address, sh2_context *sh2, uint32_t value)
{
	sh7095_periph *p = sh2->periph_state;
	sh7095_run(sh2);
	address &= 0x1FC;
	uint32_t mask;
	uint8_t no_start_divide = 0;
	switch (address)
	{
	case SH_DVDNTH_ALT:
	case SH_DVDNTL_ALT:
		address &= 0x1F7;
		no_start_divide = 1;
	case SH_DVSR:
	case SH_DVCR:
	case SH_DVDNT:
	case SH_DVDNTH:
	case SH_DVDNTL:
		while (p->divide_counter) {
			sh2->cycles += p->divide_counter;
			sh7095_run(sh2);
		}
		break;
	case SH_DMAOR:
		mask = 0xF ^ (value & 6);//AE and NMIF are clear only
		sh2->peripherals[SH_DMAOR+3] &= ~mask;
		sh2->peripherals[SH_DMAOR+3] |= mask & value;
		sh7095_check_start_dma(sh2, 0);
		sh7095_check_start_dma(sh2, 0x10);
		return;
	}
	sh7095_write_byte(address, sh2, value >> 24);
	sh7095_write_byte(address | 1, sh2, value >> 16);
	sh7095_write_byte(address | 2, sh2, value >> 8);
	sh7095_write_byte(address | 3, sh2, value);
	switch (address)
	{
	case SH_DVDNT:
		memset(sh2->peripherals + SH_DVDNTH, (value & 0x80000000) ? 0xFF : 0, 4);
		memcpy(sh2->peripherals + SH_DVDNTL, sh2->peripherals + SH_DVDNT, 4);
	case SH_DVDNTL:
		if (no_start_divide) {
			p->divu_loaded = 1;
			break;
		}
		start_divide(sh2, p);
		break;
	case SH_CHCR0:
	case SH_CHCR1:
		sh7095_check_start_dma(sh2, address & 0x10);
		break;
	}
}

static void sh7095_write_16(uint32_t address, sh2_context *sh2, uint16_t value)
{
	sh7095_run(sh2);
	address &= 0x1FE;
	switch (address)
	{
	case SH_WTCSR:
		address = value & 0xFF00;
		if (address == 0x5A00) {
			sh7095_write_byte(SH_WTCNT, sh2, value);
		} else if (address == 0xA500) {
			sh7095_write_byte(SH_WTCSR, sh2, value);
		}
		break;
	case (SH_RSTCSR-1):
		address = value & 0xFF00;
		if (address == 0x5A00) {
			if (!(value & BIT_RSTCSR_WOVF)) {
				sh2->peripherals[SH_RSTCSR] &= ~BIT_RSTCSR_WOVF;
			}
		} else if (address == 0xA500) {
			sh2->peripherals[SH_RSTCSR] &= ~(BIT_RSTCSR_RSTE|BIT_RSTCSR_RSTS);
			sh2->peripherals[SH_RSTCSR] |= value & (BIT_RSTCSR_RSTE|BIT_RSTCSR_RSTS);
		}
		break;
	default:
		sh7095_write_byte(address, sh2, value >> 8);
		sh7095_write_byte(address | 1, sh2, value);
		break;
	}
}

static void sh7095_write_8(uint32_t address, sh2_context *sh2, uint8_t value)
{
	sh7095_periph *p = sh2->periph_state;
	sh7095_run(sh2);
	address &= 0x1FF;
	uint8_t changes;
	uint8_t mask;
	switch(address)
	{
	case SH_TDR:
		 if (sh2->peripherals[SH_SCR] & BIT_SCR_TE) {
			if (p->transmit_counter) {
				//does this still happen if the CPU does it, or only the DMAC?
				sh2->peripherals[SH_SSR] &= ~BIT_SSR_TDRE;
			} else {
				p->tsr = value;
				start_transmit(sh2);
			}
			//does this still happen if the CPU does it, or only the DMAC?
			sh2->peripherals[SH_SSR] &= ~BIT_SSR_TEND;
		}
		break;
	case SH_SCR:
		changes = sh2->peripherals[SH_SCR] ^ value;
		if ((changes & BIT_SCR_TE)) {
			if (value & BIT_SCR_TE) {
				if (!(sh2->peripherals[SH_SSR] & BIT_SSR_TDRE)) {
					p->tsr = sh2->peripherals[SH_TDR];
					start_transmit(sh2);
				}
			} else {
				sh2->peripherals[SH_SSR] &= ~BIT_SSR_TEND;
			}
			sh2->peripherals[SH_SSR] |= BIT_SSR_TDRE;
			if (sh2->peripherals[SH_SCR] & BIT_SCR_TIE) {
				p->ti_pending = 1;
			}
		}
		break;
	case SH_SSR:
		//except for bit 1, most of the settable bits in this reg can only be cleared
		mask = 1 | (value ^ 0xF8);
		value = (value & mask) | (sh2->peripherals[SH_SSR] & ~mask);
		changes = value ^ sh2->peripherals[SH_SSR];
		if ((changes & BIT_SSR_TDRE) && (sh2->peripherals[SH_SCR] & BIT_SCR_TE)) {
			p->tsr = sh2->peripherals[SH_TDR];
			start_transmit(sh2);
			value |= BIT_SSR_TDRE;
		}
		break;
	}
	sh7095_write_byte(address, sh2, value);
}

static uint32_t sh7095_read_32(uint32_t address, sh2_context *sh2)
{
	sh7095_run(sh2);
	sh7095_periph *p = sh2->periph_state;
	//FIXME: probably wrong for 8-bit wide peripheral addresses
	sh2->cycles += sh2->opts->gen.clock_divider;
	address &= 0x1FC;
	uint8_t start_if_loaded = 1;
	switch (address)
	{
	case SH_DVDNTH_ALT:
	case SH_DVDNTL_ALT:
		address &= 0x1F7;
		start_if_loaded = 0;
	case SH_DVDNT:
		address |= 0x10;
	case SH_DVSR:
	case SH_DVDNTH:
	case SH_DVDNTL:
	case SH_DVCR:
		if (start_if_loaded && p->divu_loaded) {
			start_divide(sh2, p);
		}
		//Does this apply to DVCR and VCRDIV too?
		while (p->divide_counter) {
			sh2->cycles += p->divide_counter;
			sh7095_run(sh2);
		}
		break;
	}
	return sh7095_periph32(address, sh2);
}

static uint16_t sh7095_read_16(uint32_t address, sh2_context *sh2)
{
	sh7095_run(sh2);
	//FIXME: probably wrong for 8-bit wide peripheral addresses
	sh2->cycles += sh2->opts->gen.clock_divider;
	address &= 0x1FE;
	return sh2->peripherals[address] << 8 | sh2->peripherals[address | 1];
}

static uint8_t sh7095_read_8(uint32_t address, sh2_context *sh2)
{
	sh7095_run(sh2);
	sh2->cycles += sh2->opts->gen.clock_divider;
	address &= 0x1FF;
	return sh2->peripherals[address];
}

void sh7095_setup(sh2_context *sh2)
{
	sh2->periph_state = calloc(1, sizeof(sh7095_periph));
	sh2->write32[7] = sh7095_write_32;
	sh2->write16[7] = sh7095_write_16;
	sh2->write8[7] = sh7095_write_8;
	sh2->read32[7] = sh7095_read_32;
	sh2->read16[7] = sh7095_read_16;
	sh2->read8[7] = sh7095_read_8;
	sh2->periph_reset = sh7095_reset;
	sh2->periph_run = sh7095_run;
	if (!did_write_mask_setup) {
		did_write_mask_setup = 1;
		memset(write_masks, 0xFF, sizeof(write_masks));
		write_masks[SH_RDR] = 0;
		write_masks[SH_FRCH] = 0; //writes go to TEMP
		write_masks[SH_FTCSR] = 0x01; //other bits can only be cleared, handled in sh7095_write_byte
		write_masks[SH_TOCR] = 0x1F;
		write_masks[SH_ICRH] = write_masks[SH_ICRL] = 0;
		write_masks[SH_IPRA + 1] = 0xF0;
		write_masks[SH_IPRB + 1] = 0x00;
		write_masks[SH_VCRA] = 0x7F;
		write_masks[SH_VCRA + 1] = 0x7F;
		write_masks[SH_VCRB] = 0x7F;
		write_masks[SH_VCRB + 1] = 0x7F;
		write_masks[SH_VCRC] = 0x7F;
		write_masks[SH_VCRC + 1] = 0x7F;
		write_masks[SH_VCRD] = 0x7F;
		write_masks[SH_VCRD + 1] = 0;
		write_masks[SH_VCRWDT] = 0x7F;
		write_masks[SH_VCRWDT + 1] = 0x7F;
		write_masks[SH_VCRDIV] = 0;
		write_masks[SH_VCRDIV + 1] = 0;
		write_masks[SH_VCRDMA0] = 0;
		write_masks[SH_VCRDMA0 + 1] = 0;
		write_masks[SH_VCRDMA0 + 2] = 0;
		write_masks[SH_VCRDMA1] = 0;
		write_masks[SH_VCRDMA1 + 1] = 0;
		write_masks[SH_VCRDMA1 + 2] = 0;
		write_masks[SH_ICR] = 0x01;
		write_masks[SH_ICR + 1] = 0x01;
		write_masks[SH_WTCSR] = 0xE7;
		write_masks[SH_RSTCSR] = 0xE0;
		write_masks[SH_DVCR] = 0;
		write_masks[SH_DVCR + 1] = 0;
		write_masks[SH_DVCR + 2] = 0;
		write_masks[SH_DVCR + 3] = 0x03;
		//TODO: User break controller
		write_masks[SH_TCR0] = 0;
		write_masks[SH_TCR1] = 0;
		write_masks[SH_CHCR0] = 0;
		write_masks[SH_CHCR0 + 1] = 0;
		write_masks[SH_CHCR1] = 0;
		write_masks[SH_CHCR1 + 1] = 0;
		write_masks[SH_DRCR0] = 0x03;
		write_masks[SH_DRCR1] = 0x03;
		write_masks[SH_DMAOR] = 0;
		write_masks[SH_DMAOR + 1] = 0;
		write_masks[SH_DMAOR + 2] = 0;
		write_masks[SH_DMAOR + 3] = 0x0F;
		write_masks[SH_BCR1] = 0x1F;
		write_masks[SH_BCR1 + 1] = 0xF7;
		write_masks[SH_BCR2] = 0;
		write_masks[SH_BCR2 + 1] = 0xFC;
		write_masks[SH_MCR] = 0xFE;
		write_masks[SH_MCR + 1] = 0xFC;
		write_masks[SH_RTCSR] = 0;
		write_masks[SH_RTCSR + 1] = 0xF8;
		write_masks[SH_RTCNT] = 0;
		write_masks[SH_RTCOR] = 0;
		write_masks[SH_SBYCR] = 0xDF;
		write_masks[SH_CCR] = 0xCF;//CP is writeable, but always reads 0
	}
}

void sh7095_free(sh2_context *sh2)
{
	free(sh2->periph_state);
}

void sh7095_adjust_cycles(sh2_context *sh2, uint32_t deduction)
{
	sh7095_periph *p = sh2->periph_state;
	if (deduction < p->cycle) {
		p->cycle -= deduction;
	} else {
		p->cycle = 0;
	}
}

static void sh7095_ack_sci_ti(sh2_context *sh2)
{
	sh7095_run(sh2);
	sh7095_periph *p = sh2->periph_state;
	p->ti_pending = 0;
}

static void sh7095_ack_sci_ri(sh2_context *sh2)
{
	sh7095_run(sh2);
	sh7095_periph *p = sh2->periph_state;
	p->ri_pending = 0;
}

static void sh7095_ack_sci_tei(sh2_context *sh2)
{
	sh7095_run(sh2);
	sh7095_periph *p = sh2->periph_state;
	p->tei_pending = 0;
}

static void sh7095_ack_sci_eri(sh2_context *sh2)
{
	sh7095_run(sh2);
	sh7095_periph *p = sh2->periph_state;
	p->eri_pending = 0;
}

static void sh7095_ack_dmac0(sh2_context *sh2)
{
	sh7095_run(sh2);
	sh7095_periph *p = sh2->periph_state;
	p->dmac0_pending = 0;
}

static void sh7095_ack_dmac1(sh2_context *sh2)
{
	sh7095_run(sh2);
	sh7095_periph *p = sh2->periph_state;
	p->dmac1_pending = 0;
}

static void sh7095_ack_iti(sh2_context *sh2)
{
	sh7095_run(sh2);
	sh7095_periph *p = sh2->periph_state;
	p->iti_pending = 0;
}

void sh7095_next_int(sh2_context *sh2, uint32_t priority_mask)
{
	//TODO: predict interrupt timing when possible
	sh7095_periph *p = sh2->periph_state;
	if ((sh2->peripherals[SH_SCR] & BIT_SCR_TIE) && p->ti_pending) {
		uint32_t priority = sh2->peripherals[SH_IPRB] >> 4;
		if (priority_mask < priority && (sh2->int_cycle > sh2->cycles || priority > sh2->int_priority)) {
			sh2->int_cycle = sh2->cycles;
			sh2->int_priority = priority;
			sh2->int_vector = sh2->peripherals[SH_VCRB] & 0x7F;
			sh2->int_ack = sh7095_ack_sci_ti;
		}
	}
	if ((sh2->peripherals[SH_SCR] & BIT_SCR_RIE) && (p->ri_pending || p->eri_pending)) {
		uint32_t priority = sh2->peripherals[SH_IPRB] >> 4;
		if (priority_mask < priority && (sh2->int_cycle > sh2->cycles || priority > sh2->int_priority)) {
			sh2->int_cycle = sh2->cycles;
			sh2->int_priority = priority;
			if (p->eri_pending) {
				sh2->int_vector = sh2->peripherals[SH_VCRA] & 0x7F;
				sh2->int_ack = sh7095_ack_sci_eri;
			} else {
				sh2->int_vector = sh2->peripherals[SH_VCRA + 1] & 0x7F;
				sh2->int_ack = sh7095_ack_sci_ri;
			}
		}
	}
	if (p->tei_pending && (sh2->peripherals[SH_SCR] & BIT_SCR_TEIE)) {
		uint32_t priority = sh2->peripherals[SH_IPRB] >> 4;
		if (priority_mask < priority && (sh2->int_cycle > sh2->cycles || priority > sh2->int_priority)) {
			sh2->int_cycle = sh2->cycles;
			sh2->int_priority = priority;
			sh2->int_vector = sh2->peripherals[SH_VCRB + 1] & 0x7F;
			sh2->int_ack = sh7095_ack_sci_tei;
		}
	}
	if (p->dmac0_pending && (sh2->peripherals[SH_CHCR0 + 3] & BIT_CHCR_IE)) {
		uint32_t priority = sh2->peripherals[SH_IPRA] & 0xF;
		if (priority_mask < priority && (sh2->int_cycle > sh2->cycles || priority > sh2->int_priority)) {
			sh2->int_cycle = sh2->cycles;
			sh2->int_priority = priority;
			sh2->int_vector = sh2->peripherals[SH_VCRDMA0 + 3] & 0x7F;
			sh2->int_ack = sh7095_ack_dmac0;
		}
	}
	if (p->dmac1_pending && (sh2->peripherals[SH_CHCR1 + 3] & BIT_CHCR_IE)) {
		uint32_t priority = sh2->peripherals[SH_IPRA] & 0xF;
		if (priority_mask < priority && (sh2->int_cycle > sh2->cycles || priority > sh2->int_priority)) {
			sh2->int_cycle = sh2->cycles;
			sh2->int_priority = priority;
			sh2->int_vector = sh2->peripherals[SH_VCRDMA1 + 3] & 0x7F;
			sh2->int_ack = sh7095_ack_dmac1;
		}
	}
	if ((sh2->peripherals[SH_WTCSR] & (BIT_WTCSR_TME|BIT_WTCSR_WTIT)) == BIT_WTCSR_TME) {
		//WDT is enabled and in interval timer mode
		uint32_t priority = sh2->peripherals[SH_IPRA+1] >> 4;
		if (priority_mask < priority) {
			uint32_t next_wdt_int;
			if (p->iti_pending) {
				next_wdt_int = sh2->cycles;
			} else {
				uint32_t cks = wdt_counter_values[sh2->peripherals[SH_WTCSR] & 7] * sh2->opts->gen.clock_divider;
				next_wdt_int = p->cycle + p->wdt_counter + (0xFF - sh2->peripherals[SH_WTCNT]) * cks;
			}
			if (sh2->int_cycle > next_wdt_int || (sh2->int_cycle == next_wdt_int && priority > sh2->int_priority)) {
				sh2->int_cycle = next_wdt_int;
				sh2->int_priority = priority;
				sh2->int_vector = sh2->peripherals[SH_VCRWDT] & 0x7F;
				sh2->int_ack = sh7095_ack_iti;
			}
		}
	}
}
