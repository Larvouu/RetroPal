#include <math.h>
#include "ym_common.h"

#ifdef __ANDROID__
#define log2(x) (log(x)/log(2))
#endif

//According to Nemesis, real hardware only uses a 256 entry quarter sine table; however,
//memory is cheap so using a half sine table will probably save some cycles
//a full sine table would be nice, but negative numbers don't get along with log2
#define SINE_TABLE_SIZE 512
static uint16_t sine_table[SINE_TABLE_SIZE];
//Similar deal here with the power table for log -> linear conversion
//According to Nemesis, real hardware only uses a 256 entry table for the fractional part
//and uses the whole part as a shift amount.
#define POW_TABLE_SIZE (1 << 13)
static uint16_t pow_table[POW_TABLE_SIZE];

static uint16_t rate_table_base[] = {
	//main portion
	0,1,0,1,0,1,0,1,
	0,1,0,1,1,1,0,1,
	0,1,1,1,0,1,1,1,
	0,1,1,1,1,1,1,1,
	//top end
	1,1,1,1,1,1,1,1,
	1,1,1,2,1,1,1,2,
	1,2,1,2,1,2,1,2,
	1,2,2,2,1,2,2,2,
};

uint16_t rate_table[64*8];

static uint8_t lfo_pm_base[][8] = {
	{0,   0,   0,   0,   0,   0,   0,   0},
	{0,   0,   0,   0,   4,   4,   4,   4},
	{0,   0,   0,   4,   4,   4,   8,   8},
	{0,   0,   4,   4,   8,   8, 0xc, 0xc},
	{0,   0,   4,   8,   8,   8, 0xc,0x10},
	{0,   0,   8, 0xc,0x10,0x10,0x14,0x18},
	{0,   0,0x10,0x18,0x20,0x20,0x28,0x30},
	{0,   0,0x20,0x30,0x40,0x40,0x50,0x60}
};
int16_t lfo_pm_table[128 * 32 * 8];

static uint16_t round_fixed_point(double value, int dec_bits)
{
	return value * (1 << dec_bits) + 0.5;
}

void ym_init_tables(void)
{
	static uint8_t did_tbl_init;
	if (did_tbl_init) {
		return;
	}
	did_tbl_init = 1;
	//populate sine table
	for (int32_t i = 0; i < 512; i++) {
		double sine = sin( ((double)(i*2+1) / SINE_TABLE_SIZE) * M_PI_2 );

		//table stores 4.8 fixed pointed representation of the base 2 log
		sine_table[i] = round_fixed_point(-log2(sine), 8);
	}
	//populate power table
	for (int32_t i = 0; i < POW_TABLE_SIZE; i++) {
		double linear = pow(2, -((double)((i & 0xFF)+1) / 256.0));
		int32_t tmp = round_fixed_point(linear, 11);
		int32_t shift = (i >> 8) - 2;
		if (shift < 0) {
			tmp <<= 0-shift;
		} else {
			tmp >>= shift;
		}
		pow_table[i] =  tmp;
	}
	//populate envelope generator rate table, from small base table
	for (int rate = 0; rate < 64; rate++) {
		for (int cycle = 0; cycle < 8; cycle++) {
			uint16_t value;
			if (rate < 2) {
				value = 0;
			} else if (rate >= 60) {
				value = 8;
			} else if (rate < 8) {
				value = rate_table_base[((rate & 6) == 6 ? 16 : 0) + cycle];
			} else if (rate < 48) {
				value = rate_table_base[(rate & 0x3) * 8 + cycle];
			} else {
				value = rate_table_base[32 + (rate & 0x3) * 8 + cycle] << ((rate - 48) >> 2);
			}
			rate_table[rate * 8 + cycle] = value;
		}
	}
	//populate LFO PM table from small base table
	//seems like there must be a better way to derive this
	for (int freq = 0; freq < 128; freq++) {
		for (int pms = 0; pms < 8; pms++) {
			for (int step = 0; step < 32; step++) {
				int16_t value = 0;
				for (int bit = 0x40, shift = 0; bit > 0; bit >>= 1, shift++) {
					if (freq & bit) {
						value += lfo_pm_base[pms][(step & 0x8) ? 7-step & 7 : step & 7] >> shift;
					}
				}
				if (step & 0x10) {
					value = -value;
				}
				lfo_pm_table[freq * 256 + pms * 32 + step] = value;
			}
		}
	}
}

int16_t ym_sine(uint16_t phase, int16_t mod, uint16_t env)
{
	phase += mod;
	if (env > MAX_ENVELOPE) {
		env = MAX_ENVELOPE;
	}
	int16_t output = pow_table[sine_table[phase & 0x1FF] + env];
	if (phase & 0x200) {
		output = -output;
	}
	return output;
}

int16_t ym_opl_wave(uint16_t phase, int16_t mod, uint16_t env, uint8_t waveform)
{
	if (env > MAX_OPL_ENVELOPE) {
		env = MAX_OPL_ENVELOPE;
	}
	
	int16_t output;
	switch (waveform)
	{
	default:
	case 0:
		output = pow_table[sine_table[phase & 0x1FF] + env];
		if (phase & 0x200) {
			output = -output;
		}
		break;
	case 1:
		if (phase & 0x200) {
			output = 0;
		} else {
			output = pow_table[sine_table[phase & 0x1FF] + env];
		}
		break;
	case 2:
		output = pow_table[sine_table[phase & 0x1FF] + env];
		break;
	case 3:
	if (phase & 0x100) {
			output = 0;
		} else {
			output = pow_table[sine_table[phase & 0xFF] + env];
		}
		break;
	case 4:
		if (phase & 0x200) {
			output = 0;
		} else {
			output = pow_table[sine_table[(phase & 0xFF) << 1] + env];
			if (phase & 0x100) {
				output = -output;
			}
		}
		break;
	case 5:
		if (phase & 0x200) {
			output = 0;
		} else {
			output = pow_table[sine_table[(phase & 0xFF) << 1] + env];
		}
		break;
	case 6:
		output = pow_table[env];
		if (phase & 0x200) {
			output = -output;
		}
		break;
	case 7:
		if (phase & 0x200) {
			output = -pow_table[((~phase) & 0x1FF) << 3 + env];
		} else {
			output = pow_table[(phase & 0x1FF) << 3 + env];
		}
		break;
	}
	return output;
}

void start_envelope(ym_operator *op, ym_channel *channel)
{
	//Deal with "infinite" attack rates
	uint8_t rate = op->rates[PHASE_ATTACK];
	if (rate) {
		uint8_t ks = channel->keycode >> op->key_scaling;;
		rate = rate*2 + ks;
	}
	if (rate >= 62) {
		op->env_phase = PHASE_DECAY;
		op->envelope = 0;
	} else {
		op->env_phase = PHASE_ATTACK;
	}
}

void keyon(ym_operator *op, ym_channel *channel)
{
	start_envelope(op, channel);
	op->phase_counter = 0;
	op->inverted = op->ssg & SSG_INVERT;
}

void keyoff(ym_operator *op)
{
	op->env_phase = PHASE_RELEASE;
	if (op->inverted) {
		//Nemesis says the inversion state doesn't change here, but I don't see how that is observable either way
		op->inverted = 0;
		op->envelope = (SSG_CENTER - op->envelope) & MAX_ENVELOPE;
	}
}
