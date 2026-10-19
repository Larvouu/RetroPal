#ifndef MEDIAPLAYER_H_
#define MEDIAPLAYER_H_

#include <stdint.h>
#include "system.h"
#include "vgm.h"
#include "wave.h"
#include "flac.h"
#include "oscilloscope.h"
#include "render_audio.h"
#include "io.h"

typedef struct chip_info chip_info;
typedef void (*chip_run_fun)(void *context, uint32_t cycle);
typedef void (*chip_scope_fun)(chip_info *chip, oscilloscope *scope);
typedef void (*chip_noarg_fun)(void *context);
typedef void (*chip_adjust_fun)(chip_info *chip);
typedef void (*chip_clock_fun)(chip_info *chip, uint32_t percent);
typedef void (*chip_stream_fun)(chip_info *chip, uint8_t port, uint8_t command, uint16_t sample);
struct chip_info {
	void            *context;
	chip_run_fun    run;
	chip_adjust_fun adjust;
	chip_clock_fun  adjust_clock;
	chip_scope_fun  scope;
	chip_noarg_fun  no_scope;
	chip_noarg_fun  free;
	chip_stream_fun stream;
	data_block      *blocks;
	uint32_t        clock;
	uint32_t        samples;
	uint8_t         cmd;
	uint8_t         data_type;
	uint8_t         stream_type;
};

typedef struct {
	chip_info  *chip;
	data_block *cur_block;
	uint32_t   step;
	uint32_t   block_offset;
	uint32_t   start_offset;
	uint32_t   cycles_per_sample;
	uint32_t   sample_rate;
	uint32_t   next_sample_cycle;
	uint32_t   remaining; // sample count or command count
	uint8_t    data_type;
	uint8_t    port;
	uint8_t    command;
	uint8_t    flags;
	uint8_t    length_mode;
} vgm_stream;

enum {
	STATE_PLAY,
	STATE_PAUSED
};

typedef struct {
	system_header       header;
	system_media        *media;
	vgm_header          *vgm;
	vgm_extended_header *vgm_ext;
	data_block          *ym_seek_block;
	wave_header         *wave;
	flac_file           *flac;
	audio_source        *audio;
	chip_info           *chips;
	oscilloscope        *scope;
	vgm_stream          *streams[256];
	uint32_t            num_chips;
	uint32_t            current_offset;
	uint32_t            playback_time;
	uint32_t            wait_samples;
	uint32_t            ym_seek_offset;
	uint32_t            ym_block_offset;
	uint32_t            loop_count;
	uint8_t             state;
	uint8_t             media_type;
	uint8_t             should_return;
	uint8_t             button_state[NUM_GAMEPAD_BUTTONS];
} media_player;

media_player *alloc_media_player(system_media *media, uint32_t opts);


#endif //MEDIAPLAYER_H_
