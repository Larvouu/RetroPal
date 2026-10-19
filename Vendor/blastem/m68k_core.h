/*
 Copyright 2013 Michael Pavone
 This file is part of BlastEm.
 BlastEm is free software distributed under the terms of the GNU General Public License version 3 or greater. See COPYING for full license text.
*/
#ifndef M68K_CORE_H_
#define M68K_CORE_H_
#include <stdint.h>
#include <stdio.h>
#include "backend.h"
#include "serialize.h"
//#include "68kinst.h"
typedef struct m68kinst m68kinst;

#define NUM_MEM_AREAS 12
#define NATIVE_MAP_CHUNKS (64*1024)
#define NATIVE_CHUNK_SIZE ((16 * 1024 * 1024 / NATIVE_MAP_CHUNKS))
#define MAX_NATIVE_SIZE 255

#define M68K_OPT_BROKEN_READ_MODIFY 1

#define INT_PENDING_SR_CHANGE 254
#define INT_PENDING_NONE 255

#define M68K_STATUS_TRACE 0x80

typedef void (*start_fun)(uint8_t * addr, void * context);
typedef struct m68k_context m68k_context;
typedef m68k_context *(*sync_fun)(m68k_context * context, uint32_t address);
typedef m68k_context *(*int_ack_fun)(m68k_context * context);

typedef struct {
	code_ptr impl;
	uint16_t reglist;
	uint8_t  reg_to_mem;
	uint8_t  size;
	int8_t   dir;
} movem_fun;

typedef struct {
	cpu_options     gen;

	int8_t          dregs[8];
	int8_t          aregs[9];
	int8_t			flag_regs[5];
	FILE            *address_log;
	code_ptr        read_16;
	code_ptr        write_16;
	code_ptr        read_8;
	code_ptr        write_8;
	code_ptr        read_32;
	code_ptr        write_32_lowfirst;
	code_ptr        write_32_highfirst;
	code_ptr        do_sync;
	code_ptr        handle_int_latch;
	code_ptr        trap;
	start_fun       start_context;
	code_ptr        retrans_stub;
	code_ptr        native_addr;
	code_ptr        native_addr_and_sync;
	code_ptr		get_sr;
	code_ptr		set_sr;
	code_ptr		set_ccr;
	code_ptr        bp_stub;
	code_ptr        save_context_scratch;
	code_ptr        load_context_scratch;
	sync_fun        sync_components;
	int_ack_fun     int_ack;
	code_info       extra_code;
	movem_fun       *big_movem;
	uint32_t        num_movem;
	uint32_t        movem_storage;
	code_word       prologue_start;
} m68k_options;

typedef struct {
	uint32_t start;
	uint32_t end;
	uint8_t  check_change;
} m68k_watchpoint;

#ifdef X86_64
#define M68K_STACK_STORAGE 12
#else
#define M68K_STACK_STORAGE 20
#endif

struct m68k_context {
	uint8_t         flags[5];
	uint8_t         status;
	uint32_t        dregs[8];
	uint32_t        aregs[9];
	uint32_t		target_cycle; //cycle at which the next synchronization or interrupt occurs
	uint32_t		cycles;
	uint32_t        sync_cycle;
	uint32_t        int_cycle;
	uint32_t        int_num;
	uint32_t        last_prefetch_address;
	uint32_t        scratch1;
	uint32_t        scratch2;
	uint16_t        *mem_pointers[NUM_MEM_AREAS];
	code_ptr        resume_pc;
	code_ptr        reset_handler;
	m68k_options    *opts;
	void            *system;
	void            *host_sp_entry;
	void            *stack_storage[M68K_STACK_STORAGE];
	breakpoint      *breakpoints;
	uint32_t        num_breakpoints;
	uint32_t        bp_storage;
	uint32_t        watchpoint_min;
	uint32_t        watchpoint_max;
	m68k_watchpoint *watchpoints;
	uint32_t        num_watchpoints;
	uint32_t        wp_storage;
	uint32_t        wp_hit_address;
	uint16_t        wp_hit_value;
	uint16_t        wp_old_value;
	uint8_t         wp_hit;
	uint8_t         int_pending;
	uint8_t         trace_pending;
	uint8_t         should_return;
	uint8_t         stack_storage_count;
	uint8_t         ram_code_flags[];
};

typedef m68k_context *(*m68k_reset_handler)(m68k_context *context);


void translate_m68k_stream(uint32_t address, m68k_context * context);
void start_68k_context(m68k_context * context, uint32_t address);
void resume_68k(m68k_context *context);
void init_m68k_opts(m68k_options * opts, memmap_chunk * memmap, uint32_t num_chunks, uint32_t clock_divider, sync_fun sync_components, int_ack_fun int_ack);
m68k_context * init_68k_context(m68k_options * opts, m68k_reset_handler reset_handler);
void m68k_reset(m68k_context * context);
void m68k_options_free(m68k_options *opts);
void insert_breakpoint(m68k_context * context, uint32_t address, debug_handler bp_handler);
void remove_breakpoint(m68k_context * context, uint32_t address);
void m68k_add_watchpoint(m68k_context *context, uint32_t address, uint32_t size);
void m68k_remove_watchpoint(m68k_context *context, uint32_t address, uint32_t size);
m68k_context * m68k_handle_code_write(uint32_t address, m68k_context * context);
uint32_t get_instruction_start(m68k_options *opts, uint32_t address);
uint16_t m68k_get_ir(m68k_context *context);
void m68k_print_regs(m68k_context * context);
void m68k_invalidate_code_range(m68k_context *context, uint32_t start, uint32_t end);
void m68k_serialize(m68k_context *context, uint32_t pc, serialize_buffer *buf);
void m68k_deserialize(deserialize_buffer *buf, void *vcontext);
uint16_t m68k_instruction_fetch(uint32_t address, void *vcontext);
uint8_t m68k_is_terminal(m68kinst * inst);

#endif //M68K_CORE_H_

