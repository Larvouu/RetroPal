#include <string.h>
#include "ymz263b.h"
#include "backend.h"

enum {
	YMZ_SELT,
	YMZ_LSI_TEST,
	YMZ_TIMER0_LOW,
	YMZ_TIMER0_HIGH,
	YMZ_TIMER_BASE,
	YMZ_TIMER1,
	YMZ_TIMER2_LOW,
	YMZ_TIMER2_HIGH,
	YMZ_TIMER_CTRL,
	YMZ_PCM_PLAY_CTRL,
	YMZ_PCM_VOL,
	YMZ_PCM_DATA,
	YMZ_PCM_CTRL,
	YMZ_MIDI_CTRL,
	YMZ_MIDI_DATA
};

//YMZ_SELT
#define BIT_SELT    0x01

//YMZ_TIMER_CTRL
#define BIT_ST0     0x01
#define BIT_ST1     0x02
#define BIT_ST2     0x04
#define BIT_STBC    0x08
#define BIT_T0_MSK  0x10
#define BIT_T1_MSK  0x20
#define BIT_T2_MSK  0x40

#define TIMER_RUN_MASK (BIT_ST0|BIT_ST1|BIT_ST2)
#define TIMER_INT_MASK (BIT_T0_MSK|BIT_T1_MSK|BIT_T2_MSK)

//YMZ_PCM_PLAY_CTRL
#define BIT_ADP_ST  0x01
#define BIT_PLY_REC 0x02
#define BIT_PCM     0x04
#define BIT_PAN_L   0x20
#define BIT_PAN_R   0x40
#define BIT_ADP_RST 0x80

//YMZ_PCM_FIFO_CTRL
#define BIT_DMA_ENB 0x01
#define BIT_MSK_FIF 0x02
#define BIT_DMA_MOD 0x80

//YMZ_MIDI_CTRL
#define BIT_MSK_RRQ 0x01
#define BIT_MRC_RST 0x02
#define BIT_MSK_TRQ 0x04
#define BIT_MTR_RST 0x08
#define BIT_MSK_MOV 0x10
#define BIT_MSK_POV 0x20

#define STATUS_FIF1 0x01
#define STATUS_FIF2 0x02
#define STATUS_RRQ  0x04
#define STATUS_TRQ  0x08
#define STATUS_T0   0x10
#define STATUS_T1   0x20
#define STATUS_T2   0x40
#define STATUS_OV   0x80

#define TIMER_DIVIDER 32
#define MIDI_BYTE_DIVIDER 170
#define PCM_BASE_DIVIDER 12

#define FIFO_EMPTY 255
void ymz263b_init(ymz263b *ymz, uint32_t master_clock, uint32_t clock_divider)
{
	memset(ymz, 0, sizeof(*ymz));
	ymz->clock_inc = clock_divider * TIMER_DIVIDER;
	ymz->audio = render_audio_source("YMZ263B", master_clock, ymz->clock_inc * PCM_BASE_DIVIDER, 2);
	ymz->base_regs[YMZ_SELT] = 1;
	ymz->pcm[0].regs[0] = BIT_ADP_RST;
	ymz->pcm[1].regs[0] = BIT_ADP_RST;
	ymz->pcm[0].counter = 1;
	ymz->pcm[0].fifo_read = FIFO_EMPTY;
	ymz->pcm[1].counter = 1;
	ymz->pcm[1].fifo_read = FIFO_EMPTY;
	ymz->midi_regs[0] = BIT_MTR_RST | BIT_MRC_RST;
	ymz->midi_trs.read = ymz->midi_rcv.read = FIFO_EMPTY;
	ymz->status = 0;
	ymz->pcm_counter = PCM_BASE_DIVIDER;
}

void ymz263b_free(ymz263b *ymz)
{
	render_free_source(ymz->audio);
}

void ymz263b_adjust_master_clock(ymz263b *ymz, uint32_t master_clock)
{
	render_audio_adjust_clock(ymz->audio, master_clock, ymz->clock_inc * PCM_BASE_DIVIDER);
}

static uint8_t fifo_empty(ymz_midi_fifo *fifo)
{
	return fifo->read == FIFO_EMPTY;
}

