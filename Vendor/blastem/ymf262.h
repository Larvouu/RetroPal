#ifndef YMF262_H_
#define YMF262_H_

#include "ym_common.h"
#include "render_audio.h"
#include "vgm.h"
#include "oscilloscope.h"

#define OPL3_NUM_CHANNELS 18
#define OPL3_NUM_OPERATORS (2*OPL3_NUM_CHANNELS)
#define OPL3_PARAM_START 0x20
#define OPL3_PARAM_END 0xF6
#define OPL3_PARAM_REGS (OPL3_PARAM_END - OPL3_PARAM_START)

typedef struct {
	audio_source *audio;
	vgm_writer   *vgm;
	oscilloscope *scope;
    uint32_t     clock_inc;
	uint32_t     cycle;
	int32_t      volume_mult;
	int32_t      volume_div;
	ym_operator  operators[OPL3_NUM_OPERATORS];
	ym_channel   channels[OPL3_NUM_CHANNELS];
	uint8_t      part1_regs[OPL3_PARAM_REGS];
	uint8_t      part2_regs[OPL3_PARAM_REGS];
	uint8_t      timer_test[4];
	uint8_t      nts;
	uint8_t      connection_sel;
	uint8_t      opl3_mode;
	uint8_t      part2_test;
	uint8_t      status;
	uint8_t      current_op;
	uint8_t      selected_reg;
	uint8_t      selected_part;
} ymf262_context;

void ymf262_init(ymf262_context *context, uint32_t master_clock, uint32_t clock_div, uint32_t options);
void ymf262_reset(ymf262_context *context);
void ymf262_free(ymf262_context *context);
void ymf262_adjust_master_clock(ymf262_context *context, uint32_t master_clock);
void ymf262_adjust_cycles(ymf262_context *context, uint32_t deduction);
void ymf262_run(ymf262_context *context, uint32_t to_cycle);
void ymf262_address_write_part1(ymf262_context *context, uint8_t address);
void ymf262_address_write_part2(ymf262_context *context, uint8_t address);
void ymf262_data_write(ymf262_context *context, uint8_t value);
void ymf262_vgm_log(ymf262_context *context, uint32_t master_clock, vgm_writer *vgm);
uint8_t ymf262_read_status(ymf262_context *context, uint32_t cycle, uint32_t port);


#endif // YMF262_H_
