#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sh2_decode.h"
#include "util.h"

typedef struct {
	uint32_t address_off;
	uint32_t address_end;
	uint16_t *buffer;
} rom_def;

void print_label_def(char *key, tern_val val, uint8_t valtype, void *data)
{
	rom_def *rom = data;
	label_def *label = val.ptrval;
	uint32_t address = label->full_address & 0xFFFFFFF;
	if (address >= rom->address_off && address < rom->address_end) {
		return;
	}
	if (!label->referenced) {
		return;
	}
	if (label->num_labels) {
		for (int i = 0; i < label->num_labels; i++)
		{
			printf(".equ %s, $%X\n", label->labels[i], label->full_address);
		}
	} else {
		printf(".equ ADR_%X, $%X\n", label->full_address, label->full_address);
	}
}

uint16_t fetch(uint32_t address, void *data)
{
	rom_def *rom = data;
	address &= 0x7FFFFFF;
	if (address >= rom->address_off && address < rom->address_end) {
		return rom->buffer[(address - rom->address_off) >> 1];
	}
	return 0;
}

enum {
	XPCT_NONE,
	XPCT_STARTOFF,
	XPCT_ADDRLOG,
};

void expect_error(int expect)
{
	switch (expect)
	{
	case XPCT_STARTOFF:
		fputs("-s must be followed by an offset\n", stderr);
		exit(1);
	case XPCT_ADDRLOG:
		fputs("-f must be followed by a filename\n", stderr);
		exit(1);
	}
}

