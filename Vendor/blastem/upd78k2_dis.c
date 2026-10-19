#include <string.h>

#include "upd78k2_dis.h"

typedef enum {
	T_INVALID,
	T_STRING,
	T_PREFIX,
	T_REG_REG,
	T_SFR,
	T_SFR_BYTE,
	T_SFR_WORD,
	T_SADDR,
	T_SADDR_BYTE,
	T_SADDR_WORD,
	T_SADDR_SADDR,
	T_BYTE,
	T_BASE,
	T_WORD,
	T_INDEXED,
	T_ADDR16,
	T_BR_REL,
	T_BR_ABS,
	T_BR_SFR,
	T_BR_SADDR,
	T_CALLF,
	T_CALLT,
	T_CUSTOM
} upd_inst_type;

typedef struct upd_inst upd_inst;
typedef uint16_t (*custom_fun)(char *dst, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data, disasm_context *context);

struct upd_inst {
	union {
		char       *str;
		upd_inst   *prefix;
		custom_fun fun;
	} v;
	upd_inst_type type;
};

#define STRING(s) {.v = {.str = s}, .type = T_STRING}
#define PREFIX(t) {.v = {.prefix = t}, .type = T_PREFIX}
#define REG_REG(s) {.v = {.str = s}, .type = T_REG_REG}
#define SFR(s) {.v = {.str = s}, .type = T_SFR}
#define SFR_BYTE(s) {.v = {.str = s}, .type = T_SFR_BYTE}
#define SFR_WORD(s) {.v = {.str = s}, .type = T_SFR_WORD}
#define SADDR(s) {.v = {.str = s}, .type = T_SADDR}
#define SADDR_BYTE(s) {.v = {.str = s}, .type = T_SADDR_BYTE}
#define SADDR_WORD(s) {.v = {.str = s}, .type = T_SADDR_WORD}
#define SADDR_SADDR(s) {.v = {.str = s}, .type = T_SADDR_SADDR}
#define BYTE(s) {.v = {.str = s}, .type = T_BYTE}
#define BASE(s) {.v = {.str = s}, .type = T_BASE}
#define WORD(s) {.v = {.str = s}, .type = T_WORD}
#define INDEXED(s) {.v = {.str = s}, .type = T_INDEXED}
#define ADDR16(s) {.v = {.str = s}, .type = T_ADDR16}
#define BRANCH_REL(s) {.v = {.str = s}, .type = T_BR_REL}
#define BRANCH_ABS(s) {.v = {.str = s}, .type = T_BR_ABS}
#define BRANCH_SFR(s) {.v = {.str = s}, .type = T_BR_SFR}
#define BRANCH_SADDR(s) {.v = {.str = s}, .type = T_BR_SADDR}
#define CALLF {.type = T_CALLF}
#define CALLT {.type = T_CALLT}
#define CUSTOM(f) {.v = {.fun = f}, .type = T_CUSTOM}
#define INVALID {.type = T_INVALID}

static void format_address(disasm_context *context, char *dst, uint16_t address)
{
	if (context) {
		format_label(dst, address, context);
	} else {
		sprintf(dst, "0%XH", address);
	}
}

static uint16_t disasm_sfr_mov16(char *dst, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data, disasm_context *context)
{
	char addr_buf[256];
	uint8_t offset = fetch(address++, data);
	uint16_t immed = fetch(address++, data);
	immed |= fetch(address++, data) << 8;
	uint16_t ref_addr = 0;
	uint8_t ref_type = UPD_REF_NONE;
	if (offset == 0xFC) {
		sprintf(dst, "movw sp,#0%XH", immed);
	} else {
		ref_addr = 0xFF00 | offset;
		ref_type = UPD_REF_OP;
		format_address(context, addr_buf, ref_addr);
		sprintf(dst, "movw %s,#0%XH", addr_buf, immed);
	}
	if (ref) {
		ref->address = ref_addr;
		ref->ref_type = ref_type;
	}
	return address;
}

static uint16_t disasm_mov_a_sfr(char *dst, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data, disasm_context *context)
{
	char addr_buf[256];
	uint8_t offset = fetch(address++, data);
	uint16_t ref_addr = 0;
	uint8_t ref_type = UPD_REF_NONE;
	if (offset == 0xFE) {
		strcpy(dst, "mov a,psw");
	} else {
		ref_addr = 0xFF00 | offset;
		ref_type = UPD_REF_OP;
		format_address(context, addr_buf, ref_addr);
		sprintf(dst, "mov a,%s", addr_buf);
	}
	if (ref) {
		ref->address = ref_addr;
		ref->ref_type = ref_type;
	}
	return address;
}

static uint16_t disasm_movw_ax_sfr(char *dst, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data, disasm_context *context)
{
	char addr_buf[256];
	uint8_t offset = fetch(address++, data);
	uint16_t ref_addr = 0;
	uint8_t ref_type = UPD_REF_NONE;
	if (offset == 0xFC) {
		strcpy(dst, "movw ax,sp");
	} else {
		ref_addr = 0xFF00 | offset;
		ref_type = UPD_REF_OP;
		format_address(context, addr_buf, ref_addr);
		sprintf(dst, "movw ax,%s", addr_buf);
	}
	if (ref) {
		ref->address = ref_addr;
		ref->ref_type = ref_type;
	}
	return address;
}

static uint16_t disasm_mov_sfr_a(char *dst, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data, disasm_context *context)
{
	char addr_buf[256];
	uint8_t offset = fetch(address++, data);
	uint16_t ref_addr = 0;
	uint8_t ref_type = UPD_REF_NONE;
	if (offset == 0xFE) {
		strcpy(dst, "mov psw,a");
	} else {
		ref_addr = 0xFF00 | offset;
		ref_type = UPD_REF_OP;
		format_address(context, addr_buf, ref_addr);
		sprintf(dst, "mov %s,a", addr_buf);
	}
	if (ref) {
		ref->address = ref_addr;
		ref->ref_type = ref_type;
	}
	return address;
}

static uint16_t disasm_movw_sfr_ax(char *dst, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data, disasm_context *context)
{
	char addr_buf[256];
	uint8_t offset = fetch(address++, data);
	uint16_t ref_addr = 0;
	uint8_t ref_type = UPD_REF_NONE;
	if (offset == 0xFC) {
		strcpy(dst, "movw sp,ax");
	} else {
		ref_addr = 0xFF00 | offset;
		ref_type = UPD_REF_OP;
		format_address(context, addr_buf, ref_addr);
		sprintf(dst, "movw %s,ax", addr_buf);
	}
	if (ref) {
		ref->address = ref_addr;
		ref->ref_type = ref_type;
	}
	return address;
}

static uint16_t disasm_mov_sfr_byte(char *dst, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data, disasm_context *context)
{
	char addr_buf[256];
	uint8_t offset = fetch(address++, data);
	uint8_t immed = fetch(address++, data);
	uint16_t ref_addr = 0;
	uint8_t ref_type = UPD_REF_NONE;
	if (offset == 0xFE) {
		sprintf(dst, "mov psw,#0%XH", immed);
	} else {
		ref_addr = 0xFF00 | offset;
		ref_type = UPD_REF_OP;
		format_address(context, addr_buf, ref_addr);
		sprintf(dst, "mov %s,#0%XH", addr_buf, immed);
	}
	if (ref) {
		ref->address = ref_addr;
		ref->ref_type = ref_type;
	}
	return address;
}

static uint16_t disasm_ror4_mov_mem1(char *dst, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data, disasm_context *context)
{
	uint8_t byte = fetch(address++, data);
	if ((byte & 0xED) == 0x8C) {
		sprintf(dst, "ro%c4 &[%s]", byte & 0x10 ? 'l' : 'r', byte & 0x02 ? "hl" : "de");
	} else if ((byte & 0xFA) == 0xE2) {
	}
	
	if (ref) {
		ref->address = 0;
		ref->ref_type = UPD_REF_NONE;
	}
	return address;
}

static uint16_t disasm_mov_stbc(char *dst, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data, disasm_context *context)
{
	uint8_t inverse = fetch(address++, data);
	uint8_t byte = fetch(address++, data);
	if ((~inverse) != byte) {
		strcpy(dst, "invalid");
	} else {
		sprintf(dst, "mov stbc,#0%XH", byte);
	}
	if (ref) {
		ref->address = 0;
		ref->ref_type = UPD_REF_NONE;
	}
	return address;
}

static uint16_t disasm_op_r_r(char *dst, char *mnemonic, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data)
{
	static const char regnames[] = "xacbedlh";
	static const char *regpairs[] = {"ax", "bc", "de", "hl"};
	uint8_t byte = fetch(address++, data);
	uint8_t word_mask = mnemonic[0] == 'm' ? 0x99 : 0xF9;
	if (!(byte & 0x88)) {
		sprintf(dst, "%s %c,%c", mnemonic, regnames[byte >> 4], regnames[byte & 7]);
	} else if ((byte & word_mask) == 0x08) {
		sprintf(dst, "%sw %s,%s", mnemonic, regpairs[byte >> 5], regpairs[byte >> 1 & 3]);
	} else {
		strcpy(dst, "invalid");
	}
	if (ref) {
		ref->address = 0;
		ref->ref_type = UPD_REF_NONE;
	}
	return address;
}

static uint16_t disasm_mov_r_r(char *dst, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data, disasm_context *context)
{
	return disasm_op_r_r(dst, "mov", ref, address, fetch, data);
}

static uint16_t disasm_add_r_r(char *dst, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data, disasm_context *context)
{
	return disasm_op_r_r(dst, "add", ref, address, fetch, data);
}

static uint16_t disasm_sub_r_r(char *dst, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data, disasm_context *context)
{
	return disasm_op_r_r(dst, "sub", ref, address, fetch, data);
}

