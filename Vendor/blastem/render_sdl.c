/*
 Copyright 2013 Michael Pavone
 This file is part of BlastEm.
 BlastEm is free software distributed under the terms of the GNU General Public License version 3 or greater. See COPYING for full license text.
*/
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include "render.h"
#include "render_sdl.h"
#include "blastem.h"
#include "genesis.h"
#include "bindings.h"
#include "util.h"
#include "paths.h"
#include "ppm.h"
#include "png.h"
#include "config.h"
#include "controller_info.h"

#ifndef DISABLE_OPENGL
#ifdef USE_GLES
#include <SDL_opengles2.h>
#else
#include <GL/glew.h>
#endif
#endif
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#endif

#define MAX_EVENT_POLL_PER_FRAME 2


typedef struct {
	SDL_Window           *win;
	SDL_Renderer         *renderer;
	SDL_Texture          *sdl_texture;
	SDL_Texture          **static_images;
	window_close_handler on_close;
	ui_render_fun        on_render;
	event_handler        on_event;
	uint32_t             width;
	uint32_t             height;
	uint8_t              num_static;
#ifndef DISABLE_OPENGL
	SDL_GLContext        *gl_context;
	pixel_t              *texture_buf;
	uint32_t             orig_tex_width;
	uint32_t             orig_tex_height;
	uint32_t             tex_width;
	uint32_t             tex_height;
	GLuint               gl_texture[2];
	GLuint               *gl_static_images;
	GLuint               vshader;
	GLuint               fshader;
	GLuint               program;
	GLuint               gl_buffers[3];
	GLuint               image_buffer;
	GLfloat              *image_vertices;
	GLint                un_texture;
	GLint                un_width;
	GLint                un_height;
	GLint                at_pos;
	GLint                at_uv;
	uint8_t              color[4];
#endif
} extra_window;

static SDL_Window *main_window;
static extra_window *extras;
static SDL_Renderer *main_renderer;
static SDL_Texture  *sdl_textures[FRAMEBUFFER_UI + 1];
static window_close_handler *close_handlers;
static uint8_t num_extras;
static SDL_Rect      main_clip;
static SDL_GLContext *main_context;

static int main_width, main_height, windowed_width, windowed_height;

static uint8_t render_gl = 1;
static uint8_t scanlines, is_fullscreen, force_cursor;

static uint32_t last_frame = 0;

static SDL_mutex *audio_mutex, *frame_mutex, *free_buffer_mutex;
static SDL_cond *audio_ready, *frame_ready;
static uint8_t quitting = 0;

enum {
	SYNC_AUDIO,
	SYNC_AUDIO_THREAD,
	SYNC_VIDEO,
	SYNC_EXTERNAL
};

static uint8_t sync_src;
static uint32_t min_buffered;

pixel_t **frame_buffers;
uint32_t num_buffers;
uint32_t buffer_storage;

uint32_t render_min_buffered(void)
{
	return min_buffered;
}

uint8_t render_is_audio_sync(void)
{
	return sync_src < SYNC_VIDEO;
}

uint8_t render_is_threaded_video(void)
{
	return sync_src == SYNC_AUDIO_THREAD || sync_src == SYNC_EXTERNAL;
}

uint8_t render_should_release_on_exit(void)
{
#ifdef __EMSCRIPTEN__
	return 0;
#else
	return sync_src != SYNC_AUDIO_THREAD;
#endif
}

void render_buffer_consumed(audio_source *src)
{
	SDL_CondSignal(src->opaque);
}

static void audio_callback(void * userdata, uint8_t *byte_stream, int len)
{
	SDL_LockMutex(audio_mutex);
		uint8_t all_ready;
#ifdef __EMSCRIPTEN__
		if (!all_sources_ready()) {
			memset(byte_stream, 0, len);
			SDL_UnlockMutex(audio_mutex);
			return;
		}
#else
		do {
			all_ready = all_sources_ready();
			if (!quitting && !all_ready) {
				SDL_CondWait(audio_ready, audio_mutex);
			}
		} while(!quitting && !all_ready);
#endif
		if (!quitting) {
			mix_and_convert(byte_stream, len, NULL);
		}
	SDL_UnlockMutex(audio_mutex);
}

#define NO_LAST_BUFFERED -2000000000
static int32_t last_buffered = NO_LAST_BUFFERED;
static float average_change;
#define BUFFER_FRAMES_THRESHOLD 6
#define BASE_MAX_ADJUST 0.0125
static float max_adjust;
static int32_t cur_min_buffered;
static uint32_t min_remaining_buffer;
static void audio_callback_drc(void *userData, uint8_t *byte_stream, int len)
{
	if (cur_min_buffered < 0) {
		//underflow last frame, but main thread hasn't gotten a chance to call SDL_PauseAudio yet
		return;
	}
	cur_min_buffered = mix_and_convert(byte_stream, len, &min_remaining_buffer);
}

static void audio_callback_run_on_audio(void *user_data, uint8_t *byte_stream, int len)
{
	if (current_system) {
		current_system->resume_context(current_system);
	}
	mix_and_convert(byte_stream, len, NULL);
}

void render_lock_audio()
{
	if (sync_src == SYNC_AUDIO) {
		SDL_LockMutex(audio_mutex);
	} else {
		SDL_LockAudio();
	}
}

void render_unlock_audio()
{
	if (sync_src == SYNC_AUDIO) {
		SDL_UnlockMutex(audio_mutex);
	} else {
		SDL_UnlockAudio();
	}
}

static void render_close_audio()
{
	SDL_LockMutex(audio_mutex);
		quitting = 1;
		SDL_CondSignal(audio_ready);
	SDL_UnlockMutex(audio_mutex);
	SDL_CloseAudio();
	/*
	FIXME: move this to render_audio.c
	if (mix_buf) {
		free(mix_buf);
		mix_buf = NULL;
	}
	*/
}

static uint8_t audio_active;
void *render_new_audio_opaque(void)
{
	return SDL_CreateCond();
}

void render_free_audio_opaque(void *opaque)
{
	SDL_DestroyCond(opaque);
}

void render_audio_created(audio_source *source)
{
	audio_active = 1;
	if (sync_src == SYNC_AUDIO) {
		//SDL_PauseAudio acquires the audio device lock, which is held while the callback runs
		//since our callback can itself be stuck waiting on the audio_ready condition variable
		//calling SDL_PauseAudio(0) again for audio sources after the first can deadlock
		//fortunately SDL_GetAudioStatus does not acquire the lock so is safe to call here
		if (SDL_GetAudioStatus() == SDL_AUDIO_PAUSED) {
			SDL_PauseAudio(0);
		}
	}
	if (current_system && sync_src == SYNC_AUDIO_THREAD) {
		system_request_exit(current_system, 0);
	}
}

void render_source_paused(audio_source *src, uint8_t remaining_sources)
{
	if (sync_src == SYNC_AUDIO) {
		SDL_CondSignal(audio_ready);
	}
	if (!remaining_sources && render_is_audio_sync()) {
		SDL_PauseAudio(1);
		audio_active = 0;
		if (sync_src == SYNC_AUDIO_THREAD) {
			SDL_CondSignal(frame_ready);
		}
	}
}

void render_source_resumed(audio_source *src)
{
	audio_active = 1;
	if (sync_src == SYNC_AUDIO) {
		//SDL_PauseAudio acquires the audio device lock, which is held while the callback runs
		//since our callback can itself be stuck waiting on the audio_ready condition variable
		//calling SDL_PauseAudio(0) again for audio sources after the first can deadlock
		//fortunately SDL_GetAudioStatus does not acquire the lock so is safe to call here
		if (SDL_GetAudioStatus() == SDL_AUDIO_PAUSED) {
			SDL_PauseAudio(0);
		}
	}
	if (current_system && sync_src == SYNC_AUDIO_THREAD) {
		system_request_exit(current_system, 0);
	}
}

uint8_t audio_deadlock_hack(void);

static ui_render_fun audio_full_cb;
void render_set_audio_full_fun(ui_render_fun cb)
{
	audio_full_cb = cb;
}

void render_do_audio_ready(audio_source *src)
{
	if (sync_src == SYNC_AUDIO_THREAD) {
		int16_t *tmp = src->front;
		src->front = src->back;
		src->back = tmp;
		src->front_populated = 1;
		src->buffer_pos = 0;
		if (all_sources_ready()) {
			//we've emulated far enough to fill the current buffer
			system_request_exit(current_system, 0);
		}
	} else if (sync_src == SYNC_AUDIO) {
		uint8_t all_ready = 0;
		SDL_LockMutex(audio_mutex);
#ifndef __EMSCRIPTEN__
			if (src->front_populated) {
				if (audio_deadlock_hack()) {
					SDL_CondSignal(audio_ready);
				}
			}
			while (src->front_populated) {
				SDL_CondWait(src->opaque, audio_mutex);
			}
#endif
			int16_t *tmp = src->front;
			src->front = src->back;
			src->back = tmp;
			src->front_populated = 1;
			src->buffer_pos = 0;
			all_ready = all_sources_ready();
			SDL_CondSignal(audio_ready);
		SDL_UnlockMutex(audio_mutex);
		if (all_ready && audio_full_cb) {
			audio_full_cb();
		}
	} else {
		uint32_t num_buffered;
		SDL_LockAudio();
			src->read_end = src->buffer_pos;
			num_buffered = ((src->read_end - src->read_start) & src->mask) / src->num_channels;
		SDL_UnlockAudio();
		if (num_buffered >= min_buffered && SDL_GetAudioStatus() == SDL_AUDIO_PAUSED) {
			SDL_PauseAudio(0);
		}
	}
}

static SDL_Joystick * joysticks[MAX_JOYSTICKS];
static int joystick_sdl_index[MAX_JOYSTICKS];
static uint8_t joystick_index_locked[MAX_JOYSTICKS];

int render_width()
{
	return main_width;
}

int render_height()
{
	return main_height;
}

uint8_t render_fullscreen(void)
{
	return is_fullscreen;
}

pixel_t render_map_color(uint8_t r, uint8_t g, uint8_t b)
{
#ifdef USE_RGB565
	return r << 8 & 0xF800 | g << 3 & 0x07E0 | b >> 3;
#else
#ifdef USE_GLES
	return 255UL << 24 | b << 16 | g << 8 | r;
#else
	return 255UL << 24 | r << 16 | g << 8 | b;
#endif
#endif
}

static uint8_t external_sync;
void render_set_external_sync(uint8_t ext_sync_on)
{
	if (ext_sync_on != external_sync) {
		external_sync = ext_sync_on;
		if (windowed_width) {
			//only do this if render_init has already been called
			render_config_updated();
		}
	}
}

static int tex_width, tex_height;
#ifndef DISABLE_OPENGL
static GLuint textures[3], buffers[2], vshader, fshader, program;
static GLint un_textures[2], un_width, un_height, un_texsize, un_curfield, un_interlaced, un_scanlines, at_pos;

static GLfloat vertex_data_default[] = {
	-1.0f, -1.0f,
	 1.0f, -1.0f,
	-1.0f,  1.0f,
	 1.0f,  1.0f
};

static GLfloat uvs[] = {
	 0.0f,  1.0f,
	 1.0f,  1.0f,
	 0.0f,  0.0f,
	 1.0f,  0.0f
};

static GLfloat vertex_data[8];

static const GLushort element_data[] = {0, 1, 2, 3};

static const GLchar shader_prefix[] =
#ifdef USE_GLES
	"#version 100\n";
#else
	"#version 110\n"
	"#define lowp\n"
	"#define mediump\n"
	"#define highp\n";
#endif

static GLuint load_shader(char * fname, GLenum shader_type)
{
	char * shader_path;
	FILE *f;
	GLchar *text;
	long fsize;
#ifndef __ANDROID__
	char const * parts[] = {get_home_dir(), "/.config/blastem/shaders/", fname};
	shader_path = alloc_concat_m(3, parts);
	f = fopen(shader_path, "rb");
	free(shader_path);
	if (f) {
		fsize = file_size(f);
		text = malloc(fsize);
		if (fread(text, 1, fsize, f) != fsize) {
			warning("Error reading from shader file %s\n", fname);
			free(text);
			return 0;
		}
	} else {
#endif
		shader_path = path_append("shaders", fname);
		uint32_t fsize32;
		text = read_bundled_file(shader_path, &fsize32);
		free(shader_path);
		if (!text) {
			warning("Failed to open shader file %s for reading\n", fname);
			return 0;
		}
		fsize = fsize32;
#ifndef __ANDROID__
	}
#endif
	text[fsize] = 0;

	if (strncmp(text, "#version", strlen("#version"))) {
		GLchar *tmp = text;
		text = alloc_concat(shader_prefix, tmp);
		free(tmp);
		fsize += strlen(shader_prefix);
	}
	GLuint ret = glCreateShader(shader_type);
	if (!ret) {
		warning("glCreateShader failed with error %d\n", glGetError());
		return 0;
	}
	glShaderSource(ret, 1, (const GLchar **)&text, (const GLint *)&fsize);
	free(text);
	glCompileShader(ret);
	GLint compile_status, loglen;
	glGetShaderiv(ret, GL_COMPILE_STATUS, &compile_status);
	if (!compile_status) {
		glGetShaderiv(ret, GL_INFO_LOG_LENGTH, &loglen);
		text = malloc(loglen);
		glGetShaderInfoLog(ret, loglen, NULL, text);
		warning("Shader %s failed to compile:\n%s\n", fname, text);
		free(text);
		glDeleteShader(ret);
		return 0;
	}
	return ret;
}
#endif

