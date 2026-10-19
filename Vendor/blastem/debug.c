//avoid SDL_main macro grossness since it conflicts with uPD78K/II core
#define SDL_MAIN_HANDLED
#include "debug.h"
#include "genesis.h"
#include "68kinst.h"
#include "segacd.h"
#include "blastem.h"
#include "bindings.h"
#include "upd78k2_dis.h"
#include "sh2_decode.h"
#include <ctype.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <sys/select.h>
#endif
#include "render.h"
#include "util.h"
#include "terminal.h"
#include "z80inst.h"
#ifndef NO_Z80
#include "sms.h"
#include "coleco.h"
#endif

#ifdef NEW_CORE
#define Z80_OPTS opts
#else
#define Z80_OPTS options
#endif

static debug_func *funcs;
static uint32_t num_funcs, func_storage;

static debug_func* alloc_dfunc(void)
{
	if (num_funcs == func_storage) {
		func_storage = func_storage ? func_storage * 2 : 4;
		funcs = realloc(funcs, sizeof(debug_func) * func_storage);
	}
	return funcs + num_funcs++;
}

static debug_val new_native_func(debug_native_func impl, int max_args, int min_args)
{
	debug_func *f = alloc_dfunc();
	f->impl.native = impl;
	f->max_args = max_args;
	f->min_args = min_args;
	f->is_native = 1;
	return (debug_val) {
		.v = {
			.u32 = f - funcs
		},
		.type = DBG_VAL_FUNC
	};
}

static debug_val new_user_func(command_block *block, char **args, int num_args)
{
	debug_func *f = alloc_dfunc();
	f->impl.block = *block;
	f->arg_names = args;
	f->max_args = f->min_args = num_args;
	f->is_native = 0;
	return (debug_val) {
		.v = {
			.u32 = f - funcs
		},
		.type = DBG_VAL_FUNC
	};
}

debug_val user_var_get(debug_var *var)
{
	return var->val;
}

void user_var_set(debug_var *var, debug_val val)
{
	var->val = val;
}

static void new_user_variable(debug_root *root, const char *name, debug_val val)
{
	debug_var *var = calloc(1, sizeof(debug_var));
	var->get = user_var_get;
	var->set = user_var_set;
	var->val = val;
	root->variables = tern_insert_ptr(root->variables, name, var);
}

static void new_readonly_variable(debug_root *root, const char *name, debug_val val)
{
	debug_var *var = calloc(1, sizeof(debug_var));
	var->get = user_var_get;
	var->set = NULL;
	var->val = val;
	root->variables = tern_insert_ptr(root->variables, name, var);
}

static debug_array *arrays;
static uint32_t num_arrays, array_storage;
static debug_array *alloc_array(void)
{
	if (num_arrays == array_storage) {
		array_storage = array_storage ? array_storage * 2 : 4;
		arrays = realloc(arrays, sizeof(debug_array) * array_storage);
	}
	return arrays + num_arrays++;
}

static debug_val new_fixed_array(void *base, debug_array_get get, debug_array_set set, uint32_t size)
{
	debug_array *array = alloc_array();
	array->get = get;
	array->set = set;
	array->append = NULL;
	array->base = base;
	array->size = array->storage = size;
	debug_val ret;
	ret.type = DBG_VAL_ARRAY;
	ret.v.u32 = array - arrays;
	return ret;
}

static debug_val user_array_get(debug_array *array, uint32_t index)
{
	debug_val *data = array->base;
	return data[index];
}

static void user_array_set(debug_array *array, uint32_t index, debug_val value)
{
	debug_val *data = array->base;
	data[index] = value;
}

static void user_array_append(debug_array *array, debug_val value)
{
	if (array->size == array->storage) {
		array->storage *= 2;
		array->base = realloc(array->base, sizeof(debug_val) * array->storage);
	}
	debug_val *data = array->base;
	data[array->size++] = value;
}

static debug_val new_user_array(uint32_t size)
{
	debug_array *array = alloc_array();
	array->get = user_array_get;
	array->set = user_array_set;
	array->append = user_array_append;
	array->size = size;
	array->storage = size ? size : 4;
	array->base = calloc(array->storage, sizeof(debug_val));
	debug_val ret;
	ret.type = DBG_VAL_ARRAY;
	ret.v.u32 = array - arrays;
	return ret;
}

debug_array *get_array(debug_val val)
{
	if (val.type != DBG_VAL_ARRAY) {
		return NULL;
	}
	return arrays + val.v.u32;
}

static debug_string **debug_strings;
static uint32_t num_debug_strings;
static uint32_t debug_string_storage;
static debug_val new_debug_string(char *str)
{
	if (num_debug_strings == debug_string_storage) {
		debug_string_storage = debug_string_storage ? 2 * debug_string_storage : 4;
		debug_strings = realloc(debug_strings, debug_string_storage * sizeof(debug_string*));
	}
	debug_string *string = calloc(1, sizeof(debug_string));
	string->size = string->storage = strlen(str);
	string->buffer = calloc(1, string->size + 1);
	memcpy(string->buffer, str, string->size + 1);
	debug_strings[num_debug_strings] = string;
	return (debug_val){
		.type = DBG_VAL_STRING,
		.v = {
			.u32 = num_debug_strings++
		}
	};
}

static debug_string* get_string(debug_val val)
{
	if (val.type != DBG_VAL_STRING) {
		return NULL;
	}
	return debug_strings[val.v.u32];
}

static char* get_cstring(debug_val val)
{
	debug_string *str = get_string(val);
	if (!str) {
		return NULL;
	}
	return str->buffer;
}

static uint8_t debug_cast_int(debug_val val, uint32_t *out)
{
	if (val.type == DBG_VAL_U32) {
		*out = val.v.u32;
		return 1;
	}
	if (val.type == DBG_VAL_F32) {
		*out = val.v.f32;
		return 1;
	}
	return 0;
}

static uint8_t debug_cast_float(debug_val val, float *out)
{
	if (val.type == DBG_VAL_U32) {
		*out = val.v.u32;
		return 1;
	}
	if (val.type == DBG_VAL_F32) {
		*out = val.v.f32;
		return 1;
	}
	return 0;
}

static uint8_t debug_cast_bool(debug_val val)
{
	switch(val.type)
	{
	case DBG_VAL_U32: return val.v.u32 != 0;
	case DBG_VAL_F32: return val.v.f32 != 0.0f;
	case DBG_VAL_ARRAY: return get_array(val)->size != 0;
	default: return 1;
	}
}

static debug_val debug_int(uint32_t i)
{
	debug_val ret;
	ret.type = DBG_VAL_U32;
	ret.v.u32 = i;
	return ret;
}

static debug_val debug_float(float f)
{
	return (debug_val) {
		.type = DBG_VAL_F32,
		.v = {
			.f32 = f
		}
	};
}

static debug_val debug_sin(debug_val *args, int num_args)
{
	float f;
	if (!debug_cast_float(args[0], &f)) {
		return debug_float(0.0f);
	}
	return debug_float(sinf(f));
}

static debug_val debug_cos(debug_val *args, int num_args)
{
	float f;
	if (!debug_cast_float(args[0], &f)) {
		return debug_float(0.0f);
	}
	return debug_float(cosf(f));
}

static debug_val debug_tan(debug_val *args, int num_args)
{
	float f;
	if (!debug_cast_float(args[0], &f)) {
		return debug_float(0.0f);
	}
	return debug_float(tanf(f));
}

static debug_val debug_asin(debug_val *args, int num_args)
{
	float f;
	if (!debug_cast_float(args[0], &f)) {
		return debug_float(0.0f);
	}
	return debug_float(asinf(f));
}

static debug_val debug_acos(debug_val *args, int num_args)
{
	float f;
	if (!debug_cast_float(args[0], &f)) {
		return debug_float(0.0f);
	}
	return debug_float(acosf(f));
}

static debug_val debug_atan(debug_val *args, int num_args)
{
	float f;
	if (!debug_cast_float(args[0], &f)) {
		return debug_float(0.0f);
	}
	return debug_float(atanf(f));
}

static debug_val debug_atan2(debug_val *args, int num_args)
{
	float f, f2;
	if (!debug_cast_float(args[0], &f)) {
		return debug_float(0.0f);
	}
	if (!debug_cast_float(args[1], &f2)) {
		return debug_float(0.0f);
	}
	return debug_float(atan2f(f, f2));
}

static debug_val array_pop(debug_val *args, int num_args)
{
	debug_array *array = get_array(*args);
	if (!array) {
		return debug_int(0);
	}
	debug_val ret = array->get(array, array->size - 1);
	if (array->append) {
		array->size--;
	}
	return ret;
}

static debug_val debug_size(debug_val *args, int num_args)
{
	debug_array *array = get_array(*args);
	if (!array) {
		//TODO: string support
		return debug_int(0);
	}
	return debug_int(array->size);
}

static debug_root **roots;
static uint32_t num_roots, root_storage;

debug_root *find_root(void *cpu)
{
	for (uint32_t i = 0; i < num_roots; i++)
	{
		if (roots[i]->cpu_context == cpu) {
			return roots[i];
		}
	}
	if (num_roots == root_storage) {
		root_storage = root_storage ? root_storage * 2 : 5;
		roots = realloc(roots, root_storage * sizeof(debug_root*));
	}
	debug_root *root = calloc(1, sizeof(debug_root));
	roots[num_roots++] = root;
	root->cpu_context = cpu;
	new_readonly_variable(root, "sin", new_native_func(debug_sin, 1, 1));
	new_readonly_variable(root, "cos", new_native_func(debug_cos, 1, 1));
	new_readonly_variable(root, "tan", new_native_func(debug_tan, 1, 1));
	new_readonly_variable(root, "asin", new_native_func(debug_asin, 1, 1));
	new_readonly_variable(root, "acos", new_native_func(debug_acos, 1, 1));
	new_readonly_variable(root, "atan", new_native_func(debug_atan, 1, 1));
	new_readonly_variable(root, "atan2", new_native_func(debug_atan2, 2, 2));
	new_readonly_variable(root, "pop", new_native_func(array_pop, 1, 1));
	new_readonly_variable(root, "size", new_native_func(debug_size, 1, 1));
	return root;
}

bp_def ** find_breakpoint(bp_def ** cur, uint32_t address, uint8_t type)
{
	if (type == BP_TYPE_CPU_WATCH) {
		while (*cur) {
			if ((*cur)->type == type && address >= (*cur)->address && address < ((*cur)->address + (*cur)->mask)) {
				break;
			}
			cur = &((*cur)->next);
		}
	} else {
		while (*cur) {
			if ((*cur)->type == type && (*cur)->address == (((*cur)->mask) & address)) {
				break;
			}
			cur = &((*cur)->next);
		}
	}
	return cur;
}

bp_def ** find_breakpoint_idx(bp_def ** cur, uint32_t index)
{
	while (*cur) {
		if ((*cur)->index == index) {
			break;
		}
		cur = &((*cur)->next);
	}
	return cur;
}

static const char *token_type_names[] = {
	"TOKEN_NONE",
	"TOKEN_INT",
	"TOKEN_DECIMAL",
	"TOKEN_NAME",
	"TOKEN_ARRAY",
	"TOKEN_FUNCALL",
	"TOKEN_OPER",
	"TOKEN_SIZE",
	"TOKEN_LBRACKET",
	"TOKEN_RBRACKET",
	"TOKEN_LPAREN",
	"TOKEN_RPAREN",
	"TOKEN_STRING"
};

static char *parse_string_literal(char *start, char **end)
{
	uint32_t length = 0;
	uint8_t is_escape = 0;
	char *cur;
	for (cur = start; *cur && *cur != '"'; cur++)
	{
		if (is_escape) {
			switch (*cur)
			{
			case 't':
			case 'n':
			case 'r':
			case '\\':
				break;
			default:
				fprintf(stderr, "Unsupported escape character %c\n", *cur);
				return NULL;
			}
			is_escape = 0;
		} else if (*cur == '\\') {
			is_escape = 1;
			continue;
		}
		length++;
	}
	if (!*cur) {
		fprintf(stderr, "Unterminated string literal: %s\n", start);
		return NULL;
	}
	*end = cur + 1;
	char *ret = calloc(1, length + 1);
	char *dst = ret;
	is_escape = 0;
	for (cur = start; *cur != '"'; ++cur)
	{
		if (is_escape) {
			switch (*cur)
			{
			case 't':
				*(dst++) = '\t';
				break;
			case 'n':
				*(dst++) = '\n';
				break;
			case 'r':
				*(dst++) = '\r';
				break;
			case '\\':
				*(dst++) = '\\';
				break;
			}
			is_escape = 0;
		} else if (*cur == '\\') {
			is_escape = 1;
			continue;
		} else {
			*(dst++) = *cur;
		}
	}
	*dst = 0;
	return ret;
}

static token parse_token(char *start, char **end)
{
	while(*start && isblank(*start) && *start != '\n' && *start != '\r')
	{
		++start;
	}
	if (!*start || *start == '\n' || *start == '\r') {
		*end = start;
		return (token){
			.type = TOKEN_NONE
		};
	}
	if (*start == '$' || (*start == '0' && start[1] == 'x')) {
		return (token) {
			.type = TOKEN_INT,
			.v = {
				.num = strtol(start + (*start == '$' ? 1 : 2), end, 16)
			}
		};
	}
	if (*start == '"') {
		char *str = parse_string_literal(start + 1, end);
		if (!str) {
			*end = start;
			return (token){
				.type = TOKEN_NONE
			};
		}
		return (token){
			.type = TOKEN_STRING,
			.v = {
				.str = str
			}
		};
	}
	if (isdigit(*start)) {
		uint32_t ipart = strtol(start, end, 10);
		if (**end == '.') {
			start = *end + 1;
			uint32_t fpart = strtol(start, end, 10);
			float fval;
			if (fpart) {
				float divisor = powf(10.0f, *end - start);
				fval = ipart + fpart / divisor;
			} else {
				fval = ipart;
			}
			return (token) {
				.type = TOKEN_DECIMAL,
				.v = {
					.f = fval
				}
			};
		} else {
			return (token) {
				.type = TOKEN_INT,
				.v = {
					.num = ipart
				}
			};
		}
	}
	switch (*start)
	{
	case '+':
	case '-':
	case '*':
	case '/':
	case '&':
	case '|':
	case '^':
	case '~':
	case '=':
	case '!':
	case '>':
	case '<':
		if ((*start == '!' || *start == '>' || *start == '<') && start[1] == '=') {
			*end = start + 2;
			return (token) {
				.type = TOKEN_OPER,
				.v = {
					.op = {*start, start[1], 0}
				}
			};
		}
		*end = start + 1;
		return (token) {
			.type = TOKEN_OPER,
			.v = {
				.op = {*start, 0}
			}
		};
	case '.':
		*end = start + 2;
		return (token) {
			.type = TOKEN_SIZE,
			.v = {
				.op = {start[1], 0}
			}
		};
	case '[':
		*end = start + 1;
		return (token) {
			.type = TOKEN_LBRACKET
		};
	case ']':
		*end = start + 1;
		return (token) {
			.type = TOKEN_RBRACKET
		};
	case '(':
		*end = start + 1;
		return (token) {
			.type = TOKEN_LPAREN
		};
	case ')':
		*end = start + 1;
		return (token) {
			.type = TOKEN_RPAREN
		};
	}
	*end = start + 1;
	token_type type = TOKEN_NAME;
	while (**end && !isspace(**end))
	{
		uint8_t done = 0;
		switch (**end)
		{
		case '[':
			type = TOKEN_ARRAY;
			done = 1;
			break;
		case '(':
			type = TOKEN_FUNCALL;
		case '+':
		case '-':
		case '*':
		case '/':
		case '&':
		case '|':
		case '^':
		case '~':
		case '=':
		case '!':
		case '>':
		case '<':
		case '.':
		case ']':
		case ')':
			done = 1;
			break;
		}
		if (done) {
			break;
		}

		++*end;
	}
	char *name = malloc(*end - start + 1);
	memcpy(name, start, *end - start);
	name[*end-start] = 0;
	return (token) {
		.type = type,
		.v = {
			.str = name
		}
	};
}

static void free_expr(expr *e);
static void free_expr_int(expr *e)
{
	free_expr(e->left);
	if (e->type == EXPR_FUNCALL) {
		for (uint32_t i = 0; i < e->op.v.num; i++)
		{
			free_expr_int(e->right + i);
		}
		free(e->right);
	} else {
		free_expr(e->right);
	}
	if (e->op.type == TOKEN_NAME || e->op.type == TOKEN_ARRAY || e->op.type == TOKEN_STRING) {
		free(e->op.v.str);
	}
}

static void free_expr(expr *e)
{
	if (!e) {
		return;
	}
	free_expr_int(e);
	free(e);
}

static expr *parse_scalar_or_muldiv(char *start, char **end);
static expr *parse_expression(char *start, char **end);

static void handle_namespace(expr *e)
{
	if (e->op.type != TOKEN_NAME && e->op.type != TOKEN_ARRAY) {
		return;
	}
	char *start = e->op.v.str;
	char *orig_start = start;
	for (char *cur = start; *cur; ++cur)
	{
		if (*cur == ':') {
			char *ns = malloc(cur - start + 1);
			memcpy(ns, start, cur - start);
			ns[cur - start] = 0;
			expr *inner = calloc(1, sizeof(expr));
			inner->type = EXPR_SCALAR;
			inner->op.type = TOKEN_NAME;
			start = cur + 1;
			inner->op.v.str = start;
			e->left = inner;
			e->type = EXPR_NAMESPACE;
			e->op.v.str = ns;
			e = inner;
		}
	}
	if (start != orig_start) {
		//We've split the original string up into
		//a bunch of individually allocated fragments
		//this is just a little stup of the original
		e->op.v.str = strdup(e->op.v.str);
		free(orig_start);
	}
}

static expr *parse_scalar(char *start, char **end)
{
	char *after_first;
	token first = parse_token(start, &after_first);
	if (!first.type) {
		return NULL;
	}
	if (first.type == TOKEN_SIZE) {
		fprintf(stderr, "Unexpected TOKEN_SIZE '.%s'\n", first.v.op);
		return NULL;
	}
	if (first.type == TOKEN_OPER) {
		expr *target = parse_scalar(after_first, end);
		if (!target) {
			fprintf(stderr, "Unary expression %s needs value\n", first.v.op);
			return NULL;
		}
		expr *ret = calloc(1, sizeof(expr));
		ret->type = EXPR_UNARY;
		ret->op = first;
		ret->left = target;
		*end = after_first;
		return ret;
	}
	if (first.type == TOKEN_LBRACKET || first.type == TOKEN_ARRAY) {
		expr *ret = calloc(1, sizeof(expr));
		ret->type = EXPR_MEM;
		if (first.type == TOKEN_ARRAY) {
			//current token is the array name
			//consume the bracket token
			parse_token(after_first, &after_first);
			ret->right = calloc(1, sizeof(expr));
			ret->right->type = EXPR_SCALAR;
			ret->right->op = first;
			handle_namespace(ret->right);
		}

		ret->left = parse_expression(after_first, end);
		if (!ret->left) {
			fprintf(stderr, "Expression expected after `[`\n");
			free(ret);
			return NULL;
		}
		token rbrack = parse_token(*end, end);
		if (rbrack.type != TOKEN_RBRACKET) {
			fprintf(stderr, "Missing closing `]`");
			free_expr(ret);
			return NULL;
		}
		char *after_size;
		token size = parse_token(*end, &after_size);
		if (size.type == TOKEN_SIZE) {
			*end = after_size;
			ret->op = size;
		}
		return ret;
	}
	if (first.type == TOKEN_LPAREN) {
		expr *ret = parse_expression(after_first, end);
		if (!ret) {
			fprintf(stderr, "Expression expected after `(`\n");
			return NULL;
		}
		token rparen = parse_token(*end, end);
		if (rparen.type != TOKEN_RPAREN) {
			fprintf(stderr, "Missing closing `)`");
			free_expr(ret);
			return NULL;
		}
		return ret;
	}
	if (first.type == TOKEN_FUNCALL) {
		expr *ret = calloc(1, sizeof(expr));
		ret->left = calloc(1, sizeof(expr));
		ret->left->type = EXPR_SCALAR;
		ret->left->op = first;
		ret->left->op.type = TOKEN_NAME;
		uint32_t storage = 0;
		ret->op.v.num = 0;
		token next = parse_token(after_first, end);
		while (next.type != TOKEN_RPAREN && next.type != TOKEN_NONE)
		{
			expr *e = parse_expression(after_first, end);
			if (!e) {
				fprintf(stderr, "Expression expected after '('\n");
				free_expr(ret);
				return NULL;
			}
			if (storage == ret->op.v.num) {
				storage = storage ? storage * 2 : 1;
				ret->right = realloc(ret->right, storage * sizeof(expr));
			}
			ret->right[ret->op.v.num++] = *e;
			free(e);
			after_first = *end;
			next = parse_token(after_first, end);
		}
		if (next.type != TOKEN_RPAREN) {
			fprintf(stderr, "Missing ')' after '('\n");
			free_expr(ret);
			return NULL;
		}
		return ret;
	}
	if (first.type != TOKEN_INT && first.type != TOKEN_DECIMAL && first.type != TOKEN_NAME && first.type != TOKEN_STRING) {
		fprintf(stderr, "Unexpected token %s\n", token_type_names[first.type]);
		return NULL;
	}
	token second = parse_token(after_first, end);
	if (second.type != TOKEN_SIZE) {
		expr *ret = calloc(1, sizeof(expr));
		ret->type = EXPR_SCALAR;
		ret->op = first;
		handle_namespace(ret);
		*end = after_first;
		return ret;
	}
	expr *ret = calloc(1, sizeof(expr));
	ret->type = EXPR_SIZE;
	ret->left = calloc(1, sizeof(expr));
	ret->left->type = EXPR_SCALAR;
	ret->left->op = second;
	handle_namespace(ret->left);
	ret->op = first;
	return ret;
}

static expr *maybe_binary(expr *left, char *start, char **end)
{
	char *after_first;
	token first = parse_token(start, &after_first);
	if (first.type != TOKEN_OPER) {
		*end = start;
		return left;
	}
	expr *bin = calloc(1, sizeof(expr));
	bin->left = left;
	bin->op = first;
	bin->type = EXPR_BINARY;
	switch (first.v.op[0])
	{
	case '*':
	case '/':
	case '&':
	case '|':
	case '^':
		bin->right = parse_scalar(after_first, end);
		return maybe_binary(bin, *end, end);
	case '+':
	case '-':
		bin->right = parse_scalar_or_muldiv(after_first, end);
		return maybe_binary(bin, *end, end);
	case '=':
	case '!':
	case '>':
	case '<':
		bin->right = parse_expression(after_first, end);
		return bin;
	default:
		bin->left = NULL;
		free(bin);
		return left;
	}
}

static expr *maybe_muldiv(expr *left, char *start, char **end)
{
	char *after_first;
	token first = parse_token(start, &after_first);
	if (first.type != TOKEN_OPER) {
		*end = start;
		return left;
	}
	expr *bin = calloc(1, sizeof(expr));
	bin->left = left;
	bin->op = first;
	bin->type = EXPR_BINARY;
	switch (first.v.op[0])
	{
	case '*':
	case '/':
	case '&':
	case '|':
	case '^':
		bin->right = parse_scalar(after_first, end);
		return maybe_binary(bin, *end, end);
	default:
		bin->left = NULL;
		free(bin);
		return left;
	}
}

static expr *parse_scalar_or_muldiv(char *start, char **end)
{
	char *after_first;
	token first = parse_token(start, &after_first);
	if (!first.type) {
		return NULL;
	}
	if (first.type == TOKEN_SIZE) {
		fprintf(stderr, "Unexpected TOKEN_SIZE '.%s'\n", first.v.op);
		return NULL;
	}
	if (first.type == TOKEN_OPER) {
		expr *target = parse_scalar(after_first, end);
		if (!target) {
			fprintf(stderr, "Unary expression %s needs value\n", first.v.op);
			return NULL;
		}
		expr *ret = calloc(1, sizeof(expr));
		ret->type = EXPR_UNARY;
		ret->op = first;
		ret->left = target;
		return ret;
	}
	if (first.type == TOKEN_LBRACKET || first.type == TOKEN_ARRAY) {
		expr *ret = calloc(1, sizeof(expr));
		ret->type = EXPR_MEM;
		if (first.type == TOKEN_ARRAY) {
			//current token is the array name
			//consume the bracket token
			parse_token(after_first, &after_first);
			ret->right = calloc(1, sizeof(expr));
			ret->right->type = EXPR_SCALAR;
			ret->right->op = first;
			handle_namespace(ret->right);
		}

		ret->left = parse_expression(after_first, end);
		if (!ret->left) {
			fprintf(stderr, "Expression expected after `[`\n");
			free(ret);
			return NULL;
		}
		token rbrack = parse_token(*end, end);
		if (rbrack.type != TOKEN_RBRACKET) {
			fprintf(stderr, "Missing closing `]`");
			free_expr(ret);
			return NULL;
		}
		char *after_size;
		token size = parse_token(*end, &after_size);
		if (size.type == TOKEN_SIZE) {
			*end = after_size;
			ret->op = size;
		}
		return maybe_muldiv(ret, *end, end);
	}
	if (first.type == TOKEN_LPAREN) {
		expr *ret = parse_expression(after_first, end);
		if (!ret) {
			fprintf(stderr, "Expression expected after `(`\n");
			return NULL;
		}
		token rparen = parse_token(*end, end);
		if (rparen.type != TOKEN_RPAREN) {
			fprintf(stderr, "Missing closing `)`");
			free_expr(ret);
			return NULL;
		}
		return maybe_muldiv(ret, *end, end);
	}
	if (first.type == TOKEN_FUNCALL) {
		expr *ret = calloc(1, sizeof(expr));
		ret->left = calloc(1, sizeof(expr));
		ret->left->type = EXPR_SCALAR;
		ret->left->op = first;
		ret->left->op.type = TOKEN_NAME;
		uint32_t storage = 0;
		ret->op.v.num = 0;
		token next = parse_token(after_first, end);
		while (next.type != TOKEN_RPAREN && next.type != TOKEN_NONE)
		{
			expr *e = parse_expression(after_first, end);
			if (!e) {
				fprintf(stderr, "Expression expected after '('\n");
				free_expr(ret);
				return NULL;
			}
			if (storage == ret->op.v.num) {
				storage = storage ? storage * 2 : 1;
				ret->right = realloc(ret->right, storage * sizeof(expr));
			}
			ret->right[ret->op.v.num++] = *e;
			free(e);
			after_first = *end;
			next = parse_token(after_first, end);
		}
		if (next.type != TOKEN_RPAREN) {
			fprintf(stderr, "Missing ')' after '('\n");
			free_expr(ret);
			return NULL;
		}
		return maybe_muldiv(ret, *end, end);
	}
	if (first.type != TOKEN_INT && first.type != TOKEN_DECIMAL && first.type != TOKEN_NAME && first.type != TOKEN_STRING) {
		fprintf(stderr, "Unexpected token %s\n", token_type_names[first.type]);
		return NULL;
	}
	char *after_second;
	token second = parse_token(after_first, &after_second);
	if (second.type == TOKEN_OPER) {
		expr *ret;
		expr *bin = calloc(1, sizeof(expr));
		bin->type = EXPR_BINARY;
		bin->left = calloc(1, sizeof(expr));
		bin->left->type = EXPR_SCALAR;
		bin->left->op = first;
		handle_namespace(bin->left);
		bin->op = second;
		switch (second.v.op[0])
		{
		case '*':
		case '/':
		case '&':
		case '|':
		case '^':
			bin->right = parse_scalar(after_second, end);
			return maybe_muldiv(bin, *end, end);
		case '+':
		case '-':
		case '=':
		case '!':
		case '>':
		case '<':
			ret = bin->left;
			bin->left = NULL;
			free_expr(bin);
			return ret;
		default:
			fprintf(stderr, "%s is not a valid binary operator\n", second.v.op);
			free(bin->left);
			free(bin);
			return NULL;
		}
	} else if (second.type == TOKEN_SIZE) {
		expr *value = calloc(1, sizeof(expr));
		value->type = EXPR_SIZE;
		value->op = second;
		value->left = calloc(1, sizeof(expr));
		value->left->type = EXPR_SCALAR;
		value->left->op = first;
		handle_namespace(value->left);
		return maybe_muldiv(value, after_second, end);
	} else {
		expr *ret = calloc(1, sizeof(expr));
		ret->type = EXPR_SCALAR;
		ret->op = first;
		handle_namespace(ret);
		*end = after_first;
		return ret;
	}
}