static uint16_t disasm_cmp_r_r(char *dst, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data, disasm_context *context)
{
	return disasm_op_r_r(dst, "cmp", ref, address, fetch, data);
}

static uint16_t disasm_shift(char *dst, char lr, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data)
{
	static const char regnames[] = "xacbedlh";
	static const char *regpairs[] = {"ax", "bc", "de", "hl"};
	static const char *names[] = {"rolc", "rol", "shl", "shlw"};
	uint8_t byte = fetch(address++, data);
	uint8_t shift_type = byte >> 6;
	if (shift_type == 3) {
		if (byte & 1) {
			strcpy(dst, "invalid");
		} else {
			sprintf(dst, "%s %s,%d", names[shift_type], regpairs[byte >> 1 & 3], byte >> 3 & 7);
			dst[2] = lr;
		}
	} else {
		sprintf(dst, "%s %c,%d", names[shift_type], regnames[byte & 7], byte >> 3 & 7);
		dst[2] = lr;
	}
	if (ref) {
		ref->address = 0;
		ref->ref_type = UPD_REF_NONE;
	}
	return address;
}

static uint16_t disasm_shift_left(char *dst, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data, disasm_context *context)
{
	return disasm_shift(dst, 'l', ref, address, fetch, data);
}

static uint16_t disasm_shift_right(char *dst, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data, disasm_context *context)
{
	return disasm_shift(dst, 'r', ref, address, fetch, data);
}

upd_inst alt_base[256] = {
	/* 0000 0000 */BASE("mov a,&[de+0%XH]"), INVALID, INVALID, INVALID,
	/* 0000 0100 */BASE("xch a,&[de+0%XH]"), INVALID, INVALID, INVALID,
	/* 0000 1000 */BASE("add a,&[de+0%XH]"), BASE("addc a,&[de+0%XH]"), BASE("sub a,&[de+0%XH]"), BASE("subc a,&[de+0%XH]"),
	/* 0000 1100 */BASE("and a,&[de+0%XH]"), BASE("xor a,&[de+0%XH]"), BASE("or a,&[de+0%XH]"), BASE("cmp a,&[de+0%XH]"),
	/* 0001 0000 */BASE("mov a,&[sp+0%XH]"), INVALID, INVALID, INVALID,
	/* 0001 0100 */BASE("xch a,&[sp+0%XH]"), INVALID, INVALID, INVALID,
	/* 0001 1000 */BASE("add a,&[sp+0%XH]"), BASE("addc a,&[sp+0%XH]"), BASE("sub a,&[sp+0%XH]"), BASE("subc a,&[sp+0%XH]"),
	/* 0001 1100 */BASE("and a,&[sp+0%XH]"), BASE("xor a,&[sp+0%XH]"), BASE("or a,&[sp+0%XH]"), BASE("cmp a,&[sp+0%XH]"),
	/* 0010 0000 */BASE("mov a,&[hl+0%XH]"), INVALID, INVALID, INVALID,
	/* 0010 0100 */BASE("xch a,&[hl+0%XH]"), INVALID, INVALID, INVALID,
	/* 0010 1000 */BASE("add a,&[hl+0%XH]"), BASE("addc a,&[hl+0%XH]"), BASE("sub a,&[hl+0%XH]"), BASE("subc a,&[hl+0%XH]"),
	/* 0010 1100 */BASE("and a,&[hl+0%XH]"), BASE("xor a,&[hl+0%XH]"), BASE("or a,&[hl+0%XH]"), BASE("cmp a,&[hl+0%XH]"),
	/* 1000 0000 */[0x80] = BASE("mov &[de+0%XH],a"),
	/* 1001 0000 */[0x90] = BASE("mov &[sp+0%XH],a"),
	/* 1010 0000 */[0xA0] = BASE("mov &[hl+0%XH],a")
};
upd_inst alt_indexed[256] = {
	/* 0000 0000 */INDEXED("mov a,&0%XH[de]"), INVALID, INVALID, INVALID,
	/* 0000 0100 */INDEXED("xch a,&0%XH[de]"), INVALID, INVALID, INVALID,
	/* 0000 1000 */INDEXED("add a,&0%XH[de]"), INDEXED("addc a,&0%XH[de]"), INDEXED("sub a,&0%XH[de]"), INDEXED("subc a,&0%XH[de]"),
	/* 0000 1100 */INDEXED("and a,&0%XH[de]"), INDEXED("xor a,&0%XH[de]"), INDEXED("or a,&0%XH[de]"), INDEXED("cmp a,&0%XH[de]"),
	/* 0001 0000 */INDEXED("mov a,&0%XH[a]"), INVALID, INVALID, INVALID,
	/* 0001 0100 */INDEXED("xch a,&0%XH[a]"), INVALID, INVALID, INVALID,
	/* 0001 1000 */INDEXED("add a,&0%XH[a]"), INDEXED("addc a,&0%XH[a]"), INDEXED("sub a,&0%XH[a]"), INDEXED("subc a,&0%XH[a]"),
	/* 0001 1100 */INDEXED("and a,&0%XH[a]"), INDEXED("xor a,&0%XH[a]"), INDEXED("or a,&0%XH[a]"), INDEXED("cmp a,&0%XH[a]"),
	/* 0010 0000 */INDEXED("mov a,&0%XH[hl]"), INVALID, INVALID, INVALID,
	/* 0010 0100 */INDEXED("xch a,&0%XH[hl]"), INVALID, INVALID, INVALID,
	/* 0010 1000 */INDEXED("add a,&0%XH[hl]"), INDEXED("addc a,&0%XH[hl]"), INDEXED("sub a,&0%XH[hl]"), INDEXED("subc a,&0%XH[hl]"),
	/* 0010 1100 */INDEXED("and a,&0%XH[hl]"), INDEXED("xor a,&0%XH[hl]"), INDEXED("or a,&0%XH[hl]"), INDEXED("cmp a,&0%XH[hl]"),
	/* 0011 0000 */INDEXED("mov a,&0%XH[b]"), INVALID, INVALID, INVALID,
	/* 0011 0100 */INDEXED("xch a,&0%XH[b]"), INVALID, INVALID, INVALID,
	/* 0011 1000 */INDEXED("add a,&0%XH[b]"), INDEXED("addc a,&0%XH[b]"), INDEXED("sub a,&0%XH[b]"), INDEXED("subc a,&0%XH[b]"),
	/* 0011 1100 */INDEXED("and a,&0%XH[b]"), INDEXED("xor a,&0%XH[b]"), INDEXED("or a,&0%XH[b]"), INDEXED("cmp a,&0%XH[b]"),
	/* 1000 0000 */[0x80] = INDEXED("mov &0%XH[de],a"),
	/* 1001 0000 */[0x90] = INDEXED("mov &0%XH[a],a"),
	/* 1010 0000 */[0xA0] = INDEXED("mov &0%XH[hl],a"),
	/* 1011 0000 */[0xB0] = INDEXED("mov &0%XH[b],a")
};
upd_inst alt_regind[256] = {
	/* 0000 0000 */STRING("mov a,&[de+]"), INVALID, INVALID, INVALID,
	/* 0000 0100 */STRING("xch a,&[de+]"), INVALID, INVALID, INVALID,
	/* 0000 1000 */STRING("add a,&[de+]"), STRING("addc a,&[de+]"), STRING("sub a,&[de+]"), STRING("subc a,&[de+]"),
	/* 0000 1100 */STRING("and a,&[de+]"), STRING("xor a,&[de+]"), STRING("or a,&[de+]"), STRING("cmp a,&[de+]"),
	/* 0001 0000 */STRING("mov a,&[hl+]"), INVALID, INVALID, INVALID,
	/* 0001 0100 */STRING("xch a,&[hl+]"), INVALID, INVALID, INVALID,
	/* 0001 1000 */STRING("add a,&[hl+]"), STRING("addc a,&[hl+]"), STRING("sub a,&[hl+]"), STRING("subc a,&[hl+]"),
	/* 0001 1100 */STRING("and a,&[hl+]"), STRING("xor a,&[hl+]"), STRING("or a,&[hl+]"), STRING("cmp a,&[hl+]"),
	/* 0010 0000 */STRING("mov a,&[de-]"), INVALID, INVALID, INVALID,
	/* 0010 0100 */STRING("xch a,&[de-]"), INVALID, INVALID, INVALID,
	/* 0010 1000 */STRING("add a,&[de-]"), STRING("addc a,&[de-]"), STRING("sub a,&[de-]"), STRING("subc a,&[de-]"),
	/* 0010 1100 */STRING("and a,&[de-]"), STRING("xor a,&[de-]"), STRING("or a,&[de-]"), STRING("cmp a,&[de-]"),
	/* 0011 0000 */STRING("mov a,&[hl-]"), INVALID, INVALID, INVALID,
	/* 0011 0100 */STRING("xch a,&[hl-]"), INVALID, INVALID, INVALID,
	/* 0011 1000 */STRING("add a,&[hl-]"), STRING("addc a,&[hl-]"), STRING("sub a,&[hl-]"), STRING("subc a,&[hl-]"),
	/* 0011 1100 */STRING("and a,&[hl-]"), STRING("xor a,&[hl-]"), STRING("or a,&[hl-]"), STRING("cmp a,&[hl-]"),
	/* 0100 0000 */STRING("mov a,&[de]"), INVALID, INVALID, INVALID,
	/* 0100 0100 */STRING("xch a,&[de]"), INVALID, INVALID, INVALID,
	/* 0100 1000 */STRING("add a,&[de]"), STRING("addc a,&[de]"), STRING("sub a,&[de]"), STRING("subc a,&[de]"),
	/* 0100 1100 */STRING("and a,&[de]"), STRING("xor a,&[de]"), STRING("or a,&[de]"), STRING("cmp a,&[de]"),
	/* 0101 0000 */STRING("mov a,&[hl]"), INVALID, INVALID, INVALID,
	/* 0101 0100 */STRING("xch a,&[hl]"), INVALID, INVALID, INVALID,
	/* 0101 1000 */STRING("add a,&[hl]"), STRING("addc a,&[hl]"), STRING("sub a,&[hl]"), STRING("subc a,&[hl]"),
	/* 0101 1100 */STRING("and a,&[hl]"), STRING("xor a,&[hl]"), STRING("or a,&[hl]"), STRING("cmp a,&[hl]"),
	/* 1000 0000 */[0x80] = STRING("mov &[de+],a"),
	/* 1001 0000 */[0x90] = STRING("mov &[hl+],a"),
	/* 1010 0000 */[0xA0] = STRING("mov &[de-],a"),
	/* 1011 0000 */[0xB0] = STRING("mov &[hl-],a"),
	/* 1100 0000 */[0x80] = STRING("mov &[de],a"),
	/* 1101 0000 */[0x90] = STRING("mov &[hl],a")
};

