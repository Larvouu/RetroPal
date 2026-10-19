#ifndef YMZ263B_H_
#define YMZ263B_H_

#include <stdint.h>
#include "render_audio.h"
#include "oscilloscope.h"

typedef struct {
	uint16_t output;
	uint16_t adpcm_step;
	uint8_t  fifo[128];
	uint8_t  fifo_read;
	uint8_t  fifo_write;
	
	uint8_t  regs[4];
	uint8_t  counter;
	uint8_t  nibble;
	uint8_t  nibble_write;
} ymz263b_pcm;

typedef struct {
	uint8_t fifo[16];
	uint8_t read;
	uint8_t write;
} ymz_midi_fifo;

typedef struct {
	audio_source  *audio;
	oscilloscope  *scope;
	ymz263b_pcm   pcm[2];
	ymz_midi_fifo midi_rcv;
	ymz_midi_fifo midi_trs;
	
	uint32_t      clock_inc;
	uint32_t      cycle;
	
	uint16_t      timers[4];
	
	uint16_t      status;
	
	uint8_t       base_regs[9];
	uint8_t       midi_regs[2];
	uint8_t       address;
	uint8_t       midi_transmit;
	uint8_t       pcm_counter;
} ymz263b;

void ymz263b_init(ymz263b *ymz, uint32_t master_clock, uint32_t clock_divider);
void ymz263b_free(ymz263b *ymz);
void ymz263b_adjust_master_clock(ymz263b *ymz, uint32_t master_clock);
void ymz263b_run(ymz263b *ymz, uint32_t target_cycle);
uint32_t ymz263b_next_int(ymz263b *ymz);
void ymz263b_address_write(ymz263b *ymz, uint8_t value);
void ymz263b_data_write(ymz263b *ymz, uint32_t channel, uint8_t value);
uint8_t ymz263b_data_read(ymz263b *ymz, uint32_t channel);
uint8_t ymz263b_status_read(ymz263b *ymz);

#endif //YMZ263B_H_
