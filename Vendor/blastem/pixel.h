#ifndef PIXEL_H_
#define PIXEL_H_

#include <stdint.h>
#ifdef USE_RGB565
typedef uint16_t pixel_t;
#else
typedef uint32_t pixel_t;
#endif

#define PITCH_BYTES(width) (sizeof(uint32_t) * ((width * sizeof(pixel_t) + sizeof(uint32_t) - 1) / sizeof(uint32_t)))
#define PITCH_PIXEL_T(width) ((width * sizeof(pixel_t) + sizeof(uint32_t) - 1) / sizeof(uint32_t)) * (sizeof(uint32_t) / sizeof(pixel_t))

inline pixel_t mix_colors(pixel_t left, pixel_t right, uint32_t mix)
{
	uint32_t left_mix = 0x10000 - mix;
#ifdef USE_RGB565
	uint32_t red = (left & 0xF800) * left_mix + (right & 0xF800) * mix;
	uint32_t green = (left & 0x07E0) * left_mix + (right & 0x07E0) * mix;
	uint32_t blue = (left & 0x001F) * left_mix + (right & 0x001F) * mix;
	return (red >> 16 & 0xF800) | (green >> 16 & 0x07E0) | (blue >> 16 & 0x001F);
#else
	uint32_t high = (left >> 8 & 0xFF00) * left_mix + (right >> 8 & 0xFF00) * mix;
	uint32_t mid = (left & 0xFF00) * left_mix + (right & 0xFF00) * mix;
	uint32_t low = (left & 0x00FF) * left_mix + (right & 0x00FF) * mix;
	return 255UL << 24 | (high >> 8 & 0xFF0000) | (mid >> 16 & 0xFF00) | (low >> 16 & 0x00FF);
#endif
}

#endif //PIXEL_H_
