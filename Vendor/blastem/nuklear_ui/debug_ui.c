#include <limits.h>
#include <string.h>
#include <stdlib.h>

#include "blastem_nuklear.h"
#include "../blastem.h"
#include "../genesis.h"
#include "../sms.h"
#include "../coleco.h"

typedef struct {
	struct nk_context *context;
	uint32_t          tex_width;
	uint32_t          tex_height;
	uint8_t           win_idx;
} debug_window;

static debug_window windows[NUM_DEBUG_TYPES];

static void debug_handle_event(uint8_t which, SDL_Event *event)
{
	for (int i = 0; i < NUM_DEBUG_TYPES; i++)
	{
		if (windows[i].win_idx == which) {
			nk_sdl_handle_event(windows[i].context, event);
			break;
		}
	}
}

#ifndef DISABLE_OPENGL

static void plane_debug_ui(void)
{
	if (!current_system || !current_system->get_vdp) {
		return;
	}
	vdp_context *vdp = current_system->get_vdp(current_system);
	if (!vdp) {
		return;
	}
	struct nk_context *context = windows[DEBUG_PLANE].context;
	nk_input_end(context);
	struct nk_image main_image = nk_image_id((int)render_get_window_texture(windows[DEBUG_PLANE].win_idx));
	if (nk_begin(context, "Plane Debug", nk_rect(0, 0, windows[DEBUG_PLANE].tex_width + 150 + 8, windows[DEBUG_PLANE].tex_height + 8), NK_WINDOW_NO_SCROLLBAR)) {
		nk_layout_space_begin(context, NK_STATIC, windows[DEBUG_PLANE].tex_height, INT_MAX);
		nk_layout_space_push(context, nk_rect(150, 0, windows[DEBUG_PLANE].tex_width, windows[DEBUG_PLANE].tex_height));
		nk_image(context, main_image);
		struct nk_rect bounds = nk_layout_widget_bounds(context);
		bounds.x += 100;
		bounds.w -= 100;
		char buf[64];
		if (nk_input_is_mouse_hovering_rect(&context->input, bounds)) {
			//TODO: display plane position
			int x = context->input.mouse.pos.x - bounds.x;
			int y = context->input.mouse.pos.y - bounds.y;
			switch (vdp->debug_modes[DEBUG_PLANE] & 3)
			{
			case 0:
			case 1:
				y &= 0xFF | (vdp->regs[REG_SCROLL] & 0x30) << 4;
				switch(vdp->regs[REG_SCROLL] & 0x3)
				{
				case 0:
					x &= 0xFF;
					break;
				case 0x1:
					x &= 0x1FF;
					break;
				case 0x2:
					x &= 0xFF;
					break;
				case 0x3:
					x &= 0x3FF;
					break;
				}
				break;
			case 2:
				y &= 0xFF;
				if (vdp->regs[REG_MODE_4] & BIT_H40) {
					x &= 0x1FF;
				} else {
					x &= 0xFF;
				}
				break;
			case 3:
				x >>= 1;
				y >>= 1;
				x -= 128;
				y -= 128;
				break;
			}
			nk_layout_space_push(context, nk_rect(0, windows[DEBUG_PLANE].tex_height - 52, 150, 32));
			snprintf(buf, sizeof(buf), "X: %d", x);
			nk_label(context, buf, NK_TEXT_LEFT);
			nk_layout_space_push(context, nk_rect(0, windows[DEBUG_PLANE].tex_height - 32, 150, 32));
			snprintf(buf, sizeof(buf), "Y: %d", y);
			nk_label(context, buf, NK_TEXT_LEFT);
		}
		static const char* names[] = {
			"Plane A",
			"Plane B",
			"Window",
			"Sprites",
			"32X"
		};
		int num_choices = vdp->s32x_vid ? 5 : 4;
		uint8_t debug_plane = vdp->debug_modes[DEBUG_PLANE];
		if (vdp->s32x_vid) {
			debug_plane %= 5;
		} else {	
			debug_plane &= 3;
		}
		for (int i = 0; i < num_choices; i++)
		{
			nk_layout_space_push(context, nk_rect(0, i * 32, 150, 32));
			int selected = i == debug_plane;
			nk_selectable_label(context, names[i], NK_TEXT_ALIGN_LEFT, &selected);
			if (selected) {
				vdp->debug_modes[DEBUG_PLANE] = debug_plane = i;
			}
		}
		if (debug_plane < 3) {
			nk_layout_space_push(context, nk_rect(0, 5 * 32, 150, 32));
			if (nk_check_label(context, "Screen Border", vdp->debug_flags & DEBUG_FLAG_PLANE_BORDER)) {
				vdp->debug_flags |= DEBUG_FLAG_PLANE_BORDER;
			} else {
				vdp->debug_flags &= ~DEBUG_FLAG_PLANE_BORDER;
			}
		}
		nk_end(context);
	}
	nk_sdl_render(context, NK_ANTI_ALIASING_ON, 512 * 1024, 128 * 1024);
	nk_input_begin(context);
}