static expr *parse_expression(char *start, char **end)
{
	char *after_first;
	token first = parse_token(start, &after_first);
	if (!first.type) {
		return NULL;
	}
	if (first.type == TOKEN_SIZE) {
		fprintf(stderr, "Unexpected TOKEN_SIZE '.%s'\n", first.v.op);
		return NULL;
	}
	if (first.type == TOKEN_OPER) {
		expr *target = parse_scalar(after_first, end);
		if (!target) {
			fprintf(stderr, "Unary expression %s needs value\n", first.v.op);
			return NULL;
		}
		expr *ret = calloc(1, sizeof(expr));
		ret->type = EXPR_UNARY;
		ret->op = first;
		ret->left = target;
		return ret;
	}
	if (first.type == TOKEN_LBRACKET || first.type == TOKEN_ARRAY) {
		expr *ret = calloc(1, sizeof(expr));
		ret->type = EXPR_MEM;
		if (first.type == TOKEN_ARRAY) {
			//current token is the array name
			//consume the bracket token
			parse_token(after_first, &after_first);
			ret->right = calloc(1, sizeof(expr));
			ret->right->type = EXPR_SCALAR;
			ret->right->op = first;
			handle_namespace(ret->right);
		}

		ret->left = parse_expression(after_first, end);
		if (!ret->left) {
			fprintf(stderr, "Expression expected after `[`\n");
			free(ret);
			return NULL;
		}
		token rbrack = parse_token(*end, end);
		if (rbrack.type != TOKEN_RBRACKET) {
			fprintf(stderr, "Missing closing `]`");
			free_expr(ret);
			return NULL;
		}
		char *after_size;
		token size = parse_token(*end, &after_size);
		if (size.type == TOKEN_SIZE) {
			*end = after_size;
			ret->op = size;
		}
		return maybe_binary(ret, *end, end);
	}
	if (first.type == TOKEN_LPAREN) {
		expr *ret = parse_expression(after_first, end);
		if (!ret) {
			fprintf(stderr, "Expression expected after `(`\n");
			return NULL;
		}
		token rparen = parse_token(*end, end);
		if (rparen.type != TOKEN_RPAREN) {
			fprintf(stderr, "Missing closing `)`");
			free_expr(ret);
			return NULL;
		}
		return maybe_binary(ret, *end, end);
	}
	if (first.type == TOKEN_FUNCALL) {
		expr *ret = calloc(1, sizeof(expr));
		ret->type = EXPR_FUNCALL;
		ret->left = calloc(1, sizeof(expr));
		ret->left->type = EXPR_SCALAR;
		ret->left->op = first;
		ret->left->op.type = TOKEN_NAME;
		uint32_t storage = 0;
		ret->op.v.num = 0;
		//consume LPAREN
		parse_token(after_first, end);
		after_first = *end;
		token next = parse_token(after_first, end);
		while (next.type != TOKEN_RPAREN && next.type != TOKEN_NONE)
		{
			expr *e = parse_expression(after_first, end);
			if (!e) {
				fprintf(stderr, "Expression expected after '('\n");
				free_expr(ret);
				return NULL;
			}
			if (storage == ret->op.v.num) {
				storage = storage ? storage * 2 : 1;
				ret->right = realloc(ret->right, storage * sizeof(expr));
			}
			ret->right[ret->op.v.num++] = *e;
			free(e);
			after_first = *end;
			next = parse_token(after_first, end);
		}
		if (next.type != TOKEN_RPAREN) {
			fprintf(stderr, "Missing ')' after '('\n");
			free_expr(ret);
			return NULL;
		}
		return maybe_binary(ret, *end, end);
	}
	if (first.type != TOKEN_INT && first.type != TOKEN_DECIMAL && first.type != TOKEN_NAME && first.type != TOKEN_STRING) {
		fprintf(stderr, "Unexpected token %s\n", token_type_names[first.type]);
		return NULL;
	}
	char *after_second;
	token second = parse_token(after_first, &after_second);
	if (second.type == TOKEN_OPER) {
		expr *bin = calloc(1, sizeof(expr));
		bin->type = EXPR_BINARY;
		bin->left = calloc(1, sizeof(expr));
		bin->left->type = EXPR_SCALAR;
		bin->left->op = first;
		handle_namespace(bin->left);
		bin->op = second;
		switch (second.v.op[0])
		{
		case '*':
		case '/':
		case '&':
		case '|':
		case '^':
			bin->right = parse_scalar(after_second, end);
			if (!bin->right) {
				fprintf(stderr, "Expected expression to the right of %s\n", second.v.op);
				free_expr(bin);
				return NULL;
			}
			return maybe_binary(bin, *end, end);
		case '+':
		case '-':
			bin->right = parse_scalar_or_muldiv(after_second, end);
			if (!bin->right) {
				fprintf(stderr, "Expected expression to the right of %s\n", second.v.op);
				free_expr(bin);
				return NULL;
			}
			return maybe_binary(bin, *end, end);
		case '=':
		case '!':
		case '>':
		case '<':
			bin->right = parse_expression(after_second, end);
			if (!bin->right) {
				fprintf(stderr, "Expected expression to the right of %s\n", second.v.op);
				free_expr(bin);
				return NULL;
			}
			return bin;
		default:
			fprintf(stderr, "%s is not a valid binary operator\n", second.v.op);
			free(bin->left);
			free(bin);
			return NULL;
		}
	} else if (second.type == TOKEN_SIZE) {
		expr *value = calloc(1, sizeof(expr));
		value->type = EXPR_SIZE;
		value->op = second;
		value->left = calloc(1, sizeof(expr));
		value->left->type = EXPR_SCALAR;
		value->left->op = first;
		handle_namespace(value->left);
		return maybe_binary(value, after_second, end);
	} else {
		if (second.type == TOKEN_NAME) {
			free(second.v.str);
		}
		expr *ret = calloc(1, sizeof(expr));
		ret->type = EXPR_SCALAR;
		ret->op = first;
		handle_namespace(ret);
		*end = after_first;
		return ret;
	}
}

static uint8_t execute_block(debug_root *root, command_block * block);
uint8_t eval_expr(debug_root *root, expr *e, debug_val *out)
{
	debug_val right;
	debug_val *args;
	debug_func *func;
	int num_args;
	switch(e->type)
	{
	case EXPR_SCALAR:
		if (e->op.type == TOKEN_NAME || e->op.type == TOKEN_ARRAY) {
			debug_var *var = tern_find_ptr(root->variables, e->op.v.str);
			if (!var) {
				return 0;
			}
			*out = var->get(var);
			return 1;
		} else if (e->op.type == TOKEN_INT) {
			*out = debug_int(e->op.v.num);
			return 1;
		} else if (e->op.type == TOKEN_DECIMAL){
			*out = debug_float(e->op.v.f);
			return 1;
		} else {
			*out = new_debug_string(e->op.v.str);
			return 1;
		}
	case EXPR_UNARY:
		if (!eval_expr(root, e->left, out)) {
			return 0;
		}
		switch (e->op.v.op[0])
		{
		case '!':
			if (out->type != DBG_VAL_U32) { fprintf(stderr, "operator ! is only defined for integers"); return 0; }
			out->v.u32 = !out->v.u32;
			break;
		case '~':
			if (out->type != DBG_VAL_U32) { fprintf(stderr, "operator ~ is only defined for integers"); return 0; }
			out->v.u32 = ~out->v.u32;
			break;
		case '-':
			if (out->type == DBG_VAL_U32) {
				out->v.u32 = -out->v.u32;
			} else if (out->type == DBG_VAL_F32) {
				out->v.f32 = -out->v.f32;
			} else {
				fprintf(stderr, "operator ~ is only defined for integers and floats");
				return 0;
			}
			break;
		default:
			return 0;
		}
		return 1;
	case EXPR_BINARY:
		if (!eval_expr(root, e->left, out) || !eval_expr(root, e->right, &right)) {
			return 0;
		}
		if (out->type != right.type) {
			if (out->type == DBG_VAL_F32) {
				if (right.type == DBG_VAL_U32) {
					right.type = DBG_VAL_F32;
					float v = right.v.u32;
					right.v.f32 = v;
				} else {
					fprintf(stderr, "Invalid type on right side of binary operator\n");
					return 0;
				}
			} else if (out->type == DBG_VAL_U32) {
				if (right.type == DBG_VAL_F32) {
					out->type = DBG_VAL_F32;
					float v = out->v.u32;
					out->v.f32 = v;
				} else {
					fprintf(stderr, "Invalid type on right side of binary operator\n");
					return 0;
				}
			}
		}
		if (out->type == DBG_VAL_U32) {
			switch (e->op.v.op[0])
			{
			case '+':
				out->v.u32 += right.v.u32;
				break;
			case '-':
				out->v.u32 -= right.v.u32;
				break;
			case '*':
				out->v.u32 *= right.v.u32;
				break;
			case '/':
				out->v.u32 /= right.v.u32;
				break;
			case '&':
				out->v.u32 &= right.v.u32;
				break;
			case '|':
				out->v.u32 |= right.v.u32;
				break;
			case '^':
				out->v.u32 ^= right.v.u32;
				break;
			case '=':
				out->v.u32 = out->v.u32 == right.v.u32;
				break;
			case '!':
				out->v.u32 = out->v.u32 != right.v.u32;
				break;
			case '>':
				out->v.u32 = e->op.v.op[1] ? out->v.u32 >= right.v.u32 : out->v.u32 > right.v.u32;
				break;
			case '<':
				out->v.u32 = e->op.v.op[1] ? out->v.u32 <= right.v.u32 : out->v.u32 < right.v.u32;
				break;
			default:
				return 0;
			}
		} else if (out->type == DBG_VAL_F32) {
			switch (e->op.v.op[0])
			{
			case '+':
				out->v.f32 += right.v.f32;
				break;
			case '-':
				out->v.f32 -= right.v.f32;
				break;
			case '*':
				out->v.f32 *= right.v.f32;
				break;
			case '/':
				out->v.f32 /= right.v.f32;
				break;
			case '=':
				out->v.u32 = out->v.f32 == right.v.f32;
				out->type = DBG_VAL_U32;
				break;
			case '!':
				out->v.u32 = out->v.f32 != right.v.f32;
				out->type = DBG_VAL_U32;
				break;
			case '>':
				out->v.u32 = e->op.v.op[1] ? out->v.f32 >= right.v.f32 : out->v.f32 > right.v.f32;
				out->type = DBG_VAL_U32;
				break;
			case '<':
				out->v.u32 = e->op.v.op[1] ? out->v.f32 <= right.v.f32 : out->v.f32 < right.v.f32;
				out->type = DBG_VAL_U32;
				break;
			default:
				return 0;
			}
		}
		return 1;
	case EXPR_SIZE:
		if (!eval_expr(root, e->left, out)) {
			return 0;
		}
		if (out->type != DBG_VAL_U32) { fprintf(stderr, "Size expressions are only defined for integers"); return 0; }
		switch (e->op.v.op[0])
		{
		case 'b':
			out->v.u32 &= 0xFF;
			break;
		case 'w':
			out->v.u32 &= 0xFFFF;
			break;
		}
		return 1;
	case EXPR_MEM:
		if (!eval_expr(root, e->left, out)) {
			return 0;
		}
		if (out->type != DBG_VAL_U32) { fprintf(stderr, "Array index must be integer"); return 0; }
		if (e->right) {
			if (!eval_expr(root, e->right, &right)) {
				return 0;
			}
			debug_array *array = get_array(right);
			if (!array) {
				fprintf(stderr, "Attempt to index into value that is not an array");
				return 0;
			}
			if (out->v.u32 >= array->size) {
				return 0;
			}
			*out = array->get(array, out->v.u32);
			return 1;
		}
		return root->read_mem(root, &out->v.u32, e->op.v.op[0]);
	case EXPR_NAMESPACE:
		root = tern_find_ptr(root->other_roots, e->op.v.str);
		if (!root) {
			fprintf(stderr, "%s is not a valid namespace\n", e->op.v.str);
			return 0;
		}
		return eval_expr(root, e->left, out);
	case EXPR_FUNCALL:
		if (!eval_expr(root, e->left, out)) {
			return 0;
		}
		if (out->type != DBG_VAL_FUNC) {
			fprintf(stderr, "Funcall expression requires function");
			return 0;
		}
		func = funcs + out->v.u32;
		num_args = e->op.v.num;
		if (func->min_args > 0 && num_args < func->min_args) {
			fprintf(stderr, "Function requires at least %d args, but %d given\n", func->min_args, num_args);
			return 0;
		}
		if (func->max_args >= 0 && num_args > func->max_args) {
			fprintf(stderr, "Function requires no more than %d args, but %d given\n", func->max_args, num_args);
			return 0;
		}
		args = calloc(num_args, sizeof(debug_val));
		for (int i = 0; i < num_args; i++)
		{
			if (!eval_expr(root, e->right + i, args + i)) {
				free(args);
				return 0;
			}
		}
		if (func->is_native) {
			*out = func->impl.native(args, num_args);
			free(args);
			return 1;
		} else {
			debug_root *func_root = calloc(1, sizeof(debug_root));
			for (int i = 0; i < num_args; i++)
			{
				new_user_variable(func_root, func->arg_names[i], args[i]);
			}
			free(args);
			func_root->other_roots = tern_insert_ptr(func_root->other_roots, "parent", root);
			execute_block(func_root, &func->impl.block);
			*out = func_root->retval;
			//FIXME: properly free root
			tern_free(func_root->variables);
			tern_free(func_root->other_roots);
			free(func_root);
			return 1;
		}
	default:
		return 0;
	}
}

char * find_param(char * buf)
{
	for (; *buf; buf++) {
		if (*buf == ' ') {
			if (*(buf+1)) {
				return buf+1;
			}
		}
	}
	return NULL;
}

void strip_nl(char * buf)
{
	for(; *buf; buf++) {
		if (*buf == '\n') {
			*buf = 0;
			return;
		}
	}
}

static uint8_t m68k_read_byte(uint32_t address, m68k_context *context)
{
	//TODO: share this implementation with GDB debugger
	return read_byte(address, (void **)context->mem_pointers, &context->opts->gen, context);
}

static uint16_t m68k_read_word(uint32_t address, m68k_context *context)
{
	return read_word(address, (void **)context->mem_pointers, &context->opts->gen, context);
}

static uint32_t m68k_read_long(uint32_t address, m68k_context *context)
{
	return m68k_read_word(address, context) << 16 | m68k_read_word(address + 2, context);
}

static uint8_t read_m68k(debug_root *root, uint32_t *out, char size)
{
	m68k_context *context = root->cpu_context;
	if (size == 'b') {
		*out = m68k_read_byte(*out, context);
	} else if (size == 'l') {
		if (*out & 1) {
			fprintf(stderr, "Longword access to odd addresses ($%X) is not allowed\n", *out);
			return 0;
		}
		*out = m68k_read_long(*out, context);
	} else {
		if (*out & 1) {
			fprintf(stderr, "Word access to odd addresses ($%X) is not allowed\n", *out);
			return 0;
		}
		*out = m68k_read_word(*out, context);
	}
	return 1;
}

static uint8_t write_m68k(debug_root *root, uint32_t address, uint32_t value, char size)
{
	m68k_context *context = root->cpu_context;
	if (size == 'b') {
		write_byte(address, value, (void **)context->mem_pointers, &context->opts->gen, context);
	} else if (size == 'l') {
		if (address & 1) {
			fprintf(stderr, "Longword access to odd addresses ($%X) is not allowed\n", address);
			return 0;
		}
		write_word(address, value >> 16, (void **)context->mem_pointers, &context->opts->gen, context);
		write_word(address + 2, value, (void **)context->mem_pointers, &context->opts->gen, context);
	} else {
		if (address & 1) {
			fprintf(stderr, "Wword access to odd addresses ($%X) is not allowed\n", address);
			return 0;
		}
		write_word(address, value, (void **)context->mem_pointers, &context->opts->gen, context);
	}
	return 1;
}

static debug_val m68k_dreg_get(debug_var *var)
{
	m68k_context *context = var->ptr;
	return debug_int(context->dregs[var->val.v.u32]);
}

static void m68k_dreg_set(debug_var *var, debug_val val)
{
	m68k_context *context = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "M68K register d%d can only be set to an integer\n", var->val.v.u32);
		return;
	}
	context->dregs[var->val.v.u32] = ival;
}

static debug_val m68k_areg_get(debug_var *var)
{
	m68k_context *context = var->ptr;
	return debug_int(context->aregs[var->val.v.u32]);
}

static void m68k_areg_set(debug_var *var, debug_val val)
{
	m68k_context *context = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "M68K register a%d can only be set to an integer\n", var->val.v.u32);
		return;
	}
	context->aregs[var->val.v.u32] = ival;
}

static debug_val m68k_sr_get(debug_var *var)
{
	m68k_context *context = var->ptr;
	debug_val ret;
	ret.v.u32 = context->status << 8;
#ifdef NEW_CORE
	//TODO: implement me
#else
	for (int flag = 0; flag < 5; flag++)
	{
		ret.v.u32 |= context->flags[flag] << (4-flag);
	}
#endif
	ret.type = DBG_VAL_U32;
	return ret;
}

static void m68k_sr_set(debug_var *var, debug_val val)
{
	m68k_context *context = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "M68K register sr can only be set to an integer\n");
		return;
	}
	context->status = ival >> 8;
#ifdef NEW_CORE
	//TODO: implement me
#else
	for (int flag = 0; flag < 5; flag++) {
		context->flags[flag] = (ival & (1 << (4 - flag))) != 0;
	}
#endif
}

static debug_val m68k_cycle_get(debug_var *var)
{
	m68k_context *context = var->ptr;
	return debug_int(context->cycles);
}

static debug_val m68k_usp_get(debug_var *var)
{
	m68k_context *context = var->ptr;
	return debug_int(context->status & 0x20 ? context->aregs[8] : context->aregs[7]);
}

static void m68k_usp_set(debug_var *var, debug_val val)
{
	m68k_context *context = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "M68K register usp can only be set to an integer\n");
		return;
	}
	context->aregs[context->status & 0x20 ? 8 : 7] = ival;
}

static debug_val m68k_ssp_get(debug_var *var)
{
	m68k_context *context = var->ptr;
	return debug_int(context->status & 0x20 ? context->aregs[7] : context->aregs[8]);
}

static void m68k_ssp_set(debug_var *var, debug_val val)
{
	m68k_context *context = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "M68K register ssp can only be set to an integer\n");
		return;
	}
	context->aregs[context->status & 0x20 ? 7 : 8] = ival;
}

static debug_val root_address_get(debug_var *var)
{
	debug_root *root = var->ptr;
	return debug_int(root->address);
}

static void m68k_names(debug_root *root)
{
	debug_var *var;
	for (char i = 0; i < 8; i++)
	{
		char rname[3] = {'d', '0' + i, 0};
		var = calloc(1, sizeof(debug_var));
		var->get = m68k_dreg_get;
		var->set = m68k_dreg_set;
		var->ptr = root->cpu_context;
		var->val.v.u32 = i;
		root->variables = tern_insert_ptr(root->variables, rname, var);
		rname[0] = 'D';
		root->variables = tern_insert_ptr(root->variables, rname, var);

		var = calloc(1, sizeof(debug_var));
		var->get = m68k_areg_get;
		var->set = m68k_areg_set;
		var->ptr = root->cpu_context;
		var->val.v.u32 = i;
		rname[0] = 'a';
		root->variables = tern_insert_ptr(root->variables, rname, var);
		rname[0] = 'A';
		root->variables = tern_insert_ptr(root->variables, rname, var);
		if (i == 7) {
			root->variables = tern_insert_ptr(root->variables, "sp", var);
			root->variables = tern_insert_ptr(root->variables, "SP", var);
		}
	}

	var = calloc(1, sizeof(debug_var));
	var->get = m68k_sr_get;
	var->set = m68k_sr_set;
	var->ptr = root->cpu_context;
	root->variables = tern_insert_ptr(root->variables, "sr", var);
	root->variables = tern_insert_ptr(root->variables, "SR", var);

	var = calloc(1, sizeof(debug_var));
	var->get = root_address_get;
	var->ptr = root;
	root->variables = tern_insert_ptr(root->variables, "pc", var);
	root->variables = tern_insert_ptr(root->variables, "PC", var);

	var = calloc(1, sizeof(debug_var));
	var->get = m68k_usp_get;
	var->set = m68k_usp_set;
	var->ptr = root->cpu_context;
	root->variables = tern_insert_ptr(root->variables, "usp", var);
	root->variables = tern_insert_ptr(root->variables, "USP", var);

	var = calloc(1, sizeof(debug_var));
	var->get = m68k_ssp_get;
	var->set = m68k_ssp_set;
	var->ptr = root->cpu_context;
	root->variables = tern_insert_ptr(root->variables, "ssp", var);
	root->variables = tern_insert_ptr(root->variables, "SSP", var);

	var = calloc(1, sizeof(debug_var));
	var->get = m68k_cycle_get;
	var->ptr = root->cpu_context;
	root->variables = tern_insert_ptr(root->variables, "cycle", var);
}

static debug_val vcounter_get(debug_var *var)
{
	vdp_context *vdp = var->ptr;
	return debug_int(vdp->vcounter);
}

static debug_val hcounter_get(debug_var *var)
{
	vdp_context *vdp = var->ptr;
	return debug_int(vdp->hslot);
}

static debug_val vdp_address_get(debug_var *var)
{
	vdp_context *vdp = var->ptr;
	return debug_int(vdp->address);
}

static void vdp_address_set(debug_var *var, debug_val val)
{
	vdp_context *vdp = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "vdp address can only be set to an integer\n");
		return;
	}
	vdp->address = ival & 0x1FFFF;
}

static debug_val vdp_cd_get(debug_var *var)
{
	vdp_context *vdp = var->ptr;
	return debug_int(vdp->cd);
}

static void vdp_cd_set(debug_var *var, debug_val val)
{
	vdp_context *vdp = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "vdp cd can only be set to an integer\n");
		return;
	}
	vdp->cd = ival & 0x3F;
}

static debug_val vdp_status_get(debug_var *var)
{
	vdp_context *vdp = var->ptr;
	return debug_int(vdp_status(vdp));
}

static debug_val debug_vram_get(debug_array *array, uint32_t index)
{
	vdp_context *vdp = array->base;
	if (!(vdp->regs[REG_MODE_2] & BIT_MODE_5)) {
		index = mode4_address_map[index & 0x3FFF] ^ 1;
	}
	return debug_int(vdp->vdpmem[index]);
}

static void debug_vram_set(debug_array *array, uint32_t index, debug_val val)
{
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "vram can only be set to integers\n");
		return;
	}
	vdp_context *vdp = array->base;
	if (!(vdp->regs[REG_MODE_2] & BIT_MODE_5)) {
		index = mode4_address_map[index & 0x3FFF] ^ 1;
	}
	vdp->vdpmem[index] = ival;
}

static debug_val debug_vsram_get(debug_array *array, uint32_t index)
{
	vdp_context *vdp = array->base;
	return debug_int(vdp->vsram[index] & VSRAM_BITS);
}

static void debug_vsram_set(debug_array *array, uint32_t index, debug_val val)
{
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "vsram can only be set to integers\n");
		return;
	}
	vdp_context *vdp = array->base;
	vdp->vsram[index] = ival;
}

static debug_val debug_cram_get(debug_array *array, uint32_t index)
{
	vdp_context *vdp = array->base;
	return debug_int(vdp->cram[index] & CRAM_BITS);
}

static void debug_cram_set(debug_array *array, uint32_t index, debug_val val)
{
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "cram can only be set to integers\n");
		return;
	}
	vdp_context *vdp = array->base;
	vdp->cram[index] = ival;
}

