#include <stdlib.h>
#include <stddef.h>
#include <limits.h>
#include <string.h>
#include "mediaplayer.h"
#include "io.h"
#include "ym2612.h"
#include "psg.h"
#include "rf5c164.h"
#include "util.h"
#include "render.h"

#define ADJUST_BUFFER (12500000)
#define MAX_NO_ADJUST (UINT_MAX-ADJUST_BUFFER)
#define MAX_RUN_SAMPLES 128

enum {
	AUDIO_VGM,
	AUDIO_WAVE,
	AUDIO_FLAC,
	MEDIA_UNKNOWN
};

#define STREAM_FLAG_REVERSE 0x01
#define STREAM_FLAG_LOOP    0x10
#define STREAM_FLAG_PLAY    0x80

uint32_t cycles_to_samples(uint32_t clock_rate, uint32_t cycles)
{
	return ((uint64_t)cycles) * ((uint64_t)44100) / ((uint64_t)clock_rate);
}

uint32_t samples_to_cycles(uint32_t clock_rate, uint32_t cycles)
{
	return ((uint64_t)cycles) * ((uint64_t)clock_rate) / ((uint64_t)44100);
}

void ym_adjust(chip_info *chip)
{
	ym2612_context *ym = chip->context;
	if (ym->current_cycle >= MAX_NO_ADJUST) {
		uint32_t deduction = ym->current_cycle - ADJUST_BUFFER;
		chip->samples -= cycles_to_samples(chip->clock, deduction);
		ym->current_cycle -= deduction;
	}
}

void ym_adjust_clock(chip_info *chip, uint32_t percent)
{
	ym_adjust_master_clock(chip->context, chip->clock * percent / 100);
}

void ym_scope(chip_info *chip, oscilloscope *scope)
{
	ym_enable_scope(chip->context, scope, chip->clock);
}

void ym_no_scope(void *context)
{
	ym2612_context *ym = context;
	ym->scope = NULL;
}

void ym_stream(chip_info *chip, uint8_t port, uint8_t command, uint16_t sample)
{
	ym2612_context *ym = chip->context;
	if (port) {
		ym_address_write_part2(ym, command);
	} else {
		ym_address_write_part1(ym, command);
	}
	ym_data_write(ym, sample);
}

void psg_adjust(chip_info *chip)
{
	psg_context *psg = chip->context;
	if (psg->cycles >= MAX_NO_ADJUST) {
		uint32_t deduction = psg->cycles - ADJUST_BUFFER;
		chip->samples -= cycles_to_samples(chip->clock, deduction);
		psg->cycles -= deduction;
	}
}

void psg_adjust_clock(chip_info *chip, uint32_t percent)
{
	psg_adjust_master_clock(chip->context, chip->clock * percent / 100);
}

void psg_scope(chip_info *chip, oscilloscope *scope)
{
	psg_enable_scope(chip->context, scope, chip->clock);
}

void psg_no_scope(void *context)
{
	psg_context *psg = context;
	psg->scope = NULL;
}

void pcm_adjust(chip_info *chip)
{
	rf5c164 *pcm = chip->context;
	if (pcm->cycle >= MAX_NO_ADJUST) {
		uint32_t deduction = pcm->cycle - ADJUST_BUFFER;
		chip->samples -= cycles_to_samples(chip->clock, deduction);
		pcm->cycle -= deduction;
	}
}

void pcm_adjust_clock(chip_info *chip, uint32_t percent)
{
	rf5c164_adjust_master_clock(chip->context, chip->clock * percent / 100);
}

void pcm_scope(chip_info *chip, oscilloscope *scope)
{
	rf5c164_enable_scope(chip->context, scope);
}

void pcm_no_scope(void *context)
{
	rf5c164 *pcm = context;
	pcm->scope = NULL;
}

void pcm_free(void *context)
{
	rf5c164 *pcm = context;
	rf5c164_deinit(pcm);
	free(pcm);
}

uint8_t *find_block(data_block *head, uint32_t offset, uint32_t size)
{
	if (!head) {
		return NULL;
	}
	while (head->size < offset) {
		offset -= head->size;
		head = head->next;
	}
	if (head->size - offset < size) {
		return NULL;
	}
	return head->data + offset;
}