static pixel_t texture_buf[512 * 513];
#ifdef DISABLE_OPENGL
#ifdef USE_RGB565
#define RENDER_FORMAT SDL_PIXELFORMAT_RGB565
#else
#define RENDER_FORMAT SDL_PIXELFORMAT_ARGB8888
#endif
#else //DISABLE_OPENGL
#ifdef USE_RGB565
#define INTERNAL_FORMAT GL_RGB
#define SRC_FORMAT GL_RGB
#define SRC_TYPE GL_UNSIGNED_SHORT_5_6_5
#define RENDER_FORMAT SDL_PIXELFORMAT_RGB565
#else //USE_RGB565
#define SRC_TYPE GL_UNSIGNED_BYTE
#ifdef USE_GLES
#define INTERNAL_FORMAT GL_RGBA
#define SRC_FORMAT GL_RGBA
#define RENDER_FORMAT SDL_PIXELFORMAT_ABGR8888
#else //USE_GLES
#define INTERNAL_FORMAT GL_RGBA8
#define SRC_FORMAT GL_BGRA
#define RENDER_FORMAT SDL_PIXELFORMAT_ARGB8888
#endif //USE_GLES
#endif //USE_RGB565

#ifdef USE_GLES
#define SRC_FORMAT32 GL_RGBA
#else
#define SRC_FORMAT32 GL_BGRA
#endif

static void gl_setup()
{
	tern_val def = {.ptrval = "linear"};
	char *scaling = tern_find_path_default(config, "video\0scaling\0", def, TVAL_PTR).ptrval;
	GLint filter = strcmp(scaling, "linear") ? GL_NEAREST : GL_LINEAR;
	glGenTextures(3, textures);
	def.ptrval = "off";
	char *npot_textures = tern_find_path_default(config, "video\0npot_textures\0", def, TVAL_PTR).ptrval;
	if (!strcmp(npot_textures, "on")) {
		tex_width = LINEBUF_SIZE;
		tex_height = 294; //PAL height with full borders
	} else {
		tex_width = tex_height = 512;
	}
	debug_message("Using %dx%d textures\n", tex_width, tex_height);
	for (int i = 0; i < 3; i++)
	{
		glBindTexture(GL_TEXTURE_2D, textures[i]);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filter);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filter);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
		if (i < 2) {
			//TODO: Fixme for PAL + invalid display mode
			glTexImage2D(GL_TEXTURE_2D, 0, INTERNAL_FORMAT, tex_width, tex_height, 0, SRC_FORMAT, SRC_TYPE, texture_buf);
		} else {
			pixel_t blank = render_map_color(0, 0, 0);
			glTexImage2D(GL_TEXTURE_2D, 0, INTERNAL_FORMAT, 1, 1, 0, SRC_FORMAT, SRC_TYPE, &blank);
		}
	}
	glGenBuffers(2, buffers);
	glBindBuffer(GL_ARRAY_BUFFER, buffers[0]);
	glBufferData(GL_ARRAY_BUFFER, sizeof(vertex_data), vertex_data, GL_STATIC_DRAW);
	glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, buffers[1]);
	glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(element_data), element_data, GL_STATIC_DRAW);
	def.ptrval = "default.v.glsl";
	vshader = load_shader(tern_find_path_default(config, "video\0vertex_shader\0", def, TVAL_PTR).ptrval, GL_VERTEX_SHADER);
	def.ptrval = "default.f.glsl";
	fshader = load_shader(tern_find_path_default(config, "video\0fragment_shader\0", def, TVAL_PTR).ptrval, GL_FRAGMENT_SHADER);
	program = glCreateProgram();
	glAttachShader(program, vshader);
	glAttachShader(program, fshader);
	glLinkProgram(program);
	GLint link_status;
	glGetProgramiv(program, GL_LINK_STATUS, &link_status);
	if (!link_status) {
		fputs("Failed to link shader program\n", stderr);
		exit(1);
	}
	un_textures[0] = glGetUniformLocation(program, "textures[0]");
	un_textures[1] = glGetUniformLocation(program, "textures[1]");
	un_width = glGetUniformLocation(program, "width");
	un_height = glGetUniformLocation(program, "height");
	un_texsize = glGetUniformLocation(program, "texsize");
	un_curfield = glGetUniformLocation(program, "curfield");
	un_interlaced = glGetUniformLocation(program, "interlaced");
	un_scanlines = glGetUniformLocation(program, "scanlines");
	at_pos = glGetAttribLocation(program, "pos");
}

static void gl_teardown()
{
	glDeleteProgram(program);
	glDeleteShader(vshader);
	glDeleteShader(fshader);
	glDeleteBuffers(2, buffers);
	glDeleteTextures(3, textures);
}
#endif //DISABLE_OPENGL

static uint8_t texture_init;
static void render_alloc_surfaces()
{
	if (texture_init) {
		return;
	}
	texture_init = 1;
#ifndef DISABLE_OPENGL
	if (render_gl) {
		gl_setup();
	} else {
#endif
		tern_val def = {.ptrval = "linear"};
		char *scaling = tern_find_path_default(config, "video\0scaling\0", def, TVAL_PTR).ptrval;
		SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, scaling);
		//TODO: Fixme for invalid display mode
		sdl_textures[0] = sdl_textures[1] = SDL_CreateTexture(main_renderer, RENDER_FORMAT, SDL_TEXTUREACCESS_STREAMING, LINEBUF_SIZE, 588);
#ifndef DISABLE_OPENGL
	}
#endif
}

static void free_surfaces(void)
{
	for (int i = 0; i <= FRAMEBUFFER_UI; i++)
	{
		if (sdl_textures[i]) {
			SDL_DestroyTexture(sdl_textures[i]);
		}
	}
	texture_init = 0;
}

static char * caption = NULL;
static char * fps_caption = NULL;

static void render_quit()
{
	render_close_audio();
	free_surfaces();
#ifndef DISABLE_OPENGL
	if (render_gl) {
		gl_teardown();
		SDL_GL_DeleteContext(main_context);
	}
#endif
}

static float config_aspect()
{
	static float aspect = 0.0f;
	if (aspect == 0.0f) {
		char *config_aspect = tern_find_path_default(config, "video\0aspect\0", (tern_val){.ptrval = "4:3"}, TVAL_PTR).ptrval;
		if (strcmp("stretch", config_aspect)) {
			aspect = 4.0f/3.0f;
			char *end;
			float aspect_numerator = strtof(config_aspect, &end);
			if (aspect_numerator > 0.0f && *end == ':') {
				float aspect_denominator = strtof(end+1, &end);
				if (aspect_denominator > 0.0f && !*end) {
					aspect = aspect_numerator / aspect_denominator;
				}
			}
		} else {
			aspect = -1.0f;
		}
	}
	return aspect;
}

static void update_aspect()
{
	//reset default values
#ifndef DISABLE_OPENGL
	memcpy(vertex_data, vertex_data_default, sizeof(vertex_data));
#endif
	main_clip.w = main_width;
	main_clip.h = main_height;
	main_clip.x = main_clip.y = 0;
	if (config_aspect() > 0.0f) {
		char *integer_scaling_str = tern_find_path_default(config, "video\0integer_scaling\0", (tern_val){.ptrval = "off"}, TVAL_PTR).ptrval;
		uint8_t integer_scaling = !strcmp(integer_scaling_str, "on");
		float aspect = (float)main_width / main_height;
		if (!integer_scaling && fabs(aspect - config_aspect()) < 0.01f) {
			//close enough for government work
			return;
		}
		uint32_t height, scale;
		if (integer_scaling) {
			height = render_emulated_height();
			if (aspect >= config_aspect()) {
				scale = main_height / height;
			} else {
				uint32_t aspect_height = 0.5f + (float)main_width / config_aspect();
				scale = aspect_height / height;
			}
		}
#ifndef DISABLE_OPENGL
		if (render_gl) {
			if (integer_scaling) {
				float vscale = ((float)(scale * height)) / (float)main_height;
				float hscale = (config_aspect() * (float)(scale * height)) / (float)main_width;
				for (int i = 0; i < 4; i++)
				{
					vertex_data[i*2] *= hscale;
					vertex_data[i*2+1] *= vscale;
				}
			} else {
				for (int i = 0; i < 4; i++)
				{
					if (aspect > config_aspect()) {
						vertex_data[i*2] *= config_aspect()/aspect;
					} else {
						vertex_data[i*2+1] *= aspect/config_aspect();
					}
				}
			}
		} else {
#endif
			if (integer_scaling) {
				main_clip.h = height * scale;
				main_clip.w = main_clip.h * config_aspect();
			} else {
				main_clip.w = aspect > config_aspect() ? config_aspect() * (float)main_height : main_width;
				main_clip.h = aspect > config_aspect() ? main_height : main_width / config_aspect();
			}
			main_clip.x = (main_width  - main_clip.w) / 2;
			main_clip.y = (main_height - main_clip.h) / 2;
#ifndef DISABLE_OPENGL
		}
#endif
	}
}

static ui_render_fun on_context_destroyed, on_context_created, on_ui_fb_resized;
void render_set_gl_context_handlers(ui_render_fun destroy, ui_render_fun create)
{
	on_context_destroyed = destroy;
	on_context_created = create;
}

void render_set_ui_fb_resize_handler(ui_render_fun resize)
{
	on_ui_fb_resized = resize;
}

static uint8_t scancode_map[SDL_NUM_SCANCODES] = {
	[SDL_SCANCODE_A] = 0x1C,
	[SDL_SCANCODE_B] = 0x32,
	[SDL_SCANCODE_C] = 0x21,
	[SDL_SCANCODE_D] = 0x23,
	[SDL_SCANCODE_E] = 0x24,
	[SDL_SCANCODE_F] = 0x2B,
	[SDL_SCANCODE_G] = 0x34,
	[SDL_SCANCODE_H] = 0x33,
	[SDL_SCANCODE_I] = 0x43,
	[SDL_SCANCODE_J] = 0x3B,
	[SDL_SCANCODE_K] = 0x42,
	[SDL_SCANCODE_L] = 0x4B,
	[SDL_SCANCODE_M] = 0x3A,
	[SDL_SCANCODE_N] = 0x31,
	[SDL_SCANCODE_O] = 0x44,
	[SDL_SCANCODE_P] = 0x4D,
	[SDL_SCANCODE_Q] = 0x15,
	[SDL_SCANCODE_R] = 0x2D,
	[SDL_SCANCODE_S] = 0x1B,
	[SDL_SCANCODE_T] = 0x2C,
	[SDL_SCANCODE_U] = 0x3C,
	[SDL_SCANCODE_V] = 0x2A,
	[SDL_SCANCODE_W] = 0x1D,
	[SDL_SCANCODE_X] = 0x22,
	[SDL_SCANCODE_Y] = 0x35,
	[SDL_SCANCODE_Z] = 0x1A,
	[SDL_SCANCODE_1] = 0x16,
	[SDL_SCANCODE_2] = 0x1E,
	[SDL_SCANCODE_3] = 0x26,
	[SDL_SCANCODE_4] = 0x25,
	[SDL_SCANCODE_5] = 0x2E,
	[SDL_SCANCODE_6] = 0x36,
	[SDL_SCANCODE_7] = 0x3D,
	[SDL_SCANCODE_8] = 0x3E,
	[SDL_SCANCODE_9] = 0x46,
	[SDL_SCANCODE_0] = 0x45,
	[SDL_SCANCODE_RETURN] = 0x5A,
	[SDL_SCANCODE_ESCAPE] = 0x76,
	[SDL_SCANCODE_SPACE] = 0x29,
	[SDL_SCANCODE_TAB] = 0x0D,
	[SDL_SCANCODE_BACKSPACE] = 0x66,
	[SDL_SCANCODE_MINUS] = 0x4E,
	[SDL_SCANCODE_EQUALS] = 0x55,
	[SDL_SCANCODE_LEFTBRACKET] = 0x54,
	[SDL_SCANCODE_RIGHTBRACKET] = 0x5B,
	[SDL_SCANCODE_BACKSLASH] = 0x5D,
	[SDL_SCANCODE_SEMICOLON] = 0x4C,
	[SDL_SCANCODE_APOSTROPHE] = 0x52,
	[SDL_SCANCODE_GRAVE] = 0x0E,
	[SDL_SCANCODE_COMMA] = 0x41,
	[SDL_SCANCODE_PERIOD] = 0x49,
	[SDL_SCANCODE_SLASH] = 0x4A,
	[SDL_SCANCODE_CAPSLOCK] = 0x58,
	[SDL_SCANCODE_F1] = 0x05,
	[SDL_SCANCODE_F2] = 0x06,
	[SDL_SCANCODE_F3] = 0x04,
	[SDL_SCANCODE_F4] = 0x0C,
	[SDL_SCANCODE_F5] = 0x03,
	[SDL_SCANCODE_F6] = 0x0B,
	[SDL_SCANCODE_F7] = 0x83,
	[SDL_SCANCODE_F8] = 0x0A,
	[SDL_SCANCODE_F9] = 0x01,
	[SDL_SCANCODE_F10] = 0x09,
	[SDL_SCANCODE_F11] = 0x78,
	[SDL_SCANCODE_F12] = 0x07,
	[SDL_SCANCODE_LCTRL] = 0x14,
	[SDL_SCANCODE_LSHIFT] = 0x12,
	[SDL_SCANCODE_LALT] = 0x11,
	[SDL_SCANCODE_RCTRL] = 0x18,
	[SDL_SCANCODE_RSHIFT] = 0x59,
	[SDL_SCANCODE_RALT] = 0x17,
	[SDL_SCANCODE_INSERT] = 0x81,
	[SDL_SCANCODE_PAUSE] = 0x82,
	[SDL_SCANCODE_PRINTSCREEN] = 0x84,
	[SDL_SCANCODE_SCROLLLOCK] = 0x7E,
	[SDL_SCANCODE_DELETE] = 0x85,
	[SDL_SCANCODE_LEFT] = 0x86,
	[SDL_SCANCODE_HOME] = 0x87,
	[SDL_SCANCODE_END] = 0x88,
	[SDL_SCANCODE_UP] = 0x89,
	[SDL_SCANCODE_DOWN] = 0x8A,
	[SDL_SCANCODE_PAGEUP] = 0x8B,
	[SDL_SCANCODE_PAGEDOWN] = 0x8C,
	[SDL_SCANCODE_RIGHT] = 0x8D,
	[SDL_SCANCODE_NUMLOCKCLEAR] = 0x77,
	[SDL_SCANCODE_KP_DIVIDE] = 0x80,
	[SDL_SCANCODE_KP_MULTIPLY] = 0x7C,
	[SDL_SCANCODE_KP_MINUS] = 0x7B,
	[SDL_SCANCODE_KP_PLUS] = 0x79,
	[SDL_SCANCODE_KP_ENTER] = 0x19,
	[SDL_SCANCODE_KP_1] = 0x69,
	[SDL_SCANCODE_KP_2] = 0x72,
	[SDL_SCANCODE_KP_3] = 0x7A,
	[SDL_SCANCODE_KP_4] = 0x6B,
	[SDL_SCANCODE_KP_5] = 0x73,
	[SDL_SCANCODE_KP_6] = 0x74,
	[SDL_SCANCODE_KP_7] = 0x6C,
	[SDL_SCANCODE_KP_8] = 0x75,
	[SDL_SCANCODE_KP_9] = 0x7D,
	[SDL_SCANCODE_KP_0] = 0x70,
	[SDL_SCANCODE_KP_PERIOD] = 0x71,
};

