#include "pico_pcm.h"
#include "backend.h"

#define PCM_RESET   0x8000
#define PCM_BUSY    PCM_RESET
#define PCM_INT_EN  0x4000
#define PCM_ENABLED 0x0800
#define PCM_FILTER  0x00C0
#define PCM_VOLUME  0x0007

void pico_pcm_reset(pico_pcm *pcm)
{
	pcm->fifo_read = sizeof(pcm->fifo);
	pcm->fifo_write = 0;
	pcm->adpcm_state = 0;
	pcm->output = 0;
	pcm->nibble_store = 0;
	pcm->counter = 0;
	pcm->samples = 0;
	pcm->rate = 0;
	pcm->ctrl |= PCM_BUSY;
}

void pico_pcm_init(pico_pcm *pcm, uint32_t master_clock, uint32_t divider)
{
	pcm->clock_inc = divider * 4;
	pcm->audio = render_audio_source("PICO ADPCM", master_clock, pcm->clock_inc, 1);
	pcm->scope = NULL;
	pcm->scope_channel = 0;
	pico_pcm_reset(pcm);
}

void pico_pcm_free(pico_pcm *pcm)
{
	render_free_source(pcm->audio);
}

void pico_pcm_adjust_master_clock(pico_pcm *pcm, uint32_t master_clock)
{
	render_audio_adjust_clock(pcm->audio, master_clock, pcm->clock_inc);
}

void pico_pcm_enable_scope(pico_pcm *pcm, oscilloscope *scope, uint32_t master_clock)
{
#ifndef IS_LIB
	pcm->scope = scope;
	pcm->scope_channel = scope_add_channel(scope, "PICO ADPCM", master_clock / pcm->clock_inc);
#endif
}

static uint8_t pcm_fifo_read(pico_pcm *pcm)
{
	if (pcm->fifo_read == sizeof(pcm->fifo)) {
		return 0;
	}
	uint8_t ret = pcm->fifo[pcm->fifo_read++];
	pcm->fifo_read &= sizeof(pcm->fifo) - 1;
	if (pcm->fifo_read == pcm->fifo_write) {
		pcm->fifo_read = sizeof(pcm->fifo);
	}
	return ret;
}

int16_t upd7755_calc_sample(uint8_t sample, uint8_t *state)
{
	//Tables from MAME
	static const int16_t sample_delta[256] = {
		0,  0,  1,  2,  3,   5,   7,  10,  0,   0,  -1,  -2,  -3,   -5,   -7,  -10,
		0,  1,  2,  3,  4,   6,   8,  13,  0,  -1,  -2,  -3,  -4,   -6,   -8,  -13,
		0,  1,  2,  4,  5,   7,  10,  15,  0,  -1,  -2,  -4,  -5,   -7,  -10,  -15,
		0,  1,  3,  4,  6,   9,  13,  19,  0,  -1,  -3,  -4,  -6,   -9,  -13,  -19,
		0,  2,  3,  5,  8,  11,  15,  23,  0,  -2,  -3,  -5,  -8,  -11,  -15,  -23,
		0,  2,  4,  7, 10,  14,  19,  29,  0,  -2,  -4,  -7, -10,  -14,  -19,  -29,
		0,  3,  5,  8, 12,  16,  22,  33,  0,  -3,  -5,  -8, -12,  -16,  -22,  -33,
		1,  4,  7, 10, 15,  20,  29,  43, -1,  -4,  -7, -10, -15,  -20,  -29,  -43,
		1,  4,  8, 13, 18,  25,  35,  53, -1,  -4,  -8, -13, -18,  -25,  -35,  -53,
		1,  6, 10, 16, 22,  31,  43,  64, -1,  -6, -10, -16, -22,  -31,  -43,  -64,
		2,  7, 12, 19, 27,  37,  51,  76, -2,  -7, -12, -19, -27,  -37,  -51,  -76,
		2,  9, 16, 24, 34,  46,  64,  96, -2,  -9, -16, -24, -34,  -46,  -64,  -96,
		3, 11, 19, 29, 41,  57,  79, 117, -3, -11, -19, -29, -41,  -57,  -79, -117,
		4, 13, 24, 36, 50,  69,  96, 143, -4, -13, -24, -36, -50,  -69,  -96, -143,
		4, 16, 29, 44, 62,  85, 118, 175, -4, -16, -29, -44, -62,  -85, -118, -175,
		6, 20, 36, 54, 76, 104, 144, 214, -6, -20, -36, -54, -76, -104, -144, -214
	};
	static const int state_delta[16] = {-1, -1, 0, 0, 1, 2, 2, 3, -1, -1, 0, 0, 1, 2, 2, 3};
	int16_t ret = sample_delta[(*state << 4) + sample];
	int diff = state_delta[sample];
	if (diff >= 0 || *state > 0) {
		*state += diff;
		if (*state > 15) {
			*state = 15;
		}
	}
	return ret;
}