void vgm_wait(media_player *player, uint32_t samples)
{
	chip_info *chips = player->chips;
	uint32_t num_chips = player->num_chips;
	while (samples > MAX_RUN_SAMPLES)
	{
		vgm_wait(player, MAX_RUN_SAMPLES);
		samples -= MAX_RUN_SAMPLES;
	}
	uint8_t keep_going;
	do {
		keep_going = 0;
		for (uint32_t i = 0; i < 0xFF; i++)
		{
			if (!player->streams[i] || !(player->streams[i]->flags & STREAM_FLAG_PLAY)) {
				continue;
			}
			vgm_stream *stream = player->streams[i];
			uint32_t cycle = samples_to_cycles(stream->chip->clock, stream->chip->samples + samples);
			if (cycle >= stream->next_sample_cycle) {
				stream->chip->run(stream->chip->context, stream->next_sample_cycle);
				if (stream->block_offset >= stream->cur_block->size) {
					stream->cur_block = stream->cur_block->next;
					if (!stream->cur_block) {
						//TODO: looping support
						player->streams[i]->flags &= ~STREAM_FLAG_PLAY;
						continue;
					}
				}
				//TODO: support for chips where the stream data unit is not a byte
				uint16_t sample = stream->cur_block->data[stream->block_offset];
				stream->block_offset += stream->step;
				if (stream->chip->stream) {
					stream->chip->stream(stream->chip, stream->port, stream->command, sample);
				}
				stream->next_sample_cycle += stream->cycles_per_sample;
				//TODO: deal with cycle adjustments
				keep_going = 1;
				if (stream->length_mode == 1) {
					//unclear how this is supposed to work
				} else {
					stream->remaining--;
					if (!stream->remaining) {
						//TODO: looping support
						player->streams[i]->flags &= ~STREAM_FLAG_PLAY;
					}
				}
			}
		}
	} while (keep_going);
	for (uint32_t i = 0; i < num_chips; i++)
	{
		chips[i].samples += samples;
		chips[i].run(chips[i].context, samples_to_cycles(chips[i].clock, chips[i].samples));
		chips[i].adjust(chips + i);
	}
}

void vgm_stop(media_player *player)
{
	player->state = STATE_PAUSED;
	player->playback_time = 0;
	player->current_offset = player->vgm->data_offset + offsetof(vgm_header, data_offset);
	player->loop_count = 2;
}

chip_info *find_chip(media_player *player, uint8_t cmd)
{
	for (uint32_t i = 0; i < player->num_chips; i++)
	{
		if (player->chips[i].cmd == cmd) {
			return player->chips + i;
		}
	}
	return NULL;
}

void *find_chip_context(media_player *player, uint8_t cmd)
{
	chip_info *chip = find_chip(player, cmd);
	return chip ? chip->context : NULL;
}

chip_info *find_chip_by_data(media_player *player, uint8_t data_type)
{
	for (uint32_t i = 0; i < player->num_chips; i++)
	{
		if (player->chips[i].data_type == data_type) {
			return &player->chips[i];
		}
	}
	return NULL;
}

chip_info *find_chip_by_stream(media_player *player, uint8_t stream_type)
{
	for (uint32_t i = 0; i < player->num_chips; i++)
	{
		if (player->chips[i].stream_type == stream_type) {
			return &player->chips[i];
		}
	}
	return NULL;
}

static uint8_t read_byte(media_player *player)
{
	uint8_t *buffer = player->media->buffer;
	return buffer[player->current_offset++];
}

static uint16_t read_word_le(media_player *player)
{
	uint8_t *buffer = player->media->buffer;
	uint16_t value =  buffer[player->current_offset++];
	value |= buffer[player->current_offset++] << 8;
	return value;
}

static uint32_t read_24_le(media_player *player)
{
	uint8_t *buffer = player->media->buffer;
	uint32_t value =  buffer[player->current_offset++];
	value |= buffer[player->current_offset++] << 8;
	value |= buffer[player->current_offset++] << 16;
	return value;
}

static uint32_t read_long_le(media_player *player)
{
	uint8_t *buffer = player->media->buffer;
	uint32_t value =  buffer[player->current_offset++];
	value |= buffer[player->current_offset++] << 8;
	value |= buffer[player->current_offset++] << 16;
	value |= buffer[player->current_offset++] << 24;
	return value;
}