int main(int argc, char **argv)
{
	sh2_inst inst;
	disasm_context *context = create_sh2_disasm();
	char disbuf[1024];
	
	const char *fname = NULL;
	uint8_t expect = XPCT_NONE;
	uint8_t labels = 0, addr = 0, only = 0;
	uint32_t address_off = 0;
	for (int i = 1; i < argc; i++)
	{
		if (argv[i][0] == '-') {
			expect_error(expect);
			switch (argv[i][1])
			{
			case 'l': labels = 1; break;
			case 'a': addr = 1; break;
			case 'o': only = 1; break;
			case 's': expect = XPCT_STARTOFF; break;
			case 'f': expect = XPCT_ADDRLOG; break;
			}
		} else if (expect != XPCT_NONE) {
			FILE *f;
			switch (expect)
			{
			case XPCT_STARTOFF:
				address_off = strtol(argv[i], NULL, 0);
				break;
			case XPCT_ADDRLOG:
				f = fopen(argv[i], "r");
				if (!f) {
					fprintf(stderr, "Failed to open %s for reading\n", argv[i]);
					return 2;
				}
				while (fgets(disbuf, sizeof(disbuf), f)) {
				 	if (disbuf[0]) {
						process_address_def(context, disbuf);
					}
				}
				fclose(f);
				break;
			}
			expect = XPCT_NONE;
		} else if (!fname) {
			fname = argv[i];
		} else {
			process_address_def(context, argv[i]);
		}
	}
	expect_error(expect);
	FILE *f = fopen(fname, "rb");
	long filesize = file_size(f);
	long words = (filesize + 1) >> 1;
	uint16_t *filebuf = calloc(words, sizeof(uint16_t));
	if (fread(filebuf, sizeof(uint16_t), words, f) != words) {
		fprintf(stderr, "Failure while reading file %s\n", fname);
	}
	uint32_t address_end = address_off + filesize;
	byteswap_rom(filesize, filebuf);
	uint32_t address_off_alt =0, address_end_alt = 0;
	uint16_t *filebuf_alt = NULL;
	if (!address_off && filesize >= 0x800 && !memcmp(filebuf + 0x80, "ESAG", 4)) {
		uint32_t sh2_code_offset = filebuf[0x3D4>>1] << 16 | filebuf[0x3D4>>1|1];
		uint32_t sh2_dest = filebuf[0x3D8>>1] << 16 | filebuf[0x3D8>>1|1];
		uint32_t sh2_code_size = filebuf[0x3DC>>1] << 16 | filebuf[0x3DC>>1|1];
		if (sh2_code_offset < filesize && (sh2_code_offset + sh2_code_size) <= filesize && sh2_dest < 0x40000) {
			// appears to have a valid 32X SH2 code header
			uint32_t main_sh2_start = filebuf[0x3E0>>1] << 16 | filebuf[0x3E0>>1|1];
			uint32_t sub_sh2_start = filebuf[0x3E4>>1] << 16 | filebuf[0x3E4>>1|1];
			uint32_t main_vbr = filebuf[0x3E8>>1] << 16 | filebuf[0x3E8>>1|1];
			uint32_t sub_vbr = filebuf[0x3EC>>1] << 16 | filebuf[0x3EC>>1|1];
			address_off = 0x6000000 + sh2_dest;
			address_off_alt = 0x2000000;
			address_end_alt = address_off_alt + address_end;
			filebuf_alt = filebuf;
			filebuf += sh2_code_offset >> 1;
			address_end = address_off + sh2_code_size;
			defer_disasm(context, main_sh2_start);
			add_label(context, "main_sh2_start", main_sh2_start);
			defer_disasm(context, sub_sh2_start);
			add_label(context, "sub_sh2_start", sub_sh2_start);
			if (main_vbr >= address_off && main_vbr + 0x100 + 15 * 4 <= address_end) {
				process_sh2_vectors(context, filebuf + ((main_vbr - address_off) >> 1), "main_", main_vbr, only);
			} else if (main_vbr >= address_off_alt && main_vbr + 0x100 + 15 * 4 <= address_end_alt) {
				process_sh2_vectors(context, filebuf_alt + ((main_vbr - address_off_alt) >> 1), "main_", main_vbr, only);
			}
			if (sub_vbr >= address_off && sub_vbr + 0x100 + 15 * 4 <= address_end) {
				process_sh2_vectors(context, filebuf + ((sub_vbr - address_off) >> 1), "sub_", sub_vbr, only);
			} else if (sub_vbr >= address_off_alt && sub_vbr + 0x100 + 15 * 4 <= address_end_alt) {
				process_sh2_vectors(context, filebuf_alt + ((sub_vbr - address_off_alt) >> 1), "sub_", sub_vbr, only);
			}
		}
	}
	if (!address_off) {
		process_sh2_vectors(context, filebuf, NULL, 0, context->deferred && only);
	}
	uint32_t address;
	uint8_t valid_address;
	uint8_t use_alt = 0;
	while(context->deferred) {
		do {
			valid_address = 0;
			address = context->deferred->address;
			label_def *def = (label_def *)context->deferred->dest;
			deferred_addr *tmpd = context->deferred;
			context->deferred = context->deferred->next;
			free(tmpd);
			
			if (def) {
				visit(context, address);
				if (def->is_pointer) {
					for (uint32_t i = 0; i < def->data_count; i++, address += 4)
					{
						uint32_t masked = address & context->address_mask;
						if (masked < address_end - 2 && masked >= address_off) {
							uint32_t target = filebuf[(masked - address_off) >> 1] << 16;
							masked += 2;
							target |= filebuf[(masked - address_off) >> 1];
							defer_disasm(context, target);
							reference(context, target);
						} else if (masked < address_end_alt - 2 && masked >= address_off_alt) {
							uint32_t target = filebuf_alt[(masked - address_off_alt) >> 1] << 16;
							masked += 2;
							target |= filebuf_alt[(masked - address_off_alt) >> 1];
							defer_disasm(context, target);
							reference(context, target);
							use_alt = 1;
						}
					}
				}
			} else if (!is_visited(context, address)) {
				uint32_t masked = address & context->address_mask;
				if (masked < address_end && masked >= address_off) {
					valid_address = 1;
				} else if (masked < address_end_alt && masked >= address_off_alt) {
					valid_address = 1;
					use_alt = 1;
				}
			}
		} while (context->deferred && !valid_address);
		if (!valid_address) {
			break;
		}
		uint8_t should_break = 0;
		uint16_t *curbuf = filebuf;
		uint32_t cur_off = address_off;
		uint32_t cur_end = address_end;
		while(!should_break)
		{
			if ((address & context->address_mask) > address_end || (address & context->address_mask) < address_off) {
				if ((address & context->address_mask) < address_end_alt && (address & context->address_mask) >= address_off_alt) {
					curbuf = filebuf_alt;
					cur_off = address_off_alt;
					cur_end = address_end_alt;
					use_alt = 1;
				} else {
					break;
				}
			}
			visit(context, address);
			inst = sh2_decode(curbuf[((address & context->address_mask) - cur_off) >> 1]);
			uint32_t tmpaddr;
			switch (inst.opcode)
			{
			case SH2_RTS:
			case SH2_RTE:
			case SH2_JMP:
			case SH2_BRAF:
				visit(context, address + 2);
			case SH2_INVALID:
				should_break = 1;
				break;
			case SH2_BRA:
				visit(context, address + 2);
				address += inst.immed + 4;
				reference(context, address);
				should_break = is_visited(context, address);
				break;
			case SH2_BSR:
			case SH2_BF:
			case SH2_BFS:
			case SH2_BT:
			case SH2_BTS:
				tmpaddr = address + inst.immed + 4;
				reference(context, tmpaddr);
				defer_disasm(context, tmpaddr);
				address += 2;
				break;
			case SH2_MOVW:
			case SH2_MOVL:
				if (inst.src == SH2_DISP_PC) {
					tmpaddr = address + 4;
					if (inst.opcode == SH2_MOVL) {
						tmpaddr &= ~3;
					}
					tmpaddr += inst.immed;
					label_def *def = reference(context, tmpaddr); 
					def->data_count = 1;
					def->data_size = inst.opcode == SH2_MOVL ? 4 : 2;
					uint32_t masked = tmpaddr & context->address_mask;
					if (!def->num_labels && masked >= cur_off && masked < cur_end) {
						char name[128];
						uint32_t value = curbuf[(masked - cur_off) >> 1];
						if (inst.opcode == SH2_MOVL && (masked + 2) < cur_end) {
							value <<= 16;
							value |= curbuf[(masked + 2 - cur_off) >> 1];
						}
						sprintf(name, "CONST_%X", value);
						uint32_t version = 0;
						label_def *existing;
						do {
							existing = find_label_by_name(context, name);
							if (existing) {
								version++;
								sprintf(name, "CONST_%X_%d", value, version);
							}
						} while (existing != NULL);
						name_label(context, def, name);
					}
					visit(context, tmpaddr);
				}
			default:
				address += 2;
				break;
			}
			if (should_break) {	
				break;
			}
		}
	}
	uint32_t main_address_off = address_off;
	uint32_t main_address_end = address_end;
	uint16_t *filebuf_main = filebuf;
	for (int sect = 0; sect < (use_alt + 1); sect++)
	{
		if (sect) {
			if (main_address_off > address_off_alt) {
				address_off = main_address_off;
				address_end = main_address_end;
				filebuf = filebuf_main;
			} else {
				address_off = address_off_alt;
				address_end = address_end_alt;
				filebuf = filebuf_alt;
			}
		} else if (use_alt) {
			if (main_address_off > address_off_alt) {
				address_off = address_off_alt;
				address_end = address_end_alt;
				filebuf = filebuf_alt;
			} else {
				address_off = main_address_off;
				address_end = main_address_end;
				filebuf = filebuf_main;
			}
		}
		rom_def rom = {address_off, address_end, filebuf};
		if (labels) {
			tern_foreach(context->labels, print_label_def, &rom);
			puts("");
		}
		for (address = address_off; address < address_end;) {
			if (is_visited(context, address)) {
				if (labels) {
					label_def *label = find_label(context, address);
					if (!label && !(address & 1)) {
						label = find_label(context, address + 1);
						if (label) {
							uint8_t val = fetch(address, &rom) >> 8;
							printf("\t.byte %02X\n", val);
							address++;
						}
					}
					if (label) {
						if (label->num_labels) {
							for (int i = 0; i < label->num_labels; i++)
							{
								printf("%s:\n", label->labels[i]);
							}
						} else {
							printf("ADR_%X:\n", label->full_address);
						}
						if (label->data_size) {
							uint32_t els_per_line = 16 / label->data_size;
							for (uint32_t i = 0; i < label->data_count;)
							{
								printf("\t.%s ", label->data_size < 2 ? "byte" : label->data_size < 4 ? "word" : "long");
								for (uint32_t j = 0; j < els_per_line && i < label->data_count; i++,j++)
								{
									uint32_t val = fetch(address & ~1, &rom);
									const char *fmt = "$%04X";
									if (label->data_size == 1) {
										val = address & 1 ? val & 0xFF : val >> 8;
										fmt = "$%02X";
									} else if (label->data_size == 4) {
										val <<= 16;
										val |= fetch(address + 2, &rom);
										if (label->is_pointer) {
											format_label(disbuf, val, context);
											fmt = NULL;
											fputs(disbuf, stdout);
										} else {
											fmt = "$%08X";
										}
									}
									if (fmt) {
										printf(fmt, val);
									}
									if (j == els_per_line - 1 || i == label->data_count - 1) {
										puts("");
									} else {
										fputs(", ", stdout);
									}
									address += label->data_size;
								}
							}
						}
					}
					if (!label || !label->data_size) {
						if (address & 1) {
							uint8_t val = fetch(address & ~1, &rom);
							printf("\t.byte %02X\n", val);
							address++;
						}
						inst = sh2_decode(fetch(address, &rom));
						sh2_disasm(disbuf, inst, address, context);
						if (addr) {
							printf("\t%s\t!%X\n", disbuf, address);
						} else {
							printf("\t%s\n", disbuf);
						}
						address += 2;
					}
				} else {
					inst = sh2_decode(fetch(address, &rom));
					sh2_disasm(disbuf, inst, address, context);
					printf("%X: %s\n", address, disbuf);
					address += 2;
				}
			} else {
				address += 2;
			}
		}
	}
	return 0;
}
