#include "disasm.h"
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <ctype.h>
#include "util.h"

label_def *find_label(disasm_context *context, uint32_t address)
{
	char key[MAX_INT_KEY_SIZE];
	tern_sortable_int_key(address & context->address_mask, key);
	return tern_find_ptr(context->labels, key);
}

label_def *find_label_by_name(disasm_context *context, const char *name)
{
	return tern_find_ptr(context->labels_by_name, name);
}

int format_label(char *dst, uint32_t address, disasm_context *context)
{
	label_def *def = find_label(context, address);
	if (def && def->num_labels) {
		return sprintf(dst, "%s", def->labels[0]);
	}
	return sprintf(dst, "ADR_%X", address);
}

label_def *add_find_label(disasm_context *context, uint32_t address)
{
	char key[MAX_INT_KEY_SIZE];
	tern_sortable_int_key(address & context->address_mask, key);
	label_def *def = tern_find_ptr(context->labels, key);
	if (!def)
	{
		def = calloc(1, sizeof(label_def));
		context->labels = tern_insert_ptr(context->labels, key, def);
	}
	def->full_address = address;
	return def;
}

void name_label(disasm_context *context, label_def *def, const char *name)
{
	if (def->num_labels == def->storage) {
		def->storage = def->storage ? def->storage * 2 : 4;
		def->labels = realloc(def->labels, def->storage * sizeof(char*));;
	}
	def->labels[def->num_labels++] = strdup(name);
	context->labels_by_name = tern_insert_ptr(context->labels_by_name, name, def);
}

label_def *weak_label(disasm_context *context, const char *name, uint32_t address)
{
	label_def *def = add_find_label(context, address);
	name_label(context, def, name);
	return def;
}

label_def *reference(disasm_context *context, uint32_t address)
{
	label_def *def = add_find_label(context, address);
	def->referenced = 1;
	return def;
}

label_def *add_label(disasm_context *context, const char *name, uint32_t address)
{
	label_def *def = reference(context, address);
	name_label(context, def, name);
	return def;
}

void visit(disasm_context *context, uint32_t address)
{
	if (!context->visited) {
		uint32_t size = context->address_mask + 1;
		size >>= context->visit_preshift;
		size >>= 3;
		context->visited = calloc(1, size);
	}
	address &= context->address_mask;
	address >>= context->visit_preshift;
	context->visited[address >> 3] |= 1 << (address & 7);
}

uint8_t is_visited(disasm_context *context, uint32_t address)
{
	if (!context->visited) {
		return 0;
	}
	address &= context->address_mask;
	address >>= context->visit_preshift;
	return (context->visited[address >> 3] & (1 << (address & 7))) != 0;
}

void defer_disasm_label(disasm_context *context, uint32_t address, label_def *label)
{
	if (is_visited(context, address) || address & context->invalid_inst_addr_mask) {
		return;
	}
	context->deferred = defer_address(context->deferred, address, (code_ptr)label);
}

void defer_disasm(disasm_context *context, uint32_t address)
{
	defer_disasm_label(context, address, NULL);
}

void process_address_def(disasm_context *context, char *def)
{
	char *end;
	uint32_t address = strtol(def, &end, 16);
	if (*end == '=') {
		defer_disasm(context, address);
		add_label(context, strip_ws(end+1), address);
	} else if (*end && !isspace(*end)) {
		uint8_t is_table = 0;
		if (*end == 't') {
			is_table = 1;
			end++;
		}
		uint8_t el_size, is_pointer = 0;;
		switch (*end)
		{
		case 'y':
		case 'b': el_size = 1; break;
		case 'w': el_size = 2; break;
		case 'f':
		case 'p': is_pointer = 1;
		case 'l': el_size = 4; break;
		default:
			fprintf(stderr, "Invalid character %c in address definition %s\n", *end, def);
			exit(1);
		}
		uint32_t count = 1;
		char *count_end = end + 1;
		if (is_table) {
			count = strtol(end + 1, &count_end, 10);
			if (count_end == end + 2) {
				fprintf(stderr, "Table address definition %s missing count\n", def);
				exit(1);
			}
		}
		label_def *def = *count_end == '=' ? add_label(context, strip_ws(count_end+1), address) : reference(context, address);
		def->data_count = count;
		def->data_size = el_size;
		def->is_pointer = is_pointer;
		if (*end == 'f') {
			defer_disasm_label(context, address, def);
		} else {
			visit(context, address);
		}
	} else {
		defer_disasm(context, address);
		reference(context, address);
	}
}