static drop_handler drag_drop_handler;
void render_set_drag_drop_handler(drop_handler handler)
{
	drag_drop_handler = handler;
}

static event_handler custom_event_handler;
void render_set_event_handler(uint8_t which, event_handler handler)
{
	if (which < FRAMEBUFFER_USER_START) {
		custom_event_handler = handler;
	} else {
		extras[which - FRAMEBUFFER_USER_START].on_event = handler;
	}
}

int render_find_joystick_index(SDL_JoystickID instanceID)
{
	for (int i = 0; i < MAX_JOYSTICKS; i++) {
		if (joysticks[i] && SDL_JoystickInstanceID(joysticks[i]) == instanceID) {
			return i;
		}
	}
	return -1;
}

static int lowest_unused_joystick_index()
{
	for (int i = 0; i < MAX_JOYSTICKS; i++) {
		if (!joysticks[i]) {
			return i;
		}
	}
	return -1;
}

static int lowest_unlocked_joystick_index(void)
{
	for (int i = 0; i < MAX_JOYSTICKS; i++) {
		if (!joystick_index_locked[i]) {
			return i;
		}
	}
	return -1;
}

SDL_Joystick *render_get_joystick(int index)
{
	if (index >= MAX_JOYSTICKS) {
		return NULL;
	}
	return joysticks[index];
}

char* render_joystick_type_id(int index)
{
	SDL_Joystick *stick = render_get_joystick(index);
	if (!stick) {
		return NULL;
	}
	char *guid_string = malloc(33);
	SDL_JoystickGetGUIDString(SDL_JoystickGetGUID(stick), guid_string, 33);
	return guid_string;
}

SDL_GameController *render_get_controller(int index)
{
	if (index >= MAX_JOYSTICKS || !joysticks[index]) {
		return NULL;
	}
	return SDL_GameControllerOpen(joystick_sdl_index[index]);
}

static uint8_t gc_events_enabled;
static SDL_GameController *controllers[MAX_JOYSTICKS];
void render_enable_gamepad_events(uint8_t enabled)
{
	if (enabled != gc_events_enabled) {
		gc_events_enabled = enabled;
		for (int i = 0; i < MAX_JOYSTICKS; i++) {
			if (enabled) {
				controllers[i] = render_get_controller(i);
			} else if (controllers[i]) {
				SDL_GameControllerClose(controllers[i]);
				controllers[i] = NULL;
			}
		}
	}
}
uint8_t render_are_gamepad_events_enabled(void)
{
	return gc_events_enabled;
}

static uint32_t overscan_top[NUM_VID_STD] = {2, 21, 51};
static uint32_t overscan_bot[NUM_VID_STD] = {1, 17, 48};
static uint32_t overscan_left[NUM_VID_STD] = {13, 13, 61};
static uint32_t overscan_right[NUM_VID_STD] = {14, 14, 62};
static vid_std video_standard = VID_NTSC;
static uint8_t need_ui_fb_resize;

int lock_joystick_index(int joystick, int desired_index)
{
	if (desired_index < 0) {
		desired_index = lowest_unlocked_joystick_index();
		if (desired_index < 0 || desired_index >= joystick) {
			return joystick;
		}
	}
	SDL_Joystick *tmp_joy = joysticks[joystick];
	int tmp_index = joystick_sdl_index[joystick];
	joysticks[joystick] = joysticks[desired_index];
	joystick_sdl_index[joystick] = joystick_sdl_index[desired_index];
	joystick_index_locked[joystick] = joystick_index_locked[desired_index];
	joysticks[desired_index] = tmp_joy;
	joystick_sdl_index[desired_index] = tmp_index;
	joystick_index_locked[desired_index] = 1;
	//update bindings as the controllers being swapped may have different mappings
	handle_joy_added(desired_index);
	if (joysticks[joystick]) {
		handle_joy_added(joystick);
	}
	return desired_index;
}

static float ui_scale_x = 1.0f, ui_scale_y = 1.0f;
int render_ui_to_pixels_x(int ui)
{
	return ui * ui_scale_x + 0.5f;
}

int render_ui_to_pixels_y(int ui)
{
	return ui * ui_scale_y + 0.5f;
}

static uint8_t has_event_handler(SDL_Window *win)
{
	for (uint8_t i = 0; i < num_extras; i++)
	{
		if (extras[i].win == win) {
			return extras[i].on_event != NULL;
		}
	}
	return 0;
}

static uint8_t main_is_relative;
static uint8_t main_has_focus;
void render_relative_mouse(uint8_t enabled)
{
	main_is_relative = enabled;
	if (main_has_focus) {
		SDL_SetRelativeMouseMode(enabled);
	}
}



#ifndef DISABLE_OPENGL
static void gl_set_vsync(const char *vsync)
{
	SDL_GL_MakeCurrent(main_window, main_context);
	if (!strcmp("tear", vsync)) {
		if (SDL_GL_SetSwapInterval(-1) < 0) {
			warning("late tear is not available (%s), using normal vsync\n", SDL_GetError());
			vsync = "on";
		} else {
			vsync = NULL;
		}
	}
	if (vsync) {
		if (SDL_GL_SetSwapInterval(!strcmp("on", vsync)) < 0) {
#ifdef __ANDROID__
			debug_message("Failed to set vsync to %s: %s\n", vsync, SDL_GetError());
#else
			warning("Failed to set vsync to %s: %s\n", vsync, SDL_GetError());
#endif
		}
	} else {
		printf("vsync not set, SDL_GL_SetSwapInterval not called\n");
	}
}
#endif

static int32_t handle_event(SDL_Event *event)
{
	SDL_Window *event_win = NULL;
	switch (event->type) {
	case SDL_KEYDOWN:
		event_win = SDL_GetWindowFromID(event->key.windowID);
		if (event_win == main_window || !has_event_handler(event_win)) {
			handle_keydown(event->key.keysym.sym, scancode_map[event->key.keysym.scancode]);
		}
		break;
	case SDL_KEYUP:
		event_win = SDL_GetWindowFromID(event->key.windowID);
		if (event_win == main_window || !has_event_handler(event_win)) {
			handle_keyup(event->key.keysym.sym, scancode_map[event->key.keysym.scancode]);
		}
		break;
	case SDL_JOYBUTTONDOWN:
		event_win = main_window;
		handle_joydown(render_find_joystick_index(event->jbutton.which), event->jbutton.button);
		break;
	case SDL_JOYBUTTONUP:
		event_win = main_window;
		handle_joyup(lock_joystick_index(render_find_joystick_index(event->jbutton.which), -1), event->jbutton.button);
		break;
	case SDL_JOYHATMOTION:
		event_win = main_window;
		handle_joy_dpad(lock_joystick_index(render_find_joystick_index(event->jhat.which), -1), event->jhat.hat, event->jhat.value);
		break;
	case SDL_JOYAXISMOTION:
		event_win = main_window;
		handle_joy_axis(lock_joystick_index(render_find_joystick_index(event->jaxis.which), -1), event->jaxis.axis, event->jaxis.value);
		break;
	case SDL_JOYDEVICEADDED: {
		int index = lowest_unused_joystick_index();
		if (index >= 0) {
			SDL_Joystick * joy = SDL_JoystickOpen(event->jdevice.which);
			if (SDL_JoystickNumAxes(joy) == 3 && SDL_JoystickNumButtons(joy) == 0) {
				//probably just an acclerometer or gyro
				SDL_JoystickClose(joy);
				break;
			}
			joysticks[index] = joy;
			joystick_sdl_index[index] = event->jdevice.which;
			joystick_index_locked[index] = 0;
			if (gc_events_enabled) {
				controllers[index] = SDL_GameControllerOpen(event->jdevice.which);
			}
			if (joy) {
				debug_message("Joystick %d added: %s\n", index, SDL_JoystickName(joy));
				debug_message("\tNum Axes: %d\n\tNum Buttons: %d\n\tNum Hats: %d\n", SDL_JoystickNumAxes(joy), SDL_JoystickNumButtons(joy), SDL_JoystickNumHats(joy));
				handle_joy_added(index);
			}
		}
		break;
	}
	case SDL_JOYDEVICEREMOVED: {
		int index = render_find_joystick_index(event->jdevice.which);
		if (index >= 0) {
			SDL_JoystickClose(joysticks[index]);
			joysticks[index] = NULL;
			if (controllers[index]) {
				SDL_GameControllerClose(controllers[index]);
				controllers[index] = NULL;
			}
			debug_message("Joystick %d removed\n", index);
		} else {
			debug_message("Failed to find removed joystick with instance ID: %d\n", index);
		}
		break;
	}
	case SDL_MOUSEMOTION:
		event_win = SDL_GetWindowFromID(event->motion.windowID);
		handle_mouse_moved(event->motion.which, event->motion.x * ui_scale_x + 0.5f, event->motion.y * ui_scale_y + 0.5f + overscan_top[video_standard], event->motion.xrel, event->motion.yrel);
		break;
	case SDL_MOUSEBUTTONDOWN:
		event_win = SDL_GetWindowFromID(event->button.windowID);
		handle_mousedown(event->button.which, event->button.button);
		break;
	case SDL_MOUSEBUTTONUP:
		event_win = SDL_GetWindowFromID(event->button.windowID);
		handle_mouseup(event->button.which, event->button.button);
		break;
	case SDL_MOUSEWHEEL:
		event_win = SDL_GetWindowFromID(event->wheel.windowID);
		break;
	case SDL_FINGERMOTION:
	case SDL_FINGERDOWN:
	case SDL_FINGERUP:
#if SDL_VERSION_ATLEAST(2, 0, 12)
		event_win = SDL_GetWindowFromID(event->tfinger.windowID);
#else
		event_win = main_window;
#endif
		break;
	case SDL_WINDOWEVENT:
		switch (event->window.event)
		{
		case SDL_WINDOWEVENT_SIZE_CHANGED:
			if (!main_window || SDL_GetWindowFromID(event->window.windowID) != main_window) {
				break;
			}
			need_ui_fb_resize = 1;
			const char *vsync;
			if (sync_src == SYNC_AUDIO) {
				tern_val def = {.ptrval = "off"};
				vsync = tern_find_path_default(config, "video\0vsync\0", def, TVAL_PTR).ptrval;
			} else {
				vsync = "on";
			}
#ifndef DISABLE_OPENGL
			if (render_gl) {
				SDL_GL_MakeCurrent(main_window, main_context);
				if (on_context_destroyed) {
					on_context_destroyed();
				}
				gl_teardown();
				SDL_GL_DeleteContext(main_context);
				main_context = SDL_GL_CreateContext(main_window);
				SDL_GL_GetDrawableSize(main_window, &main_width, &main_height);
				update_aspect();
				gl_set_vsync(vsync);
				gl_setup();
				if (on_context_created) {
					on_context_created();
				}
			} else {
#endif
				SDL_GetRendererOutputSize(main_renderer, &main_width, &main_height);
				update_aspect();
#ifndef DISABLE_OPENGL
			}
#endif
			if (main_width != event->window.data1 || main_height != event->window.data2) {
				debug_message("Window resized - UI units %dx%d, pixels %dx%d\n", event->window.data1, event->window.data2, main_width, main_height);
			} else {
				debug_message("Window resized: %dx%d\n", main_width, main_height);
			}
			ui_scale_x = (float)main_width / (float)event->window.data1;
			ui_scale_y = (float)main_height / (float)event->window.data2;
			break;
		case SDL_WINDOWEVENT_ENTER:
			main_has_focus = main_window && SDL_GetWindowID(main_window) == event->window.windowID;
			if (main_is_relative) {
				SDL_SetRelativeMouseMode(main_has_focus);
			}
			break;
		case SDL_WINDOWEVENT_LEAVE:
			main_has_focus = !(main_window && SDL_GetWindowID(main_window) == event->window.windowID);
			if (main_is_relative && main_has_focus) {
				SDL_SetRelativeMouseMode(0);
			}
			break;
		case SDL_WINDOWEVENT_CLOSE:
			if (main_window && SDL_GetWindowID(main_window) == event->window.windowID) {
				exit(0);
			} else {
				for (int i = 0; i < num_extras; i++)
				{
					if (SDL_GetWindowID(extras[i].win) == event->window.windowID) {
						if (extras[i].on_close) {
							extras[i].on_close(i + FRAMEBUFFER_USER_START);
						}
						break;
					}
				}
			}
			break;
		}
		break;
	case SDL_TEXTEDITING:
		event_win = SDL_GetWindowFromID(event->edit.windowID);
		break;
#if SDL_VERSION_ATLEAST(2, 0, 22)
	case SDL_TEXTEDITING_EXT:
		event_win = SDL_GetWindowFromID(event->editExt.windowID);
		break;
#endif
	case SDL_TEXTINPUT:
		event_win = SDL_GetWindowFromID(event->text.windowID);
		break;
	case SDL_DROPFILE:
		if (drag_drop_handler) {
			drag_drop_handler(strdup(event->drop.file));
		}
		SDL_free(event->drop.file);
		break;
	case SDL_QUIT:
		puts("");
		exit(0);
	default:
		event_win = main_window;
		break;
	}
	if (event_win) {
		if (event_win == main_window) {
			if (custom_event_handler) {
				custom_event_handler(FRAMEBUFFER_UI, event);
			}
		} else {
			for (uint8_t i = 0; i < num_extras; i++)
			{
				if (extras[i].win == event_win) {
					if (extras[i].on_event) {
						extras[i].on_event(i + FRAMEBUFFER_USER_START, event);
					}
					break;
				}
			}
		}
	}
	return 0;
}