static uint8_t fifo_read(ymz_midi_fifo *fifo)
{
	uint8_t ret = fifo->fifo[fifo->read++];
	fifo->read &= 15;
	if (fifo->read == fifo->write) {
		fifo->read = FIFO_EMPTY;
	}
	return ret;
}

static uint8_t fifo_write(ymz_midi_fifo *fifo, uint8_t value)
{
	uint8_t overflow = fifo->read == fifo->write;
	if (fifo->read == FIFO_EMPTY) {
		fifo->read = fifo->write;
	}
	fifo->fifo[fifo->write++] = value;
	fifo->write &= 15;
	return overflow;
}

static uint8_t fifo_size(ymz_midi_fifo *fifo)
{
	if (fifo->read == FIFO_EMPTY) {
		return 0;
	}
	if (fifo->read == fifo->write) {
		return 16;
	}
	return (fifo->write - fifo->read) & 15;
}

static uint8_t pcm_fifo_empty(ymz263b_pcm *pcm)
{
	return pcm->fifo_read == FIFO_EMPTY;
}

static uint16_t pcm_fifo_read(ymz263b_pcm *pcm, uint8_t nibbles)
{
	uint16_t ret = 0;
	for (; nibbles && !pcm_fifo_empty(pcm); nibbles--)
	{
		ret <<= 4;
		if (pcm->nibble) {
			ret |= pcm->fifo[pcm->fifo_read++] & 0xF;
			pcm->fifo_read &= sizeof(pcm->fifo) - 1;
			pcm->nibble = 0;
			if (pcm->fifo_read == pcm->fifo_write) {
				pcm->fifo_read = FIFO_EMPTY;
			}
		} else {
			ret |= pcm->fifo[pcm->fifo_read] >> 4;
			pcm->nibble = 1;
		}
	}
	return ret;
}

static uint8_t pcm_fifo_write(ymz263b_pcm *pcm, uint8_t nibbles, uint16_t value)
{
	uint8_t overflow = 0;
	value <<= (4 - nibbles) * 4;
	for (; nibbles; nibbles--)
	{
		if (pcm->nibble_write) {
			pcm->fifo[pcm->fifo_write++] |= value >> 12;
			pcm->fifo_write &= sizeof(pcm->fifo) - 1;
			pcm->nibble_write = 0;
		} else {
			if (pcm->fifo_read == FIFO_EMPTY) {
				pcm->fifo_read = pcm->fifo_write;
			} else if (pcm->fifo_read == pcm->fifo_write) {
				overflow = 1;
			}
			pcm->fifo[pcm->fifo_write] = value >> 8 & 0xF0;
			pcm->nibble_write = 1;
		}
		value <<= 4;
	}
	return overflow;
}

static uint8_t pcm_fifo_free(ymz263b_pcm *pcm)
{
	if (pcm->fifo_read == FIFO_EMPTY) {
		return sizeof(pcm->fifo);
	}
	return (pcm->fifo_read - pcm->fifo_write) & (sizeof(pcm->fifo) - 1);
}