void process_m68k_vectors(disasm_context *context, uint16_t *table, uint8_t labels_only)
{
	static const char* names[] = {
		"access_fault",
		"address_error",
		"illegal_instruction",
		"integer_divide_by_zero",
		"chk_exception",
		"trap_exception",
		"privilege_violation",
		"trace_exception",
		"line_1010_emulator",
		"line_1111_emulator"
	};
	uint32_t address = table[2] << 16 | table[3];
	add_label(context, "start", address);
	if (!labels_only) {
		defer_disasm(context, address);
	}
	for (int i = 0; i < sizeof(names)/sizeof(*names); i++)
	{
		address = table[i*2+4] << 16 | table[i*2 + 5];
		add_label(context, names[i], address);
		if (!labels_only) {
			defer_disasm(context, address);
		}
	}
	char int_name[] = "int_0";
	for (int i = 0; i < 7; i++)
	{
		int_name[4] = '1' + i;
		address = table[i*2+(0x64>>1)] << 16 | table[i*2 + (0x64>>1|1)];
		add_label(context, int_name, address);
		if (!labels_only) {
			defer_disasm(context, address);
		}
	}

	char trap_name[] = "trap_0";
	for (int i = 0; i < 16; i++)
	{
		trap_name[5] = i < 0xA ? '0' + i : 'a' + i - 0xA;
		address = table[i*2+(0x80>>1)] << 16 | table[i*2 + (0x80>>1|1)];
		add_label(context, trap_name, address);
		if (!labels_only) {
			defer_disasm(context, address);
		}
	}
}