static void drain_events()
{
	SDL_Event event;
	while(SDL_PollEvent(&event))
	{
		handle_event(&event);
	}
}

static char *vid_std_names[NUM_VID_STD] = {"ntsc", "pal", "gamegear"};
static int display_hz;
static int source_hz;
static int source_frame;
static int source_frame_count;
static int frame_repeat[60];

static uint32_t sample_rate;
typedef struct {
	int      rate;
	int      samples;
	uint16_t format;
} audio_config;

static audio_config get_audio_config(void)
{
	audio_config ret;
	char * rate_str = tern_find_path(config, "audio\0rate\0", TVAL_PTR).ptrval;
   	ret.rate = rate_str ? atoi(rate_str) : 0;
   	if (!ret.rate) {
   		ret.rate = 48000;
   	}
	char *config_format = tern_find_path_default(config, "audio\0format\0", (tern_val){.ptrval="f32"}, TVAL_PTR).ptrval;
	ret.format = !strcmp(config_format, "s16") ? AUDIO_S16SYS : AUDIO_F32SYS;
    char * samples_str = tern_find_path(config, "audio\0buffer\0", TVAL_PTR).ptrval;
   	ret.samples = samples_str ? atoi(samples_str) : 0;
   	if (!ret.samples) {
   		ret.samples = 512;
   	}
	return ret;
}

static audio_config current_audio_config;
static void init_audio(void)
{
	SDL_AudioSpec desired, actual;
	audio_config ac = get_audio_config();
	desired.freq = ac.rate;
	desired.format = ac.format;
	desired.channels = 2;
	desired.samples = ac.samples * 2;
	switch (sync_src)
	{
	case SYNC_AUDIO:
		desired.callback = audio_callback;
		break;
	case SYNC_AUDIO_THREAD:
		desired.callback = audio_callback_run_on_audio;
		break;
	default:
		desired.callback = audio_callback_drc;
	}
	desired.userdata = NULL;

	if (SDL_OpenAudio(&desired, &actual) < 0) {
		fatal_error("Unable to open SDL audio: %s\n", SDL_GetError());
	}
	current_audio_config = ac;
	sample_rate = actual.freq;
	debug_message("Initialized %d channel audio at frequency %d with a %d sample buffer, ", actual.channels, actual.freq, actual.samples);
	render_audio_format format = RENDER_AUDIO_UNKNOWN;
	if (actual.format == AUDIO_S16SYS) {
		debug_message("signed 16-bit int format\n");
		format = RENDER_AUDIO_S16;
	} else if (actual.format == AUDIO_F32SYS) {
		debug_message("32-bit float format\n");
		format = RENDER_AUDIO_FLOAT;
	} else {
		debug_message("unsupported format %X\n", actual.format);
		warning("Unsupported audio sample format: %X\n", actual.format);
	}
#ifdef __EMSCRIPTEN__
	if (sync_src == SYNC_AUDIO) {
		printf("emscripten_set_main_loop_timing %d\n", actual.samples * 500 / actual.freq);
		emscripten_set_main_loop_timing(EM_TIMING_SETTIMEOUT, actual.samples * 500 / actual.freq);
	}
#endif
	render_audio_initialized(format, actual.freq, actual.channels, actual.samples, SDL_AUDIO_BITSIZE(actual.format) / 8);
}

static void update_cursor(void)
{
	SDL_ShowCursor((is_fullscreen && !force_cursor) ? SDL_DISABLE : SDL_ENABLE);
}

void render_force_cursor(uint8_t force)
{
	if (force != force_cursor) {
		force_cursor = force;
		update_cursor();
	}
}

static void window_setup(void)
{
	uint32_t flags = SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI;
	if (is_fullscreen) {
		flags |= SDL_WINDOW_FULLSCREEN_DESKTOP;
	}
	update_cursor();

	tern_val def = {.ptrval = "audio"};
	if (external_sync) {
		sync_src = SYNC_EXTERNAL;
	} else {
		char *sync_src_str = tern_find_path_default(config, "system\0sync_source\0", def, TVAL_PTR).ptrval;
		if (!strcmp(sync_src_str, "audio")) {
			sync_src = SYNC_AUDIO;
		} else if (!strcmp(sync_src_str, "audio_thread")) {
			sync_src = SYNC_AUDIO_THREAD;
		} else {
			sync_src = SYNC_VIDEO;
		}
	}

	if (!num_buffers && (sync_src == SYNC_AUDIO_THREAD || sync_src == SYNC_EXTERNAL)) {
		frame_mutex = SDL_CreateMutex();
		free_buffer_mutex = SDL_CreateMutex();
		frame_ready = SDL_CreateCond();
		buffer_storage = 4;
		frame_buffers = calloc(buffer_storage, sizeof(pixel_t*));
		frame_buffers[0] = texture_buf;
		num_buffers = 1;
	}

	const char *vsync;
	if (sync_src == SYNC_AUDIO) {
		def.ptrval = "off";
		vsync = tern_find_path_default(config, "video\0vsync\0", def, TVAL_PTR).ptrval;
	} else {
		vsync = "on";
	}

	tern_node *video = tern_find_node(config, "video");
	if (video)
	{
		for (int i = 0; i < NUM_VID_STD; i++)
		{
			tern_node *std_settings = tern_find_node(video, vid_std_names[i]);
			if (std_settings) {
				char *val = tern_find_path_default(std_settings, "overscan\0top\0", (tern_val){.ptrval = NULL}, TVAL_PTR).ptrval;
				if (val) {
					overscan_top[i] = atoi(val);
				}
				val = tern_find_path_default(std_settings, "overscan\0bottom\0", (tern_val){.ptrval = NULL}, TVAL_PTR).ptrval;
				if (val) {
					overscan_bot[i] = atoi(val);
				}
				val = tern_find_path_default(std_settings, "overscan\0left\0", (tern_val){.ptrval = NULL}, TVAL_PTR).ptrval;
				if (val) {
					overscan_left[i] = atoi(val);
				}
				val = tern_find_path_default(std_settings, "overscan\0right\0", (tern_val){.ptrval = NULL}, TVAL_PTR).ptrval;
				if (val) {
					overscan_right[i] = atoi(val);
				}
			}
		}
	}
	render_gl = 0;

#ifndef DISABLE_OPENGL
	char *gl_enabled_str = tern_find_path_default(config, "video\0gl\0", def, TVAL_PTR).ptrval;
	uint8_t gl_enabled = strcmp(gl_enabled_str, "off") != 0;
	if (gl_enabled)
	{
		flags |= SDL_WINDOW_OPENGL;
		SDL_GL_SetAttribute(SDL_GL_RED_SIZE, 5);
		SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, 5);
		SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE, 5);
		SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 0);
		SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
#ifdef USE_GLES
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
#endif
	}
#endif
	main_window = SDL_CreateWindow(caption, SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, main_width, main_height, flags);
	if (!main_window) {
		fatal_error("Unable to create SDL window: %s\n", SDL_GetError());
	}
	SDL_GetWindowSize(main_window, &main_width, &main_height);
	debug_message("Window created with size: %d x %d\n", main_width, main_height);
	int orig_width = main_width, orig_height = main_height;
#ifndef DISABLE_OPENGL
	if (gl_enabled)
	{
		main_context = SDL_GL_CreateContext(main_window);
#ifdef USE_GLES
		int major_version;
		if (SDL_GL_GetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, &major_version) == 0 && major_version >= 2) {
#else
		GLenum res = glewInit();
		if (res != GLEW_OK) {
			warning("Initialization of GLEW failed with code %d\n", res);
		}

		if (res == GLEW_OK && GLEW_VERSION_2_0) {
#endif
			render_gl = 1;
			gl_set_vsync(vsync);
			SDL_GL_GetDrawableSize(main_window, &main_width, &main_height);
		} else {
			warning("OpenGL 2.0 is unavailable, falling back to SDL2 renderer\n");
		}
	}
	if (!render_gl) {
#endif
		flags = SDL_RENDERER_ACCELERATED;
		if (!strcmp("on", vsync) || !strcmp("tear", vsync)) {
			flags |= SDL_RENDERER_PRESENTVSYNC;
		}
		main_renderer = SDL_CreateRenderer(main_window, -1, flags);

		if (!main_renderer) {
			fatal_error("unable to create SDL renderer: %s\n", SDL_GetError());
		}
		SDL_GetRendererOutputSize(main_renderer, &main_width, &main_height);
		SDL_RendererInfo rinfo;
		SDL_GetRendererInfo(main_renderer, &rinfo);
		debug_message("SDL2 Render Driver: %s\n", rinfo.name);
		main_clip.x = main_clip.y = 0;
		main_clip.w = main_width;
		main_clip.h = main_height;
#ifndef DISABLE_OPENGL
	}
#endif

	if (main_width != orig_width || main_height != orig_height) {
		debug_message("True window resolution %d x %d\n", main_width, main_height);
	}
	ui_scale_x = (float)main_width / (float)orig_width;
	ui_scale_y = (float)main_height / (float)orig_height;


	update_aspect();
	render_alloc_surfaces();
	def.ptrval = "off";
	scanlines = !strcmp(tern_find_path_default(config, "video\0scanlines\0", def, TVAL_PTR).ptrval, "on");
}

void render_init(int width, int height, char * title, uint8_t fullscreen)
{
#ifdef SDL_HINT_WINDOWS_DPI_SCALING
	//In some ways, the other DPI scaling option for SDL2 on Windows is better for BlastEm's needs,
	//but setting this makes it more consistent with how high DPI support works on other platforms
	SDL_SetHint(SDL_HINT_WINDOWS_DPI_SCALING, "1");
#endif
	if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_JOYSTICK | SDL_INIT_GAMECONTROLLER) < 0) {
		fatal_error("Unable to init SDL: %s\n", SDL_GetError());
	}
	atexit(SDL_Quit);
	if (height <= 0) {
		float aspect = config_aspect() > 0.0f ? config_aspect() : 4.0f/3.0f;
		height = ((float)width / aspect) + 0.5f;
	}
	debug_message("width: %d, height: %d\n", width, height);
	windowed_width = width;
	windowed_height = height;

	SDL_DisplayMode mode;
	//TODO: Explicit multiple monitor support
	SDL_GetCurrentDisplayMode(0, &mode);