void vgm_frame(media_player *player)
{
	for (uint32_t remaining_samples = 44100 / 60; remaining_samples > 0;)
	{
		if (player->wait_samples) {
			uint32_t to_wait = player->wait_samples;
			if (to_wait > remaining_samples) {
				to_wait = remaining_samples;
			}
			vgm_wait(player, to_wait);
			player->wait_samples -= to_wait;
			remaining_samples -= to_wait;
			if (player->wait_samples) {
				goto frame_end;
			}
		}
		if (player->current_offset >= player->media->size) {
			vgm_stop(player);
			goto frame_end;
		}
		uint8_t cmd = read_byte(player);
		psg_context *psg;
		ym2612_context *ym;
		rf5c164 *pcm;
		switch (cmd)
		{
		case CMD_PSG_STEREO:
			psg = find_chip_context(player, CMD_PSG);
			if (!psg || player->current_offset > player->media->size - 1) {
				vgm_stop(player);
				goto frame_end;
			}
			psg->pan = read_byte(player);
			break;
		case CMD_PSG:
			psg = find_chip_context(player, CMD_PSG);
			if (!psg || player->current_offset > player->media->size - 1) {
				vgm_stop(player);
				goto frame_end;
			}
			psg_write(psg, read_byte(player));
			break;
		case CMD_YM2612_0:
			ym = find_chip_context(player, CMD_YM2612_0);
			if (!ym || player->current_offset > player->media->size - 2) {
				vgm_stop(player);
				goto frame_end;
			}
			ym_address_write_part1(ym, read_byte(player));
			ym_data_write(ym, read_byte(player));
			break;
		case CMD_YM2612_1:
			ym = find_chip_context(player, CMD_YM2612_0);
			if (!ym || player->current_offset > player->media->size - 2) {
				vgm_stop(player);
				goto frame_end;
			}
			ym_address_write_part2(ym, read_byte(player));
			ym_data_write(ym, read_byte(player));
			break;
		case CMD_WAIT: {
			if (player->current_offset > player->media->size - 2) {
				vgm_stop(player);
				goto frame_end;
			}
			player->wait_samples += read_word_le(player);
			break;
		}
		case CMD_WAIT_60:
			player->wait_samples += 735;
			break;
		case CMD_WAIT_50:
			player->wait_samples += 882;
			break;
		case CMD_END:
			if (player->vgm->loop_offset && --player->loop_count) {
				player->current_offset = player->vgm->loop_offset + offsetof(vgm_header, loop_offset);
				if (player->current_offset < player->vgm->data_offset + offsetof(vgm_header, data_offset)) {
					// invalid loop offset
					vgm_stop(player);
					goto frame_end;
				}
			} else {
				//TODO: fade out?
				vgm_stop(player);
				goto frame_end;
			}
			return;
		case CMD_PCM_WRITE: {
			if (player->current_offset > player->media->size - 11) {
				vgm_stop(player);
				goto frame_end;
			}
			player->current_offset++; //skip compatibility command
			uint8_t data_type = read_byte(player);
			uint32_t read_offset = read_24_le(player);
			uint32_t write_offset = read_24_le(player);
			uint16_t size = read_24_le(player);
			chip_info *chip = find_chip_by_data(player, data_type);
			if (!chip || !chip->blocks) {
				warning("Failed to find data block list for type %d\n", data_type);
				break;
			}
			uint8_t *src = find_block(chip->blocks, read_offset, size);
			if (!src) {
				warning("Failed to find data offset %X with size %X for chip type %d\n", read_offset, size, data_type);
				break;
			}
			switch (data_type)
			{
			case DATA_RF5C68:
			case DATA_RF5C164:
				pcm = chip->context;
				write_offset |= pcm->ram_bank;
				write_offset &= 0xFFFF;
				if (size + write_offset > 0x10000) {
					size = 0x10000 - write_offset;
				}
				memcpy(pcm->ram + write_offset, src, size);
				break;
			default:
				warning("Unknown PCM write read_offset %X, write_offset %X, size %X\n", read_offset, write_offset, size);
			}
			break;
		}
		case CMD_PCM68_REG:
			pcm = find_chip_context(player, CMD_PCM68_REG);
			if (!pcm || player->current_offset > player->media->size - 2) {
				vgm_stop(player);
				return;
			} else {
				uint8_t reg = read_byte(player);
				uint8_t value = read_byte(player);
				rf5c164_write(pcm, reg, value);
			}
			break;
		case CMD_PCM164_REG:
			pcm = find_chip_context(player, CMD_PCM164_REG);
			if (!pcm || player->current_offset > player->media->size - 2) {
				vgm_stop(player);
				return;
			} else {
				uint8_t reg = read_byte(player);
				uint8_t value = read_byte(player);
				rf5c164_write(pcm, reg, value);
			}
			break;
		case CMD_PCM68_RAM:
			pcm = find_chip_context(player, CMD_PCM68_REG);
			if (!pcm || player->current_offset > player->media->size - 3) {
				vgm_stop(player);
				return;
			} else {
				uint16_t address = read_word_le(player);
				address &= 0xFFF;
				address |= 0x1000;
				rf5c164_write(pcm, address, read_byte(player));
			}
			break;
		case CMD_PCM164_RAM:
			pcm = find_chip_context(player, CMD_PCM164_REG);
			if (!pcm || player->current_offset > player->media->size - 3) {
				vgm_stop(player);
				return;
			} else {
				uint16_t address = read_word_le(player);
				address &= 0xFFF;
				address |= 0x1000;
				rf5c164_write(pcm, address, read_byte(player));
			}
			break;
		case CMD_DATA:
			if (player->current_offset > player->media->size - 6) {
				vgm_stop(player);
				return;
			} else {
				player->current_offset++; //skip compat command
				uint8_t data_type = read_byte(player);
				uint32_t data_size = read_long_le(player);
				if (data_size > player->media->size || player->current_offset > player->media->size - data_size) {
					vgm_stop(player);
					goto frame_end;
				}
				chip_info *chip = find_chip_by_data(player, data_type);
				if (chip) {
					data_block **cur = &(chip->blocks);
					while (*cur)
					{
						cur = &((*cur)->next);
					}
					*cur = calloc(1, sizeof(data_block));
					(*cur)->size = data_size;
					(*cur)->type = data_type;
					(*cur)->data = ((uint8_t *)player->media->buffer) + player->current_offset;
				} else {
					fprintf(stderr, "Skipping data block with unrecognized type %X\n", data_type);
				}
				player->current_offset += data_size;
			}
			break;
		case CMD_DAC_STREAM_SETUP:
			if (player->current_offset > player->media->size - 4) {
				vgm_stop(player);
				goto frame_end;
			} else {
				uint8_t stream_id = read_byte(player);
				if (!player->streams[stream_id]) {
					player->streams[stream_id] = calloc(1, sizeof(vgm_stream));
				}
				vgm_stream *stream = player->streams[stream_id];
				uint8_t chip_type = read_byte(player);
				stream->chip = find_chip_by_stream(player, chip_type);
				if (!stream->chip) {
					fprintf(stderr, "Failed to find chip with stream type %d for stream %d\n", chip_type, stream_id);
				}
				stream->port = read_byte(player);
				stream->command = read_byte(player);
			}
			break;
		case CMD_DAC_STREAM_DATA:
			if (player->current_offset > player->media->size - 4) {
				vgm_stop(player);
				goto frame_end;
			} else {
				uint8_t stream_id = read_byte(player);
				if (!player->streams[stream_id]) {
					player->streams[stream_id] = calloc(1, sizeof(vgm_stream));
				}
				vgm_stream *stream = player->streams[stream_id];
				stream->data_type = read_byte(player);
				stream->step = read_byte(player);
				stream->start_offset = read_byte(player);
			}
			break;
		case CMD_DAC_STREAM_FREQ:
			if (player->current_offset > player->media->size - 4) {
				vgm_stop(player);
				goto frame_end;
			} else {
				uint8_t stream_id = read_byte(player);
				if (!player->streams[stream_id]) {
					player->streams[stream_id] = calloc(1, sizeof(vgm_stream));
				}
				vgm_stream *stream = player->streams[stream_id];
				stream->sample_rate = read_long_le(player);
				if (stream->chip) {
					stream->cycles_per_sample = stream->chip->clock / stream->sample_rate;
				}
			}
			break;
		case CMD_DAC_STREAM_START:
			if (player->current_offset > player->media->size - 10) {
				vgm_stop(player);
				goto frame_end;
			} else {
				uint8_t stream_id = read_byte(player);
				if (!player->streams[stream_id]) {
					player->streams[stream_id] = calloc(1, sizeof(vgm_stream));
				}
				vgm_stream *stream = player->streams[stream_id];
				uint32_t data_start_offset = read_long_le(player);
				uint8_t length_mode = read_byte(player);
				uint32_t length = read_long_le(player);
				stream->flags = length_mode & STREAM_FLAG_REVERSE;
				if (length_mode & 0x80) {
					stream->flags |= STREAM_FLAG_LOOP;
				}
				length_mode &= 0x3;
				if (length_mode) {
					stream->length_mode = length_mode;
					if (length_mode == 2) {
						//length is in msec
						if (stream->chip) {
							stream->remaining = (((uint64_t)length) * (uint64_t)stream->sample_rate) / 1000;
						}
					} else if (length_mode == 3) {
						//play until end of data
						stream->remaining = 0xFFFFFFFF;
					} else {
						//length is in commands?
						stream->remaining = length;
					}
				}
				if (stream->chip && data_start_offset != 0xFFFFFFFF) {
					data_block * cur_block = stream->chip->blocks;
					data_start_offset += stream->start_offset;
					while (cur_block)
					{
						if (cur_block->type == stream->data_type) {
							if (data_start_offset >= cur_block->size) {
								data_start_offset -= cur_block->size;
								cur_block = cur_block->next;
							} else {
								stream->block_offset = data_start_offset;
								stream->cur_block = cur_block;
								break;
							}
						} else {
							cur_block = cur_block->next;
						}
					}
				}
				if (stream->chip && stream->cur_block) {
					stream->flags |= STREAM_FLAG_PLAY;
				}
			}
			break;
		case CMD_DAC_STREAM_STOP:
			if (player->current_offset < player->media->size) {
				vgm_stop(player);
				goto frame_end;
			} else {
				uint8_t stream_id = read_byte(player);
				if (stream_id == 0xFF) {
					for (uint32_t i = 0; i < 0xFF; i++) {
						if (player->streams[i]) {
							player->streams[i]->flags &= ~STREAM_FLAG_PLAY;
						}
					}
				} else {
					if (!player->streams[stream_id]) {
						player->streams[stream_id] = calloc(1, sizeof(vgm_stream));
					}
					player->streams[stream_id]->flags &= ~STREAM_FLAG_PLAY;
				}
			}
			break;
		case CMD_DAC_STREAM_STARTFAST:
			if (player->current_offset > player->media->size - 4) {
				vgm_stop(player);
				goto frame_end;
			} else {
				uint8_t stream_id = read_byte(player);
				if (!player->streams[stream_id]) {
					player->streams[stream_id] = calloc(1, sizeof(vgm_stream));
				}
				vgm_stream *stream = player->streams[stream_id];
				uint16_t block_id = read_word_le(player);
				stream->flags = read_byte(player) & (STREAM_FLAG_LOOP|STREAM_FLAG_REVERSE);
				if (stream->chip) {
					uint16_t cur_block_id = 0;
					data_block *cur_block = stream->chip->blocks;
					while (cur_block)
					{
						if (cur_block_id == block_id) {
							stream->cur_block = cur_block;
							stream->block_offset = stream->start_offset;
							break;
						}
						if (cur_block->type == stream->data_type) {
							cur_block_id++;
						}
						cur_block = cur_block->next;
					}
					if (stream->cur_block) {
						stream->remaining = 0xFFFFFFFF;
						stream->length_mode = 3;
						stream->flags |= STREAM_FLAG_PLAY;
						stream->next_sample_cycle = samples_to_cycles(stream->chip->clock, stream->chip->samples);
					}
				}
			}
			break;
		case CMD_DATA_SEEK:
			if (player->current_offset > player->media->size - 4) {
				vgm_stop(player);
				return;
			} else {
				uint32_t new_offset = read_long_le(player);
				if (!player->ym_seek_block || new_offset < player->ym_seek_offset) {
					chip_info *chip = find_chip(player, CMD_YM2612_0);
					if (!chip) {
						break;
					}
					player->ym_seek_block = chip->blocks;
					player->ym_seek_offset = 0;
					player->ym_block_offset = 0;
				}
				while (player->ym_seek_block && (player->ym_seek_offset - player->ym_block_offset + player->ym_seek_block->size) < new_offset)
				{
					player->ym_seek_offset += player->ym_seek_block->size - player->ym_block_offset;
					player->ym_seek_block = player->ym_seek_block->next;
					player->ym_block_offset = 0;
				}
				player->ym_block_offset += new_offset - player->ym_seek_offset;
				player->ym_seek_offset = new_offset;
			}
			break;
		default:
			if (cmd >= CMD_WAIT_SHORT && cmd < (CMD_WAIT_SHORT + 0x10)) {
				uint32_t wait_time = (cmd & 0xF) + 1;
				player->wait_samples += wait_time;
			} else if (cmd >= CMD_YM2612_DAC && cmd < CMD_DAC_STREAM_SETUP) {
				if (player->ym_seek_block) {
					ym = find_chip_context(player, CMD_YM2612_0);
					ym_address_write_part1(ym, 0x2A);
					ym_data_write(ym, player->ym_seek_block->data[player->ym_block_offset++]);
					player->ym_seek_offset++;
					if (player->ym_block_offset > player->ym_seek_block->size) {
						player->ym_seek_block = player->ym_seek_block->next;
						player->ym_block_offset = 0;
					}
				} else {
					fputs("Encountered DAC write command but data seek pointer is invalid!\n", stderr);
				}
				player->wait_samples += cmd & 0xF;
			} else {
				warning("unimplemented command: %X at offset %X\n", cmd, player->current_offset);
				vgm_stop(player);
				goto frame_end;
			}
		}
	}
frame_end:
#ifndef IS_LIB
	if (player->scope) {
		scope_render(player->scope);
	}
#endif
	return;
}

