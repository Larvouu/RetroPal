#ifndef VGM_H_
#define VGM_H_

#include <stdint.h>
#include <stdio.h>

#pragma pack(push, 1)
typedef struct {
	char     ident[4];
	uint32_t eof_offset;
	uint32_t version;
	uint32_t sn76489_clk;
	uint32_t ym2413_clk;
	uint32_t gd3_offset;
	uint32_t num_samples;
	uint32_t loop_offset;
	uint32_t loop_samples;
	uint32_t rate;
	uint16_t sn76489_fb;
	uint8_t  sn76489_shift;
	uint8_t  sn76489_flags;
	uint32_t ym2612_clk;
	uint32_t ym2151_clk;
	uint32_t data_offset;
	uint32_t sega_pcm_clk;
	uint32_t sega_pcm_reg;
} vgm_header;

typedef struct {
	uint32_t rf5c68_clk;
	uint32_t ym2203_clk;
	uint32_t ym2608_clk;
	uint32_t ym2610_clk;
	uint32_t ym3812_clk;
	uint32_t ym3526_clk;
	uint32_t y8950_clk;
	uint32_t ymf262_clk;
	uint32_t ymf278b_clk;
	uint32_t ymf271_clk;
	uint32_t ymz280b_clk;
	uint32_t rf5c164_clk;
	uint32_t pwm_clk;
	uint32_t ay8910_clk;
	uint8_t  ay8910_type;
	uint8_t  ay8910_flags;
	uint8_t  ym2203_ay_flags;
	uint8_t  ym2608_ay_flags;
	//TODO: additional header extension fields
} vgm_extended_header;

enum {
	CMD_PSG_STEREO = 0x4F,
	CMD_PSG,
	CMD_YM2413,
	CMD_YM2612_0,
	CMD_YM2612_1,
	CMD_YM2151,
	CMD_YM2203,
	CMD_YM2608_0,
	CMD_YM2608_1,
	CMD_YM2610_0,
	CMD_YM2610_1,
	CMD_YM3812,
	CMD_YM3526,
	CMD_Y8950,
	CMD_YMZ280B,
	CMD_YMF262_0,
	CMD_YMF262_1,
	CMD_WAIT = 0x61,
	CMD_WAIT_60,
	CMD_WAIT_50,
	CMD_END = 0x66,
	CMD_DATA,
	CMD_PCM_WRITE,
	CMD_WAIT_SHORT = 0x70,
	CMD_YM2612_DAC = 0x80,
	CMD_DAC_STREAM_SETUP = 0x90,
	CMD_DAC_STREAM_DATA,
	CMD_DAC_STREAM_FREQ,
	CMD_DAC_STREAM_START,
	CMD_DAC_STREAM_STOP,
	CMD_DAC_STREAM_STARTFAST,
	CMD_PCM68_REG = 0xB0,
	CMD_PCM164_REG,
	CMD_PCM68_RAM = 0xC1,
	CMD_PCM164_RAM = 0xC2,
	CMD_DATA_SEEK = 0xE0
};

enum {
	DATA_YM2612_PCM = 0,
	DATA_RF5C68,
	DATA_RF5C164,
	DATA_PWM
};

enum {
	STREAM_CHIP_PSG,
	STREAM_CHIP_YM2413,
	STREAM_CHIP_YM2612,
	STREAM_CHIP_YM2151,
	STREAM_CHIP_RF5C68,
	STREAM_CHIP_YM2203,
	STREAM_CHIP_YM2608,
	STREAM_CHIP_YM2610,
	STREAM_CHIP_YM3812,
	STREAM_CHIP_YM3526,
	STREAM_CHIP_Y8950,
	STREAM_CHIP_YMF262,
	STREAM_CHIP_YMF278B,
	STREAM_CHIP_YMF271,
	STREAM_CHIP_YMZ280B,
	STREAM_CHIP_RF5C164,
	STREAM_CHIP_PWM
};

#pragma pack(pop)

typedef struct data_block data_block;
struct data_block {
	data_block  *next;
	uint8_t     *data;
	uint32_t    size;
	uint8_t     type;
};

typedef struct {
	vgm_header header;
	vgm_extended_header ext;
	FILE       *f;
	uint32_t   master_clock;
	uint32_t   last_cycle;
	uint32_t   extra_delta;
	uint32_t   header_size;
} vgm_writer;

vgm_writer *vgm_write_open(char *filename, uint32_t rate, uint32_t clock, uint32_t cycle);
void vgm_sn76489_init(vgm_writer *writer, uint32_t clock, uint16_t feedback, uint8_t shift_reg_size, uint8_t flags);
void vgm_sn76489_write(vgm_writer *writer, uint32_t cycle, uint8_t value);
void vgm_gg_pan_write(vgm_writer *writer, uint32_t cycle, uint8_t value);
void vgm_ym2612_init(vgm_writer *writer, uint32_t clock);
void vgm_ym2612_part1_write(vgm_writer *writer, uint32_t cycle, uint8_t reg, uint8_t value);
void vgm_ym2612_part2_write(vgm_writer *writer, uint32_t cycle, uint8_t reg, uint8_t value);
void vgm_ymf262_init(vgm_writer *writer, uint32_t clock);
void vgm_ymf262_part1_write(vgm_writer *writer, uint32_t cycle, uint8_t reg, uint8_t value);
void vgm_ymf262_part2_write(vgm_writer *writer, uint32_t cycle, uint8_t reg, uint8_t value);
void vgm_adjust_cycles(vgm_writer *writer, uint32_t deduction);
void vgm_close(vgm_writer *writer);

#endif //VGM_H_