static uint8_t pcm_dividers[] = {1, 2, 4, 6, 8};
static void ymz263b_pcm_run(ymz263b *ymz, ymz263b_pcm *pcm, int16_t *output)
{
	if ((pcm->regs[0] & (BIT_ADP_RST|BIT_ADP_ST)) != BIT_ADP_ST) {
		//PCM channel is either in reset or not started
		return;
	}
	pcm->counter--;
	if (!pcm->counter) {
		uint8_t fs = pcm->regs[0] >> 3 & 3;
		if (!(pcm->regs[0] & BIT_PCM)) {
			//ADPCM can't use 44.1 kHz, but gains 5.5125 kHz
			fs++;
		}
		pcm->counter = pcm_dividers[fs];
		uint8_t nibbles = (pcm->regs[3] >> 5 & 3) + 2;
		if (nibbles > 4) {
			//4-bit format is encoded as the highest value for some reason
			nibbles = 1;
		}
		//adlib driver suggests that FMT should be 3 for 4-bit ADPCM, but Copera games seem to use zero
		//maybe FMT is ignored for ADPCM mode?
		if (!(pcm->regs[0] & BIT_PCM)) {
			nibbles = 1;
		}
		//adlib driver sets SELF to 5 for playback to trigger int "when less than 32 bytes in fifo" aka 96 bytes free
		//adlib driver sets SELF to 3 for recording to trigger int "when more than 64 bytes in fifo" aka 64 bytes free
		uint8_t fifo_threshold = ((pcm->regs[3] >> 2 & 7) + 1) << 4;
		if (pcm->regs[0] & BIT_PLY_REC) {
			//Playback mode
			uint16_t sample = pcm_fifo_read(pcm, nibbles);
			if (pcm->regs[0] & BIT_PCM) {
				//TODO: Presumably SELT bit impacts this
				if (sample & (1 << (nibbles * 4 - 1))) {
					sample |= 0xFFF << (nibbles * 4);
				}
				switch (nibbles)
				{
				case 1:
					sample <<= 8;
					break;
				case 2:
					sample <<= 4;
					break;
				case 4:
					//PCem's code seems to imply the "hole" is in the middle
					//but that's ugly so hoping it's incorrect
					sample >>= 4;
					break;
				}
				pcm->output = sample;
				if (pcm->output & 0x800) {
					pcm->output |= 0xF000;
				} else {
					pcm->output &= 0x0FFF;
				}
			} else {
				//This uses superctr's YMZ280B decoder as a reference
				//That chip has 16-bit output, but supposedly is compatible
				//with ADPCM data from the YM263B
				//Currently I'm 'calculating as 16-bit internally and
				//truncating to 12-bit on output
				uint16_t mag = sample & 7;
				int32_t delta = (((mag << 1) + 1) * pcm->adpcm_step) >> 3;
				if (delta > 0x7FFF) {
					delta = 0x7FFF;
				}
				if (sample & 8) {
					delta = -delta;
				}
				int32_t value = ((int16_t)pcm->output);
				value = (value * 254) >> 8;
				value += delta;
				if (value > 0x7FFF) {
					value = 0x7FFF;
				} else if (value < -0x8000) {
					value = -0x8000;
				}
				pcm->output = value;
				
				static const uint16_t step_adjust[8] = {
					230, 230, 230, 230, 307, 409, 512, 614
				};
				int32_t step = pcm->adpcm_step * step_adjust[mag];
				if (step > 24576) {
					step = 24576;
				} else if (step < 127) {
					step = 127;
				}
				pcm->adpcm_step = step;
			}
			if (pcm_fifo_free(pcm) > fifo_threshold) {
				ymz->status |= pcm == &ymz->pcm[0] ? STATUS_FIF1 : STATUS_FIF2;
			}
		} else {
			//Recording mode
			//TODO: support recording actual audio input
			if (pcm_fifo_write(pcm, nibbles, 0)) {
				ymz->status |= STATUS_OV;
			}
			if (pcm_fifo_free(pcm) < fifo_threshold) {
				ymz->status |= pcm == &ymz->pcm[0] ? STATUS_FIF1 : STATUS_FIF2;
			}
		}
		
	}
	
	if (pcm->regs[0] & BIT_PLY_REC) {
		//TODO: Volume
		int16_t value = pcm->output;
		if (!(pcm->regs[0] & BIT_PCM)) {
			value >>= 4;
		}
		if (pcm->regs[0] & BIT_PAN_L) {
			output[0] += value;
		}
		if (pcm->regs[0] & BIT_PAN_R) {
			output[1] += value;
		}
	}
}