static void wave_stop(media_player *player)
{
	player->current_offset = player->wave->format_header.size + offsetof(wave_header, audio_format);
	player->state = STATE_PAUSED;
	player->playback_time = 0;
}

void wave_frame(media_player *player)
{
	for (uint32_t remaining_samples = player->wave->sample_rate / 60; remaining_samples > 0; remaining_samples--)
	{
		uint32_t sample_size = player->wave->bits_per_sample * player->wave->num_channels / 8;
		if (sample_size > player->media->size || player->current_offset > player->media->size - sample_size) {
			wave_stop(player);
			return;
		}
		if (player->wave->bits_per_sample == 16) {
			int16_t value = read_word_le(player);
			if (player->wave->num_channels == 1) {
				render_put_mono_sample(player->audio, value);
			} else {
				int16_t right = read_word_le(player);
				render_put_stereo_sample(player->audio, value, right);
			}
		} else {
			uint8_t sample = read_byte(player);
			int16_t value = sample * 257 - 128 * 257;
			if (player->wave->num_channels == 1) {
				render_put_mono_sample(player->audio, value);
			} else {
				sample = read_byte(player);
				int16_t right = sample * 257 - 128 * 257;
				render_put_stereo_sample(player->audio, value, right);
			}
		}

	}
}

static void flac_stop(media_player *player)
{
	player->state = STATE_PAUSED;
	player->playback_time = 0;
	flac_seek(player->flac, 0);
}