upd_inst sfr[256] = {
	/* 0000 0100 */[0x04] = INVALID, CUSTOM(disasm_ror4_mov_mem1), PREFIX(alt_base), INVALID,
	/* 0000 1000 */INVALID, INVALID, PREFIX(alt_indexed), INVALID,
	/* 0001 0100 */[0x14] = INVALID, INVALID, PREFIX(alt_regind), INVALID,
	/* 0001 1000 */INVALID, INVALID, INVALID, INVALID,
	/* 0001 1100 */INVALID, SFR("addw ax,%s"), SFR("subw ax,%s"), SFR("cmpw ax,%s"),
	/* 0010 0000 */INVALID, SFR("xch a,%s"), INVALID, INVALID,
	/* 0101 0000 */[0x50] = STRING("mov &[de+],a"), STRING("mov &[hl+],a"), STRING("mov &[de-],a"), STRING("mov &[hl-],a"),
	/* 0101 0100 */STRING("mov &[de],a"), STRING("mov &[hl],a"), INVALID, INVALID,
	/* 0101 1000 */STRING("mov a,&[de+]"), STRING("mov a,&[hl+]"), STRING("mov a,&[de-]"), STRING("mov a,&[hl-]"),
	/* 0101 1100 */STRING("mov a,&[de]"), STRING("mov a,&[hl]"), INVALID, INVALID,
	/* 0110 1000 */[0x68] = SFR_BYTE("add %s, #0%XH"), SFR_BYTE("addc %s, #0%XH"), SFR_BYTE("sub %s, #0%XH"), SFR_BYTE("subc %s, #0%XH"),
	/* 0110 1100 */SFR_BYTE("and %s, #0%XH"), SFR_BYTE("xor %s, #0%XH"), SFR_BYTE("or %s, #0%XH"), SFR_BYTE("cmp %s, #0%XH"),
	/* 1001 1000 */[0x98] = SFR("add a,%s"), SFR("addc a,%s"), SFR("sub a,%s"), SFR("subc a,%s"), 
	/* 1001 1100 */SFR("and a,%s"), SFR("xor a,%s"), SFR("or a,%s"), SFR("cmp a,%s")
};
upd_inst bit1[256] = {
	/* 0000 0000 */STRING("mov1 cy,psw.0"), STRING("mov1 cy,psw.1"), STRING("mov1 cy,psw.2"), STRING("mov1 cy,psw.3"),
	/* 0000 0100 */STRING("mov1 cy,psw.4"), STRING("mov1 cy,psw.5"), STRING("mov1 cy,psw.6"), STRING("mov1 cy,psw.7"),
	/* 0000 1000 */INVALID, INVALID, INVALID, INVALID,
	/* 0000 1100 */INVALID, INVALID, INVALID, INVALID,
	/* 0001 0000 */STRING("mov1 psw.0,cy"), STRING("mov1 psw.1,cy"), STRING("mov1 psw.2,cy"), STRING("mov1 psw.3,cy"),
	/* 0001 0100 */STRING("mov1 psw.4,cy"), STRING("mov1 psw.5,cy"), STRING("mov1 psw.6,cy"), STRING("mov1 psw.7,cy"),
	/* 0001 1000 */INVALID, INVALID, INVALID, INVALID,
	/* 0001 1100 */INVALID, INVALID, INVALID, INVALID,
	/* 0010 0000 */STRING("and1 cy,psw.0"), STRING("and1 cy,psw.1"), STRING("and1 cy,psw.2"), STRING("and1 cy,psw.3"),
	/* 0010 0100 */STRING("and1 cy,psw.4"), STRING("and1 cy,psw.5"), STRING("and1 cy,psw.6"), STRING("and1 cy,psw.7"),
	/* 0010 1000 */INVALID, INVALID, INVALID, INVALID,
	/* 0010 1100 */INVALID, INVALID, INVALID, INVALID,
	/* 0011 0000 */STRING("and1 /psw.0,cy"), STRING("and1 /psw.1,cy"), STRING("and1 /psw.2,cy"), STRING("and1 /psw.3,cy"),
	/* 0011 0100 */STRING("and1 /psw.4,cy"), STRING("and1 /psw.5,cy"), STRING("and1 /psw.6,cy"), STRING("and1 /psw.7,cy"),
	/* 0011 1000 */INVALID, INVALID, INVALID, INVALID,
	/* 0011 1100 */INVALID, INVALID, INVALID, INVALID,
	/* 0100 0000 */STRING("or1 cy,psw.0"), STRING("or1 cy,psw.1"), STRING("or1 cy,psw.2"), STRING("or1 cy,psw.3"),
	/* 0100 0100 */STRING("or1 cy,psw.4"), STRING("or1 cy,psw.5"), STRING("or1 cy,psw.6"), STRING("or1 cy,psw.7"),
	/* 0100 1000 */INVALID, INVALID, INVALID, INVALID,
	/* 0100 1100 */INVALID, INVALID, INVALID, INVALID,
	/* 0101 0000 */STRING("or1 /psw.0,cy"), STRING("or1 /psw.1,cy"), STRING("or1 /psw.2,cy"), STRING("or1 /psw.3,cy"),
	/* 0101 0100 */STRING("or1 /psw.4,cy"), STRING("or1 /psw.5,cy"), STRING("or1 /psw.6,cy"), STRING("or1 /psw.7,cy"),
	/* 0101 1000 */INVALID, INVALID, INVALID, INVALID,
	/* 0101 1100 */INVALID, INVALID, INVALID, INVALID,
	/* 0110 0000 */STRING("xor1 cy,psw.0"), STRING("xor1 cy,psw.1"), STRING("xor1 cy,psw.2"), STRING("xor1 cy,psw.3"),
	/* 0110 0100 */STRING("xor1 cy,psw.4"), STRING("xor1 cy,psw.5"), STRING("xor1 cy,psw.6"), STRING("xor1 cy,psw.7"),
	/* 0110 1000 */INVALID, INVALID, INVALID, INVALID,
	/* 0110 1100 */INVALID, INVALID, INVALID, INVALID,
	/* 0111 0000 */STRING("not1 psw.0"), STRING("not1 psw.1"), STRING("not1 psw.2"), STRING("not1 psw.3"),
	/* 0111 0100 */STRING("not1 psw.4"), STRING("not1 psw.5"), STRING("not1 psw.6"), STRING("not1 psw.7"),
	/* 0111 1000 */INVALID, INVALID, INVALID, INVALID,
	/* 0111 1100 */INVALID, INVALID, INVALID, INVALID,
	/* 1000 0000 */STRING("set1 psw.0"), STRING("set1 psw.1"), STRING("set1 psw.2"), STRING("set1 psw.3"),
	/* 1000 0100 */STRING("set1 psw.4"), STRING("set1 psw.5"), STRING("set1 psw.6"), STRING("set1 psw.7"),
	/* 1000 1000 */INVALID, INVALID, INVALID, INVALID,
	/* 1000 1100 */INVALID, INVALID, INVALID, INVALID,
	/* 1001 0000 */STRING("clr1 psw.0"), STRING("clr1 psw.1"), STRING("clr1 psw.2"), STRING("clr1 psw.3"),
	/* 1001 0100 */STRING("clr1 psw.4"), STRING("clr1 psw.5"), STRING("clr1 psw.6"), STRING("clr1 psw.7"),
	/* 1001 1000 */INVALID, INVALID, INVALID, INVALID,
	/* 1001 1100 */INVALID, INVALID, INVALID, INVALID,
	/* 1010 0000 */BRANCH_REL("bf psw.0,$%s"), BRANCH_REL("bf psw.1,$%s"), BRANCH_REL("bf psw.2,$%s"), BRANCH_REL("bf psw.3,$%s"),
	/* 1010 0100 */BRANCH_REL("bf psw.4,$%s"), BRANCH_REL("bf psw.5,$%s"), BRANCH_REL("bf psw.6,$%s"), BRANCH_REL("bf psw.7,$%s"),
	/* 1010 1000 */INVALID, INVALID, INVALID, INVALID,
	/* 1010 1100 */INVALID, INVALID, INVALID, INVALID,
	/* 1011 0000 */BRANCH_REL("bt psw.0,$%s"), BRANCH_REL("bt psw.1,$%s"), BRANCH_REL("bt psw.2,$%s"), BRANCH_REL("bt psw.3,$%s"),
	/* 1011 0100 */BRANCH_REL("bt psw.4,$%s"), BRANCH_REL("bt psw.5,$%s"), BRANCH_REL("bt psw.6,$%s"), BRANCH_REL("bt psw.7,$%s"),
	/* 1011 1000 */INVALID, INVALID, INVALID, INVALID,
	/* 1011 1100 */INVALID, INVALID, INVALID, INVALID,
	/* 1100 0000 */INVALID, INVALID, INVALID, INVALID,
	/* 1100 0100 */INVALID, INVALID, INVALID, INVALID,
	/* 1100 1000 */INVALID, INVALID, INVALID, INVALID,
	/* 1100 1100 */INVALID, INVALID, INVALID, INVALID,
	/* 1101 0000 */BRANCH_REL("btclr psw.0,$%s"), BRANCH_REL("btclr psw.1,$%s"), BRANCH_REL("btclr psw.2,$%s"), BRANCH_REL("btclr psw.3,$%s"),
	/* 1101 0100 */BRANCH_REL("btclr psw.4,$%s"), BRANCH_REL("btclr psw.5,$%s"), BRANCH_REL("btclr psw.6,$%s"), BRANCH_REL("btclr psw.7,$%s")
};
upd_inst bit2[256] = {
	/* 0000 0000 */STRING("mov1 cy,x.0"), STRING("mov1 cy,x.1"), STRING("mov1 cy,x.2"), STRING("mov1 cy,x.3"),
	/* 0000 0100 */STRING("mov1 cy,x.4"), STRING("mov1 cy,x.5"), STRING("mov1 cy,x.6"), STRING("mov1 cy,x.7"),
	/* 0000 1000 */STRING("mov1 cy,a.0"), STRING("mov1 cy,a.1"), STRING("mov1 cy,a.2"), STRING("mov1 cy,a.3"),
	/* 0000 1100 */STRING("mov1 cy,a.4"), STRING("mov1 cy,a.5"), STRING("mov1 cy,a.6"), STRING("mov1 cy,a.7"),
	/* 0001 0000 */STRING("mov1 x.0,cy"), STRING("mov1 x.1,cy"), STRING("mov1 x.2,cy"), STRING("mov1 x.3,cy"),
	/* 0001 0100 */STRING("mov1 x.4,cy"), STRING("mov1 x.5,cy"), STRING("mov1 x.6,cy"), STRING("mov1 x.7,cy"),
	/* 0001 1000 */STRING("mov1 a.0,cy"), STRING("mov1 a.1,cy"), STRING("mov1 a.2,cy"), STRING("mov1 a.3,cy"),
	/* 0001 1100 */STRING("mov1 a.4,cy"), STRING("mov1 a.5,cy"), STRING("mov1 a.6,cy"), STRING("mov1 a.7,cy"),
	/* 0010 0000 */STRING("and1 cy,x.0"), STRING("and1 cy,x.1"), STRING("and1 cy,x.2"), STRING("and1 cy,x.3"),
	/* 0010 0100 */STRING("and1 cy,x.4"), STRING("and1 cy,x.5"), STRING("and1 cy,x.6"), STRING("and1 cy,x.7"),
	/* 0010 1000 */STRING("and1 cy,a.0"), STRING("and1 cy,a.1"), STRING("and1 cy,a.2"), STRING("and1 cy,a.3"),
	/* 0010 1100 */STRING("and1 cy,a.4"), STRING("and1 cy,a.5"), STRING("and1 cy,a.6"), STRING("and1 cy,a.7"),
	/* 0011 0000 */STRING("and1 cy,/x.0"), STRING("and1 cy,/x.1"), STRING("and1 cy,/x.2"), STRING("and1 cy,/x.3"),
	/* 0011 0100 */STRING("and1 cy,/x.4"), STRING("and1 cy,/x.5"), STRING("and1 cy,/x.6"), STRING("and1 cy,/x.7"),
	/* 0011 1000 */STRING("and1 cy,/a.0"), STRING("and1 cy,/a.1"), STRING("and1 cy,/a.2"), STRING("and1 cy,/a.3"),
	/* 0011 1100 */STRING("and1 cy,/a.4"), STRING("and1 cy,/a.5"), STRING("and1 cy,/a.6"), STRING("and1 cy,/a.7"),
	/* 0100 0000 */STRING("or1 cy,x.0"), STRING("or1 cy,x.1"), STRING("or1 cy,x.2"), STRING("or1 cy,x.3"),
	/* 0100 0100 */STRING("or1 cy,x.4"), STRING("or1 cy,x.5"), STRING("or1 cy,x.6"), STRING("or1 cy,x.7"),
	/* 0100 1000 */STRING("or1 cy,a.0"), STRING("or1 cy,a.1"), STRING("or1 cy,a.2"), STRING("or1 cy,a.3"),
	/* 0100 1100 */STRING("or1 cy,a.4"), STRING("or1 cy,a.5"), STRING("or1 cy,a.6"), STRING("or1 cy,a.7"),
	/* 0101 0000 */STRING("or1 cy,/x.0"), STRING("or1 cy,/x.1"), STRING("or1 cy,/x.2"), STRING("or1 cy,/x.3"),
	/* 0101 0100 */STRING("or1 cy,/x.4"), STRING("or1 cy,/x.5"), STRING("or1 cy,/x.6"), STRING("or1 cy,/x.7"),
	/* 0101 1000 */STRING("or1 cy,/a.0"), STRING("or1 cy,/a.1"), STRING("or1 cy,/a.2"), STRING("or1 cy,/a.3"),
	/* 0101 1100 */STRING("or1 cy,/a.4"), STRING("or1 cy,/a.5"), STRING("or1 cy,/a.6"), STRING("or1 cy,/a.7"),
	/* 0110 0000 */STRING("xor1 cy,x.0"), STRING("xor1 cy,x.1"), STRING("xor1 cy,x.2"), STRING("xor1 cy,x.3"),
	/* 0110 0100 */STRING("xor1 cy,x.4"), STRING("xor1 cy,x.5"), STRING("xor1 cy,x.6"), STRING("xor1 cy,x.7"),
	/* 0110 1000 */STRING("xor1 cy,a.0"), STRING("xor1 cy,a.1"), STRING("xor1 cy,a.2"), STRING("xor1 cy,a.3"),
	/* 0110 1100 */STRING("xor1 cy,a.4"), STRING("xor1 cy,a.5"), STRING("xor1 cy,a.6"), STRING("xor1 cy,a.7"),
	/* 0111 0000 */STRING("not1 x.0"), STRING("not1 x.1"), STRING("not1 x.2"), STRING("not1 x.3"),
	/* 0111 0100 */STRING("not1 x.4"), STRING("not1 x.5"), STRING("not1 x.6"), STRING("not1 x.7"),
	/* 0111 1000 */STRING("not1 a.0"), STRING("not1 a.1"), STRING("not1 a.2"), STRING("not1 a.3"),
	/* 0111 1100 */STRING("not1 a.4"), STRING("not1 a.5"), STRING("not1 a.6"), STRING("not1 a.7"),
	/* 1000 0000 */STRING("set1 x.0"), STRING("set1 x.1"), STRING("set1 x.2"), STRING("set1 x.3"),
	/* 1000 0100 */STRING("set1 x.4"), STRING("set1 x.5"), STRING("set1 x.6"), STRING("set1 x.7"),
	/* 1000 1000 */STRING("set1 a.0"), STRING("set1 a.1"), STRING("set1 a.2"), STRING("set1 a.3"),
	/* 1000 1100 */STRING("set1 a.4"), STRING("set1 a.5"), STRING("set1 a.6"), STRING("set1 a.7"),
	/* 1001 0000 */STRING("clr1 x.0"), STRING("clr1 x.1"), STRING("clr1 x.2"), STRING("clr1 x.3"),
	/* 1001 0100 */STRING("clr1 x.4"), STRING("clr1 x.5"), STRING("clr1 x.6"), STRING("clr1 x.7"),
	/* 1001 1000 */STRING("clr1 a.0"), STRING("clr1 a.1"), STRING("clr1 a.2"), STRING("clr1 a.3"),
	/* 1001 1100 */STRING("clr1 a.4"), STRING("clr1 a.5"), STRING("clr1 a.6"), STRING("clr1 a.7"),
	/* 1010 0000 */BRANCH_REL("bf x.0,$%s"), BRANCH_REL("bf x.1,$%s"), BRANCH_REL("bf x.2,$%s"), BRANCH_REL("bf x.3,$%s"),
	/* 1010 0100 */BRANCH_REL("bf x.4,$%s"), BRANCH_REL("bf x.5,$%s"), BRANCH_REL("bf x.6,$%s"), BRANCH_REL("bf x.7,$%s"),
	/* 1010 1000 */BRANCH_REL("bf a.0,$%s"), BRANCH_REL("bf a.1,$%s"), BRANCH_REL("bf a.2,$%s"), BRANCH_REL("bf a.3,$%s"),
	/* 1010 1100 */BRANCH_REL("bf a.4,$%s"), BRANCH_REL("bf a.5,$%s"), BRANCH_REL("bf a.6,$%s"), BRANCH_REL("bf a.7,$%s"),
	/* 1011 0000 */BRANCH_REL("bt x.0,$%s"), BRANCH_REL("bt x.1,$%s"), BRANCH_REL("bt x.2,$%s"), BRANCH_REL("bt x.3,$%s"),
	/* 1011 0100 */BRANCH_REL("bt x.4,$%s"), BRANCH_REL("bt x.5,$%s"), BRANCH_REL("bt x.6,$%s"), BRANCH_REL("bt x.7,$%s"),
	/* 1011 1000 */BRANCH_REL("bt a.0,$%s"), BRANCH_REL("bt a.1,$%s"), BRANCH_REL("bt a.2,$%s"), BRANCH_REL("bt a.3,$%s"),
	/* 1011 1100 */BRANCH_REL("bt a.4,$%s"), BRANCH_REL("bt a.5,$%s"), BRANCH_REL("bt a.6,$%s"), BRANCH_REL("bt a.7,$%s"),
	/* 1100 0000 */INVALID, INVALID, INVALID, INVALID,
	/* 1100 0100 */INVALID, INVALID, INVALID, INVALID,
	/* 1100 1000 */INVALID, INVALID, INVALID, INVALID,
	/* 1100 1100 */INVALID, INVALID, INVALID, INVALID,
	/* 1101 0000 */BRANCH_REL("btclr x.0,$%s"), BRANCH_REL("btclr x.1,$%s"), BRANCH_REL("btclr x.2,$%s"), BRANCH_REL("btclr x.3,$%s"),
	/* 1101 0100 */BRANCH_REL("btclr x.4,$%s"), BRANCH_REL("btclr x.5,$%s"), BRANCH_REL("btclr x.6,$%s"), BRANCH_REL("btclr x.7,$%s"),
	/* 1101 1000 */BRANCH_REL("btclr a.0,$%s"), BRANCH_REL("btclr a.1,$%s"), BRANCH_REL("btclr a.2,$%s"), BRANCH_REL("btclr a.3,$%s"),
	/* 1101 1100 */BRANCH_REL("btclr a.4,$%s"), BRANCH_REL("btclr a.5,$%s"), BRANCH_REL("btclr a.6,$%s"), BRANCH_REL("btclr a.7,$%s"),
};
upd_inst muldiv[256] = {
	/* 0000 1000 */[0x08] = STRING("mulu x"), STRING("mulu a"), STRING("mulu c"), STRING("mulu b"),
	/* 0000 1100 */STRING("mulu e"), STRING("mulu d"), STRING("mulu l"), STRING("mulu h"),
	/* 0001 1000 */[0x18] = STRING("divuw x"), STRING("divuw a"), STRING("divuw c"), STRING("divuw b"),
	/* 0001 1100 */STRING("divuw e"), STRING("divuw d"), STRING("divuw l"), STRING("divuw h"),
	/* 0100 1000 */[0x48] = STRING("br ax"), INVALID, STRING("br bc"), INVALID,
	/* 0100 1100 */STRING("br de"), INVALID, STRING("br hl"), INVALID,
	/* 0101 1000 */[0x58] = STRING("call ax"), INVALID, STRING("call bc"), INVALID,
	/* 0101 1100 */STRING("call de"), INVALID, STRING("call hl"), INVALID,
	/* 1000 1100 */[0x8C] = STRING("ror4 [de]"), INVALID, STRING("ror4 [hl]"), INVALID,
	/* 1001 1100 */[0x9C] = STRING("rol4 [de]"), INVALID, STRING("rol4 [hl]"), INVALID,
	/* 1010 1000 */[0xA8] = STRING("sel rb0"), STRING("sel rb1"), STRING("sel rb2"), STRING("sel rb3"),
	/* 1100 1000 */[0xC8] = STRING("incw sp"), STRING("decw sp"),
	/* 1110 0010 */[0xE2] = STRING("movw ax,[de]"), STRING("movw ax,[hl]"),
	/* 1110 0110 */[0xE6] = STRING("movw [de],ax"), STRING("movw [hl],ax")
};
upd_inst base[256] = {
	/* 0000 0000 */BASE("mov a,[de+0%XH]"), INVALID, INVALID, INVALID,
	/* 0000 0100 */BASE("xch a,[de+0%XH]"), INVALID, INVALID, INVALID,
	/* 0000 1000 */BASE("add a,[de+0%XH]"), BASE("addc a,[de+0%XH]"), BASE("sub a,[de+0%XH]"), BASE("subc a,[de+0%XH]"),
	/* 0000 1100 */BASE("and a,[de+0%XH]"), BASE("xor a,[de+0%XH]"), BASE("or a,[de+0%XH]"), BASE("cmp a,[de+0%XH]"),
	/* 0001 0000 */BASE("mov a,[sp+0%XH]"), INVALID, INVALID, INVALID,
	/* 0001 0100 */BASE("xch a,[sp+0%XH]"), INVALID, INVALID, INVALID,
	/* 0001 1000 */BASE("add a,[sp+0%XH]"), BASE("addc a,[sp+0%XH]"), BASE("sub a,[sp+0%XH]"), BASE("subc a,[sp+0%XH]"),
	/* 0001 1100 */BASE("and a,[sp+0%XH]"), BASE("xor a,[sp+0%XH]"), BASE("or a,[sp+0%XH]"), BASE("cmp a,[sp+0%XH]"),
	/* 0010 0000 */BASE("mov a,[hl+0%XH]"), INVALID, INVALID, INVALID,
	/* 0010 0100 */BASE("xch a,[hl+0%XH]"), INVALID, INVALID, INVALID,
	/* 0010 1000 */BASE("add a,[hl+0%XH]"), BASE("addc a,[hl+0%XH]"), BASE("sub a,[hl+0%XH]"), BASE("subc a,[hl+0%XH]"),
	/* 0010 1100 */BASE("and a,[hl+0%XH]"), BASE("xor a,[hl+0%XH]"), BASE("or a,[hl+0%XH]"), BASE("cmp a,[hl+0%XH]"),
	/* 1000 0000 */[0x80] = BASE("mov [de+0%XH],a"),
	/* 1001 0000 */[0x90] = BASE("mov [sp+0%XH],a"),
	/* 1010 0000 */[0xA0] = BASE("mov [hl+0%XH],a")
};
upd_inst sfrbit[256] = {
	/* 0000 0000 */SADDR("mov1 cy,%s.0"), SADDR("mov1 cy,%s.1"), SADDR("mov1 cy,%s.2"), SADDR("mov1 cy,%s.3"),
	/* 0000 0100 */SADDR("mov1 cy,%s.4"), SADDR("mov1 cy,%s.5"), SADDR("mov1 cy,%s.6"), SADDR("mov1 cy,%s.7"),
	/* 0000 1000 */SFR("mov1 cy,%s.0"), SFR("mov1 cy,%s.1"), SFR("mov1 cy,%s.2"), SFR("mov1 cy,%s.3"),
	/* 0000 1100 */SFR("mov1 cy,%s.4"), SFR("mov1 cy,%s.5"), SFR("mov1 cy,%s.6"), SFR("mov1 cy,%s.7"),
	/* 0001 0000 */SADDR("mov1 %s.0,cy"), SADDR("mov1 %s.1,cy"), SADDR("mov1 %s.2,cy"), SADDR("mov1 %s.3,cy"),
	/* 0001 0100 */SADDR("mov1 %s.4,cy"), SADDR("mov1 %s.5,cy"), SADDR("mov1 %s.6,cy"), SADDR("mov1 %s.7,cy"),
	/* 0001 1000 */SFR("mov1 %s.0,cy"), SFR("mov1 %s.1,cy"), SFR("mov1 %s.2,cy"), SFR("mov1 %s.3,cy"),
	/* 0001 1100 */SFR("mov1 %s.4,cy"), SFR("mov1 %s.5,cy"), SFR("mov1 %s.6,cy"), SFR("mov1 %s.7,cy"),
	/* 0010 0000 */SADDR("and1 cy,%s.0"), SADDR("and1 cy,%s.1"), SADDR("and1 cy,%s.2"), SADDR("and1 cy,%s.3"),
	/* 0010 0100 */SADDR("and1 cy,%s.4"), SADDR("and1 cy,%s.5"), SADDR("and1 cy,%s.6"), SADDR("and1 cy,%s.7"),
	/* 0010 1000 */SFR("and1 cy,%s.0"), SFR("and1 cy,%s.1"), SFR("and1 cy,%s.2"), SFR("and1 cy,%s.3"),
	/* 0010 1100 */SFR("and1 cy,%s.4"), SFR("and1 cy,%s.5"), SFR("and1 cy,%s.6"), SFR("and1 cy,%s.7"),
	/* 0011 0000 */SADDR("and1 cy,/%s.0"), SADDR("and1 cy,/%s.1"), SADDR("and1 cy,/%s.2"), SADDR("and1 cy,/%s.3"),
	/* 0011 0100 */SADDR("and1 cy,/%s.4"), SADDR("and1 cy,/%s.5"), SADDR("and1 cy,/%s.6"), SADDR("and1 cy,/%s.7"),
	/* 0011 1000 */SFR("and1 cy,/%s.0"), SFR("and1 cy,/%s.1"), SFR("and1 cy,/%s.2"), SFR("and1 cy,/%s.3"),
	/* 0011 1100 */SFR("and1 cy,/%s.4"), SFR("and1 cy,/%s.5"), SFR("and1 cy,/%s.6"), SFR("and1 cy,/%s.7"),
	/* 0100 0000 */SADDR("or1 cy,%s.0"), SADDR("or1 cy,%s.1"), SADDR("or1 cy,%s.2"), SADDR("or1 cy,%s.3"),
	/* 0100 0100 */SADDR("or1 cy,%s.4"), SADDR("or1 cy,%s.5"), SADDR("or1 cy,%s.6"), SADDR("or1 cy,%s.7"),
	/* 0100 1000 */SFR("or1 cy,%s.0"), SFR("or1 cy,%s.1"), SFR("or1 cy,%s.2"), SFR("or1 cy,%s.3"),
	/* 0100 1100 */SFR("or1 cy,%s.4"), SFR("or1 cy,%s.5"), SFR("or1 cy,%s.6"), SFR("or1 cy,%s.7"),
	/* 0101 0000 */SADDR("or1 cy,/%s.0"), SADDR("or1 cy,/%s.1"), SADDR("or1 cy,/%s.2"), SADDR("or1 cy,/%s.3"),
	/* 0101 0100 */SADDR("or1 cy,/%s.4"), SADDR("or1 cy,/%s.5"), SADDR("or1 cy,/%s.6"), SADDR("or1 cy,/%s.7"),
	/* 0101 1000 */SFR("or1 cy,/%s.0"), SFR("or1 cy,/%s.1"), SFR("or1 cy,/%s.2"), SFR("or1 cy,/%s.3"),
	/* 0101 1100 */SFR("or1 cy,/%s.4"), SFR("or1 cy,/%s.5"), SFR("or1 cy,/%s.6"), SFR("or1 cy,/%s.7"),
	/* 0110 0000 */SADDR("xor1 cy,%s.0"), SADDR("xor1 cy,%s.1"), SADDR("xor1 cy,%s.2"), SADDR("xor1 cy,%s.3"),
	/* 0110 0100 */SADDR("xor1 cy,%s.4"), SADDR("xor1 cy,%s.5"), SADDR("xor1 cy,%s.6"), SADDR("xor1 cy,%s.7"),
	/* 0110 1000 */SFR("xor1 cy,%s.0"), SFR("xor1 cy,%s.1"), SFR("xor1 cy,%s.2"), SFR("xor1 cy,%s.3"),
	/* 0110 1100 */SFR("xor1 cy,%s.4"), SFR("xor1 cy,%s.5"), SFR("xor1 cy,%s.6"), SFR("xor1 cy,%s.7"),
	/* 0111 0000 */SADDR("not1 %s.0"), SADDR("not1 %s.1"), SADDR("not1 %s.2"), SADDR("not1 %s.3"),
	/* 0111 0100 */SADDR("not1 %s.4"), SADDR("not1 %s.5"), SADDR("not1 %s.6"), SADDR("not1 %s.7"),
	/* 0111 1000 */SFR("not1 %s.0"), SFR("not1 %s.1"), SFR("not1 %s.2"), SFR("not1 %s.3"),
	/* 0111 1100 */SFR("not1 %s.4"), SFR("not1 %s.5"), SFR("not1 %s.6"), SFR("not1 %s.7"),
	/* 1000 0000 */SADDR("set1 %s.0"), SADDR("set1 %s.1"), SADDR("set1 %s.2"), SADDR("set1 %s.3"),
	/* 1000 0100 */SADDR("set1 %s.4"), SADDR("set1 %s.5"), SADDR("set1 %s.6"), SADDR("set1 %s.7"),
	/* 1000 1000 */SFR("set1 %s.0"), SFR("set1 %s.1"), SFR("set1 %s.2"), SFR("set1 %s.3"),
	/* 1000 1100 */SFR("set1 %s.4"), SFR("set1 %s.5"), SFR("set1 %s.6"), SFR("set1 %s.7"),
	/* 1001 0000 */SADDR("clr1 %s.0"), SADDR("clr1 %s.1"), SADDR("clr1 %s.2"), SADDR("clr1 %s.3"),
	/* 1001 0100 */SADDR("clr1 %s.4"), SADDR("clr1 %s.5"), SADDR("clr1 %s.6"), SADDR("clr1 %s.7"),
	/* 1001 1000 */SFR("clr1 %s.0"), SFR("clr1 %s.1"), SFR("clr1 %s.2"), SFR("clr1 %s.3"),
	/* 1001 1100 */SFR("clr1 %s.4"), SFR("clr1 %s.5"), SFR("clr1 %s.6"), SFR("clr1 %s.7"),
	/* 1010 0000 */BRANCH_SADDR("bf %s.0,$%s"), BRANCH_SADDR("bf %s.1,$%s"), BRANCH_SADDR("bf %s.2,$%s"), BRANCH_SADDR("bf %s.3,$%s"),
	/* 1010 0100 */BRANCH_SADDR("bf %s.4,$%s"), BRANCH_SADDR("bf %s.5,$%s"), BRANCH_SADDR("bf %s.6,$%s"), BRANCH_SADDR("bf %s.7,$%s"),
	/* 1010 1000 */BRANCH_SFR("bf %s.0,$%s"), BRANCH_SFR("bf %s.1,$%s"), BRANCH_SFR("bf %s.2,$%s"), BRANCH_SFR("bf %s.3,$%s"),
	/* 1010 1100 */BRANCH_SFR("bf %s.4,$%s"), BRANCH_SFR("bf %s.5,$%s"), BRANCH_SFR("bf %s.6,$%s"), BRANCH_SFR("bf %s.7,$%s"),
	/* 1011 1000 */[0xB8] = BRANCH_SFR("bt %s.0,$%s"), BRANCH_SFR("bt %s.1,$%s"), BRANCH_SFR("bt %s.2,$%s"), BRANCH_SFR("bt %s.3,$%s"),
	/* 1011 1100 */BRANCH_SFR("bt %s.4,$%s"), BRANCH_SFR("bt %s.5,$%s"), BRANCH_SFR("bt %s.6,$%s"), BRANCH_SFR("bt %s.7,$%s"),
	/* 1101 0000 */[0xD0] = BRANCH_SADDR("btclr %s.0,$%s"), BRANCH_SADDR("btclr %s.1,$%s"), BRANCH_SADDR("btclr %s.2,$%s"), BRANCH_SADDR("btclr %s.3,$%s"),
	/* 1101 0100 */BRANCH_SADDR("btclr %s.4,$%s"), BRANCH_SADDR("btclr %s.5,$%s"), BRANCH_SADDR("btclr %s.6,$%s"), BRANCH_SADDR("btclr %s.7,$%s"),
	/* 1101 1000 */BRANCH_SFR("btclr %s.0,$%s"), BRANCH_SFR("btclr %s.1,$%s"), BRANCH_SFR("btclr %s.2,$%s"), BRANCH_SFR("btclr %s.3,$%s"),
	/* 1101 1100 */BRANCH_SFR("btclr %s.4,$%s"), BRANCH_SFR("btclr %s.5,$%s"), BRANCH_SFR("btclr %s.6,$%s"), BRANCH_SFR("btclr %s.7,$%s"),
};
upd_inst spmov[256] = {
	[0xC0] = CUSTOM(disasm_mov_stbc),
	[0xF0] = ADDR16("mov a,!%s"), ADDR16("mov !%s,a")
};
upd_inst indexed[256] = {
	/* 0000 0000 */INDEXED("mov a,0%XH[de]"), INVALID, INVALID, INVALID,
	/* 0000 0100 */INDEXED("xch a,0%XH[de]"), INVALID, INVALID, INVALID,
	/* 0000 1000 */INDEXED("add a,0%XH[de]"), INDEXED("addc a,0%XH[de]"), INDEXED("sub a,0%XH[de]"), INDEXED("subc a,0%XH[de]"),
	/* 0000 1100 */INDEXED("and a,0%XH[de]"), INDEXED("xor a,0%XH[de]"), INDEXED("or a,0%XH[de]"), INDEXED("cmp a,0%XH[de]"),
	/* 0001 0000 */INDEXED("mov a,0%XH[a]"), INVALID, INVALID, INVALID,
	/* 0001 0100 */INDEXED("xch a,0%XH[a]"), INVALID, INVALID, INVALID,
	/* 0001 1000 */INDEXED("add a,0%XH[a]"), INDEXED("addc a,0%XH[a]"), INDEXED("sub a,0%XH[a]"), INDEXED("subc a,0%XH[a]"),
	/* 0001 1100 */INDEXED("and a,0%XH[a]"), INDEXED("xor a,0%XH[a]"), INDEXED("or a,0%XH[a]"), INDEXED("cmp a,0%XH[a]"),
	/* 0010 0000 */INDEXED("mov a,0%XH[hl]"), INVALID, INVALID, INVALID,
	/* 0010 0100 */INDEXED("xch a,0%XH[hl]"), INVALID, INVALID, INVALID,
	/* 0010 1000 */INDEXED("add a,0%XH[hl]"), INDEXED("addc a,0%XH[hl]"), INDEXED("sub a,0%XH[hl]"), INDEXED("subc a,0%XH[hl]"),
	/* 0010 1100 */INDEXED("and a,0%XH[hl]"), INDEXED("xor a,0%XH[hl]"), INDEXED("or a,0%XH[hl]"), INDEXED("cmp a,0%XH[hl]"),
	/* 0011 0000 */INDEXED("mov a,0%XH[b]"), INVALID, INVALID, INVALID,
	/* 0011 0100 */INDEXED("xch a,0%XH[b]"), INVALID, INVALID, INVALID,
	/* 0011 1000 */INDEXED("add a,0%XH[b]"), INDEXED("addc a,0%XH[b]"), INDEXED("sub a,0%XH[b]"), INDEXED("subc a,0%XH[b]"),
	/* 0011 1100 */INDEXED("and a,0%XH[b]"), INDEXED("xor a,0%XH[b]"), INDEXED("or a,0%XH[b]"), INDEXED("cmp a,0%XH[b]"),
	/* 1000 0000 */[0x80] = INDEXED("mov 0%XH[de],a"),
	/* 1001 0000 */[0x90] = INDEXED("mov 0%XH[a],a"),
	/* 1010 0000 */[0xA0] = INDEXED("mov 0%XH[hl],a"),
	/* 1011 0000 */[0xB0] = INDEXED("mov 0%XH[b],a")
};
upd_inst regind[256] = {
	/* 0000 0000 */STRING("mov a,[de+]"), INVALID, INVALID, INVALID,
	/* 0000 0100 */STRING("xch a,[de+]"), INVALID, INVALID, INVALID,
	/* 0000 1000 */STRING("add a,[de+]"), STRING("addc a,[de+]"), STRING("sub a,[de+]"), STRING("subc a,[de+]"),
	/* 0000 1100 */STRING("and a,[de+]"), STRING("xor a,[de+]"), STRING("or a,[de+]"), STRING("cmp a,[de+]"),
	/* 0001 0000 */STRING("mov a,[hl+]"), INVALID, INVALID, INVALID,
	/* 0001 0100 */STRING("xch a,[hl+]"), INVALID, INVALID, INVALID,
	/* 0001 1000 */STRING("add a,[hl+]"), STRING("addc a,[hl+]"), STRING("sub a,[hl+]"), STRING("subc a,[hl+]"),
	/* 0001 1100 */STRING("and a,[hl+]"), STRING("xor a,[hl+]"), STRING("or a,[hl+]"), STRING("cmp a,[hl+]"),
	/* 0010 0000 */STRING("mov a,[de-]"), INVALID, INVALID, INVALID,
	/* 0010 0100 */STRING("xch a,[de-]"), INVALID, INVALID, INVALID,
	/* 0010 1000 */STRING("add a,[de-]"), STRING("addc a,[de-]"), STRING("sub a,[de-]"), STRING("subc a,[de-]"),
	/* 0010 1100 */STRING("and a,[de-]"), STRING("xor a,[de-]"), STRING("or a,[de-]"), STRING("cmp a,[de-]"),
	/* 0011 0000 */STRING("mov a,[hl-]"), INVALID, INVALID, INVALID,
	/* 0011 0100 */STRING("xch a,[hl-]"), INVALID, INVALID, INVALID,
	/* 0011 1000 */STRING("add a,[hl-]"), STRING("addc a,[hl-]"), STRING("sub a,[hl-]"), STRING("subc a,[hl-]"),
	/* 0011 1100 */STRING("and a,[hl-]"), STRING("xor a,[hl-]"), STRING("or a,[hl-]"), STRING("cmp a,[hl-]"),
	/* 0100 0000 */STRING("mov a,[de]"), INVALID, INVALID, INVALID,
	/* 0100 0100 */STRING("xch a,[de]"), INVALID, INVALID, INVALID,
	/* 0100 1000 */STRING("add a,[de]"), STRING("addc a,[de]"), STRING("sub a,[de]"), STRING("subc a,[de]"),
	/* 0100 1100 */STRING("and a,[de]"), STRING("xor a,[de]"), STRING("or a,[de]"), STRING("cmp a,[de]"),
	/* 0101 0000 */STRING("mov a,[hl]"), INVALID, INVALID, INVALID,
	/* 0101 0100 */STRING("xch a,[hl]"), INVALID, INVALID, INVALID,
	/* 0101 1000 */STRING("add a,[hl]"), STRING("addc a,[hl]"), STRING("sub a,[hl]"), STRING("subc a,[hl]"),
	/* 0101 1100 */STRING("and a,[hl]"), STRING("xor a,[hl]"), STRING("or a,[hl]"), STRING("cmp a,[hl]"),
	/* 1000 0000 */[0x80] = STRING("mov [de+],a"),
	/* 1001 0000 */[0x90] = STRING("mov [hl+],a"),
	/* 1010 0000 */[0xA0] = STRING("mov [de-],a"),
	/* 1011 0000 */[0xB0] = STRING("mov [hl-],a"),
	/* 1100 0000 */[0x80] = STRING("mov [de],a"),
	/* 1101 0000 */[0x90] = STRING("mov [hl],a")
};