static debug_val debug_vreg_get(debug_array *array, uint32_t index)
{
	vdp_context *vdp = array->base;
	return debug_int(vdp->regs[index]);
}

static void debug_vreg_set(debug_array *array, uint32_t index, debug_val val)
{
	vdp_context *vdp = array->base;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "vdp registers can only be set to integers\n");
		return;
	}
	vdp_reg_write(vdp, index, ival);
}

static debug_root* find_vdp_root(vdp_context *context)
{
	debug_root *root = find_root(context);
	debug_var *var = calloc(1, sizeof(debug_var));
	var->get = vcounter_get;
	var->ptr = context;
	root->variables = tern_insert_ptr(root->variables, "vcounter", var);

	var = calloc(1, sizeof(debug_var));
	var->get = hcounter_get;
	var->ptr = context;
	root->variables = tern_insert_ptr(root->variables, "hcounter", var);

	var = calloc(1, sizeof(debug_var));
	var->get = vdp_address_get;
	var->set = vdp_address_set;
	var->ptr = context;
	root->variables = tern_insert_ptr(root->variables, "address", var);

	var = calloc(1, sizeof(debug_var));
	var->get = vdp_cd_get;
	var->set = vdp_cd_set;
	var->ptr = context;
	root->variables = tern_insert_ptr(root->variables, "cd", var);

	new_readonly_variable(root, "vram", new_fixed_array(context, debug_vram_get, debug_vram_set, VRAM_SIZE));
	new_readonly_variable(root, "vsram", new_fixed_array(context, debug_vsram_get, debug_vsram_set, context->vsram_size));
	new_readonly_variable(root, "cram", new_fixed_array(context, debug_cram_get, debug_cram_set, CRAM_SIZE));
	new_readonly_variable(root, "reg", new_fixed_array(context, debug_vreg_get, debug_vreg_set, VDP_REGS));

	return root;
}

static debug_val debug_part1_get(debug_array *array, uint32_t index)
{
	ym2612_context *ym = array->base;
	return debug_int(ym->part1_regs[index]);
}

static void debug_part1_set(debug_array *array, uint32_t index, debug_val val)
{
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "ym2612 registers can only be set to integers\n");
		return;
	}
	ym2612_context *ym = array->base;
	uint8_t old_part = ym->selected_part;
	uint8_t old_reg = ym->selected_reg;
	ym->selected_part = 0;
	ym->selected_reg = index;
	ym_data_write(ym, ival);
	ym->selected_part = old_part;
	ym->selected_reg = old_reg;
}

static debug_val debug_part2_get(debug_array *array, uint32_t index)
{
	ym2612_context *ym = array->base;
	return debug_int(ym->part2_regs[index]);
}

static void debug_part2_set(debug_array *array, uint32_t index, debug_val val)
{
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "ym2612 registers can only be set to integers\n");
		return;
	}
	ym2612_context *ym = array->base;
	uint8_t old_part = ym->selected_part;
	uint8_t old_reg = ym->selected_reg;
	ym->selected_part = 1;
	ym->selected_reg = index;
	ym_data_write(ym, ival);
	ym->selected_part = old_part;
	ym->selected_reg = old_reg;
}

static debug_root* find_ym2612_root(ym2612_context *context)
{
	debug_root *root = find_root(context);

	new_readonly_variable(root, "part1", new_fixed_array(context, debug_part1_get, debug_part1_set, YM_REG_END));
	new_readonly_variable(root, "part2", new_fixed_array(context, debug_part2_get, debug_part2_set, YM_REG_END));

	return root;
}


static debug_val debug_psgfreq_get(debug_array *array, uint32_t index)
{
	psg_context *psg = array->base;
	return debug_int(psg->counter_load[index]);
}

static void debug_psgfreq_set(debug_array *array, uint32_t index, debug_val val)
{
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "psg registers can only be set to integers\n");
		return;
	}
	psg_context *psg = array->base;
	psg->counter_load[index] = ival;
}

static debug_val debug_psgcount_get(debug_array *array, uint32_t index)
{
	psg_context *psg = array->base;
	return debug_int(psg->counters[index]);
}

static void debug_psgcount_set(debug_array *array, uint32_t index, debug_val val)
{
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "psg registers can only be set to integers\n");
		return;
	}
	psg_context *psg = array->base;
	psg->counters[index] = ival;
}

static debug_val debug_psgvol_get(debug_array *array, uint32_t index)
{
	psg_context *psg = array->base;
	return debug_int(psg->volume[index]);
}

static void debug_psgvol_set(debug_array *array, uint32_t index, debug_val val)
{
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "psg registers can only be set to integers\n");
		return;
	}
	psg_context *psg = array->base;
	psg->volume[index] = ival;
}

debug_root *find_psg_root(psg_context *psg)
{
	debug_root *root = find_root(psg);

	new_readonly_variable(root, "frequency", new_fixed_array(psg, debug_psgfreq_get, debug_psgfreq_set, 4));
	new_readonly_variable(root, "counter", new_fixed_array(psg, debug_psgcount_get, debug_psgcount_set, 4));
	new_readonly_variable(root, "volume", new_fixed_array(psg, debug_psgvol_get, debug_psgvol_set, 4));

	return root;
}

static debug_val debug_iopad_get(debug_array *array, uint32_t index)
{
	io_port *port = find_gamepad(array->base, index + 1);
	uint32_t ret = 0;
	if (port) {
		ret |= port->input[1];
		ret |= port->input[0] << 2 & 0xC0;
		ret |= port->input[2] << 8 & 0xF00;
	}
	return debug_int(ret);
}

static void debug_iopad_set(debug_array *array, uint32_t index, debug_val val)
{
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "pad state can only be set to integers\n");
		return;
	}
	io_port *port = find_gamepad(array->base, index + 1);
	if (port) {
		port->input[1] &= ~0x3F;
		port->input[1] |= ival & 0x3F;
		port->input[0] &= ~0x33;
		port->input[0] |= ival & 0x3;
		port->input[0] |= ival >> 2 & 0x30;
		port->input[2] &= ~0xF;
		port->input[2] |= ival >> 8 & 0xF;
	}
}

static debug_val debug_version_get(debug_var *var)
{
	genesis_context *gen = var->ptr;
	return debug_int(gen->version_reg);
}

static void debug_version_set(debug_var *var, debug_val val)
{
	genesis_context *gen = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "version register can only be set to integers\n");
		return;
	}
	gen->version_reg = ival;
}

debug_root *find_io_root(sega_io *io, genesis_context *gen)
{
	debug_root *root = find_root(io);
	
	new_readonly_variable(root, "pads", new_fixed_array(io, debug_iopad_get, debug_iopad_set, MAX_JOYSTICKS));
	if (gen) {
		debug_var *var = calloc(1, sizeof(debug_var));
		var->get = debug_version_get;
		var->set = debug_version_set;
		var->ptr = gen;
		root->variables = tern_insert_ptr(root->variables, "version", var);
	}
	
	return root;
}

void ambiguous_iter(char *key, tern_val val, uint8_t valtype, void *data)
{
	char *prefix = data;
	char * full = alloc_concat(prefix, key);
	fprintf(stderr, "\t%s\n", full);
	free(full);
}

uint8_t parse_command(debug_root *root, char *text, parsed_command *out)
{
	char *cur = text;
	uint8_t is_func = 0;
	while (*cur && *cur != '/' && !isspace(*cur))
	{
		if (*cur == '(') {
			is_func = 1;
			break;
		}
		++cur;
	}
	char *name = malloc(cur - text + 1);
	memcpy(name, text, cur - text);
	name[cur-text] = 0;
	uint8_t ret = 0;
	char *format = NULL;
	debug_func *func = NULL;
	command_def *def = NULL;
	if (is_func) {
		char *start = name;
		for (char *ncur = name; *ncur; ncur++)
		{
			if (*ncur == ':') {
				char *nspace = malloc(ncur - start + 1);
				memcpy(nspace, start, ncur - start);
				nspace[ncur - start] = 0;
				root = tern_find_ptr(root->other_roots, nspace);
				if (!root) {
					fprintf(stderr, "%s is not a valid namespace\n", nspace);
					free(nspace);
					goto cleanup_name;
				}
				start = ncur + 1;
			}
		}
		debug_var *var = tern_find_ptr(root->variables, start);
		if (!var) {
			fprintf(stderr, "%s is not defined\n", name);
			goto cleanup_name;
		}
		debug_val val = var->get(var);
		if (val.type != DBG_VAL_FUNC) {
			fprintf(stderr, "%s is not a function\n", name);
			goto cleanup_name;
		}
		func = funcs + val.v.u32;
	} else {
		tern_node *prefix_res = tern_find_prefix(root->commands, name);
		def = tern_find_ptr(prefix_res, "");
		if (!def) {
			tern_node *node = prefix_res;
			while (node)
			{
				if (node->left || node->right) {
					break;
				}
				if (node->el) {
					node = node->straight.next;
				} else {
					def = node->straight.value.ptrval;
					break;
				}
			}
			if (!def && prefix_res) {
				fprintf(stderr, "%s is ambiguous. Matching commands:\n", name);
				tern_foreach(prefix_res, ambiguous_iter, name);
				goto cleanup_name;
			}
		}
		if (!def) {
			fprintf(stderr, "%s is not a recognized command\n", name);
			goto cleanup_name;
		}
		if (*cur == '/') {
			++cur;
			text = cur;
			while (*cur && !isspace(*cur))
			{
				++cur;
			}
			format = malloc(cur - text + 1);
			memcpy(format, text, cur - text);
			format[cur - text] = 0;
		}
	}
	
	int num_args = 0;
	command_arg *args = NULL;
	if (*cur && *cur != '\n') {
		++cur;
	}
	text = cur;
	if (def && def->raw_args) {
		while (*cur && *cur != '\n')
		{
			++cur;
		}
		char *raw_param = NULL;
		if (cur != text) {
			raw_param = malloc(cur - text + 1);
			memcpy(raw_param, text, cur - text);
			raw_param[cur - text] = 0;
		}
		out->raw = raw_param;
		out->args = NULL;
		out->num_args = 0;
	} else {
		int arg_storage = 0;
		int32_t max_args = def ? def->max_args : func->max_args;
		int32_t min_args = def ? def->min_args : func->min_args;
		if (max_args > 0) {
			arg_storage = max_args;
		} else if (max_args) {
			arg_storage = min_args > 0 ? 2 * min_args : 2;
		}
		if (arg_storage) {
			args = calloc(arg_storage, sizeof(command_arg));
		}
		while (*text && *text != '\n' && (!is_func || *text != ')'))
		{
			char *after;
			expr *e = parse_expression(text, &after);
			if (e) {
				if (num_args == arg_storage) {
					if (max_args >= 0) {
						free_expr(e);
						fprintf(stderr, "Command %s takes a max of %d arguments, but at least %d provided\n", name, max_args, max_args+1);
						goto cleanup_args;
					} else {
						arg_storage *= 2;
						args = realloc(args, arg_storage * sizeof(command_arg));
					}
				}
				args[num_args].parsed = e;
				args[num_args].raw = malloc(after - text + 1);
				memcpy(args[num_args].raw, text, after - text);
				args[num_args++].raw[after - text] = 0;
				text = after;
			} else {
				goto cleanup_args;
			}
		}
		if (num_args < min_args) {
			fprintf(stderr, "Command %s requires at least %d arguments, but only %d provided\n", name, min_args, num_args);
			goto cleanup_args;
		}
		out->raw = NULL;
		out->args = args;
		out->num_args = num_args;
	}
	out->def = def;
	out->func = func ? func - funcs : 0;
	out->format = format;

	ret = 1;
cleanup_args:
	if (!ret) {
		for (int i = 0; i < num_args; i++)
		{
			free_expr(args[i].parsed);
			free(args[i].raw);
		}
		free(args);
	}
cleanup_name:
	free(name);
	return ret;
}

static void free_parsed_command(parsed_command *cmd);
static void free_command_block(command_block *block)
{
	for (int i = 0; i < block->num_commands; i++)
	{
		free_parsed_command(block->commands + i);
	}
	free(block->commands);
}

static void free_parsed_command(parsed_command *cmd)
{
	free(cmd->format);
	free(cmd->raw);
	for (int i = 0; i < cmd->num_args; i++)
	{
		free(cmd->args[i].raw);
		free_expr(cmd->args[i].parsed);
	}
	free_command_block(&cmd->block);
	free_command_block(&cmd->else_block);
	free(cmd->args);
}

enum {
	READ_FAILED = 0,
	NORMAL,
	EMPTY,
	ELSE,
	END
};

static void read_wait_progress(void)
{
	process_events();
#ifndef IS_LIB
	render_update_display();
	if (current_system->get_vdp) {
		vdp_context *vdp = current_system->get_vdp(current_system);
		if (vdp) {
			vdp_update_per_frame_debug(vdp);
		}
	}
#endif
}

static uint8_t read_parse_command(debug_root *root, parsed_command *out, int indent_level)
{
	++indent_level;
	for (int i = 0; i < indent_level; i++)
	{
		putchar('>');
	}
	putchar(' ');
	fflush(stdout);
	read_wait_progress();
	char input_buf[1024];
	if (!fgets_timeout(input_buf, sizeof(input_buf), stdin, 16667, read_wait_progress)) {
		fputs("fgets failed", stderr);
		return READ_FAILED;
	}
	char *stripped = strip_ws(input_buf);
	if (!stripped[0]) {
		return EMPTY;
	}
	if (indent_level > 1) {
		if (!strcmp(stripped, "else")) {
			return ELSE;
		}
		if (!strcmp(stripped, "end")) {
			return END;
		}
	}
	if (parse_command(root, input_buf, out)) {
		if (!out->def || !out->def->has_block) {
			return NORMAL;
		}
		int command_storage = 4;
		command_block *block = &out->block;
		block->commands = calloc(command_storage, sizeof(parsed_command));
		block->num_commands = 0;
		for (;;)
		{
			if (block->num_commands == command_storage) {
				command_storage *= 2;
				block->commands = realloc(block->commands, command_storage * sizeof(parsed_command));
			}
			switch (read_parse_command(root, block->commands + block->num_commands, indent_level))
			{
			case READ_FAILED:
				return READ_FAILED;
			case NORMAL:
				block->num_commands++;
				break;
			case END:
				return NORMAL;
			case ELSE:
				if (block == &out->else_block) {
					fprintf(stderr, "Too many else blocks for command %s\n", out->def->names[0]);
					return READ_FAILED;
				}
				if (!out->def->accepts_else) {
					fprintf(stderr, "Command %s does not take an else block\n", out->def->names[0]);
					return READ_FAILED;
				}
				block = &out->else_block;
				block->commands = calloc(command_storage, sizeof(parsed_command));
				block->num_commands = 0;
				break;
			}
		}
	}
	return READ_FAILED;
}

static uint8_t run_command(debug_root *root, parsed_command *cmd)
{
	if (!cmd->def || (!cmd->def->raw_args && !cmd->def->skip_eval)) {
		for (int i = 0; i < cmd->num_args; i++)
		{
			if (!eval_expr(root, cmd->args[i].parsed, &cmd->args[i].value)) {
				fprintf(stderr, "Failed to eval %s\n", cmd->args[i].raw);
				return 1;
			}
		}
	}
	if (cmd->def) {
		return cmd->def->impl(root, cmd);
	} else {
		debug_func *func = funcs + cmd->func;
		if (func->is_native) {
			debug_val *args = calloc(cmd->num_args, sizeof(debug_val));
			for (int i = 0; i < cmd->num_args; i++)
			{
				args[i] = cmd->args[i].value;
			}
			func->impl.native(args, cmd->num_args);
			free(args);
		} else {
			debug_root *func_root = calloc(1, sizeof(debug_root));
			for (int i = 0; i < cmd->num_args; i++)
			{
				new_user_variable(func_root, func->arg_names[i], cmd->args[i].value);
			}
			func_root->other_roots = tern_insert_ptr(func_root->other_roots, "parent", root);
			execute_block(func_root, &func->impl.block);
			//FIXME: properly free root
			tern_free(func_root->variables);
			tern_free(func_root->other_roots);
			free(func_root);
		}
		return 1;
	}
}

static void debugger_repl(debug_root *root)
{

	int debugging = 1;
	parsed_command cmds[2] = {0};
	int cur = 0;
	uint8_t has_last = 0;
	if (root->last_cmd.def) {
		memcpy(cmds + 1, &root->last_cmd, sizeof(root->last_cmd));
		has_last = 1;
	}
	while(debugging) {
		switch (read_parse_command(root, cmds + cur, 0))
		{
		case NORMAL:
			debugging = run_command(root, cmds + cur);
			cur = !cur;
			if (debugging && has_last) {
				free_parsed_command(cmds + cur);
				memset(cmds + cur, 0, sizeof(cmds[cur]));
			}
			has_last = 1;
			break;
		case EMPTY:
			if (has_last) {
				debugging = run_command(root, cmds + !cur);
			}
			break;
		}
	}
	if (has_last) {
		memcpy(&root->last_cmd, cmds + !cur, sizeof(root->last_cmd));
	} else {
		free_parsed_command(cmds + !cur);
	}
	free_parsed_command(cmds + cur);
}

static uint8_t cmd_quit(debug_root *root, parsed_command *cmd)
{
	exit(0);
}

typedef struct {
	size_t num_commands;
	size_t longest_command;
} help_state;

static void help_first_pass(char *key, tern_val val, uint8_t valtype, void *data)
{
	command_def *def = val.ptrval;
	if (def->visited) {
		return;
	}
	def->visited = 1;
	help_state *state = data;
	state->num_commands++;
	size_t len = strlen(def->usage);
	if (len > state->longest_command) {
		state->longest_command = len;
	}
}

static void help_reset_visited(char *key, tern_val val, uint8_t valtype, void *data)
{
	command_def *def = val.ptrval;
	def->visited = 0;
}

static void help_second_pass(char *key, tern_val val, uint8_t valtype, void *data)
{
	command_def *def = val.ptrval;
	if (def->visited) {
		return;
	}
	def->visited = 1;
	help_state *state = data;
	size_t len = strlen(def->usage);
	printf("  %s", def->usage);
	while (len < state->longest_command) {
		putchar(' ');
		len++;
	}
	int remaining = 80 - state->longest_command - 5;
	const char *extra_desc = NULL;
	if (strlen(def->desc) <= remaining) {
		printf(" - %s\n", def->desc);
	} else {
		char split[76];
		int split_point = remaining;
		while (split_point > 0 && !isspace(def->desc[split_point]))
		{
			--split_point;
		}
		if (!split_point) {
			split_point = remaining;
		}
		memcpy(split, def->desc, split_point);
		extra_desc = def->desc + split_point + 1;
		split[split_point] = 0;
		printf(" - %s\n", split);
	}
	if (def->names[1]) {
		fputs("    Aliases: ", stdout);
		len = strlen("    Aliases: ");
		const char **name = def->names + 1;
		uint8_t first = 1;
		while (*name)
		{
			if (first) {
				first = 0;
			} else {
				putchar(',');
				putchar(' ');
				len += 2;
			}
			fputs(*name, stdout);
			len += strlen(*name);
			++name;
		}
	} else {
		len = 0;
	}
	if (extra_desc) {
		while (len < state->longest_command + 5) {
			putchar(' ');
			len++;
		}
		fputs(extra_desc, stdout);
	}
	putchar('\n');
}

static uint8_t cmd_help(debug_root *root, parsed_command *cmd)
{
	help_state state = {0,0};
	tern_foreach(root->commands, help_first_pass, &state);
	tern_foreach(root->commands, help_reset_visited, &state);
	tern_foreach(root->commands, help_second_pass, &state);
	tern_foreach(root->commands, help_reset_visited, &state);
	return 1;
}

static uint8_t cmd_continue(debug_root *root, parsed_command *cmd)
{
	return 0;
}

static void make_format_str(char *format_str, char *format)
{
	strcpy(format_str, "%s: %d\n");
	if (format) {
		switch (format[0])
		{
		case 'x':
		case 'X':
		case 'd':
		case 'c':
		case 's':
			format_str[5] = format[0];
			break;
		default:
			fprintf(stderr, "Unrecognized format character: %c\n", format[0]);
		}
	}
}

static void do_print(debug_root *root, char *format_str, char *raw, debug_val value)
{
	switch(value.type)
	{
	case DBG_VAL_U32:
		if (format_str[5] == 's') {
			char tmp[128];
			int j;
			uint32_t addr = value.v.u32;
			for (j = 0; j < sizeof(tmp)-1; j++, addr++)
			{
				uint32_t tmp_addr = addr;
				root->read_mem(root, &tmp_addr, 'b');
				char c = tmp_addr;
				if (c < 0x20 || c > 0x7F) {
					break;
				}
				tmp[j] = c;
			}
			tmp[j] = 0;
			printf(format_str, raw, tmp);
		} else {
			printf(format_str, raw, value.v.u32);
		}
		break;
	case DBG_VAL_F32: {
		char tmp = format_str[5];
		format_str[5] = 'f';
		printf(format_str, raw, value.v.f32);
		format_str[5] = tmp;
		break;
	}
	}
}

static uint8_t cmd_print(debug_root *root, parsed_command *cmd)
{
	char format_str[8];
	make_format_str(format_str, cmd->format);
	for (int i = 0; i < cmd->num_args; i++)
	{
		do_print(root, format_str, cmd->args[i].raw, cmd->args[i].value);
	}
	return 1;
}

static uint8_t cmd_printf(debug_root *root, parsed_command *cmd)
{
	char *fmt = get_cstring(cmd->args[0].value);
	if (!fmt) {
		fprintf(stderr, "First parameter to printf must be a string\n");
		return 1;
	}
	char *cur = fmt;
	char format_str[3] = {'%', 'd', 0};
	uint32_t cur_param = 1;
	while (*cur)
	{
		if (*cur == '%') {
			switch(cur[1])
			{
			case 'x':
			case 'X':
			case 'c':
			case 'd':
			case 's':
			case 'f':
				break;
			default:
				fprintf(stderr, "Unsupported format character %c\n", cur[1]);
				return 1;
			}
			format_str[1] = cur[1];
			if (cur_param == cmd->num_args) {
				fprintf(stderr, "Not enough arguments for format char %c\n", *cur);
				return 1;
			}
			debug_val val = cmd->args[cur_param++].value;
			if (cur[1] == 's') {
				if (val.type == DBG_VAL_STRING) {
					printf(format_str, get_cstring(val));
				} else {
					char tmp[128];
					uint32_t address;
					if (!debug_cast_int(val, &address)) {
						fprintf(stderr, "Format char 's' accepts only integers and strings\n");
						return 1;
					}
					int j;
					for (j = 0; j < sizeof(tmp)-1; j++, address++)
					{
						uint32_t addr = address;
						root->read_mem(root, &addr, 'b');
						char c = addr;
						if (c < 0x20 || c > 0x7F) {
							break;
						}
						tmp[j] = c;
					}
					tmp[j] = 0;
					printf(format_str, tmp);
				}
			} else if (cur[1] == 'f') {
				float fval;
				if (!debug_cast_float(val, &fval)) {
					fprintf(stderr, "Format char '%c' only accepts floats\n", cur[1]);
					return 1;
				}
				printf(format_str, fval);
			} else {
				uint32_t ival;
				if (!debug_cast_int(val, &ival)) {
					fprintf(stderr, "Format char '%c' only accepts integers\n", cur[1]);
					return 1;
				}
				printf(format_str, ival);
			}
			cur += 2;
		} else {
			putchar(*cur);
			++cur;
		}
	}
	return 1;
}

static uint8_t cmd_display(debug_root *root, parsed_command *cmd)
{
	cmd_print(root, cmd);
	disp_def *ndisp = calloc(1, sizeof(*ndisp));
	ndisp->next = root->displays;
	ndisp->index = root->disp_index++;
	ndisp->format = cmd->format ? strdup(cmd->format) : NULL;
	ndisp->num_args = cmd->num_args;
	ndisp->args = cmd->args;
	cmd->args = NULL;
	cmd->num_args = 0;
	root->displays = ndisp;
	printf("Added display %d\n", ndisp->index);
	return 1;
}

static uint8_t cmd_delete_display(debug_root *root, parsed_command *cmd)
{
	disp_def **cur = &root->displays;
	uint32_t index;
	if (!debug_cast_int(cmd->args[0].value, &index)) {
		fprintf(stderr, "Argument to deletedisplay must be an integer\n");
		return 1;
	}
	while (*cur)
	{
		if ((*cur)->index == index) {
			disp_def *del_disp = *cur;
			*cur = del_disp->next;
			free(del_disp->format);
			for (int i = 0; i < del_disp->num_args; i++)
			{
				free(del_disp->args[i].raw);
				free_expr(del_disp->args[i].parsed);
			}
			free(del_disp->args);
			free(del_disp);
			break;
		} else {
			cur = &(*cur)->next;
		}
	}
	return 1;
}

static uint8_t cmd_softreset(debug_root *root, parsed_command *cmd)
{
	if (current_system->soft_reset) {
		current_system->soft_reset(current_system);
		return 0;
	} else {
		fputs("Current system does not support soft reset", stderr);
		return 1;
	}
}

static uint8_t cmd_command(debug_root *root, parsed_command *cmd)
{
	uint32_t index;
	if (!debug_cast_int(cmd->args[0].value, &index)) {
		fprintf(stderr, "Argument to commands must be an integer\n");
		return 1;
	}
	bp_def **target = find_breakpoint_idx(&root->breakpoints, index);
	if (!target) {
		fprintf(stderr, "Breakpoint %d does not exist!\n", index);
		return 1;
	}
	for (uint32_t i = 0; i < (*target)->num_commands; i++)
	{
		free_parsed_command((*target)->commands + i);
	}
	free((*target)->commands);
	(*target)->commands = cmd->block.commands;
	(*target)->num_commands = cmd->block.num_commands;
	cmd->block.commands = NULL;
	cmd->block.num_commands = 0;
	return 1;
}

static uint8_t execute_block(debug_root *root, command_block * block)
{
	uint8_t debugging = 1;
	for (int i = 0; i < block->num_commands && debugging; i++)
	{
		debugging = run_command(root, block->commands + i);
	}
	return debugging;
}