#ifdef __EMSCRIPTEN__
	display_hz = 60; //TODO: FIXME
#else
	display_hz = mode.refresh_rate;
#endif

	if (fullscreen) {
		//the SDL2 migration guide suggests setting width and height to 0 when using SDL_WINDOW_FULLSCREEN_DESKTOP
		//but that doesn't seem to work right when using OpenGL, at least on Linux anyway
		width = mode.w;
		height = mode.h;
	}
	main_width = width;
	main_height = height;
	is_fullscreen = fullscreen;

	caption = title;

	window_setup();

	audio_mutex = SDL_CreateMutex();
	audio_ready = SDL_CreateCond();

	init_audio();

	uint32_t db_size;
	char *db_data = read_bundled_file("gamecontrollerdb.txt", &db_size);
	if (db_data) {
		int added = SDL_GameControllerAddMappingsFromRW(SDL_RWFromMem(db_data, db_size), 1);
		free(db_data);
		debug_message("Added %d game controller mappings from gamecontrollerdb.txt\n", added);
	}

	controller_add_mappings();

	SDL_JoystickEventState(SDL_ENABLE);

	render_set_video_standard(VID_NTSC);

	atexit(render_quit);
}

void render_reset_mappings(void)
{
	SDL_QuitSubSystem(SDL_INIT_GAMECONTROLLER);
	SDL_InitSubSystem(SDL_INIT_GAMECONTROLLER);
	uint32_t db_size;
	char *db_data = read_bundled_file("gamecontrollerdb.txt", &db_size);
	if (db_data) {
		int added = SDL_GameControllerAddMappingsFromRW(SDL_RWFromMem(db_data, db_size), 1);
		free(db_data);
		debug_message("Added %d game controller mappings from gamecontrollerdb.txt\n", added);
	}
}
static int in_toggle;

#ifdef __EMSCRIPTEN__
void resume_config_update(void *arg)
{
	uint8_t was_paused = arg != NULL;
	quitting = 0;
	init_audio();
	render_set_video_standard(video_standard);

	drain_events();
	in_toggle = 0;
	if (!was_paused) {
		SDL_PauseAudio(0);
	}
	emscripten_resume_main_loop();
}
#endif //__EMSCRIPTEN__

void render_config_updated(void)
{
	for (int i = 0; i <= FRAMEBUFFER_UI; i++)
	{
		if (sdl_textures[i]) {
			SDL_DestroyTexture(sdl_textures[i]);
			sdl_textures[i] = NULL;
		}
	}
	texture_init = 0;
#ifndef DISABLE_OPENGL
	if (render_gl) {
		if (on_context_destroyed) {
			on_context_destroyed();
		}
		gl_teardown();
		SDL_GL_DeleteContext(main_context);
	} else {
#endif
		SDL_DestroyRenderer(main_renderer);
#ifndef DISABLE_OPENGL
	}
#endif
	in_toggle = 1;
	SDL_DestroyWindow(main_window);
	main_window = NULL;
	drain_events();

	char *config_width = tern_find_path(config, "video\0width\0", TVAL_PTR).ptrval;
	if (config_width) {
		windowed_width = atoi(config_width);
	}
	char *config_height = tern_find_path(config, "video\0height\0", TVAL_PTR).ptrval;
	if (config_height) {
		windowed_height = atoi(config_height);
	} else {
		float aspect = config_aspect() > 0.0f ? config_aspect() : 4.0f/3.0f;
		windowed_height = ((float)windowed_width / aspect) + 0.5f;
	}
	char *config_fullscreen = tern_find_path(config, "video\0fullscreen\0", TVAL_PTR).ptrval;
	is_fullscreen = config_fullscreen && !strcmp("on", config_fullscreen);
	if (is_fullscreen) {
		SDL_DisplayMode mode;
		//TODO: Multiple monitor support
		SDL_GetCurrentDisplayMode(0, &mode);
		main_width = mode.w;
		main_height = mode.h;
	} else {
		main_width = windowed_width;
		main_height = windowed_height;
	}
	if (on_ui_fb_resized) {
		on_ui_fb_resized();
	}
	uint8_t old_sync_src = sync_src;

	window_setup();
	update_aspect();
#ifndef DISABLE_OPENGL
	//need to check render_gl again after window_setup as render option could have changed
	if (render_gl && on_context_created) {
		on_context_created();
	}
#endif

	
	uint8_t was_paused = 1;
	uint8_t do_audio_reinit = sync_src != old_sync_src;
	if (!do_audio_reinit) {
		audio_config ac = get_audio_config();
		do_audio_reinit = ac.rate != current_audio_config.rate || 
			ac.samples != current_audio_config.samples || ac.format != current_audio_config.format;
	}
	if (do_audio_reinit) {
		was_paused = SDL_GetAudioStatus() == SDL_AUDIO_PAUSED;
		render_close_audio();
#ifdef __EMSCRIPTEN__
		emscripten_pause_main_loop();
		emscripten_async_call(resume_config_update, was_paused ? config : NULL, 1000);
#else
		quitting = 0;
		init_audio();
#endif
	}
	render_set_video_standard(video_standard);

	drain_events();
	in_toggle = 0;
	if (!was_paused) {
		SDL_PauseAudio(0);
	}
}

SDL_Window *render_get_window(uint8_t which)
{
	SDL_Window *ret = which < FRAMEBUFFER_USER_START ? main_window : extras[which - FRAMEBUFFER_USER_START].win;
#ifndef DISABLE_OPENGL
	if (render_gl) {
		SDL_GL_MakeCurrent(ret, which < FRAMEBUFFER_USER_START ? main_context : extras[which - FRAMEBUFFER_USER_START].gl_context);
	}
#endif
	return ret;
}

uint32_t render_audio_syncs_per_sec(void)
{
	//sync samples with audio thread approximately every 8 lines when doing sync to video
	return render_is_audio_sync() ? 0 : source_hz * (video_standard == VID_PAL ? 313 : 262) / 8;
}

void render_set_video_standard(vid_std std)
{
	video_standard = std;
	if (render_is_audio_sync()) {
		return;
	}
	source_hz = std == VID_PAL ? 50 : 60;
	uint32_t max_repeat = 0;
	if (abs(source_hz - display_hz) < 2) {
		memset(frame_repeat, 0, sizeof(int)*display_hz);
	} else {
		int inc = display_hz * 100000 / source_hz;
		int accum = 0;
		int dst_frames = 0;
		for (int src_frame = 0; src_frame < source_hz; src_frame++)
		{
			frame_repeat[src_frame] = -1;
			accum += inc;
			while (accum > 100000)
			{
				accum -= 100000;
				frame_repeat[src_frame]++;
				max_repeat = frame_repeat[src_frame] > max_repeat ? frame_repeat[src_frame] : max_repeat;
				dst_frames++;
			}
		}
		if (dst_frames != display_hz) {
			frame_repeat[source_hz-1] += display_hz - dst_frames;
		}
	}
	source_frame = 0;
	source_frame_count = frame_repeat[0];
	max_repeat++;
	min_buffered = (((float)max_repeat * (float)sample_rate/(float)source_hz)/* / (float)buffer_samples*/);// + 0.9999;
	//min_buffered *= buffer_samples;
	debug_message("Min samples buffered before audio start: %d\n", min_buffered);
	max_adjust = BASE_MAX_ADJUST / source_hz;
}

void render_update_caption(char *title)
{
	caption = title;
	free(fps_caption);
	fps_caption = NULL;
}

static char *screenshot_path;
void render_save_screenshot(char *path)
{
	if (screenshot_path) {
		free(screenshot_path);
	}
	screenshot_path = path;
}

#ifndef DISABLE_ZLIB
static apng_state *apng;
static FILE *apng_file;
#endif
uint8_t render_saving_video(void)
{
#ifndef DISABLE_ZLIB
	return apng_file != NULL;
#else
	return 0;
#endif
}

void render_end_video(void)
{
#ifndef DISABLE_ZLIB
	if (apng) {
		puts("Ending recording");
		end_apng(apng_file, apng);
		apng = NULL;
		apng_file = NULL;
	}
#endif
}
void render_save_video(char *path)
{
	render_end_video();
#ifndef DISABLE_ZLIB
	apng_file = fopen(path, "wb");
	if (apng_file) {
		printf("Saving video to %s\n", path);
	} else {
		warning("Failed to open %s for writing\n", path);
	}
#endif
	free(path);
}

#ifdef GL_DEBUG_OUTPUT
void GLAPIENTRY gl_message_callback(GLenum source, GLenum type, GLenum id, GLenum severity, GLsizei length, const GLchar *message, const void *user)
{
	fprintf(stderr, "GL Message: %d, %d, %d - %s\n", source, type, severity, message);
}
#endif

uint8_t render_create_window_tex(char *caption, uint32_t width, uint32_t height, uint32_t tex_width, uint32_t tex_height, window_close_handler close_handler)
{
	uint8_t win_idx = 0xFF;
	for (int i = 0; i < num_extras; i++)
	{
		if (!extras[i].win) {
			win_idx = i;
			break;
		}
	}

	if (win_idx == 0xFF) {
		num_extras++;
		extras = realloc(extras, num_extras * sizeof(*extras));
		win_idx = num_extras - 1;
	}
	memset(&extras[win_idx], 0, sizeof(extra_window));
	uint32_t flags = 0;
#ifndef DISABLE_OPENGL
	if (render_gl) {
		flags |= SDL_WINDOW_OPENGL;
	}
#endif
	int x = SDL_WINDOWPOS_UNDEFINED;
	int y = SDL_WINDOWPOS_UNDEFINED;
	SDL_GetWindowPosition(main_window, &x, &y);
	if (x != SDL_WINDOWPOS_UNDEFINED) {
		x += main_width;
	}
	extras[win_idx].win = SDL_CreateWindow(caption, x, y, width, height, flags);
	if (!extras[win_idx].win) {
		goto fail_window;
	}
	extras[win_idx].width = width;
	extras[win_idx].height = height;
#ifndef DISABLE_OPENGL
	if (render_gl) {
		extras[win_idx].gl_context = SDL_GL_CreateContext(extras[win_idx].win);
		SDL_GL_MakeCurrent(extras[win_idx].win, extras[win_idx].gl_context);
#ifdef GL_DEBUG_OUTPUT
		glEnable(GL_DEBUG_OUTPUT);
		if (glDebugMessageCallback) {
			glDebugMessageCallback(gl_message_callback, NULL);
		}
#endif
		glGenTextures(2, extras[win_idx].gl_texture);
		for (int i = 0; i < 2; i++)
		{
			glBindTexture(GL_TEXTURE_2D, extras[win_idx].gl_texture[i]);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
			if (i) {
				glTexImage2D(GL_TEXTURE_2D, 0, INTERNAL_FORMAT, 1, 1, 0, SRC_FORMAT, SRC_TYPE, extras[win_idx].color);
			} else {
				extras[win_idx].tex_width = extras[win_idx].orig_tex_width = tex_width;
				extras[win_idx].tex_height = extras[win_idx].orig_tex_height = tex_height;
				char *npot_textures = tern_find_path_default(config, "video\0npot_textures\0", (tern_val){.ptrval = "off"}, TVAL_PTR).ptrval;
				if (strcmp(npot_textures, "on")) {
					extras[win_idx].tex_width = nearest_pow2(tex_width);
					extras[win_idx].tex_height = nearest_pow2(tex_height);
				}
				extras[win_idx].texture_buf = calloc(PITCH_PIXEL_T(extras[win_idx].tex_width) * extras[win_idx].tex_height, sizeof(pixel_t));
				glTexImage2D(GL_TEXTURE_2D, 0, INTERNAL_FORMAT, extras[win_idx].tex_width, extras[win_idx].tex_height, 0, SRC_FORMAT, SRC_TYPE, extras[win_idx].texture_buf);
			}
		}
		glGenBuffers(3, extras[win_idx].gl_buffers);
		glBindBuffer(GL_ARRAY_BUFFER, extras[win_idx].gl_buffers[0]);
		glBufferData(GL_ARRAY_BUFFER, sizeof(vertex_data_default), vertex_data_default, GL_STATIC_DRAW);
		glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, extras[win_idx].gl_buffers[1]);
		glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(element_data), element_data, GL_STATIC_DRAW);
		glBindBuffer(GL_ARRAY_BUFFER, extras[win_idx].gl_buffers[2]);
		glBufferData(GL_ARRAY_BUFFER, sizeof(uvs), uvs, GL_STATIC_DRAW);
		extras[win_idx].vshader = load_shader("extra_window.v.glsl", GL_VERTEX_SHADER);
		extras[win_idx].fshader = load_shader("extra_window.f.glsl", GL_FRAGMENT_SHADER);
		extras[win_idx].program = glCreateProgram();
		glAttachShader(program, extras[win_idx].vshader);
		glAttachShader(program, extras[win_idx].fshader);
		glLinkProgram(extras[win_idx].program);
		GLint link_status;
		glGetProgramiv(program, GL_LINK_STATUS, &link_status);
		if (!link_status) {
			fputs("Failed to link shader program\n", stderr);
			//TODO: cleanup
			goto sdl_renderer;
		}
		extras[win_idx].un_texture = glGetUniformLocation(program, "texture");
		extras[win_idx].un_width = glGetUniformLocation(program, "width");
		extras[win_idx].un_height = glGetUniformLocation(program, "height");
		extras[win_idx].at_pos = glGetAttribLocation(program, "pos");
		extras[win_idx].at_uv = glGetAttribLocation(program, "uv");
		extras[win_idx].color[3] = 255;
	} else {
sdl_renderer:
#endif
		extras[win_idx].renderer = SDL_CreateRenderer(extras[win_idx].win, -1, SDL_RENDERER_ACCELERATED);
		if (!extras[win_idx].renderer) {
			goto fail_renderer;
		}
		extras[win_idx].sdl_texture = SDL_CreateTexture(extras[win_idx].renderer, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING, tex_width, tex_height);
		if (!extras[win_idx].sdl_texture) {
			goto fail_texture;
		}
#ifndef DISABLE_OPENGL
	}