void add_segacd_maincpu_labels(disasm_context *context)
{
	weak_label(context, "_bios_reset", 0x280);
	weak_label(context, "_bios_entry", 0x284);
	weak_label(context, "_bios_init", 0x288);
	weak_label(context, "_bios_init_sp", 0x28C);
	weak_label(context, "_bios_vint", 0x290);
	weak_label(context, "_bios_set_hint", 0x294);
	weak_label(context, "_bios_poll_io", 0x298);
	weak_label(context, "_bios_detect_io", 0x29C);
	weak_label(context, "_bios_clear_vram", 0x2A0);
	weak_label(context, "_bios_clear_nmtbl", 0x2A4);
	weak_label(context, "_bios_clear_vsram", 0x2A8);
	weak_label(context, "_bios_init_vdp", 0x2AC);
	weak_label(context, "_bios_vdp_loadregs", 0x2B0);
	weak_label(context, "_bios_vdp_fill", 0x2B4);
	weak_label(context, "_bios_clear_vram_range", 0x2B8);
	weak_label(context, "_bios_clear_vram_range_dma", 0x2BC);
	weak_label(context, "_bios_vram_dma_fill", 0x2C0);
	weak_label(context, "_bios_update_nmtbl", 0x2C4);
	weak_label(context, "_bios_update_nmtbl_template", 0x2C8);
	weak_label(context, "_bios_fill_nmtbl", 0x2CC);
	weak_label(context, "_bios_vdp_dma", 0x2D0);
	weak_label(context, "_bios_vdp_dma_wordram", 0x2D4);
	weak_label(context, "_bios_vdp_display_enable", 0x2D8);
	weak_label(context, "_bios_vdp_display_disable", 0x2DC);
	weak_label(context, "_bios_pal_buffer", 0x2E0);
	weak_label(context, "_bios_pal_buffer_update", 0x2E4);
	weak_label(context, "_bios_pal_dma", 0x2E8);
	weak_label(context, "_bios_gfx_decomp", 0x2EC);
	weak_label(context, "_bios_gfx_decomp_ram", 0x2F0);
	weak_label(context, "_bios_update_sprites", 0x2F4);
	weak_label(context, "_bios_clear_ram", 0x2F8);
	weak_label(context, "_bios_display_sprite", 0x300);
	weak_label(context, "_bios_wait_vint", 0x304);
	weak_label(context, "_bios_wait_vint_flags", 0x308);
	weak_label(context, "_bios_dma_sat", 0x30C);
	weak_label(context, "_bios_set_hint_direct", 0x314);
	weak_label(context, "_bios_disable_hint", 0x318);
	weak_label(context, "_bios_print", 0x31C);
	weak_label(context, "_bios_load_user_font", 0x320);
	weak_label(context, "_bios_load_bios_font", 0x324);
	weak_label(context, "_bios_load_bios_font_default", 0x328);
	//TODO: more functions in the middle here
	weak_label(context, "_bios_prng_mod", 0x338);
	weak_label(context, "_bios_prng", 0x33C);
	weak_label(context, "_bios_clear_comm", 0x340);
	weak_label(context, "_bios_comm_update", 0x344);
	//TODO: more functions in the middle here
	weak_label(context, "_bios_sega_logo", 0x364);
	weak_label(context, "_bios_set_vint", 0x368);
	//TODO: more functions at the end here

	weak_label(context, "WORD_RAM", 0x200000);
	weak_label(context, "CD_RESET_IFL2", 0xA12000);
	weak_label(context, "CD_RESET_IFL2_BYTE", 0xA12001);
	weak_label(context, "CD_WRITE_PROTECT", 0xA12002);
	weak_label(context, "CD_MEM_MODE", 0xA12003);
	weak_label(context, "CDC_CTRL", 0xA12004);
	weak_label(context, "HINT_VECTOR", 0xA12006);
	weak_label(context, "CDC_HOST_DATA", 0xA12008);
	weak_label(context, "STOP_WATCH", 0xA1200C);
	weak_label(context, "COMM_MAIN_FLAG", 0xA1200E);
	weak_label(context, "COMM_SUB_FLAG", 0xA1200F);
	weak_label(context, "COMM_CMD0", 0xA12010);
	weak_label(context, "COMM_CMD1", 0xA12012);
	weak_label(context, "COMM_CMD2", 0xA12014);
	weak_label(context, "COMM_CMD3", 0xA12016);
	weak_label(context, "COMM_CMD4", 0xA12018);
	weak_label(context, "COMM_CMD5", 0xA1201A);
	weak_label(context, "COMM_CMD6", 0xA1201C);
	weak_label(context, "COMM_CMD7", 0xA1201E);
	weak_label(context, "COMM_STATUS0", 0xA12020);
	weak_label(context, "COMM_STATUS1", 0xA12022);
	weak_label(context, "COMM_STATUS2", 0xA12024);
	weak_label(context, "COMM_STATUS3", 0xA12026);
	weak_label(context, "COMM_STATUS4", 0xA12028);
	weak_label(context, "COMM_STATUS5", 0xA1202A);
	weak_label(context, "COMM_STATUS6", 0xA1202C);
	weak_label(context, "COMM_STATUS7", 0xA1202E);
}