static uint8_t cmd_if(debug_root *root, parsed_command *cmd)
{
	return execute_block(root, debug_cast_bool(cmd->args[0].value) ? &cmd->block : &cmd->else_block);
}

static uint8_t cmd_while(debug_root *root, parsed_command *cmd)
{
	if (!debug_cast_bool(cmd->args[0].value)) {
		return execute_block(root, &cmd->else_block);
	}
	int debugging = 1;
	do {
		debugging = execute_block(root, &cmd->block) && debugging;
		if (!eval_expr(root, cmd->args[0].parsed, &cmd->args[0].value)) {
			fprintf(stderr, "Failed to eval %s\n", cmd->args[0].raw);
			return 1;
		}
	} while (debug_cast_bool(cmd->args[0].value));
	return debugging;
}

const char *expr_type_names[] = {
	"EXPR_NONE",
	"EXPR_SCALAR",
	"EXPR_UNARY",
	"EXPR_BINARY",
	"EXPR_SIZE",
	"EXPR_MEM"
};

static uint8_t cmd_function(debug_root *root, parsed_command *cmd)
{
	debug_root *set_root = root;
	expr *set_expr = cmd->args[0].parsed;
	while (set_expr->type == EXPR_NAMESPACE)
	{
		set_root = tern_find_ptr(set_root->other_roots, set_expr->op.v.str);
		if (!set_root) {
			fprintf(stderr, "%s is not a valid namespace\n", set_expr->op.v.str);
			return 1;
		}
		set_expr = set_expr->left;
	}
	if (set_expr->type != EXPR_SCALAR || set_expr->op.type != TOKEN_NAME) {
		fprintf(stderr, "Arguments to function must be names, bug argument 0 is %s\n", expr_type_names[set_expr->type]);
		return 1;
	}
	debug_var *var = tern_find_ptr(set_root->variables, set_expr->op.v.str);
	if (var) {
		fprintf(stderr, "%s is already defined\n", set_expr->op.v.str);
		return 1;
	}
	for (uint32_t i = 1; i < cmd->num_args; i++)
	{
		if (cmd->args[i].parsed->type != EXPR_SCALAR || cmd->args[i].parsed->op.type != TOKEN_NAME) {
			fprintf(stderr, "Arguments to function must be names, bug argument %d is %s\n", i, expr_type_names[cmd->args[i].parsed->type]);
			return 1;
		}
	}
	char **args = calloc(cmd->num_args - 1, sizeof(char *));
	for (uint32_t i = 1; i < cmd->num_args; i++)
	{
		args[i - 1] = cmd->args[i].parsed->op.v.str;
		cmd->args[i].parsed->op.v.str = NULL;
	}
	new_readonly_variable(set_root, set_expr->op.v.str, new_user_func(&cmd->block, args, cmd->num_args - 1));
	cmd->block.commands = NULL;
	cmd->block.num_commands = 0;
	return 1;
}

static uint8_t cmd_return(debug_root *root, parsed_command *cmd)
{
	root->retval = cmd->args[0].value;
	return 0;
}

static uint8_t cmd_set(debug_root *root, parsed_command *cmd)
{
	char *name = NULL;
	char size = 0;
	debug_root *set_root = root;
	expr *set_expr = cmd->args[0].parsed;
	while (set_expr->type == EXPR_NAMESPACE)
	{
		set_root = tern_find_ptr(set_root->other_roots, set_expr->op.v.str);
		if (!set_root) {
			fprintf(stderr, "%s is not a valid namespace\n", set_expr->op.v.str);
			return 1;
		}
		set_expr = set_expr->left;
	}
	debug_val address;
	debug_array *array = NULL;
	switch (set_expr->type)
	{
	case EXPR_SCALAR:
		if (set_expr->op.type == TOKEN_NAME) {
			name = set_expr->op.v.str;
		} else {
			fputs("First argument to set must be a name or memory expression, not a number", stderr);
			return 1;
		}
		break;
	case EXPR_SIZE:
		size = set_expr->op.v.op[0];
		if (set_expr->left->op.type == TOKEN_NAME) {
			name = set_expr->left->op.v.str;
		} else {
			fputs("First argument to set must be a name or memory expression, not a number", stderr);
			return 1;
		}
		break;
	case EXPR_MEM:
		size = set_expr->op.v.op[0];
		if (!eval_expr(root, set_expr->left, &address)) {
			fprintf(stderr, "Failed to eval %s\n", cmd->args[0].raw);
			return 1;
		}
		if (address.type != DBG_VAL_U32) {
			fprintf(stderr, "Index in array expression must be integer\n");
			return 1;
		}
		if (set_expr->right) {
			debug_val right;
			if (!eval_expr(root, set_expr->right, &right)) {
				return 1;
			}
			array = get_array(right);
			if (!array) {
				fprintf(stderr, "%s does not refer to an array\n", cmd->args[0].raw);
				return 1;
			}
			if (!array->set) {
				fprintf(stderr, "Array %s is read-only\n", set_expr->right->op.v.str);
				return 1;
			}
			if (address.v.u32 >= array->size) {
				fprintf(stderr, "Address $%X is out of bounds for array %s\n", address.v.u32, set_expr->right->op.v.str);
				return 1;
			}
		}
		break;
	default:
		fprintf(stderr, "First argument to set must be a name or memory expression, got %s\n", expr_type_names[set_expr->type]);
		return 1;
	}
	if (!eval_expr(root, cmd->args[1].parsed, &cmd->args[1].value)) {
		fprintf(stderr, "Failed to eval %s\n", cmd->args[1].raw);
		return 1;
	}
	debug_val value = cmd->args[1].value;
	if (name) {
		debug_var *var = tern_find_ptr(set_root->variables, name);
		if (!var) {
			fprintf(stderr, "%s is not defined\n", name);
			return 1;
		}
		if (!var->set) {
			fprintf(stderr, "%s is read-only\n", name);
			return 1;
		}
		if (size && size != 'l') {
			debug_val old = var->get(var);
			if (size == 'b') {
				old.v.u32 &= 0xFFFFFF00;
				value.v.u32 &= 0xFF;
				value.v.u32 |= old.v.u32;
			} else {
				old.v.u32 &= 0xFFFF0000;
				value.v.u32 &= 0xFFFF;
				value.v.u32 |= old.v.u32;
			}
		}
		var->set(var, value);
	} else if (array) {
		array->set(array, address.v.u32, value);
	} else if (!root->write_mem(root, address.v.u32, value.v.u32, size)) {
		fprintf(stderr, "Failed to write to address $%X\n", address.v.u32);
	}
	return 1;
}

static uint8_t cmd_variable(debug_root *root, parsed_command *cmd)
{
	debug_root *set_root = root;
	expr *set_expr = cmd->args[0].parsed;
	while (set_expr->type == EXPR_NAMESPACE)
	{
		set_root = tern_find_ptr(set_root->other_roots, set_expr->op.v.str);
		if (!set_root) {
			fprintf(stderr, "%s is not a valid namespace\n", set_expr->op.v.str);
			return 1;
		}
		set_expr = set_expr->left;
	}
	if (set_expr->type != EXPR_SCALAR || set_expr->op.type != TOKEN_NAME) {
		fprintf(stderr, "First argument to variable must be a name, got %s\n", expr_type_names[set_expr->type]);
		return 1;
	}
	debug_var *var = tern_find_ptr(set_root->variables, set_expr->op.v.str);
	if (var) {
		fprintf(stderr, "%s is already defined\n", set_expr->op.v.str);
		return 1;
	}
	debug_val value;
	value.type = DBG_VAL_U32;
	value.v.u32 = 0;
	if (cmd->num_args > 1) {
		if (!eval_expr(root, cmd->args[1].parsed, &cmd->args[1].value)) {
			fprintf(stderr, "Failed to eval %s\n", cmd->args[1].raw);
			return 1;
		}
		value = cmd->args[1].value;
	}
	new_user_variable(set_root, set_expr->op.v.str, value);
	return 1;
}

static uint8_t cmd_array(debug_root *root, parsed_command *cmd)
{
	debug_root *set_root = root;
	expr *set_expr = cmd->args[0].parsed;
	while (set_expr->type == EXPR_NAMESPACE)
	{
		set_root = tern_find_ptr(set_root->other_roots, set_expr->op.v.str);
		if (!set_root) {
			fprintf(stderr, "%s is not a valid namespace\n", set_expr->op.v.str);
			return 1;
		}
		set_expr = set_expr->left;
	}
	if (set_expr->type != EXPR_SCALAR || set_expr->op.type != TOKEN_NAME) {
		fprintf(stderr, "First argument to array must be a name, got %s\n", expr_type_names[set_expr->type]);
		return 1;
	}
	debug_var *var = tern_find_ptr(set_root->variables, set_expr->op.v.str);
	debug_array *array;
	if (var) {
		debug_val val = var->get(var);
		array = get_array(val);
		if (!array) {
			fprintf(stderr, "%s is already defined as a non-array value\n", set_expr->op.v.str);
			return 1;
		}
	} else {
		var = calloc(1, sizeof(debug_var));
		var->get = user_var_get;
		var->set = user_var_set;
		var->val = new_user_array(cmd->num_args - 1);
		set_root->variables = tern_insert_ptr(set_root->variables, set_expr->op.v.str, var);
		array = get_array(var->val);
	}
	if (array->set == user_array_set) {
		array->size = cmd->num_args - 1;
		if (array->storage < array->size) {
			array->storage = array->size;
			array->base = realloc(array->base, sizeof(debug_val) * array->storage);
		}
	}
	for (uint32_t i = 1; i < cmd->num_args && i <= array->size; i++)
	{
		if (!eval_expr(root, cmd->args[i].parsed, &cmd->args[i].value)) {
			fprintf(stderr, "Failed to eval %s\n", cmd->args[i].raw);
			return 1;
		}
		array->set(array, i - 1, cmd->args[i].value);
	}
	return 1;
}

static uint8_t cmd_append(debug_root *root, parsed_command *cmd)
{
	debug_array *array = get_array(cmd->args[0].value);
	if (!array) {
		fprintf(stderr, "%s is not an array\n", cmd->args[0].raw);
		return 1;
	}
	if (!array->append) {
		fprintf(stderr, "Array %s doesn't support appending\n", cmd->args[0].raw);
		return 1;
	}
	array->append(array, cmd->args[1].value);
	return 1;
}

static uint8_t cmd_frames(debug_root *root, parsed_command *cmd)
{
	uint32_t frames;
	if (!debug_cast_int(cmd->args[0].value, &frames)) {
		fprintf(stderr, "Argument to frames must be an integer\n");
		return 1;
	}
	current_system->enter_debugger_frames = frames;
	return 0;
}

static uint8_t cmd_bindup(debug_root *root, parsed_command *cmd)
{
	char *bind = get_cstring(cmd->args[0].value);
	if (!bind) {
		fprintf(stderr, "Argument to bindup must be a string\n");
		return 1;
	}
	if (!bind_up(bind)) {
		fprintf(stderr, "%s is not a valid binding name\n", bind);
	}
	return 1;
}

static uint8_t cmd_binddown(debug_root *root, parsed_command *cmd)
{
	char *bind = get_cstring(cmd->args[0].value);
	if (!bind) {
		fprintf(stderr, "Argument to binddown must be a string\n");
		return 1;
	}
	if (!bind_down(bind)) {
		fprintf(stderr, "%s is not a valid binding name\n", bind);
	}
	return 1;
}

static uint8_t cmd_condition(debug_root *root, parsed_command *cmd)
{
	if (!eval_expr(root, cmd->args[0].parsed, &cmd->args[0].value)) {
		fprintf(stderr, "Failed to evaluate breakpoint number: %s\n", cmd->args[0].raw);
		return 1;
	}
	uint32_t index;
	if (!debug_cast_int(cmd->args[0].value, &index)) {
		fprintf(stderr, "First argument to condition must be an integer\n");
		return 1;
	}
	bp_def **target = find_breakpoint_idx(&root->breakpoints, index);
	if (!*target) {
		fprintf(stderr, "Failed to find breakpoint %u\n", index);
		return 1;
	}
	free_expr((*target)->condition);
	if (cmd->num_args > 1 && cmd->args[1].parsed) {
		(*target)->condition = cmd->args[1].parsed;
		cmd->args[1].parsed = NULL;
	} else {
		(*target)->condition = NULL;
	}
	return 1;
}

static void symbol_max_len(char *key, tern_val val, uint8_t valtype, void *data)
{
	size_t *max_len = data;
	size_t len = strlen(key);
	if (len > *max_len) {
		*max_len = len;
	}
}

static void print_symbol(char *key, tern_val val, uint8_t valtype, void *data)
{
	size_t *padding = data;
	size_t len = strlen(key);
	fputs(key, stdout);
	while (len < *padding)
	{
		putchar(' ');
		len++;
	}
	printf("$%X\n", (uint32_t)val.intval);
}

static uint8_t cmd_symbols(debug_root *root, parsed_command *cmd)
{
	if (cmd->num_args) {
		char *filename = get_cstring(cmd->args[0].value);
		if (!filename) {
			fprintf(stderr, "Argument to symbols must be a string if provided\n");
			return 1;
		}
		FILE *f = fopen(filename, "r");
		if (!f) {
			fprintf(stderr, "Failed to open %s for reading\n", filename);
			return 1;
		}
		char linebuf[1024];
		while (fgets(linebuf, sizeof(linebuf), f))
		{
			char *line = strip_ws(linebuf);
			if (*line) {
				char *end;
				uint32_t address = strtol(line, &end, 16);
				if (end != line) {
					if (*end == '=') {
						char *name = strip_ws(end + 1);
						add_label(root->disasm, name, address);
						root->symbols = tern_insert_int(root->symbols, name, address);
					}
				}
			}
		}
	} else {
		size_t max_len = 0;
		tern_foreach(root->symbols, symbol_max_len, &max_len);
		max_len += 2;
		tern_foreach(root->symbols, print_symbol, &max_len);
	}
	return 1;
}

static uint8_t cmd_save(debug_root *root, parsed_command *cmd)
{
	char size = cmd->format ? cmd->format[0] : 'b';
	if (size != 'b' && size != 'w' && size != 'l') {
		fprintf(stderr, "Invalid size %s\n", cmd->format);
		return 1;
	}
	if (!eval_expr(root, cmd->args[0].parsed, &cmd->args[0].value)) {
		fprintf(stderr, "Failed to eval %s\n", cmd->args[0].raw);
		return 1;
	}
	char *fname = get_cstring(cmd->args[0].value);
	if (!fname) {
		fprintf(stderr, "First argument to save must be a string\n");
		return 1;
	}
	FILE *f = fopen(fname, "wb");
	if (!f) {
		fprintf(stderr, "Failed to open %s for writing\n", fname);
		return 1;
	}
	uint32_t start = 0;
	debug_val val;
	debug_array * arr = NULL;
	if (cmd->args[1].parsed->type == EXPR_MEM) {

		if (!eval_expr(root, cmd->args[1].parsed->left, &val)) {
			fprintf(stderr, "Failed to eval start index\n");
			goto cleanup;
		}
		if (!debug_cast_int(val, &start)) {
			fprintf(stderr, "Start index must evaluate to integer\n");
			goto cleanup;
		}
		if (cmd->args[1].parsed->right) {
			if (!eval_expr(root, cmd->args[1].parsed->right, &val)) {
				fprintf(stderr, "Failed to eval array name in argument %s\n", cmd->args[1].raw);
				goto cleanup;
			}
			arr = get_array(val);
			if (!arr) {
				fprintf(stderr, "Name in argument %s did not evaluate to an array\n", cmd->args[1].raw);
				goto cleanup;
			}
		}
	} else {
		if (!eval_expr(root, cmd->args[1].parsed, &val)) {
			fprintf(stderr, "Failed to eval %s\n", cmd->args[1].raw);
			goto cleanup;
		}
		arr = get_array(val);
		if (!arr) {
			fprintf(stderr, "Argument %s did not evaluate to an array\n", cmd->args[1].raw);
			goto cleanup;
		}
	}
	uint32_t count = 0;
	if (cmd->num_args > 2) {
		if (!eval_expr(root, cmd->args[2].parsed, &val)) {
			fprintf(stderr, "Failed to eval %s\n", cmd->args[2].raw);
			goto cleanup;
		}
		if (!debug_cast_int(val, &count)) {
			fprintf(stderr, "Count must evaluate to integer\n");
			goto cleanup;
		}
	} else if (arr) {
		count = arr->size < start ? 0 : arr->size - start;
	} else {
		count = root->chunk_end(root, start) - start;
		if (size == 'l') {
			count /= 4;
		} else if (size == 'w') {
			count /= 2;
		}
	}
	union {
		uint8_t b[1024];
		uint16_t w[512];
		uint32_t l[256];
	} buffer;
	uint32_t cur = start;
	if (size == 'l') {
		while (count)
		{
			uint32_t n = count < 256 ? count : 256;
			count -= n;
			for (uint32_t i = 0; i < n ; i++)
			{
				if (arr) {
					val = arr->get(arr, cur++);
					if (!debug_cast_int(val, buffer.l + i)) {
						n = i;
						count = 0;
					}
				} else {
					buffer.l[i] = cur;
					cur += 4;
					if (!root->read_mem(root, buffer.l + i, 'l')) {
						n = i;
						count = 0;
					}
				}
			}
			fwrite(buffer.l, sizeof(uint32_t), n, f);
		}
	} else if (size == 'w') {
		while (count)
		{
			uint32_t n = count < 512 ? count : 512;
			count -= n;
			uint32_t tmp;
			for (uint32_t i = 0; i < n ; i++)
			{
				if (arr) {
					val = arr->get(arr, cur++);
					if (!debug_cast_int(val, &tmp)) {
						n = i;
						count = 0;
					}
				} else {
					tmp = cur;
					cur += 2;
					if (!root->read_mem(root, &tmp, 'w')) {
						n = i;
						count = 0;
					}
				}
				buffer.w[i] = tmp;
			}
			fwrite(buffer.w, sizeof(uint16_t), n, f);
		}
	} else {
		while (count)
		{
			uint32_t n = count < 1024 ? count : 1024;
			count -= n;
			uint32_t tmp;
			for (uint32_t i = 0; i < n ; i++)
			{
				if (arr) {
					val = arr->get(arr, cur++);
					if (!debug_cast_int(val, &tmp)) {
						n = i;
						count = 0;
					}
				} else {
					tmp = cur++;
					if (!root->read_mem(root, &tmp, 'b')) {
						n = i;
						count = 0;
					}
				}
				buffer.b[i] = tmp;
			}
			fwrite(buffer.b, sizeof(uint8_t), n, f);
		}
	}
cleanup:
	fclose(f);
	return 1;
}

static uint8_t cmd_load(debug_root *root, parsed_command *cmd)
{
	char size = cmd->format ? cmd->format[0] : 'b';
	if (size != 'b' && size != 'w' && size != 'l') {
		fprintf(stderr, "Invalid size %s\n", cmd->format);
		return 1;
	}
	if (!eval_expr(root, cmd->args[0].parsed, &cmd->args[0].value)) {
		fprintf(stderr, "Failed to eval %s\n", cmd->args[0].raw);
		return 1;
	}
	char *fname = get_cstring(cmd->args[0].value);
	if (!fname) {
		fprintf(stderr, "First argument to load must be a string\n");
		return 1;
	}
	FILE *f = fopen(fname, "rb");
	if (!f) {
		fprintf(stderr, "Failed to open %s for reading\n", fname);
		return 1;
	}
	uint32_t start = 0;
	debug_val val;
	debug_array * arr = NULL;
	if (cmd->args[1].parsed->type == EXPR_MEM) {

		if (!eval_expr(root, cmd->args[1].parsed->left, &val)) {
			fprintf(stderr, "Failed to eval start index\n");
			goto cleanup;
		}
		if (!debug_cast_int(val, &start)) {
			fprintf(stderr, "Start index must evaluate to integer\n");
			goto cleanup;
		}
		if (cmd->args[1].parsed->right) {
			if (!eval_expr(root, cmd->args[1].parsed->right, &val)) {
				fprintf(stderr, "Failed to eval array name in argument %s\n", cmd->args[1].raw);
				goto cleanup;
			}
			arr = get_array(val);
			if (!arr) {
				fprintf(stderr, "Name in argument %s did not evaluate to an array\n", cmd->args[1].raw);
				goto cleanup;
			}
		}
	} else {
		if (!eval_expr(root, cmd->args[1].parsed, &val)) {
			fprintf(stderr, "Failed to eval %s\n", cmd->args[1].raw);
			goto cleanup;
		}
		arr = get_array(val);
		if (!arr) {
			fprintf(stderr, "Argument %s did not evaluate to an array\n", cmd->args[1].raw);
			goto cleanup;
		}
	}
	uint32_t count = 0;
	uint8_t has_count = 0;
	if (cmd->num_args > 2) {
		if (!eval_expr(root, cmd->args[2].parsed, &val)) {
			fprintf(stderr, "Failed to eval %s\n", cmd->args[2].raw);
			goto cleanup;
		}
		if (!debug_cast_int(val, &count)) {
			fprintf(stderr, "Count must evaluate to integer\n");
			goto cleanup;
		}
		has_count = 1;
	}
	union {
		uint8_t b[1024];
		uint16_t w[512];
		uint32_t l[256];
	} buffer;
	uint32_t cur = start;
	if (size == 'l') {
		while (count || !has_count)
		{
			uint32_t n = (has_count && count < 256) ? count : 256;
			count -= n;
			n = fread(buffer.l, sizeof(uint32_t), n, f);
			if (!n) {
				break;
			}
			for (uint32_t i = 0; i < n ; i++)
			{
				if (arr) {
					val = debug_int(buffer.l[i]);
					if (cur >= arr->size) {
						if (arr->append) {
							arr->append(arr, val);
						} else {
							goto cleanup;
						}
					} else {
						arr->set(arr, cur, val);
					}
					cur++;
				} else {
					if (!root->write_mem(root, cur, buffer.l[i], 'l')) {
						goto cleanup;
					}
					cur += 4;
				}
			}
		}
	} else if (size == 'w') {
		while (count || !has_count)
		{
			uint32_t n = (has_count && count < 512) ? count : 512;
			count -= n;
			n = fread(buffer.w, sizeof(uint16_t), n, f);
			if (!n) {
				break;
			}
			for (uint32_t i = 0; i < n ; i++)
			{
				if (arr) {
					val = debug_int(buffer.w[i]);
					if (cur >= arr->size) {
						if (arr->append) {
							arr->append(arr, val);
						} else {
							goto cleanup;
						}
					} else {
						arr->set(arr, cur, val);
					}
					cur++;
				} else {
					if (!root->write_mem(root, cur, buffer.w[i], 'w')) {
						goto cleanup;
					}
					cur += 2;
				}
			}
		}
	} else {
		while (count || !has_count)
		{
			uint32_t n = (has_count && count < 1024) ? count : 1024;
			count -= n;
			n = fread(buffer.b, sizeof(uint8_t), n, f);
			if (!n) {
				break;
			}
			for (uint32_t i = 0; i < n ; i++)
			{
				if (arr) {
					val = debug_int(buffer.b[i]);
					if (cur >= arr->size) {
						if (arr->append) {
							arr->append(arr, val);
						} else {
							goto cleanup;
						}
					} else {
						arr->set(arr, cur, val);
					}
				} else {
					if (!root->write_mem(root, cur, buffer.b[i], 'b')) {
						goto cleanup;
					}
				}
				cur++;
			}
		}
	}
cleanup:
	fclose(f);
	return 1;
}

static uint8_t cmd_delete_m68k(debug_root *root, parsed_command *cmd)
{
	uint32_t index;
	if (!debug_cast_int(cmd->args[0].value, &index)) {
		fprintf(stderr, "Argument to delete must be an integer\n");
		return 1;
	}
	bp_def **this_bp = find_breakpoint_idx(&root->breakpoints, index);
	if (!*this_bp) {
		fprintf(stderr, "Breakpoint %d does not exist\n", index);
		return 1;
	}
	bp_def *tmp = *this_bp;
	if (tmp->type == BP_TYPE_CPU) {
		remove_breakpoint(root->cpu_context, tmp->address);
	} else if (tmp->type == BP_TYPE_CPU_WATCH) {
		m68k_remove_watchpoint(root->cpu_context, tmp->address, tmp->mask);
	}
	*this_bp = (*this_bp)->next;
	if (tmp->commands) {
		for (uint32_t i = 0; i < tmp->num_commands; i++)
		{
			free_parsed_command(tmp->commands + i);
		}
		free(tmp->commands);
	}
	free(tmp);
	return 1;
}

static uint8_t cmd_breakpoint_m68k(debug_root *root, parsed_command *cmd)
{
	uint32_t address;
	if (!debug_cast_int(cmd->args[0].value, &address)) {
		fprintf(stderr, "Argument to breakpoint must be an integer\n");
		return 1;
	}
	insert_breakpoint(root->cpu_context, address, debugger);
	bp_def *new_bp = calloc(1, sizeof(bp_def));
	new_bp->next = root->breakpoints;
	new_bp->address = address;
	new_bp->mask = 0xFFFFFF;
	new_bp->index = root->bp_index++;
	new_bp->type = BP_TYPE_CPU;
	root->breakpoints = new_bp;
	printf("68K Breakpoint %d set at $%X\n", new_bp->index, address);
	return 1;
}

static uint8_t cmd_watchpoint_m68k(debug_root *root, parsed_command *cmd)
{
	uint32_t address;
	if (!debug_cast_int(cmd->args[0].value, &address)) {
		fprintf(stderr, "First argument to watchpoint must be an integer\n");
		return 1;
	}
	uint32_t size;
	if (cmd->num_args > 1) {
		if (!debug_cast_int(cmd->args[1].value, &size)) {
			fprintf(stderr, "Second argument to watchpoint must be an integer if provided\n");
			return 1;
		}
	} else {
		//default to byte for odd addresses, word for even
		size = (address & 1) ? 1 : 2;
	}
	m68k_add_watchpoint(root->cpu_context, address, size);
	bp_def *new_bp = calloc(1, sizeof(bp_def));
	new_bp->next = root->breakpoints;
	new_bp->address = address;
	new_bp->mask = size;
	new_bp->index = root->bp_index++;
	new_bp->type = BP_TYPE_CPU_WATCH;
	root->breakpoints = new_bp;
	printf("68K Watchpoint %d set for $%X\n", new_bp->index, address);
	return 1;
}

