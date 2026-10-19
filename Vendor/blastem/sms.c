#include <string.h>
#include <stdlib.h>
#include <stddef.h>
#include "config.h"
#include "sms.h"
#include "blastem.h"
#include "render.h"
#include "util.h"
#include "debug.h"
#include "saves.h"
#include "bindings.h"
#include "korean_sms_multi.h"

#ifdef NEW_CORE
#define Z80_CYCLE cycles
#define Z80_OPTS opts
#define z80_handle_code_write(...)
#else
#define Z80_CYCLE current_cycle
#define Z80_OPTS options
#endif

enum {
	TAPE_NONE,
	TAPE_STOPPED,
	TAPE_PLAYING,
	TAPE_RECORDING
};

#define PASTE_DELAY (3420 * 22)

static void *memory_io_write(uint32_t location, void *vcontext, uint8_t value)
{
	z80_context *z80 = vcontext;
	sms_context *sms = z80->system;
	if (location & 1) {
		uint8_t fuzzy_ctrl_0 = sms->io.ports[0].control, fuzzy_ctrl_1 = sms->io.ports[1].control;
		io_control_write(sms->io.ports, (~value) << 5 & 0x60, z80->Z80_CYCLE);
		fuzzy_ctrl_0 |= sms->io.ports[0].control;
		io_control_write(sms->io.ports+1, (~value) << 3 & 0x60, z80->Z80_CYCLE);
		fuzzy_ctrl_1 |= sms->io.ports[1].control;
		if (
			(fuzzy_ctrl_0 & 0x40 & (sms->io.ports[0].output ^ (value << 1)) & (value << 1))
			|| (fuzzy_ctrl_0 & 0x40 & (sms->io.ports[1].output ^ (value >> 1)) & (value >> 1))
		) {
			//TH is an output and it went from 0 -> 1
			vdp_run_context(sms->vdp, z80->Z80_CYCLE);
			vdp_latch_hv(sms->vdp);
		}
		io_data_write(sms->io.ports, value << 1, z80->Z80_CYCLE);
		io_data_write(sms->io.ports + 1, value >> 1, z80->Z80_CYCLE);
	} else {
		//TODO: memory control write
	}
	return vcontext;
}

static uint8_t hv_read(uint32_t location, void *vcontext)
{
	z80_context *z80 = vcontext;
	sms_context *sms = z80->system;
	vdp_run_context(sms->vdp, z80->Z80_CYCLE);
	uint16_t hv = vdp_hv_counter_read(sms->vdp);
	if (location & 1) {
		return hv;
	} else {
		return hv >> 8;
	}
}

static void *sms_psg_write(uint32_t location, void *vcontext, uint8_t value)
{
	z80_context *z80 = vcontext;
	sms_context *sms = z80->system;
	psg_run(sms->psg, z80->Z80_CYCLE);
	psg_write(sms->psg, value);
	return vcontext;
}

static void update_interrupts(sms_context *sms)
{
	uint32_t vint = vdp_next_vint(sms->vdp);
	uint32_t hint = vdp_next_hint(sms->vdp);
#ifdef NEW_CORE
	sms->z80->int_cycle = vint < hint ? vint : hint;
	z80_sync_cycle(sms->z80, sms->z80->sync_cycle);
#else
	sms->z80->int_pulse_start = vint < hint ? vint : hint;
#endif
}

static uint8_t vdp_read(uint32_t location, void *vcontext)
{
	z80_context *z80 = vcontext;
	sms_context *sms = z80->system;
	vdp_run_context(sms->vdp, z80->Z80_CYCLE);
	if (location & 1) {
		uint8_t ret = vdp_control_port_read(sms->vdp);
		sms->vdp->flags2 &= ~(FLAG2_VINT_PENDING|FLAG2_HINT_PENDING);
		update_interrupts(sms);
		return ret;
	} else {
		return vdp_data_port_read_pbc(sms->vdp);
	}
}

static void *vdp_write(uint32_t location, void *vcontext, uint8_t value)
{
	z80_context *z80 = vcontext;
	sms_context *sms = z80->system;
	if (location & 1) {
		vdp_run_context_full(sms->vdp, z80->Z80_CYCLE);
		vdp_control_port_write_pbc(sms->vdp, value);
		update_interrupts(sms);
	} else {
		vdp_run_context(sms->vdp, z80->Z80_CYCLE);
		vdp_data_port_write_pbc(sms->vdp, value);
	}
	return vcontext;
}

static uint8_t io_read(uint32_t location, void *vcontext)
{
	z80_context *z80 = vcontext;
	sms_context *sms = z80->system;
	if (location == 0xC0 || location == 0xDC) {
		uint8_t port_a = io_data_read(sms->io.ports, z80->Z80_CYCLE);
		uint8_t port_b = io_data_read(sms->io.ports+1, z80->Z80_CYCLE);
		return (port_a & 0x3F) | (port_b << 6);
	}
	if (location == 0xC1 || location == 0xDD) {
		uint8_t port_a = io_data_read(sms->io.ports, z80->Z80_CYCLE);
		uint8_t port_b = io_data_read(sms->io.ports+1, z80->Z80_CYCLE);
		return (port_a & 0x40) | (port_b >> 2 & 0xF) | (port_b << 1 & 0x80) | 0x10;
	}
	return 0xFF;
}

static void i8255_output_updated(i8255 *ppi, uint32_t cycle, uint32_t port, uint8_t data)
{
	if (port == 2) {
		sms_context *sms = ppi->system;
		sms->kb_mux = data & 0x7;
	}
}

static void cassette_run(sms_context *sms, uint32_t cycle)
{
	if (!sms->cassette) {
		return;
	}
	if (cycle > sms->cassette_cycle) {
		uint64_t diff = cycle - sms->cassette_cycle;
		diff *= sms->cassette_wave.sample_rate;
		diff /= sms->normal_clock;
		if (sms->cassette_state == TAPE_PLAYING) {
			uint64_t bytes_per_sample = sms->cassette_wave.num_channels * sms->cassette_wave.bits_per_sample / 8;
			uint64_t offset = diff * bytes_per_sample + sms->cassette_offset;
			if (offset > UINT32_MAX || offset > sms->cassette->size - bytes_per_sample) {
				sms->cassette_offset = sms->cassette->size - bytes_per_sample;
			} else {
				sms->cassette_offset = offset;
			}
			static uint32_t last_displayed_seconds;
			uint32_t seconds = (sms->cassette_offset - (sms->cassette_wave.format_header.size + offsetof(wave_header, audio_format))) / (bytes_per_sample * sms->cassette_wave.sample_rate);
			if (seconds != last_displayed_seconds) {
				last_displayed_seconds = seconds;
				printf("Cassette: %02d:%02d\n", seconds / 60, seconds % 60);
			}
		}
		diff *= sms->normal_clock;
		diff /= sms->cassette_wave.sample_rate;
		sms->cassette_cycle += diff;
	}
}

static uint8_t cassette_read(sms_context *sms, uint32_t cycle)
{
	cassette_run(sms, cycle);
	if (sms->cassette_state != TAPE_PLAYING) {
		return 0;
	}
	int64_t sample = 0;
	for (uint16_t i = 0; i < sms->cassette_wave.num_channels; i++)
	{
		if (sms->cassette_wave.audio_format == 3) {
			if (sms->cassette_wave.bits_per_sample == 64) {
				sample += 32767.0 * ((double *)(((char *)sms->cassette->buffer) + sms->cassette_offset))[i];
			} else if (sms->cassette_wave.bits_per_sample == 32) {
				sample += 32767.0f * ((float *)(((char *)sms->cassette->buffer) + sms->cassette_offset))[i];
			}
		} else if (sms->cassette_wave.audio_format == 1) {
			if (sms->cassette_wave.bits_per_sample == 32) {
				sample += ((int32_t *)(((char *)sms->cassette->buffer) + sms->cassette_offset))[i];
			} else if (sms->cassette_wave.bits_per_sample == 16) {
				sample += ((int16_t *)(((char *)sms->cassette->buffer) + sms->cassette_offset))[i];
			} else if (sms->cassette_wave.bits_per_sample == 8) {
				sample += ((uint8_t *)sms->cassette->buffer)[sms->cassette_offset + i] - 0x80;
			}
		}
	}
	uint32_t bytes_per_sample = sms->cassette_wave.num_channels * sms->cassette_wave.bits_per_sample / 8;
	if (sms->cassette_offset == sms->cassette->size - bytes_per_sample) {
		sms->cassette_state = TAPE_STOPPED;
		puts("Cassette reached end of file, playback stoped");
	}
	return sample > 0 ? 0x80 : 0;
}

