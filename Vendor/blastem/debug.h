#ifndef DEBUG_H_
#define DEBUG_H_

#include <stdint.h>
#include "tern.h"
#ifdef NEW_CORE
#include "m68k.h"
#include "z80.h"
#else
#include "m68k_core.h"
#include "z80_to_x86.h"
#endif
#include "upd78k2.h"
#include "sh2.h"
#include "disasm.h"

typedef enum {
	TOKEN_NONE,
	TOKEN_INT,
	TOKEN_DECIMAL,
	TOKEN_NAME,
	TOKEN_ARRAY,
	TOKEN_FUNCALL,
	TOKEN_OPER,
	TOKEN_SIZE,
	TOKEN_LBRACKET,
	TOKEN_RBRACKET,
	TOKEN_LPAREN,
	TOKEN_RPAREN,
	TOKEN_STRING
} token_type;

typedef struct {
	token_type type;
	union {
		char     *str;
		char     op[3];
		uint32_t num;
		float    f;
	} v;
} token;

typedef enum {
	EXPR_NONE,
	EXPR_SCALAR,
	EXPR_UNARY,
	EXPR_BINARY,
	EXPR_SIZE,
	EXPR_MEM,
	EXPR_NAMESPACE,
	EXPR_FUNCALL
} expr_type;

typedef struct expr expr;

struct expr {
	expr_type type;
	expr      *left;
	expr      *right;
	token     op;
};

enum {
	DBG_VAL_U32,
	DBG_VAL_F32,
	DBG_VAL_ARRAY,
	DBG_VAL_STRING,
	DBG_VAL_FUNC
};

typedef struct {
	union {
		uint32_t u32;
		float    f32;
	} v;
	uint32_t type;
} debug_val;

typedef struct {
	char      *raw;
	expr      *parsed;
	debug_val value;
} command_arg;

typedef struct debug_root debug_root;
typedef struct parsed_command parsed_command;
typedef uint8_t (*cmd_fun)(debug_root *root, parsed_command *cmd);

typedef struct {
	const char **names;
	const char *usage;
	const char *desc;
	cmd_fun    impl;
	int        min_args;
	int        max_args;
	uint8_t    skip_eval;
	uint8_t    visited;
	uint8_t    has_block;
	uint8_t    accepts_else;
	uint8_t    raw_args;
} command_def;

typedef struct disp_def {
	struct disp_def *next;
	char             *format;
	int              num_args;
	command_arg      *args;
	uint32_t          index;
} disp_def;

typedef struct {
	parsed_command *commands;
	int            num_commands;
} command_block;

typedef debug_val (*debug_native_func)(debug_val *args, int num_args);
typedef struct {
	union {
		debug_native_func native;
		command_block     block;
	} impl;
	char     **arg_names;
	int      max_args;
	int      min_args;
	uint8_t  is_native;
} debug_func;

struct parsed_command {
	command_def   *def;
	uint32_t      func;
	char          *format;
	char          *raw;
	command_arg   *args;
	int           num_args;
	command_block block;
	command_block else_block;
};

enum {
	BP_TYPE_CPU,
	BP_TYPE_CPU_WATCH,
	BP_TYPE_VDPREG,
	BP_TYPE_VDPDMA,
	BP_TYPE_VDPDATA
};

typedef struct bp_def {
	struct bp_def  *next;
	parsed_command *commands;
	expr           *condition;
	uint32_t       num_commands;
	uint32_t       address;
	uint32_t       index;
	uint32_t       mask;
	uint8_t        type;
} bp_def;

typedef struct debug_array debug_array;
typedef debug_val (*debug_array_get)(debug_array *array, uint32_t index);
typedef void (*debug_array_set)(debug_array *array, uint32_t index, debug_val value);
typedef void (*debug_array_append)(debug_array *array, debug_val value);

struct debug_array{
	debug_array_get    get;
	debug_array_set    set;
	debug_array_append append;
	void               *base;
	uint32_t           size;
	uint32_t           storage;
};

typedef struct {
	char     *buffer;
	uint32_t size;
	uint32_t storage;
} debug_string;

typedef struct debug_var debug_var;
typedef debug_val (*debug_var_get)(debug_var *var);
typedef void (*debug_var_set)(debug_var *var, debug_val val);

struct debug_var {
	debug_var_get get;
	debug_var_set set;
	void          *ptr;
	debug_val     val;
};

typedef debug_var *(*resolver)(debug_root *root, const char *name);
typedef uint8_t (*reader)(debug_root *root, uint32_t *out, char size);
typedef uint8_t (*writer)(debug_root *root, uint32_t address, uint32_t value, char size);
typedef uint32_t (*find_chunk_end)(debug_root *root, uint32_t start_address);

struct debug_root {
	void           *cpu_context;
	bp_def         *breakpoints;
	disp_def       *displays;
	tern_node      *commands;
	tern_node      *variables;
	tern_node      *symbols;
	tern_node      *other_roots;
	disasm_context *disasm;
	reader         read_mem;
	writer         write_mem;
	find_chunk_end chunk_end;
	parsed_command last_cmd;
	debug_val      retval;
	uint32_t       bp_index;
	uint32_t       disp_index;
	uint32_t       branch_t;
	uint32_t       branch_f;
	void           *inst;
	uint32_t       address;
	uint32_t       after;
};

debug_root *find_root(void *cpu);
debug_root *find_m68k_root(m68k_context *context);
debug_root *find_z80_root(z80_context *context);
debug_root *find_upd_root(upd78k2_context *upd);
debug_root *find_sh2_root(sh2_context *sh2);
bp_def ** find_breakpoint(bp_def ** cur, uint32_t address, uint8_t type);
bp_def ** find_breakpoint_idx(bp_def ** cur, uint32_t index);
void add_display(disp_def ** head, uint32_t *index, char format_char, char * param);
void remove_display(disp_def ** head, uint32_t index);
void debugger(void * vcontext, uint32_t address);
z80_context * zdebugger(z80_context * context, uint16_t address);
void upd_debugger(upd78k2_context *upd);
void sh2_debugger(sh2_context *sh2);
void print_m68k_help();
void print_z80_help();

#endif //DEBUG_H_
