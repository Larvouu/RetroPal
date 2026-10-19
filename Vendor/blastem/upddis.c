#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include "upd78k2_dis.h"
#include "util.h"

typedef struct {
	uint16_t address_off;
	uint16_t address_end;
	uint8_t *buffer;
} rom_def;

uint8_t fetch(uint16_t address, void *data)
{
	rom_def *rom = data;
	if (address >= rom->address_off && address < rom->address_end) {
		return rom->buffer[(address - rom->address_off)];
	}
	return 0;
}

void print_label_def(char *key, tern_val val, uint8_t valtype, void *data)
{
	rom_def *rom = data;
	label_def *label = val.ptrval;
	uint32_t address = label->full_address & 0xFFFF;
	if (address >= rom->address_off && address < rom->address_end) {
		return;
	}
	if (!label->referenced) {
		return;
	}
	if (label->num_labels) {
		for (int i = 0; i < label->num_labels; i++)
		{
			printf("%s equ 0%XH\n", label->labels[i], label->full_address);
		}
	} else {
		printf("ADR_%X equ 0%XH\n", label->full_address, label->full_address);
	}
}

void format_data(disasm_context *context, rom_def *rom, uint8_t labels, uint16_t start_address, uint16_t end_address)
{
	char label_buf[256];
	for (uint16_t address = start_address; address < end_address;)
	{
		if (labels) {
			uint16_t end = address + 8;
			if (end > end_address) {
				end = end_address;
			}
			uint16_t start = address;
			if (!(address & 1) && address < 0x80) {
				for (; address < end; address += 2) {
					uint16_t value = fetch(address, rom);
					value |= fetch(address + 1, rom) << 8;
					format_label(label_buf, value, context);
					if (address == start) {
						printf("\tdw %s", label_buf);
					} else {
						printf(", %s", label_buf);
					}
				}
			} else {
				if (address < 0x80) {
					end = address + 1;
				}
				for (; address < end; address++) {
					uint8_t value = fetch(address, rom);
					if (address == start) {
						printf("\tdb 0%02XH", value);
					} else {
						printf(", 0%02XH", value);
					}
				}
			}
			address = end;
			puts("");
		} else {
			uint8_t value = fetch(address, rom);
			printf("%X: %X\n", address, value);
			address++;
		}
	}
}

