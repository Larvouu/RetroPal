#include "i8255.h"

#include <string.h>

#define BIT_OBFA      0x80
#define BIT_ACKA      0x40
#define BIT_IBFA      0x20
#define BIT_STBA      0x10
#define BIT_INTRA     0x08
#define BIT_STB_ACKB  0x04
#define BIT_IBF_OBFB  0x02
#define BIT_INTRB     0x01

#define BIT_INTE1     BIT_ACKA
#define BIT_INTE2     BIT_STBA
#define BIT_INTEB     BIT_STB_ACKB

void i8255_init(i8255 *ppi, i8255_out_update out, i8255_in_sample in)
{
	memset(ppi->latches, 0, sizeof(ppi->latches));
	ppi->control = 0x1B; //all ports start as input
	ppi->portc_write_mask = 0xFF;
	ppi->portc_out_mask = 0;
	ppi->out_handler = out;
	ppi->in_handler = in;
}

static uint8_t porta_out_enabled(i8255 *ppi)
{
	return (ppi->control & 0x40) || !(ppi->control & 0x10);
}

void i8255_write(uint32_t address, i8255 *ppi, uint8_t value, uint32_t cycle)
{
	switch(address)
	{
	case 0:
		ppi->latches[0] = value;
		if (porta_out_enabled(ppi)) {
			if (ppi->control & 0x60) {
				//Mode 1 or 2
				ppi->latches[2] &= ~BIT_OBFA;
				if ((ppi->control & 0x60) == 0x20 || !(ppi->latches[2] & BIT_IBFA)) {
					ppi->latches[2] &= ~BIT_INTRA;
				}
				if (ppi->out_handler) {
					ppi->out_handler(ppi, cycle, 2, ppi->latches[2] & ppi->portc_out_mask);
				}
			}
			if (ppi->out_handler && !(ppi->control & 0x40)) {
				ppi->out_handler(ppi, cycle, address, value);
			}
		}
		break;
	case 1:
		if (!(ppi->control & 0x02)) {
			ppi->latches[1] = value;
			if (ppi->control & 0x04) {
				//Mode 1
				ppi->latches[2] &= ~(BIT_IBF_OBFB|BIT_INTRB);
				if (ppi->out_handler) {
					ppi->out_handler(ppi, cycle, 2, ppi->latches[2] & ppi->portc_out_mask);
				}
			}
			if (ppi->out_handler) {
				ppi->out_handler(ppi, cycle, address, value);
			}
		}
		break;
	case 2:
		ppi->latches[2] &= ~ppi->portc_write_mask;
		ppi->latches[2] |= value & ppi->portc_write_mask;
		if (ppi->out_handler && ppi->portc_out_mask) {
			ppi->out_handler(ppi, cycle, address, ppi->latches[2] & ppi->portc_out_mask);
		}
		break;
	case 3:
		if (value & 0x80) {
			uint8_t changed = ppi->control ^ value;
			//datasheet says "output" state is cleared on mode changes
			if (changed & 0x60) {
				//group A mode changed
				ppi->latches[0] = 0;
				ppi->latches[2] &= 0x0F;
			}
			if (changed & 4) {
				//group B mode changed
				ppi->latches[1] = 0;
				if (value & 0x60) {
					//PC4 is INTRa
					ppi->latches[2] &= 0xF8;
				} else {
					ppi->latches[2] &= 0xF0;
				}
			}
			ppi->control = value;
			ppi->portc_write_mask = ppi->portc_out_mask = 0;
			if (value & 0x40) {
				//Port A Mode 2
				ppi->portc_out_mask |= BIT_OBFA | BIT_IBFA | BIT_INTRA;
				ppi->portc_write_mask |= BIT_INTE1 | BIT_INTE2;
			} else if (value & 0x20) {
				//Port A Mode 1
					ppi->portc_out_mask |= BIT_INTRA;
				if (value & 0x10) {
					//Input
					ppi->portc_out_mask |= BIT_IBFA;
					ppi->portc_write_mask |= BIT_INTE2 | 0xC0;
					if (!(value & 0x08)) {
						//Port C upper Output
						ppi->portc_out_mask |= 0xC0;
					}
				} else {
					//Output
					ppi->portc_out_mask |= BIT_OBFA;
					ppi->portc_out_mask |= BIT_INTE1 | 0x30;
					if (!(value & 0x08)) {
						//Port C upper Output
						ppi->portc_out_mask |= 0x30;
					}
				}
			} else {
				ppi->portc_write_mask |= 0xF0;
				if (!(value & 0x08)) {
					//Port C upper Output
					ppi->portc_out_mask |= 0xF0;
				}
			}
			if (value & 0x04) {
				//Port B Mode 1
				ppi->portc_out_mask |= BIT_IBF_OBFB | BIT_INTRB;
				ppi->portc_write_mask |= BIT_INTEB;
				if (!(ppi->portc_out_mask & BIT_INTRA) && !(value & 1)) {
					//Port C lower Output
					ppi->portc_out_mask |= 0x08;
					ppi->portc_write_mask |= 0x08;
				}
			} else {
				if (!(value & 1)) {
					//Port C lower Output
					ppi->portc_out_mask |= 0x07;
					ppi->portc_write_mask |= 0x07;
					if (!(ppi->portc_out_mask & BIT_INTRA)) {
						ppi->portc_out_mask |= 0x08;
						ppi->portc_write_mask |= 0x08;
					}
				}
			}
		} else {
			uint8_t bit = 1 << ((value >> 1) & 7);
			if (ppi->portc_write_mask & bit) {
				if (value & 1) {
					ppi->latches[2] |= bit;
				} else {
					ppi->latches[2] &= bit;
				}
				if (ppi->out_handler && ppi->portc_out_mask) {
					ppi->out_handler(ppi, cycle, 2, ppi->latches[2] & ppi->portc_out_mask);
				}
			}
		}
		
	}
}

