#ifndef YM_COMMON_H_
#define YM_COMMON_H_
#include <stdint.h>
#include <stdio.h>

#define MAX_ENVELOPE 0xFFC
#define MAX_OPL_ENVELOPE 0xFF8

#define SSG_ENABLE    8
#define SSG_INVERT    4
#define SSG_ALTERNATE 2
#define SSG_HOLD      1

#define SSG_CENTER 0x800

enum {
	PHASE_ATTACK,
	PHASE_DECAY,
	PHASE_SUSTAIN,
	PHASE_RELEASE
};

typedef struct {
	int16_t  *mod_src[2];
	uint32_t phase_counter;
	uint32_t phase_inc;
	uint16_t envelope;
	int16_t  output;
	uint16_t total_level;
	uint16_t sustain_level;
	uint8_t  rates[4];
	uint8_t  key_scaling;
	uint8_t  multiple;
	uint8_t  detune;
	uint8_t  am;
	uint8_t  env_phase;
	uint8_t  ssg;
	uint8_t  inverted;
	uint8_t  phase_overflow;
	uint8_t  wave;
} ym_operator;

typedef struct {
	FILE *   logfile;
	uint16_t fnum;
	int16_t  output;
	int16_t  op1_old;
	int16_t  op2_old;
	uint8_t  block_fnum_latch;
	uint8_t  block;
	uint8_t  keycode;
	uint8_t  algorithm;
	uint8_t  feedback;
	uint8_t  ams;
	uint8_t  pms;
	uint8_t  lr;
	uint8_t  keyon;
	uint8_t  scope_channel;
	uint8_t  phase_overflow;
} ym_channel;

extern int16_t lfo_pm_table[128 * 32 * 8];
extern uint16_t rate_table[64*8];

void ym_init_tables(void);
int16_t ym_sine(uint16_t phase, int16_t mod, uint16_t env);
int16_t ym_opl_wave(uint16_t phase, int16_t mod, uint16_t env, uint8_t waveform);
void start_envelope(ym_operator *op, ym_channel *channel);
void keyon(ym_operator *op, ym_channel *channel);
void keyoff(ym_operator *op);

#endif //YM_COMMON_H_