static void cassette_action(system_header *header, uint8_t action)
{
	sms_context *sms = (sms_context*)header;
	if (!sms->cassette) {
		return;
	}
	cassette_run(sms, sms->z80->Z80_CYCLE);
	switch(action)
	{
	case CASSETTE_PLAY:
		sms->cassette_state = TAPE_PLAYING;
		puts("Cassette playback started");
		break;
	case CASSETTE_RECORD:
		break;
	case CASSETTE_STOP:
		sms->cassette_state = TAPE_STOPPED;
		puts("Cassette playback stoped");
		break;
	case CASSETTE_REWIND:
		sms->cassette_offset = sms->cassette_wave.format_header.size + offsetof(wave_header, audio_format);
		break;
	}
}

typedef struct {
	uint8_t main;
	uint8_t mod;
	uint8_t before;
	uint8_t after;
} cp_keys;

#define SIMPLE(cp, sc) case cp: return (cp_keys){sc}
#define MAYBE_SHIFT(cp, sc) case cp: return (cp_keys){sc, shift}
#define SHIFTED(cp, sc) case cp: return (cp_keys){sc, 0x12}
#define ACCENTED(cp, sc) case cp: return (cp_keys){sc, 0x81}
#define GRAPHIC(cp, sc) case cp: return (cp_keys){sc, .before=0x11, .after=0x11}
#define SHIFTED_GRAPHIC(cp, sc) case cp: return (cp_keys){sc, 0x12, .before=0x11, .after=0x11}
#define KANA(cp, sc) case cp: return (cp_keys){sc, .before=0x81, .after=0x81}
#define SHIFTED_KANA(cp, sc) case cp: return (cp_keys){sc, 0x12, .before=0x81, .after=0x81}
#define DAKUTEN_KANA(cp, sc) case cp: return (cp_keys){sc, .before=0x81, .after=0x85}
#define MARU_KANA(cp, sc) case cp: return (cp_keys){sc, .before=0x81, .after=0x54}