static void on_vdp_reg_write(vdp_context *context, uint16_t reg, uint16_t value)
{
	value &= 0xFF;
	if (context->regs[reg] == value) {
		return;
	}
	genesis_context *gen = (genesis_context *)context->system;
	debug_root *root = find_m68k_root(gen->m68k);
	bp_def **this_bp = find_breakpoint(&root->breakpoints, reg, BP_TYPE_VDPREG);
	int debugging = 1;
	if (*this_bp) {
		if ((*this_bp)->condition) {
			debug_val condres;
			if (eval_expr(root, (*this_bp)->condition, &condres)) {
				if (!condres.v.u32) {
					return;
				}
			} else {
				fprintf(stderr, "Failed to eval condition for VDP Register Breakpoint %u\n", (*this_bp)->index);
				free_expr((*this_bp)->condition);
				(*this_bp)->condition = NULL;
			}
		}
		for (uint32_t i = 0; debugging && i < (*this_bp)->num_commands; i++)
		{
			debugging = run_command(root, (*this_bp)->commands + i);
		}
		if (debugging) {
			printf("VDP Register Breakpoint %d hit on register write $%X - Old: $%X, New: $%X\n", (*this_bp)->index, reg, context->regs[reg], value);
			gen->header.enter_debugger = 1;
			if (gen->m68k->sync_cycle > gen->m68k->cycles + 1) {
				gen->m68k->sync_cycle = gen->m68k->cycles + 1;
			}
			if (gen->m68k->target_cycle > gen->m68k->sync_cycle) {
				gen->m68k->target_cycle = gen->m68k->sync_cycle;
			}
		}
	}
}

static uint8_t cmd_vdp_reg_break(debug_root *root, parsed_command *cmd)
{
	bp_def *new_bp = calloc(1, sizeof(bp_def));
	new_bp->next = root->breakpoints;
	if (cmd->num_args) {
		if (!debug_cast_int(cmd->args[0].value, &new_bp->address)) {
			fprintf(stderr, "Arguments to vdpregbreak must be integers if provided\n");
			return 1;
		}
		if (cmd->num_args > 1) {
			if (!debug_cast_int(cmd->args[1].value, &new_bp->mask)) {
				fprintf(stderr, "Arguments to vdpregbreak must be integers if provided\n");
				return 1;
			}
		} else {
			new_bp->mask = 0xFF;
		}
	}
	new_bp->index = root->bp_index++;
	new_bp->type = BP_TYPE_VDPREG;
	root->breakpoints = new_bp;
	m68k_context *m68k = root->cpu_context;
	genesis_context *gen = m68k->system;
	gen->vdp->reg_hook = on_vdp_reg_write;
	printf("VDP Register Breakpoint %d set\n", new_bp->index);
	return 1;
}

static uint8_t cmd_advance_m68k(debug_root *root, parsed_command *cmd)
{
	uint32_t address;
	if (!debug_cast_int(cmd->args[0].value, &address)) {
		fprintf(stderr, "Argument to advance must be an integer\n");
		return 1;
	}
	insert_breakpoint(root->cpu_context, address, debugger);
	return 0;
}

static uint8_t cmd_step_m68k(debug_root *root, parsed_command *cmd)
{
	m68kinst *inst = root->inst;
	m68k_context *context = root->cpu_context;
	uint32_t after = root->after;
	if (inst->op == M68K_RTS) {
		after = m68k_read_long(context->aregs[7], context);
	} else if (inst->op == M68K_RTE || inst->op == M68K_RTR) {
		after = m68k_read_long(context->aregs[7] + 2, context);
	} else if(m68k_is_branch(inst)) {
		if (inst->op == M68K_BCC && inst->extra.cond != COND_TRUE) {
			root->branch_f = after;
			root->branch_t = m68k_branch_target(inst, context->dregs, context->aregs) & 0xFFFFFF;
			insert_breakpoint(context, root->branch_t, debugger);
		} else if(inst->op == M68K_DBCC) {
			if (inst->extra.cond == COND_FALSE) {
				if (context->dregs[inst->dst.params.regs.pri] & 0xFFFF) {
					after = m68k_branch_target(inst, context->dregs, context->aregs);
				}
			} else {
				root->branch_t = after;
				root->branch_f = m68k_branch_target(inst, context->dregs, context->aregs);
				insert_breakpoint(context, root->branch_f, debugger);
			}
		} else {
			after = m68k_branch_target(inst, context->dregs, context->aregs) & 0xFFFFFF;
		}
	}
	insert_breakpoint(root->cpu_context, after, debugger);
	return 0;
}

static uint8_t cmd_over_m68k(debug_root *root, parsed_command *cmd)
{
	m68kinst *inst = root->inst;
	m68k_context *context = root->cpu_context;
	uint32_t after = root->after;
	if (inst->op == M68K_RTS) {
		after = m68k_read_long(context->aregs[7], context);
	} else if (inst->op == M68K_RTE || inst->op == M68K_RTR) {
		after = m68k_read_long(context->aregs[7] + 2, context);
	} else if(m68k_is_noncall_branch(inst)) {
		if (inst->op == M68K_BCC && inst->extra.cond != COND_TRUE) {
			root->branch_t = m68k_branch_target(inst, context->dregs, context->aregs)  & 0xFFFFFF;
			if (root->branch_t < after) {
					root->branch_t = 0;
			} else {
				root->branch_f = after;
				insert_breakpoint(context, root->branch_t, debugger);
			}
		} else if(inst->op == M68K_DBCC) {
			uint32_t target = m68k_branch_target(inst, context->dregs, context->aregs)  & 0xFFFFFF;
			if (target > after) {
				if (inst->extra.cond == COND_FALSE) {
					after = target;
				} else {
					root->branch_f = target;
					root->branch_t = after;
					insert_breakpoint(context, root->branch_f, debugger);
				}
			}
		} else {
			after = m68k_branch_target(inst, context->dregs, context->aregs) & 0xFFFFFF;
		}
	}
	insert_breakpoint(root->cpu_context, after, debugger);
	return 0;
}

static uint8_t cmd_next_m68k(debug_root *root, parsed_command *cmd)
{
	m68kinst *inst = root->inst;
	m68k_context *context = root->cpu_context;
	uint32_t after = root->after;
	if (inst->op == M68K_RTS) {
		after = m68k_read_long(context->aregs[7], context);
	} else if (inst->op == M68K_RTE || inst->op == M68K_RTR) {
		after = m68k_read_long(context->aregs[7] + 2, context);
	} else if(m68k_is_noncall_branch(inst)) {
		if (inst->op == M68K_BCC && inst->extra.cond != COND_TRUE) {
			root->branch_f = after;
			root->branch_t = m68k_branch_target(inst, context->dregs, context->aregs);
			insert_breakpoint(context, root->branch_t, debugger);
		} else if(inst->op == M68K_DBCC) {
			if ( inst->extra.cond == COND_FALSE) {
				if (context->dregs[inst->dst.params.regs.pri] & 0xFFFF) {
					after = m68k_branch_target(inst, context->dregs, context->aregs);
				}
			} else {
				root->branch_t = after;
				root->branch_f = m68k_branch_target(inst, context->dregs, context->aregs);
				insert_breakpoint(context, root->branch_f, debugger);
			}
		} else {
			after = m68k_branch_target(inst, context->dregs, context->aregs) & 0xFFFFFF;
		}
	}
	insert_breakpoint(root->cpu_context, after, debugger);
	return 0;
}

static uint8_t cmd_backtrace_m68k(debug_root *root, parsed_command *cmd)
{
	m68k_context *context = root->cpu_context;
#ifdef NEW_CORE
	//TODO: implement me
#else
	uint32_t stack = context->aregs[7];
	uint8_t non_adr_count = 0;
	do {
		uint32_t bt_address = m68k_instruction_fetch(stack, context);
		bt_address = get_instruction_start(context->opts, bt_address - 2);
		if (bt_address) {
			stack += 4;
			non_adr_count = 0;
			m68kinst inst;
			char buf[128];
			m68k_decode(m68k_instruction_fetch, context, &inst, bt_address);
			m68k_disasm(&inst, buf);
			printf("%X: %s\n", bt_address, buf);
		} else {
			//non-return address value on stack can be word wide
			stack += 2;
			non_adr_count++;
		}
		//TODO: Make sure we don't wander into an invalid memory region
	} while (stack && non_adr_count < 6);
#endif
	return 1;
}

static uint8_t cmd_disassemble_m68k(debug_root *root, parsed_command *cmd)
{
	m68k_context *context = root->cpu_context;
	uint32_t address = root->address;
	if (cmd->num_args) {
		if (!debug_cast_int(cmd->args[0].value, &address)) {
			fprintf(stderr, "Argument to disassemble must be an integer if provided\n");
			return 1;
		}
	}
#ifndef NEW_CORE
	char disasm_buf[1024];
	m68kinst inst;
	do {
		label_def *def = find_label(root->disasm, address);
		if (def) {
			for (uint32_t i = 0; i < def->num_labels; i++)
			{
				printf("%s:\n", def->labels[i]);
			}
		}

		address = m68k_decode(m68k_instruction_fetch, context, &inst, address);
		m68k_disasm_labels(&inst, disasm_buf, root->disasm);
		printf("\t%s\n", disasm_buf);
	} while(!m68k_is_terminal(&inst));
#endif
	return 1;
}

static uint8_t cmd_vdp_sprites(debug_root *root, parsed_command *cmd)
{
	m68k_context *context = root->cpu_context;
	genesis_context * gen = context->system;
	vdp_print_sprite_table(gen->vdp);
	return 1;
}

static uint8_t cmd_vdp_regs(debug_root *root, parsed_command *cmd)
{
	m68k_context *context = root->cpu_context;
	genesis_context * gen = context->system;
	vdp_print_reg_explain(gen->vdp);
	return 1;
}

static uint8_t cmd_ym_channel(debug_root *root, parsed_command *cmd)
{
	m68k_context *context = root->cpu_context;
	genesis_context * gen = context->system;
	if (cmd->num_args) {
		if (cmd->args[0].value.v.u32 < 1 || cmd->args[0].value.v.u32 > 6) {
			printf("%d is not a valid YM2612 channel number. Valid values are 1-6\n", cmd->args[0].value.v.u32);
			return 1;
		}
		ym_print_channel_info(gen->ym, cmd->args[0].value.v.u32 - 1);
	} else {
		for (int i = 0; i < 6; i++) {
			ym_print_channel_info(gen->ym, i);
		}
	}
	return 1;
}

static uint8_t cmd_ym_timer(debug_root *root, parsed_command *cmd)
{
	m68k_context *context = root->cpu_context;
	genesis_context * gen = context->system;
	ym_print_timer_info(gen->ym);
	return 1;
}

static uint8_t cmd_sub(debug_root *root, parsed_command *cmd)
{
	char *param = cmd->raw;
	while (param && *param && isblank(*param))
	{
		++param;
	}
	m68k_context *m68k = root->cpu_context;
	genesis_context *gen = m68k->system;
	segacd_context *cd = gen->expansion;
	if (param && *param && !isspace(*param)) {
		parsed_command cmd = {0};
		debug_root *sub_root = find_m68k_root(cd->m68k);
		if (!sub_root) {
			fputs("Failed to get debug root for Sub CPU\n", stderr);
			return 1;
		}
		if (!parse_command(sub_root, param, &cmd)) {
			return 1;
		}
		uint8_t ret = run_command(sub_root, &cmd);
		free_parsed_command(&cmd);
		return ret;
	} else {
		cd->enter_debugger = 1;
		return 0;
	}
}

static uint8_t cmd_main(debug_root *root, parsed_command *cmd)
{
	char *param = cmd->raw;
	while (param && *param && isblank(*param))
	{
		++param;
	}
	m68k_context *m68k = root->cpu_context;
	segacd_context *cd = m68k->system;

	if (param && *param && !isspace(*param)) {
		parsed_command cmd = {0};
		debug_root *main_root = find_m68k_root(cd->genesis->m68k);
		if (!main_root) {
			fputs("Failed to get debug root for Main CPU\n", stderr);
			return 1;
		}
		if (!parse_command(main_root, param, &cmd)) {
			return 1;
		}
		uint8_t ret = run_command(main_root, &cmd);
		free_parsed_command(&cmd);
		return ret;
	} else {
		cd->genesis->header.enter_debugger = 1;
		return 0;
	}
}

static uint8_t cmd_mainsh2(debug_root *root, parsed_command *cmd)
{
	char *param = cmd->raw;
	while (param && *param && isblank(*param))
	{
		++param;
	}
	genesis_context *gen = (genesis_context *)current_system;

	if (param && *param && !isspace(*param)) {
		parsed_command cmd = {0};
		debug_root *main_root = find_sh2_root(gen->mars->main);
		if (!main_root) {
			fputs("Failed to get debug root for Main SH2\n", stderr);
			return 1;
		}
		if (!parse_command(main_root, param, &cmd)) {
			return 1;
		}
		uint8_t ret = run_command(main_root, &cmd);
		free_parsed_command(&cmd);
		return ret;
	} else {
		gen->mars->main_enter_debugger = 1;
		return 0;
	}
}

static uint8_t cmd_subsh2(debug_root *root, parsed_command *cmd)
{
	char *param = cmd->raw;
	while (param && *param && isblank(*param))
	{
		++param;
	}
	genesis_context *gen = (genesis_context *)current_system;

	if (param && *param && !isspace(*param)) {
		parsed_command cmd = {0};
		debug_root *sub_root = find_sh2_root(gen->mars->sub);
		if (!sub_root) {
			fputs("Failed to get debug root for Sub SH2\n", stderr);
			return 1;
		}
		if (!parse_command(sub_root, param, &cmd)) {
			return 1;
		}
		uint8_t ret = run_command(sub_root, &cmd);
		free_parsed_command(&cmd);
		return ret;
	} else {
		gen->mars->sub_enter_debugger = 1;
		return 0;
	}
}

static uint8_t cmd_gen_z80(debug_root *root, parsed_command *cmd)
{
	char *param = cmd->raw;
	while (param && *param && isblank(*param))
	{
		++param;
	}
	m68k_context *m68k = root->cpu_context;
	genesis_context *gen = m68k->system;

	if (param && *param && !isspace(*param)) {
		parsed_command cmd = {0};
		debug_root *z80_root = find_z80_root(gen->z80);
		if (!z80_root) {
			fputs("Failed to get debug root for Z80\n", stderr);
			return 1;
		}
		if (!parse_command(z80_root, param, &cmd)) {
			return 1;
		}
		uint8_t ret = run_command(z80_root, &cmd);
		free_parsed_command(&cmd);
		return ret;
	} else {
		gen->enter_z80_debugger = 1;
		return 0;
	}
}

command_def common_commands[] = {
	{
		.names = (const char *[]){
			"quit", NULL
		},
		.usage = "quit",
		.desc = "Quit BlastEm",
		.impl = cmd_quit,
		.min_args = 0,
		.max_args = 0,
	},
	{
		.names = (const char *[]){
			"help", "?", NULL
		},
		.usage = "help",
		.desc = "Print a list of available commands for the current debug context",
		.impl = cmd_help,
		.min_args = 0,
		.max_args = 1,
		.raw_args = 1
	},
	{
		.names = (const char *[]){
			"continue", "c", NULL
		},
		.usage = "continue",
		.desc = "Resume execution",
		.impl = cmd_continue,
		.min_args = 0,
		.max_args = 0
	},
	{
		.names = (const char *[]){
			"print", "p", NULL
		},
		.usage = "print[/FORMAT] EXPRESSION...",
		.desc = "Print one or more expressions using the optional format character",
		.impl = cmd_print,
		.min_args = 1,
		.max_args = -1
	},
	{
		.names = (const char *[]){
			"printf", NULL
		},
		.usage = "printf FORMAT EXPRESSION...",
		.desc = "Print a string with C-style formatting specifiers replaced with the value of the remaining arguments",
		.impl = cmd_printf,
		.min_args = 1,
		.max_args = -1
	},
	{
		.names = (const char *[]){
			"softreset", "sr", NULL
		},
		.usage = "softreset",
		.desc = "Perform a soft-reset for the current system",
		.impl = cmd_softreset,
		.min_args = 0,
		.max_args = 0,
	},
	{
		.names = (const char *[]){
			"display", NULL
		},
		.usage = "display[/FORMAT] EXPRESSION...",
		.desc = "Print one or more expressions every time the debugger is entered",
		.impl = cmd_display,
		.min_args = 1,
		.max_args = -1
	},
	{
		.names = (const char *[]){
			"deletedisplay", "dd", NULL
		},
		.usage = "deletedisplay DISPLAYNUM",
		.desc = "Remove expressions added with the `display` command",
		.impl = cmd_delete_display,
		.min_args = 1,
		.max_args = 1
	},
	{
		.names = (const char *[]){
			"commands", NULL
		},
		.usage = "command BREAKPOINT",
		.desc = "Set a list of debugger commands to be executed when the given breakpoint is hit",
		.impl = cmd_command,
		.min_args = 1,
		.max_args = 1,
		.has_block = 1
	},
	{
		.names = (const char *[]){
			"function", NULL
		},
		.usage = "function NAME [ARGS...]",
		.desc = "Creates a user-defined function named NAME with arguments ARGS",
		.impl = cmd_function,
		.min_args = 1,
		.max_args = -1,
		.has_block = 1,
		.skip_eval = 1
	},
	{
		.names = (const char *[]){
			"return", NULL
		},
		.usage = "return VALUE",
		.desc = "Return from a user defined function with the result VALUE",
		.impl = cmd_return,
		.min_args = 1,
		.max_args = 1
	},
	{
		.names = (const char *[]){
			"set", NULL
		},
		.usage = "set MEM|NAME VALUE",
		.desc = "Set a register, symbol or memory location to the result of evaluating VALUE",
		.impl = cmd_set,
		.min_args = 2,
		.max_args = 2,
		.skip_eval = 1
	},
	{
		.names = (const char *[]){
			"variable", NULL
		},
		.usage = "variable NAME [VALUE]",
		.desc = "Create a new variable called NAME and set it to VALUE or 0 if no value provided",
		.impl = cmd_variable,
		.min_args = 1,
		.max_args = 2,
		.skip_eval = 1
	},
	{
		.names = (const char *[]){
			"array", NULL
		},
		.usage = "array NAME [VALUE...]",
		.desc = "Create a new array called NAME if it doesn't already exist. The array is initialized with the remaining parameters",
		.impl = cmd_array,
		.min_args = 1,
		.max_args = -1,
		.skip_eval = 1
	},
	{
		.names = (const char *[]){
			"append", NULL
		},
		.usage = "append NAME VALUE",
		.desc = "Increase the size of array NAME by 1 and set the last element to VALUE",
		.impl = cmd_append,
		.min_args = 2,
		.max_args = 2
	},
	{
		.names = (const char *[]){
			"frames", NULL
		},
		.usage = "frames EXPRESSION",
		.desc = "Resume execution for EXPRESSION video frames",
		.impl = cmd_frames,
		.min_args = 1,
		.max_args = 1
	},
	{
		.names = (const char *[]){
			"bindup", NULL
		},
		.usage = "bindup NAME",
		.desc = "Simulate a keyup for binding NAME",
		.impl = cmd_bindup,
		.min_args = 1,
		.max_args = 1
	},
	{
		.names = (const char *[]){
			"binddown", NULL
		},
		.usage = "bindown NAME",
		.desc = "Simulate a keydown for binding NAME",
		.impl = cmd_binddown,
		.min_args = 1,
		.max_args = 1
	},
	{
		.names = (const char *[]){
			"condition", NULL
		},
		.usage = "condition BREAKPOINT [EXPRESSION]",
		.desc = "Makes breakpoint BREAKPOINT conditional on the value of EXPRESSION or removes a condition if EXPRESSION is omitted",
		.impl = cmd_condition,
		.min_args = 1,
		.max_args = 2,
		.skip_eval = 1
	},
	{
		.names = (const char *[]){
			"if", NULL
		},
		.usage = "if CONDITION",
		.desc = "If the condition is true, the following block is executed. Otherwise the else block is executed if present",
		.impl = cmd_if,
		.min_args = 1,
		.max_args = 1,
		.has_block = 1,
		.accepts_else = 1
	},
	{
		.names = (const char *[]){
			"while", NULL
		},
		.usage = "while CONDITION",
		.desc = "The following block is executed repeatedly until the condition is false. If the condition is false at the start, the else block is executed if present",
		.impl = cmd_while,
		.min_args = 1,
		.max_args = 1,
		.has_block = 1,
		.accepts_else = 1
	},
	{
		.names = (const char *[]){
			"symbols", NULL
		},
		.usage = "symbols [FILENAME]",
		.desc = "Loads a list of symbols from the file indicated by FILENAME or lists currently loaded symbols if FILENAME is omitted",
		.impl = cmd_symbols,
		.min_args = 0,
		.max_args = 1
	},
	{
		.names = (const char *[]){
			"save", NULL
		},
		.usage = "save[/SIZE] FILENAME ARRAY [COUNT]",
		.desc = "Saves COUNT elements of size SIZE from the array or memory region specified by ARRAY to a file",
		.impl = cmd_save,
		.min_args = 2,
		.max_args = 3,
		.skip_eval = 1
	},
	{
		.names = (const char *[]){
			"load", NULL
		},
		.usage = "load[/SIZE] FILENAME ARRAY [COUNT]",
		.desc = "Loads COUNT elements of size SIZE from a file to the array or memory region specified by ARRAY",
		.impl = cmd_load,
		.min_args = 2,
		.max_args = 3,
		.skip_eval = 1
	}
};
#define NUM_COMMON (sizeof(common_commands)/sizeof(*common_commands))

command_def m68k_commands[] = {
	{
		.names = (const char *[]){
			"breakpoint", "b", NULL
		},
		.usage = "breakpoint ADDRESSS",
		.desc = "Set a breakpoint at ADDRESS",
		.impl = cmd_breakpoint_m68k,
		.min_args = 1,
		.max_args = 1
	},
	{
		.names = (const char *[]){
			"watchpoint", NULL
		},
		.usage = "watchpoint ADDRESS [SIZE]",
		.desc = "Set a watchpoint at ADDRESS with an optional SIZE in bytes. SIZE defaults to 2 for even address and 1 for odd",
		.impl = cmd_watchpoint_m68k,
		.min_args = 1,
		.max_args = 2
	},
	{
		.names = (const char *[]){
			"advance", NULL
		},
		.usage = "advance ADDRESS",
		.desc = "Advance to ADDRESS",
		.impl = cmd_advance_m68k,
		.min_args = 1,
		.max_args = 1
	},
	{
		.names = (const char *[]){
			"step", "s", NULL
		},
		.usage = "step",
		.desc = "Advance to the next instruction, stepping into subroutines",
		.impl = cmd_step_m68k,
		.min_args = 0,
		.max_args = 0
	},
	{
		.names = (const char *[]){
			"over", NULL
		},
		.usage = "over",
		.desc = "Advance to the next instruction, ignoring branches to lower addresses",
		.impl = cmd_over_m68k,
		.min_args = 0,
		.max_args = 0
	},
	{
		.names = (const char *[]){
			"next", NULL
		},
		.usage = "next",
		.desc = "Advance to the next instruction",
		.impl = cmd_next_m68k,
		.min_args = 0,
		.max_args = 0
	},
	{
		.names = (const char *[]){
			"backtrace", "bt", NULL
		},
		.usage = "backtrace",
		.desc = "Print a backtrace",
		.impl = cmd_backtrace_m68k,
		.min_args = 0,
		.max_args = 0
	},
	{
		.names = (const char *[]){
			"delete", "d", NULL
		},
		.usage = "delete BREAKPOINT",
		.desc = "Remove breakpoint identified by BREAKPOINT",
		.impl = cmd_delete_m68k,
		.min_args = 1,
		.max_args = 1
	},
	{
		.names = (const char *[]){
			"disassemble", "disasm", NULL
		},
		.usage = "disassemble [ADDRESS]",
		.desc = "Disassemble code starting at ADDRESS if provided or the current address if not",
		.impl = cmd_disassemble_m68k,
		.min_args = 0,
		.max_args = 1
	}
};

#define NUM_68K (sizeof(m68k_commands)/sizeof(*m68k_commands))

command_def genesis_commands[] = {
	{
		.names = (const char *[]){
			"vdpsprites", "vs", NULL
		},
		.usage = "vdpsprites",
		.desc = "Print the VDP sprite table",
		.impl = cmd_vdp_sprites,
		.min_args = 0,
		.max_args = 0
	},
	{
		.names = (const char *[]){
			"vdpregs", "vr", NULL
		},
		.usage = "vdpregs",
		.desc = "Print VDP register values with a short description",
		.impl = cmd_vdp_regs,
		.min_args = 0,
		.max_args = 0
	},
	{
		.names = (const char *[]){
			"vdpregbreak", "vregbreak", "vrb", NULL
		},
		.usage = "vdpregbreak [REGISTER [MASK]]",
		.desc = "Enter debugger on VDP register write. If REGISTER is provided, breakpoint will only fire for writes to that register. If MASK is also provided, it will be applied to the register number before comparison with REGISTER",
		.impl = cmd_vdp_reg_break,
		.min_args = 0,
		.max_args = 2
	},
#ifndef NO_Z80
	{
		.names = (const char *[]){
			"z80", NULL
		},
		.usage = "z80 [COMMAND]",
		.desc = "Run a Z80 debugger command or switch to Z80 context when no command is given",
		.impl = cmd_gen_z80,
		.min_args = 0,
		.max_args = -1,
		.raw_args = 1
	},
#endif
	{
		.names = (const char *[]){
			"ymchannel", "yc", NULL
		},
		.usage = "ymchannel [CHANNEL]",
		.desc = "Print YM-2612 channel and operator params. Limited to CHANNEL if specified",
		.impl = cmd_ym_channel,
		.min_args = 0,
		.max_args = 1
	},
	{
		.names = (const char *[]){
			"ymtimer", "yt", NULL
		},
		.usage = "ymtimer",
		.desc = "Print YM-2612 timer info",
		.impl = cmd_ym_timer,
		.min_args = 0,
		.max_args = 0
	}
};

