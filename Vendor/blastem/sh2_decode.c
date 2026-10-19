#include <stddef.h>
#include "sh2_decode.h"

const char *sh2_mnemonics[] = {
	"invalid",
	"add",
	"addc",
	"addv",
	"and",
	"bf",
	"bf/s",
	"bra",
	"braf",
	"bsr",
	"bsrf",
	"bt",
	"bt/s",
	"clrmac",	
	"clrt",
	"cmp/eq",
	"cmp/ge",
	"cmp/gt",
	"cmp/hi",
	"cmp/hs",
	"cmp/pl",
	"cmp/pz",
	"cmp/str",
	"div0s",
	"div0u",
	"div1",
	"dmuls",
	"dmulu",
	"dt",
	"exts.b",
	"exts.w",
	"extu.b",
	"extu.w",
	"jmp",
	"jsr",
	"ldc",
	"lds",
	"mac.w",
	"mac.l",
	"mov",
	"mova",
	"mov.b",
	"mov.w",
	"mov.l",
	"movt",
	"mul.l",
	"muls.w",
	"mulu.w",
	"neg",
	"negc",
	"nop",
	"not",
	"or",
	"rotcl",
	"rotcr",
	"rotl",
	"rotr",
	"rte",
	"rts",
	"sett",
	"shal",
	"shar",
	"shll",
	"shll2",
	"shll8",
	"shll16",
	"shlr",
	"shlr2",
	"shlr8",
	"shlr16",
	"sleep",
	"stc",
	"sts",
	"sub",
	"subc",
	"subv",
	"swap.b",
	"swap.w",
	"tas",
	"trapa",
	"tst",
	"xor",
	"xtrct"
};

static const char* sh2_regnames[] = {
	NULL,
	"sr", "gbr", "vbr",
	"mach", "macl", "pr",
	"#%d", NULL, "@(r0,gbr)", "@(%s,pc)",
	[SH2_R0] = "r0", "r1", "r2", "r3",
	"r4", "r5", "r6", "r7",
	"r8", "r9", "r10", "r11",
	"r12", "r13", "r14", "sp",
	"@r0+", "@r1+", "@r2+", "@r3+", //32
	"@r4+", "@r5+", "@r6+", "@r7+",
	"@r8+", "@r9+", "@r10+", "@r11+",
	"@r12+", "@r13+", "@r14+", "@sp+",
	"@-r0", "@-r1", "@-r2", "@-r3", //48
	"@-r4", "@-r5", "@-r6", "@-r7",
	"@-r8", "@-r9", "@-r10", "@-r11",
	"@-r12", "@-r13", "@-r14", "@-sp",
	"@r0", "@r1", "@r2", "@r3", //64
	"@r4", "@r5", "@r6", "@r7",
	"@r8", "@r9", "@r10", "@r11",
	"@r12", "@r13", "@r14", "@sp",
	"@(r0,r0)", "@(r0,r1)", "@(r0,r2)", "@(r0,r3)", //80
	"@(r0,r4)", "@(r0,r5)", "@(r0,r6)", "@(r0,r7)",
	"@(r0,r8)", "@(r0,r9)", "@(r0,r10)", "@(r0,r11)",
	"@(r0,r12)", "@(r0,r13)", "@(r0,r14)", "@(r0,sp)",
	"@(%d,r0)", "@(%d,r1)", "@(%d,r2)", "@(%d,r3)",
	"@(%d,r4)", "@(%d,r5)", "@(%d,r6)", "@(%d,r7)",
	"@(%d,r8)", "@(%d,r9)", "@(%d,r10)", "@(%d,r11)",
	"@(%d,r12)", "@(%d,r13)", "@(%d,r14)", "@(%d,sp)",
	"@(%d,gbr)"
};


static const sh2_inst sh2_invalid = {.opcode = SH2_INVALID};

static sh2_inst no_oper(uint8_t opcode)
{
	return (sh2_inst){.opcode = opcode};
}

static sh2_inst reg_unary(uint8_t opcode, uint8_t reg)
{
	return (sh2_inst){.opcode = opcode, .src = SH2_R0 + reg};
}