upd_inst maint[256] = {
	/* 0000 0000 */STRING("nop"), PREFIX(sfr), PREFIX(bit1), PREFIX(bit2),
	/* 0000 0100 */INVALID, PREFIX(muldiv), PREFIX(base), INVALID,
	/* 0000 1000 */PREFIX(sfrbit), PREFIX(spmov), PREFIX(indexed), CUSTOM(disasm_sfr_mov16),
	/* 0000 1100 */SADDR_WORD("movw %s, #0%XH"), INVALID, STRING("adjba"), STRING("adjbs"),
	/* 0001 0000 */CUSTOM(disasm_mov_a_sfr), CUSTOM(disasm_movw_ax_sfr), CUSTOM(disasm_mov_sfr_a), CUSTOM(disasm_movw_sfr_ax),
	/* 0001 0100 */BRANCH_REL("br $%s"), INVALID, PREFIX(regind), INVALID, 
	/* 0001 1000 */INVALID, INVALID, SADDR("movw %s,ax"), INVALID,
	/* 0001 1100 */SADDR("movw ax,%s"), SADDR("addw ax,%s"), SADDR("subw ax,%s"), SADDR("cmpw ax,%s"),
	/* 0010 0000 */SADDR("mov a,%s"), SADDR("xch a,%s"), SADDR("mov %s,a"), INVALID,
	/* 0010 0100 */CUSTOM(disasm_mov_r_r), REG_REG("mov %c,%c"), SADDR("inc %s"), SADDR("dec %s"),
	/* 0010 1000 */BRANCH_ABS("call !%s"), SFR("push %s"), SFR("pop %s"), CUSTOM(disasm_mov_sfr_byte),
	/* 0010 1100 */BRANCH_ABS("br !%s"), WORD("addw ax,#0%XH"), WORD("subw ax,#0%XH"), WORD("cmpw ax,#0%XH"),
	/* 0011 0000 */CUSTOM(disasm_shift_right), CUSTOM(disasm_shift_left), BRANCH_REL("dbnz c,$%s"), BRANCH_REL("dbnz b,$%s"),
	/* 0011 0100 */STRING("pop ax"), STRING("pop bc"), STRING("pop de"), STRING("pop hl"),
	/* 0011 1000 */SADDR_SADDR("mov %s,%s"), SADDR_SADDR("xch %s,%s"), SADDR_BYTE("mov %s, #0%XH"), BRANCH_SADDR("dbnz %s,$%s"),
	/* 0011 1100 */STRING("push ax"), STRING("push bc"), STRING("push de"), STRING("push hl"),
	/* 0100 0000 */STRING("clr1 cy"), STRING("set1 cy"), STRING("not1 cy"), SFR("pop %s"),
	/* 0100 0100 */STRING("incw ax"), STRING("incw bc"), STRING("incw de"), STRING("incw hl"),
	/* 0100 1000 */STRING("pop psw"), STRING("push psw"), STRING("di"), STRING("ei"),
	/* 0100 1100 */STRING("decw ax"), STRING("decw bc"), STRING("decw de"), STRING("decw hl"),
	/* 0101 0000 */STRING("mov [de+],a"), STRING("mov [hl+],a"), STRING("mov [de-],a"), STRING("mov [hl-],a"),
	/* 0101 0100 */STRING("mov [de],a"), STRING("mov [hl],a"), STRING("ret"), STRING("reti"),
	/* 0101 1000 */STRING("mov a,[de+]"), STRING("mov a,[hl+]"), STRING("mov a,[de-]"), STRING("mov a,[hl-]"),
	/* 0101 1100 */STRING("mov a,[de]"), STRING("mov a,[hl]"), STRING("brk"), STRING("retb"),
	/* 0110 0000 */WORD("movw ax,#0%XH"), INVALID, WORD("movw bc,#0%XH"), INVALID,
	/* 0110 0100 */WORD("movw de,#0%XH"), INVALID, WORD("movw hl,#0%XH"), INVALID,
	/* 0110 1000 */SADDR_BYTE("add %s, #0%XH"), SADDR_BYTE("addc %s, #0%XH"), SADDR_BYTE("sub %s, #0%XH"), SADDR_BYTE("subc %s, #0%XH"),
	/* 0110 1100 */SADDR_BYTE("and %s, #0%XH"), SADDR_BYTE("xor %s, #0%XH"), SADDR_BYTE("or %s, #0%XH"), SADDR_BYTE("cmp %s, #0%XH"),
	/* 0111 0000 */BRANCH_SADDR("bt %s.0,%s"), BRANCH_SADDR("bt %s.1,%s"), BRANCH_SADDR("bt %s.2,%s"), BRANCH_SADDR("bt %s.3,%s"),
	/* 0111 0100 */BRANCH_SADDR("bt %s.4,%s"), BRANCH_SADDR("bt %s.5,%s"), BRANCH_SADDR("bt %s.6,%s"), BRANCH_SADDR("bt %s.7,%s"),
	/* 0111 1000 */SADDR_SADDR("add %s,%s"), SADDR_SADDR("addc %s,%s"), SADDR_SADDR("sub %s,%s"), SADDR_SADDR("subc %s,%s"),
	/* 0111 1100 */SADDR_SADDR("and %s,%s"), SADDR_SADDR("xor %s,%s"), SADDR_SADDR("or %s,%s"), SADDR_SADDR("cmp %s,%s"),
	/* 1000 0000 */BRANCH_REL("bnz $%s"), BRANCH_REL("bz $%s"), BRANCH_REL("bnc $%s"), BRANCH_REL("bc $%s"),
	/* 1000 0100 */INVALID, INVALID, INVALID, INVALID,
	/* 1000 1000 */CUSTOM(disasm_add_r_r), REG_REG("addc %c,%c"), CUSTOM(disasm_sub_r_r), REG_REG("subc %c,%c"),
	/* 1000 1100 */REG_REG("and %c,%c"), REG_REG("xor %c,%c"), REG_REG("or %c,%c"), CUSTOM(disasm_cmp_r_r),
	/* 1001 0000 */CALLF, CALLF, CALLF, CALLF,
	/* 1001 0100 */CALLF, CALLF, CALLF, CALLF,
	/* 1001 1000 */SADDR("add a,%s"), SADDR("addc a,%s"), SADDR("sub a,%s"), SADDR("subc a,%s"), 
	/* 1001 1100 */SADDR("and a,%s"), SADDR("xor a,%s"), SADDR("or a,%s"), SADDR("cmp a,%s"),
	/* 1010 0000 */SADDR("clr1 %s.0"), SADDR("clr1 %s.1"), SADDR("clr1 %s.2"), SADDR("clr1 %s.3"),
	/* 1010 0100 */SADDR("clr1 %s.4"), SADDR("clr1 %s.5"), SADDR("clr1 %s.6"), SADDR("clr1 %s.7"),
	/* 1010 1000 */BYTE("add a,#0%XH"), BYTE("addc a,#0%XH"), BYTE("sub a,#0%XH"), BYTE("subc a,#0%XH"),
	/* 1010 1100 */BYTE("and a,#0%XH"), BYTE("xor a,#0%XH"), BYTE("or a,#0%XH"), BYTE("cmp a,#0%XH"),
	/* 1011 0000 */SADDR("set1 %s.0"), SADDR("set1 %s.1"), SADDR("set1 %s.2"), SADDR("set1 %s.3"),
	/* 1011 0100 */SADDR("set1 %s.4"), SADDR("set1 %s.5"), SADDR("set1 %s.6"), SADDR("set1 %s.7"),
	/* 1011 1000 */BYTE("mov x,#0%XH"), BYTE("mov a,#0%XH"), BYTE("mov c,#0%XH"), BYTE("mov b,#0%XH"),
	/* 1011 1100 */BYTE("mov e,#0%XH"), BYTE("mov d,#0%XH"), BYTE("mov l,#0%XH"), BYTE("mov h,#0%XH"),
	/* 1100 0000 */STRING("inc x"), STRING("inc a"), STRING("inc c"), STRING("inc b"),
	/* 1100 0100 */STRING("inc e"), STRING("inc d"), STRING("inc l"), STRING("inc h"),
	/* 1100 1000 */STRING("dec x"), STRING("dec a"), STRING("dec c"), STRING("dec b"),
	/* 1100 1100 */STRING("dec e"), STRING("dec d"), STRING("dec l"), STRING("dec h"),
	/* 1101 0000 */STRING("mov a,x"), STRING("mov a,a"), STRING("mov a,c"), STRING("mov a,b"),
	/* 1101 0100 */STRING("mov a,e"), STRING("mov a,d"), STRING("mov a,l"), STRING("mov a,h"),
	/* 1101 1000 */STRING("xch a,x"), STRING("xch a,a"), STRING("xch a,c"), STRING("xch a,b"),
	/* 1101 1100 */STRING("xch a,e"), STRING("xch a,d"), STRING("xch a,l"), STRING("xch a,h"),
	/* 1110 0000 */CALLT, CALLT, CALLT, CALLT,
	/* 1110 0100 */CALLT, CALLT, CALLT, CALLT,
	/* 1110 1000 */CALLT, CALLT, CALLT, CALLT,
	/* 1110 1100 */CALLT, CALLT, CALLT, CALLT,
	/* 1111 0000 */CALLT, CALLT, CALLT, CALLT,
	/* 1111 0100 */CALLT, CALLT, CALLT, CALLT,
	/* 1111 1000 */CALLT, CALLT, CALLT, CALLT,
	/* 1111 1100 */CALLT, CALLT, CALLT, CALLT,
};