void flac_frame(media_player *player)
{
	for (uint32_t remaining_samples = player->flac->sample_rate / 60; remaining_samples > 0; remaining_samples--)
	{
		int16_t samples[2];
		if (flac_get_sample(player->flac, samples, 2)) {
			render_put_stereo_sample(player->audio, samples[0], samples[1]);
		} else {
			flac_stop(player);
			return;
		}
	}
}

void vgm_init(media_player *player, uint32_t opts)
{
	player->vgm = calloc(1, sizeof(vgm_header));
	player->vgm_ext = NULL;
	memcpy(player->vgm, player->media->buffer, sizeof(vgm_header));
	if (player->vgm->version < 0x150 || !player->vgm->data_offset) {
		player->vgm->data_offset = 0xC;
	}
	if (player->vgm->data_offset + offsetof(vgm_header, data_offset) > player->media->size) {
		player->vgm->data_offset = player->media->size - offsetof(vgm_header, data_offset);
	}
	if (player->vgm->version <= 0x101 && player->vgm->ym2413_clk > 4000000) {
		player->vgm->ym2612_clk = player->vgm->ym2413_clk;
		player->vgm->ym2413_clk = 0;
	}
	if (player->vgm->data_offset > 0xC) {
		player->vgm_ext = calloc(1, sizeof(vgm_extended_header));
		size_t additional_header = player->vgm->data_offset + offsetof(vgm_header, data_offset) - sizeof(vgm_header);
		if (additional_header > sizeof(vgm_extended_header)) {
			additional_header = sizeof(vgm_extended_header);
		}
		memcpy(player->vgm_ext, ((uint8_t *)player->media->buffer) + sizeof(vgm_header),  additional_header);
	}
	player->num_chips = 0;
	if (player->vgm->sn76489_clk) {
		player->num_chips++;
	}
	if (player->vgm->ym2612_clk) {
		player->num_chips++;
	}
	if (player->vgm_ext && player->vgm_ext->rf5c68_clk) {
		player->num_chips++;
	}
	if (player->vgm_ext && player->vgm_ext->rf5c164_clk) {
		player->num_chips++;
	}
	player->chips = calloc(player->num_chips, sizeof(chip_info));
	uint32_t chip = 0;
	if (player->vgm->ym2612_clk) {
		ym2612_context *ym = calloc(1, sizeof(ym2612_context));
		ym_init(ym, player->vgm->ym2612_clk, 1, opts);
		player->chips[chip++] = (chip_info) {
			.context = ym,
			.run = (chip_run_fun)ym_run,
			.adjust = ym_adjust,
			.adjust_clock = ym_adjust_clock,
			.scope = ym_scope,
			.no_scope = ym_no_scope,
			.free = (chip_noarg_fun)ym_free,
			.stream = ym_stream,
			.clock = player->vgm->ym2612_clk,
			.samples = 0,
			.cmd = CMD_YM2612_0,
			.data_type = DATA_YM2612_PCM,
			.stream_type = STREAM_CHIP_YM2612
		};
	}
	if (player->vgm->sn76489_clk) {
		psg_context *psg = calloc(1, sizeof(psg_context));
		psg_init(psg, player->vgm->sn76489_clk, 16);
		player->chips[chip++] = (chip_info) {
			.context = psg,
			.run = (chip_run_fun)psg_run,
			.adjust = psg_adjust,
			.adjust_clock = psg_adjust_clock,
			.scope = psg_scope,
			.no_scope = ym_no_scope,
			.free = (chip_noarg_fun)psg_free,
			.clock = player->vgm->sn76489_clk,
			.samples = 0,
			.cmd = CMD_PSG,
			.data_type = 0xFF,
			.stream_type = STREAM_CHIP_PSG
		};
	}
	if (player->vgm_ext && player->vgm_ext->rf5c68_clk) {
		rf5c164 *pcm = calloc(1, sizeof(rf5c164));
		rf5c164_init(pcm, player->vgm_ext->rf5c68_clk, 1);
		player->chips[chip++] = (chip_info) {
			.context = pcm,
			.run = (chip_run_fun)rf5c164_run,
			.adjust = pcm_adjust,
			.adjust_clock = pcm_adjust_clock,
			.scope = pcm_scope,
			.no_scope = pcm_no_scope,
			.free = pcm_free,
			.clock = player->vgm_ext->rf5c68_clk,
			.samples = 0,
			.cmd = CMD_PCM68_REG,
			.data_type = DATA_RF5C68,
			.stream_type = STREAM_CHIP_RF5C68
		};
	}
	if (player->vgm_ext && player->vgm_ext->rf5c164_clk) {
		rf5c164 *pcm = calloc(1, sizeof(rf5c164));
		rf5c164_init(pcm, player->vgm_ext->rf5c164_clk, 1);
		player->chips[chip++] = (chip_info) {
			.context = pcm,
			.run = (chip_run_fun)rf5c164_run,
			.adjust = pcm_adjust,
			.adjust_clock = pcm_adjust_clock,
			.scope = pcm_scope,
			.no_scope = pcm_no_scope,
			.free = pcm_free,
			.clock = player->vgm_ext->rf5c164_clk,
			.samples = 0,
			.cmd = CMD_PCM164_REG,
			.data_type = DATA_RF5C164,
			.stream_type = STREAM_CHIP_RF5C164
		};
	}
	player->current_offset = player->vgm->data_offset + offsetof(vgm_header, data_offset);
	player->loop_count = 2;
}

