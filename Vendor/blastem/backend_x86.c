#include "backend.h"
#include "gen_x86.h"
#include <string.h>

void cycles(cpu_options *opts, uint32_t num)
{
	if (opts->cycles < 0) {
		add_irdisp(&opts->code, num*opts->clock_divider, opts->context_reg, opts->cycles_off, SZ_D);
	} else if (opts->limit < 0) {
		sub_ir(&opts->code, num*opts->clock_divider, opts->cycles, SZ_D);
	} else {
		add_ir(&opts->code, num*opts->clock_divider, opts->cycles, SZ_D);
	}
}

void check_cycles_int(cpu_options *opts, uint32_t address)
{
	code_info *code = &opts->code;
	uint8_t cc;
	if (opts->limit < 0) {
		cmp_ir(code, 1, opts->cycles, SZ_D);
		cc = CC_NS;
	} else {
		cmp_rr(code, opts->cycles, opts->limit, SZ_D);
		cc = CC_A;
	}
	code_ptr jmp_off = code->cur+1;
	jcc(code, cc, jmp_off+1);
	mov_ir(code, address, opts->scratch1, SZ_D);
	call(code, opts->handle_cycle_limit_int);
	*jmp_off = code->cur - (jmp_off+1);
}

void retranslate_calc(cpu_options *opts)
{
	code_info *code = &opts->code;
	code_info tmp = *code;
	uint8_t cc;
	if (opts->limit < 0) {
		cmp_ir(code, 1, opts->cycles, SZ_D);
		cc = CC_NS;
	} else {
		cmp_rr(code, opts->cycles, opts->limit, SZ_D);
		cc = CC_A;
	}
	jcc(code, cc, code->cur+2);
	opts->move_pc_off = code->cur - tmp.cur;
	mov_ir(code, 0x1234, opts->scratch1, SZ_D);
	opts->move_pc_size = code->cur - tmp.cur - opts->move_pc_off;
	*code = tmp;
}

void patch_for_retranslate(cpu_options *opts, code_ptr native_address, code_ptr handler)
{
	if (!is_mov_ir(native_address)) {
		//instruction is not already patched for either retranslation or a breakpoint
		//copy original mov_ir instruction containing PC to beginning of native code area
		memmove(native_address, native_address + opts->move_pc_off, opts->move_pc_size);
	}
	//jump to the retranslation handler
	code_info tmp = {
		.cur =  native_address + opts->move_pc_size,
		.last = native_address + 256,
		.stack_off = 0
	};
	jmp(&tmp, handler);
}

void defer_translation(cpu_options *opts, uint32_t address, code_ptr handler)
{
	mov_ir(&opts->code, address, opts->scratch1, SZ_D);
	jmp(&opts->code, handler);
}

void check_cycles(cpu_options * opts)
{
	code_info *code = &opts->code;
	uint8_t cc;
	if (opts->limit < 0) {
		cmp_ir(code, 1, opts->cycles, SZ_D);
		cc = CC_NS;
	} else {
		cmp_rr(code, opts->cycles, opts->limit, SZ_D);
		cc = CC_A;
	}
	code_ptr jmp_off;
ALLOC_CODE_RETRY_POINT
	jmp_off = code->cur+1;
	jcc(code, cc, jmp_off+1);
	call(code, opts->handle_cycle_limit);
	CHECK_BRANCH_DEST(jmp_off);
}

void log_address(cpu_options *opts, uint32_t address, char * format)
{
	code_info *code = &opts->code;
	call(code, opts->save_context);
	push_r(code, opts->context_reg);
	mov_rr(code, opts->cycles, RDX, SZ_D);
	mov_ir(code, (intptr_t)format, RDI, SZ_PTR);
	mov_ir(code, address, RSI, SZ_D);
	call_args_abi(code, (code_ptr)printf, 3, RDI, RSI, RDX);
	pop_r(code, opts->context_reg);
	call(code, opts->load_context);
}

void check_code_prologue(code_info *code)
{
	check_alloc_code(code, MAX_INST_LEN*4);
}