uint16_t upd78k2_disasm(char *dst, upd_address_ref *ref, uint16_t address, upd_fetch_fun fetch, void *data, disasm_context *context)
{
	static const char regnames[] = "xacbedlh";
	char addr_buf[256], addr_buf2[256];
	uint8_t opcode = fetch(address++, data);
	uint8_t byte;
	uint16_t word;
	upd_inst *table = maint;
	while (table[opcode].type == T_PREFIX)
	{
		table = table[opcode].v.prefix;
		opcode = fetch(address++, data);
	}
	uint16_t ref_addr = 0, ref_addr2 = 0;
	uint8_t ref_type = UPD_REF_NONE;
	switch (table[opcode].type)
	{
	case T_INVALID:
		strcpy(dst, "invalid");
		break;
	case T_STRING:
		strcpy(dst, table[opcode].v.str);
		break;
	case T_REG_REG:
		byte = fetch(address++, data);
		sprintf(dst, table[opcode].v.str, regnames[byte >> 4 & 7], regnames[byte & 7]);
		break;
	case T_SFR:
		ref_addr = 0xFF00 | fetch(address++, data);
		ref_type = UPD_REF_OP;
		format_address(context, addr_buf, ref_addr);
		sprintf(dst, table[opcode].v.str, addr_buf);
		break;
	case T_SFR_BYTE:
		ref_addr = 0xFF00 | fetch(address++, data);
		ref_type = UPD_REF_OP;
		byte = fetch(address++, data);
		format_address(context, addr_buf, ref_addr);
		sprintf(dst, table[opcode].v.str, addr_buf, byte);
		break;
	case T_SFR_WORD:
		ref_addr = 0xFF00 | fetch(address++, data);
		ref_type = UPD_REF_OP;
		word = fetch(address++, data);
		word |= fetch(address++, data) << 8;
		format_address(context, addr_buf, ref_addr);
		sprintf(dst, table[opcode].v.str, addr_buf, word);
		break;
	case T_SADDR:
		ref_addr = fetch(address++, data);
		ref_addr |= ref_addr < 0x20 ? 0xFF00 : 0xFE00;
		ref_type = UPD_REF_OP;
		format_address(context, addr_buf, ref_addr);
		sprintf(dst, table[opcode].v.str, addr_buf);
		break;
	case T_SADDR_BYTE:
		ref_addr = fetch(address++, data);
		ref_addr |= ref_addr < 0x20 ? 0xFF00 : 0xFE00;
		ref_type = UPD_REF_OP;
		byte = fetch(address++, data);
		format_address(context, addr_buf, ref_addr);
		sprintf(dst, table[opcode].v.str, addr_buf, byte);
		break;
	case T_SADDR_WORD:
		ref_addr = fetch(address++, data);
		ref_addr |= ref_addr < 0x20 ? 0xFF00 : 0xFE00;
		ref_type = UPD_REF_OP;
		word = fetch(address++, data);
		word |= fetch(address++, data) << 8;
		format_address(context, addr_buf, ref_addr);
		sprintf(dst, table[opcode].v.str, addr_buf, word);
		break;
	case T_SADDR_SADDR:
		ref_addr2 = fetch(address++, data);
		ref_addr2 |= ref_addr2 < 0x20 ? 0xFF00 : 0xFE00;
		ref_addr = fetch(address++, data);
		ref_addr |= ref_addr < 0x20 ? 0xFF00 : 0xFE00;
		ref_type = UPD_REF_2OP;
		format_address(context, addr_buf, ref_addr);
		format_address(context, addr_buf2, ref_addr2);
		sprintf(dst, table[opcode].v.str, addr_buf, addr_buf2);
		break;
	case T_BYTE:
	case T_BASE:
		byte = fetch(address++, data);
		sprintf(dst, table[opcode].v.str, byte);
		break;
	case T_WORD:
	case T_INDEXED:
		word = fetch(address++, data);
		word |= fetch(address++, data) << 8;
		sprintf(dst, table[opcode].v.str, word);
		break;
	case T_ADDR16:
		ref_addr = fetch(address++, data);
		ref_addr |= fetch(address++, data) << 8;
		ref_type = UPD_REF_OP;
		format_address(context, addr_buf, ref_addr);
		sprintf(dst, table[opcode].v.str, addr_buf);
		break;
	case T_BR_REL:
		ref_addr = fetch(address++, data);
		if (ref_addr & 0x80) {
			ref_addr |= 0xFF00;
		}
		ref_addr += address;
		ref_type = table[opcode].v.str[1] == 'r' ? UPD_REF_BRANCH : UPD_REF_COND_BRANCH;
		format_address(context, addr_buf, ref_addr);
		sprintf(dst, table[opcode].v.str, addr_buf);
		break;
	case T_BR_ABS:
		ref_addr = fetch(address++, data);
		ref_addr |= fetch(address++, data) << 8;
		ref_type = table[opcode].v.str[0] == 'c' ? UPD_REF_CALL : UPD_REF_BRANCH;
		format_address(context, addr_buf, ref_addr);
		sprintf(dst, table[opcode].v.str, addr_buf);
		break;
	case T_BR_SFR:
		ref_addr = 0xFF00 | fetch(address++, data);
		ref_addr2 = fetch(address++, data);
		if (ref_addr2 & 0x80) {
			ref_addr2 |= 0xFF00;
		}
		ref_addr2 += address;
		ref_type = UPD_REF_OP_BRANCH;
		format_address(context, addr_buf, ref_addr);
		format_address(context, addr_buf2, ref_addr2);
		sprintf(dst, table[opcode].v.str, addr_buf, addr_buf2);
		break;
	case T_BR_SADDR:
		ref_addr = fetch(address++, data);
		ref_addr |= ref_addr < 0x20 ? 0xFF00 : 0xFE00;
		ref_addr2 = fetch(address++, data);
		if (ref_addr2 & 0x80) {
			ref_addr2 |= 0xFF00;
		}
		ref_addr2 += address;
		ref_type = UPD_REF_OP_BRANCH;
		format_address(context, addr_buf, ref_addr);
		format_address(context, addr_buf2, ref_addr2);
		sprintf(dst, table[opcode].v.str, addr_buf, addr_buf2);
		break;
	case T_CALLF:
		ref_addr = opcode << 8 & 0x700;
		ref_addr |= 0x800 | fetch(address++, data);
		ref_type = UPD_REF_CALL;
		format_address(context, addr_buf, ref_addr);
		sprintf(dst, "callf !%s", addr_buf);
		break;
	case T_CALLT:
		ref_addr = opcode << 1& 0x3E;
		ref_addr |= 0x40;
		ref_type = UPD_REF_CALL_TABLE;
		format_address(context, addr_buf, ref_addr);
		sprintf(dst, "callt [%s]", addr_buf);
		break;
	case T_CUSTOM:
		return table[opcode].v.fun(dst, ref, address, fetch, data, context);
	}
	if (ref) {
		ref->address = ref_addr;
		ref->address2 = ref_addr2;
		ref->ref_type = ref_type;
	}
	return address;
}