static void wave_player_init(media_player *player)
{
	player->wave = calloc(1, sizeof(wave_header));
	memcpy(player->wave, player->media->buffer, offsetof(wave_header, data_header));
	if (memcmp(player->wave->chunk.format, "WAVE", 4)) {
		goto format_error;
	}
	if (player->wave->chunk.size < offsetof(wave_header, data_header)) {
		goto format_error;
	}
	if (memcmp(player->wave->format_header.id, "fmt ", 4)) {
		goto format_error;
	}
	if (player->wave->format_header.size < offsetof(wave_header, data_header) - offsetof(wave_header, audio_format)) {
		goto format_error;
	}
	if (player->wave->bits_per_sample != 8 && player->wave->bits_per_sample != 16) {
		goto format_error;
	}
	uint32_t data_sub_chunk = player->wave->format_header.size + offsetof(wave_header, audio_format);
	if (data_sub_chunk > player->media->size || player->media->size - data_sub_chunk < sizeof(riff_sub_chunk)) {
		goto format_error;
	}
	memcpy(&player->wave->data_header, ((uint8_t *)player->media->buffer) + data_sub_chunk, sizeof(riff_sub_chunk));
	player->current_offset = data_sub_chunk;
	player->audio = render_audio_source("Audio File", player->wave->sample_rate, 1, player->wave->num_channels);
	return;
format_error:
	player->media_type = MEDIA_UNKNOWN;
	free(player->wave);
}

