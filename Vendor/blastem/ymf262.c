#include <stdlib.h>
#include <string.h>
#include "ymf262.h"
#include "render_audio.h"

void ymf262_init(ymf262_context *context, uint32_t master_clock, uint32_t clock_div, uint32_t options)
{
	memset(context, 0, sizeof(*context));
	context->clock_inc = clock_div * 8;
	context->audio = render_audio_source("YMF262", master_clock, context->clock_inc * OPL3_NUM_OPERATORS, 2);
	ymf262_reset(context);
}

void ymf262_reset(ymf262_context *context)
{
	//TODO: implement me
}

void ymf262_free(ymf262_context *context)
{
	render_free_source(context->audio);
	free(context);
}

void ymf262_adjust_master_clock(ymf262_context *context, uint32_t master_clock)
{
	render_audio_adjust_clock(context->audio, master_clock, context->clock_inc * OPL3_NUM_OPERATORS);
}

void ymf262_adjust_cycles(ymf262_context *context, uint32_t deduction)
{
	context->cycle -= deduction;
}

void ymf262_run(ymf262_context *context, uint32_t to_cycle)
{
	for (; context->cycle < to_cycle; context->cycle += context->clock_inc)
	{
		context->current_op++;
		if (context->current_op == OPL3_NUM_OPERATORS) {
			context->current_op = 0;
			int16_t left = 0, right = 0;
			render_put_stereo_sample(context->audio, left, right);
		}
	}
}

void ymf262_address_write_part1(ymf262_context *context, uint8_t address)
{
	context->selected_reg = address;
	context->selected_part = 0;
}
void ymf262_address_write_part2(ymf262_context *context, uint8_t address)
{
	context->selected_reg = address;
	context->selected_part = 0;
}

static void ymf262_update_connections(ymf262_context *context, uint8_t channel, uint8_t csel_bit)
{
	uint8_t channel_off = channel >= 9 ? channel - 9 : channel;
	uint8_t op = channel_off;
	if (op > 5) {
		op += 6;
	} else if (op > 2) {
		op += 3;
	}
	if (channel >= 9) {
		op += 18;
	}
	if (context->opl3_mode && channel_off < 6 && (context->connection_sel & csel_bit)) {
		if (channel_off > 2) {
			channel -= 3;
			op -= 6;
		}
		uint8_t alg = (context->channels[channel].algorithm & 1) << 1;
		alg |= context->channels[channel + 3].algorithm & 1;
		switch (alg)
		{
		case 0:
			context->operators[op + 3].mod_src[0] = &context->operators[op].output;
			context->operators[op + 6].mod_src[0] = &context->operators[op + 3].output;
			context->operators[op + 9].mod_src[0] = &context->operators[op + 6].output;
			break;
		case 1:
			context->operators[op + 3].mod_src[0] = &context->operators[op].output;
			context->operators[op + 6].mod_src[0] = NULL;
			context->operators[op + 9].mod_src[0] = &context->operators[op + 6].output;
			break;
		case 2:
			context->operators[op + 3].mod_src[0] = NULL;
			context->operators[op + 6].mod_src[0] = &context->operators[op + 3].output;
			context->operators[op + 9].mod_src[0] = &context->operators[op + 6].output;
			break;
		case 3:
			context->operators[op + 3].mod_src[0] = NULL;
			context->operators[op + 6].mod_src[0] = &context->operators[op + 3].output;
			context->operators[op + 9].mod_src[0] = NULL;
			break;
		}
	} else {
		context->operators[op].mod_src[0] = NULL;
		context->operators[op + 3].mod_src[0] = context->channels[channel].algorithm ? NULL : &context->operators[op].output;
	}
}

void ymf262_calc_phase_inc(ymf262_context *context, ym_channel *channel, ym_operator *operator)
{
	int32_t inc = channel->fnum;
	//TODO: vibrato?
	if (!channel->block) {
		inc >>= 1;
	} else {
		inc <<= (channel->block-1);
	}
	if (operator->multiple) {
		inc *= operator->multiple;
		inc &= 0xFFFFF;
	} else {
		//0.5
		inc >>= 1;
	}
	operator->phase_inc = inc;
}