void write_cram_internal(vdp_context * context, uint16_t addr, uint16_t value);
static void cram_debug_ui(void)
{
	if (!current_system || !current_system->get_vdp) {
		return;
	}
	vdp_context *vdp = current_system->get_vdp(current_system);
	if (!vdp) {
		return;
	}
	struct nk_context *context = windows[DEBUG_CRAM].context;
	nk_input_end(context);
	char buf[64];
	
	struct nk_image main_image = nk_image_id((int)render_get_window_texture(windows[DEBUG_CRAM].win_idx));
	if (nk_begin(context, "CRAM Debug", nk_rect(0, 0, windows[DEBUG_CRAM].tex_width + 100 + 8, windows[DEBUG_CRAM].tex_height + 8), NK_WINDOW_NO_SCROLLBAR)) {
		nk_layout_space_begin(context, NK_STATIC, windows[DEBUG_CRAM].tex_height, INT_MAX);
		nk_layout_space_push(context, nk_rect(100, 0, windows[DEBUG_CRAM].tex_width, windows[DEBUG_CRAM].tex_height));
		nk_image(context, main_image);
		struct nk_rect bounds = nk_layout_widget_bounds(context);
		bounds.x += 100;
		bounds.w -= 100;
		bounds.h = (vdp->flags2 & FLAG2_REGION_PAL) ? 313 : 262;
		if (nk_input_is_mouse_hovering_rect(&context->input, bounds)) {
			int off_y = context->input.mouse.pos.y - bounds.y;
			int off_x = context->input.mouse.pos.x - bounds.x;
			pixel_t pix = vdp->debug_fbs[DEBUG_CRAM][off_y * vdp->debug_fb_pitch[DEBUG_CRAM] / sizeof(pixel_t) + off_x];
#ifdef USE_GLES
			pixel_t b = pix >> 20 & 0xE, g = pix >> 12 & 0xE, r = pix >> 4 & 0xE;
#else
			pixel_t r = pix >> 20 & 0xE, g = pix >> 12 & 0xE, b = pix >> 4 & 0xE;
#endif
			pix = b << 8 | g << 4 | r;
			snprintf(buf, sizeof(buf), "Line: %d, Index: %d, Value: %03X", off_y- vdp->border_top, off_x >> 3, pix & 0xFFFFFF);
			nk_layout_space_push(context, nk_rect(100, 512 - 32*5, windows[DEBUG_CRAM].tex_width, 32));
			nk_label(context, buf, NK_TEXT_LEFT);
		}
		bounds.y += 512-32*4;
		bounds.h = 32*4;
		if (nk_input_is_mouse_hovering_rect(&context->input, bounds)) {
			int index = ((((int)(context->input.mouse.pos.y - bounds.y)) >> 1) & 0xF0) + (((int)(context->input.mouse.pos.x - bounds.x)) >> 5);
			snprintf(buf, sizeof(buf), "Index: %2d, Value: %03X", index, vdp->cram[index]);
			nk_layout_space_push(context, nk_rect(100, 512 - 32*5, windows[DEBUG_CRAM].tex_width, 32));
			nk_label(context, buf, NK_TEXT_LEFT);
		}
		
		static struct nk_scroll scroll;
		context->style.window.scrollbar_size.y = 0;
		nk_layout_space_push(context, nk_rect(0, 0, 100, windows[DEBUG_CRAM].tex_height));
		if (nk_group_scrolled_begin(context, &scroll, "Entries", 0)) {
			nk_layout_space_begin(context, NK_STATIC, windows[DEBUG_CRAM].tex_height * 4, INT_MAX);
			for (int i = 0; i < 64; i++)
			{
				nk_layout_space_push(context, nk_rect(0, i *32, 25, 32));
				snprintf(buf, sizeof(buf), "%d", i);
				nk_label(context, buf, NK_TEXT_RIGHT);
				nk_layout_space_push(context, nk_rect(30, i *32, 50, 32));
				snprintf(buf, sizeof(buf), "%03X", vdp->cram[i] & 0xEEE);
				nk_edit_string_zero_terminated(context, NK_EDIT_FIELD, buf, sizeof(buf), nk_filter_hex);
				char *end;
				long newv = strtol(buf, &end, 16);
				if (end != buf && newv != vdp->cram[i]) {
					write_cram_internal(vdp, i, newv & 0xEEE);
				}
			}
			nk_layout_space_end(context);
			nk_group_scrolled_end(context);
		}
		
		nk_end(context);
	}
	nk_sdl_render(context, NK_ANTI_ALIASING_ON, 512 * 1024, 128 * 1024);
	
	nk_input_begin(context);
}
#endif

uint8_t debug_create_window(uint8_t debug_type, char *caption, uint32_t width, uint32_t height, window_close_handler close_handler)
{
#ifndef DISABLE_OPENGL
	if (!render_has_gl()) {
#endif
		return render_create_window(caption, width, height, close_handler);
#ifndef DISABLE_OPENGL
	}
	uint32_t win_width = width, win_height = height;
	ui_render_fun render = NULL;
	switch (debug_type)
	{
	case DEBUG_PLANE:
		win_width += 150;
		render = plane_debug_ui;
		break;
	case DEBUG_CRAM:
		win_width += 100;
		render = cram_debug_ui;
		break;
	}
	if (render) {
		//compensate for padding
		win_width += 4 * 2;
		win_height += 4 * 2;
		windows[debug_type].win_idx = render_create_window_tex(caption, win_width, win_height, width, height, close_handler);
		windows[debug_type].tex_width = width;
		windows[debug_type].tex_height = width;
		windows[debug_type].context = shared_nuklear_init(windows[debug_type].win_idx);
		render_set_ui_render_fun(windows[debug_type].win_idx, render);
		render_set_event_handler(windows[debug_type].win_idx, debug_handle_event);
		return windows[debug_type].win_idx;
	} else {
		return render_create_window(caption, width, height, close_handler);
	}
#endif
}