static void flac_player_init(media_player *player)
{
	player->flac = flac_file_from_buffer(player->media->buffer, player->media->size);
	if (player->flac) {
		player->audio = render_audio_source("Audio File", player->flac->sample_rate, 1, 2);
	}
}

static void resume_player(system_header *system)
{
	media_player *player = (media_player *)system;
	player->should_return = 0;
	while (!player->header.should_exit && !player->should_return)
	{
		switch (player->state)
		{
		case STATE_PLAY:
			player->playback_time++;
			switch(player->media_type)
			{
			case AUDIO_VGM:
				vgm_frame(player);
				break;
			case AUDIO_WAVE:
				wave_frame(player);
				break;
			case AUDIO_FLAC:
				flac_frame(player);
				break;
			}
			break;
		case STATE_PAUSED:
#ifndef IS_LIB
			render_sleep_ms(15);
#endif
			break;
		}
	//TODO: Fix this for libretro build properly
#ifndef IS_LIB
		render_update_display();
#endif
	}
}

static void gamepad_down(system_header *system, uint8_t pad, uint8_t button)
{
	if (pad != 1) {
		return;
	}
	media_player *player = (media_player *)system;
	if (player->button_state[button]) {
		//already pressed
		return;
	}
	player->button_state[button] = 1;
	if (button == BUTTON_A || button == BUTTON_C || button == BUTTON_START) {
		if (player->state == STATE_PAUSED) {
			player->state = STATE_PLAY;
			puts("Now playing");
		} else {
			player->state = STATE_PAUSED;
			puts("Now paused");
		}
	}
}

