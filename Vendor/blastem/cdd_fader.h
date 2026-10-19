#ifndef CDD_FADER_H_
#define CDD_FADER_H_

#include "render_audio.h"
#include "serialize.h"

typedef struct {
	audio_source *audio;
	uint16_t     cur_attenuation;
	uint16_t     dst_attenuation;
	uint16_t     attenuation_step;
	uint8_t      flags;
	uint8_t      bytes[4];
	uint8_t      byte_counter;
} cdd_fader;

void cdd_fader_init(cdd_fader *fader);
void cdd_fader_deinit(cdd_fader *fader);
void cdd_fader_set_speed_percent(cdd_fader *fader, uint32_t percent);
void cdd_fader_attenuation_write(cdd_fader *fader, uint16_t attenuation);
void cdd_fader_data(cdd_fader *fader, uint8_t byte);
void cdd_fader_pause(cdd_fader *fader);
void cdd_fader_serialize(cdd_fader *fader, serialize_buffer *buf);
void cdd_fader_deserialize(deserialize_buffer *buf, void *vfader);

#endif //CDD_FADER_H_
