#ifndef PNG_H_
#define PNG_H_

#include "pixel.h"

typedef struct {
	uint32_t sequence_number;
	uint32_t num_frames;
	uint32_t num_frame_offset;
	uint16_t delay_num;
	uint16_t delay_den;
} apng_state;

void save_png24_frame(FILE *f, pixel_t *buffer, apng_state *apng, uint32_t width, uint32_t height, uint32_t pitch);
void save_png24(FILE *f, pixel_t *buffer, uint32_t width, uint32_t height, uint32_t pitch);
void save_png(FILE *f, pixel_t *buffer, uint32_t width, uint32_t height, uint32_t pitch);
apng_state* start_apng(FILE *f, uint32_t width, uint32_t height, float frame_rate);
void end_apng(FILE *f, apng_state *apng);
uint32_t *load_png(uint8_t *buffer, uint32_t buf_size, uint32_t *width, uint32_t *height);

#endif //PNG_H_