static sh2_inst reg_binary(uint8_t opcode, uint8_t src, uint8_t dst)
{
	return (sh2_inst){.opcode = opcode, .src = SH2_R0 + src, .dst = SH2_R0 + dst};
}

static sh2_inst indirect_unary(uint8_t opcode, uint8_t reg)
{
	return (sh2_inst){.opcode = opcode, .src = SH2_IND_R0 + reg};
}

static int16_t sign_extend8(uint8_t in)
{
	uint16_t ext = in;
	if (ext & 0x80) {
		ext |= 0xFF00;
	}
	return (int16_t)ext;
}

static int16_t sign_extend12(uint16_t in)
{
	if (in & 0x800) {
		in |= 0xF000;
	}
	return (int16_t)in;
}

static sh2_inst immed8_sext(uint8_t opcode, uint8_t immed, uint8_t dst)
{
	return (sh2_inst){.opcode = opcode, .src = SH2_IMMED, .dst = dst, .immed = sign_extend8(immed)};
}

static sh2_inst immed8_zext(uint8_t opcode, uint8_t immed, uint8_t dst)
{
	return (sh2_inst){.opcode = opcode, .src = SH2_IMMED, .dst = dst, .immed = immed};
}

sh2_inst sh2_decode(uint16_t inst)
{
	uint8_t rm, rn, oplo;
	rn = inst >> 8 & 0xF;
	rm = inst >> 4 & 0xF;
	oplo = inst & 0xF;
	switch (inst >> 12)
	{
	case 0x0:
		switch (oplo)
		{
		case 0x0:
		case 0x1: return sh2_invalid;
		case 0x2:
			if (rm < 0x3) {
				return (sh2_inst){.opcode = SH2_STC, .src = SH2_SR + rm, .dst= rn + SH2_R0};
			}
			return sh2_invalid;
		case 0x3:
			if (rm == 0) {
				return reg_unary(SH2_BSRF, rn);
			} else if (rm == 2) {
				return reg_unary(SH2_BRAF, rn);
			}
			return sh2_invalid;
		case 0x4: 
		case 0x5: 
		case 0x6: return (sh2_inst){.opcode = SH2_MOVB + oplo - 0x4, .src = SH2_R0 + rm, .dst = SH2_IDX_R0_R0 + rn};
		case 0x7: return reg_binary(SH2_MUL, rm, rn);
		case 0x8:
			if (rn != 0) {
				return sh2_invalid;
			}
			switch(rm)
			{
			case 0: return no_oper(SH2_CLRT);
			case 1: return no_oper(SH2_SETT);
			case 2: return no_oper(SH2_CLRMAC);
			default: return sh2_invalid;
			}
		case 0x9:
			if (rm < 2 && rn != 0) {
				return sh2_invalid;
			}
			switch(rm)
			{
			case 0: return no_oper(SH2_NOP);
			case 1: return no_oper(SH2_DIV0U);
			case 2: return reg_unary(SH2_MOVT, rn);
			}
			return sh2_invalid;
		case 0xA:
			if (rm < 0x3) {
				return (sh2_inst){.opcode = SH2_STS, .src = SH2_MACH + rm, .dst = rn + SH2_R0};
			}
			return sh2_invalid;
		case 0xB:
			switch(rm)
			{
			case 0: return no_oper(SH2_RTS);
			case 1: return no_oper(SH2_SLEEP);
			case 2: return no_oper(SH2_RTE);
			default: return sh2_invalid;
			}
		case 0xC:
		case 0xD:
		case 0xE: return (sh2_inst){.opcode = SH2_MOVB + oplo - 0xC, .src = SH2_IDX_R0_R0 + rm, .dst = SH2_R0 + rn};
		case 0xF: return (sh2_inst){.opcode = SH2_MAC_L, .src = SH2_POSTINC_R0 + rm, .dst = SH2_POSTINC_R0 + rn};
		}
		break;
	case 0x1: return (sh2_inst){.opcode = SH2_MOVL, .src = SH2_R0 + rm, .dst = SH2_DISP_R0 + rn, .immed = oplo};
	case 0x2:
		switch (oplo)
		{
		case 0x0:
		case 0x1:
		case 0x2: return (sh2_inst){.opcode = SH2_MOVB + (oplo & 3), .src = SH2_R0 + rm, .dst = SH2_IND_R0 + rn};
		case 0x3: return sh2_invalid;
		case 0x4:
		case 0x5:
		case 0x6: return (sh2_inst){.opcode = SH2_MOVB + (oplo & 3), .src = SH2_R0 + rm, .dst = SH2_PREDEC_R0 + rn};
		case 0x7: return reg_binary(SH2_DIV0S, rm, rn);
		case 0x8: return reg_binary(SH2_TST, rm, rn);
		case 0x9: return reg_binary(SH2_AND, rm, rn);
		case 0xA: return reg_binary(SH2_XOR, rm, rn);
		case 0xB: return reg_binary(SH2_OR, rm, rn);
		case 0xC: return reg_binary(SH2_CMPSTR, rm, rn);
		case 0xD: return reg_binary(SH2_XTRCT, rm, rn);
		case 0xE: return reg_binary(SH2_MULU, rm, rn);
		case 0xF: return reg_binary(SH2_MULS, rm, rn);
		}
	case 0x3:
		switch (oplo)
		{
		case 0x0: return reg_binary(SH2_CMPEQ, rm, rn);
		case 0x1: return sh2_invalid;
		case 0x2: return reg_binary(SH2_CMPHS, rm, rn);
		case 0x3: return reg_binary(SH2_CMPGE, rm, rn);
		case 0x4: return reg_binary(SH2_DIV1, rm, rn);
		case 0x5: return reg_binary(SH2_DMULU, rm, rn);
		case 0x6: return reg_binary(SH2_CMPHI, rm, rn);
		case 0x7: return reg_binary(SH2_CMPGT, rm, rn);
		case 0x8: return reg_binary(SH2_SUB, rm, rn);
		case 0x9: return sh2_invalid;
		case 0xA: return reg_binary(SH2_SUBC, rm, rn);
		case 0xB: return reg_binary(SH2_SUBV, rm, rn);
		case 0xC: return reg_binary(SH2_ADD, rm, rn);
		case 0xD: return reg_binary(SH2_DMULS, rm, rn);
		case 0xE: return reg_binary(SH2_ADDC, rm, rn);
		case 0xF: return reg_binary(SH2_ADDV, rm, rn);
		}
	case 0x4:
		if (oplo != 0xF && rm >= 3) {
			return sh2_invalid;
		}
		switch (oplo)
		{
		case 0x0:
			switch (rm)
			{
			case 0: return reg_unary(SH2_SHLL, rn);
			case 1: return reg_unary(SH2_DT, rn);
			case 2: return reg_unary(SH2_SHAL, rn);
			}
		case 0x1:
			switch (rm)
			{
			case 0: return reg_unary(SH2_SHLR, rn);
			case 1: return reg_unary(SH2_CMPPZ, rn);
			case 2: return reg_unary(SH2_SHAR, rn);
			}
		case 0x2: return (sh2_inst){.opcode = SH2_STS, .src = SH2_MACH + rm, .dst = SH2_PREDEC_R0 + rn};
		case 0x3: return (sh2_inst){.opcode = SH2_STC, .src = SH2_SR + rm, .dst = SH2_PREDEC_R0 + rn};
		case 0x4:
			switch (rm)
			{
			case 0: return reg_unary(SH2_ROTL, rn);
			case 1: return sh2_invalid;
			case 2: return reg_unary(SH2_ROTCL, rn);
			}
		case 0x5:
			switch (rm)
			{
			case 0: return reg_unary(SH2_ROTR, rn);
			case 1: return reg_unary(SH2_CMPPL, rn);;
			case 2: return reg_unary(SH2_ROTCR, rn);
			}
		case 0x6: return (sh2_inst){.opcode = SH2_LDS, .src = SH2_POSTINC_R0 + rn, .dst = SH2_MACH + rm};
		case 0x7: return (sh2_inst){.opcode = SH2_LDC, .src = SH2_POSTINC_R0 + rn, .dst = SH2_SR + rm};
		case 0x8: return reg_unary(SH2_SHLL2 + rm, rn);
		case 0x9: return reg_unary(SH2_SHLR2 + rm, rn);
		case 0xA: return (sh2_inst){.opcode = SH2_LDS, .src = SH2_R0 + rn, .dst = SH2_MACH + rm};
		case 0xB: 
			switch (rm)
			{
			case 0: return indirect_unary(SH2_JSR, rn);
			case 1: return indirect_unary(SH2_TAS, rn);
			case 2: return indirect_unary(SH2_JMP, rn);
			}
		case 0xC: return sh2_invalid;
		case 0xD: return sh2_invalid;
		case 0xE: return (sh2_inst){.opcode = SH2_LDC, .src = SH2_R0 + rn, .dst = SH2_SR + rm};
		case 0xF: return (sh2_inst){.opcode = SH2_MAC_W, .src = SH2_POSTINC_R0 + rm, .dst = SH2_POSTINC_R0 + rn};
		}
	case 0x5: return (sh2_inst){.opcode = SH2_MOVL, .src = SH2_DISP_R0 + rm, .dst = SH2_R0 + rn, .immed = oplo};
	case 0x6:
		switch (oplo)
		{
		case 0x0:
		case 0x1:
		case 0x2: return (sh2_inst){.opcode = SH2_MOVB + oplo, .src = SH2_IND_R0 + rm, .dst = SH2_R0 + rn};
		case 0x3: return reg_binary(SH2_MOV, rm, rn);
		case 0x4:
		case 0x5:
		case 0x6: return (sh2_inst){.opcode = SH2_MOVB + (oplo & 3), .src = SH2_POSTINC_R0 + rm, .dst = SH2_R0 + rn};
		case 0x7: return reg_binary(SH2_NOT, rm, rn);
		case 0x8:
		case 0x9: return reg_binary(SH2_SWAPB + (oplo & 1), rm, rn);
		case 0xA: return reg_binary(SH2_NEGC, rm, rn);
		case 0xB: return reg_binary(SH2_NEG, rm, rn);
		case 0xC:
		case 0xD: return reg_binary(SH2_EXTUB + (oplo & 1), rm, rn);
		case 0xE:
		case 0xF: return reg_binary(SH2_EXTSB + (oplo & 1), rm, rn);
		}
	case 0x7: return immed8_sext(SH2_ADD, inst & 0xFF, SH2_R0 + rn);
	case 0x8:
		switch (rn)
		{
		case 0x0:
		case 0x1: return (sh2_inst){.opcode = SH2_MOVB + rn, .src = SH2_R0, .dst = SH2_DISP_R0 + rm, .immed = oplo};
		case 0x2:
		case 0x3:
		case 0x6:
		case 0x7:
		case 0xA:
		case 0xC: 
		case 0xE: return sh2_invalid;
		case 0x4:
		case 0x5: return (sh2_inst){.opcode = SH2_MOVB + (rn & 1), .src = SH2_DISP_R0 + rm, .dst = SH2_R0, .immed = oplo};		
		case 0x8: return immed8_sext(SH2_CMPEQ, inst & 0xFF, SH2_R0);
		case 0x9: return (sh2_inst){.opcode = SH2_BT, .src = SH2_REL, .immed = sign_extend8(inst & 0xFF) << 1};
		case 0xB: return (sh2_inst){.opcode = SH2_BF, .src = SH2_REL, .immed = sign_extend8(inst & 0xFF) << 1};
		case 0xD: return (sh2_inst){.opcode = SH2_BTS, .src = SH2_REL, .immed = sign_extend8(inst & 0xFF) << 1};
		case 0xF: return (sh2_inst){.opcode = SH2_BFS, .src = SH2_REL, .immed = sign_extend8(inst & 0xFF) << 1};
		}
	case 0x9: return (sh2_inst){.opcode = SH2_MOVW, .src = SH2_DISP_PC, .dst = SH2_R0 + rn, .immed = (inst & 0xFF) << 1};
	case 0xA: return (sh2_inst){.opcode = SH2_BRA, .src = SH2_REL, .immed = sign_extend12(inst & 0xFFF) << 1};
	case 0xB: return (sh2_inst){.opcode = SH2_BSR, .src = SH2_REL, .immed = sign_extend12(inst & 0xFFF) << 1};
	case 0xC:
		switch (rn)
		{
		case 0x0:
		case 0x1:
		case 0x2: return (sh2_inst){.opcode = SH2_MOVB + rn, .src = SH2_R0, .dst = SH2_DISP_GBR, .immed = (inst & 0xFF) << rn};
		case 0x3: return (sh2_inst){.opcode = SH2_TRAPA, .src = SH2_IMMED, .immed = (inst & 0xFF)};
		case 0x4:
		case 0x5:
		case 0x6: return (sh2_inst){.opcode = SH2_MOVB + (rn & 3), .src = SH2_DISP_GBR, .dst = SH2_R0, .immed = (inst & 0xFF) << (rn & 3)};
		case 0x7: return (sh2_inst){.opcode = SH2_MOVA, .src = SH2_DISP_PC, .dst = SH2_R0, .immed = (inst & 0xFF) << 2};
		case 0x8: return immed8_zext(SH2_TST, inst & 0xFF, SH2_R0);
		case 0x9: return immed8_zext(SH2_AND, inst & 0xFF, SH2_R0);
		case 0xA: return immed8_zext(SH2_XOR, inst & 0xFF, SH2_R0);
		case 0xB: return immed8_zext(SH2_OR, inst & 0xFF, SH2_R0);
		case 0xC: return immed8_zext(SH2_TST, inst & 0xFF, SH2_IDX_R0_GBR);
		case 0xD: return immed8_zext(SH2_AND, inst & 0xFF, SH2_IDX_R0_GBR);
		case 0xE: return immed8_zext(SH2_XOR, inst & 0xFF, SH2_IDX_R0_GBR);
		case 0xF: return immed8_zext(SH2_OR, inst & 0xFF, SH2_IDX_R0_GBR);
		}
	case 0xD: return (sh2_inst){.opcode = SH2_MOVL, .src = SH2_DISP_PC, .dst = SH2_R0 + rn, .immed = (inst & 0xFF) << 2};
	case 0xE: return immed8_sext(SH2_MOV, inst & 0xFF, SH2_R0 + rn);
	case 0xF: return sh2_invalid;
	}
	return sh2_invalid;
}

