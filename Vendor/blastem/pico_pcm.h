#ifndef PICO_PCM_H_
#define PICO_PCM_H_

#include <stdint.h>
#include "render_audio.h"
#include "oscilloscope.h"

typedef struct {
	audio_source *audio;
	oscilloscope *scope;
	uint32_t     clock_inc;
	uint32_t     cycle;
	uint16_t     ctrl;
	
	uint16_t     counter;
	uint16_t     rate;
	uint16_t     samples;
	int16_t      output;
	
	uint8_t      fifo[0x40];
	uint8_t      fifo_read;
	uint8_t      fifo_write;
	uint8_t      adpcm_state;
	uint8_t      nibble_store;
	uint8_t      scope_channel;
} pico_pcm;

void pico_pcm_init(pico_pcm *pcm, uint32_t master_clock, uint32_t divider);
void pico_pcm_free(pico_pcm *pcm);
void pico_pcm_adjust_master_clock(pico_pcm *pcm, uint32_t master_clock);
void pico_pcm_enable_scope(pico_pcm *pcm, oscilloscope *scope, uint32_t master_clock);
void pico_pcm_run(pico_pcm *pcm, uint32_t cycle);
void pico_pcm_ctrl_write(pico_pcm *pcm, uint16_t value);
void pico_pcm_data_write(pico_pcm *pcm, uint16_t value);
uint16_t pico_pcm_ctrl_read(pico_pcm *pcm);
uint16_t pico_pcm_data_read(pico_pcm *pcm);
uint32_t pico_pcm_next_int(pico_pcm *pcm);

#endif //PICO_PCM_H_
