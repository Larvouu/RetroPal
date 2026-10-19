#ifndef S32X_VIDEO_H_
#define S32X_VIDEO_H_
#include <stdint.h>
#include "pixel.h"

enum {
	S32X_VID_MODE,
	S32X_VID_SHIFT,
	S32X_VID_FILL_LEN,
	S32X_VID_FILL_START,
	S32X_VID_FILL_DATA,
	S32X_VID_FB_CTRL,
	S32X_NUM_VID_REGS
};

#define S32X_VID_BIT_PAL   0x8000
#define S32X_VID_BIT_V240  0x0040
#define S32X_VID_BIT_PRI   0x0080
#define S32X_VID_MODE_MASK 0x0003

#define S32X_VID_BIT_VBLK  0x8000
#define S32X_VID_BIT_HBLK  0x4000
#define S32X_VID_BIT_PEN   0x2000
#define S32X_VID_BIT_FEN   0x0002
#define S32X_VID_BIT_FS    0x0001

enum {
	S32X_VID_MODE_BLANK,
	S32X_VID_MODE_INDEXED,
	S32X_VID_MODE_DIRECT,
	S32X_VID_MODE_RLE
};

typedef struct {
	uint8_t     *front;
	uint8_t     *back;
	uint32_t    cycle;
	uint32_t    fill_remainder;
	uint16_t    vcounter;
	uint16_t    hcounter;
	uint16_t    regs[S32X_NUM_VID_REGS];
	uint16_t    palette[256];
	uint16_t    fill_count;
	uint16_t    hint_count;
	uint16_t    hint_counter;
	//TODO: FIFO
	uint8_t     main_vint_pending;
	uint8_t     sub_vint_pending;
	uint8_t     main_hint_pending;
	uint8_t     sub_hint_pending;
	uint8_t     hen;
	uint8_t     flip_pending;
} s32x_video;

void s32x_video_init(s32x_video *vid, uint8_t pal);
void s32x_video_free(s32x_video *vid);
void s32x_video_run(s32x_video *vid, uint32_t target);
uint8_t s32x_video_composite(s32x_video *vid, pixel_t *output, uint8_t *compositebuf, uint32_t line, uint8_t is_h40);
uint32_t s32x_cycles_to_vblank(s32x_video *video);
uint32_t s32x_cycles_to_hint(s32x_video *video);
uint16_t s32x_video_68k_read(uint32_t address, s32x_video *video);
uint16_t s32x_video_sh2_read(uint32_t address, s32x_video *video);
uint32_t s32x_video_68k_write(uint32_t address, s32x_video *video, uint16_t value);
uint32_t s32x_video_68k_write_b(uint32_t address, s32x_video *video, uint16_t value);
uint32_t s32x_video_sh2_write(uint32_t address, s32x_video *video, uint16_t value);
uint32_t s32x_video_sh2_write_b(uint32_t address, s32x_video *video, uint8_t value);
void s32x_video_fb_write_w(uint32_t address, s32x_video *video, uint16_t value);
void s32x_video_fb_write_b(uint32_t address, s32x_video *video, uint8_t value);
uint16_t s32x_video_fb_read_w(uint32_t address, s32x_video *video);
uint16_t s32x_video_fb_read_b(uint32_t address, s32x_video *video);
void s32x_video_overwrite_write_w(uint32_t address, s32x_video *video, uint16_t value);
void s32x_video_overwrite_write_b(uint32_t address, s32x_video *video, uint8_t value);
void s32x_fb_debug(pixel_t *fb, uint32_t pitch, s32x_video *video);

#endif //S32X_VIDEO_H_
