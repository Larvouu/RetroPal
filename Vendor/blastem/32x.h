#ifndef S32X_H_
#define S32X_H_
#include <stdint.h>
#include "sh2.h"
#include "32x_video.h"
#include "oscilloscope.h"
#include "render_audio.h"

enum {
	S32X_ADAPT_CTRL,
	S32X_INT_CTRL,
	S32X_CART_BANK,
	S32X_DREQ_CTRL,
	S32X_DREQ_SRC_HI,
	S32X_DREQ_SRC_LO,
	S32X_DREQ_DST_HI,
	S32X_DREQ_DST_LO,
	S32X_DREQ_LEN,
	S32X_DREQ_FIFO,
	S32X_VRES_INT_CLR,
	S32X_VINT_CLR,
	S32X_HINT_CLR,
	S32X_SEGA_TV,
	S32X_PWM_INT_CLR,
	S32X_REG_1E,
	S32X_COMM_0,
	S32X_COMM_1,
	S32X_COMM_2,
	S32X_COMM_3,
	S32X_COMM_4,
	S32X_COMM_5,
	S32X_COMM_6,
	S32X_COMM_7,
	S32X_PWM_CTRL,
	S32X_PWM_CYCLE,
	S32X_PWM_WIDTH_L,
	S32X_PWM_WIDTH_R,
	S32X_PWM_WIDTH_M,
	S32X_NUM_REGS,
	S32X_CMD_INT_CLR = S32X_SEGA_TV
};

enum {
	S32X_SH2_INT_CTRL,
	S32X_SH2_STANDBY,
	S32X_SH2_HINT_COUNT,
	S32X_SH2_SUB_INT,
	S32X_NUM_SH2_REGS = S32X_SH2_SUB_INT
};

#define BIT_ADEN_M68K   0x0001
#define BIT_ADCT_FM     0x8000
#define BIT_CART_SH2    0x0100
#define BIT_ADEN_SH2    0x0200
#define BIT_MAIN_INT    0x0001
#define BIT_SUB_INT     0x0002
#define BIT_INTMASK_HEN 0x0080
#define BIT_VERT_INT_EN 0x0008
#define BIT_HORZ_INT_EN 0x0004
#define BIT_CMD_INT_EN  0x0002
#define BIT_PWM_INT_EN  0x0001
#define BIT_SH2_RESET   0x0002
#define BIT_DREQ_FULL   0x0080
#define BIT_DREQ_68S    0x0004
#define BIT_DREQ_RV     0x0001
#define BIT_PWM_RTP     0x0080
#define BIT_PWM_FULL    0x8000
#define BIT_PWM_EMPTY   0x4000
#define S32X_BANK_MASK  0x0003
#define S32X_INTEN_MASK 0x000F
#define S32X_PWM_LRMD   0x000F

typedef struct {
	uint16_t fifo[3];
	uint8_t  write;
	uint8_t  read;
} pwm_fifo;

void pwm_fifo_write(pwm_fifo *fifo, uint16_t *status, uint16_t value);
void pwm_fifo_read(pwm_fifo *fifo, uint16_t *status, uint16_t cycle, int16_t *out);

typedef struct {
	void         *gen;
	sh2_context  *main;
	sh2_context  *sub;
	sh2_context  *main_tmp;
	sh2_context  *sub_tmp;
	uint16_t     *sdram;
	uint16_t     *rom;
	uint16_t     *vector_rom;
	audio_source *pwm;
	oscilloscope *scope;
	s32x_video   video;
	uint32_t     pwm_cycle;
	uint32_t     cur_sh2_target;
	uint16_t     regs[S32X_NUM_REGS];
	uint16_t     sh2_regs[S32X_SH2_SUB_INT+1];
	uint16_t     dreq_fifo[8];
	pwm_fifo     fifo_left;
	pwm_fifo     fifo_right;
	int16_t      pwm_left;
	int16_t      pwm_right;
	int16_t      pwm_left_accum;
	int16_t      pwm_right_accum;
	uint16_t     pwm_counter;
	uint8_t      pwm_decimate;
	uint8_t      pwm_timer;
	uint8_t      pwm_main_int_pending;
	uint8_t      pwm_sub_int_pending;
	uint8_t      scope_left;
	uint8_t      scope_right;
	uint8_t      dreq_fifo_write;
	uint8_t      dreq_fifo_read;
	uint8_t      main_enter_debugger;
	uint8_t      sub_enter_debugger;
	uint8_t      saved_sh2_state;
} s32x;

s32x *alloc_32x(system_media *media, uint8_t pal, uint8_t cd_boot);
void free_32x(s32x *mars);
void s32x_run(s32x *mars, uint32_t target);
void s32x_adjust_cycles(s32x *mars, uint32_t deduction);
void s32x_enable_scope(s32x *mars, oscilloscope *scope, uint32_t main_clock);
void s32x_set_speed(s32x *mars, uint32_t main_clock);
uint16_t s32x_68k_read(uint32_t address, void *vcontext);
void *s32x_68k_write(uint32_t address, void *vcontext, uint16_t value);
uint8_t s32x_68k_read_b(uint32_t address, void *vcontext);
void *s32x_68k_write_b(uint32_t address, void *vcontext, uint8_t value);
void *s32x_write_hint(uint32_t address, void *vcontext, uint16_t value);
void *s32x_write_hint_b(uint32_t address, void *vcontext, uint8_t value);
void *s32x_fb_write_w(uint32_t address, void *vcontext, uint16_t value);
void *s32x_fb_write_b(uint32_t address, void *vcontext, uint8_t value);
uint16_t s32x_fb_read_w(uint32_t address, void *vcontext);
uint8_t s32x_fb_read_b(uint32_t address, void *vcontext);
void *s32x_overwrite_write_w(uint32_t address, void *vcontext, uint16_t value);
void *s32x_overwrite_write_b(uint32_t address, void *vcontext, uint8_t value);


#endif //S32X_H_