void pico_pcm_run(pico_pcm *pcm, uint32_t cycle)
{
	while (pcm->cycle < cycle)
	{
		pcm->cycle += pcm->clock_inc;
		//TODO: Figure out actual attenuation
		int16_t shift = pcm->ctrl & PCM_VOLUME;
#ifndef IS_LIB
		if (pcm->scope) {
			scope_add_sample(pcm->scope, pcm->scope_channel, (pcm->output >> shift) * 32, 0);
		}
#endif
		render_put_mono_sample(pcm->audio, (pcm->output >> shift) * 32);
		/*
		Unclear what this bit is actually supposed to do
		But some games expect ADPCM to work with it cleared
		Anpanman Pico: Waku Waku Pan Koujou sets the ctrl reg to $6040
		if (!(pcm->ctrl & PCM_ENABLED)) {
			continue;
		}*/
		if (pcm->counter) {
			pcm->counter--;
		} else if (pcm->samples) {
			pcm->samples--;
			uint8_t sample;
			if (pcm->nibble_store) {
				sample = pcm->nibble_store & 0xF;
				pcm->nibble_store = 0;
			} else {
				uint8_t byte = pcm_fifo_read(pcm);
				sample = byte >> 4;
				pcm->nibble_store = 0x80 | (byte & 0xF);
			}
			uint8_t old_state = pcm->adpcm_state;
			pcm->output += upd7755_calc_sample(sample, &pcm->adpcm_state);
			if (pcm->output > 255) {
				pcm->output = 255;
			} else if (pcm->output < -256) {
				pcm->output = -256;
			}
			//printf("Sample %d, old_state %d, new_state %d, output %d\n", sample, old_state, pcm->adpcm_state, pcm->output);
			pcm->counter = pcm->rate;
		} else {
			uint8_t cmd = pcm_fifo_read(pcm);
			if (cmd) {
				pcm->ctrl &= ~PCM_BUSY;
			} else {
				pcm->ctrl |= PCM_BUSY;
			}
			switch (cmd & 0xC0)
			{
			case 0:
				pcm->output = 0;
				pcm->adpcm_state = 0;
				pcm->counter = (cmd & 0x3F) * 160;
				break;
			case 0x40:
				pcm->rate = (cmd & 0x3F);
				pcm->samples = 256;
				pcm->nibble_store = 0;
				break;
			case 0x80:
				pcm->rate = (cmd & 0x3F);
				//FIXME: this probably does not happen instantly
				pcm->samples = pcm_fifo_read(pcm) + 1;
				pcm->nibble_store = 0;
				break;
			case 0xC0:
				//FIXME: this probably does not happen instantly
				//TODO: Does repeat mode even work on this chip?
				//      Does it work on a uPD7759 in slave mode?
				//      Is this correct behavior if it does work?
				pcm->counter = pcm->rate = pcm_fifo_read(pcm) & 0x3F;
				pcm->samples = (pcm_fifo_read(pcm) + 1) * ((cmd & 7) + 1);
				pcm->nibble_store = 0;
				break;
			}
		}
	}
}

// RI??E???FF???VVV
// R: 1 = Reset request, 0 = normal operation
// I: 1 = interrupts enabled, 0 = disabled
// E: 1 = Enabled? Sega code always sets this to 1 outside of reset
// F: Low-pass Filter 1 = 6 kHz, 2 = 12 kHz 3 = 16 kHz
// V: volume, probably attenuation value since converter defaults to "0"
void pico_pcm_ctrl_write(pico_pcm *pcm, uint16_t value)
{
	if (value & PCM_RESET) {
		pico_pcm_reset(pcm);
	}
	pcm->ctrl &= PCM_BUSY;
	pcm->ctrl |= value & ~(PCM_BUSY);
	//TODO: update low-pass filter
}

void pico_pcm_data_write(pico_pcm *pcm, uint16_t value)
{
	if (pcm->fifo_read == pcm->fifo_write) {
		puts("ADPCM fifo overflow");
	}
	if (pcm->fifo_read == sizeof(pcm->fifo)) {
		pcm->fifo_read = pcm->fifo_write;
	}
	pcm->fifo[pcm->fifo_write++] = value >> 8;
	pcm->fifo_write &= sizeof(pcm->fifo)-1;
	if (pcm->fifo_read == pcm->fifo_write) {
		puts("ADPCM fifo overflow");
	}
	pcm->fifo[pcm->fifo_write++] = value;
	pcm->fifo_write &= sizeof(pcm->fifo)-1;
}