int main(int argc, char ** argv)
{
	long filesize;
	uint8_t *filebuf = NULL;
	char disbuf[1024];

	uint8_t labels = 0, addr = 0, only = 0, reset = 0;
	disasm_context *context = create_upd78k2_disasm();
	
	uint32_t address_off = 0, address_end;
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
			case 'r':
				reset = 1;
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
						char *end;
						uint32_t address = strtol(disbuf, &end, 16);
						if (address) {
							if (address >= 0x80) {
								defer_disasm(context, address);
							}
							if (*end == '=') {
								add_label(context, strip_ws(end+1), address);
							} else {
								reference(context, address);
							}
						}
					}
				}
				fclose(address_log);
			}
		} else {
			char *end;
			uint32_t address = strtol(argv[opt], &end, 16);
			defer_disasm(context, address);
			if (*end == '=') {
				add_label(context, end+1, address);
			} else {
				reference(context, address);
			}
		}
	}
	if (labels) {
		add_upd7823x_labels(context);
	}
	FILE * f = fopen(argv[1], "rb");
	fseek(f, 0, SEEK_END);
	filesize = ftell(f);
	fseek(f, 0, SEEK_SET);

	char int_key[MAX_INT_KEY_SIZE];
	uint8_t has_manual_defs = !!context->deferred;
	filebuf = malloc(filesize);
	if (fread(filebuf, 1, filesize, f) != filesize)
	{
		fprintf(stderr, "Failure while reading file %s\n", argv[1]);
	}
	address_end = address_off + filesize;
	if (address_end > 0xFB00) {
		//correct for uPD78237 and some other members of the uPD78K/II family
		//but others allow external ROM up to higher addresses
		address_end = 0xFB00;
	}
	if (!address_off && filesize >= 0x40) {
		char *vector_names[] = {
			"reset",
			"nmi",
			NULL,
			"intp0",
			"intp1",
			"intp2",
			"intp3",
			"intp4_intc30",
			"intp5_intad",
			"intc20_intp6",
			"intc00",
			"intc01",
			"intc10",
			"intc11",
			"intc21",
			NULL,
			"intser",
			"intsr",
			"intst",
			"intcsi",
			[0x3E/2] = "brkex"
		};
		for (int i = 0; i < sizeof(vector_names)/sizeof(*vector_names); i++)
		{
			if (vector_names[i]) {
				uint16_t address = filebuf[i * 2] | (filebuf[i * 2 + 1] << 8);
				if (address < address_end) {
					defer_disasm(context, address);
					add_label(context, vector_names[i], address);
				}
			}
		}
	}
	rom_def rom = {
		.address_off = address_off,
		.address_end = address_end,
		.buffer = filebuf
	};
	uint16_t address, tmp_addr;
	uint8_t valid_address;
	while(context->deferred) {
		do {
			valid_address = 0;
			address = context->deferred->address;
			if (!is_visited(context, address)) {
				address &= context->address_mask;
				if (address < address_end && address >= address_off) {
					valid_address = 1;
					address = context->deferred->address;
				}
			}
			deferred_addr *tmpd = context->deferred;
			context->deferred = context->deferred->next;
			free(tmpd);
		} while(context->deferred && !valid_address);
		if (!valid_address) {
			break;
		}
		for(;;) {
			if ((address & context->address_mask) > address_end || address < address_off) {
				break;
			}
			visit(context, address);
			upd_address_ref ref;
			address = upd78k2_disasm(disbuf, &ref, address, fetch, &rom, NULL);
			if (!strcmp(disbuf, "invalid") || startswith(disbuf, "ret")) {
				break;
			}
			switch(ref.ref_type)
			{
			case UPD_REF_NONE:
				if (startswith(disbuf, "br ")) {
					//unconditional branch to register
					goto loop_end;
				}
				break;
			case UPD_REF_OP:
				reference(context, ref.address);
				break;
			case UPD_REF_2OP:
				reference(context, ref.address);
				reference(context, ref.address2);
				break;
			case UPD_REF_BRANCH:
				reference(context, ref.address);
				if (ref.address <= address) {
					defer_disasm(context, ref.address);
					goto loop_end;
				} else {
					address = ref.address;
				}
				break;
			case UPD_REF_COND_BRANCH:
			case UPD_REF_CALL:
				reference(context, ref.address);
				defer_disasm(context, ref.address);
				break;
			case UPD_REF_OP_BRANCH:
				reference(context, ref.address);
				reference(context, ref.address2);
				defer_disasm(context, ref.address2);
				break;
			case UPD_REF_CALL_TABLE:
				reference(context, ref.address);
				if (ref.address >= address_off && ref.address < address_end - 1) {
					uint16_t table_address = ref.address;
					ref.address = fetch(table_address, &rom);
					ref.address |= fetch(table_address + 1, &rom) << 8;
					reference(context, ref.address);
					defer_disasm(context, ref.address);
				}
				break;
			}
		}
loop_end: ;
	}
	if (labels) {
		tern_foreach(context->labels, print_label_def, &rom);
		puts("");
	}
	uint16_t data_start = 0xFFFF;
	for (address = address_off; address < address_end;) {
		if (labels) {
			label_def *label = find_label(context, address);
			if (label) {
				if (data_start < address) {
					format_data(context, &rom, labels, data_start, address);
					data_start = 0xFFFF;
				}
				if (label->num_labels) {
					for (int i = 0; i < label->num_labels; i++)
					{
						printf("%s:\n", label->labels[i]);
					}
				} else {
					printf("ADR_%X:\n", label->full_address);
				}
			}
		}
		if (is_visited(context, address)) {
			if (data_start < address) {
				format_data(context, &rom, labels, data_start, address);
				data_start = 0xFFFF;
			}
			uint16_t next = upd78k2_disasm(disbuf, NULL, address, fetch, &rom, labels ? context : NULL);
			if (labels) {
				if (addr) {
					printf("\t%s\t;%X\n", disbuf, address);
				} else {
					printf("\t%s\n", disbuf);
				}
			} else {
				printf("%X: %s\n", address, disbuf);
			}
			address = next;
		} else {
			if (data_start > address) {
				data_start = address;
			}
			address++;
		}
	}
	if (data_start < address) {
		format_data(context, &rom, labels, data_start, address);
	}
	return 0;
}