void ymz263b_run(ymz263b *ymz, uint32_t target_cycle)
{
	uint8_t timer_ctrl = ymz->base_regs[YMZ_TIMER_CTRL];
	for (; ymz->cycle < target_cycle; ymz->cycle += ymz->clock_inc)
	{
		if (timer_ctrl & BIT_ST0) {
			ymz->timers[0]--;
			if (!ymz->timers[0]) {
				ymz->timers[0] = ymz->base_regs[YMZ_TIMER0_HIGH] << 8 | ymz->base_regs[YMZ_TIMER0_LOW];
				ymz->status |= STATUS_T0;
			}
		}
		if (timer_ctrl & BIT_STBC) {
			ymz->timers[3]--;
			ymz->timers[3] &= 0xFFF;
			if (!ymz->timers[3]) {
				ymz->timers[3] = ymz->base_regs[YMZ_TIMER1] << 8 & 0xF00;
				ymz->timers[3] |= ymz->base_regs[YMZ_TIMER_BASE];
				
				if (timer_ctrl & BIT_ST1) {
					ymz->timers[1]--;
					if (!ymz->timers[1]) {
						ymz->timers[1] = ymz->base_regs[YMZ_TIMER1] >> 4;
						ymz->status |= STATUS_T1;
					}
				}
				
				if (timer_ctrl & BIT_ST2) {
					ymz->timers[2]--;
					if (!ymz->timers[2]) {
						ymz->timers[2] = ymz->base_regs[YMZ_TIMER2_HIGH] << 8 | ymz->base_regs[YMZ_TIMER2_LOW];
						ymz->status |= STATUS_T2;
					}
				}
			}
		}
		if (!(ymz->midi_regs[0] & BIT_MTR_RST) && !fifo_empty(&ymz->midi_trs)) {
			if (ymz->midi_transmit) {
				--ymz->midi_transmit;
			} else {
				ymz->midi_transmit = MIDI_BYTE_DIVIDER - 1;
				//TODO: send this byte to MIDI device
				uint8_t byte = fifo_read(&ymz->midi_trs);
				printf("MIDI Transmit: %X\n", byte);
				if (fifo_empty(&ymz->midi_trs)) {
					ymz->status |= STATUS_TRQ;
				}
			}
		}
		ymz->pcm_counter--;
		if (!ymz->pcm_counter) {
			ymz->pcm_counter = PCM_BASE_DIVIDER;
			int16_t output[2] = {0, 0};
			ymz263b_pcm_run(ymz, &ymz->pcm[0], output);
			ymz263b_pcm_run(ymz, &ymz->pcm[1], output);
			render_put_stereo_sample(ymz->audio, output[0], output[1]);
		}
	}
}

static uint32_t predict_fifo_thres(ymz263b *ymz, ymz263b_pcm *pcm)
{
	if ((pcm->regs[0] & (BIT_ADP_RST|BIT_ADP_ST)) != BIT_ADP_ST) {
		//PCM channel is either in reset or not started
		return CYCLE_NEVER;
	}
	uint32_t next_pcm_cycle = ymz->cycle + ymz->pcm_counter * ymz->clock_inc;
	next_pcm_cycle += (pcm->counter - 1) * PCM_BASE_DIVIDER * ymz->clock_inc;
	uint32_t fifo_free = pcm_fifo_free(pcm);
	//convert to nibbles
	fifo_free <<= 1;
	uint32_t fifo_threshold = ((pcm->regs[3] >> 2 & 7) + 1) << 5;
	uint32_t diff;
	if (pcm->regs[0] & BIT_PLY_REC) {
		if (pcm->nibble) {
			fifo_free++;
		}
		diff = fifo_threshold - fifo_free + 1;
	} else {
		if (pcm->nibble_write) {
			fifo_free--;
		}
		diff = fifo_free - fifo_threshold + 1;
	}
	uint32_t nibbles_per_samp = (pcm->regs[3] >> 5 & 3) + 2;
	if (nibbles_per_samp > 4) {
		//4-bit format is encoded as the highest value for some reason
		nibbles_per_samp = 1;
	}
	uint8_t fs = pcm->regs[0] >> 3 & 3;
	if (!(pcm->regs[0] & BIT_PCM)) {
		//ADPCM can't use 44.1 kHz, but gains 5.5125 kHz
		fs++;
		//see note in PCM playback code
		nibbles_per_samp = 1;
	}
	diff /= nibbles_per_samp;
	
	next_pcm_cycle += diff * PCM_BASE_DIVIDER * pcm_dividers[fs] * ymz->clock_inc;
	return next_pcm_cycle;
}

