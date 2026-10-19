#include <stdint.h>
#include <stdio.h>
#include "pixel.h"

void save_ppm(FILE *f, pixel_t *buffer, uint32_t width, uint32_t height, uint32_t pitch)
{
	fprintf(f, "P6\n%d %d\n255\n", width, height);
	for(uint32_t y = 0; y < height; y++)
	{
		pixel_t *line = buffer;
		for (uint32_t x = 0; x < width; x++, line++)
		{
			uint8_t buf[3] = {
#ifdef USE_RGB565
				(*line >> 8 & 0xF8) | (*line >> (8+5)),       //red
				(*line >> 3 & 0xFC) | (*line >> (3+5) & 0x3), //green
				*line << 3 | (*line >> (5-3) & 0x3)           //blue
#else
#ifdef USE_GLES
				*line,      //red
				*line >> 8, //green
				*line >> 16 //blue
#else
				*line >> 16, //red
				*line >> 8,  //green
				*line        //blue
#endif
#endif
			};
			fwrite(buf, 1, sizeof(buf), f);
		}
		buffer = buffer + pitch / sizeof(pixel_t);
	}
}