void add_segacd_subcpu_labels(disasm_context *context)
{
	weak_label(context, "bios_common_work", 0x5E80);
	weak_label(context, "_setjmptbl", 0x5F0A);
	weak_label(context, "_waitvsync", 0x5F10);
	weak_label(context, "_buram", 0x5F16);
	weak_label(context, "_cdboot", 0x5F1C);
	weak_label(context, "_cdbios", 0x5F22);
	weak_label(context, "_usercall0", 0x5F28);
	weak_label(context, "_usercall1", 0x5F2E);
	weak_label(context, "_usercall2", 0x5F34);
	weak_label(context, "_usercall2Address", 0x5F36);
	weak_label(context, "_usercall3", 0x5F3A);
	weak_label(context, "_adrerr", 0x5F40);
	weak_label(context, "_adrerrAddress", 0x5F42);
	weak_label(context, "_coderr", 0x5F46);
	weak_label(context, "_coderrAddress", 0x5F48);
	weak_label(context, "_diverr", 0x5F4C);
	weak_label(context, "_diverrAddress", 0x5F4E);
	weak_label(context, "_chkerr", 0x5F52);
	weak_label(context, "_chkerrAddress", 0x5F54);
	weak_label(context, "_trperr", 0x5F58);
	weak_label(context, "_trperrAddress", 0x5F5A);
	weak_label(context, "_spverr", 0x5F5E);
	weak_label(context, "_spverrAddress", 0x5F60);
	weak_label(context, "_trace", 0x5F64);
	weak_label(context, "_traceAddress", 0x5F66);
	weak_label(context, "_nocod0", 0x5F6A);
	weak_label(context, "_nocod0Address", 0x5F6C);
	weak_label(context, "_nocod1", 0x5F70);
	weak_label(context, "_nocod1Address", 0x5F72);
	weak_label(context, "_slevel1", 0x5F76);
	weak_label(context, "_slevel1Address", 0x5F78);
	weak_label(context, "_slevel2", 0x5F7C);
	weak_label(context, "_slevel2Address", 0x5F7E);
	weak_label(context, "_slevel3", 0x5F82);
	weak_label(context, "_slevel3Address", 0x5F84);
	weak_label(context, "WORD_RAM_2M", 0x80000);
	weak_label(context, "WORD_RAM_1M", 0xC0000);
	weak_label(context, "PCM_ENV", 0xFF0001);
	weak_label(context, "PCM_PAN", 0xFF0003);
	weak_label(context, "PCM_FDL", 0xFF0005);
	weak_label(context, "PCM_FDH", 0xFF0007);
	weak_label(context, "PCM_LSL", 0xFF0009);
	weak_label(context, "PCM_LSH", 0xFF000B);
	weak_label(context, "PCM_ST", 0xFF000D);
	weak_label(context, "PCM_CTRL", 0xFF000F);
	weak_label(context, "PCM_CHAN_ENABLE", 0xFF0011);
	weak_label(context, "LED_CONTROL", 0xFFFF8000);
	weak_label(context, "VERSION_RESET", 0xFFFF8001);
	weak_label(context, "MEM_MODE_WORD", 0xFFFF8002);
	weak_label(context, "MEM_MODE_BYTE", 0xFFFF8003);
	weak_label(context, "CDC_CTRL", 0xFFFF8004);
	weak_label(context, "CDC_AR", 0xFFFF8005);
	weak_label(context, "CDC_REG_DATA_WORD", 0xFFFF8006);
	weak_label(context, "CDC_REG_DATA", 0xFFFF8007);
	weak_label(context, "CDC_HOST_DATA", 0xFFFF8008);
	weak_label(context, "CDC_DMA_ADDR", 0xFFFF800A);
	weak_label(context, "STOP_WATCH", 0xFFFF800C);
	weak_label(context, "COMM_MAIN_FLAG", 0xFFFF800E);
	weak_label(context, "COMM_SUB_FLAG", 0xFFFF800F);
	weak_label(context, "COMM_CMD0", 0xFFFF8010);
	weak_label(context, "COMM_CMD1", 0xFFFF8012);
	weak_label(context, "COMM_CMD2", 0xFFFF8014);
	weak_label(context, "COMM_CMD3", 0xFFFF8016);
	weak_label(context, "COMM_CMD4", 0xFFFF8018);
	weak_label(context, "COMM_CMD5", 0xFFFF801A);
	weak_label(context, "COMM_CMD6", 0xFFFF801C);
	weak_label(context, "COMM_CMD7", 0xFFFF801E);
	weak_label(context, "COMM_STATUS0", 0xFFFF8020);
	weak_label(context, "COMM_STATUS1", 0xFFFF8022);
	weak_label(context, "COMM_STATUS2", 0xFFFF8024);
	weak_label(context, "COMM_STATUS3", 0xFFFF8026);
	weak_label(context, "COMM_STATUS4", 0xFFFF8028);
	weak_label(context, "COMM_STATUS5", 0xFFFF802A);
	weak_label(context, "COMM_STATUS6", 0xFFFF802C);
	weak_label(context, "COMM_STATUS7", 0xFFFF802E);
	weak_label(context, "TIMER_WORD", 0xFFFF8030);
	weak_label(context, "TIMER", 0xFFFF8031);
	weak_label(context, "INT_MASK_WORD", 0xFFFF8032);
	weak_label(context, "INT_MASK", 0xFFFF8033);
	weak_label(context, "CDD_FADER", 0xFFFF8034);
	weak_label(context, "CDD_CTRL_WORD", 0xFFFF8036);
	weak_label(context, "CDD_CTRL_BYTE", 0xFFFF8037);
}