int sh2_disasm(char *dst, sh2_inst inst, uint32_t address, disasm_context *context)
{
	int ret = sprintf(dst, "%s", sh2_mnemonics[inst.opcode]);
	if (inst.src) {
		if (inst.src == SH2_IMMED || inst.src >= SH2_DISP_R0) {
			dst[ret++] = ' ';
			ret += sprintf(dst + ret, sh2_regnames[inst.src], inst.immed);
		} else if (inst.src == SH2_DISP_PC) {
			dst[ret++] = ' ';
			if (inst.opcode == SH2_MOVL || inst.opcode == SH2_MOVA) {
				address &= ~3;
			}
			address += inst.immed + 4;
			char label[128];
			if (context && context->labels) {
				format_label(label, address, context);
			} else {
				sprintf(label, "%d", inst.immed);
			}
			ret += sprintf(dst + ret, sh2_regnames[inst.src], label);
		} else if (inst.src == SH2_REL) {
			address += inst.immed + 4;
			if (context && context->labels) {
				dst[ret++] = ' ';
				ret += format_label(dst + ret, address, context);
			} else {
				ret += sprintf(dst + ret, " $%X", address);
			}
		} else {
			ret += sprintf(dst + ret, " %s", sh2_regnames[inst.src]);
		}
	}
	if (inst.dst) {
		if (inst.dst == SH2_IMMED || inst.dst >= SH2_DISP_R0) {
			dst[ret++] = ',';
			ret += sprintf(dst + ret, sh2_regnames[inst.dst], inst.immed);
		} else {
			ret += sprintf(dst + ret, ",%s", sh2_regnames[inst.dst]);
		}
	}
	return ret;
}