code_ptr gen_mem_fun(cpu_options * opts, memmap_chunk const * memmap, uint32_t num_chunks, ftype fun_type, code_ptr *after_inc, uint8_t from_c)
{
	code_info *code = &opts->code;
	code_ptr start = code->cur;
	uint8_t is_write = fun_type == WRITE_16 || fun_type == WRITE_8;
	uint8_t adr_reg, context_reg, value_reg, dst_reg, tmp_context_reg;
	uint8_t size =  (fun_type == READ_16 || fun_type == WRITE_16) ? SZ_W : SZ_B;
	
	if (from_c) {
#if defined(X86_64)
#if defined(_WIN32)
		//RCX, RDX, R8
		adr_reg = RCX;
		context_reg = RDX;
		value_reg = is_write ? R8 : RAX;
#else
		//RDI, RSI, RDX
		adr_reg = RDI;
		context_reg = RSI;
		value_reg = is_write ? RDX : RAX;
#endif
#else
		//rtl on stack, EAX, ECX, EDX are caller saved
		adr_reg = RCX;
		context_reg = RDX;
		value_reg = RAX;
		mov_rr(code, RSP, RAX, SZ_D);
		mov_rdispr(code, RAX, 4, adr_reg, opts->address_size);
		mov_rdispr(code, RAX, 8, context_reg, SZ_D);
		if (is_write) {
			mov_rdispr(code, RAX, 12, value_reg, size);
		}
#endif
		tmp_context_reg = opts->context_reg;
		opts->context_reg = context_reg;
	} else {
		adr_reg = is_write ? opts->scratch2 : opts->scratch1;
		value_reg = opts->scratch1;
		context_reg = opts->context_reg;
		check_cycles(opts);
	}
	if (size != SZ_B && opts->align_error_mask) {
		test_ir(code, opts->align_error_mask, adr_reg, SZ_D);
		jcc(code, CC_NZ, is_write ? opts->handle_align_error_write : opts->handle_align_error_read);
	}
	if (opts->bus_cycles) {
		cycles(opts, opts->bus_cycles);
	}
	if (after_inc) {
		*after_inc = code->cur;
	}

	if (opts->address_size == SZ_D && opts->address_mask != 0xFFFFFFFF) {
		and_ir(code, opts->address_mask, adr_reg, SZ_D);
	} else if (opts->address_size == SZ_W && opts->address_mask != 0xFFFF) {
		and_ir(code, opts->address_mask, adr_reg, SZ_W);
	}

	code_ptr check_watchpoints = size == SZ_W ? (code_ptr)opts->check_watchpoints_16 : (code_ptr)opts->check_watchpoints_8;
	if (is_write && check_watchpoints) {
		//watchpoints are enabled, check if the address is within the watchpoint range
		cmp_rdispr(code, context_reg, opts->watchpoint_range_off, adr_reg, opts->address_size);
		code_ptr watch_lb = code->cur + 1;
		jcc(code, CC_C, code->cur + 2);
		cmp_rdispr(code, context_reg, opts->watchpoint_range_off + (opts->address_size == SZ_D ? 4 : 2), adr_reg, opts->address_size);
		code_ptr watch_ub = code->cur + 1;
		jcc(code, CC_A, code->cur + 2);

		push_r(code, value_reg);
		push_r(code, adr_reg);
		if (!from_c) {
			call(code, opts->save_context);
		}
		call_args_abi(code, check_watchpoints, 3, adr_reg, context_reg, value_reg);
		mov_rr(code, RAX, context_reg, SZ_PTR);
		if (!from_c) {
			call(code, opts->load_context);
		}
		pop_r(code, adr_reg);
		pop_r(code, value_reg);

		*watch_lb = code->cur - (watch_lb + 1);
		*watch_ub = code->cur - (watch_ub + 1);
	}

	code_ptr lb_jcc = NULL, ub_jcc = NULL;
	uint16_t access_flag = is_write ? MMAP_WRITE : MMAP_READ;
	uint32_t ram_flags_off = opts->ram_flags_off;
	uint32_t min_address = 0;
	uint32_t max_address = opts->max_address;
	uint8_t need_wide_jcc = 0;
	for (uint32_t chunk = 0; chunk < num_chunks; chunk++)
	{
		code_info chunk_start = *code;
		if (memmap[chunk].start > min_address) {
			cmp_ir(code, memmap[chunk].start, adr_reg, opts->address_size);
			lb_jcc = code->cur + 1;
			if (need_wide_jcc) {
				jcc(code, CC_C, code->cur + 130);
				lb_jcc++;
			} else {
				jcc(code, CC_C, code->cur + 2);
			}
		} else {
			min_address = memmap[chunk].end;
		}
		if (memmap[chunk].end < max_address) {
			cmp_ir(code, memmap[chunk].end, adr_reg, opts->address_size);
			ub_jcc = code->cur + 1;
			if (need_wide_jcc) {
				jcc(code, CC_NC, code->cur + 130);
				ub_jcc++;
			} else {
				jcc(code, CC_NC, code->cur + 2);
			}
		} else {
			max_address = memmap[chunk].start;
		}

		if (memmap[chunk].mask != opts->address_mask) {
			and_ir(code, memmap[chunk].mask, adr_reg, opts->address_size);
		}
		if (!is_write && memmap[chunk].read_cycles) {
			cycles(opts, memmap[chunk].read_cycles);
		} else if (is_write && memmap[chunk].write_cycles) {
			cycles(opts, memmap[chunk].write_cycles);
		}
		code_ptr after_normal = NULL;
		uint8_t need_addr_pop = 0;
		if (size == SZ_B && memmap[chunk].shift != 0) {
			if (is_write && (memmap[chunk].flags & MMAP_CODE) && !from_c) {
				push_r(code, adr_reg);
				need_addr_pop = 1;
			}
			btr_ir(code, 0, adr_reg, opts->address_size);
			code_ptr normal = code->cur+1;
			jcc(code, CC_NC, normal);
			if (memmap[chunk].shift > 0) {
				shl_ir(code, memmap[chunk].shift, adr_reg, opts->address_size);
			} else {
				shr_ir(code, -memmap[chunk].shift, adr_reg, opts->address_size);
			}
			or_ir(code, 1, adr_reg, opts->address_size);
			after_normal = code->cur + 1;
			jmp(code, after_normal);
			*normal = code->cur - (normal + 1);
		}
		if (memmap[chunk].shift > 0) {
			if (!need_addr_pop && is_write && (memmap[chunk].flags & MMAP_CODE) && !from_c) {
				push_r(code, adr_reg);
				need_addr_pop = 1;
			}
			shl_ir(code, memmap[chunk].shift, adr_reg, opts->address_size);
		} else if (memmap[chunk].shift < 0) {
			if (!need_addr_pop && is_write && (memmap[chunk].flags & MMAP_CODE) && !from_c) {
				push_r(code, adr_reg);
				need_addr_pop = 1;
			}
			shr_ir(code, -memmap[chunk].shift, adr_reg, opts->address_size);
		}
		if (after_normal) {
			*after_normal = code->cur - (after_normal + 1);
		}
		void * cfun;
		switch (fun_type)
		{
		case READ_16:
			cfun = memmap[chunk].read_16;
			break;
		case READ_8:
			cfun = memmap[chunk].read_8;
			break;
		case WRITE_16:
			cfun = memmap[chunk].write_16;
			break;
		case WRITE_8:
			cfun = memmap[chunk].write_8;
			break;
		default:
			cfun = NULL;
		}
		if(memmap[chunk].flags & access_flag) {
			uint8_t tmp_size = size;
			if (memmap[chunk].flags & MMAP_PTR_IDX) {
				if (memmap[chunk].flags & (MMAP_FUNC_NULL | MMAP_AUX_BUFF)) {
					cmp_irdisp(code, 0, context_reg, opts->mem_ptr_off + sizeof(void*) * memmap[chunk].ptr_index, SZ_PTR);
					code_ptr not_null = code->cur + 1;
					jcc(code, CC_NZ, code->cur + 2);
					if (memmap[chunk].flags & MMAP_FUNC_NULL) {
						uint32_t stack_off;
						if (need_addr_pop) {
							stack_off = code->stack_off;
							pop_r(code, adr_reg);
						}
						if (!from_c) {
							call(code, opts->save_context);
						}
						if (is_write) {
							call_args_abi(code, cfun, 3, adr_reg, context_reg, value_reg);
							if (!from_c) {
								mov_rr(code, RAX, context_reg, SZ_PTR);
							}
						} else {
							if (!from_c) {
								push_r(code, context_reg);
							}
							call_args_abi(code, cfun, 2, adr_reg, context_reg);
							if (!from_c) {
								pop_r(code, context_reg);
							}
							if (value_reg != RAX) {
								mov_rr(code, RAX, value_reg, size);
							}
						}
						if (from_c) {
							retn(code);
						} else {
							jmp(code, opts->load_context);
						}
						if (need_addr_pop) {
							code->stack_off = stack_off;
						}
					} else {
						if (!is_write) {
							mov_ir(code, size == SZ_B ? 0xFF : 0xFFFF, value_reg, size);
						}
						retn(code);
					}

					*not_null = code->cur - (not_null + 1);
				}
				if (size == SZ_B) {
					if ((memmap[chunk].flags & MMAP_ONLY_ODD) || (memmap[chunk].flags & MMAP_ONLY_EVEN)) {
						bt_ir(code, 0, adr_reg, opts->address_size);
						code_ptr good_addr = code->cur + 1;
						jcc(code, (memmap[chunk].flags & MMAP_ONLY_ODD) ? CC_C : CC_NC, code->cur + 2);
						if (!is_write) {
							mov_ir(code, 0xFF, value_reg, SZ_B);
						}
						retn(code);
						*good_addr = code->cur - (good_addr + 1);
						shr_ir(code, 1, adr_reg, opts->address_size);
					} else if (opts->byte_swap || memmap[chunk].flags & MMAP_BYTESWAP) {
						xor_ir(code, 1, adr_reg, opts->address_size);
					}
				} else if ((memmap[chunk].flags & MMAP_ONLY_ODD) || (memmap[chunk].flags & MMAP_ONLY_EVEN)) {
					tmp_size = SZ_B;
					shr_ir(code, 1, adr_reg, opts->address_size);
					if ((memmap[chunk].flags & MMAP_ONLY_EVEN) && is_write) {
						shr_ir(code, 8, value_reg, SZ_W);
					}
				}
				if (opts->address_size != SZ_D) {
					movzx_rr(code, adr_reg, adr_reg, opts->address_size, SZ_D);
				}
				if (!need_addr_pop && is_write && (memmap[chunk].flags & MMAP_CODE) && !from_c) {
					push_r(code, adr_reg);
					need_addr_pop = 1;
				}
				add_rdispr(code, context_reg, opts->mem_ptr_off + sizeof(void*) * memmap[chunk].ptr_index, adr_reg, SZ_PTR);
				if (is_write) {
					mov_rrind(code, value_reg, adr_reg, tmp_size);
				} else {
					mov_rindr(code, adr_reg, value_reg, tmp_size);
				}
				if (size != tmp_size && !is_write) {
					if (memmap[chunk].flags & MMAP_ONLY_EVEN) {
						shl_ir(code, 8, value_reg, SZ_W);
						mov_ir(code, 0xFF, value_reg, SZ_B);
					} else {
						or_ir(code, 0xFF00, value_reg, SZ_W);
					}
				}
			} else {
				if (size == SZ_B) {
					if ((memmap[chunk].flags & MMAP_ONLY_ODD) || (memmap[chunk].flags & MMAP_ONLY_EVEN)) {
						bt_ir(code, 0, adr_reg, opts->address_size);
						code_ptr good_addr = code->cur + 1;
						jcc(code, (memmap[chunk].flags & MMAP_ONLY_ODD) ? CC_C : CC_NC, code->cur + 2);
						if (!is_write) {
							mov_ir(code, 0xFF, value_reg, SZ_B);
						}
						retn(code);
						*good_addr = code->cur - (good_addr + 1);
						shr_ir(code, 1, adr_reg, opts->address_size);
					} else if (opts->byte_swap || memmap[chunk].flags & MMAP_BYTESWAP) {
						xor_ir(code, 1, adr_reg, opts->address_size);
					}
				} else if ((memmap[chunk].flags & MMAP_ONLY_ODD) || (memmap[chunk].flags & MMAP_ONLY_EVEN)) {
					tmp_size = SZ_B;
					shr_ir(code, 1, adr_reg, opts->address_size);
					if ((memmap[chunk].flags & MMAP_ONLY_EVEN) && is_write) {
						shr_ir(code, 8, value_reg, SZ_W);
					}
				}
				if (opts->address_size != SZ_D) {
					movzx_rr(code, adr_reg, adr_reg, opts->address_size, SZ_D);
				}
				if ((intptr_t)memmap[chunk].buffer <= 0x7FFFFFFF && (intptr_t)memmap[chunk].buffer >= -2147483648) {
					if (is_write) {
						mov_rrdisp(code, value_reg, adr_reg, (intptr_t)memmap[chunk].buffer, tmp_size);
					} else {
						mov_rdispr(code, adr_reg, (intptr_t)memmap[chunk].buffer, value_reg, tmp_size);
					}
				} else {
					if (is_write) {
						push_r(code, adr_reg);
						mov_ir(code, (intptr_t)memmap[chunk].buffer, adr_reg, SZ_PTR);
						add_rdispr(code, RSP, 0, adr_reg, SZ_PTR);
						mov_rrind(code, value_reg, adr_reg, tmp_size);
						if (is_write && (memmap[chunk].flags & MMAP_CODE) && !from_c) {
							need_addr_pop = 1;
						} else {
							add_ir(code, sizeof(void*), RSP, SZ_PTR);
							code->stack_off -= sizeof(void *);
						}
					} else {
						if (from_c) {
							mov_ir(code, (intptr_t)memmap[chunk].buffer, value_reg, SZ_PTR);
							mov_rindexr(code, value_reg, adr_reg, 1, value_reg, tmp_size);
						} else {
							push_r(code, opts->scratch2);
							mov_ir(code, (intptr_t)memmap[chunk].buffer, opts->scratch2, SZ_PTR);
							mov_rindexr(code, opts->scratch2, opts->scratch1, 1, opts->scratch1, tmp_size);
							pop_r(code, opts->scratch2);
						}
					}
				}
				if (size != tmp_size && !is_write) {
					if (memmap[chunk].flags & MMAP_ONLY_EVEN) {
						shl_ir(code, 8, value_reg, SZ_W);
						mov_ir(code, 0xFF, value_reg, SZ_B);
					} else {
						or_ir(code, 0xFF00, value_reg, SZ_W);
					}
				}
			}
			if (is_write && (memmap[chunk].flags & MMAP_CODE) && !from_c) {
				//FIXME: make this work in the from_c case
				if (need_addr_pop) {
					pop_r(code, adr_reg);
				}
				mov_rr(code, opts->scratch2, opts->scratch1, opts->address_size);
				shr_ir(code, opts->ram_flags_shift, opts->scratch1, opts->address_size);
				bt_rrdisp(code, opts->scratch1, context_reg, ram_flags_off, opts->address_size);
				code_ptr not_code = code->cur + 1;
				jcc(code, CC_NC, code->cur + 2);
				if (memmap[chunk].mask != opts->address_mask) {
					or_ir(code, memmap[chunk].start, opts->scratch2, opts->address_size);
				}
				call(code, opts->save_context);
				call_args(code, opts->handle_code_write, 2, opts->scratch2, context_reg);
				mov_rr(code, RAX, context_reg, SZ_PTR);
				jmp(code, opts->load_context);
				*not_code = code->cur - (not_code+1);
			}
			retn(code);
		} else if (cfun) {
			if (!from_c) {
				call(code, opts->save_context);
			}
			if (is_write) {
				call_args_abi(code, cfun, 3, adr_reg, context_reg, value_reg);
				if (!from_c) {
					mov_rr(code, RAX, context_reg, SZ_PTR);
				}
			} else {
				if (!from_c) {
					push_r(code, context_reg);
				}
				call_args_abi(code, cfun, 2, adr_reg, context_reg);
				if (!from_c) {
					pop_r(code, context_reg);
				}
				if (value_reg != RAX) {
					mov_rr(code, RAX, value_reg, size);
				}
			}
			if (from_c) {
				retn(code);
			} else {
				jmp(code, opts->load_context);
			}
		} else {
			//Not sure the best course of action here
			if (!is_write) {
				mov_ir(code, size == SZ_B ? 0xFF : 0xFFFF, value_reg, size);
			}
			retn(code);
		}
		if (lb_jcc) {
			if (need_wide_jcc) {
				*((int32_t*)lb_jcc) = code->cur - (lb_jcc+4);
			} else if (code->cur - (lb_jcc+1) > 0x7f) {
				need_wide_jcc = 1;
				chunk--;
				*code = chunk_start;
				continue;
			} else {
				*lb_jcc = code->cur - (lb_jcc+1);
			}
			lb_jcc = NULL;
		}
		if (ub_jcc) {
			if (need_wide_jcc) {
				*((int32_t*)ub_jcc) = code->cur - (ub_jcc+4);
			} else if (code->cur - (ub_jcc+1) > 0x7f) {
				need_wide_jcc = 1;
				chunk--;
				*code = chunk_start;
				continue;
			} else {
				*ub_jcc = code->cur - (ub_jcc+1);
			}

			ub_jcc = NULL;
		}
		if (memmap[chunk].flags & MMAP_CODE) {
			uint32_t size = chunk_size(opts, memmap + chunk);
			uint32_t size_round_mask = (1 << (opts->ram_flags_shift + 3)) - 1;
			if (size & size_round_mask) {
				size &= ~size_round_mask;
				size += size_round_mask + 1;
			}
			ram_flags_off += size >> (opts->ram_flags_shift + 3);
		}
		if (need_wide_jcc) {
			need_wide_jcc = 0;
		}
	}
	if (!is_write) {
		mov_ir(code, size == SZ_B ? 0xFF : 0xFFFF, value_reg, size);
	}
	retn(code);
	if (from_c) {
		opts->context_reg = tmp_context_reg;
	}
	return start;
}