uint8_t i8255_read(uint32_t address, i8255 *ppi, uint32_t cycle)
{
	switch(address)
	{
	case 0:
		if (ppi->control & 0x60) {
			//Mode 1 or 2
			if (ppi->control & 0x50) {
				//Mode 2 or Mode 1 input
				ppi->latches[2] &= ~BIT_IBFA;
				if (!(ppi->control & 0x40) || (ppi->latches[2] & BIT_OBFA)) {
					ppi->latches[2] &= ~BIT_INTRA;
				}
				if (ppi->out_handler) {
					ppi->out_handler(ppi, cycle, 2, ppi->latches[2] & ppi->portc_out_mask);
				}
			}
			return ppi->latches[3];
		}
		if (ppi->control & 0x10) {
			if (ppi->in_handler) {
				return ppi->in_handler(ppi, cycle, address);
			}
			return 0xFF;
		}
		return ppi->latches[0];
	case 1:
		if (ppi->control & 0x40) {
			//Mode 1
			if (ppi->control & 0x2) {
				//input
				ppi->latches[2] &= ~(BIT_IBF_OBFB|BIT_INTRB);
				if (ppi->out_handler) {
					ppi->out_handler(ppi, cycle, 2, ppi->latches[2] & ppi->portc_out_mask);
				}
			}
			return ppi->latches[1];
		}
		if (ppi->control & 0x2) {
			//input
			if (ppi->in_handler) {
				return ppi->in_handler(ppi, cycle, address);
			}
			return 0xFF;
		}
		return ppi->latches[1];
	case 2:
		return ppi->latches[2];
	case 3:
	default:
		return 0xFF;//described as illegal in datasheet
	}
}

void i8255_input_strobe_a(i8255 *ppi, uint8_t value, uint32_t cycle)
{
	if ((ppi->control & 0x70) == 0x30 || (ppi->control & 0x40)) {
		//Mode 2 or Mode 1 input
		ppi->latches[3] = value;
		ppi->latches[2] |= BIT_IBFA;
		if (ppi->latches[2] & BIT_INTE2) {
			ppi->latches[2] |= BIT_INTRA;
		}
		if (ppi->out_handler) {
			ppi->out_handler(ppi, cycle, 2, ppi->latches[2] & ppi->portc_out_mask);
		}
	}
}

void i8255_input_strobe_b(i8255 *ppi, uint8_t value, uint32_t cycle)
{
	if ((ppi->control & 6) == 6) {
		//Mode 1 input
		ppi->latches[1] = value;
		ppi->latches[2] |= BIT_IBF_OBFB;
		if (ppi->latches[2] & BIT_INTEB) {
			ppi->latches[2] |= BIT_INTRB;
		}
		if (ppi->out_handler) {
			ppi->out_handler(ppi, cycle, 2, ppi->latches[2] & ppi->portc_out_mask);
		}
	}
}

uint8_t i8255_output_ack_a(i8255 *ppi, uint32_t cycle)
{
	if ((ppi->control & 0x70) == 0x20 || (ppi->control & 0x40)) {
		//Mode 2 or Mode 1 output
		ppi->latches[2] |= BIT_OBFA;
		if (ppi->latches[2] & BIT_INTE1) {
			ppi->latches[2] |= BIT_INTRA;
		}
		if (ppi->out_handler) {
			ppi->out_handler(ppi, cycle, 2, ppi->latches[2] & ppi->portc_out_mask);
		}
		return ppi->latches[0];
	}
	if (ppi->control & 0x10) {
		//input mode
		return 0xFF;
	}
	//Mode 0 output
	return ppi->latches[0];
}

uint8_t i8255_output_ack_b(i8255 *ppi, uint32_t cycle)
{
	if ((ppi->control & 0x06) == 0x04) {
		//Mode 1 output
		ppi->latches[2] |= BIT_IBF_OBFB;
		if (ppi->latches[2] & BIT_INTEB) {
			ppi->latches[2] |= BIT_INTRB;
		}
		if (ppi->out_handler) {
			ppi->out_handler(ppi, cycle, 2, ppi->latches[2] & ppi->portc_out_mask);
		}
		return ppi->latches[1];
	}
	if (ppi->control & 2) {
		//input mode
		return 0xFF;
	}
	//Mode 0 output
	return ppi->latches[1];
}