uint16_t pico_pcm_ctrl_read(pico_pcm *pcm)
{
	return pcm->ctrl;
}

uint16_t pico_pcm_data_read(pico_pcm *pcm)
{
	if (pcm->fifo_read == sizeof(pcm->fifo)) {
		return sizeof(pcm->fifo) - 1;
	}
	return (pcm->fifo_read - pcm->fifo_write) & (sizeof(pcm->fifo)-1);
}

#define FIFO_THRESHOLD 48
uint32_t pico_pcm_next_int(pico_pcm *pcm)
{
	if (!(pcm->ctrl & PCM_INT_EN)) {
		return CYCLE_NEVER;
	}
	uint32_t fifo_bytes;
	if (pcm->fifo_read == sizeof(pcm->fifo)) {
		fifo_bytes = 0;
	} else if (pcm->fifo_read == pcm->fifo_write) {
		fifo_bytes = sizeof(pcm->fifo);
	} else {
		fifo_bytes = (pcm->fifo_write - pcm->fifo_read) & (sizeof(pcm->fifo) - 1);
	}
	if (fifo_bytes < FIFO_THRESHOLD) {
		return pcm->cycle;
	}
	uint32_t cycles_to_threshold = pcm->counter + 1;
	if (pcm->samples) {
		uint16_t samples = pcm->samples;
		if (pcm->nibble_store) {
			cycles_to_threshold += pcm->rate + 1;
			samples--;
		}
		uint16_t bytes = (samples >> 1) + (samples & 1);
		if (bytes > (fifo_bytes - FIFO_THRESHOLD)) {
			cycles_to_threshold += (fifo_bytes - FIFO_THRESHOLD + 1) * (pcm->rate + 1) * 2;
			fifo_bytes = 0;
		} else {
			cycles_to_threshold += bytes * (pcm->rate + 1) * 2;
			fifo_bytes -= bytes;
		}
	}
	uint8_t fifo_read = pcm->fifo_read;
	uint8_t cmd = 0;
	while (fifo_bytes >= FIFO_THRESHOLD)
	{
		if (cmd) {
			switch(cmd & 0xC0)
			{
			case 0:
				cycles_to_threshold += 640 * (cmd & 0x3F) + 1;
				break;
			case 0x40:
				cycles_to_threshold += (fifo_bytes - FIFO_THRESHOLD + 1) * ((cmd & 0x3F) + 1) * 2;
				fifo_bytes = 0;
				break;
			case 0x80: {
				uint32_t samples = pcm->fifo[fifo_read++];
				fifo_bytes--;
				fifo_read &= sizeof(pcm->fifo) - 1;
				if (fifo_bytes < FIFO_THRESHOLD) {
					break;
				}
				uint32_t bytes = (samples +1) >> 1;
				if (bytes > (fifo_bytes - FIFO_THRESHOLD)) {
					cycles_to_threshold += (fifo_bytes - FIFO_THRESHOLD + 1) * ((cmd & 0x3F) + 1) * 2;
					fifo_bytes = 0;
				}
				break; }
			case 0xC0: {
				uint32_t rate = pcm->fifo[fifo_read++] & 0x3F;
				fifo_bytes--;
				fifo_read &= sizeof(pcm->fifo) - 1;
				uint32_t samples = pcm->fifo[fifo_read++] & 0x3F;
				fifo_bytes--;
				fifo_read &= sizeof(pcm->fifo) - 1;
				if (fifo_bytes < FIFO_THRESHOLD) {
					break;
				}
				samples++;
				samples *= (cmd & 7) + 1;
				uint32_t bytes = (samples + 1) >> 1;
				if (bytes > (fifo_bytes - FIFO_THRESHOLD)) {
					cycles_to_threshold += (fifo_bytes - FIFO_THRESHOLD + 1) * ((cmd & 0x3F) + 1) * 2;
					fifo_bytes = 0;
				}
				break; }
			}
			cmd = 0;
		} else {
			cycles_to_threshold++;
			cmd = pcm->fifo[fifo_read++];
			fifo_bytes--;
			fifo_read &= sizeof(pcm->fifo) - 1;
		}
	}
	
	return pcm->cycle + cycles_to_threshold * pcm->clock_inc;
}