code_ptr gen_burst_read(cpu_options * opts, memmap_chunk const * memmap, uint32_t num_chunks)
{
	code_info *code = &opts->code;
	code_ptr start = code->cur;
	uint8_t context_reg, adr_reg, dst_reg, tmp_context_reg;
	//assumes caller ensures burst alignment
	//currently assumes 16-byte/8-word burst needed for SH2
	//from_c is assumed for now
#if defined(X86_64)
#if defined(_WIN32)
	//RCX, RDX, R8
	adr_reg = RCX;
	context_reg = RDX;
	dst_reg = R8;
#else
	//RDI, RSI, RDX
	adr_reg = RDI;
	context_reg = RSI;
	dst_reg = RDX;
#endif
#else
	//rtl on stack, EAX, ECX, EDX are caller saved
	adr_reg = RCX;
	context_reg = RDX;
	dst_reg = RAX;
	mov_rr(code, RSP, RAX, SZ_D);
	mov_rdispr(code, RAX, 4, adr_reg, opts->address_size);
	mov_rdispr(code, RAX, 8, context_reg, SZ_PTR);
	mov_rdispr(code, RAX, 12, dst_reg, SZ_PTR);
#endif
	tmp_context_reg = opts->context_reg;
	opts->context_reg = context_reg;

	if (opts->address_size == SZ_D && opts->address_mask != 0xFFFFFFFF) {
		and_ir(code, opts->address_mask, adr_reg, SZ_D);
	} else if (opts->address_size == SZ_W && opts->address_mask != 0xFFFF) {
		and_ir(code, opts->address_mask, adr_reg, SZ_W);
	}
	code_ptr lb_jcc = NULL, ub_jcc = NULL;
	uint32_t min_address = 0;
	uint32_t max_address = opts->max_address;
	uint8_t use_sse2 = cpu_has_sse2();
	uint8_t need_wide_jcc = 0;
	for (uint32_t chunk = 0; chunk < num_chunks; chunk++)
	{
		code_info chunk_start = *code;
		if (memmap[chunk].start > min_address) {
			cmp_ir(code, memmap[chunk].start, adr_reg, opts->address_size);
			lb_jcc = code->cur + 1;
			if (need_wide_jcc) {
				jcc(code, CC_C, code->cur + 130);
				lb_jcc++;
			} else {
				jcc(code, CC_C, code->cur + 2);
			}
		} else {
			min_address = memmap[chunk].end;
		}
		if (memmap[chunk].end < max_address) {
			cmp_ir(code, memmap[chunk].end, adr_reg, opts->address_size);
			ub_jcc = code->cur + 1;
			if (need_wide_jcc) {
				jcc(code, CC_NC, code->cur + 130);
				ub_jcc++;
			} else {
				jcc(code, CC_NC, code->cur + 2);
			}
		} else {
			max_address = memmap[chunk].start;
		}

		if (memmap[chunk].mask != opts->address_mask) {
			and_ir(code, memmap[chunk].mask, adr_reg, opts->address_size);
		}
		if (memmap[chunk].burst_cycles) {
			cycles(opts, memmap[chunk].burst_cycles);
		}
		if (memmap[chunk].flags & MMAP_READ) {
			uint8_t need_pop_rbp = 0;
			if (memmap[chunk].flags & MMAP_PTR_IDX) {
				if (memmap[chunk].flags & MMAP_FUNC_NULL) {
					cmp_irdisp(code, 0, context_reg, opts->mem_ptr_off + sizeof(void*) * memmap[chunk].ptr_index, SZ_PTR);
					code_ptr not_null = code->cur + 1;
					jcc(code, CC_NZ, code->cur + 2);
					push_r(code, RBX);//counter
#if defined(X86_64)
					push_r(code, RBP);
					push_r(code, R12);
					push_r(code, R13);
					mov_rr(code, dst_reg, RBP, SZ_PTR);
					uint8_t my_dst_reg = RBP;
					mov_rr(code, adr_reg, R12, opts->address_size);
					uint8_t my_adr_reg = R12;
					mov_rr(code, context_reg, R13, SZ_PTR);
					uint8_t my_context_reg = R13;
#else
					
					push_r(code, RBP);
					push_r(code, RDI);
					push_r(code, RSI);
					mov_rr(code, dst_reg, RBP, SZ_PTR);
					uint8_t my_dst_reg = RBP;
					mov_rr(code, adr_reg, RDI, opts->address_size);
					uint8_t my_adr_reg = RDI;
					mov_rr(code, context_reg, RSI, SZ_PTR);
					uint8_t my_context_reg = RSI;
#endif
					mov_ir(code, 8, RBX, SZ_D);
					code_ptr loop_top = code->cur;
					//caller saved
					//32-bit: EAX, ECX, EDX
					//SYSV 64: RAX, RCX, RDX, RDI, RSI, R8, R9, R10, R11
					//WIN64: RAX, RCX, RDX, R8, R9, R10, R11
					//callee saved
					//32-bit: EBX, EDI, ESI, EBP
					//SYSV 64: RBX, RBP, R12-R15
					//WIN64: RBX, RDI, RSI, RBP, R12-R15
					xor_ir(code, 2, my_dst_reg, SZ_PTR);
					call_args_abi(code, (code_ptr)memmap[chunk].read_16, 2, my_adr_reg, my_context_reg);
					mov_rrind(code, RAX, my_dst_reg, SZ_W);
					xor_ir(code, 2, my_dst_reg, SZ_PTR);
					add_ir(code, 2, my_dst_reg, SZ_PTR);
					add_ir(code, 2, my_adr_reg, opts->address_size);
					dec_r(code, RBX, SZ_D);
					jcc(code, CC_NZ, loop_top);
#if defined(X86_64)
					pop_r(code, R13);
					pop_r(code, R12);
					pop_r(code, RBP);
#else
					pop_r(code, RSI);
					pop_r(code, RDI);
					pop_r(code, RBP);
#endif
					pop_r(code, RBX);
					retn(code);
					*not_null = code->cur - (not_null + 1);
				}
				if (opts->address_size != SZ_D) {
					movzx_rr(code, adr_reg, adr_reg, opts->address_size, SZ_D);
				}
				add_rdispr(code, context_reg, opts->mem_ptr_off + sizeof(void*) * memmap[chunk].ptr_index, adr_reg, SZ_PTR);
				//TODO: Don't shuffle if byteswap is not set
				if (use_sse2) {
					//   10 11 00 01
					pshuflw_rindr(code, adr_reg, XMM0, 0xB1);
				} else {
					pshufw_rindr(code, adr_reg, MM0, 0xB1);
					pshufw_rdispr(code, adr_reg, 8, MM1, 0xB1);
				}
			} else {
				if (opts->address_size != SZ_D) {
					movzx_rr(code, adr_reg, adr_reg, opts->address_size, SZ_D);
				}
#if defined(X86_64)
				if ((intptr_t)memmap[chunk].buffer <= 0x7FFFFFFF && (intptr_t)memmap[chunk].buffer >= -2147483648) {
#endif
					//TODO: Don't shuffle if byteswap is not set
					if (use_sse2) {
						pshuflw_rdispr(code, adr_reg, (intptr_t)memmap[chunk].buffer, XMM0, 0xB1);
					} else {
						pshufw_rdispr(code, adr_reg, (intptr_t)memmap[chunk].buffer, MM0, 0xB1);
						pshufw_rdispr(code, adr_reg, ((intptr_t)memmap[chunk].buffer) + 8, MM1, 0xB1);
					}
#if defined(X86_64)
				} else {
					mov_ir(code, (intptr_t)memmap[chunk].buffer, RAX, SZ_PTR);
					//TODO: Don't shuffle if byteswap is not set
					//SSE2 always available on 64-bit
					pshuflw_rindexr(code, RAX, adr_reg, 1, XMM0, 0xB1);
				}
#endif
			}
			if (use_sse2) {
				pshufhw_rr(code, XMM0, XMM0, 0xB1);
				movdqa_rrind(code, XMM0, dst_reg);
			} else {
				movq_rrind(code, MM0, dst_reg);
				movq_rrdisp(code, MM1, dst_reg, 8);
				emms(code);
			}
			retn(code);
		} else if (memmap[chunk].read_16) {
			push_r(code, RBX);//counter
#if defined(X86_64)
			push_r(code, RBP);
			push_r(code, R12);
			push_r(code, R13);
			mov_rr(code, dst_reg, RBP, SZ_PTR);
			uint8_t my_dst_reg = RBP;
			mov_rr(code, adr_reg, R12, opts->address_size);
			uint8_t my_adr_reg = R12;
			mov_rr(code, context_reg, R13, SZ_PTR);
			uint8_t my_context_reg = R13;
#else
			push_r(code, RBP);
			push_r(code, RDI);
			push_r(code, RSI);
			mov_rr(code, dst_reg, RBP, SZ_PTR);
			uint8_t my_dst_reg = RBP;
			mov_rr(code, adr_reg, RDI, opts->address_size);
			uint8_t my_adr_reg = RDI;
			mov_rr(code, context_reg, RSI, SZ_PTR);
			uint8_t my_context_reg = RSI;
#endif
			mov_ir(code, 8, RBX, SZ_D);
			code_ptr loop_top = code->cur;
			//caller saved
			//32-bit: EAX, ECX, EDX
			//SYSV 64: RAX, RCX, RDX, RDI, RSI, R8, R9, R10, R11
			//WIN64: RAX, RCX, RDX, R8, R9, R10, R11
			//callee saved
			//32-bit: EBX, EDI, ESI, EBP
			//SYSV 64: RBX, RBP, R12-R15
			//WIN64: RBX, RDI, RSI, RBP, R12-R15
			xor_ir(code, 2, my_dst_reg, SZ_PTR);
			call_args_abi(code, (code_ptr)memmap[chunk].read_16, 2, my_adr_reg, my_context_reg);
			mov_rrind(code, RAX, my_dst_reg, SZ_W);
			xor_ir(code, 2, my_dst_reg, SZ_PTR);
			add_ir(code, 2, my_dst_reg, SZ_PTR);
			add_ir(code, 2, my_adr_reg, opts->address_size);
			dec_r(code, RBX, SZ_D);
			jcc(code, CC_NZ, loop_top);
#if defined(X86_64)
			pop_r(code, R13);
			pop_r(code, R12);
			pop_r(code, RBP);
#else
			pop_r(code, RSI);
			pop_r(code, RDI);
			pop_r(code, RBP);
#endif
			pop_r(code, RBX);
			retn(code);
		} else {
#if defined(X86_64)
			mov_ir(code, 0xFFFFFFFFFFFFFFFFULL, adr_reg, SZ_Q);
			mov_rrind(code, adr_reg, dst_reg, SZ_Q);
			mov_rrdisp(code, adr_reg, dst_reg, 8, SZ_Q);
#else
			mov_ir(code, 0xFFFFFFFF, adr_reg, SZ_D);
			mov_rrind(code, adr_reg, dst_reg, SZ_D);
			mov_rrdisp(code, adr_reg, dst_reg, 4, SZ_D);
			mov_rrdisp(code, adr_reg, dst_reg, 8, SZ_D);
			mov_rrdisp(code, adr_reg, dst_reg, 12, SZ_D);
#endif
			retn(code);
		}
		if (lb_jcc) {
			if (need_wide_jcc) {
				*((int32_t*)lb_jcc) = code->cur - (lb_jcc+4);
			} else if (code->cur - (lb_jcc+1) > 0x7f) {
				need_wide_jcc = 1;
				chunk--;
				*code = chunk_start;
				continue;
			} else {
				*lb_jcc = code->cur - (lb_jcc+1);
			}
			lb_jcc = NULL;
		}
		if (ub_jcc) {
			if (need_wide_jcc) {
				*((int32_t*)ub_jcc) = code->cur - (ub_jcc+4);
			} else if (code->cur - (ub_jcc+1) > 0x7f) {
				need_wide_jcc = 1;
				chunk--;
				*code = chunk_start;
				continue;
			} else {
				*ub_jcc = code->cur - (ub_jcc+1);
			}

			ub_jcc = NULL;
		}
		if (need_wide_jcc) {
			need_wide_jcc = 0;
		}
	}
#if defined(X86_64)
	mov_ir(code, 0xFFFFFFFFFFFFFFFFULL, adr_reg, SZ_Q);
	mov_rrind(code, adr_reg, dst_reg, SZ_Q);
	mov_rrdisp(code, adr_reg, dst_reg, 8, SZ_Q);
#else
	mov_ir(code, 0xFFFFFFFF, adr_reg, SZ_D);
	mov_rrind(code, adr_reg, dst_reg, SZ_D);
	mov_rrdisp(code, adr_reg, dst_reg, 4, SZ_D);
	mov_rrdisp(code, adr_reg, dst_reg, 8, SZ_D);
	mov_rrdisp(code, adr_reg, dst_reg, 12, SZ_D);
#endif
	retn(code);
	opts->context_reg = tmp_context_reg;
	return start;
}