static void gamepad_up(system_header *system, uint8_t pad, uint8_t button)
{
	if (pad != 1) {
		return;
	}
	media_player *player = (media_player *)system;
	player->button_state[button] = 0;
}

static void start_player(system_header *system, char *statefile)
{
	resume_player(system);
}

static void free_player(system_header *system)
{
	media_player *player = (media_player *)system;
	for (uint32_t i = 0; i < player->num_chips; i++)
	{
		player->chips[i].free(player->chips[i].context);
	}
	free(player->chips);
	free(player->vgm);
	free(player);
}

uint8_t detect_media_type(system_media *media)
{
	if (media->size < 4) {
		return MEDIA_UNKNOWN;
	}
	if (!memcmp(media->buffer, "Vgm ", 4)) {
		if (media->size < sizeof(vgm_header)) {
			return MEDIA_UNKNOWN;
		}
		return AUDIO_VGM;
	}
	if (!memcmp(media->buffer, "RIFF", 4)) {
		if (media->size < sizeof(wave_header)) {
			return MEDIA_UNKNOWN;
		}
		return AUDIO_WAVE;
	}
	if (!memcmp(media->buffer, "fLaC", 4)) {
		return AUDIO_FLAC;
	}
	return MEDIA_UNKNOWN;
}

static void request_exit(system_header *system)
{
	media_player *player = (media_player *)system;
	player->should_return = 1;
}

static void toggle_debug_view(system_header *system, uint8_t debug_view)
{
#ifndef IS_LIB
	media_player *player = (media_player *)system;
	if (debug_view == DEBUG_OSCILLOSCOPE && player->chips) {
		if (player->scope) {
			for (uint32_t i = 0; i < player->num_chips; i++)
			{
				player->chips[i].no_scope(player->chips[i].context);
			}
			scope_close(player->scope);
			player->scope = NULL;
		} else {
			player->scope = create_oscilloscope();
			for (uint32_t i = 0; i < player->num_chips; i++)
			{
				player->chips[i].scope(player->chips + i, player->scope);
			}
		}
	}
#endif
}

static void inc_debug_mode(system_header * system)
{
}

static void soft_reset(system_header * system)
{
	media_player *player = (media_player *)system;
	switch(player->media_type)
	{
	case AUDIO_VGM:
		vgm_stop(player);
		break;
	case AUDIO_WAVE:
		wave_stop(player);
		break;
	case AUDIO_FLAC:
		flac_stop(player);
		break;
	}
	player->state = STATE_PLAY;
}

static void set_speed_percent(system_header * system, uint32_t percent)
{
	media_player *player = (media_player *)system;
	switch(player->media_type)
	{
	case AUDIO_VGM:
		for (uint32_t i = 0; i < player->num_chips; i++)
		{
			player->chips[i].adjust_clock(player->chips + i, percent);
		}
		break;
	case AUDIO_WAVE:
		render_audio_adjust_clock(player->audio, player->wave->sample_rate * percent / 100, 1);
		break;
	case AUDIO_FLAC:
		render_audio_adjust_clock(player->audio, player->wave->sample_rate * percent / 100, 1);
		break;
	}
}

media_player *alloc_media_player(system_media *media, uint32_t opts)
{
	media_player *player = calloc(1, sizeof(media_player));
	player->header.start_context = start_player;
	player->header.resume_context = resume_player;
	player->header.request_exit = request_exit;
	player->header.soft_reset = soft_reset;
	player->header.free_context = free_player;
	player->header.set_speed_percent = set_speed_percent;
	player->header.gamepad_down = gamepad_down;
	player->header.gamepad_up = gamepad_up;
	player->header.toggle_debug_view = toggle_debug_view;
	player->header.inc_debug_mode = inc_debug_mode;
	player->header.type = SYSTEM_MEDIA_PLAYER;
	player->header.info.name = strdup(media->name);

	player->media = media;
	player->media_type = detect_media_type(media);
	player->state = STATE_PLAY;
	switch (player->media_type)
	{
	case AUDIO_VGM:
		vgm_init(player, opts);
		break;
	case AUDIO_WAVE:
		wave_player_init(player);
		break;
	case AUDIO_FLAC:
		flac_player_init(player);
		break;
	}

	return player;
}