static cp_keys cp_to_keys(int cp)
{
	uint8_t shift = 0;
	if (cp >= 'a' && cp <= 'z') {
		shift = 0x12;
		cp -= 'a' - 'A';
	} else if (cp >= '!' && cp <= ')') {
		shift = 0x12;
		cp += '1' - '!';
	} else if (cp >= 0xE0 && cp <= 0xFC && cp != 0xF7) {
		//accented latin letters only have a single case (Latin-1 block)
		cp -= 0xE0 - 0xC0;
	} else if (cp >= 0x100 && cp <= 0x16D && (cp & 1)) {
		//accented latin letters only have a single case (Latin Extended-A block)
		cp &= ~1;
	} else if (cp >= 0x1CD && cp <= 0x1D4 && !(cp & 1)) {
		cp--;
	}
	switch (cp)
	{
	SIMPLE('0', 0x45);
	MAYBE_SHIFT('1', 0x16);
	MAYBE_SHIFT('2', 0x1E);
	MAYBE_SHIFT('3', 0x26);
	MAYBE_SHIFT('4', 0x25);
	MAYBE_SHIFT('5', 0x2E);
	MAYBE_SHIFT('6', 0x36);
	MAYBE_SHIFT('7', 0x3D);
	MAYBE_SHIFT('8', 0x3E);
	MAYBE_SHIFT('9', 0x46);
	MAYBE_SHIFT('A', 0x1C);
	MAYBE_SHIFT('B', 0x32);
	MAYBE_SHIFT('C', 0x21);
	MAYBE_SHIFT('D', 0x23);
	MAYBE_SHIFT('E', 0x24);
	MAYBE_SHIFT('F', 0x2B);
	MAYBE_SHIFT('G', 0x34);
	MAYBE_SHIFT('H', 0x33);
	MAYBE_SHIFT('I', 0x43);
	MAYBE_SHIFT('J', 0x3B);
	MAYBE_SHIFT('K', 0x42);
	MAYBE_SHIFT('L', 0x4B);
	MAYBE_SHIFT('M', 0x3A);
	MAYBE_SHIFT('N', 0x31);
	MAYBE_SHIFT('O', 0x44);
	MAYBE_SHIFT('P', 0x4D);
	MAYBE_SHIFT('Q', 0x15);
	MAYBE_SHIFT('R', 0x2D);
	MAYBE_SHIFT('S', 0x1B);
	MAYBE_SHIFT('T', 0x2C);
	MAYBE_SHIFT('U', 0x3C);
	MAYBE_SHIFT('V', 0x2A);
	MAYBE_SHIFT('W', 0x1D);
	MAYBE_SHIFT('X', 0x22);
	MAYBE_SHIFT('Y', 0x35);
	MAYBE_SHIFT('Z', 0x1A);
	SIMPLE('-', 0x4E);
	SHIFTED('=', 0x4E);
	SIMPLE(';', 0x4C);
	SHIFTED('+', 0x4C);
	SIMPLE(':', 0x52);
	SHIFTED('*', 0x52);
	SIMPLE(',', 0x41);
	SHIFTED('<', 0x41);
	SIMPLE('.', 0x49);
	SHIFTED('>', 0x49);
	SIMPLE('/', 0x4A);
	SHIFTED('?', 0x4A);
	SIMPLE('^', 0x55);
	SHIFTED('~', 0x55);
	SIMPLE('[', 0x54);
	SHIFTED('{', 0x54);
	SIMPLE(']', 0x5B);
	SHIFTED('}', 0x5B);
	SIMPLE('@', 0x85);
	SHIFTED('`', 0x85);
	SIMPLE('\n', 0x5A);
	SIMPLE(' ', 0x29);
	SIMPLE(0xA5, 0x5D);//¥
	case 0xA6: //¦ (broken bar)
	SHIFTED('|', 0x5D);//|
	//Accented latin letters will only work right with export BASIC
	ACCENTED(0xA1, 0x32);//¡
	ACCENTED(0xA3, 0x5D);//£
	ACCENTED(0xBF, 0x2A);//¿
	ACCENTED(0xC0, 0x1D);//À
	ACCENTED(0xC1, 0x15);//Á
	ACCENTED(0xC2, 0x16);//Â
	ACCENTED(0xC3, 0x23);//Ã
	ACCENTED(0xC4, 0x1C);//Ä
	ACCENTED(0xC5, 0x1B);//Å
	ACCENTED(0xC7, 0x21);//Ç
	case 0xC6: return (cp_keys){0x31, 0x81, .after=0x24};//Æ
	ACCENTED(0xC8, 0x2D);//È
	ACCENTED(0xC9, 0x24);//É
	ACCENTED(0xCA, 0x26);//Ê
	ACCENTED(0xCB, 0x2E);//Ë
	ACCENTED(0xCC, 0x44);//Ì
	ACCENTED(0xCD, 0x4B);//Í
	ACCENTED(0xCE, 0x49);//Î
	ACCENTED(0xCF, 0x4C);//Ï
	ACCENTED(0xD1, 0x2C);//Ñ
	ACCENTED(0xD2, 0x85);//Ò
	ACCENTED(0xD3, 0x4D);//Ó
	ACCENTED(0xD4, 0x45);//Ô
	ACCENTED(0xD5, 0x0E);//Õ
	ACCENTED(0xD6, 0x52);//Ö
	//character in font doesn't really look like a phi to me
	//but Wikipedia lists it as such and it's between other Greek chars
	case 0x3A6: //Φ
	ACCENTED(0xD8, 0x54);//Ø
	ACCENTED(0xD9, 0x43);//Ù
	ACCENTED(0xDA, 0x3C);//Ú
	ACCENTED(0xDB, 0x3D);//Û
	ACCENTED(0xDC, 0x42);//Ü
	GRAPHIC(0xF7, 0x0E);//÷
	//Latin Extended-A
	ACCENTED(0x100, 0x2B);//Ā
	case 0x1CD: //Ǎ
	ACCENTED(0x102, 0x1E);//Ă
	ACCENTED(0x112, 0x36);//Ē
	case 0x11A: //Ě
	ACCENTED(0x114, 0x25);//Ĕ
	ACCENTED(0x12A, 0x4A);//Ī
	case 0x1CF: //Ǐ
	ACCENTED(0x12C, 0x46);//Ĭ
	case 0x1D1: //Ǒ
	ACCENTED(0x14E, 0x4E);//Ŏ
	ACCENTED(0x16A, 0x41);//Ū
	case 0x1D3: //Ǔ
	ACCENTED(0x16C, 0x3E);//Ŭ
	//Greek and Coptic
	ACCENTED(0x3A3, 0x5B);//Σ
	ACCENTED(0x3A9, 0x3A);//Ω
	ACCENTED(0x3B1, 0x34);//α
	ACCENTED(0x3B2, 0x33);//β
	ACCENTED(0x3B8, 0x3B);//θ
	ACCENTED(0x3BB, 0x22);//λ
	case 0xB5://µ
	ACCENTED(0x3BC, 0x1A);//μ
	SHIFTED(0x3C0, 0x0E);//π
	//Arrows
	GRAPHIC(0x2190, 0x46);//←
	GRAPHIC(0x2191, 0x3E);//↑
	//Box drawing
	GRAPHIC(0x2500, 0x1E);//─
	GRAPHIC(0x2501, 0x34);//━
	GRAPHIC(0x2502, 0x26);//│
	GRAPHIC(0x2503, 0x2C);//┃
	GRAPHIC(0x250C, 0x15);//┌
	GRAPHIC(0x2510, 0x1D);//┐
	GRAPHIC(0x2514, 0x1C);//└
	GRAPHIC(0x2518, 0x1B);//┘
	SHIFTED_GRAPHIC(0x251C, 0x15);//├
	SHIFTED_GRAPHIC(0x2524, 0x1B);//┤
	SHIFTED_GRAPHIC(0x252C, 0x1D);//┬
	SHIFTED_GRAPHIC(0x2534, 0x1C);//┴
	SHIFTED_GRAPHIC(0x256D, 0x24);//╭
	SHIFTED_GRAPHIC(0x256E, 0x2D);//╮
	SHIFTED_GRAPHIC(0x256F, 0x2B);//╯
	SHIFTED_GRAPHIC(0x2570, 0x23);//╰
	GRAPHIC(0x253C, 0x16);//┼
	GRAPHIC(0x2571, 0x4E);//╱
	GRAPHIC(0x2572, 0x5D);//╲
	GRAPHIC(0x2573, 0x55);//╳
	//Block Elements
	SHIFTED_GRAPHIC(0x2580, 0x32);//▀ upper half
	SHIFTED_GRAPHIC(0x2581, 0x1A);//▁ lower 1/8th
	SHIFTED_GRAPHIC(0x2582, 0x22);//▂ lower 1/4th
	SHIFTED_GRAPHIC(0x2584, 0x21);//▄ lower half
	GRAPHIC(0x2588, 0x2A);//█ full block
	GRAPHIC(0x258C, 0x32);//▌ left half
	GRAPHIC(0x258D, 0x31);//▍ left 3/8ths (Sega character is 1/3rd)
	GRAPHIC(0x258F, 0x3A);//▏ left 1/8th (Sega character is 1/6th)
	GRAPHIC(0x2590, 0x21);//▐ right half
	SHIFTED_GRAPHIC(0x2592, 0x2A);//▒
	SHIFTED_GRAPHIC(0x2594, 0x3A);//▔ upper 1/8th
	GRAPHIC(0x2595, 0x1A);//▕ right 1/8th (Sega character is 1/6th)
	GRAPHIC(0x259E, 0x33);//▞
	//Geometric Shapes
	SHIFTED_GRAPHIC(0x25CB, 0x3C);//○
	SHIFTED_GRAPHIC(0x25CF, 0x3B);//●
	GRAPHIC(0x25E2, 0x24);//◢
	GRAPHIC(0x25E3, 0x2D);//◣
	GRAPHIC(0x25E4, 0x2B);//◤
	GRAPHIC(0x25E5, 0x23);//◥
	SHIFTED_GRAPHIC(0x25DC, 0x24);//◜
	SHIFTED_GRAPHIC(0x25DD, 0x2D);//◝
	SHIFTED_GRAPHIC(0x25DE, 0x2B);//◞
	SHIFTED_GRAPHIC(0x25DF, 0x23);//◟
	//Miscellaneous Symbols
	GRAPHIC(0x263B, 0x3B);//☻
	GRAPHIC(0x2660, 0x25);//♠
	GRAPHIC(0x2663, 0x3D);//♣
	GRAPHIC(0x2665, 0x2E);//♥
	GRAPHIC(0x2666, 0x36);//♦
	//CJK Punctuation
	SHIFTED_KANA(0x3002, 0x49);//。
	SHIFTED_KANA(0x300C, 0x54);//「
	SHIFTED_KANA(0x300D, 0x5B);//」
	//Hiragana (for diacritics shared with Katakana)
	case 0xFF9E://ﾞ (half-width)
	case 0x3099:// (combining)
	KANA(0x309B, 0x85);//゛
	case 0xFF9F://ﾟ (half-width)
	case 0x309A:// (combining)
	KANA(0x309C, 0x54);//゜
	//Katakana
	SHIFTED(0x30A0, 0x4E);//Katakana double hyphen, translate to =
	case 0x30A1://ァ
	KANA(0x30A2, 0x26);//ア
	case 0x30A3://ィ
	KANA(0x30A4, 0x24);//イ
	case 0x30A5://ゥ
	KANA(0x30A6, 0x25);//ウ
	case 0x30A7://ェ
	KANA(0x30A8, 0x2E);//エ
	case 0x30A9://ォ
	KANA(0x30AA, 0x36);//オ
	case 0x30F5://ヵ
	KANA(0x30AB, 0x2C);//カ
	DAKUTEN_KANA(0x30AC, 0x2C);//ガ
	KANA(0x30AD, 0x34);//キ
	DAKUTEN_KANA(0x30AE, 0x34);//ギ
	KANA(0x30AF, 0x33);//ク
	DAKUTEN_KANA(0x30B0, 0x33);//グ
	case 0x30F6://ヶ
	KANA(0x30B1, 0x52);//ケ
	DAKUTEN_KANA(0x30B2, 0x52);//ゲ
	KANA(0x30B3, 0x32);//コ
	DAKUTEN_KANA(0x30B4, 0x32);//ゴ
	KANA(0x30B5, 0x22);//サ
	DAKUTEN_KANA(0x30B6, 0x22);//ザ
	KANA(0x30B7, 0x23);//シ
	DAKUTEN_KANA(0x30B8, 0x23);//ジ
	KANA(0x30B9, 0x2D);//ス
	DAKUTEN_KANA(0x30BA, 0x2D);//ズ
	KANA(0x30BB, 0x4D);//セ
	DAKUTEN_KANA(0x30BC, 0x4D);//ゼ
	KANA(0x30BD, 0x21);//ソ
	DAKUTEN_KANA(0x30BE, 0x21);//ゾ
	KANA(0x30BF, 0x15);//タ
	DAKUTEN_KANA(0x30C0, 0x15);//ダ
	KANA(0x30C1, 0x1C);//チ
	DAKUTEN_KANA(0x30C2, 0x1C);//ヂ
	case 0x30C3://ッ
	KANA(0x30C4, 0x1A);//ツ
	DAKUTEN_KANA(0x30C5, 0x1A);//ヅ
	KANA(0x30C6, 0x1D);//テ
	DAKUTEN_KANA(0x30C7, 0x1D);//デ
	KANA(0x30C8, 0x1B);//ト
	DAKUTEN_KANA(0x30C9, 0x1B);//ド
	KANA(0x30CA, 0x3C);//ナ
	KANA(0x30CB, 0x43);//ニ
	KANA(0x30CC, 0x16);//ヌ
	KANA(0x30CD, 0x41);//ネ
	KANA(0x30CE, 0x42);//ノ
	KANA(0x30CF, 0x2B);//ハ
	DAKUTEN_KANA(0x30D0, 0x2B);//バ
	MARU_KANA(0x30D1, 0x2B);//パ
	KANA(0x30D2, 0x2A);//ヒ
	DAKUTEN_KANA(0x30D3, 0x2A);//ビ
	MARU_KANA(0x30D4, 0x2A);//ピ
	KANA(0x30D5, 0x1E);//フ
	DAKUTEN_KANA(0x30D6, 0x1E);//ブ
	MARU_KANA(0x30D7, 0x1E);//プ
	KANA(0x30D8, 0x55);//ヘ
	DAKUTEN_KANA(0x30D9,0x55);//ベ
	MARU_KANA(0x30DA, 0x55);//ペ
	KANA(0x30DB, 0x4E);//ホ
	DAKUTEN_KANA(0x30DC,0x4E);//ボ
	MARU_KANA(0x30DD, 0x4E);//ポ
	KANA(0x30DE, 0x3B);//マ
	KANA(0x30DF, 0x31);//ミ
	KANA(0x30E0, 0x5B);//ム
	KANA(0x30E1, 0x4A);//メ
	KANA(0x30E2, 0x3A);//モ
	case 0x30E3://ャ
	KANA(0x30E4, 0x3D);//ヤ
	case 0x30E5://ュ
	KANA(0x30E6, 0x3E);//ユ
	case 0x30E7://ョ
	KANA(0x30E8, 0x46);//ヨ
	KANA(0x30E9, 0x44);//ラ
	KANA(0x30EA, 0x4B);//リ
	KANA(0x30EB, 0x49);//ル
	KANA(0x30EC, 0x4C);//レ
	KANA(0x30ED, 0x0E);//ロ
	case 0x30EE://ヮ
	KANA(0x30EF, 0x45);//ワ
	SHIFTED_KANA(0x30F2, 0x45);//ヲ
	KANA(0x30F3, 0x35);//ン
	SHIFTED_KANA(0x30FB, 0x4A);//・
	KANA(0x30FC, 0x5D);//ー
	//CJK Unified Ideographs
	GRAPHIC(0x571F, 0x85);//土
	GRAPHIC(0x5E74, 0x4B);//年
	GRAPHIC(0x65E5, 0x52);//日
	GRAPHIC(0x6708, 0x4C);//月
	GRAPHIC(0x6728, 0x44);//木
	GRAPHIC(0x6C34, 0x43);//水
	GRAPHIC(0x706B, 0x3C);//火
	GRAPHIC(0x91D1, 0x4D);//金
	//Miscellaneous Symbos and Pictographs
	GRAPHIC(0x1F47E, 0x42);//👾
	//Transport and Map Symbols
	SHIFTED_GRAPHIC(0x1F697, 0x33);//🚗
	SHIFTED_GRAPHIC(0x1F698, 0x35);//🚘
	//Symbols for legacy computing
	SHIFTED_GRAPHIC(0x1FB82, 0x31);//🮂 upper 1/4th
	GRAPHIC(0x1FB88, 0x22);//🮈 right 3/8ths (Sega character is 1/3rd)
	case 0x1FB8C: //🮌 left half medium shade
	SHIFTED_GRAPHIC(0x1FB8D, 0x2C);//🮍 right half medium shade, Sega char is sort of in the middle
	case 0x1FB8E://🮎 upper half medium shade
	SHIFTED_GRAPHIC(0x1FB8F, 0x34);//🮏 lower half medium shade, Sega char is sort of in the middle
	GRAPHIC(0x1FBC5, 0x35);//🯅 stick figure
	GRAPHIC(0x1FBCF, 0x31);//🯏 left 1/3rd
	default: return (cp_keys){0};
	}
}

