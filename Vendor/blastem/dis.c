/*
 Copyright 2013 Michael Pavone
 This file is part of BlastEm.
 BlastEm is free software distributed under the terms of the GNU General Public License version 3 or greater. See COPYING for full license text.
*/
#include "68kinst.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <ctype.h>
#include "vos_program_module.h"
#include "tern.h"
#include "util.h"
#include "disasm.h"

void check_reference(disasm_context *context, m68kinst * inst, m68k_op_info * op)
{
	label_def *def = NULL;
	switch(op->addr_mode)
	{
	case MODE_PC_DISPLACE:
		def = reference(context, inst->address + 2 + op->params.regs.displacement);
		break;
	case MODE_ABSOLUTE:
	case MODE_ABSOLUTE_SHORT:
		def = reference(context, op->params.immed);
		break;
	}
	if (
		def && !def->data_size && inst->op != M68K_JMP && 
		inst->op != M68K_JSR && inst->op != M68K_LEA && inst->op != M68K_PEA
	) {
		def->data_count = 1;
		def->data_size = inst->extra.size == OPSIZE_WORD ? 2 : inst->extra.size == OPSIZE_BYTE ? 1 : 4;
		visit(context, def->full_address);
	}
}

typedef struct {
	uint32_t address_off;
	uint32_t address_end;
	uint16_t *buffer;
} rom_def;

uint16_t fetch(uint32_t address, void *data)
{
	rom_def *rom = data;
	address &= 0xFFFFFF;
	if (address >= rom->address_off && address < rom->address_end) {
		return rom->buffer[(address - rom->address_off) >> 1];
	}
	return 0;
}

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
			printf("%s equ $%X\n", label->labels[i], label->full_address);
		}
	} else {
		printf("ADR_%X equ $%X\n", label->full_address, label->full_address);
	}
}