#define OPL3_NTS 0x08

void ymf262_data_write(ymf262_context *context, uint8_t value)
{
	if (!context->selected_reg) {
		return;
	}
	uint8_t old = 0;
	if (context->selected_reg >= OPL3_PARAM_START && context->selected_reg < OPL3_PARAM_END) {
		uint8_t channel, op;
		if (context->selected_part) {
			old = context->part2_regs[context->selected_reg - OPL3_PARAM_START];
			context->part2_regs[context->selected_reg - OPL3_PARAM_START] = value;
			channel = 9;
			op = 18;
		} else {
			old = context->part1_regs[context->selected_reg - OPL3_PARAM_START];
			context->part1_regs[context->selected_reg - OPL3_PARAM_START] = value;
			channel = 0;
			op = 0;
		}
		if (context->selected_reg < 0xA0 || context->selected_reg >= 0xE0) {
			uint8_t op_off = context->selected_reg & 0x1F;
			if ((op_off >= 0x26 && op_off < 0x28) || (op_off >= 0x2E && op_off < 0x30) || op_off > 0x35) {
				return;
			}
			if (op_off >= 0x30) {
				op_off -= 4;
			} else if (op_off >= 0x28) {
				op_off -= 2;
			}
			op += op_off;
			ym_operator *operator = context->operators + op;
			switch (context->selected_reg & 0xE0)
			{
			case 0x20:
				operator->multiple = value & 0xF;
				operator->rates[PHASE_SUSTAIN] = (value & 0x20) ? 0 : operator->rates[PHASE_RELEASE];
				operator->am = value & 0x80;
				//TODO: KSR,VIB
				break;
			case 0x40:
				operator->total_level = (value & 0x3F) << 6;
				//TODO: KSL
				break;
			case 0x60:
				//TODO: what should the LSB be?
				operator->rates[PHASE_ATTACK] = (value & 0xF0) >> 3 | 1;
				operator->rates[PHASE_DECAY] = (value & 0xF) << 1 | 1;
				break;
			case 0x80:
				operator->rates[PHASE_RELEASE] = (value & 0xF) << 1 | 1;
				operator->sustain_level = (value & 0xF0) << 3;
				if (operator->sustain_level == 0x780) {
					operator->sustain_level = MAX_ENVELOPE;
				}
				if (!((context->selected_part ? context->part2_regs : context->part1_regs)[context->selected_reg - 0x60] & 0x20)) {
					operator->rates[PHASE_SUSTAIN] = operator->rates[PHASE_RELEASE];
				}
				break;
			case 0xE0:
				operator->wave = value & (context->opl3_mode ? 0x7 : 0x3);
				break;
			}
		} else {
			uint8_t channel_off = context->selected_reg & 0xF;
			if (channel_off > 8 && context->selected_reg != 0xBD) {
				return;
			}
			uint8_t csel_bit = channel_off > 2 ? channel_off - 3 : channel_off;
			if (channel) {
				csel_bit += 3;
			}
			csel_bit = 1 << csel_bit;
			if (context->selected_reg < 0xC0 && context->opl3_mode && (channel_off > 2 && channel_off < 6) && (context->connection_sel & csel_bit)) {
				//ignore writes to "upper" channel in 4-op mode
				return;
			}
			channel += channel_off;
			op = channel_off;
			if (op > 5) {
				op += 6;
			} else if (op > 2) {
				op += 3;
			}
			ym_channel *chan = context->channels + channel;
			switch(context->selected_reg & 0xF0)
			{
			case 0xA0:
				chan->fnum &= ~0xFF;
				chan->fnum |= value;
				ymf262_calc_phase_inc(context, chan, context->operators + op);
				ymf262_calc_phase_inc(context, chan, context->operators + op + 3);
				if (context->opl3_mode && channel_off < 6 && (context->connection_sel & csel_bit)) {
					//4-op mode
					ymf262_calc_phase_inc(context, chan, context->operators + op + 6);
					ymf262_calc_phase_inc(context, chan, context->operators + op + 9);
				}
				break;
			case 0xB0:
				chan->fnum &= 0xFF;
				chan->fnum |= (value & 0x3) << 8;
				chan->block = (value >> 2) & 7;
				ymf262_calc_phase_inc(context, chan, context->operators + op);
				ymf262_calc_phase_inc(context, chan, context->operators + op + 3);
				if (context->opl3_mode && channel_off < 6 && (context->connection_sel & csel_bit)) {
					//4-op mode
					ymf262_calc_phase_inc(context, chan, context->operators + op + 6);
					ymf262_calc_phase_inc(context, chan, context->operators + op + 9);
				}
				if ((value ^ old) & 0x20) {
					if (value & 0x20) {
						keyon(context->operators + op, chan);
						keyon(context->operators + op + 3, chan);
						if (context->opl3_mode && channel_off < 6 && (context->connection_sel & csel_bit)) {
							//4-op mode
							keyon(context->operators + op + 6, chan);
							keyon(context->operators + op + 9, chan);
						}
					} else {
						keyoff(context->operators + op);
						keyoff(context->operators + op + 3);
						if (context->opl3_mode && channel_off < 6 && (context->connection_sel & csel_bit)) {
							//4-op mode
							keyoff(context->operators + op + 6);
							keyoff(context->operators + op + 9);
						}
					}
				}
				break;
			case 0xC0:
				chan->algorithm = value & 1;
				chan->feedback = value >> 1 & 0x7;
				chan->lr = value & 0xF0;
				ymf262_update_connections(context, channel, csel_bit);
				break;
			}
		}
	} else if (context->selected_part) {
		if (context->selected_reg <= sizeof(context->timer_test)) {
			old = context->timer_test[context->selected_reg - 1];
			context->timer_test[context->selected_reg - 1] = value;
		} else if (context->selected_reg == OPL3_NTS) {
			old = context->nts;
			context->nts = value;
		} else {
			return;
		}
	} else {
	
		switch (context->selected_reg)
		{
		case 0x01:
			old = context->part2_test;
			context->part2_test = value;
			break;
		case 0x04:
			old = context->connection_sel;
			context->connection_sel = value;
			if (context->opl3_mode) {
				uint8_t changes = old ^ value;
				for (uint8_t i = 0; i < 6; i++)
				{
					uint8_t csel_bit = 1 << i;
					if (changes & csel_bit) {
						uint8_t channel = i > 2 ? i + 9 : i;
						if (value & csel_bit) {
							//switched to 4-op mode
							ymf262_update_connections(context, channel, csel_bit);
						} else {
							//switched to 2-op mode
							ymf262_update_connections(context, channel, csel_bit);
							ymf262_update_connections(context, channel + 3, csel_bit);
						}
					}
				}
			}
			break;
		case 0x05:
			old = context->opl3_mode;
			context->opl3_mode = value;
			break;
		default:
			return;
		}
	}
	if (value != old) {
		if (context->vgm) {
			if (context->selected_reg) {
				vgm_ymf262_part2_write(context->vgm, context->cycle, context->selected_reg, value);
			} else {
				vgm_ymf262_part1_write(context->vgm, context->cycle, context->selected_reg, value);
			}
		}
	}
}

void ymf262_vgm_log(ymf262_context *context, uint32_t master_clock, vgm_writer *vgm)
{
	vgm_ymf262_init(vgm, 8 * master_clock / context->clock_inc);
	context->vgm = vgm;
	//TODO: write initial state
}

uint8_t ymf262_read_status(ymf262_context *context, uint32_t cycle, uint32_t port)
{
	if (port) {
		//TODO: Investigate behavior of invalid status reads
		return 0xFF;
	}
	return context->status;
}
