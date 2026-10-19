#include "cdd_fader.h"
#include <stdio.h>
#define CDDA_MCLKS 16934400

void cdd_fader_init(cdd_fader *fader)
{
	fader->audio = render_audio_source("CDDA", CDDA_MCLKS, 384, 2);
	fader->cur_attenuation = 0x4000;
	fader->dst_attenuation = 0x4000;
	fader->attenuation_step = 0;
}

void cdd_fader_deinit(cdd_fader *fader)
{
	render_free_source(fader->audio);
}

void cdd_fader_set_speed_percent(cdd_fader *fader, uint32_t percent)
{
	uint32_t new_clock = ((uint64_t)CDDA_MCLKS * (uint64_t)percent) / 100;
	render_audio_adjust_clock(fader->audio, new_clock, 384);
}

void cdd_fader_attenuation_write(cdd_fader *fader, uint16_t attenuation)
{
	fader->dst_attenuation = attenuation & 0xFFF0;
	fader->flags = attenuation & 0xE;
	if (fader->dst_attenuation > fader->cur_attenuation) {
		fader->attenuation_step = (fader->dst_attenuation - fader->cur_attenuation) >> 4;
	} else if (fader->dst_attenuation < fader->cur_attenuation) {
		fader->attenuation_step = (fader->cur_attenuation - fader->dst_attenuation) >> 4;
	} else {
		fader->attenuation_step = 0;
	}
}

void cdd_fader_data(cdd_fader *fader, uint8_t byte)
{
	fader->bytes[fader->byte_counter++] = byte;
	if (fader->byte_counter == sizeof(fader->bytes)) {
		fader->byte_counter = 0;
		int32_t left = (fader->bytes[1] << 8) | fader->bytes[0];
		int32_t right = (fader->bytes[3] << 8) | fader->bytes[2];
		if (left & 0x8000) {
			left |= 0xFFFF0000;
		}
		if (right & 0x8000) {
			right |= 0xFFFF0000;
		}
		if (!fader->cur_attenuation) {
			left = right = 0;
		} else if (fader->cur_attenuation >= 4) {
			left *= fader->cur_attenuation & 0x7FF0;
			right *= fader->cur_attenuation & 0x7FF0;
			left >>= 14;
			right >>= 14;
		} else {
			//TODO: FIXME
			left = right = 0;
		}
		render_put_stereo_sample(fader->audio, left, right);
		if (fader->attenuation_step) {
			if (fader->dst_attenuation > fader->cur_attenuation) {
				fader->cur_attenuation += fader->attenuation_step;
				if (fader->cur_attenuation >= fader->dst_attenuation) {
					fader->cur_attenuation = fader->dst_attenuation;
					fader->attenuation_step = 0;
				}
			} else {
				fader->cur_attenuation -= fader->attenuation_step;
				if (fader->cur_attenuation <= fader->dst_attenuation) {
					fader->cur_attenuation = fader->dst_attenuation;
					fader->attenuation_step = 0;
				}
			}
		}
	}
}

void cdd_fader_serialize(cdd_fader *fader, serialize_buffer *buf)
{
	save_int16(buf, fader->cur_attenuation);
	save_int16(buf, fader->dst_attenuation);
	save_int16(buf, fader->attenuation_step);
	save_int8(buf, fader->flags);
	save_buffer8(buf, fader->bytes, sizeof(fader->bytes));
	save_int8(buf, fader->byte_counter);
}

void cdd_fader_deserialize(deserialize_buffer *buf, void *vfader)
{
	cdd_fader *fader = vfader;
	fader->cur_attenuation = load_int16(buf);
	fader->dst_attenuation = load_int16(buf);
	fader->attenuation_step = load_int16(buf);
	fader->flags = load_int8(buf);
	load_buffer8(buf, fader->bytes, sizeof(fader->bytes));
	fader->byte_counter = load_int8(buf);
}