#define NUM_GENESIS (sizeof(genesis_commands)/sizeof(*genesis_commands))

command_def scd_main_commands[] = {
	{
		.names = (const char *[]){
			"subcpu", NULL
		},
		.usage = "subcpu [COMMAND]",
		.desc = "Run a Sub-CPU debugger command or switch to Sub-CPU context when no command is given",
		.impl = cmd_sub,
		.min_args = 0,
		.max_args = -1,
		.raw_args = 1
	}
};

#define NUM_SCD_MAIN (sizeof(scd_main_commands)/sizeof(*scd_main_commands))

command_def scd_sub_commands[] = {
	{
		.names = (const char *[]){
			"maincpu", NULL
		},
		.usage = "maincpu [COMMAND]",
		.desc = "Run a Main-CPU debugger command or switch to Main-CPU context when no command is given",
		.impl = cmd_main,
		.min_args = 0,
		.max_args = -1,
		.raw_args = 1
	}
};

#define NUM_SCD_SUB (sizeof(scd_main_commands)/sizeof(*scd_main_commands))

command_def s32x_68k_commands[] = {
	{
		.names = (const char *[]){
			"mainsh2", NULL
		},
		.usage = "mainsh2 [COMMAND]",
		.desc = "Run a Main SH2 debugger command or switch to Main SH2 context when no command is given",
		.impl = cmd_mainsh2,
		.min_args = 0,
		.max_args = -1,
		.raw_args = 1
	},
	{
		.names = (const char *[]){
			"subsh2", NULL
		},
		.usage = "subsh2 [COMMAND]",
		.desc = "Run a Sub SH2 debugger command or switch to Sub SH2 context when no command is given",
		.impl = cmd_subsh2,
		.min_args = 0,
		.max_args = -1,
		.raw_args = 1
	}
};

#define NUM_32X_68K (sizeof(s32x_68k_commands)/sizeof(*s32x_68k_commands))

#ifndef NO_Z80
#ifndef NEW_CORE

static uint8_t cmd_delete_z80(debug_root *root, parsed_command *cmd)
{
	uint32_t index;
	if (!debug_cast_int(cmd->args[0].value, &index)) {
		fprintf(stderr, "Argument to delete must be an integer\n");
		return 1;
	}
	bp_def **this_bp = find_breakpoint_idx(&root->breakpoints, index);
	if (!*this_bp) {
		fprintf(stderr, "Breakpoint %d does not exist\n", index);
		return 1;
	}
	bp_def *tmp = *this_bp;
	if (tmp->type == BP_TYPE_CPU) {
		zremove_breakpoint(root->cpu_context, tmp->address);
	} else if (tmp->type == BP_TYPE_CPU_WATCH) {
		z80_remove_watchpoint(root->cpu_context, tmp->address, tmp->mask);
	}
	*this_bp = (*this_bp)->next;
	if (tmp->commands) {
		for (uint32_t i = 0; i < tmp->num_commands; i++)
		{
			free_parsed_command(tmp->commands + i);
		}
		free(tmp->commands);
	}
	free(tmp);
	return 1;
}

static uint8_t cmd_breakpoint_z80(debug_root *root, parsed_command *cmd)
{
	uint32_t address;
	if (!debug_cast_int(cmd->args[0].value, &address)) {
		fprintf(stderr, "Argument to breakpoint must be an integer\n");
		return 1;
	}
	zinsert_breakpoint(root->cpu_context, address, (uint8_t *)zdebugger);
	bp_def *new_bp = calloc(1, sizeof(bp_def));
	new_bp->next = root->breakpoints;
	new_bp->address = address;
	new_bp->mask = 0xFFFF;
	new_bp->type = BP_TYPE_CPU;
	new_bp->index = root->bp_index++;
	root->breakpoints = new_bp;
	printf("Z80 Breakpoint %d set at $%X\n", new_bp->index, address);
	return 1;
}

static uint8_t cmd_watchpoint_z80(debug_root *root, parsed_command *cmd)
{
	uint32_t address;
	if (!debug_cast_int(cmd->args[0].value, &address)) {
		fprintf(stderr, "First argument to watchpoint must be an integer\n");
		return 1;
	}
	uint32_t size = 1;
	if (cmd->num_args > 1) {
		if (!debug_cast_int(cmd->args[1].value, &size)) {
			fprintf(stderr, "Second argument to watchpoint must be an integer if provided\n");
			return 1;
		}
	}
	z80_add_watchpoint(root->cpu_context, address, size);
	bp_def *new_bp = calloc(1, sizeof(bp_def));
	new_bp->next = root->breakpoints;
	new_bp->address = address;
	new_bp->mask = size;
	new_bp->index = root->bp_index++;
	new_bp->type = BP_TYPE_CPU_WATCH;
	root->breakpoints = new_bp;
	printf("Z80 Watchpoint %d set for $%X\n", new_bp->index, address);
	return 1;
}

static uint8_t cmd_advance_z80(debug_root *root, parsed_command *cmd)
{
	uint32_t address;
	if (!debug_cast_int(cmd->args[0].value, &address)) {
		fprintf(stderr, "Argument to advance must be an integer\n");
		return 1;
	}
	zinsert_breakpoint(root->cpu_context, address, (uint8_t *)zdebugger);
	return 0;
}

static uint8_t cmd_step_z80(debug_root *root, parsed_command *cmd)
{
	z80inst *inst = root->inst;
	z80_context *context = root->cpu_context;
	uint32_t after = root->after;
	//TODO: handle conditional branches
	if (inst->op == Z80_JP || inst->op == Z80_CALL || inst->op == Z80_RST) {
		if (inst->addr_mode == Z80_IMMED) {
			after = inst->immed;
		} else if (inst->ea_reg == Z80_HL) {
#ifndef NEW_CORE
			after = context->regs[Z80_H] << 8 | context->regs[Z80_L];
		} else if (inst->ea_reg == Z80_IX) {
			after = context->regs[Z80_IXH] << 8 | context->regs[Z80_IXL];
		} else if (inst->ea_reg == Z80_IY) {
			after = context->regs[Z80_IYH] << 8 | context->regs[Z80_IYL];
#endif
		}
#ifndef NEW_CORE
	} else if (inst->op == Z80_JPCC || inst->op == Z80_CALLCC) {
		uint8_t invert = 0;
		uint8_t flag = 0;
		switch (inst->reg)
		{
		case Z80_CC_NZ:
			invert = 1;
		case Z80_CC_Z:
			flag = context->flags[ZF_Z];
			break;
		case Z80_CC_NC:
			invert = 1;
		case Z80_CC_C:
			flag = context->flags[ZF_C];
			break;
		case Z80_CC_PO:
			invert = 1;
		case Z80_CC_PE:
			flag = context->flags[ZF_PV];
			break;
		case Z80_CC_P:
			invert = 1;
		case Z80_CC_M:
			flag = context->flags[ZF_S];
			break;
		}
		if (invert) {
			flag = !flag;
		}
		if (flag) {
			after = inst->immed;
		}
	} else if (inst->op == Z80_JRCC) {
		uint8_t invert = 0;
		uint8_t flag = 0;
		switch (inst->reg)
		{
		case Z80_CC_NZ:
			invert = 1;
		case Z80_CC_Z:
			flag = context->flags[ZF_Z];
			break;
		case Z80_CC_NC:
			invert = 1;
		case Z80_CC_C:
			flag = context->flags[ZF_C];
			break;
		}
		if (invert) {
			flag = !flag;
		}
		if (flag) {
			after += inst->immed;
		}
	} else if (inst->op == Z80_DJNZ) {
		if (context->regs[Z80_B] != 1) {
			after += inst->immed;
		}
#endif
	} else if(inst->op == Z80_JR) {
		after += inst->immed;
	} else if(inst->op == Z80_RET) {
		uint8_t *sp = get_native_pointer(context->sp, (void **)context->mem_pointers, &context->Z80_OPTS->gen);
		if (sp) {
			after = *sp;
			sp = get_native_pointer((context->sp + 1) & 0xFFFF, (void **)context->mem_pointers, &context->Z80_OPTS->gen);
			if (sp) {
				after |= *sp << 8;
			}
		}
	}
	zinsert_breakpoint(context, after, (uint8_t *)zdebugger);
	return 0;
}

static uint8_t cmd_next_z80(debug_root *root, parsed_command *cmd)
{
	z80inst *inst = root->inst;
	if (inst->op != Z80_CALL && inst->op != Z80_CALLCC && inst->op != Z80_RST) {
		return cmd_step_z80(root, cmd);
	}
	z80_context *context = root->cpu_context;
	uint32_t after = root->after;
	zinsert_breakpoint(context, after, (uint8_t *)zdebugger);
	return 0;
}

static uint8_t cmd_over_z80(debug_root *root, parsed_command *cmd)
{
	z80inst *inst = root->inst;
	z80_context *context = root->cpu_context;
	uint32_t after = root->after;
#ifndef NEW_CORE
	if (inst->op == Z80_JPCC) {
		if (inst->immed < after) {
			zinsert_breakpoint(context, inst->immed, (uint8_t *)zdebugger);
			return 0;
		}
	} else if (inst->op == Z80_JRCC || inst->op == Z80_DJNZ) {
		after += inst->immed;
		if (after < root->after) {
			zinsert_breakpoint(context, after, (uint8_t *)zdebugger);
			return 0;
		}
	}
#endif
	return cmd_next_z80(root, cmd);
}

static uint8_t cmd_backtrace_z80(debug_root *root, parsed_command *cmd)
{
	z80_context *context = root->cpu_context;
	uint32_t stack = context->sp;
	uint8_t non_adr_count = 0;
	do {
		uint32_t bt_address = stack;
		if (!root->read_mem(root, &bt_address, 'w')) {
			break;
		}
		bt_address = z80_get_instruction_start(context, bt_address - 1);
		if (bt_address != 0xFEEDFEED) {
			stack += 4;
			non_adr_count = 0;
			z80inst inst;
			char buf[128];
			uint8_t *pc = get_native_pointer(bt_address, (void **)context->mem_pointers, &context->Z80_OPTS->gen);
			z80_decode(pc, &inst);
			z80_disasm(&inst, buf, bt_address);
			printf("%X: %s\n", bt_address, buf);
		} else {
			//non-return address value on stack can be byte wide
			stack++;
			non_adr_count++;
		}
		//TODO: Make sure we don't wander into an invalid memory region
	} while (stack && non_adr_count < 6);
	return 1;
}

static uint8_t cmd_disassemble_z80(debug_root *root, parsed_command *cmd)
{
	z80_context *context = root->cpu_context;
	uint32_t address = root->address;
	if (cmd->num_args) {
		if (!debug_cast_int(cmd->args[0].value, &address)) {
			fprintf(stderr, "Argument to disassemble must be an integer if provided\n");
			return 1;
		}
	}
	char disasm_buf[1024];
	z80inst inst;
	do {
		label_def *def = find_label(root->disasm, address);
		if (def) {
			for (uint32_t i = 0; i < def->num_labels; i++)
			{
				printf("%s:\n", def->labels[i]);
			}
		}
		uint8_t *pc = get_native_pointer(address, (void **)context->mem_pointers, &context->Z80_OPTS->gen);
		uint8_t *after = z80_decode(pc, &inst);
		z80_disasm(&inst, disasm_buf, address);
		address += after - pc;
		printf("\t%s\n", disasm_buf);
	} while(!z80_is_terminal(&inst));
	return 1;
}
#endif //NEW_CORE

static uint8_t cmd_gen_m68k(debug_root *root, parsed_command *cmd)
{
	char *param = cmd->raw;
	while (param && *param && isblank(*param))
	{
		++param;
	}
	genesis_context *gen = (genesis_context *)current_system;

	if (param && *param && !isspace(*param)) {
		parsed_command cmd = {0};
		debug_root *m68k_root = find_m68k_root(gen->m68k);
		if (!m68k_root) {
			fputs("Failed to get debug root for M68K\n", stderr);
			return 1;
		}
		if (!parse_command(m68k_root, param, &cmd)) {
			return 1;
		}
		uint8_t ret = run_command(m68k_root, &cmd);
		free_parsed_command(&cmd);
		return ret;
	} else {
		gen->header.enter_debugger = 1;
		return 0;
	}
}

static uint8_t cmd_ym_channel_z80(debug_root *root, parsed_command *cmd)
{
	z80_context *context = root->cpu_context;
	genesis_context * gen = context->system;
	if (cmd->num_args) {
		if (cmd->args[0].value.v.u32 < 1 || cmd->args[0].value.v.u32 > 6) {
			printf("%d is not a valid YM2612 channel number. Valid values are 1-6\n", cmd->args[0].value.v.u32);
			return 1;
		}
		ym_print_channel_info(gen->ym, cmd->args[0].value.v.u32 - 1);
	} else {
		for (int i = 0; i < 6; i++) {
			ym_print_channel_info(gen->ym, i);
		}
	}
	return 1;
}

static uint8_t cmd_vdp_sprites_sms(debug_root *root, parsed_command *cmd)
{
	z80_context *context = root->cpu_context;
	sms_context * sms = context->system;
	vdp_print_sprite_table(sms->vdp);
	return 1;
}

static uint8_t cmd_vdp_regs_sms(debug_root *root, parsed_command *cmd)
{
	z80_context *context = root->cpu_context;
	sms_context * sms = context->system;
	vdp_print_reg_explain(sms->vdp);
	return 1;
}

command_def z80_commands[] = {
#ifndef NEW_CORE
	{
		.names = (const char *[]){
			"breakpoint", "b", NULL
		},
		.usage = "breakpoint ADDRESSS",
		.desc = "Set a breakpoint at ADDRESS",
		.impl = cmd_breakpoint_z80,
		.min_args = 1,
		.max_args = 1
	},
	{
		.names = (const char *[]){
			"watchpoint", NULL
		},
		.usage = "watchpoint ADDRESS [SIZE]",
		.desc = "Set a watchpoint at ADDRESS with an optional SIZE in bytes. SIZE defaults to 1",
		.impl = cmd_watchpoint_z80,
		.min_args = 1,
		.max_args = 2
	},
	{
		.names = (const char *[]){
			"advance", NULL
		},
		.usage = "advance ADDRESS",
		.desc = "Advance to ADDRESS",
		.impl = cmd_advance_z80,
		.min_args = 1,
		.max_args = 1
	},
	{
		.names = (const char *[]){
			"step", "s", NULL
		},
		.usage = "step",
		.desc = "Advance to the next instruction, stepping into subroutines",
		.impl = cmd_step_z80,
		.min_args = 0,
		.max_args = 0
	},
	{
		.names = (const char *[]){
			"over", NULL
		},
		.usage = "over",
		.desc = "Advance to the next instruction, ignoring branches to lower addresses",
		.impl = cmd_over_z80,
		.min_args = 0,
		.max_args = 0
	},
	{
		.names = (const char *[]){
			"next", NULL
		},
		.usage = "next",
		.desc = "Advance to the next instruction",
		.impl = cmd_next_z80,
		.min_args = 0,
		.max_args = 0
	},
	{
		.names = (const char *[]){
			"backtrace", "bt", NULL
		},
		.usage = "backtrace",
		.desc = "Print a backtrace",
		.impl = cmd_backtrace_z80,
		.min_args = 0,
		.max_args = 0
	},
	{
		.names = (const char *[]){
			"delete", "d", NULL
		},
		.usage = "delete BREAKPOINT",
		.desc = "Remove breakpoint identified by BREAKPOINT",
		.impl = cmd_delete_z80,
		.min_args = 1,
		.max_args = 1
	},
	{
		.names = (const char *[]){
			"disassemble", "disasm", NULL
		},
		.usage = "disassemble [ADDRESS]",
		.desc = "Disassemble code starting at ADDRESS if provided or the current address if not",
		.impl = cmd_disassemble_z80,
		.min_args = 0,
		.max_args = 1
	}
#endif //NEW_CORE
};

#define NUM_Z80 (sizeof(z80_commands)/sizeof(*z80_commands))

command_def gen_z80_commands[] = {
	{
		.names = (const char *[]){
			"m68k", NULL
		},
		.usage = "m68k [COMMAND]",
		.desc = "Run a M68K debugger command or switch to M68K context when no command is given",
		.impl = cmd_gen_m68k,
		.min_args = 0,
		.max_args = -1,
		.raw_args = 1
	},
	{
		.names = (const char *[]){
			"ymchannel", NULL
		},
		.usage = "ymchannel [CHANNEL]",
		.desc = "Print YM-2612 channel and operator params. Limited to CHANNEL if specified",
		.impl = cmd_ym_channel_z80,
		.min_args = 0,
		.max_args = 1
	}
};

#define NUM_GEN_Z80 (sizeof(gen_z80_commands)/sizeof(*gen_z80_commands))

command_def sms_commands[] = {
	{
		.names = (const char *[]){
			"vdpsprites", "vs", NULL
		},
		.usage = "vdpsprites",
		.desc = "Print the VDP sprite table",
		.impl = cmd_vdp_sprites_sms,
		.min_args = 0,
		.max_args = 0
	},
	{
		.names = (const char *[]){
			"vdpsregs", "vr", NULL
		},
		.usage = "vdpregs",
		.desc = "Print VDP register values with a short description",
		.impl = cmd_vdp_regs_sms,
		.min_args = 0,
		.max_args = 0
	}
};

#define NUM_SMS (sizeof(sms_commands)/sizeof(*sms_commands))

#endif

void add_commands(debug_root *root, command_def *defs, uint32_t num_commands)
{
	for (uint32_t i = 0; i < num_commands; i++)
	{
		for (int j = 0; defs[i].names[j]; j++)
		{
			root->commands = tern_insert_ptr(root->commands, defs[i].names[j], defs + i);
		}
	}
}

static void symbol_map(char *key, tern_val val, uint8_t valtype, void *data)
{
	debug_root *root = data;
	label_def *label = val.ptrval;
	for (uint32_t i = 0; i < label->num_labels; i++)
	{
		root->symbols = tern_insert_int(root->symbols, label->labels[i], label->full_address);
	}
}

static debug_val debug_frame_get(debug_var *var)
{
	vdp_context *vdp = var->ptr;
	return debug_int(vdp->frame);
}

static uint32_t m68k_chunk_end(debug_root *root, uint32_t start_address)
{
	m68k_context *m68k = root->cpu_context;
	memmap_chunk const *chunk = find_map_chunk(start_address, &m68k->opts->gen, 0, NULL);
	if (!chunk) {
		return start_address;
	}
	if (chunk->mask == m68k->opts->gen.address_mask) {
		return chunk->end;
	}
	return (start_address & ~chunk->mask) + chunk->mask + 1;
}

debug_root *find_m68k_root(m68k_context *context)
{
	debug_root *root = find_root(context);
	if (root && !root->commands) {
		add_commands(root, common_commands, NUM_COMMON);
		add_commands(root, m68k_commands, NUM_68K);
		root->read_mem = read_m68k;
		root->write_mem = write_m68k;
		root->chunk_end = m68k_chunk_end;
		root->disasm = create_68000_disasm();
		m68k_names(root);
		debug_var *var;
		switch (current_system->type)
		{
		case SYSTEM_GENESIS:
		case SYSTEM_SEGACD:
		case SYSTEM_PICO:
		case SYSTEM_COPERA:
		case SYSTEM_32X:
		case SYSTEM_32XCD:
			//check if this is the main CPU
			if (context->system == current_system) {
				genesis_context *gen = context->system;
				if (
					current_system->type == SYSTEM_GENESIS || current_system->type == SYSTEM_SEGACD ||
					current_system->type == SYSTEM_32X || current_system->type == SYSTEM_32XCD
				) {
					root->other_roots = tern_insert_ptr(root->other_roots, "z80", find_z80_root(gen->z80));
					root->other_roots = tern_insert_ptr(root->other_roots, "io", find_io_root(&gen->io, gen));
				}
				root->other_roots = tern_insert_ptr(root->other_roots, "vdp", find_vdp_root(gen->vdp));
				root->other_roots = tern_insert_ptr(root->other_roots, "psg", find_psg_root(gen->psg));
				uint32_t num_commands = NUM_GENESIS;
				if (current_system->type == SYSTEM_PICO || current_system->type == SYSTEM_COPERA) {
					num_commands -= 3;
				} else {
					root->other_roots = tern_insert_ptr(root->other_roots, "ym", find_ym2612_root(gen->ym));
				}
				add_commands(root, genesis_commands, num_commands);
				var = calloc(1, sizeof(debug_var));
				var->get = debug_frame_get;
				var->ptr = gen->vdp;
				root->variables = tern_insert_ptr(root->variables, "frame", var);
				if (current_system->type == SYSTEM_SEGACD || current_system->type == SYSTEM_32XCD) {
					add_segacd_maincpu_labels(root->disasm);
					add_commands(root, scd_main_commands, NUM_SCD_MAIN);
					segacd_context *scd = gen->expansion;
					root->other_roots = tern_insert_ptr(root->other_roots, "sub", find_m68k_root(scd->m68k));
				}
				if (current_system->type == SYSTEM_32X || current_system->type == SYSTEM_32XCD) {
					root->other_roots = tern_insert_ptr(root->other_roots, "mainsh2", find_sh2_root(gen->mars->main));
					root->other_roots = tern_insert_ptr(root->other_roots, "subsh2", find_sh2_root(gen->mars->sub));
					add_commands(root, s32x_68k_commands, NUM_32X_68K);
				}
				break;
			} else {
				add_segacd_subcpu_labels(root->disasm);
				add_commands(root, scd_sub_commands, NUM_SCD_SUB);
				segacd_context *scd = context->system;
				root->other_roots = tern_insert_ptr(root->other_roots, "main", find_m68k_root(scd->genesis->m68k));
			}
		default:
			break;
		}
		tern_foreach(root->disasm->labels, symbol_map, root);
	}
	return root;
}

typedef struct {
	upd_address_ref ref;
	char            mnemonic[6];
} upd_inst;

static uint8_t read_upd_byte(upd78k2_context *upd, uint32_t address)
{
	if (address > 0xFE00 && address < 0xFF00) {
		return upd->iram[address & 0xFF];
	}
	uint32_t tmp = upd->cycles;
	uint8_t ret = read_byte(address, (void **)upd->mem_pointers, &upd->opts->gen, upd);
	upd->cycles = tmp;
	return ret;
}

static uint16_t read_upd_word(upd78k2_context *upd, uint32_t address)
{
	return read_upd_byte(upd, address) | read_upd_byte(upd, address + 1) << 8;
}

static uint8_t upd_debug_fetch(uint16_t address, void *data)
{
	upd78k2_context *upd = data;
	uint32_t tmp = upd->cycles;
	uint8_t ret = read_byte(address, (void **)upd->mem_pointers, &upd->opts->gen, upd);
	upd->cycles = tmp;
	return ret;
}

static uint8_t cmd_breakpoint_upd(debug_root *root, parsed_command *cmd)
{
	uint32_t address;
	if (!debug_cast_int(cmd->args[0].value, &address)) {
		fprintf(stderr, "Argument to breakpoint must be an integer\n");
		return 1;
	}
	upd78k2_insert_breakpoint(root->cpu_context, address, upd_debugger);
	bp_def *new_bp = calloc(1, sizeof(bp_def));
	new_bp->next = root->breakpoints;
	new_bp->address = address;
	new_bp->mask = 0xFFFF;
	new_bp->index = root->bp_index++;
	new_bp->type = BP_TYPE_CPU;
	root->breakpoints = new_bp;
	printf("uPD78K/II Breakpoint %d set at $%X\n", new_bp->index, address);
	return 1;
}

static uint8_t cmd_advance_upd(debug_root *root, parsed_command *cmd)
{
	uint32_t address;
	if (!debug_cast_int(cmd->args[0].value, &address)) {
		fprintf(stderr, "Argument to advance must be an integer\n");
		return 1;
	}
	upd78k2_insert_breakpoint(root->cpu_context, address, upd_debugger);
	return 0;
}

static uint8_t cmd_step_upd(debug_root *root, parsed_command *cmd)
{
	upd_inst *inst = root->inst;
	upd78k2_context *upd = root->cpu_context;
	uint32_t after = root->after;
	if (startswith(inst->mnemonic, "ret")) {
		after = read_upd_word(upd, upd->sp);
	} else if(inst->ref.ref_type == UPD_REF_COND_BRANCH || inst->ref.ref_type == UPD_REF_OP_BRANCH) {
		root->branch_f = after;
		root->branch_t = inst->ref.ref_type == UPD_REF_COND_BRANCH ? inst->ref.address : inst->ref.address2;
		upd78k2_insert_breakpoint(upd, root->branch_t, upd_debugger);
	} else if (inst->ref.ref_type == UPD_REF_CALL_TABLE) {
		after = read_upd_word(upd, inst->ref.address);
	} else if (inst->ref.ref_type >= UPD_REF_BRANCH) {
		after = inst->ref.address;
	}
	upd78k2_insert_breakpoint(upd, after, upd_debugger);
	return 0;
}

static uint8_t cmd_over_upd(debug_root *root, parsed_command *cmd)
{
	upd_inst *inst = root->inst;
	upd78k2_context *upd = root->cpu_context;
	uint32_t after = root->after;
	if (startswith(inst->mnemonic, "ret")) {
		after = read_upd_word(upd, upd->sp);
	} else if(inst->ref.ref_type == UPD_REF_COND_BRANCH || inst->ref.ref_type == UPD_REF_OP_BRANCH) {
		root->branch_t = inst->ref.ref_type == UPD_REF_COND_BRANCH ? inst->ref.address : inst->ref.address2;
		if (root->branch_t < after) {
			//backwards branch, ignore
			root->branch_t = 0;
		} else {
			root->branch_f = after;
			upd78k2_insert_breakpoint(upd, root->branch_t, upd_debugger);
		}
	} else if (inst->ref.ref_type == UPD_REF_CALL_TABLE || inst->ref.ref_type == UPD_REF_CALL) {
		//don't step into subroutines
	} else if (inst->ref.ref_type >= UPD_REF_BRANCH) {
		after = inst->ref.address;
	}
	upd78k2_insert_breakpoint(upd, after, upd_debugger);
	return 0;
}