int main(int argc, char ** argv)
{
	long filesize;
	unsigned short *filebuf = NULL;
	char disbuf[1024];
	m68kinst instbuf;
	unsigned short * cur;

	uint8_t labels = 0, addr = 0, only = 0, vos = 0, reset = 0;
	disasm_context *context = create_68000_disasm();


	uint32_t address_off = 0, address_end;
	uint8_t do_cd_labels = 0, main_cpu = 0;
	for(uint8_t opt = 2; opt < argc; ++opt) {
		if (argv[opt][0] == '-') {
			FILE * address_log;
			switch (argv[opt][1])
			{
			case 'l':
				labels = 1;
				break;
			case 'a':
				addr = 1;
				break;
			case 'o':
				only = 1;
				break;
			case 'v':
				vos = 1;
				break;
			case 'r':
				reset = 1;
				break;
			case 'c':
				do_cd_labels = 1;
				break;
			case 'm':
				main_cpu = 1;
				break;
			case 's':
				opt++;
				if (opt >= argc) {
					fputs("-s must be followed by an offset\n", stderr);
					exit(1);
				}
				address_off = strtol(argv[opt], NULL, 0);
				break;
			case 'f':
				opt++;
				if (opt >= argc) {
					fputs("-f must be followed by a filename\n", stderr);
					exit(1);
				}
				address_log = fopen(argv[opt], "r");
				if (!address_log) {
					fprintf(stderr, "Failed to open %s for reading\n", argv[opt]);
					exit(1);
				}
				while (fgets(disbuf, sizeof(disbuf), address_log)) {
				 	if (disbuf[0]) {
						process_address_def(context, disbuf);
					}
				}
				fclose(address_log);
			}
		} else {
			process_address_def(context, argv[opt]);
		}
	}
	FILE * f = fopen(argv[1], "rb");
	fseek(f, 0, SEEK_END);
	filesize = ftell(f);
	fseek(f, 0, SEEK_SET);

	char int_key[MAX_INT_KEY_SIZE];
	uint8_t is_scd_iso = 0;
	uint8_t has_manual_defs = !!context->deferred;
	if (vos)
	{
		vos_program_module header;
		vos_read_header(f, &header);
		vos_read_alloc_module_map(f, &header);
		address_off = header.user_boundary;
		address_end = address_off + filesize - 0x1000;
		defer_disasm(context, header.main_entry_link.code_address);
		add_label(context, "main_entry_link", header.main_entry_link.code_address);
		for (int i = 0; i < header.n_modules; i++)
		{
			if (!reset || header.module_map_entries[i].code_address != header.user_boundary)
			{
				defer_disasm(context, header.module_map_entries[i].code_address);
			}
			add_label(context, header.module_map_entries[i].name.str, header.module_map_entries[i].code_address);
		}
		fseek(f, 0x1000, SEEK_SET);
		filebuf = malloc(filesize - 0x1000);
		if (fread(filebuf, 2, (filesize - 0x1000)/2, f) != (filesize - 0x1000)/2)
		{
			fprintf(stderr, "Failure while reading file %s\n", argv[1]);
		}
		fclose(f);
		for(cur = filebuf; cur - filebuf < ((filesize - 0x1000)/2); ++cur)
		{
			*cur = (*cur >> 8) | (*cur << 8);
		}
		if (reset)
		{
			defer_disasm(context, filebuf[2] << 16 | filebuf[3]);
			add_label(context, "reset", filebuf[2] << 16 | filebuf[3]);
		}
	} else if (filesize > 0x1000) {
		long boot_size = filesize > (16*2352) ? 16*2352 : filesize;
		filebuf = malloc(boot_size);
		if (fread(filebuf, 1, boot_size, f) != boot_size) {
			fprintf(stderr, "Failure while reading file %s\n", argv[1]);
			return 1;
		}
		is_scd_iso = !memcmp("SEGADISCSYSTEM  ", filebuf, 0x10);
		if (!is_scd_iso && !memcmp("SEGADISCSYSTEM  ", filebuf + 0x8, 0x10)) {
			is_scd_iso = 1;
			uint32_t end = 16 * 2352;
			if (end > filesize) {
				end = (filesize / 2352) * 2352;
			}
			for(uint32_t offset = 0x10, dst_offset = 0; offset < end; offset += 2352, dst_offset += 2048)
			{
				memmove(filebuf + dst_offset/2, filebuf + offset/2, 2048);
			}
			boot_size = (end / 2352) * 2048;
		}
		if (is_scd_iso) {
			fclose(f);
			for(cur = filebuf; cur - filebuf < (boot_size/2); ++cur)
			{
				*cur = (*cur >> 8) | (*cur << 8);
			}
			if (main_cpu) {
				uint32_t main_start = 0x200;
				uint32_t extra_start = filebuf[0x30/2] << 16 | filebuf[0x32/2];
				uint32_t main_end = (filebuf[0x34/2] << 16 | filebuf[0x36/2]) + extra_start;
				if (main_end > boot_size) {
					main_end = boot_size;
				}
				address_off = 0xFF0000;
				address_end = address_off + main_end-main_start;
				filebuf += main_start / 2;
				add_label(context, "start", 0xFF0000);
				if (!has_manual_defs || !only) {
					defer_disasm(context, 0xFF0000);
				}
				uint32_t user_start;
				if (filebuf[0xA/2] == 0x57A) {
					//US
					user_start = 0xFF0584;
				} else if (filebuf[0xA/2] == 0x564) {
					//EU
					user_start = 0xFF056E;
				} else {
					//JP
					user_start = 0xFF0156;
				}
				add_label(context, "user_start", user_start);
				do_cd_labels = 1;
			} else {
				uint32_t sub_start =filebuf[0x40/2] << 16 | filebuf[0x42/2];
				sub_start &= ~0x7FF;
				uint32_t sub_end = sub_start + (filebuf[0x44/2] << 16 | filebuf[0x46/2]);
				if (sub_start > (boot_size - 0x20)) {
					fprintf(stderr, "System Program start offset is %X, but image is only %X bytes\n", sub_start, (uint32_t)boot_size);
					return 1;
				}
				if (sub_end > boot_size) {
					sub_end = boot_size;
				}
				uint32_t offset_start = (filebuf[(sub_start + 0x18)/2] << 16 | filebuf[(sub_start + 0x1A)/2]) + sub_start;
				for(uint32_t cur = offset_start, index = 0; cur < sub_end && filebuf[cur/2]; cur+=2, ++index)
				{
					uint32_t offset = offset_start + filebuf[cur/2];
					if (offset >= boot_size) {
						break;
					}
					static const char* fixed_names[3] = {
						"init",
						"main",
						"int_2"
					};
					char namebuf[32];
					const char *name;
					if (index < 3) {
						name = fixed_names[index];
					} else {
						name = namebuf;
						sprintf(namebuf, "usercall%u", index);
					}
					uint32_t address = 0x6000 + offset - sub_start;
					add_label(context, name, address);
					if (!has_manual_defs || !only) {
						defer_disasm(context, address);
					}
				}

				do_cd_labels = 1;
				filebuf += sub_start / 2;
				address_off = 0x6000;
				address_end = sub_end-sub_start + address_off;
			}
		}
	}
	if (!vos && !is_scd_iso) {
		if (filebuf) {
			if (filesize > (32*1024)) {
				filebuf = realloc(filebuf, filesize);
				fseek(f, 32*1024, SEEK_SET);
				uint32_t to_read = filesize/2 - 16*1024;
				if (fread(filebuf + 16*1024, 2, to_read, f) != to_read)
				{
					fprintf(stderr, "Failure while reading file %s\n", argv[1]);
				}
			}
		} else {
			filebuf = malloc(filesize);
			if (fread(filebuf, 2, filesize/2, f) != filesize/2)
			{
				fprintf(stderr, "Failure while reading file %s\n", argv[1]);
			}
		}
		address_end = address_off + filesize;
		fclose(f);
		for(cur = filebuf; cur - filebuf < (filesize/2); ++cur)
		{
			*cur = (*cur >> 8) | (*cur << 8);
		}
		if (!address_off) {
			process_m68k_vectors(context, filebuf, context->deferred && only);
		}
	}
	if (do_cd_labels) {
		if (main_cpu) {
			add_segacd_maincpu_labels(context);
		} else {
			add_segacd_subcpu_labels(context);
		}
	}
	uint32_t size, tmp_addr;
	uint32_t address;
	rom_def rom = {
		.address_off = address_off,
		.address_end = address_end,
		.buffer = filebuf
	};
	uint8_t valid_address;
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
							uint32_t target = rom.buffer[(masked - rom.address_off) >> 1] << 16;
							masked += 2;
							target |= rom.buffer[(masked - rom.address_off) >> 1];
							defer_disasm(context, target);
							reference(context, target);
						}
					}
				}
			}else if (!is_visited(context, address)) {
				uint32_t masked = address & context->address_mask;
				if (masked < address_end && masked >= address_off) {
					valid_address = 1;
				}
			}
		} while(context->deferred && !valid_address);
		if (!valid_address) {
			break;
		}
		for(;;) {
			if ((address & context->address_mask) > address_end || address < address_off) {
				break;
			}
			visit(context, address);
			address = m68k_decode(fetch, &rom, &instbuf, address);
			//m68k_disasm(&instbuf, disbuf);
			//printf("%X: %s\n", instbuf.address, disbuf);
			check_reference(context, &instbuf, &(instbuf.src));
			check_reference(context, &instbuf, &(instbuf.dst));
			if (instbuf.op == M68K_ILLEGAL || instbuf.op == M68K_RTS || instbuf.op == M68K_RTE || instbuf.op == M68K_INVALID) {
				break;
			}
			if (instbuf.op == M68K_BCC || instbuf.op == M68K_DBCC || instbuf.op == M68K_BSR) {
				tmp_addr = instbuf.address + 2 + instbuf.src.params.immed;
				reference(context, tmp_addr);
				if (instbuf.op == M68K_BCC && instbuf.extra.cond == COND_TRUE) {
					address = tmp_addr;
					if (is_visited(context, address)) {
						break;
					}
				} else {
					defer_disasm(context, tmp_addr);
				}
			} else if(instbuf.op == M68K_JMP) {
				if (instbuf.src.addr_mode == MODE_ABSOLUTE || instbuf.src.addr_mode == MODE_ABSOLUTE_SHORT) {
					address = instbuf.src.params.immed;
					if (is_visited(context, address)) {
						break;
					}
				} else if (instbuf.src.addr_mode == MODE_PC_DISPLACE) {
					address = instbuf.src.params.regs.displacement + instbuf.address + 2;
					if (is_visited(context, address)) {
						break;
					}
				} else {
					break;
				}
			} else if(instbuf.op == M68K_JSR) {
				if (instbuf.src.addr_mode == MODE_ABSOLUTE || instbuf.src.addr_mode == MODE_ABSOLUTE_SHORT) {
					defer_disasm(context, instbuf.src.params.immed);
				} else if (instbuf.src.addr_mode == MODE_PC_DISPLACE) {
					defer_disasm(context, instbuf.src.params.regs.displacement + instbuf.address + 2);
				}
			}
		}
	}
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
						printf("\tdc.b %02X\n", val);
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
							printf("\tdc.%c ", label->data_size < 2 ? 'b' : label->data_size < 4 ? 'w' : 'l');
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
						printf("\tdc.b %02X\n", val);
						address++;
					}
					uint32_t after = m68k_decode(fetch, &rom, &instbuf, address);
					m68k_disasm_labels(&instbuf, disbuf, context);
					if (addr) {
						printf("\t%s\t;%X\n", disbuf, instbuf.address);
					} else {
						printf("\t%s\n", disbuf);
					}
					address = after;
				}
			} else {
				uint32_t after = m68k_decode(fetch, &rom, &instbuf, address);
				m68k_disasm(&instbuf, disbuf);
				printf("%X: %s\n", instbuf.address, disbuf);
				address = after;
			}
		} else {
			address += 2;
		}
	}
	return 0;
}