#endif
	extras[win_idx].on_close = close_handler;
	return win_idx + FRAMEBUFFER_USER_START;

fail_texture:
	SDL_DestroyRenderer(extras[win_idx].renderer);
fail_renderer:
	SDL_DestroyWindow(extras[win_idx].win);
fail_window:
	return 0;
}

uint8_t render_create_window(char *caption, uint32_t width, uint32_t height, window_close_handler close_handler)
{
	return render_create_window_tex(caption, width, height, width, height, close_handler);
}

#ifndef DISABLE_OPENGL
uint32_t render_get_window_texture(uint8_t which)
{
	return extras[which - FRAMEBUFFER_USER_START].gl_texture[0];
}
#endif

void render_destroy_window(uint8_t which)
{
	uint8_t win_idx = which - FRAMEBUFFER_USER_START;
	if (extras[win_idx].renderer) {
		//Destroying the renderers also frees the textures
		SDL_DestroyRenderer(extras[win_idx].renderer);
		extras[win_idx].renderer = NULL;
		free (extras[win_idx].static_images);
		extras[win_idx].static_images = NULL;
	}
#ifndef DISABLE_OPENGL
	else {
		SDL_GL_MakeCurrent(extras[win_idx].win, extras[win_idx].gl_context);
		glDeleteProgram(extras[win_idx].program);
		glDeleteShader(extras[win_idx].vshader);
		glDeleteShader(extras[win_idx].fshader);
		glDeleteBuffers(3, extras[win_idx].gl_buffers);
		glDeleteTextures(2, extras[win_idx].gl_texture);
		for (uint8_t i = 0; i < extras[win_idx].num_static; i++)
		{
			if (extras[win_idx].gl_static_images[i]) {
				glDeleteTextures(1, extras[win_idx].gl_static_images + i);
			}
		}
		SDL_GL_DeleteContext(extras[win_idx].gl_context);
		free(extras[win_idx].image_vertices);
		extras[win_idx].image_vertices = NULL;
		free(extras[win_idx].gl_static_images);
		extras[win_idx].gl_static_images = NULL;
	}
#endif
	SDL_DestroyWindow(extras[win_idx].win);

	extras[win_idx].win = NULL;
	extras[win_idx].num_static = 0;
}

#ifndef DISABLE_OPENGL
static void extra_draw_quad(extra_window *extra, GLuint texture, float width, float height)
{
	glUseProgram(extra->program);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, texture);
	glUniform1i(extra->un_texture, 0);
	
	glUniform1f(extra->un_width, width);
	glUniform1f(extra->un_height, height);
	
	glVertexAttribPointer(extra->at_pos, 2, GL_FLOAT, GL_FALSE, sizeof(GLfloat[2]), (void *)0);
	glEnableVertexAttribArray(extra->at_pos);
	
	glBindBuffer(GL_ARRAY_BUFFER, extra->gl_buffers[2]);
	glVertexAttribPointer(extra->at_uv, 2, GL_FLOAT, GL_FALSE, sizeof(GLfloat[2]), (void *)0);
	glEnableVertexAttribArray(extra->at_uv);
	
	glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, extra->gl_buffers[1]);
	glDrawElements(GL_TRIANGLE_STRIP, 4, GL_UNSIGNED_SHORT, (void *)0);
	glDisableVertexAttribArray(extra->at_pos);
	glDisableVertexAttribArray(extra->at_uv);
}
#endif

uint8_t render_static_image(uint8_t window, uint8_t *buffer, uint32_t size)
{
	window -= FRAMEBUFFER_USER_START;
	extra_window *extra = extras + window;
	uint32_t width, height;
	uint32_t *pixels = load_png(buffer, size, &width, &height);
	if (!pixels) {
		return 0xFF;
	}
	uint8_t img_index = 0;
	if (!extra->num_static) {
		extra->num_static = 8;
#ifndef DISABLE_OPENGL
		if (render_gl) {
			extra->gl_static_images = calloc(extra->num_static, sizeof(GLuint));
			extra->image_vertices = malloc(sizeof(vertex_data_default));
			memcpy(extra->image_vertices, vertex_data_default, sizeof(vertex_data_default));
			SDL_GL_MakeCurrent(extra->win, extra->gl_context);
			glGenBuffers(1, &extra->image_buffer);
			glBindBuffer(GL_ARRAY_BUFFER, extra->image_buffer);
			glBufferData(GL_ARRAY_BUFFER, sizeof(vertex_data_default), extra->image_vertices, GL_DYNAMIC_DRAW);
		} else 
#endif
		{
			extra->static_images = calloc(extra->num_static, sizeof(SDL_Texture*));
		}
	}
	for (; img_index < extra->num_static; img_index++)
	{
#ifndef DISABLE_OPENGL
		if (render_gl) {
			if (!extra->gl_static_images[img_index]) {
				break;
			}
		} else
#endif
		if (!extra->static_images[img_index]) {
			break;
		}
	}
	if (img_index == extra->num_static) {
		extra->num_static *= 2;
#ifndef DISABLE_OPENGL
		if (render_gl) {
			extra->gl_static_images = realloc(extra->static_images, extra->num_static * sizeof(GLuint));
		} else 
#endif
		{
			extra->static_images = realloc(extra->static_images, extra->num_static * sizeof(SDL_Texture*));
		}
	}
#ifndef DISABLE_OPENGL
	if (render_gl) {
		SDL_GL_MakeCurrent(extra->win, extra->gl_context);
		
		glGenTextures(1, extra->gl_static_images + img_index);
		glBindTexture(GL_TEXTURE_2D, extra->gl_static_images[img_index]);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
		//TODO: maybe make this respect the npot texture setting?
		glTexImage2D(GL_TEXTURE_2D, 0, INTERNAL_FORMAT, width, height, 0, SRC_FORMAT32, GL_UNSIGNED_BYTE, pixels);
	} else
#endif
	{
		extra->static_images[img_index] = SDL_CreateTexture(extra->renderer, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STATIC, width, height);
		SDL_UpdateTexture(extra->static_images[img_index], NULL, pixels, sizeof(pixel_t) * width);
	}
	free(pixels);
	return img_index;
}

#ifndef DISABLE_OPENGL
static void extra_update_verts(extra_window *extra, int x, int y, int width, int height)
{
	memcpy(extra->image_vertices, vertex_data_default, sizeof(vertex_data_default));
	extra->image_vertices[0] = extra->image_vertices[4] = 2.0f * x / (float)extra->width - 1.0f;
	extra->image_vertices[2] = extra->image_vertices[6] = 2.0f * (x + width) / (float)extra->width - 1.0f;
	extra->image_vertices[1] = extra->image_vertices[3] = -2.0f * (y + height) / (float)extra->height + 1.0f;
	extra->image_vertices[5] = extra->image_vertices[7] = -2.0f * y / (float)extra->height + 1.0f;
	
	SDL_GL_MakeCurrent(extra->win, extra->gl_context);
	glBindBuffer(GL_ARRAY_BUFFER, extra->image_buffer);
	glBufferData(GL_ARRAY_BUFFER, sizeof(vertex_data_default), extra->image_vertices, GL_DYNAMIC_DRAW);
}
#endif

void render_draw_image(uint8_t window, uint8_t image, int x, int y, int width, int height)
{
	extra_window *extra = extras + window - FRAMEBUFFER_USER_START;
	if (extra->renderer) {
		SDL_Rect dst = {
			.x = x,
			.y = y,
			.w = width,
			.h = height
		};
		SDL_RenderCopy(extra->renderer, extra->static_images[image], NULL, &dst);
	}
#ifndef DISABLE_OPENGL
	else {
		extra_update_verts(extra, x, y, width, height);
		extra_draw_quad(extra, extra->gl_static_images[image], 1.0f, 1.0f);
	}
#endif
}

void render_clear_window(uint8_t window, uint8_t r, uint8_t g, uint8_t b)
{
	uint8_t win_idx = window - FRAMEBUFFER_USER_START;
	if (extras[win_idx].renderer) {
		SDL_SetRenderDrawColor(extras[win_idx].renderer, r, g, b, 255);
		SDL_RenderClear(extras[win_idx].renderer);
	}
#ifndef DISABLE_OPENGL
	else {
		SDL_GL_MakeCurrent(extras[win_idx].win, extras[win_idx].gl_context);
		glClearColor(r / 255.0f, g / 255.0f, b / 255.0f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	}
#endif
}

void render_fill_rect(uint8_t window, uint8_t r, uint8_t g, uint8_t b, int x, int y, int width, int height)
{
	extra_window *extra = extras + window - FRAMEBUFFER_USER_START;
	if (extra->renderer) {
		SDL_SetRenderDrawColor(extra->renderer, r, g, b, 255);
		SDL_Rect dst = {
			.x = x,
			.y = y,
			.w = width,
			.h = height
		};
		SDL_RenderFillRect(extra->renderer, &dst);
	}
#ifndef DISABLE_OPENGL
	else {
		if (!extra->image_vertices) {
			extra->image_vertices = malloc(sizeof(vertex_data_default));
			SDL_GL_MakeCurrent(extra->win, extra->gl_context);
			glGenBuffers(1, &extra->image_buffer);
		}
		extra_update_verts(extra, x, y, width, height);
		extra->color[0] = b;
		extra->color[1] = g;
		extra->color[2] = r;
		glBindTexture(GL_TEXTURE_2D, extra->gl_texture[1]);
		glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 1, 1, SRC_FORMAT, SRC_TYPE, extra->color);
		extra_draw_quad(extra, extra->gl_texture[1], 1.0f, 1.0f);
	}
#endif
}

void render_window_refresh(uint8_t window)
{
	uint8_t win_idx = window - FRAMEBUFFER_USER_START;
	if (extras[win_idx].renderer) {
		SDL_RenderPresent(extras[win_idx].renderer);
	}
#ifndef DISABLE_OPENGL
	else {
		SDL_GL_SwapWindow(extras[win_idx].win);
	}
#endif
}

pixel_t *locked_pixels;
uint32_t locked_pitch;
pixel_t *render_get_framebuffer(uint8_t which, int *pitch)
{
	if (sync_src == SYNC_AUDIO_THREAD || sync_src == SYNC_EXTERNAL) {
		*pitch = PITCH_BYTES(LINEBUF_SIZE);
		pixel_t *buffer;
		SDL_LockMutex(free_buffer_mutex);
			if (num_buffers) {
				buffer = frame_buffers[--num_buffers];
			} else {
				buffer = calloc(tex_width*(tex_height + 1), sizeof(pixel_t));
			}
		SDL_UnlockMutex(free_buffer_mutex);
		locked_pixels = buffer;
		return buffer;
	}
#ifndef DISABLE_OPENGL
	if (render_gl && which <= FRAMEBUFFER_EVEN) {
		*pitch = PITCH_BYTES(LINEBUF_SIZE);
		return texture_buf;
	} else if (render_gl && which >= FRAMEBUFFER_USER_START) {
		uint8_t win_idx = which - FRAMEBUFFER_USER_START;
		*pitch = PITCH_BYTES(extras[win_idx].orig_tex_width);
		return extras[win_idx].texture_buf;
	} else {
#endif
		if (which == FRAMEBUFFER_UI && !sdl_textures[which]) {
			sdl_textures[which] = SDL_CreateTexture(main_renderer, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING, main_width, main_height);
		}
		SDL_Texture *tex;
		if (which >= FRAMEBUFFER_USER_START) {
			uint8_t win_idx = which - FRAMEBUFFER_USER_START;
			if (win_idx >= num_extras || !extras[win_idx].renderer) {
				warning("Request for invalid framebuffer number %d\n", which);
				return NULL;
			}
			tex = extras[win_idx].sdl_texture;
		} else {
			tex = sdl_textures[which];
		}
		uint8_t *pixels;
		if (SDL_LockTexture(tex, NULL, (void **)&pixels, pitch) < 0) {
			warning("Failed to lock texture: %s\n", SDL_GetError());
			return NULL;
		}
		static uint8_t last;
		if (which <= FRAMEBUFFER_EVEN) {
			locked_pixels = (pixel_t *)pixels;
			if (which == FRAMEBUFFER_EVEN) {
				pixels += *pitch;
			}
			locked_pitch = *pitch;
			if (which != last) {
				*pitch *= 2;
			}
			last = which;
		}
		return (pixel_t *)pixels;
#ifndef DISABLE_OPENGL
	}
#endif
}