static void advance_paste_buffer(sms_context *sms, const char *paste)
{
	if (!*paste) {
		free(sms->header.paste_buffer);
		sms->header.paste_buffer = NULL;
	} else {
		sms->header.paste_cur_char = paste - sms->header.paste_buffer;
	}
}

enum {
	PASTE_BEFORE,
	PASTE_MAIN,
	PASTE_AFTER,
	PASTE_BEFORE_UP,
	PASTE_MAIN_UP,
	PASTE_AFTER_UP,
	PASTE_TOGGLE_UP
};


static uint8_t paste_internal(sms_context *sms, uint8_t prev_key)
{
	const char *paste = sms->header.paste_buffer + sms->header.paste_cur_char;
	int cp = utf8_codepoint(&paste);
	cp_keys keys = {0};
	if (cp == 'N' || cp == 'n') {
		const char *tmp = paste;
		int next = utf8_codepoint(&tmp);
		if (next == 0x302) {
			keys = (cp_keys){0x35, 0x81};//N̂  (N with circumflex above)
			paste = tmp;
		}
	}
	if (!keys.main) {
		keys = cp_to_keys(cp);
	}
	if (!keys.main) {
		advance_paste_buffer(sms, paste);
		return 0;
	}
	switch (sms->paste_state)
	{
	default:
	case PASTE_BEFORE:
		if (sms->paste_toggle != keys.before) {
			if (sms->paste_toggle) {
				sms->header.keyboard_down(&sms->header, sms->paste_toggle);
				sms->paste_state = PASTE_TOGGLE_UP;
				return sms->paste_toggle;
			} else {
				if (prev_key == keys.before) {
					return 0;
				}
				sms->header.keyboard_down(&sms->header, keys.before);
				sms->paste_state = PASTE_BEFORE_UP;
				return keys.before;
			}
		}
	case PASTE_MAIN:
		if (prev_key == keys.main) {
			// we're pressing the key that was just released, we need to wait to the next scan
			return 0;
		}
		sms->header.keyboard_down(&sms->header, keys.main);
		if (keys.mod) {
			sms->header.keyboard_down(&sms->header, keys.mod);
		}
		sms->paste_state = PASTE_MAIN_UP;
		return keys.main;
	case PASTE_AFTER:
		if (prev_key == keys.after) {
			return 0;
		}
		sms->header.keyboard_down(&sms->header, keys.after);
		sms->paste_state = PASTE_AFTER_UP;
		return keys.after;
	case PASTE_BEFORE_UP:
		sms->header.keyboard_up(&sms->header, keys.before);
		sms->paste_state = PASTE_MAIN;
		return keys.before;
	case PASTE_MAIN_UP:
		sms->header.keyboard_up(&sms->header, keys.main);
		if (keys.mod) {
			sms->header.keyboard_up(&sms->header, keys.mod);
		}
		if (keys.after && keys.after != keys.before) {
			sms->paste_state = PASTE_AFTER;
		} else {
			sms->paste_toggle = keys.after;
			sms->paste_state = PASTE_BEFORE;
			advance_paste_buffer(sms, paste);
		}
		return keys.main;
	case PASTE_AFTER_UP:
		sms->header.keyboard_up(&sms->header, keys.after);
		sms->paste_state = PASTE_BEFORE;
		if (keys.before == 0x81 && (keys.after == 0x85 || keys.after == 0x54)) {
			//special handling for DAKUTEN_KANA and MARU_KANA
			sms->paste_toggle = keys.before;
		}
		advance_paste_buffer(sms, paste);
		return keys.after;
	case PASTE_TOGGLE_UP: {
		sms->header.keyboard_up(&sms->header, sms->paste_toggle);
		sms->paste_state = PASTE_BEFORE;
		uint8_t ret = sms->paste_toggle;
		sms->paste_toggle = 0;
		return ret;
		}
	}
}

static void process_paste(sms_context *sms, uint32_t cycle)
{
	if (sms->header.paste_buffer && cycle > sms->last_paste_cycle && cycle - sms->last_paste_cycle >= PASTE_DELAY) {
		
		uint8_t main_key;
		if ((main_key = paste_internal(sms, 0))) {
			sms->last_paste_cycle = cycle;
			if (sms->header.paste_buffer && !sms->paste_state) {
				paste_internal(sms, main_key);
			}
		}
	}
}

static uint8_t i8255_input_poll(i8255 *ppi, uint32_t cycle, uint32_t port)
{
	if (port > 1) {
		return 0xFF;
	}
	sms_context *sms = ppi->system;
	if (sms->kb_mux == 7) {
		if (port) {
			//TODO: printer port BUSY/FAULT
			uint8_t port_b = io_data_read(sms->io.ports+1, cycle);
			return (port_b >> 2 & 0xF) | 0x10 | cassette_read(sms, cycle);
		} else {
			uint8_t port_a = io_data_read(sms->io.ports, cycle);
			uint8_t port_b = io_data_read(sms->io.ports+1, cycle);
			return (port_a & 0x3F) | (port_b << 6);
		}
	}
	process_events();
	process_paste(sms, cycle);
	//TODO: keyboard matrix ghosting
	if (port) {
		//TODO: printer port BUSY/FAULT
		return (sms->keystate[sms->kb_mux] >> 8) | 0x10 | cassette_read(sms, cycle);
	}
	return sms->keystate[sms->kb_mux];
}

static void update_mem_map(uint32_t location, sms_context *sms, uint8_t value)
{
	z80_context *z80 = sms->z80;
	void *old_value;
	if (location) {
		uint32_t idx = sms->header.info.mapper_start_index + location - 1;
		if (location != 3 || !(sms->bank_regs[0] & 8)) {
			//only update bank 2 location if RAM is not enabled
			old_value = z80->mem_pointers[idx];
			z80->mem_pointers[idx] = sms->rom + (value << 14 & (sms->rom_size-1));
			if (old_value != z80->mem_pointers[idx]) {
				//invalidate any code we translated for the relevant bank
				z80_invalidate_code_range(z80, idx ? idx * 0x4000 : 0x400, idx * 0x4000 + 0x4000);
			}
		}
	} else {
		uint32_t idx = sms->header.info.mapper_start_index + 2;
		old_value = z80->mem_pointers[idx];
		if (value & 8) {
			//cartridge RAM is enabled
			z80->mem_pointers[idx] = sms->cart_ram + ((value & 4) ? (SMS_CART_RAM_SIZE/2) : 0);
		} else {
			//cartridge RAM is disabled
			z80->mem_pointers[idx] = sms->rom + (sms->bank_regs[3] << 14 & (sms->rom_size-1));
		}
		if (old_value != z80->mem_pointers[idx]) {
			//invalidate any code we translated for the relevant bank
			z80_invalidate_code_range(z80, 0x8000, 0xC000);
		}
	}
}

void *sms_sega_mapper_write(uint32_t location, void *vcontext, uint8_t value)
{
	z80_context *z80 = vcontext;
	sms_context *sms = z80->system;
	location &= 3;
	sms->ram[0x1FFC + location] = value;
	sms->bank_regs[location] = value;
	update_mem_map(location, sms, value);
	return vcontext;
}