uint32_t ymz263b_next_int(ymz263b *ymz)
{
	//TODO: Handle MIDI receive interrupts
	uint8_t enabled_ints = (~ymz->base_regs[YMZ_TIMER_CTRL]) & TIMER_INT_MASK;
	if (!(ymz->base_regs[YMZ_MIDI_CTRL] & (BIT_MTR_RST|BIT_MSK_TRQ))) {
		enabled_ints |= STATUS_TRQ;
	}
	if (!(ymz->pcm[0].regs[3] & BIT_MSK_FIF)) {
		enabled_ints |= STATUS_FIF1;
	}
	if (!(ymz->pcm[1].regs[3] & BIT_MSK_FIF)) {
		enabled_ints |= STATUS_FIF2;
	}
	if (!enabled_ints) {
		return CYCLE_NEVER;
	}
	//Handle currently pending interrupts
	if (enabled_ints & ymz->status) {
		return ymz->cycle;
	}
	
	uint32_t ret = CYCLE_NEVER;
	if (enabled_ints & STATUS_TRQ) {
		uint8_t bytes = fifo_size(&ymz->midi_trs);
		if (bytes) {
			ret = ymz->cycle + (ymz->midi_transmit + 1) * ymz->clock_inc;
			if (bytes > 1) {
				ret += MIDI_BYTE_DIVIDER * ymz->clock_inc * (bytes - 1);
			}
		}
	}
	
	if (enabled_ints & STATUS_FIF1) {
		uint32_t next_pcm = predict_fifo_thres(ymz, &ymz->pcm[0]);
		if (next_pcm < ret) {
			ret = next_pcm;
		}
	}
	if (enabled_ints & STATUS_FIF2) {
		uint32_t next_pcm = predict_fifo_thres(ymz, &ymz->pcm[1]);
		if (next_pcm < ret) {
			ret = next_pcm;
		}
	}
	
	enabled_ints >>= 4;
	//If timers aren't already expired, interrupts can't fire unless the timers are enabled
	enabled_ints &= ymz->base_regs[YMZ_TIMER_CTRL];
	if (!(ymz->base_regs[YMZ_TIMER_CTRL] & BIT_STBC)) {
		//Timer 1 and Timer 2 depend on the base timer
		enabled_ints &= 1;
	}
	if (enabled_ints & BIT_ST0) {
		uint32_t t0 = ymz->cycle + (ymz->timers[0] ? ymz->timers[0] : 0x10000) * ymz->clock_inc;
		if (t0 < ret) {
			ret = t0;
		} 
	}
	if (enabled_ints & (BIT_ST1|BIT_ST2)) {
		uint32_t base = ymz->cycle + (ymz->timers[3] ? ymz->timers[3] : 0x1000) * ymz->clock_inc;
		if (base < ret) {
			uint32_t load = (ymz->base_regs[YMZ_TIMER1] << 8 & 0xF00) | ymz->base_regs[YMZ_TIMER_BASE];
			if (!load) {
				load = 0x1000;
			}
			if (enabled_ints & BIT_ST1) {
				uint32_t t1 = base + (ymz->timers[1] ? ymz->timers[1] - 1 : 0xF) * load * ymz->clock_inc;
				if (t1 < ret) {
					ret = t1;
				}
			}
			if (enabled_ints & BIT_ST2) {
				uint32_t t2 = base + (ymz->timers[2] ? ymz->timers[2] - 1 : 0xFFFF) * load * ymz->clock_inc;
				if (t2 < ret) {
					ret = t2;
				}
			}
		}
	}
	return ret;
}

void ymz263b_address_write(ymz263b *ymz, uint8_t value)
{
	ymz->address = value;
}