static uint8_t cmd_next_upd(debug_root *root, parsed_command *cmd)
{
	upd_inst *inst = root->inst;
	upd78k2_context *upd = root->cpu_context;
	uint32_t after = root->after;
	if (startswith(inst->mnemonic, "ret")) {
		after = read_upd_word(upd, upd->sp);
	} else if(inst->ref.ref_type == UPD_REF_COND_BRANCH || inst->ref.ref_type == UPD_REF_OP_BRANCH) {
		root->branch_f = after;
		root->branch_t = inst->ref.ref_type == UPD_REF_COND_BRANCH ? inst->ref.address : inst->ref.address2;
		upd78k2_insert_breakpoint(upd, root->branch_t, upd_debugger);
	} else if (inst->ref.ref_type == UPD_REF_CALL_TABLE || inst->ref.ref_type == UPD_REF_CALL) {
		//don't step into subroutines
	} else if (inst->ref.ref_type >= UPD_REF_BRANCH) {
		after = inst->ref.address;
	}
	upd78k2_insert_breakpoint(upd, after, upd_debugger);
	return 0;
}

static uint8_t cmd_delete_upd(debug_root *root, parsed_command *cmd)
{
	uint32_t index;
	if (!debug_cast_int(cmd->args[0].value, &index)) {
		fprintf(stderr, "Argument to delete must be an integer\n");
		return 1;
	}
	bp_def **this_bp = find_breakpoint_idx(&root->breakpoints, index);
	if (!*this_bp) {
		fprintf(stderr, "Breakpoint %d does not exist\n", index);
		return 1;
	}
	bp_def *tmp = *this_bp;
	if (tmp->type == BP_TYPE_CPU) {
		upd78k2_remove_breakpoint(root->cpu_context, tmp->address);
	} else if (tmp->type == BP_TYPE_CPU_WATCH) {
		//TODO: implement watchpoints for uPD78K/II
		//upd_remove_watchpoint(root->cpu_context, tmp->address, tmp->mask);
	}
	*this_bp = (*this_bp)->next;
	if (tmp->commands) {
		for (uint32_t i = 0; i < tmp->num_commands; i++)
		{
			free_parsed_command(tmp->commands + i);
		}
		free(tmp->commands);
	}
	free(tmp);
	return 1;
}

static uint8_t cmd_disassemble_upd(debug_root *root, parsed_command *cmd)
{
	upd78k2_context *upd = root->cpu_context;
	uint32_t address = root->address;
	if (cmd->num_args) {
		if (!debug_cast_int(cmd->args[0].value, &address)) {
			fprintf(stderr, "Argument to disassemble must be an integer if provided\n");
			return 1;
		}
	}
	char disasm_buf[1024];
	upd_address_ref ref;
	do {
		label_def *def = find_label(root->disasm, address);
		if (def) {
			for (uint32_t i = 0; i < def->num_labels; i++)
			{
				printf("%s:\n", def->labels[i]);
			}
		}
		uint16_t after = upd78k2_disasm(disasm_buf, &ref, address, upd_debug_fetch, upd, root->disasm);
		printf("\t%s\n", disasm_buf);
		address = after;
	} while(!startswith(disasm_buf, "ret") && strcmp(disasm_buf, "invalid"));
	return 1;
}

command_def upd_commands[] = {
	{
		.names = (const char *[]){
			"breakpoint", "b", NULL
		},
		.usage = "breakpoint ADDRESSS",
		.desc = "Set a breakpoint at ADDRESS",
		.impl = cmd_breakpoint_upd,
		.min_args = 1,
		.max_args = 1
	},
	/*{
		.names = (const char *[]){
			"watchpoint", NULL
		},
		.usage = "watchpoint ADDRESS [SIZE]",
		.desc = "Set a watchpoint at ADDRESS with an optional SIZE in bytes. SIZE defaults to 2 for even address and 1 for odd",
		.impl = cmd_watchpoint_upd,
		.min_args = 1,
		.max_args = 2
	},*/
	{
		.names = (const char *[]){
			"advance", NULL
		},
		.usage = "advance ADDRESS",
		.desc = "Advance to ADDRESS",
		.impl = cmd_advance_upd,
		.min_args = 1,
		.max_args = 1
	},
	{
		.names = (const char *[]){
			"step", "s", NULL
		},
		.usage = "step",
		.desc = "Advance to the next instruction, stepping into subroutines",
		.impl = cmd_step_upd,
		.min_args = 0,
		.max_args = 0
	},
	{
		.names = (const char *[]){
			"over", NULL
		},
		.usage = "over",
		.desc = "Advance to the next instruction, ignoring branches to lower addresses",
		.impl = cmd_over_upd,
		.min_args = 0,
		.max_args = 0
	},
	{
		.names = (const char *[]){
			"next", NULL
		},
		.usage = "next",
		.desc = "Advance to the next instruction",
		.impl = cmd_next_upd,
		.min_args = 0,
		.max_args = 0
	},
	/*{
		.names = (const char *[]){
			"backtrace", "bt", NULL
		},
		.usage = "backtrace",
		.desc = "Print a backtrace",
		.impl = cmd_backtrace_upd,
		.min_args = 0,
		.max_args = 0
	},*/
	{
		.names = (const char *[]){
			"delete", "d", NULL
		},
		.usage = "delete BREAKPOINT",
		.desc = "Remove breakpoint identified by BREAKPOINT",
		.impl = cmd_delete_upd,
		.min_args = 1,
		.max_args = 1
	},
	{
		.names = (const char *[]){
			"disassemble", "disasm", NULL
		},
		.usage = "disassemble [ADDRESS]",
		.desc = "Disassemble code starting at ADDRESS if provided or the current address if not",
		.impl = cmd_disassemble_upd,
		.min_args = 0,
		.max_args = 1
	}
};

#define NUM_UPD (sizeof(upd_commands)/sizeof(*upd_commands))

static uint8_t read_upd(debug_root *root, uint32_t *out, char size)
{
	upd78k2_context *upd = root->cpu_context;
	uint32_t address = *out;
	*out = read_upd_byte(upd, address);
	if (size != 'b') {
		*out |= read_upd_byte(upd, address + 1) << 8;
		if (size == 'l') {
			*out |= read_upd_word(upd, address + 2) << 16;
		}
	}
	return 1;
}

static void write_upd_byte(upd78k2_context *upd, uint32_t address, uint8_t value)
{
	if (address > 0xFE00 && address < 0xFF00) {
		upd->iram[address & 0xFF] = value;
	} else {
		write_byte(address, value, (void **)upd->mem_pointers, &upd->opts->gen, upd);
	}
}

static uint8_t write_upd(debug_root *root, uint32_t address, uint32_t value, char size)
{
	upd78k2_context *upd = root->cpu_context;
	write_upd_byte(upd, address, value);
	if (size != 'b') {
		write_upd_byte(upd, address + 1, value >> 8);
		if (size == 'l') {
			write_upd_byte(upd, address + 2, value >> 16);
			write_upd_byte(upd, address + 3, value >> 24);
		}
	}
	return 1;
}

static uint32_t upd_chunk_end(debug_root *root, uint32_t start_address)
{
	upd78k2_context *upd = root->cpu_context;
	memmap_chunk const *chunk = find_map_chunk(start_address, &upd->opts->gen, 0, NULL);
	if (!chunk) {
		return start_address;
	}
	if (chunk->mask == upd->opts->gen.address_mask) {
		return chunk->end;
	}
	return (start_address & ~chunk->mask) + chunk->mask + 1;
}

static debug_val upd_reg_get(debug_var *var)
{
	upd78k2_context *upd = var->ptr;
	return debug_int(upd->main[var->val.v.u32]);
}

static void upd_reg_set(debug_var *var, debug_val val)
{
	upd78k2_context *upd = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		static const char regs[] = "xacbedlh";
		fprintf(stderr, "uPD78K/II register %c can only be set to an integer\n", regs[var->val.v.u32]);
		return;
	}
	upd->main[var->val.v.u32] = ival;
}

static debug_val upd_regpair_get(debug_var *var)
{
	upd78k2_context *upd = var->ptr;
	uint16_t val = upd->main[var->val.v.u32 * 2];
	val |= upd->main[var->val.v.u32 * 2 + 1] << 8;
	return debug_int(val);
}

static void upd_regpair_set(debug_var *var, debug_val val)
{
	upd78k2_context *upd = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		static const char regs[] = "xacbedlh";
		fprintf(stderr, "uPD78K/II register %c can only be set to an integer\n", regs[var->val.v.u32]);
		return;
	}
	upd->main[var->val.v.u32 * 2] = ival;
	upd->main[var->val.v.u32 * 2 + 1] = ival >> 8;
}

static debug_val word_ptr_get(debug_var *var)
{
	uint16_t *word = var->ptr;
	return debug_int(*word);
}

static void word_ptr_set(debug_var *var, debug_val val)
{
	static const char *names[] = {
		"uPD78K/II register pc",
		"uPD78K/II register sp",
		"uPD78K/II register cr00",
		"uPD78K/II register cr01",
		"uPD78K/II register if0",
		"uPD78K/II register mk0",
		"uPD78K/II register pr0",
		"uPD78K/II register ism0",
	};
	uint16_t *word = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		static const char regs[] = "xacbedlh";
		fprintf(stderr, "%s can only be set to an integer\n", names[var->val.v.u32]);
		return;
	}
	*word = ival;
}

static debug_val upd_cycle_get(debug_var *var)
{
	upd78k2_context *upd = var->ptr;
	return debug_int(upd->cycles);
}

debug_root *find_upd_root(upd78k2_context *upd)
{
	debug_root *root = find_root(upd);
	if (root && !root->commands) {
		add_commands(root, common_commands, NUM_COMMON);
		add_commands(root, upd_commands, NUM_UPD);
		root->read_mem = read_upd;
		root->write_mem = write_upd;
		root->chunk_end = upd_chunk_end;
		root->disasm = create_upd78k2_disasm();
		static const char *regs[] = {"x","a","c","b","e","d","l","h"};
		static const char *regpairs[] = {"ax", "bc", "de", "hl"};
		debug_var *var;
		for (int i = 0; i < sizeof(regs)/sizeof(*regs); i++)
		{
			var = calloc(1, sizeof(debug_var));
			var->get = upd_reg_get;
			var->set = upd_reg_set;
			var->ptr = root->cpu_context;
			var->val.v.u32 = i;
			root->variables = tern_insert_ptr(root->variables, regs[i], var);
		}
		for (int i = 0; i < sizeof(regpairs)/sizeof(*regpairs); i++)
		{
			var = calloc(1, sizeof(debug_var));
			var->get = upd_regpair_get;
			var->set = upd_regpair_set;
			var->ptr = root->cpu_context;
			var->val.v.u32 = i;
			root->variables = tern_insert_ptr(root->variables, regpairs[i], var);
		}
		static const char *word_names[] = {
			"pc", "sp", "cr00", "cr01",
			"if0", "mk0", "pr0", "ism0"
		};
		uint16_t *word_ptrs[] = {
			&upd->pc, &upd->sp, &upd->cr00, &upd->cr01,
			&upd->if0, &upd->mk0, &upd->pr0, &upd->ism0
		};
		for (int i = 0; i < sizeof(word_names)/sizeof(*word_names); i++)
		{
			var = calloc(1, sizeof(debug_var));
			var->get = word_ptr_get;
			var->set = word_ptr_set;
			var->ptr = word_ptrs[i];
			var->val.v.u32 = i;
			root->variables = tern_insert_ptr(root->variables, word_names[i], var);
		}
		var = calloc(1, sizeof(debug_var));
		var->get = upd_cycle_get;
		var->ptr = root->cpu_context;
		root->variables = tern_insert_ptr(root->variables, "cycle", var);
	}
	return root;
}

#ifndef NO_Z80
#ifdef NEW_CORE
#define Z80_OPTS opts
#else
#define Z80_OPTS options
#endif

static uint8_t read_z80(debug_root *root, uint32_t *out, char size)
{
	z80_context *context = root->cpu_context;
	uint32_t address = *out;
	*out = read_byte(address, (void **)context->mem_pointers, &context->Z80_OPTS->gen, context);
	if (size == 'w') {
		*out |= read_byte(address + 1, (void **)context->mem_pointers, &context->Z80_OPTS->gen, context) << 8;
	}
	return 1;
}

static uint8_t write_z80(debug_root *root, uint32_t address, uint32_t value, char size)
{
	z80_context *context = root->cpu_context;
	write_byte(address, value, (void **)context->mem_pointers, &context->Z80_OPTS->gen, context);
	if (size == 'w') {
		write_byte(address + 1, value >> 8, (void **)context->mem_pointers, &context->Z80_OPTS->gen, context);
	}
	return 1;
}

#ifndef NEW_CORE
static debug_val z80_reg8_get(debug_var *var)
{
	z80_context *context = var->ptr;
	return debug_int(context->regs[var->val.v.u32]);
}

static void z80_reg8_set(debug_var *var, debug_val val)
{
	z80_context *context = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "Z80 register %s can only be set to an integer\n", z80_regs[var->val.v.u32]);
		return;
	}
	context->regs[var->val.v.u32] = ival;
}


static debug_val z80_alt_reg8_get(debug_var *var)
{
	z80_context *context = var->ptr;
	return debug_int(context->alt_regs[var->val.v.u32]);
}

static void z80_alt_reg8_set(debug_var *var, debug_val val)
{
	z80_context *context = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "Z80 register %s' can only be set to an integer\n", z80_regs[var->val.v.u32]);
		return;
	}
	context->alt_regs[var->val.v.u32] = ival;
}

static debug_val z80_flags_get(debug_var *var)
{
	z80_context *context = var->ptr;
	debug_val ret;
	ret.type = DBG_VAL_U32;
	ret.v.u32 = context->flags[ZF_S] << 7;
	ret.v.u32 |= context->flags[ZF_Z] << 6;
	ret.v.u32 |= context->flags[ZF_H] << 4;
	ret.v.u32 |= context->flags[ZF_PV] << 2;
	ret.v.u32 |= context->flags[ZF_N] << 1;
	ret.v.u32 |= context->flags[ZF_C];
	return ret;
}

static debug_val z80_alt_flags_get(debug_var *var)
{
	z80_context *context = var->ptr;
	debug_val ret;
	ret.type = DBG_VAL_U32;
	ret.v.u32 = context->alt_flags[ZF_S] << 7;
	ret.v.u32 |= context->alt_flags[ZF_Z] << 6;
	ret.v.u32 |= context->alt_flags[ZF_H] << 4;
	ret.v.u32 |= context->alt_flags[ZF_PV] << 2;
	ret.v.u32 |= context->alt_flags[ZF_N] << 1;
	ret.v.u32 |= context->alt_flags[ZF_C];
	return ret;
}

static void z80_flags_set(debug_var *var, debug_val val)
{
	z80_context *context = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "Z80 register F can only be set to an integer\n");
		return;
	}
	context->flags[ZF_S] = ival >> 7 & 1;
	context->flags[ZF_Z] = ival >> 6 & 1;
	context->flags[ZF_H] = ival >> 4 & 1;
	context->flags[ZF_PV] = ival >> 2 & 1;
	context->flags[ZF_N] = ival >> 1 & 1;
	context->flags[ZF_C] = ival & 1;
}

static void z80_alt_flags_set(debug_var *var, debug_val val)
{
	z80_context *context = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "Z80 register F' can only be set to an integer\n");
		return;
	}
	context->alt_flags[ZF_S] = ival >> 7 & 1;
	context->alt_flags[ZF_Z] = ival >> 6 & 1;
	context->alt_flags[ZF_H] = ival >> 4 & 1;
	context->alt_flags[ZF_PV] = ival >> 2 & 1;
	context->alt_flags[ZF_N] = ival >> 1 & 1;
	context->alt_flags[ZF_C] = ival & 1;
}

static debug_val z80_regpair_get(debug_var *var)
{
	z80_context *context = var->ptr;
	debug_val ret;
	if (var->val.v.u32 == Z80_AF) {
		ret = z80_flags_get(var);
		ret.v.u32 |= context->regs[Z80_A] << 8;
	} else {
		ret = debug_int(context->regs[z80_high_reg(var->val.v.u32)] << 8 | context->regs[z80_low_reg(var->val.v.u32)]);
	}
	return ret;
}

static void z80_regpair_set(debug_var *var, debug_val val)
{
	z80_context *context = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "Z80 register %s can only be set to an integer\n", z80_regs[var->val.v.u32]);
		return;
	}
	if (var->val.v.u32 == Z80_AF) {
		context->regs[Z80_A] = ival >> 8;
		z80_flags_set(var, val);
	} else {
		context->regs[z80_high_reg(var->val.v.u32)] = ival >> 8;
		context->regs[z80_low_reg(var->val.v.u32)] = ival;
	}
}

static debug_val z80_alt_regpair_get(debug_var *var)
{
	z80_context *context = var->ptr;
	debug_val ret;
	if (var->val.v.u32 == Z80_AF) {
		ret = z80_alt_flags_get(var);
		ret.v.u32 |= context->alt_regs[Z80_A] << 8;
	} else {
		ret = debug_int(context->alt_regs[z80_high_reg(var->val.v.u32)] << 8 | context->alt_regs[z80_low_reg(var->val.v.u32)]);
	}
	return ret;
}

static void z80_alt_regpair_set(debug_var *var, debug_val val)
{
	z80_context *context = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "Z80 register %s' can only be set to an integer\n", z80_regs[var->val.v.u32]);
		return;
	}
	if (var->val.v.u32 == Z80_AF) {
		context->regs[Z80_A] = ival >> 8;
		z80_alt_flags_set(var, val);
	} else {
		context->alt_regs[z80_high_reg(var->val.v.u32)] = ival >> 8;
		context->alt_regs[z80_low_reg(var->val.v.u32)] = ival;
	}
}

static debug_val z80_sp_get(debug_var *var)
{
	z80_context *context = var->ptr;
	return debug_int(context->sp);
}

static void z80_sp_set(debug_var *var, debug_val val)
{
	z80_context *context = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "Z80 register sp can only be set to an integer\n");
		return;
	}
	context->sp = ival;
}

static debug_val z80_im_get(debug_var *var)
{
	z80_context *context = var->ptr;
	return debug_int(context->im);
}

static void z80_im_set(debug_var *var, debug_val val)
{
	z80_context *context = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		fprintf(stderr, "Z80 register im can only be set to an integer\n");
		return;
	}
	context->im = ival & 3;
}

static debug_val z80_iff1_get(debug_var *var)
{
	z80_context *context = var->ptr;
	return debug_int(context->iff1);
}

static void z80_iff1_set(debug_var *var, debug_val val)
{
	z80_context *context = var->ptr;
	context->iff1 = debug_cast_bool(val);
}

static debug_val z80_iff2_get(debug_var *var)
{
	z80_context *context = var->ptr;
	return debug_int(context->iff2);
}

static void z80_iff2_set(debug_var *var, debug_val val)
{
	z80_context *context = var->ptr;
	context->iff2 = debug_cast_bool(val);
}

static debug_val z80_cycle_get(debug_var *var)
{
	z80_context *context = var->ptr;
	return debug_int(context->current_cycle);
}

static debug_val z80_pc_get(debug_var *var)
{
	z80_context *context = var->ptr;
	return debug_int(context->pc);
}

static void z80_names(debug_root *root)
{
	debug_var *var;
	for (int i = 0; i < Z80_UNUSED; i++)
	{
		var = calloc(1, sizeof(debug_var));
		var->ptr = root->cpu_context;
		if (i < Z80_BC) {
			var->get = z80_reg8_get;
			var->set = z80_reg8_set;
		} else if (i == Z80_SP) {
			var->get = z80_sp_get;
			var->set = z80_sp_set;
		} else {
			var->get = z80_regpair_get;
			var->set = z80_regpair_set;
		}
		var->val.v.u32 = i;
		root->variables = tern_insert_ptr(root->variables, z80_regs[i], var);
		size_t name_size = strlen(z80_regs[i]);
		char *name = malloc(name_size + 2);
		char *d = name;
		for (const char *c = z80_regs[i]; *c; c++, d++)
		{
			*d = toupper(*c);
		}
		name[name_size] = 0;
		root->variables = tern_insert_ptr(root->variables, name, var);

		if (i < Z80_IXL || (i > Z80_R && i < Z80_IX && i != Z80_SP)) {
			memcpy(name, z80_regs[i], name_size);
			name[name_size] = '\'';
			name[name_size + 1] = 0;
			var = calloc(1, sizeof(debug_var));
			var->ptr = root->cpu_context;
			if (i < Z80_BC) {
				var->get = z80_alt_reg8_get;
				var->set = z80_alt_reg8_set;
			} else {
				var->get = z80_alt_regpair_get;
				var->set = z80_alt_regpair_set;
			}
			var->val.v.u32 = i;
			root->variables = tern_insert_ptr(root->variables, name, var);
			d = name;
			for (const char *c = z80_regs[i]; *c; c++, d++)
			{
				*d = toupper(*c);
			}
			root->variables = tern_insert_ptr(root->variables, name, var);
		}
		free(name);
	}
	var = calloc(1, sizeof(debug_var));
	var->ptr = root->cpu_context;
	var->get = z80_flags_get;
	var->set = z80_flags_set;
	root->variables = tern_insert_ptr(root->variables, "f", var);
	root->variables = tern_insert_ptr(root->variables, "F", var);
	var = calloc(1, sizeof(debug_var));
	var->ptr = root->cpu_context;
	var->get = z80_alt_flags_get;
	var->set = z80_alt_flags_set;
	root->variables = tern_insert_ptr(root->variables, "f'", var);
	root->variables = tern_insert_ptr(root->variables, "F'", var);
	var = calloc(1, sizeof(debug_var));
	var->ptr = root->cpu_context;
	var->get = z80_im_get;
	var->set = z80_im_set;
	root->variables = tern_insert_ptr(root->variables, "im", var);
	root->variables = tern_insert_ptr(root->variables, "IM", var);
	var = calloc(1, sizeof(debug_var));
	var->ptr = root->cpu_context;
	var->get = z80_iff1_get;
	var->set = z80_iff1_set;
	root->variables = tern_insert_ptr(root->variables, "iff1", var);
	var = calloc(1, sizeof(debug_var));
	var->ptr = root->cpu_context;
	var->get = z80_iff2_get;
	var->set = z80_iff2_set;
	root->variables = tern_insert_ptr(root->variables, "iff2", var);
	var = calloc(1, sizeof(debug_var));
	var->ptr = root->cpu_context;
	var->get = z80_cycle_get;
	root->variables = tern_insert_ptr(root->variables, "cycle", var);
	var = calloc(1, sizeof(debug_var));
	var->ptr = root->cpu_context;
	var->get = z80_pc_get;
	root->variables = tern_insert_ptr(root->variables, "pc", var);
	root->variables = tern_insert_ptr(root->variables, "PC", var);
}
#endif //NEW_CORE

static uint32_t z80_chunk_end(debug_root *root, uint32_t start_address)
{
	z80_context *z80 = root->cpu_context;
	memmap_chunk const *chunk = find_map_chunk(start_address, &z80->Z80_OPTS->gen, 0, NULL);
	if (!chunk) {
		return start_address;
	}
	if (chunk->mask == z80->Z80_OPTS->gen.address_mask) {
		return chunk->end;
	}
	return (start_address & ~chunk->mask) + chunk->mask + 1;
}

debug_root *find_z80_root(z80_context *context)
{
	debug_root *root = find_root(context);
	if (root && !root->commands) {
		add_commands(root, common_commands, NUM_COMMON);
		add_commands(root, z80_commands, NUM_Z80);
#ifndef NEW_CORE
		z80_names(root);
#endif
		genesis_context *gen;
		sms_context *sms;
		coleco_context *coleco;
		debug_var *var;
		switch (current_system->type)
		{
		case SYSTEM_GENESIS:
		case SYSTEM_SEGACD:
		case SYSTEM_32X:
		case SYSTEM_32XCD:
			gen = context->system;
			add_commands(root, gen_z80_commands, NUM_GEN_Z80);
			root->other_roots = tern_insert_ptr(root->other_roots, "m68k", find_m68k_root(gen->m68k));
			root->other_roots = tern_insert_ptr(root->other_roots, "io", find_io_root(&gen->io, gen));
			root->other_roots = tern_insert_ptr(root->other_roots, "vdp", find_vdp_root(gen->vdp));
			root->other_roots = tern_insert_ptr(root->other_roots, "psg", find_psg_root(gen->psg));
			root->other_roots = tern_insert_ptr(root->other_roots, "ym", find_ym2612_root(gen->ym));
			var = calloc(1, sizeof(debug_var));
			var->get = debug_frame_get;
			var->ptr = gen->vdp;
			root->variables = tern_insert_ptr(root->variables, "frame", var);
			break;
		case SYSTEM_SMS:
			sms = context->system;
			add_commands(root, sms_commands, NUM_SMS);
			root->other_roots = tern_insert_ptr(root->other_roots, "vdp", find_vdp_root(sms->vdp));
			root->other_roots = tern_insert_ptr(root->other_roots, "psg", find_psg_root(sms->psg));
			root->other_roots = tern_insert_ptr(root->other_roots, "io", find_io_root(&gen->io, NULL));
			var = calloc(1, sizeof(debug_var));
			var->get = debug_frame_get;
			var->ptr = sms->vdp;
			root->variables = tern_insert_ptr(root->variables, "frame", var);
			break;
		case SYSTEM_COLECOVISION:
			coleco = context->system;
			root->other_roots = tern_insert_ptr(root->other_roots, "vdp", find_vdp_root(coleco->vdp));
			root->other_roots = tern_insert_ptr(root->other_roots, "psg", find_psg_root(coleco->psg));
			break;
		}
		root->read_mem = read_z80;
		root->write_mem = write_z80;
		root->disasm = create_z80_disasm();
		root->chunk_end = z80_chunk_end;
	}
	return root;
}