void *sms_cart_ram_write(uint32_t location, void *vcontext, uint8_t value)
{
	z80_context *z80 = vcontext;
	sms_context *sms = z80->system;
	if (sms->bank_regs[0] & 8) {
		//cartridge RAM is enabled
		location &= 0x3FFF;
		z80->mem_pointers[sms->header.info.mapper_start_index + 2][location] = value;
		z80_handle_code_write(0x8000 + location, z80);
	}
	return vcontext;
}

static z80_context *codemasters_write(uint8_t bank, z80_context *z80, uint8_t value)
{
	sms_context *sms = z80->system;
	if (value != sms->bank_regs[bank]) {
		sms->bank_regs[bank] = value;
		value &= 0x7F;
		z80->mem_pointers[bank] = sms->rom + (value << 14 & (sms->rom_size-1));
		z80_invalidate_code_range(z80, bank * 0x4000, bank * 0x4000 + 0x4000);
	}
	return z80;
}

void *sms_codemasters_bank0_write(uint32_t location, void *vcontext, uint8_t value)
{
	return codemasters_write(0, vcontext, value);
}

void *sms_codemasters_bank1_write(uint32_t location, void *vcontext, uint8_t value)
{
	return codemasters_write(1, vcontext, value);
}

void *sms_codemasters_bank2_write(uint32_t location, void *vcontext, uint8_t value)
{
	//TODO: Handle Ernie Els Golf cart RAM
	return codemasters_write(2, vcontext, value);
}

uint8_t debug_commands(system_header *system, char *input_buf)
{
	sms_context *sms = (sms_context *)system;
	switch(input_buf[0])
	{
	case 'v':
		if (input_buf[1] == 'r') {
			vdp_print_reg_explain(sms->vdp);
		} else if (input_buf[1] == 's') {
			vdp_print_sprite_table(sms->vdp);
		} else {
			return 0;
		}
		break;
	}
	return 1;
}

static uint8_t gg_io_read(uint32_t location, void *vcontext)
{
	z80_context *z80 = vcontext;
	sms_context *sms = z80->system;
	if (!location) {
		return sms->start_button_region;
	} else {
		//TODO: implement link port
		return 0xFF;
	}
}

static void *gg_io_write(uint32_t location, void *vcontext, uint8_t value)
{
	//TODO: implement link port
	return vcontext;
}
static void *psg_pan_write(uint32_t location, void *vcontext, uint8_t value)
{
	z80_context *z80 = vcontext;
	sms_context *sms = z80->system;
	psg_run(sms->psg, z80->Z80_CYCLE);
	sms->psg->pan = value;
	if (sms->psg->vgm) {
		vgm_gg_pan_write(sms->psg->vgm, sms->psg->cycles, sms->psg->pan);
	}
	return vcontext;
}

static void *ppi_write(uint32_t location, void *vcontext, uint8_t value)
{
	z80_context *z80 = vcontext;
	sms_context *sms = z80->system;
	i8255_write(location, sms->i8255, value, z80->Z80_CYCLE);
	return vcontext;
}

static uint8_t ppi_read(uint32_t location, void *vcontext)
{
	z80_context *z80 = vcontext;
	sms_context *sms = z80->system;
	return i8255_read(location, sms->i8255, z80->Z80_CYCLE);
}

static void *all_write(uint32_t location, void *vcontext, uint8_t value)
{
	vdp_write(location, vcontext, value);
	sms_psg_write(location, vcontext, value);
	return ppi_write(location, vcontext, value);
}

static uint8_t ppi_vdp_read(uint32_t location, void *vcontext)
{
	//TODO: "corrupt" PPI value by VDP value
	vdp_read(location, vcontext);
	return ppi_read(location, vcontext);
}

static void *vdp_psg_write(uint32_t location, void *vcontext, uint8_t value)
{
	vdp_write(location, vcontext, value);
	return sms_psg_write(location, vcontext, value);
}

static void *ppi_psg_write(uint32_t location, void *vcontext, uint8_t value)
{
	vdp_write(location, vcontext, value);
	return ppi_write(location, vcontext, value);
}

static void *ppi_vdp_write(uint32_t location, void *vcontext, uint8_t value)
{
	vdp_write(location, vcontext, value);
	return ppi_write(location, vcontext, value);
}

static memmap_chunk io_map[] = {
	{0x00, 0x40, 0xFF, .write_8 = memory_io_write},
	{0x40, 0x80, 0xFF, .read_8 = hv_read, .write_8 = sms_psg_write},
	{0x80, 0xC0, 0xFF, .read_8 = vdp_read, .write_8 = vdp_write},
	{0xC0, 0x100,0xFF, .read_8 = io_read}
};

static memmap_chunk io_gg[] = {
	{0x00, 0x06, 0xFF, .read_8 = gg_io_read, .write_8 = gg_io_write},
	{0x06, 0x07, 0xFF, .write_8 = psg_pan_write},
	{0x08, 0x40, 0xFF, .write_8 = memory_io_write},
	{0x40, 0x80, 0xFF, .read_8 = hv_read, .write_8 = sms_psg_write},
	{0x80, 0xC0, 0xFF, .read_8 = vdp_read, .write_8 = vdp_write},
	{0xC0, 0x100,0xFF, .read_8 = io_read}
};

static memmap_chunk io_sc[] = {
	{0x00, 0x20, 0x03, .read_8 = ppi_vdp_read, .write_8 = all_write},
	{0x20, 0x40, 0xFF, .read_8 = vdp_read, .write_8 = vdp_psg_write},
	{0x40, 0x60, 0x03, .read_8 = ppi_read, .write_8 = ppi_psg_write},
	{0x60, 0x80, 0xFF, .write_8 = sms_psg_write},
	{0x80, 0xA0, 0x03, .read_8 = ppi_vdp_read, .write_8 = ppi_vdp_write},
	{0xA0, 0xC0, 0xFF, .read_8 = vdp_read, .write_8 = vdp_write},
	{0xD0, 0x100, 0x03, .read_8 = ppi_read, .write_8 = ppi_write}
};

static void set_speed_percent(system_header * system, uint32_t percent)
{
	sms_context *context = (sms_context *)system;
	uint32_t old_clock = context->master_clock;
	context->master_clock = ((uint64_t)context->normal_clock * (uint64_t)percent) / 100;

	psg_adjust_master_clock(context->psg, context->master_clock);
}

void sms_serialize(sms_context *sms, serialize_buffer *buf)
{
	start_section(buf, SECTION_Z80);
	z80_serialize(sms->z80, buf);
	end_section(buf);

	start_section(buf, SECTION_VDP);
	vdp_serialize(sms->vdp, buf);
	end_section(buf);

	start_section(buf, SECTION_PSG);
	psg_serialize(sms->psg, buf);
	end_section(buf);

	start_section(buf, SECTION_SEGA_IO_1);
	io_serialize(sms->io.ports, buf);
	end_section(buf);

	start_section(buf, SECTION_SEGA_IO_2);
	io_serialize(sms->io.ports + 1, buf);
	end_section(buf);

	start_section(buf, SECTION_MAIN_RAM);
	save_int8(buf, sizeof(sms->ram) / 1024);
	save_buffer8(buf, sms->ram, sizeof(sms->ram));
	end_section(buf);

	start_section(buf, SECTION_MAPPER);
	save_int8(buf, 1);//mapper type, 1 for Sega mapper
	save_buffer8(buf, sms->bank_regs, sizeof(sms->bank_regs));
	end_section(buf);

	start_section(buf, SECTION_CART_RAM);
	save_int8(buf, SMS_CART_RAM_SIZE / 1024);
	save_buffer8(buf, sms->cart_ram, SMS_CART_RAM_SIZE);
	end_section(buf);
}

static uint8_t *serialize(system_header *sys, size_t *size_out)
{
	sms_context *sms = (sms_context *)sys;
	serialize_buffer state;
	init_serialize(&state);
	sms_serialize(sms, &state);
	if (size_out) {
		*size_out = state.size;
	}
	return state.data;
}

static void ram_deserialize(deserialize_buffer *buf, void *vsms)
{
	sms_context *sms = vsms;
	uint32_t ram_size = load_int8(buf) * 1024;
	if (ram_size > sizeof(sms->ram)) {
		fatal_error("State has a RAM size of %d bytes", ram_size);
	}
	load_buffer8(buf, sms->ram, ram_size);
}

static void cart_ram_deserialize(deserialize_buffer *buf, void *vsms)
{
	sms_context *sms = vsms;
	uint32_t ram_size = load_int8(buf) * 1024;
	if (ram_size > SMS_CART_RAM_SIZE) {
		fatal_error("State has a cart RAM size of %d bytes", ram_size);
	}
	load_buffer8(buf, sms->cart_ram, ram_size);
}