void ymz263b_data_write(ymz263b *ymz, uint32_t channel, uint8_t value)
{
	if (channel) {
		if (ymz->address >= YMZ_PCM_PLAY_CTRL && ymz->address < YMZ_MIDI_CTRL) {
			if (ymz->address == YMZ_PCM_PLAY_CTRL) {
				if (((value ^ ymz->pcm[1].regs[0]) & ymz->pcm[1].regs[0]) & BIT_ADP_RST) {
					//Perform reset on falling edge of reset bit
					ymz->pcm[1].counter = 1;
					ymz->pcm[1].fifo_read = FIFO_EMPTY;
					ymz->pcm[1].nibble = ymz->pcm[1].nibble_write = 0;
					ymz->pcm[1].output = 0;
					ymz->pcm[1].adpcm_step = 127;
				}
			}
			ymz->pcm[1].regs[ymz->address - YMZ_PCM_PLAY_CTRL] = value;
			if (ymz->address == YMZ_PCM_DATA) {
				pcm_fifo_write(&ymz->pcm[1], 2, value);
				//Does an overflow here set the overflow statu sflag?
			}
		}
	} else {
		if (ymz->address < YMZ_PCM_PLAY_CTRL) {
			if (ymz->address == YMZ_TIMER_CTRL) {
				uint8_t newly_set = (ymz->base_regs[ymz->address] ^ value) & value;
				if (newly_set & BIT_ST0) {
					ymz->timers[0] = ymz->base_regs[YMZ_TIMER0_HIGH] << 8 | ymz->base_regs[YMZ_TIMER0_LOW];
				}
				if (newly_set & BIT_ST1) {
					ymz->timers[1] = ymz->base_regs[YMZ_TIMER1] >> 4;
				}
				if (newly_set & BIT_ST2) {
					ymz->timers[2] = ymz->base_regs[YMZ_TIMER2_HIGH] << 8 | ymz->base_regs[YMZ_TIMER2_LOW];
				}
				if (newly_set & BIT_STBC) {
					ymz->timers[0] = (ymz->base_regs[YMZ_TIMER1] << 8 | ymz->base_regs[YMZ_TIMER_BASE]) & 0xFFF;
				}
			}
			ymz->base_regs[ymz->address] = value;
		} else if (ymz->address < YMZ_MIDI_CTRL) {
			if (((value ^ ymz->pcm[0].regs[0]) & ymz->pcm[1].regs[0]) & BIT_ADP_RST) {
				//Perform reset on falling edge of reset bit
				ymz->pcm[0].counter = 1;
				ymz->pcm[0].fifo_read = FIFO_EMPTY;
				ymz->pcm[0].nibble = ymz->pcm[1].nibble_write = 0;
				ymz->pcm[0].output = 0;
				ymz->pcm[0].adpcm_step = 127;
			}
			ymz->pcm[0].regs[ymz->address - YMZ_PCM_PLAY_CTRL] = value;
			if (ymz->address == YMZ_PCM_DATA) {
				pcm_fifo_write(&ymz->pcm[0], 2, value);
				//Does an overflow here set the overflow statu sflag?
			}
		} else {
			ymz->midi_regs[ymz->address - YMZ_MIDI_CTRL] = value;
			if (ymz->address == YMZ_MIDI_DATA) {
				ymz->status &= ~STATUS_TRQ;
				if (fifo_empty(&ymz->midi_trs)) {
					ymz->midi_transmit = MIDI_BYTE_DIVIDER - 1;
				}
				fifo_write(&ymz->midi_trs, value);
			}
		}
	}
}

uint8_t ymz263b_data_read(ymz263b *ymz, uint32_t channel)
{
	//TODO: Supposedly only a few registers are actually readable
	if (channel) {
		if (ymz->address >= YMZ_PCM_PLAY_CTRL && ymz->address < YMZ_MIDI_CTRL) {
			if (ymz->address == YMZ_PCM_DATA) {
				return pcm_fifo_read(&ymz->pcm[1], 2);
			}
			return ymz->pcm[1].regs[ymz->address - YMZ_PCM_PLAY_CTRL];
		}
	} else {
		if (ymz->address < YMZ_PCM_PLAY_CTRL) {
			return ymz->base_regs[ymz->address];
		} else if (ymz->address < YMZ_MIDI_CTRL) {
			if (ymz->address == YMZ_PCM_DATA) {
				return pcm_fifo_read(&ymz->pcm[0], 2);
			}
			return ymz->pcm[0].regs[ymz->address - YMZ_PCM_PLAY_CTRL];
		} else {
			return ymz->midi_regs[ymz->address - YMZ_MIDI_CTRL];
		}
	}
	return 0XFF;
}

uint8_t ymz263b_status_read(ymz263b *ymz)
{
	uint8_t ret = ymz->status;
	ymz->status = 0;//&= ~(STATUS_T0|STATUS_T1|STATUS_T2);
	return ret;
}