static void release_buffer(pixel_t *buffer)
{
	SDL_LockMutex(free_buffer_mutex);
		if (num_buffers == buffer_storage) {
			buffer_storage *= 2;
			frame_buffers = realloc(frame_buffers, sizeof(pixel_t*)*buffer_storage);
		}
		frame_buffers[num_buffers++] = buffer;
	SDL_UnlockMutex(free_buffer_mutex);
}

uint8_t events_processed;
#ifdef __ANDROID__
#define FPS_INTERVAL 10000
#else
#define FPS_INTERVAL 1000
#endif

static uint32_t last_width, last_height;
static uint8_t interlaced, last_field;
static void process_framebuffer(pixel_t *buffer, uint8_t which, int width)
{
	if (sync_src == SYNC_VIDEO && which <= FRAMEBUFFER_EVEN && source_frame_count < 0) {
		source_frame++;
		if (source_frame >= source_hz) {
			source_frame = 0;
		}
		source_frame_count = frame_repeat[source_frame];
		//TODO: Figure out what to do about SDL Render API texture locking
		return;
	}

	uint32_t height = which <= FRAMEBUFFER_EVEN
		? (video_standard == VID_PAL ? 294 : 243) - (overscan_top[video_standard] + overscan_bot[video_standard])
		: 240;
	FILE *screenshot_file = NULL;
	char *ext;
	if (which < FRAMEBUFFER_UI) {
		last_width = width;
		width -= overscan_left[video_standard] + overscan_right[video_standard];
		if (screenshot_path && which == FRAMEBUFFER_ODD) {
			screenshot_file = fopen(screenshot_path, "wb");
			if (screenshot_file) {
#ifndef DISABLE_ZLIB
				ext = path_extension(screenshot_path);
#endif
				debug_message("Saving screenshot to %s\n", screenshot_path);
			} else {
				warning("Failed to open screenshot file %s for writing\n", screenshot_path);
			}
			free(screenshot_path);
			screenshot_path = NULL;
		}
		interlaced = last_field != which;
		buffer += overscan_left[video_standard] + PITCH_PIXEL_T(LINEBUF_SIZE) * overscan_top[video_standard];
	}
#ifndef DISABLE_OPENGL
	if (render_gl && which <= FRAMEBUFFER_EVEN) {
		SDL_GL_MakeCurrent(main_window, main_context);
		glBindTexture(GL_TEXTURE_2D, textures[which]);
		glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, LINEBUF_SIZE, height, SRC_FORMAT, SRC_TYPE, buffer);

		if (screenshot_file) {
			//properly supporting interlaced modes here is non-trivial, so only save the odd field for now
#ifndef DISABLE_ZLIB
			if (!strcasecmp(ext, "png")) {
				free(ext);
				save_png(screenshot_file, buffer, width, height, PITCH_BYTES(LINEBUF_SIZE));
			} else {
				free(ext);
#endif
				save_ppm(screenshot_file, buffer, width, height, PITCH_BYTES(LINEBUF_SIZE));
#ifndef DISABLE_ZLIB
			}
#endif
		}
#ifndef DISABLE_ZLIB
		if (apng_file) {
			if (!apng) {
				//TODO: more precise frame rate
				apng = start_apng(apng_file, width, height, video_standard == VID_PAL ? 50.0 : 60.0);
			}
			save_png24_frame(apng_file, buffer, apng, width, height, PITCH_BYTES(LINEBUF_SIZE));
		}
#endif
	} else if (render_gl && which >= FRAMEBUFFER_USER_START) {
		uint8_t win_idx = which - FRAMEBUFFER_USER_START;
		SDL_GL_MakeCurrent(extras[win_idx].win, extras[win_idx].gl_context);
		glBindTexture(GL_TEXTURE_2D, extras[win_idx].gl_texture[0]);
		glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, extras[win_idx].orig_tex_width, extras[win_idx].orig_tex_height, SRC_FORMAT, SRC_TYPE, buffer);
	} else {
#endif
		uint32_t shot_height = height;
		//TODO: Support SYNC_AUDIO_THREAD/SYNC_EXTERNAL for render API framebuffers
		if (which <= FRAMEBUFFER_EVEN && last_field != which) {
			uint8_t *cur_dst = (uint8_t *)locked_pixels;
			uint8_t *cur_saved = (uint8_t *)texture_buf;
			uint32_t dst_off = which == FRAMEBUFFER_EVEN ? 0 : locked_pitch;
			uint32_t src_off = which == FRAMEBUFFER_EVEN ? locked_pitch : 0;
			for (int i = 0; i < height; ++i)
			{
				//copy saved line from other field
				memcpy(cur_dst + dst_off, cur_saved, locked_pitch);
				//save line from this field to buffer for next frame
				memcpy(cur_saved, cur_dst + src_off, locked_pitch);
				cur_dst += locked_pitch * 2;
				cur_saved += locked_pitch;
			}
			height = 480;
		}
		if (screenshot_file) {
			uint32_t shot_pitch = locked_pitch;
			if (which == FRAMEBUFFER_EVEN) {
				shot_height *= 2;
			} else {
				shot_pitch *= 2;
			}
#ifndef DISABLE_ZLIB
			if (!strcasecmp(ext, "png")) {
				free(ext);
				save_png(screenshot_file, locked_pixels, width, shot_height, shot_pitch);
			} else {
				free(ext);
#endif
				save_ppm(screenshot_file, locked_pixels, width, shot_height, shot_pitch);
#ifndef DISABLE_ZLIB
			}
#endif
		}
		SDL_UnlockTexture(sdl_textures[which]);
#ifndef DISABLE_OPENGL
	}
#endif
	if (which <= FRAMEBUFFER_EVEN) {
		last_height = height;
		render_update_display();
	} else if (which == FRAMEBUFFER_UI) {
		SDL_RenderCopy(main_renderer, sdl_textures[which], NULL, NULL);
		if (need_ui_fb_resize) {
			SDL_DestroyTexture(sdl_textures[which]);
			sdl_textures[which] = NULL;
			if (on_ui_fb_resized) {
				on_ui_fb_resized();
			}
			need_ui_fb_resize = 0;
		}
	} else {
		uint8_t win_idx = which - FRAMEBUFFER_USER_START;
		if (extras[win_idx].renderer) {
			SDL_RenderCopy(extras[win_idx].renderer, extras[win_idx].sdl_texture, NULL, NULL);
			SDL_RenderPresent(extras[win_idx].renderer);
		}
#ifndef DISABLE_OPENGL
		else {
			glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
			glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
			if (extras[win_idx].on_render) {
				extras[win_idx].on_render();
			} else {
				glBindBuffer(GL_ARRAY_BUFFER, extras[win_idx].gl_buffers[0]);
				extra_draw_quad(
					extras + win_idx,
					extras[win_idx].gl_texture[0], 
					(float)extras[win_idx].orig_tex_width / (float)extras[win_idx].tex_width,
					(float)extras[win_idx].orig_tex_height / (float)extras[win_idx].tex_height
				);
			}
			
			SDL_GL_SwapWindow(extras[win_idx].win);
		}
#endif
	}
	if (screenshot_file) {
		fclose(screenshot_file);
	}
	if (which <= FRAMEBUFFER_EVEN) {
		last_field = which;
		static uint32_t frame_counter, start;
		frame_counter++;
		last_frame= SDL_GetTicks();
		if ((last_frame - start) > FPS_INTERVAL) {
			if (start && (last_frame-start)) {
	#ifdef __ANDROID__
				debug_message("%s - %.1f fps", caption, ((float)frame_counter) / (((float)(last_frame-start)) / 1000.0));
	#else
				if (!fps_caption) {
					fps_caption = malloc(strlen(caption) + strlen(" - 100000000.1 fps") + 1);
				}
				sprintf(fps_caption, "%s - %.1f fps", caption, ((float)frame_counter) / (((float)(last_frame-start)) / 1000.0));
				SDL_SetWindowTitle(main_window, fps_caption);
	#endif
			}
			start = last_frame;
			frame_counter = 0;
		}
	}
	if (!render_is_audio_sync()) {
		int32_t local_cur_min, local_min_remaining;
		SDL_LockAudio();
			if (last_buffered > NO_LAST_BUFFERED) {
				average_change *= 0.9f;
				average_change += (cur_min_buffered - last_buffered) * 0.1f;
			}
			local_cur_min = cur_min_buffered;
			local_min_remaining = min_remaining_buffer;
			last_buffered = cur_min_buffered;
		SDL_UnlockAudio();
		float frames_to_problem;
		if (average_change < 0) {
			frames_to_problem = (float)local_cur_min / -average_change;
		} else {
			frames_to_problem = (float)local_min_remaining / average_change;
		}
		float adjust_ratio = 0.0f;
		if (
			frames_to_problem < BUFFER_FRAMES_THRESHOLD
			|| (average_change < 0 && local_cur_min < 3*min_buffered / 4)
			|| (average_change >0 && local_cur_min > 5 * min_buffered / 4)
			|| cur_min_buffered < 0
		) {

			if (cur_min_buffered < 0) {
				adjust_ratio = max_adjust;
				SDL_PauseAudio(1);
				last_buffered = NO_LAST_BUFFERED;
				cur_min_buffered = 0;
			} else {
				adjust_ratio = -1.0 * average_change / ((float)sample_rate / (float)source_hz);
				adjust_ratio /= 2.5 * source_hz;
				if (fabsf(adjust_ratio) > max_adjust) {
					adjust_ratio = adjust_ratio > 0 ? max_adjust : -max_adjust;
				}
			}
		} else if (local_cur_min < min_buffered / 2) {
			adjust_ratio = max_adjust;
		}
		if (adjust_ratio != 0.0f) {
			average_change = 0;
			render_audio_adjust_speed(adjust_ratio);

		}
		while (source_frame_count > 0)
		{
			render_update_display();
			source_frame_count--;
		}
		source_frame++;
		if (source_frame >= source_hz) {
			source_frame = 0;
		}
		source_frame_count = frame_repeat[source_frame];
	}
}

typedef struct {
	pixel_t *buffer;
	int      width;
	uint8_t  which;
} frame;
frame frame_queue[4];
int frame_queue_len, frame_queue_read, frame_queue_write;

void render_framebuffer_updated(uint8_t which, int width)
{
	if (which < FRAMEBUFFER_USER_START && (sync_src == SYNC_AUDIO_THREAD || sync_src == SYNC_EXTERNAL)) {
		SDL_LockMutex(frame_mutex);
			while (frame_queue_len == 4) {
				SDL_CondSignal(frame_ready);
				SDL_UnlockMutex(frame_mutex);
				SDL_Delay(1);
				SDL_LockMutex(frame_mutex);
			}
			for (int cur = frame_queue_read, i = 0; i < frame_queue_len; i++) {
				if (frame_queue[cur].which == which) {
					int last = (frame_queue_write - 1) & 3;
					frame_queue_len--;
					release_buffer(frame_queue[cur].buffer);
					if (last != cur) {
						frame_queue[cur] = frame_queue[last];
					}
					frame_queue_write = last;
					break;
				}
				cur = (cur + 1) & 3;
			}
			frame_queue[frame_queue_write++] = (frame){
				.buffer = locked_pixels,
				.width = width,
				.which = which
			};
			frame_queue_write &= 0x3;
			frame_queue_len++;
			SDL_CondSignal(frame_ready);
		SDL_UnlockMutex(frame_mutex);
#ifdef __ANDROID__
		if (which <= FRAMEBUFFER_EVEN) {
			static uint32_t frame_counter, start;
			frame_counter++;
			uint32_t last_frame= SDL_GetTicks();
			if ((last_frame - start) > FPS_INTERVAL) {
				if (start && (last_frame-start)) {
					debug_message("%s - %.1f fps (emulated)", caption, ((float)frame_counter) / (((float)(last_frame-start)) / 1000.0));
				}
				start = last_frame;
				frame_counter = 0;
			}
		}
#endif
		return;
	}
	//TODO: Maybe fixme for render API
	process_framebuffer(which < FRAMEBUFFER_USER_START ? texture_buf : extras[which - FRAMEBUFFER_USER_START].texture_buf, which, width);
}