static void mapper_deserialize(deserialize_buffer *buf, void *vsms)
{
	sms_context *sms = vsms;
	uint8_t mapper_type = load_int8(buf);
	if (mapper_type != 1) {
		warning("State contains an unrecognized mapper type %d, it may be from a newer version of BlastEm\n", mapper_type);
		return;
	}
	for (int i = 0; i < sizeof(sms->bank_regs); i++)
	{
		sms->bank_regs[i] = load_int8(buf);
		update_mem_map(i, sms, sms->bank_regs[i]);
	}
}

void sms_deserialize(deserialize_buffer *buf, sms_context *sms)
{
	register_section_handler(buf, (section_handler){.fun = z80_deserialize, .data = sms->z80}, SECTION_Z80);
	register_section_handler(buf, (section_handler){.fun = vdp_deserialize, .data = sms->vdp}, SECTION_VDP);
	register_section_handler(buf, (section_handler){.fun = psg_deserialize, .data = sms->psg}, SECTION_PSG);
	register_section_handler(buf, (section_handler){.fun = io_deserialize, .data = sms->io.ports}, SECTION_SEGA_IO_1);
	register_section_handler(buf, (section_handler){.fun = io_deserialize, .data = sms->io.ports + 1}, SECTION_SEGA_IO_2);
	register_section_handler(buf, (section_handler){.fun = ram_deserialize, .data = sms}, SECTION_MAIN_RAM);
	register_section_handler(buf, (section_handler){.fun = mapper_deserialize, .data = sms}, SECTION_MAPPER);
	register_section_handler(buf, (section_handler){.fun = cart_ram_deserialize, .data = sms}, SECTION_CART_RAM);
	//TODO: cart RAM
	while (buf->cur_pos < buf->size)
	{
		load_section(buf);
	}
	z80_invalidate_code_range(sms->z80, 0xC000, 0x10000);
	if (sms->bank_regs[0] & 8) {
		//cart RAM is enabled, invalidate the region in case there is any code there
		z80_invalidate_code_range(sms->z80, 0x8000, 0xC000);
	}
	free(buf->handlers);
	buf->handlers = NULL;
}

static void deserialize(system_header *sys, uint8_t *data, size_t size)
{
	sms_context *sms = (sms_context *)sys;
	deserialize_buffer buffer;
	init_deserialize(&buffer, data, size);
	sms_deserialize(&buffer, sms);
}

static void save_state(sms_context *sms, uint8_t slot)
{
	char *save_path = get_slot_name(&sms->header, slot, "state");
	serialize_buffer state;
	init_serialize(&state);
	sms_serialize(sms, &state);
	save_to_file(&state, save_path);
	printf("Saved state to %s\n", save_path);
	free(save_path);
	free(state.data);
}

static uint8_t load_state_path(sms_context *sms, char *path)
{
	deserialize_buffer state;
	uint8_t ret;
	if ((ret = load_from_file(&state, path))) {
		sms_deserialize(&state, sms);
		free(state.data);
		printf("Loaded %s\n", path);
	}
	return ret;
}

static uint8_t load_state(system_header *system, uint8_t slot)
{
	sms_context *sms = (sms_context *)system;
	char *statepath = get_slot_name(system, slot, "state");
	uint8_t ret;
#ifndef NEW_CORE
	if (!sms->z80->native_pc) {
		ret = get_modification_time(statepath) != 0;
		if (ret) {
			system->delayed_load_slot = slot + 1;
		}
		goto done;

	}
#endif
	ret = load_state_path(sms, statepath);
done:
	free(statepath);
	return ret;
}