static uint8_t cmd_breakpoint_sh2(debug_root *root, parsed_command *cmd)
{
	uint32_t address;
	if (!debug_cast_int(cmd->args[0].value, &address)) {
		fprintf(stderr, "Argument to breakpoint must be an integer\n");
		return 1;
	}
	sh2_insert_breakpoint(root->cpu_context, address, sh2_debugger);
	bp_def *new_bp = calloc(1, sizeof(bp_def));
	new_bp->next = root->breakpoints;
	new_bp->address = address;
	if (address < 0x28000000) {
		new_bp->mask = 0x7FFFFFF;
	} else {
		new_bp->mask = 0xFFFFFFFF;
	}
	new_bp->index = root->bp_index++;
	new_bp->type = BP_TYPE_CPU;
	root->breakpoints = new_bp;
	printf("SH2 Breakpoint %d set at $%X\n", new_bp->index, address);
	return 1;
}

static uint8_t cmd_advance_sh2(debug_root *root, parsed_command *cmd)
{
	uint32_t address;
	if (!debug_cast_int(cmd->args[0].value, &address)) {
		fprintf(stderr, "Argument to advance must be an integer\n");
		return 1;
	}
	sh2_insert_breakpoint(root->cpu_context, address, sh2_debugger);
	return 0;
}

static uint8_t cmd_step_sh2(debug_root *root, parsed_command *cmd)
{
	sh2_inst *inst = root->inst;
	sh2_context *sh2 = root->cpu_context;
	uint32_t after = root->after;
	switch (inst->opcode)
	{
	case SH2_BF:
	case SH2_BFS:
		if (!sh2->t) {
			after += 2 + inst->immed;
		}
		break;
	case SH2_BT:
	case SH2_BTS:
		if (sh2->t) {
			after += 2 + inst->immed;
		}
		break;
	case SH2_BRA:
	case SH2_BSR:
		after += 2 + inst->immed;
		break;
	case SH2_BRAF:
	case SH2_BSRF:
		after += 2 + sh2->gpr[inst->src - SH2_IND_R0];
		break;
	case SH2_JMP:
	case SH2_JSR:
		after = sh2->gpr[inst->src - SH2_IND_R0];
		break;
	case SH2_RTS:
		after = sh2->pr;
		break;
	//TODO: SH2_RTE
	}
	sh2_insert_breakpoint(sh2, after, sh2_debugger);
	return 0;
}

static uint8_t cmd_next_sh2(debug_root *root, parsed_command *cmd)
{
	sh2_inst *inst = root->inst;
	sh2_context *sh2 = root->cpu_context;
	uint32_t after = root->after;
	switch (inst->opcode)
	{
	case SH2_BF:
	case SH2_BFS:
		if (!sh2->t) {
			after += 2 + inst->immed;
		}
		break;
	case SH2_BT:
	case SH2_BTS:
		if (sh2->t) {
			after += 2 + inst->immed;
		}
		break;
	case SH2_BRA:
		after += 2 + inst->immed;
		break;
	case SH2_BSR:
	case SH2_JSR:
	case SH2_BSRF:
		after += 2; //skip over delay slot for now
		break;
	case SH2_BRAF:
		after += 2 + sh2->gpr[inst->src - SH2_IND_R0];
		break;
	case SH2_JMP:
		after = sh2->gpr[inst->src - SH2_IND_R0];
		break;
	case SH2_RTS:
		after = sh2->pr;
		break;
	//TODO: SH2_RTE
	}
	sh2_insert_breakpoint(sh2, after, sh2_debugger);
	return 0;
}

static uint8_t cmd_over_sh2(debug_root *root, parsed_command *cmd)
{
	sh2_inst *inst = root->inst;
	sh2_context *sh2 = root->cpu_context;
	uint32_t after = root->after;
	switch (inst->opcode)
	{
	case SH2_BF:
		if (!sh2->t && inst->immed >= -2) {
			after += 2 + inst->immed;
		}
		break;
	case SH2_BFS:
		if (!sh2->t) {
			if (inst->immed >= -2) {
				after += 2 + inst->immed;
			} else {
				//skip over delay slot for now
				after += 2;
			}
		}
		break;
	case SH2_BT:
		if (sh2->t && inst->immed >= -2) {
			after += 2 + inst->immed;
		}
		break;
	case SH2_BTS:
		if (sh2->t) {
			if (inst->immed >= -2) {
				after += 2 + inst->immed;
			} else {
				//skip over delay slot for now
				after += 2;
			}
		}
		break;
	case SH2_BRA:
		after += 2 + inst->immed;
		break;
	case SH2_BSR:
	case SH2_JSR:
	case SH2_BSRF:
		after += 2; //skip over delay slot for now
		break;
	case SH2_BRAF:
		after += 2 + sh2->gpr[inst->src = SH2_IND_R0];
		break;
	case SH2_JMP:
		after = sh2->gpr[inst->src = SH2_IND_R0];
		break;
	case SH2_RTS:
		after = sh2->pr;
		break;
	//TODO: SH2_RTE
	}
	sh2_insert_breakpoint(sh2, after, sh2_debugger);
	return 0;
}

static uint8_t cmd_delete_sh2(debug_root *root, parsed_command *cmd)
{
	uint32_t index;
	if (!debug_cast_int(cmd->args[0].value, &index)) {
		fprintf(stderr, "Argument to delete must be an integer\n");
		return 1;
	}
	bp_def **this_bp = find_breakpoint_idx(&root->breakpoints, index);
	if (!*this_bp) {
		fprintf(stderr, "Breakpoint %d does not exist\n", index);
		return 1;
	}
	bp_def *tmp = *this_bp;
	if (tmp->type == BP_TYPE_CPU) {
		sh2_remove_breakpoint(root->cpu_context, tmp->address);
	} else if (tmp->type == BP_TYPE_CPU_WATCH) {
		//TODO: implement watchpoints for SH2
		//sh2_remove_watchpoint(root->cpu_context, tmp->address, tmp->mask);
	}
	*this_bp = (*this_bp)->next;
	if (tmp->commands) {
		for (uint32_t i = 0; i < tmp->num_commands; i++)
		{
			free_parsed_command(tmp->commands + i);
		}
		free(tmp->commands);
	}
	free(tmp);
	return 1;
}

command_def sh2_commands[] = {
	{
		.names = (const char *[]){
			"breakpoint", "b", NULL
		},
		.usage = "breakpoint ADDRESSS",
		.desc = "Set a breakpoint at ADDRESS",
		.impl = cmd_breakpoint_sh2,
		.min_args = 1,
		.max_args = 1
	},
	/*{
		.names = (const char *[]){
			"watchpoint", NULL
		},
		.usage = "watchpoint ADDRESS [SIZE]",
		.desc = "Set a watchpoint at ADDRESS with an optional SIZE in bytes. SIZE defaults to 1",
		.impl = cmd_watchpoint_sh2,
		.min_args = 1,
		.max_args = 2
	},*/
	{
		.names = (const char *[]){
			"advance", NULL
		},
		.usage = "advance ADDRESS",
		.desc = "Advance to ADDRESS",
		.impl = cmd_advance_sh2,
		.min_args = 1,
		.max_args = 1
	},
	{
		.names = (const char *[]){
			"step", "s", NULL
		},
		.usage = "step",
		.desc = "Advance to the next instruction, stepping into subroutines",
		.impl = cmd_step_sh2,
		.min_args = 0,
		.max_args = 0
	},
	{
		.names = (const char *[]){
			"over", NULL
		},
		.usage = "over",
		.desc = "Advance to the next instruction, ignoring branches to lower addresses",
		.impl = cmd_over_sh2,
		.min_args = 0,
		.max_args = 0
	},
	{
		.names = (const char *[]){
			"next", NULL
		},
		.usage = "next",
		.desc = "Advance to the next instruction",
		.impl = cmd_next_sh2,
		.min_args = 0,
		.max_args = 0
	},/*
	{
		.names = (const char *[]){
			"backtrace", "bt", NULL
		},
		.usage = "backtrace",
		.desc = "Print a backtrace",
		.impl = cmd_backtrace_sh2,
		.min_args = 0,
		.max_args = 0
	},*/
	{
		.names = (const char *[]){
			"delete", "d", NULL
		},
		.usage = "delete BREAKPOINT",
		.desc = "Remove breakpoint identified by BREAKPOINT",
		.impl = cmd_delete_sh2,
		.min_args = 1,
		.max_args = 1
	}/*,
	{
		.names = (const char *[]){
			"disassemble", "disasm", NULL
		},
		.usage = "disassemble [ADDRESS]",
		.desc = "Disassemble code starting at ADDRESS if provided or the current address if not",
		.impl = cmd_disassemble_sh2,
		.min_args = 0,
		.max_args = 1
	}*/,
	{
		.names = (const char *[]){
			"m68k", NULL
		},
		.usage = "m68k [COMMAND]",
		.desc = "Run a M68K debugger command or switch to M68K context when no command is given",
		.impl = cmd_gen_m68k,
		.min_args = 0,
		.max_args = -1,
		.raw_args = 1
	}
};

#define NUM_SH2 (sizeof(sh2_commands)/sizeof(*sh2_commands))

static uint8_t read_sh2(debug_root *root, uint32_t *out, char size)
{
	sh2_context *sh2 = root->cpu_context;
	uint32_t address = *out;
	switch (size)
	{
	case 'b':
		*out = sh2->read8[address >> 29](address, sh2);
		break;
	case 'w':
		*out = sh2->read16[address >> 29](address, sh2);
		break;
	case 'l':
		*out = sh2->read32[address >> 29](address, sh2);
		break;
	}
	return 1;
}

static uint8_t write_sh2(debug_root *root, uint32_t address, uint32_t value, char size)
{
	sh2_context *sh2 = root->cpu_context;
	switch (size)
	{
	case 'b':
		sh2->write8[address >> 29](address, sh2, value);
		break;
	case 'w':
		sh2->write16[address >> 29](address, sh2, value);
		break;
	case 'l':
		sh2->write32[address >> 29](address, sh2, value);
		break;
	}
	return 1;
}

static uint32_t sh2_chunk_end(debug_root *root, uint32_t start_address)
{
	sh2_context *sh2 = root->cpu_context;
	memmap_chunk const *chunk = find_map_chunk(start_address, &sh2->opts->gen, 0, NULL);
	if (!chunk) {
		return start_address;
	}
	if (chunk->mask == sh2->opts->gen.address_mask) {
		return chunk->end;
	}
	return (start_address & ~chunk->mask) + chunk->mask + 1;
}

static debug_val sh2_reg_get(debug_var *var)
{
	sh2_context *sh2 = var->ptr;
	uint32_t val;
	if (var->val.v.u32 < 16) {
		val = sh2->gpr[var->val.v.u32];
	} else {
		switch(var->val.v.u32)
		{
		//TODO: flags
		case 16:
			sh2_collect_sr(sh2);
			val = sh2->sr; 
			break;
		case 17: val = sh2->gbr; break;
		case 18: val = sh2->vbr; break;
		case 19: val = sh2->mach; break;
		case 20: val = sh2->macl; break;
		case 21: val = sh2->pr; break;
		case 22: val = sh2->pc; break;
		case 23: val = sh2->cycles; break;
		default: val = 0;
		}
	}
	return debug_int(val);
}

static void sh2_reg_set(debug_var *var, debug_val val)
{
	sh2_context *sh2 = var->ptr;
	uint32_t ival;
	if (!debug_cast_int(val, &ival)) {
		static const char regs[] = "xacbedlh";
		fprintf(stderr, "uPD78K/II register %c can only be set to an integer\n", regs[var->val.v.u32]);
		return;
	}
	if (var->val.v.u32 < 16) {
		sh2->gpr[var->val.v.u32] = ival;
	} else {
		switch(var->val.v.u32)
		{
		case 16:
			sh2->sr = ival;
			sh2_disperse_sr(sh2);
			break;
		case 17: sh2->gbr = ival; break;
		case 18: sh2->vbr = ival; break;
		case 19: sh2->mach = ival; break;
		case 20: sh2->macl = ival; break;
		case 21: sh2->pr = ival; break;
		}
	}
}

debug_root *find_sh2_root(sh2_context *context)
{
	debug_root *root = find_root(context);
	if (root && !root->commands) {
		add_commands(root, common_commands, NUM_COMMON);
		add_commands(root, sh2_commands, NUM_SH2);
		s32x *mars = context->system;
		if (mars->main == context) {
			add_commands(root, s32x_68k_commands + 1, 1);
		} else {
			add_commands(root, s32x_68k_commands, 1);
		}
		root->read_mem = read_sh2;
		root->write_mem = write_sh2;
		root->chunk_end = sh2_chunk_end;
		root->disasm = create_sh2_disasm();
		static const char *regs[] = {
			"r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10", "r11", "r12",
			"r13", "r14", "sp", "sr", "gbr", "vbr", "mach", "macl", "pr", "pc", "cycle"
		};
		static size_t num_regs = sizeof(regs)/sizeof(*regs);
		for (int i = 0; i < num_regs; i++)
		{
			debug_var *var = calloc(1, sizeof(debug_var));
			var->get = sh2_reg_get;
			var->set = sh2_reg_set;
			var->ptr = context;
			var->val.v.u32 = i;
			root->variables = tern_insert_ptr(root->variables, regs[i], var);
		}
	}
	return root;
}

z80_context * zdebugger(z80_context * context, uint16_t address)
{
	static char last_cmd[1024];
	char input_buf[1024];
	z80inst inst;
	genesis_context *system = context->system;
	init_terminal();
	debug_root *root = find_z80_root(context);
	if (!root) {
		return context;
	}
	root->address = address;
	//Check if this is a user set breakpoint, or just a temporary one
	int debugging;
	bp_def ** this_bp = find_breakpoint(&root->breakpoints, address, BP_TYPE_CPU);
	if (*this_bp) {
		if ((*this_bp)->condition) {
			debug_val condres;
			if (eval_expr(root, (*this_bp)->condition, &condres)) {
				if (!condres.v.u32) {
					return context;
				}
			} else {
				fprintf(stderr, "Failed to eval condition for Z80 breakpoint %u\n", (*this_bp)->index);
				free_expr((*this_bp)->condition);
				(*this_bp)->condition = NULL;
			}
		}
		debugging = 1;
		for (uint32_t i = 0; debugging && i < (*this_bp)->num_commands; i++)
		{
			debugging = run_command(root, (*this_bp)->commands + i);
		}
		if (debugging) {
			printf("Z80 Breakpoint %d hit\n", (*this_bp)->index);
		} else {
			fflush(stdout);
			return context;
		}
	} else {
		zremove_breakpoint(context, address);
	}
#ifndef NEW_CORE
	if (context->wp_hit) {
		context->wp_hit = 0;
		this_bp = find_breakpoint(&root->breakpoints, context->wp_hit_address, BP_TYPE_CPU_WATCH);
		if (*this_bp) {
			if ((*this_bp)->condition) {
				debug_val condres;
				if (eval_expr(root, (*this_bp)->condition, &condres)) {
					if (!condres.v.u32) {
						return context;
					}
				} else {
					fprintf(stderr, "Failed to eval condition for Z80 watchpoint %u\n", (*this_bp)->index);
					free_expr((*this_bp)->condition);
					(*this_bp)->condition = NULL;
				}
			}
			debugging = 1;
			for (uint32_t i = 0; debugging && i < (*this_bp)->num_commands; i++)
			{
				debugging = run_command(root, (*this_bp)->commands + i);
			}
			if (debugging) {
				if (context->wp_old_value != context->wp_hit_value) {
					printf("Z80 Watchpoint %d hit, old value: %X, new value %X\n", (*this_bp)->index, context->wp_old_value, context->wp_hit_value);
				} else {
					printf("Z80 Watchpoint %d hit\n", (*this_bp)->index);
				}
			} else {
				fflush(stdout);
				return context;
			}
		}
	}
#endif
	uint8_t * pc = get_native_pointer(address, (void **)context->mem_pointers, &context->Z80_OPTS->gen);
	if (!pc) {
		fatal_error("Failed to get native pointer on entering Z80 debugger at address %X\n", address);
	}
	uint8_t * after_pc = z80_decode(pc, &inst);
	uint16_t after = address + (after_pc-pc);
	root->after = after;
	root->inst = &inst;
	for (disp_def * cur = root->displays; cur; cur = cur->next) {
		char format_str[8];
		make_format_str(format_str, cur->format);
		for (int i = 0; i < cur->num_args; i++)
		{
			eval_expr(root, cur->args[i].parsed, &cur->args[i].value);
			do_print(root, format_str, cur->args[i].raw, cur->args[i].value);
		}
	}

	z80_disasm(&inst, input_buf, address);
	printf("%X:\t%s\n", address, input_buf);
	debugger_repl(root);
	return context;
}

#endif

void debugger(void *vcontext, uint32_t address)
{
	static char last_cmd[1024];
	char input_buf[1024];
	m68kinst inst;
	m68k_context *context = vcontext;

	init_terminal();

#ifndef NEW_CORE
	context->opts->sync_components(context, 0);
#endif
	debug_root *root = find_m68k_root(context);
	if (!root) {
		return;
	}
	//probably not necessary, but let's play it safe
	address &= 0xFFFFFF;
	if (address == root->branch_t) {
		bp_def ** f_bp = find_breakpoint(&root->breakpoints, root->branch_f, BP_TYPE_CPU);
		if (!*f_bp) {
			remove_breakpoint(context, root->branch_f);
		}
		root->branch_t = root->branch_f = 0;
	} else if(address == root->branch_f) {
		bp_def ** t_bp = find_breakpoint(&root->breakpoints, root->branch_t, BP_TYPE_CPU);
		if (!*t_bp) {
			remove_breakpoint(context, root->branch_t);
		}
		root->branch_t = root->branch_f = 0;
	}

	root->address = address;
	int debugging = 1;
	//Check if this is a user set breakpoint, or just a temporary one
	bp_def ** this_bp = find_breakpoint(&root->breakpoints, address, BP_TYPE_CPU);
	if (*this_bp) {
		if ((*this_bp)->condition) {
			debug_val condres;
			if (eval_expr(root, (*this_bp)->condition, &condres)) {
				if (!condres.v.u32) {
					return;
				}
			} else {
				fprintf(stderr, "Failed to eval condition for M68K breakpoint %u\n", (*this_bp)->index);
				free_expr((*this_bp)->condition);
				(*this_bp)->condition = NULL;
			}
		}
		for (uint32_t i = 0; debugging && i < (*this_bp)->num_commands; i++)
		{
			debugging = run_command(root, (*this_bp)->commands + i);
		}
		if (debugging) {
			printf("68K Breakpoint %d hit\n", (*this_bp)->index);
		} else {
			fflush(stdout);
			return;
		}
	} else {
		remove_breakpoint(context, address);
	}
	if (context->wp_hit) {
		context->wp_hit = 0;
		this_bp = find_breakpoint(&root->breakpoints, context->wp_hit_address, BP_TYPE_CPU_WATCH);
		if (*this_bp) {
			if ((*this_bp)->condition) {
				debug_val condres;
				if (eval_expr(root, (*this_bp)->condition, &condres)) {
					if (!condres.v.u32) {
						return;
					}
				} else {
					fprintf(stderr, "Failed to eval condition for M68K watchpoint %u\n", (*this_bp)->index);
					free_expr((*this_bp)->condition);
					(*this_bp)->condition = NULL;
				}
			}
			for (uint32_t i = 0; debugging && i < (*this_bp)->num_commands; i++)
			{
				debugging = run_command(root, (*this_bp)->commands + i);
			}
			if (debugging) {
				if (context->wp_old_value != context->wp_hit_value) {
					printf("68K Watchpoint %d hit, old value: %X, new value %X\n", (*this_bp)->index, context->wp_old_value, context->wp_hit_value);
				} else {
					printf("68K Watchpoint %d hit\n", (*this_bp)->index);
				}
			} else {
				fflush(stdout);
				return;
			}
		}
	}
	if (context->system == current_system) {
		genesis_context *gen = context->system;
		vdp_force_update_framebuffer(gen->vdp);
	}
	uint32_t after = m68k_decode(m68k_instruction_fetch, context, &inst, address);
	root->after = after;
	root->inst = &inst;
	for (disp_def * cur = root->displays; cur; cur = cur->next) {
		char format_str[8];
		make_format_str(format_str, cur->format);
		for (int i = 0; i < cur->num_args; i++)
		{
			eval_expr(root, cur->args[i].parsed, &cur->args[i].value);
			do_print(root, format_str, cur->args[i].raw, cur->args[i].value);
		}
	}
	m68k_disasm_labels(&inst, input_buf, root->disasm);
	printf("%X: %s\n", address, input_buf);
	debugger_repl(root);
	return;
}

void upd_debugger(upd78k2_context *upd)
{
	static char last_cmd[1024];
	char input_buf[1024];

	init_terminal();

	debug_root *root = find_upd_root(upd);
	if (!root) {
		return;
	}
	if (upd->pc == root->branch_t) {
		bp_def ** f_bp = find_breakpoint(&root->breakpoints, root->branch_f, BP_TYPE_CPU);
		if (!*f_bp) {
			upd78k2_remove_breakpoint(upd, root->branch_f);
		}
		root->branch_t = root->branch_f = 0;
	} else if(upd->pc == root->branch_f) {
		bp_def ** t_bp = find_breakpoint(&root->breakpoints, root->branch_t, BP_TYPE_CPU);
		if (!*t_bp) {
			upd78k2_remove_breakpoint(upd, root->branch_t);
		}
		root->branch_t = root->branch_f = 0;
	}

	root->address = upd->pc;
	int debugging = 1;
	//Check if this is a user set breakpoint, or just a temporary one
	bp_def ** this_bp = find_breakpoint(&root->breakpoints, upd->pc, BP_TYPE_CPU);
	if (*this_bp) {
		if ((*this_bp)->condition) {
			debug_val condres;
			if (eval_expr(root, (*this_bp)->condition, &condres)) {
				if (!condres.v.u32) {
					return;
				}
			} else {
				fprintf(stderr, "Failed to eval condition for uPD78K/II breakpoint %u\n", (*this_bp)->index);
				free_expr((*this_bp)->condition);
				(*this_bp)->condition = NULL;
			}
		}
		for (uint32_t i = 0; debugging && i < (*this_bp)->num_commands; i++)
		{
			debugging = run_command(root, (*this_bp)->commands + i);
		}
		if (debugging) {
			printf("uPD78K/II Breakpoint %d hit\n", (*this_bp)->index);
		} else {
			fflush(stdout);
			return;
		}
	} else {
		upd78k2_remove_breakpoint(upd, root->address);
	}
	upd_inst inst;
	uint16_t after = upd78k2_disasm(input_buf, &inst.ref, upd->pc, upd_debug_fetch, upd, root->disasm);
	int ic;
	for (ic = 0; input_buf[ic] && input_buf[ic] != ' ' && ic < sizeof(inst.mnemonic) - 1; ic++)
	{
		inst.mnemonic[ic] = input_buf[ic];
	}
	inst.mnemonic[ic] = 0;
	root->after = after;
	root->inst = &inst;
	for (disp_def * cur = root->displays; cur; cur = cur->next) {
		char format_str[8];
		make_format_str(format_str, cur->format);
		for (int i = 0; i < cur->num_args; i++)
		{
			eval_expr(root, cur->args[i].parsed, &cur->args[i].value);
			do_print(root, format_str, cur->args[i].raw, cur->args[i].value);
		}
	}
	printf("%X: %s\n", root->address, input_buf);
	debugger_repl(root);
	return;
}

void sh2_debugger(sh2_context *sh2)
{
	static char last_cmd[1024];
	char input_buf[1024];

	init_terminal();

	debug_root *root = find_sh2_root(sh2);
	if (!root) {
		return;
	}
	if (sh2->pc == root->branch_t) {
		bp_def ** f_bp = find_breakpoint(&root->breakpoints, root->branch_f, BP_TYPE_CPU);
		if (!*f_bp) {
			sh2_remove_breakpoint(sh2, root->branch_f);
		}
		root->branch_t = root->branch_f = 0;
	} else if(sh2->pc == root->branch_f) {
		bp_def ** t_bp = find_breakpoint(&root->breakpoints, root->branch_t, BP_TYPE_CPU);
		if (!*t_bp) {
			sh2_remove_breakpoint(sh2, root->branch_t);
		}
		root->branch_t = root->branch_f = 0;
	}

	root->address = sh2->pc;
	int debugging = 1;
	//Check if this is a user set breakpoint, or just a temporary one
	bp_def ** this_bp = find_breakpoint(&root->breakpoints, sh2->pc, BP_TYPE_CPU);
	if (*this_bp) {
		if ((*this_bp)->condition) {
			debug_val condres;
			if (eval_expr(root, (*this_bp)->condition, &condres)) {
				if (!condres.v.u32) {
					return;
				}
			} else {
				fprintf(stderr, "Failed to eval condition for uPD78K/II breakpoint %u\n", (*this_bp)->index);
				free_expr((*this_bp)->condition);
				(*this_bp)->condition = NULL;
			}
		}
		for (uint32_t i = 0; debugging && i < (*this_bp)->num_commands; i++)
		{
			debugging = run_command(root, (*this_bp)->commands + i);
		}
		if (debugging) {
			printf("SH2 Breakpoint %d hit\n", (*this_bp)->index);
		} else {
			fflush(stdout);
			return;
		}
	} else {
		sh2_remove_breakpoint(sh2, root->address);
	}
	sh2_inst inst = sh2_decode(sh2->prefetch_cur);
	sh2_disasm(input_buf, inst, sh2->pc, root->disasm);
	root->after = root->address + 2;
	root->inst = &inst;
	for (disp_def * cur = root->displays; cur; cur = cur->next) {
		char format_str[8];
		make_format_str(format_str, cur->format);
		for (int i = 0; i < cur->num_args; i++)
		{
			eval_expr(root, cur->args[i].parsed, &cur->args[i].value);
			do_print(root, format_str, cur->args[i].raw, cur->args[i].value);
		}
	}
	printf("%X: %s\n", root->address, input_buf);
	debugger_repl(root);
}
