#ifndef OSCILLOSCOPE_H_
#define OSCILLOSCOPE_H_
#include <stdint.h>

typedef struct {
	const char *name;
	int16_t    *samples;
	uint32_t   next_sample;
	uint32_t   period;
	uint32_t   last_trigger;
	uint32_t   cur_trigger;
} scope_channel;

typedef struct {
	scope_channel *channels;
	uint8_t       num_channels;
	uint8_t       channel_storage;
	uint8_t       window;
} oscilloscope;

oscilloscope *create_oscilloscope();
uint8_t scope_add_channel(oscilloscope *scope, const char *name, uint32_t sample_rate);
void scope_add_sample(oscilloscope *scope, uint8_t channel, int16_t value, uint8_t trigger);
void scope_render(oscilloscope *scope);
void scope_close(oscilloscope *scope);

#endif //OSCILLOSCOPE_H_