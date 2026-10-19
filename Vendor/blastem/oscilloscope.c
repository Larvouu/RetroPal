#include "oscilloscope.h"
#include "render.h"
#include "blastem.h"
#include <stdlib.h>
#include <string.h>

#define INVALID_TRIGGER 0xFFFFFFFF
#define WIDTH 1280
#define HEIGHT 720

static void scope_window_close(uint8_t which)
{
	if (current_system && current_system->toggle_debug_view) {
		current_system->toggle_debug_view(current_system, DEBUG_OSCILLOSCOPE);
	}
}

oscilloscope *create_oscilloscope()
{
	oscilloscope *scope = calloc(1, sizeof(oscilloscope));
	scope->channel_storage = 4;
	scope->channels = calloc(scope->channel_storage, sizeof(scope_channel));
	scope->window = render_create_window("Oscilloscope", WIDTH, HEIGHT, scope_window_close);
	return scope;
}
uint8_t scope_add_channel(oscilloscope *scope, const char *name, uint32_t sample_rate)
{
	if (scope->num_channels == scope->channel_storage) {
		scope->channel_storage *= 2;
		scope->channels = realloc(scope->channels, scope->channel_storage * sizeof(scope_channel));
	}
	uint8_t channel = scope->num_channels++;
	scope_channel *chan = scope->channels + channel;
	chan->name = name;
	chan->period = sample_rate / 30;
	chan->next_sample = 0;
	chan->samples = calloc(chan->period, sizeof(int16_t));
	chan->last_trigger = INVALID_TRIGGER;
	chan->cur_trigger = INVALID_TRIGGER;
	return channel;
}
void scope_add_sample(oscilloscope *scope, uint8_t channel, int16_t value, uint8_t trigger)
{
	if (channel >= scope->num_channels) {
		return;
	}
	scope_channel *chan = scope->channels + channel;
	if (trigger) {
		chan->cur_trigger = chan->next_sample;
	}
	chan->samples[chan->next_sample++] = value;
	if (chan->next_sample == chan->period) {
		chan->next_sample = 0;
	}
}
void scope_render(oscilloscope *scope)
{
	int pitch;
	pixel_t *fb = render_get_framebuffer(scope->window, &pitch);
	memset(fb, 0, HEIGHT * pitch);
	pitch /= sizeof(pixel_t);
	int offset = 0;
	int column_width = WIDTH/3;
	int width = column_width * 3;
	int row_height = HEIGHT / ((scope->num_channels + 2) / 3);
	float value_scale = (float)row_height / 20000.0f;
	pixel_t *cur_line = fb;
	pixel_t white = render_map_color(255, 255, 255);
	for (uint8_t i = 0; i < scope->num_channels; i++)
	{
		float samples_per_pixel = (float)scope->channels[i].period / (float)(2*column_width);
		uint32_t start = scope->channels[i].last_trigger;
		if (start == INVALID_TRIGGER) {
			if (scope->channels[i].next_sample >= scope->channels[i].period / 2) {
				start = scope->channels[i].next_sample - scope->channels[i].period / 2;
			} else {
				start = scope->channels[i].period - (scope->channels[i].period /2 - scope->channels[i].next_sample);
			}
		}
		scope->channels[i].last_trigger = scope->channels[i].cur_trigger;
		scope->channels[i].cur_trigger = INVALID_TRIGGER;
		float cur_sample = start;
		int last_y = -1;
		for (int x = offset; x < offset + column_width; x++)
		{
			//TODO: bresenham
			//TODO: at least linear filtering
			int16_t sample = scope->channels[i].samples[(int)(cur_sample + 0.5f)];
			int y = (float)sample * value_scale + 0.5f;
			if (y > row_height / 2 - 1) {
				y = row_height / 2 - 1;
			} else if (y < -(row_height / 2)) {
				y = -(row_height / 2);
			}
			y += row_height / 2;
			if (last_y >= 0) {
				int delta = last_y > y ? -1 : 1;
				while (last_y != y)
				{
					cur_line[last_y * pitch + x ] = white;
					last_y += delta;
				}
			} else {
				last_y = y;
			}
			cur_line[y * pitch + x ] = white;
			cur_sample += samples_per_pixel;
			if (cur_sample + 0.5f >= scope->channels[i].period) {
				cur_sample -= scope->channels[i].period;
			}
		}

		offset += column_width;
		if (offset >= width) {
			offset = 0;
			cur_line += pitch * row_height;
		}
	}


	render_framebuffer_updated(scope->window, WIDTH);
}

void scope_close(oscilloscope *scope)
{
	render_destroy_window(scope->window);
	for (uint8_t i = 0; i < scope->num_channels; i++)
	{
		free(scope->channels[i].samples);
	}
	free(scope->channels);
	free(scope);
}