void add_upd7823x_labels(disasm_context *context)
{
	weak_label(context, "P0", 0xFF00);
	weak_label(context, "P1", 0xFF01);
	weak_label(context, "P2", 0xFF02);
	weak_label(context, "P3", 0xFF03);
	weak_label(context, "P4", 0xFF04);
	weak_label(context, "P5", 0xFF05);
	weak_label(context, "P6", 0xFF06);
	weak_label(context, "P7", 0xFF07);
	weak_label(context, "P0L", 0xFF0A);
	weak_label(context, "P0B", 0xFF0B);
	weak_label(context, "RTPC", 0xFF0C);
	weak_label(context, "CR00", 0xFF10);
	weak_label(context, "CR01", 0xFF12);
	weak_label(context, "CR10", 0xFF14);
	weak_label(context, "CR20", 0xFF15);
	weak_label(context, "CR21", 0xFF16);
	weak_label(context, "CR30", 0xFF17);
	weak_label(context, "CR02", 0xFF18);
	weak_label(context, "CR22", 0xFF1A);
	weak_label(context, "CR11", 0xFF1C);
	weak_label(context, "PM0", 0xFF20);
	weak_label(context, "PM1", 0xFF21);
	weak_label(context, "PM3", 0xFF23);
	weak_label(context, "PM5", 0xFF25);
	weak_label(context, "PM6", 0xFF26);
	weak_label(context, "CRC0", 0xFF30);
	weak_label(context, "TOC", 0xFF31);
	weak_label(context, "CRC1", 0xFF32);
	weak_label(context, "CRC2", 0xFF34);
	weak_label(context, "PUO", 0xFF40);
	weak_label(context, "PMC3", 0xFF43);
	weak_label(context, "TM0", 0xFF50);
	weak_label(context, "TM1", 0xFF52);
	weak_label(context, "TM2", 0xFF54);
	weak_label(context, "TM3", 0xFF56);
	weak_label(context, "PRM0", 0xFF5C);
	weak_label(context, "TMC0", 0xFF5D);
	weak_label(context, "PRM1", 0xFF5E);
	weak_label(context, "TMC1", 0xFF5F);
	weak_label(context, "DACS0", 0xFF60);
	weak_label(context, "DACS1", 0xFF61);
	weak_label(context, "ADM", 0xFF68);
	weak_label(context, "ADCR", 0xFF6A);
	weak_label(context, "PWMC", 0xFF70);
	weak_label(context, "PWM0", 0xFF72);
	weak_label(context, "PWM1", 0xFF74);
	weak_label(context, "OSPC", 0xFF7D);
	weak_label(context, "CSIM", 0xFF80);
	weak_label(context, "SBIC", 0xFF82);
	weak_label(context, "SIO", 0xFF86);
	weak_label(context, "ASIM", 0xFF88);
	weak_label(context, "ASIS", 0xFF8A);
	weak_label(context, "RxB", 0xFF8C);
	weak_label(context, "TxS", 0xFF8E);
	weak_label(context, "BRGC", 0xFF90);
	weak_label(context, "STBC", 0xFFC0);
	weak_label(context, "MM", 0xFFC4);
	weak_label(context, "PW", 0xFFC5);
	weak_label(context, "RFM", 0xFFC6);
	weak_label(context, "IMS", 0xFFCF);
	weak_label(context, "IF0L", 0xFFE0);
	weak_label(context, "IF0H", 0xFFE1);
	weak_label(context, "MK0L", 0xFFE4);
	weak_label(context, "MK0H", 0xFFE5);
	weak_label(context, "PR0L", 0xFFE8);
	weak_label(context, "PR0H", 0xFFE9);
	weak_label(context, "ISM0L", 0xFFEC);
	weak_label(context, "ISM0H", 0xFFED);
	weak_label(context, "INTM0", 0xFFF4);
	weak_label(context, "INTM1", 0xFFF5);
	weak_label(context, "IST", 0xFFF8);
}