static void run_sms(system_header *system)
{
	sms_context *sms = (sms_context *)system;
	uint32_t target_cycle = sms->z80->Z80_CYCLE + 3420*16;
	while (!sms->should_return)
	{
		if (system->delayed_load_slot) {
			load_state(system, system->delayed_load_slot - 1);
			system->delayed_load_slot = 0;

		}
		if (sms->vdp->frame != sms->last_frame) {
#ifndef IS_LIB
			if (sms->psg->scope) {
				scope_render(sms->psg->scope);
			}
#endif
			uint32_t elapsed = sms->vdp->frame - sms->last_frame;
			sms->last_frame = sms->vdp->frame;
			if (system->enter_debugger_frames) {
				if (elapsed >= system->enter_debugger_frames) {
					system->enter_debugger_frames = 0;
					system->enter_debugger = 1;
				} else {
					system->enter_debugger_frames -= elapsed;
				}
			}

			if(exit_after){
				if (elapsed >= exit_after) {
					exit(0);
				} else {
					exit_after -= elapsed;
				}
			}
		}
#ifndef NEW_CORE
		if ((system->enter_debugger || sms->z80->wp_hit) && sms->z80->pc) {
			if (!sms->z80->wp_hit) {
				system->enter_debugger = 0;
			}
#ifndef IS_LIB
			zdebugger(sms->z80, sms->z80->pc);
#endif
		}
#endif
#ifdef NEW_CORE
		if (sms->z80->nmi_cycle == CYCLE_NEVER) {
#else
		if (sms->z80->nmi_start == CYCLE_NEVER) {
#endif
			uint32_t nmi = vdp_next_nmi(sms->vdp);
			if (nmi != CYCLE_NEVER) {
				z80_assert_nmi(sms->z80, nmi);
			}
		}

#ifndef NEW_CORE
		if (system->enter_debugger || sms->z80->wp_hit) {
			target_cycle = sms->z80->Z80_CYCLE + 1;
		}
#endif
		z80_run(sms->z80, target_cycle);
		if (sms->z80->reset) {
			z80_clear_reset(sms->z80, sms->z80->Z80_CYCLE + 128*15);
		}
		target_cycle = sms->z80->Z80_CYCLE;
		vdp_run_context(sms->vdp, target_cycle);
		psg_run(sms->psg, target_cycle);
		cassette_run(sms, target_cycle);

		if (system->save_state) {
			while (!sms->z80->pc) {
				//advance Z80 to an instruction boundary
				z80_run(sms->z80, sms->z80->Z80_CYCLE + 1);
			}
			save_state(sms, system->save_state - 1);
			system->save_state = 0;
		}

		target_cycle += 3420*16;
		if (target_cycle > 0x10000000) {
			uint32_t adjust = sms->z80->Z80_CYCLE - 3420*262*2;
			io_adjust_cycles(sms->io.ports, sms->z80->Z80_CYCLE, adjust);
			io_adjust_cycles(sms->io.ports+1, sms->z80->Z80_CYCLE, adjust);
			z80_adjust_cycles(sms->z80, adjust);
			vdp_adjust_cycles(sms->vdp, adjust);
			sms->psg->cycles -= adjust;
			sms->cassette_cycle -= adjust;
			if (sms->last_paste_cycle > adjust) {
				sms->last_paste_cycle -= adjust;
			} else {
				sms->last_paste_cycle = 0;
			}
			if (sms->psg->vgm) {
				vgm_adjust_cycles(sms->psg->vgm, adjust);
			}
			target_cycle -= adjust;
		}
	}
	if (sms->header.force_release || render_should_release_on_exit()) {
		bindings_release_capture();
		vdp_release_framebuffer(sms->vdp);
		render_pause_source(sms->psg->audio);
	}
	sms->should_return = 0;
}

static void resume_sms(system_header *system)
{
	sms_context *sms = (sms_context *)system;
	if (sms->header.force_release || render_should_release_on_exit()) {
		sms->header.force_release = 0;
		//TODO: PAL support
		if (sms->vdp->type == VDP_GAMEGEAR) {
			render_set_video_standard(VID_GAMEGEAR);
		} else {
			render_set_video_standard(VID_NTSC);
		}
		bindings_reacquire_capture();
		vdp_reacquire_framebuffer(sms->vdp);
		render_resume_source(sms->psg->audio);
	}
	run_sms(system);
}

static void start_sms(system_header *system, char *statefile)
{
	sms_context *sms = (sms_context *)system;

	z80_assert_reset(sms->z80, 0);
	z80_clear_reset(sms->z80, 128*15);

	if (statefile) {
		load_state_path(sms, statefile);
	}

	if (system->enter_debugger) {
		system->enter_debugger = 0;
#ifndef IS_LIB
		zinsert_breakpoint(sms->z80, sms->z80->pc, (uint8_t *)zdebugger);
#endif
	}

	//TODO: PAL support
	if (sms->vdp->type == VDP_GAMEGEAR) {
		render_set_video_standard(VID_GAMEGEAR);
	} else {
		render_set_video_standard(VID_NTSC);
	}
	run_sms(system);
}

static void soft_reset(system_header *system)
{
	sms_context *sms = (sms_context *)system;
	z80_assert_reset(sms->z80, sms->z80->Z80_CYCLE);
#ifndef NEW_CORE
	sms->z80->target_cycle = sms->z80->sync_cycle = sms->z80->Z80_CYCLE;
#endif
}

static void free_sms(system_header *system)
{
	sms_context *sms = (sms_context *)system;
	vdp_free(sms->vdp);
	z80_options_free(sms->z80->Z80_OPTS);
	free(sms->z80);
	psg_free(sms->psg);
	free(sms->i8255);
	free(sms);
}

static uint16_t get_open_bus_value(system_header *system)
{
	return 0xFFFF;
}

static void request_exit(system_header *system)
{
	sms_context *sms = (sms_context *)system;
	sms->should_return = 1;
#ifndef NEW_CORE
	sms->z80->target_cycle = sms->z80->sync_cycle = sms->z80->Z80_CYCLE;
#endif
}

static void inc_debug_mode(system_header *system)
{
	sms_context *sms = (sms_context *)system;
	vdp_inc_debug_mode(sms->vdp);
}

static void load_save(system_header *system)
{
	//TODO: Implement me
}

static void persist_save(system_header *system)
{
	//TODO: Implement me
}

static void gamepad_down(system_header *system, uint8_t gamepad_num, uint8_t button)
{
	sms_context *sms = (sms_context *)system;
	if (gamepad_num == GAMEPAD_MAIN_UNIT) {
		if (button == MAIN_UNIT_PAUSE) {
			vdp_pbc_pause(sms->vdp);
		}
	} else if (sms->vdp->type == VDP_GAMEGEAR && gamepad_num == 1 && button == BUTTON_START) {
		sms->start_button_region &= 0x7F;
	} else {
		io_gamepad_down(&sms->io, gamepad_num, button);
	}
}

static void gamepad_up(system_header *system, uint8_t gamepad_num, uint8_t button)
{
	sms_context *sms = (sms_context *)system;
	if (sms->vdp->type == VDP_GAMEGEAR && gamepad_num == 1 && button == BUTTON_START) {
		sms->start_button_region |= 0x80;
	} else {
		io_gamepad_up(&sms->io, gamepad_num, button);
	}
}

static void mouse_down(system_header *system, uint8_t mouse_num, uint8_t button)
{
	sms_context *sms = (sms_context *)system;
	io_mouse_down(&sms->io, mouse_num, button);
}

static void mouse_up(system_header *system, uint8_t mouse_num, uint8_t button)
{
	sms_context *sms = (sms_context *)system;
	io_mouse_up(&sms->io, mouse_num, button);
}

static void mouse_motion_absolute(system_header *system, uint8_t mouse_num, uint16_t x, uint16_t y)
{
	sms_context *sms = (sms_context *)system;
	io_mouse_motion_absolute(&sms->io, mouse_num, x, y);
}

static void mouse_motion_relative(system_header *system, uint8_t mouse_num, int32_t x, int32_t y)
{
	sms_context *sms = (sms_context *)system;
	io_mouse_motion_relative(&sms->io, mouse_num, x, y);
}

uint16_t scancode_map[0x90] = {
	[0x1C] = 0x0004,//A
	[0x32] = 0x4008,//B
	[0x21] = 0x2008,//C
	[0x23] = 0x2004,//D
	[0x24] = 0x2002,//E
	[0x2B] = 0x3004,//F
	[0x34] = 0x4004,//G
	[0x33] = 0x5004,//H
	[0x43] = 0x0080,//I
	[0x3B] = 0x6004,//J
	[0x42] = 0x0040,//K
	[0x4B] = 0x1040,//L
	[0x3A] = 0x6008,//M
	[0x31] = 0x5008,//N
	[0x44] = 0x1080,//O
	[0x4D] = 0x2080,//P
	[0x15] = 0x0002,//Q
	[0x2D] = 0x3002,//R
	[0x1B] = 0x1004,//S
	[0x2C] = 0x4002,//T
	[0x3C] = 0x6002,//U
	[0x2A] = 0x3008,//V
	[0x1D] = 0x1002,//W
	[0x22] = 0x1008,//X
	[0x35] = 0x5002,//Y
	[0x1A] = 0x0008,//Z
	[0x16] = 0x0001,//1
	[0x1E] = 0x1001,//2
	[0x26] = 0x2001,//3
	[0x25] = 0x3001,//4
	[0x2E] = 0x4001,//5
	[0x36] = 0x5001,//6
	[0x3D] = 0x6001,//7
	[0x3E] = 0x0100,//8
	[0x46] = 0x1100,//9
	[0x45] = 0x2100,//0
	[0x5A] = 0x5040,//return
	[0x29] = 0x1010,//space
	[0x0D] = 0x5800,//tab mapped to FUNC
	[0x66] = 0x3010,//backspace mapped to INS/DEL
	[0x4E] = 0x3100,// -
	[0x55] = 0x4100,// = mapped to ^ based on position
	[0x54] = 0x4080,// [
	[0x5B] = 0x4040,// ]
	[0x5D] = 0x5100,// \ mapped to Yen based on position/correspondence on PC keyboards
	[0x4C] = 0x2040,// ;
	[0x52] = 0x3040,// ' mapped to : based on position
	[0x0E] = 0x3020,// ` mapped to PI because of lack of good options
	[0x41] = 0x0020,// ,
	[0x49] = 0x1020,// .
	[0x4A] = 0x2020,// /
	[0x14] = 0x6400,//lctrl mapped to ctrl
	//rctrl is default keybind for toggle keyboard capture
	//[0x18] = 0x6400,//rctrl mapped to ctrl
	[0x12] = 0x6800,//lshift mapped to shift
	[0x59] = 0x6800,//lshift mapped to shift
	[0x11] = 0x6200,//lalt mapped to GRAPH
	[0x17] = 0x6200,//ralt mapped to GRAPH
	[0x81] = 0x0010,//insert mapped to kana/dieresis key
	[0x86] = 0x5020,//left arrow
	[0x87] = 0x2010,//home mapped to HOME/CLR
	[0x88] = 0x6100,//end mapped to BREAK
	[0x89] = 0x6040,//up arrow
	[0x8A] = 0x4020,//down arrow
	[0x8D] = 0x6020,//right arrow
	[0x85] = 0x3080,//del mapped to @ because of lack of good options
};

static void keyboard_down(system_header *system, uint8_t scancode)
{
	sms_context *sms = (sms_context *)system;
	io_keyboard_down(&sms->io, scancode);
	if (sms->keystate && scancode < 0x90 && scancode_map[scancode]) {
		uint16_t row = scancode_map[scancode] >> 12;
		sms->keystate[row] &= ~(scancode_map[scancode] & 0xFFF);
	}
}

static void keyboard_up(system_header *system, uint8_t scancode)
{
	sms_context *sms = (sms_context *)system;
	io_keyboard_up(&sms->io, scancode);
	if (sms->keystate && scancode < 0x90 && scancode_map[scancode]) {
		uint16_t row = scancode_map[scancode] >> 12;
		sms->keystate[row] |= scancode_map[scancode] & 0xFFF;
	}
}

static void set_gain_config(sms_context *sms)
{
	char *config_gain;
	config_gain = tern_find_path(config, "audio\0psg_gain\0", TVAL_PTR).ptrval;
	render_audio_source_gaindb(sms->psg->audio, config_gain ? atof(config_gain) : 0.0f);
}

static void config_updated(system_header *system)
{
	sms_context *sms = (sms_context *)system;
	setup_io_devices(config, &system->info, &sms->io);
	//sample rate may have changed
	psg_adjust_master_clock(sms->psg, sms->master_clock);
}

static void toggle_debug_view(system_header *system, uint8_t debug_view)
{
#ifndef IS_LIB
	sms_context *sms = (sms_context *)system;
	if (debug_view < DEBUG_OSCILLOSCOPE) {
		vdp_toggle_debug_view(sms->vdp, debug_view);
	} else if (debug_view == DEBUG_OSCILLOSCOPE) {
		if (sms->psg->scope) {
			oscilloscope *scope = sms->psg->scope;
			sms->psg->scope = NULL;
			scope_close(scope);
		} else {
			oscilloscope *scope = create_oscilloscope();
			psg_enable_scope(sms->psg, scope, sms->normal_clock);
		}
	}
#endif
}

void load_cassette(sms_context *sms, system_media *media)
{
	sms->cassette = NULL;
	sms->cassette_state = TAPE_NONE;
	memcpy(&sms->cassette_wave, media->buffer, offsetof(wave_header, data_header));
	if (memcmp(sms->cassette_wave.chunk.format, "WAVE", 4)) {
		return;
	}
	if (sms->cassette_wave.chunk.size < offsetof(wave_header, data_header)) {
		return;
	}
	if (memcmp(sms->cassette_wave.format_header.id, "fmt ", 4)) {
		return;
	}
	if (sms->cassette_wave.format_header.size < offsetof(wave_header, data_header) - offsetof(wave_header, audio_format)) {
		return;
	}
	if (sms->cassette_wave.bits_per_sample != 8 && sms->cassette_wave.bits_per_sample != 16) {
		return;
	}
	uint32_t data_sub_chunk = sms->cassette_wave.format_header.size + offsetof(wave_header, audio_format);
	if (data_sub_chunk > media->size || media->size - data_sub_chunk < sizeof(riff_sub_chunk)) {
		return;
	}
	memcpy(&sms->cassette_wave.data_header, ((uint8_t *)media->buffer) + data_sub_chunk, sizeof(riff_sub_chunk));
	sms->cassette_state = TAPE_STOPPED;
	sms->cassette_offset = data_sub_chunk;
	sms->cassette = media;
	sms->cassette_cycle = sms->z80->Z80_CYCLE;
}

static void start_vgm_log(system_header *system, char *filename)
{
	sms_context *sms = (sms_context *)system;
	//TODO: 50 Hz support
	vgm_writer *vgm = vgm_write_open(filename, 60, sms->normal_clock, sms->z80->Z80_CYCLE);
	if (vgm) {
		printf("Started logging VGM to %s\n", filename);
		psg_run(sms->psg, sms->z80->Z80_CYCLE);
		psg_vgm_log(sms->psg, sms->normal_clock, vgm);
		sms->header.vgm_logging = 1;
	} else {
		printf("Failed to start logging to %s\n", filename);
	}
}

static void stop_vgm_log(system_header *system)
{
	puts("Stopped VGM log");
	sms_context *sms = (sms_context *)system;
	vgm_close(sms->psg->vgm);
	sms->psg->vgm = NULL;
	sms->header.vgm_logging = 0;
}

static void lockon_change(system_header *system, system_media *media)
{
	sms_context *sms = (sms_context *)system;
	load_cassette(sms, media);
}

static vdp_context *get_vdp(system_header *system)
{
	sms_context *sms = (sms_context *)system;
	return sms->vdp;
}

sms_context *alloc_configure_sms(system_media *media, system_type stype, uint32_t opts, uint8_t force_region)
{
	sms_context *sms = calloc(1, sizeof(sms_context));
	tern_node *rom_db = get_rom_db();
	const memmap_chunk base_map[] = {
		{0xC000, 0x10000, sizeof(sms->ram)-1, .flags = MMAP_READ|MMAP_WRITE|MMAP_CODE, .buffer = sms->ram}
	};
	sms->header.info = configure_rom_sms(rom_db, media->buffer, media->size, base_map, sizeof(base_map)/sizeof(base_map[0]));
	uint32_t rom_size = sms->header.info.rom_size;
	z80_options *zopts = malloc(sizeof(z80_options));
	tern_node *model_def;
	uint8_t vdp_type = VDP_SMS2;
	switch (stype)
	{
	case SYSTEM_GAME_GEAR:
		model_def = tern_find_node(get_systems_config(), "gg");
		vdp_type = VDP_GAMEGEAR;
		break;
	case SYSTEM_SG1000:
		model_def = tern_find_node(get_systems_config(), "sg1000");
		vdp_type = VDP_TMS9918A;
		break;
	case SYSTEM_SC3000:
		model_def = tern_find_node(get_systems_config(), "sc3000");
		vdp_type = VDP_TMS9918A;
		break;
	default:
		model_def = get_model(config, SYSTEM_SMS);
		break;
	}
	char *vdp_str = tern_find_ptr(model_def, "vdp");
	if (vdp_str) {
		if (!strcmp(vdp_str, "sms1")) {
			vdp_type = VDP_SMS;
		} else if (!strcmp(vdp_str, "sms2")) {
			vdp_type = VDP_SMS2;
		} else if (!strcmp(vdp_str, "tms9918a")) {
			vdp_type = VDP_TMS9918A;
		} else if (!strcmp(vdp_str, "gamegear")) {
			vdp_type = VDP_GAMEGEAR;
		} else if (!strcmp(vdp_str, "genesis")) {
			vdp_type = VDP_GENESIS;
		} else {
			warning("Unrecognized VDP type %s\n", vdp_str);
		}
	}
	for (uint32_t i = 0; i < sms->header.info.map_chunks; i++)
	{
		memmap_chunk *chunk = sms->header.info.map + i;
		if ((chunk->flags == MMAP_READ) && !chunk->buffer && chunk->start > 0xC000) {
			chunk->buffer = sms->ram + ((chunk->start - 0xC000) & 0x1FFF);
		}
	}
	uint8_t is_gamegear = stype == SYSTEM_GAME_GEAR, is_sc3000 = stype == SYSTEM_SC3000;
	char *io_type = tern_find_ptr(model_def, "io");
	if (io_type) {
		if (!strcmp(io_type, "gamegear")) {
			is_gamegear = 1;
			is_sc3000 = 0;
		} else if (!strcmp(io_type, "i8255")) {
			is_gamegear = 0;
			is_sc3000 = 1;
		}
	}
	if (is_gamegear) {
		init_z80_opts(zopts, sms->header.info.map, sms->header.info.map_chunks, io_gg, 6, 15, 0xFF);
		sms->start_button_region = 0xC0;
	} else if (is_sc3000) {
		sms->keystate = calloc(sizeof(uint16_t), 7);
		for (int i = 0; i < 7; i++)
		{
			sms->keystate[i] = 0xFFF;
		}
		sms->i8255 = calloc(1, sizeof(i8255));
		i8255_init(sms->i8255, i8255_output_updated, i8255_input_poll);
		sms->i8255->system = sms;
		sms->kb_mux = 7;
		init_z80_opts(zopts, sms->header.info.map, sms->header.info.map_chunks, io_sc, 7, 15, 0xFF);
	} else {
		init_z80_opts(zopts, sms->header.info.map, sms->header.info.map_chunks, io_map, 4, 15, 0xFF);
	}
	if (is_sc3000 && media->chain) {
		load_cassette(sms, media->chain);
	}
	sms->z80 = init_z80_context(zopts);
	sms->z80->system = sms;
	sms->z80->Z80_OPTS->gen.debug_cmd_handler = debug_commands;

	sms->rom = media->buffer;
	sms->rom_size = rom_size;
	switch (sms->header.info.mapper_type)
	{
	case MAPPER_SMS_SEGA:
		sms->z80->mem_pointers[0] = sms->rom;
		sms->z80->mem_pointers[1] = sms->rom + 0x4000;
		sms->z80->mem_pointers[2] = sms->rom + 0x8000;
		sms->bank_regs[1] = 0;
		sms->bank_regs[2] = 0x4000 >> 14;
		sms->bank_regs[3] = 0x8000 >> 14;
		break;
	case MAPPER_SMS_CODEMASTERS:
		//FIXME:
		break;
	case MAPPER_SMS_SUPER_GAME_30:
		super_game_30_init(sms);
		break;
	}

	//TODO: Detect region and pick master clock based off of that
	sms->normal_clock = sms->master_clock = 53693175;

	sms->psg = malloc(sizeof(psg_context));
	psg_init(sms->psg, sms->master_clock, 15*16);

	set_gain_config(sms);

	sms->vdp = init_vdp_context(0, 0, vdp_type);
	sms->vdp->system = &sms->header;

	sms->header.info.save_type = SAVE_NONE;
	sms->header.info.name = strdup(media->name);

	tern_node *io_config_root = config;
	tern_node *sms_root = tern_find_node(config, "sms");
	if (sms_root) {
		tern_node *io = tern_find_node(sms_root, "io");
		if (io) {
			io_config_root = sms_root;
		}
	}
	setup_io_devices(io_config_root, &sms->header.info, &sms->io);
	sms->header.has_keyboard = io_has_keyboard(&sms->io) || sms->keystate;

	sms->header.set_speed_percent = set_speed_percent;
	sms->header.start_context = start_sms;
	sms->header.resume_context = resume_sms;
	sms->header.load_save = load_save;
	sms->header.persist_save = persist_save;
	sms->header.load_state = load_state;
	sms->header.free_context = free_sms;
	sms->header.get_open_bus_value = get_open_bus_value;
	sms->header.request_exit = request_exit;
	sms->header.soft_reset = soft_reset;
	sms->header.inc_debug_mode = inc_debug_mode;
	sms->header.gamepad_down = gamepad_down;
	sms->header.gamepad_up = gamepad_up;
	sms->header.mouse_down = mouse_down;
	sms->header.mouse_up = mouse_up;
	sms->header.mouse_motion_absolute = mouse_motion_absolute;
	sms->header.mouse_motion_relative = mouse_motion_relative;
	sms->header.keyboard_down = keyboard_down;
	sms->header.keyboard_up = keyboard_up;
	sms->header.config_updated = config_updated;
	sms->header.serialize = serialize;
	sms->header.deserialize = deserialize;
	sms->header.start_vgm_log = start_vgm_log;
	sms->header.stop_vgm_log = stop_vgm_log;
	sms->header.toggle_debug_view = toggle_debug_view;
	sms->header.cassette_action = cassette_action;
	sms->header.get_vdp = get_vdp;
	sms->header.type = stype;
	if (is_sc3000) {
		sms->header.lockon_change = lockon_change;
	}

	return sms;
}