void render_video_loop(void)
{
	if (sync_src != SYNC_AUDIO_THREAD && sync_src != SYNC_EXTERNAL) {
		return;
	}
	SDL_PauseAudio(0);
	SDL_LockMutex(frame_mutex);
		for(;;)
		{
			while (!frame_queue_len && audio_active)
			{
				SDL_CondWait(frame_ready, frame_mutex);
			}
			while (frame_queue_len)
			{
				frame f = frame_queue[frame_queue_read++];
				frame_queue_read &= 0x3;
				frame_queue_len--;
				SDL_UnlockMutex(frame_mutex);
				process_framebuffer(f.buffer, f.which, f.width);
				release_buffer(f.buffer);
				SDL_LockMutex(frame_mutex);
			}
			if (!audio_active) {
				break;
			}
		}

	SDL_UnlockMutex(frame_mutex);
}

static ui_render_fun render_ui;
void render_set_ui_render_fun(uint8_t which, ui_render_fun fun)
{
	if (which < FRAMEBUFFER_USER_START) {
		render_ui = fun;
	} else {
		extras[which - FRAMEBUFFER_USER_START].on_render = fun;
	}
}

static ui_render_fun frame_presented;
void render_set_frame_presented_fun(ui_render_fun fun)
{
	frame_presented = fun;
}

void render_update_display()
{
	static uint8_t last_was_paused;
	if (current_system) {
		if (current_system->paused && !last_was_paused) {
			if (!fps_caption) {
				fps_caption = malloc(strlen(caption) + strlen(" - 100000000.1 fps") + 1);
			}
			sprintf(fps_caption, "%s - PAUSED", caption);
			SDL_SetWindowTitle(main_window, fps_caption);
		}
		last_was_paused = current_system->paused;
	}
#ifndef DISABLE_OPENGL
	if (render_gl) {
		SDL_GL_MakeCurrent(main_window, main_context);
		glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);

		glUseProgram(program);
		glActiveTexture(GL_TEXTURE0);
		glBindTexture(GL_TEXTURE_2D, textures[0]);
		glUniform1i(un_textures[0], 0);

		glActiveTexture(GL_TEXTURE1);
		int bot_texture = 2; //black texture
		if (interlaced) {
			bot_texture = 1;
		} else if (!scanlines && un_scanlines == -1) {
			bot_texture = 0;
		}
		glBindTexture(GL_TEXTURE_2D, textures[bot_texture]);
		glUniform1i(un_textures[1], 1);

		glUniform1f(un_width, render_emulated_width());
		glUniform1f(un_height, last_height);
		glUniform2f(un_texsize, tex_width, tex_height);
		if (un_curfield != -1) {
			glUniform1i(un_curfield, last_field);
		}
		if (un_interlaced != -1) {
			glUniform1i(un_interlaced, interlaced);
		}
		if (un_scanlines != -1) {
			glUniform1i(un_scanlines, scanlines);
		}

		glBindBuffer(GL_ARRAY_BUFFER, buffers[0]);
		glVertexAttribPointer(at_pos, 2, GL_FLOAT, GL_FALSE, sizeof(GLfloat[2]), (void *)0);
		glEnableVertexAttribArray(at_pos);

		glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, buffers[1]);
		glDrawElements(GL_TRIANGLE_STRIP, 4, GL_UNSIGNED_SHORT, (void *)0);

		glDisableVertexAttribArray(at_pos);

		if (render_ui) {
			render_ui();
		}

		SDL_GL_SwapWindow(main_window);
	} else {
#endif
		SDL_Rect src_clip = {
			.x = overscan_left[video_standard],
			.y = overscan_top[video_standard],
			.w = render_emulated_width(),
			.h = last_height
		};
		SDL_SetRenderDrawColor(main_renderer, 0, 0, 0, 255);
		SDL_RenderClear(main_renderer);
		SDL_RenderCopy(main_renderer, sdl_textures[FRAMEBUFFER_ODD], &src_clip, &main_clip);
		if (render_ui) {
			render_ui();
		}
		SDL_RenderPresent(main_renderer);
#ifndef DISABLE_OPENGL
	}
#endif
	if (!events_processed) {
		process_events();
	}
	events_processed = 0;
	if (frame_presented) {
		frame_presented();
	}
}

uint32_t render_emulated_width()
{
	return last_width - overscan_left[video_standard] - overscan_right[video_standard];
}

uint32_t render_emulated_height()
{
	return (video_standard == VID_PAL ? 294 : 243) - overscan_top[video_standard] - overscan_bot[video_standard];
}

uint32_t render_overscan_left()
{
	return overscan_left[video_standard];
}

uint32_t render_overscan_top()
{
	return overscan_top[video_standard];
}

uint32_t render_overscan_bot()
{
	return overscan_bot[video_standard];
}

void render_wait_quit(void)
{
	SDL_Event event;
	while(SDL_WaitEvent(&event)) {
		switch (event.type) {
		case SDL_QUIT:
			return;
		}
	}
}

int render_lookup_button(char *name)
{
	static tern_node *button_lookup;
	if (!button_lookup) {
		for (int i = SDL_CONTROLLER_BUTTON_A; i < SDL_CONTROLLER_BUTTON_MAX; i++)
		{
			const char *bname = SDL_GameControllerGetStringForButton(i);
			if (bname) {
				button_lookup = tern_insert_int(button_lookup, bname, i);
			}
		}
		//alternative Playstation-style names
		button_lookup = tern_insert_int(button_lookup, "cross", SDL_CONTROLLER_BUTTON_A);
		button_lookup = tern_insert_int(button_lookup, "circle", SDL_CONTROLLER_BUTTON_B);
		button_lookup = tern_insert_int(button_lookup, "square", SDL_CONTROLLER_BUTTON_X);
		button_lookup = tern_insert_int(button_lookup, "triangle", SDL_CONTROLLER_BUTTON_Y);
		button_lookup = tern_insert_int(button_lookup, "share", SDL_CONTROLLER_BUTTON_BACK);
		button_lookup = tern_insert_int(button_lookup, "select", SDL_CONTROLLER_BUTTON_BACK);
		button_lookup = tern_insert_int(button_lookup, "options", SDL_CONTROLLER_BUTTON_START);
		button_lookup = tern_insert_int(button_lookup, "l1", SDL_CONTROLLER_BUTTON_LEFTSHOULDER);
		button_lookup = tern_insert_int(button_lookup, "r1", SDL_CONTROLLER_BUTTON_RIGHTSHOULDER);
		button_lookup = tern_insert_int(button_lookup, "l3", SDL_CONTROLLER_BUTTON_LEFTSTICK);
		button_lookup = tern_insert_int(button_lookup, "r3", SDL_CONTROLLER_BUTTON_RIGHTSTICK);
	}
	return (int)tern_find_int(button_lookup, name, SDL_CONTROLLER_BUTTON_INVALID);
}

int render_lookup_axis(char *name)
{
	static tern_node *axis_lookup;
	if (!axis_lookup) {
		for (int i = SDL_CONTROLLER_AXIS_LEFTX; i < SDL_CONTROLLER_AXIS_MAX; i++)
		{
			axis_lookup = tern_insert_int(axis_lookup, SDL_GameControllerGetStringForAxis(i), i);
		}
		//alternative Playstation-style names
		axis_lookup = tern_insert_int(axis_lookup, "l2", SDL_CONTROLLER_AXIS_TRIGGERLEFT);
		axis_lookup = tern_insert_int(axis_lookup, "r2", SDL_CONTROLLER_AXIS_TRIGGERRIGHT);
	}
	return (int)tern_find_int(axis_lookup, name, SDL_CONTROLLER_AXIS_INVALID);
}

int32_t render_translate_input_name(int32_t controller, char *name, uint8_t is_axis)
{
	tern_node *button_lookup, *axis_lookup;
	if (controller > MAX_JOYSTICKS || !joysticks[controller]) {
		return RENDER_NOT_PLUGGED_IN;
	}

	if (!SDL_IsGameController(joystick_sdl_index[controller])) {
		return RENDER_NOT_MAPPED;
	}
	SDL_GameController *control = SDL_GameControllerOpen(joystick_sdl_index[controller]);
	if (!control) {
		warning("Failed to open game controller %d: %s\n", controller, SDL_GetError());
		return RENDER_NOT_PLUGGED_IN;
	}

	SDL_GameControllerButtonBind cbind;
	int32_t is_positive = RENDER_AXIS_POS;
	if (is_axis) {

		int sdl_axis = render_lookup_axis(name);
		if (sdl_axis == SDL_CONTROLLER_AXIS_INVALID) {
			SDL_GameControllerClose(control);
			return RENDER_INVALID_NAME;
		}
		cbind = SDL_GameControllerGetBindForAxis(control, sdl_axis);
	} else {
		int sdl_button = render_lookup_button(name);
		if (sdl_button == SDL_CONTROLLER_BUTTON_INVALID) {
			SDL_GameControllerClose(control);
			return RENDER_INVALID_NAME;
		}
		if (sdl_button == SDL_CONTROLLER_BUTTON_DPAD_UP || sdl_button == SDL_CONTROLLER_BUTTON_DPAD_LEFT) {
			//assume these will be negative if they are an axis
			is_positive = 0;
		}
		cbind = SDL_GameControllerGetBindForButton(control, sdl_button);
	}
	SDL_GameControllerClose(control);
	switch (cbind.bindType)
	{
	case SDL_CONTROLLER_BINDTYPE_BUTTON:
		return cbind.value.button;
	case SDL_CONTROLLER_BINDTYPE_AXIS:
		return RENDER_AXIS_BIT | cbind.value.axis | is_positive;
	case SDL_CONTROLLER_BINDTYPE_HAT:
		return RENDER_DPAD_BIT | (cbind.value.hat.hat << 4) | cbind.value.hat.hat_mask;
	}
	return RENDER_NOT_MAPPED;
}

int32_t render_dpad_part(int32_t input)
{
	return input >> 4 & 0xFFFFFF;
}

uint8_t render_direction_part(int32_t input)
{
	return input & 0xF;
}

int32_t render_axis_part(int32_t input)
{
	return input & 0xFFFFFFF;
}

void process_events()
{
	if (events_processed > MAX_EVENT_POLL_PER_FRAME) {
		return;
	}
	drain_events();
	events_processed++;
}

#define TOGGLE_MIN_DELAY 250
void render_toggle_fullscreen()
{
	//protect against event processing causing us to attempt to toggle while still toggling
	if (in_toggle) {
		return;
	}
	in_toggle = 1;

	//toggling too fast seems to cause a deadlock
	static uint32_t last_toggle;
	uint32_t cur = SDL_GetTicks();
	if (last_toggle && cur - last_toggle < TOGGLE_MIN_DELAY) {
		in_toggle = 0;
		return;
	}
	last_toggle = cur;

	drain_events();
	is_fullscreen = !is_fullscreen;
	if (is_fullscreen) {
		SDL_DisplayMode mode;
		//TODO: Multiple monitor support
		SDL_GetCurrentDisplayMode(0, &mode);
		//In theory, the SDL2 docs suggest this is unnecessary
		//but without it the OpenGL context remains the original size
		//This needs to happen before the fullscreen transition to have any effect
		//because SDL does not apply window size changes in fullscreen
		SDL_SetWindowSize(main_window, mode.w, mode.h);
	}
	SDL_SetWindowFullscreen(main_window, is_fullscreen ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
	update_cursor();
	//Since we change the window size on transition to full screen
	//we need to set it back to normal so we can also go back to windowed mode
	//normally you would think that this should only be done when actually transitioning
	//but something is screwy in the guts of SDL (at least on Linux) and setting it each time
	//is the only thing that seems to work reliably
	//when we've just switched to fullscreen mode this should be harmless though
	SDL_SetWindowSize(main_window, windowed_width, windowed_height);
	drain_events();
	in_toggle = 0;
	need_ui_fb_resize = 1;
}

void render_errorbox(char *title, char *message)
{
	SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, title, message, NULL);
}

void render_warnbox(char *title, char *message)
{
	SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_WARNING, title, message, NULL);
}

void render_infobox(char *title, char *message)
{
	SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_INFORMATION, title, message, NULL);
}

uint32_t render_elapsed_ms(void)
{
	return SDL_GetTicks();
}

void render_sleep_ms(uint32_t delay)
{
	return SDL_Delay(delay);
}

uint8_t render_has_gl(void)
{
	return render_gl;
}

uint8_t render_get_active_framebuffer(void)
{
	if (SDL_GetWindowFlags(main_window) & SDL_WINDOW_INPUT_FOCUS) {
		return FRAMEBUFFER_ODD;
	}
	for (int i = 0; i < num_extras; i++)
	{
		if (extras[i].win && (SDL_GetWindowFlags(extras[i].win) & SDL_WINDOW_INPUT_FOCUS)) {
			return FRAMEBUFFER_USER_START + i;
		}
	}
	return 0xFF;
}

uint8_t render_create_thread(render_thread *thread, const char *name, render_thread_fun fun, void *data)
{
	*thread = SDL_CreateThread(fun, name, data);
	return *thread != 0;
}

char *render_read_clipboard(void)
{
	char *tmp = SDL_GetClipboardText();
	char *ret = strdup(tmp);
	SDL_free(tmp);
	return ret;
}