static void prefixed_label(disasm_context *context, const char *prefix, const char *name, uint32_t address)
{
	if (prefix) {
		char *tmp = alloc_concat(prefix, name);
		add_label(context, tmp, address);
		free(tmp);
	} else {
		add_label(context, name, address);
	}
}

void process_sh2_vectors(disasm_context *context, uint16_t *table, const char *prefix, uint32_t offset, uint8_t labels_only)
{
	static const char* names[] = {
		"illegal_instruction",
		NULL,
		"slot_illegal_instruction",
		NULL,
		"cpu_address_error",
		"dma_address_error",
		"nmi",
		"user_break"
	};
	uint32_t address = table[0] << 16 | table[1];
	prefixed_label(context, prefix, "power_on_reset", address);
	if (!labels_only) {
		defer_disasm(context, address);
	}
	address = table[4] << 16 | table[5];
	prefixed_label(context, prefix, "manual_reset", address);
	if (!labels_only) {
		defer_disasm(context, address);
	}
	
	for (int i = 0; i < sizeof(names)/sizeof(*names); i++)
	{
		if (!names[i]) {
			continue;
		}
		address = table[i*2+8] << 16 | table[i*2 + 9];
		prefixed_label(context, prefix, names[i], address);
		if (!labels_only) {
			defer_disasm(context, address);
		}
	}
	if (!labels_only) {
		visit(context, offset);
		label_def *def = reference(context, offset);
		def->data_count = 13;
		def->data_size = 4;
		def->is_pointer = 1;
	}

	char trap_name[] = "trap_00";
	for (int i = 0; i < 32; i++)
	{
		if (i < 0x10) {
			trap_name[5] = i < 0xA ? '0' + i : 'a' + i - 0xA;
			trap_name[6] = 0;
		} else {
			char c = i >> 4;
			trap_name[5] = c < 0xA ? '0' + c : 'a' + c - 0xA;
			c = i & 0xF;
			trap_name[6] = c < 0xA ? '0' + c : 'a' + c - 0xA;
		}
		address = table[i*2+64] << 16 | table[i*2 + 65];
		prefixed_label(context, prefix, trap_name, address);
		if (!labels_only) {
			defer_disasm(context, address);
		}
	}
	if (!labels_only) {
		visit(context, offset + 0x80);
		label_def *def = reference(context, offset + 0x80);
		def->data_count = 32;
		def->data_size = 4;
		def->is_pointer = 1;
	}

	char int_name[] = "irl_1_0";
	for (int i = 0; i < 8; i++)
	{
		if (i) {
			int num = i * 2;
			int_name[4] = num < 0xA ? '0' + num : 'A' + num - 0xA;
			int_name[5] = '_';
			num++;
			int_name[6] = num < 0xA ? '0' + num : 'A' + num - 0xA;
		} else {
			int_name[5] = 0;
		}
		address = table[i*2+128] << 16 | table[i*2 + 129];
		prefixed_label(context, prefix, int_name, address);
		if (!labels_only) {
			defer_disasm(context, address);
		}
	}
	if (!labels_only) {
		visit(context, offset + 0x100);
		label_def *def = reference(context, offset + 0x100);
		def->data_count = 8;
		def->data_size = 4;
		def->is_pointer = 1;
	}
}

disasm_context *create_68000_disasm(void)
{
	disasm_context *context = calloc(1, sizeof(disasm_context));
	context->address_mask = 0xFFFFFF;
	context->invalid_inst_addr_mask = 1;
	context->visit_preshift = 1;
	return context;
}

disasm_context *create_z80_disasm(void)
{
	disasm_context *context = calloc(1, sizeof(disasm_context));
	context->address_mask = 0xFFFF;
	context->invalid_inst_addr_mask = 0;
	context->visit_preshift = 0;
	return context;
}

disasm_context *create_upd78k2_disasm(void)
{
	disasm_context *context = calloc(1, sizeof(disasm_context));
	context->address_mask = 0xFFFF;
	context->invalid_inst_addr_mask = 0;
	context->visit_preshift = 0;
	return context;
}

disasm_context *create_sh2_disasm(void)
{
	disasm_context *context = calloc(1, sizeof(disasm_context));
	context->address_mask = 0x7FFFFFF;
	context->invalid_inst_addr_mask = 1;
	context->visit_preshift = 1;
	return context;
}
