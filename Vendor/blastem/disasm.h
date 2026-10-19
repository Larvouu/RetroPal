#ifndef DISASM_H_
#define DISASM_H_

#include <stdint.h>
#include "tern.h"
#include "backend.h"

typedef struct {
	char     **labels;
	uint32_t num_labels;
	uint32_t storage;
	uint32_t full_address;
	uint32_t data_count;
	uint8_t  referenced;
	uint8_t  data_size;
	uint8_t  is_pointer;
} label_def;

typedef struct {
	tern_node     *labels;
	tern_node     *labels_by_name;
	uint8_t       *visited;
	deferred_addr *deferred;
	uint32_t      address_mask;
	uint32_t      invalid_inst_addr_mask;
	uint32_t      visit_preshift;
} disasm_context;

typedef int (*format_label_fun)(char * dst, uint32_t address, disasm_context * context);

label_def *find_label(disasm_context *context, uint32_t address);
label_def *find_label_by_name(disasm_context *context, const char *name);
int format_label(char *dst, uint32_t address, disasm_context *context);
void name_label(disasm_context *context, label_def *def, const char *name);
label_def *weak_label(disasm_context *context, const char *name, uint32_t address);
label_def *reference(disasm_context *context, uint32_t address);
label_def *add_label(disasm_context *context, const char *name, uint32_t address);
void visit(disasm_context *context, uint32_t address);
uint8_t is_visited(disasm_context *context, uint32_t address);
void defer_disasm_label(disasm_context *context, uint32_t address, label_def *label);
void defer_disasm(disasm_context *context, uint32_t address);
void process_address_def(disasm_context *context, char *def);
void process_m68k_vectors(disasm_context *context, uint16_t *table, uint8_t labels_only);
void process_sh2_vectors(disasm_context *context, uint16_t *table, const char *prefix, uint32_t offset, uint8_t labels_only);
void add_segacd_maincpu_labels(disasm_context *context);
void add_segacd_subcpu_labels(disasm_context *context);
disasm_context *create_68000_disasm(void);
disasm_context *create_z80_disasm(void);
disasm_context *create_upd78k2_disasm(void);
disasm_context *create_sh2_disasm(void);
void add_upd7823x_labels(disasm_context *context);

#endif //DISASM_H_
