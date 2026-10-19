/*
 Copyright 2013 Michael Pavone
 This file is part of BlastEm.
 BlastEm is free software distributed under the terms of the GNU General Public License version 3 or greater. See COPYING for full license text.
*/
#include "backend.h"
#include <stdlib.h>

deferred_addr * defer_address(deferred_addr * old_head, uint32_t address, code_ptr dest)
{
	deferred_addr * new_head = malloc(sizeof(deferred_addr));
	new_head->next = old_head;
	new_head->address = address;
	new_head->dest = dest;
	return new_head;
}

void remove_deferred_until(deferred_addr **head_ptr, deferred_addr * remove_to)
{
	for(deferred_addr *cur = *head_ptr; cur && cur != remove_to; cur = *head_ptr)
	{
		*head_ptr = cur->next;
		free(cur);
	}
}

void process_deferred(deferred_addr ** head_ptr, void * context, native_addr_func get_native)
{
	deferred_addr * cur = *head_ptr;
	deferred_addr **last_next = head_ptr;
	while(cur)
	{
		code_ptr native = get_native(context, cur->address);//get_native_address(opts->native_code_map, cur->address);
		if (native) {
			int32_t disp = native - (cur->dest + 4);
			code_ptr out = cur->dest;
			*(out++) = disp;
			disp >>= 8;
			*(out++) = disp;
			disp >>= 8;
			*(out++) = disp;
			disp >>= 8;
			*out = disp;
			*last_next = cur->next;
			free(cur);
			cur = *last_next;
		} else {
			last_next = &(cur->next);
			cur = cur->next;
		}
	}
}

memmap_chunk const *find_map_chunk(uint32_t address, cpu_options *opts, uint16_t flags, uint32_t *size_sum)
{
	if (size_sum) {
		*size_sum = 0;
	}
	uint32_t size_round_mask;
	if (flags == MMAP_CODE) {
		size_round_mask = (1 << (opts->ram_flags_shift + 3)) - 1;
	} else {
		size_round_mask = 0;
	}
	address &= opts->address_mask;
	for (memmap_chunk const *cur = opts->memmap, *end = opts->memmap + opts->memmap_chunks; cur != end; cur++)
	{
		if (address >= cur->start && address < cur->end) {
			return cur;
		} else if (size_sum && (cur->flags & flags) == flags) {
			uint32_t size = chunk_size(opts, cur);
			if (size_round_mask) {
				if (size & size_round_mask) {
					size &= ~size_round_mask;
					size += size_round_mask + 1;
				}
			}
			*size_sum += size;
		}
	}
	return NULL;
}

void * get_native_pointer(uint32_t address, void ** mem_pointers, cpu_options * opts)
{
	memmap_chunk const * memmap = opts->memmap;
	address &= opts->address_mask;
	for (uint32_t chunk = 0; chunk < opts->memmap_chunks; chunk++)
	{
		if (address >= memmap[chunk].start && address < memmap[chunk].end) {
			if (!(memmap[chunk].flags & (MMAP_READ|MMAP_READ_CODE))) {
				return NULL;
			}
			uint8_t * base = memmap[chunk].flags & MMAP_PTR_IDX
				? mem_pointers[memmap[chunk].ptr_index]
				: memmap[chunk].buffer;
			if (!base) {
				if (memmap[chunk].flags & MMAP_AUX_BUFF) {
					address &= memmap[chunk].aux_mask;
					if (memmap[chunk].shift > 0) {
						address <<= memmap[chunk].shift;
					} else if (memmap[chunk].shift < 0) {
						address >>= -memmap[chunk].shift;
					}
					return ((uint8_t *)memmap[chunk].buffer) + address;
				}
				return NULL;
			}
			address &= memmap[chunk].mask;
			if (memmap[chunk].shift > 0) {
				address <<= memmap[chunk].shift;
			} else if (memmap[chunk].shift < 0) {
				address >>= -memmap[chunk].shift;
			}
			return base + address;
		}
	}
	return NULL;
}

void * get_native_write_pointer(uint32_t address, void ** mem_pointers, cpu_options * opts)
{
	memmap_chunk const * memmap = opts->memmap;
	address &= opts->address_mask;
	for (uint32_t chunk = 0; chunk < opts->memmap_chunks; chunk++)
	{
		if (address >= memmap[chunk].start && address < memmap[chunk].end) {
			if (!(memmap[chunk].flags & (MMAP_WRITE))) {
				return NULL;
			}
			uint8_t * base = memmap[chunk].flags & MMAP_PTR_IDX
				? mem_pointers[memmap[chunk].ptr_index]
				: memmap[chunk].buffer;
			if (!base) {
				if (memmap[chunk].flags & MMAP_AUX_BUFF) {
					address &= memmap[chunk].aux_mask;
					if (memmap[chunk].shift > 0) {
						address <<= memmap[chunk].shift;
					} else if (memmap[chunk].shift < 0) {
						address >>= -memmap[chunk].shift;
					}
					return ((uint8_t *)memmap[chunk].buffer) + address;
				}
				return NULL;
			}
			address &= memmap[chunk].mask;
			if (memmap[chunk].shift > 0) {
				address <<= memmap[chunk].shift;
			} else if (memmap[chunk].shift < 0) {
				address >>= -memmap[chunk].shift;
			}
			return base + address;
		}
	}
	return NULL;
}

uint16_t read_word(uint32_t address, void **mem_pointers, cpu_options *opts, void *context)
{
	memmap_chunk const *chunk = find_map_chunk(address, opts, 0, NULL);
	if (!chunk) {
		return 0xFFFF;
	}
	uint32_t offset = address & chunk->mask;
	if (chunk->shift > 0) {
		offset <<= chunk->shift;
	} else if (chunk->shift < 0){
		offset >>= -chunk->shift;
	}
	if (chunk->flags & MMAP_READ) {
		uint8_t *base;
		if (chunk->flags & MMAP_PTR_IDX) {
			base = mem_pointers[chunk->ptr_index];
		} else {
			base = chunk->buffer;
		}
		if (base) {
			uint16_t val;
			if ((chunk->flags & MMAP_ONLY_ODD) || (chunk->flags & MMAP_ONLY_EVEN)) {
				offset /= 2;
				val = base[offset];
				if (chunk->flags & MMAP_ONLY_ODD) {
					val |= 0xFF00;
				} else {
					val = val << 8 | 0xFF;
				}
			} else {
				val = *(uint16_t *)(base + offset);
			}
			return val;
		}
	}
	if ((!(chunk->flags & MMAP_READ) || (chunk->flags & MMAP_FUNC_NULL)) && chunk->read_16) {
		return chunk->read_16(offset, context);
	}
	return 0xFFFF;
}

uint16_t read_word_cycles(uint32_t address, void **mem_pointers, cpu_options *opts, void *context, uint32_t *cycles)
{
	memmap_chunk const *chunk = find_map_chunk(address, opts, 0, NULL);
	if (!chunk) {
		return 0xFFFF;
	}
	uint32_t offset = address & chunk->mask;
	if (chunk->shift > 0) {
		offset <<= chunk->shift;
	} else if (chunk->shift < 0){
		offset >>= -chunk->shift;
	}
	if (chunk->read_cycles) {
		*cycles += chunk->read_cycles * opts->clock_divider;
	}
	if (chunk->flags & MMAP_READ) {
		uint8_t *base;
		if (chunk->flags & MMAP_PTR_IDX) {
			base = mem_pointers[chunk->ptr_index];
		} else {
			base = chunk->buffer;
		}
		if (base) {
			uint16_t val;
			if ((chunk->flags & MMAP_ONLY_ODD) || (chunk->flags & MMAP_ONLY_EVEN)) {
				offset /= 2;
				val = base[offset];
				if (chunk->flags & MMAP_ONLY_ODD) {
					val |= 0xFF00;
				} else {
					val = val << 8 | 0xFF;
				}
			} else {
				val = *(uint16_t *)(base + offset);
			}
			return val;
		}
	}
	if ((!(chunk->flags & MMAP_READ) || (chunk->flags & MMAP_FUNC_NULL)) && chunk->read_16) {
		return chunk->read_16(offset, context);
	}
	return 0xFFFF;
}

void write_word(uint32_t address, uint16_t value, void **mem_pointers, cpu_options *opts, void *context)
{
	memmap_chunk const *chunk = find_map_chunk(address, opts, 0, NULL);
	if (!chunk) {
		return;
	}
	uint32_t offset = address & chunk->mask;
	if (chunk->shift > 0) {
		offset <<= chunk->shift;
	} else if (chunk->shift < 0){
		offset >>= -chunk->shift;
	}
	
	if (chunk->flags & MMAP_WRITE) {
		uint8_t *base;
		if (chunk->flags & MMAP_PTR_IDX) {
			base = mem_pointers[chunk->ptr_index];
		} else {
			base = chunk->buffer;
		}
		if (base) {
			if ((chunk->flags & MMAP_ONLY_ODD) || (chunk->flags & MMAP_ONLY_EVEN)) {
				offset /= 2;
				if (chunk->flags & MMAP_ONLY_EVEN) {
					value >>= 16;
				}
				base[offset] = value;
			} else {
				*(uint16_t *)(base + offset) = value;
			}
			return;
		}
	}
	if ((!(chunk->flags & MMAP_WRITE) || (chunk->flags & MMAP_FUNC_NULL)) && chunk->write_16) {
		chunk->write_16(offset, context, value);
	}
}

void write_word_cycles(uint32_t address, uint16_t value, void **mem_pointers, cpu_options *opts, void *context, uint32_t *cycles)
{
	memmap_chunk const *chunk = find_map_chunk(address, opts, 0, NULL);
	if (!chunk) {
		return;
	}
	uint32_t offset = address & chunk->mask;
	if (chunk->shift > 0) {
		offset <<= chunk->shift;
	} else if (chunk->shift < 0){
		offset >>= -chunk->shift;
	}
	if (chunk->write_cycles) {
		*cycles += chunk->write_cycles * opts->clock_divider;
	}
	if (chunk->flags & MMAP_WRITE) {
		uint8_t *base;
		if (chunk->flags & MMAP_PTR_IDX) {
			base = mem_pointers[chunk->ptr_index];
		} else {
			base = chunk->buffer;
		}
		if (base) {
			if ((chunk->flags & MMAP_ONLY_ODD) || (chunk->flags & MMAP_ONLY_EVEN)) {
				offset /= 2;
				if (chunk->flags & MMAP_ONLY_EVEN) {
					value >>= 16;
				}
				base[offset] = value;
			} else {
				*(uint16_t *)(base + offset) = value;
			}
			return;
		}
	}
	if ((!(chunk->flags & MMAP_WRITE) || (chunk->flags & MMAP_FUNC_NULL)) && chunk->write_16) {
		chunk->write_16(offset, context, value);
	}
}

uint8_t read_byte(uint32_t address, void **mem_pointers, cpu_options *opts, void *context)
{
	memmap_chunk const *chunk = find_map_chunk(address, opts, 0, NULL);
	if (!chunk) {
		return 0xFF;
	}
	uint32_t offset = address & chunk->mask;
	if (offset) {
		uint32_t low_bit = offset & 1;
		offset &= ~1;
		if (chunk->shift > 0) {
			offset <<= chunk->shift;
		} else {
			offset >>= -chunk->shift;
		}
		offset |= low_bit;
	}
	if (chunk->flags & MMAP_READ) {
		uint8_t *base;
		if (chunk->flags & MMAP_PTR_IDX) {
			base = mem_pointers[chunk->ptr_index];
		} else {
			base = chunk->buffer;
		}
		if (base) {
			if ((chunk->flags & MMAP_ONLY_ODD) || (chunk->flags & MMAP_ONLY_EVEN)) {
				if (address & 1) {
					if (chunk->flags & MMAP_ONLY_EVEN) {
						return 0xFF;
					}
				} else if (chunk->flags & MMAP_ONLY_ODD) {
					return 0xFF;
				}
				offset /= 2;
			} else if(opts->byte_swap) {
				offset ^= 1;
			}
			return base[offset];
		}
	}
	if ((!(chunk->flags & MMAP_READ) || (chunk->flags & MMAP_FUNC_NULL)) && chunk->read_8) {
		return chunk->read_8(offset, context);
	}
	return 0xFF;
}

uint8_t read_byte_cycles(uint32_t address, void **mem_pointers, cpu_options *opts, void *context, uint32_t *cycles)
{
	memmap_chunk const *chunk = find_map_chunk(address, opts, 0, NULL);
	if (!chunk) {
		return 0xFF;
	}
	uint32_t offset = address & chunk->mask;
	if (offset) {
		uint32_t low_bit = offset & 1;
		offset &= ~1;
		if (chunk->shift > 0) {
			offset <<= chunk->shift;
		} else {
			offset >>= -chunk->shift;
		}
		offset |= low_bit;
	}
	
	if (chunk->read_cycles) {
		*cycles += chunk->read_cycles * opts->clock_divider;
	}
	if (chunk->flags & MMAP_READ) {
		uint8_t *base;
		if (chunk->flags & MMAP_PTR_IDX) {
			base = mem_pointers[chunk->ptr_index];
		} else {
			base = chunk->buffer;
		}
		if (base) {
			if ((chunk->flags & MMAP_ONLY_ODD) || (chunk->flags & MMAP_ONLY_EVEN)) {
				if (address & 1) {
					if (chunk->flags & MMAP_ONLY_EVEN) {
						return 0xFF;
					}
				} else if (chunk->flags & MMAP_ONLY_ODD) {
					return 0xFF;
				}
				offset /= 2;
			} else if(opts->byte_swap) {
				offset ^= 1;
			}
			return base[offset];
		}
	}
	if ((!(chunk->flags & MMAP_READ) || (chunk->flags & MMAP_FUNC_NULL)) && chunk->read_8) {
		return chunk->read_8(offset, context);
	}
	return 0xFF;
}

void write_byte(uint32_t address, uint8_t value, void **mem_pointers, cpu_options *opts, void *context)
{
	memmap_chunk const *chunk = find_map_chunk(address, opts, 0, NULL);
	if (!chunk) {
		return;
	}
	uint32_t offset = address & chunk->mask;
	if (chunk->shift) {
		uint32_t low_bit = offset & 1;
		offset &= ~1;
		if (chunk->shift > 0) {
			offset <<= chunk->shift;
		} else {
			offset >>= -chunk->shift;
		}
		offset |= low_bit;
	}
	if (chunk->flags & MMAP_WRITE) {
		uint8_t *base;
		if (chunk->flags & MMAP_PTR_IDX) {
			base = mem_pointers[chunk->ptr_index];
		} else {
			base = chunk->buffer;
		}
		if (base) {
			if ((chunk->flags & MMAP_ONLY_ODD) || (chunk->flags & MMAP_ONLY_EVEN)) {
				if (address & 1) {
					if (chunk->flags & MMAP_ONLY_EVEN) {
						return;
					}
				} else if (chunk->flags & MMAP_ONLY_ODD) {
					return;
				}
				offset /= 2;
			} else if(opts->byte_swap) {
				offset ^= 1;
			}
			base[offset] = value;
		}
	}
	if ((!(chunk->flags & MMAP_WRITE) || (chunk->flags & MMAP_FUNC_NULL)) && chunk->write_8) {
		chunk->write_8(offset, context, value);
	}
}

void write_byte_cycles(uint32_t address, uint8_t value, void **mem_pointers, cpu_options *opts, void *context, uint32_t *cycles)
{
	memmap_chunk const *chunk = find_map_chunk(address, opts, 0, NULL);
	if (!chunk) {
		return;
	}
	uint32_t offset = address & chunk->mask;
	if (chunk->shift) {
		uint32_t low_bit = offset & 1;
		offset &= ~1;
		if (chunk->shift > 0) {
			offset <<= chunk->shift;
		} else {
			offset >>= -chunk->shift;
		}
		offset |= low_bit;
	}
	if (chunk->write_cycles) {
		*cycles += chunk->write_cycles * opts->clock_divider;
	}
	if (chunk->flags & MMAP_WRITE) {
		uint8_t *base;
		if (chunk->flags & MMAP_PTR_IDX) {
			base = mem_pointers[chunk->ptr_index];
		} else {
			base = chunk->buffer;
		}
		if (base) {
			if ((chunk->flags & MMAP_ONLY_ODD) || (chunk->flags & MMAP_ONLY_EVEN)) {
				if (address & 1) {
					if (chunk->flags & MMAP_ONLY_EVEN) {
						return;
					}
				} else if (chunk->flags & MMAP_ONLY_ODD) {
					return;
				}
				offset /= 2;
			} else if(opts->byte_swap) {
				offset ^= 1;
			}
			base[offset] = value;
		}
	}
	if ((!(chunk->flags & MMAP_WRITE) || (chunk->flags & MMAP_FUNC_NULL)) && chunk->write_8) {
		chunk->write_8(offset, context, value);
	}
}

uint32_t chunk_size(cpu_options *opts, memmap_chunk const *chunk)
{
	if (chunk->mask == opts->address_mask) {
		return chunk->end - chunk->start;
	} else {
		return chunk->mask + 1;
	}
}

uint32_t ram_size(cpu_options *opts)
{
	uint32_t size = 0;
	uint32_t minsize = 1 << (opts->ram_flags_shift + 3);
	for (int i = 0; i < opts->memmap_chunks; i++)
	{
		if (opts->memmap[i].flags & MMAP_CODE) {
			uint32_t cursize = chunk_size(opts, opts->memmap + i);
			if (cursize < minsize) {
				size += minsize;
			} else {
				size += cursize;
			}
		}
	}
	return size;
}

uint16_t interp_read_direct_16(uint32_t address, void *context, void *data)
{
	return *(uint16_t *)((address & 0xFFFE) + (uint8_t *)data);
}

uint8_t interp_read_direct_8(uint32_t address, void *context, void *data)
{
	return ((uint8_t *)data)[(address & 0xFFFF) ^ 1];
}

void interp_write_direct_16(uint32_t address, void *context, uint16_t value, void *data)
{
	*(uint16_t *)((address & 0xFFFE) + (uint8_t *)data) = value;
}

void interp_write_direct_8(uint32_t address, void *context, uint8_t value, void *data)
{
	((uint8_t *)data)[(address & 0xFFFF) ^ 1] = value;
}

uint16_t interp_read_indexed_16(uint32_t address, void *context, void *data)
{
	return *(uint16_t *)((*(uint8_t **)data) + (address & 0xFFFE));
}

uint8_t interp_read_indexed_8(uint32_t address, void *context, void *data)
{
	return (*(uint8_t **)data)[(address & 0xFFFF) ^ 1];
}

void interp_write_indexed_16(uint32_t address, void *context, uint16_t value, void *data)
{
	*(uint16_t *)((*(uint8_t **)data) + (address & 0xFFFE)) = value;
}

void interp_write_indexed_8(uint32_t address, void *context, uint8_t value, void *data)
{
	(*(uint8_t **)data)[(address & 0xFFFF) ^ 1] = value;
}

uint16_t interp_read_fixed_16(uint32_t address, void *context, void *data)
{
	return (uintptr_t)data;
}

uint8_t interp_read_fixed_8(uint32_t address, void *context, void *data)
{
	uint16_t val = (uintptr_t)data;
	if (address & 1) {
		return val;
	}
	return val >> 8;
}

void interp_write_ignored_16(uint32_t address, void *context, uint16_t value, void *data)
{
}

void interp_write_ignored_8(uint32_t address, void *context, uint8_t value, void *data)
{
}

uint16_t interp_read_func_16(uint32_t address, void *context, void *data)
{
	read_16_fun f = (read_16_fun)data;
	return f(address, context);
}

uint8_t interp_read_func_8(uint32_t address, void *context, void *data)
{
	read_8_fun f = (read_8_fun)data;
	return f(address, context);
}

void interp_write_func_16(uint32_t address, void *context, uint16_t value, void *data)
{
	write_16_fun f = (write_16_fun)data;
	f(address, context, value);
}

void interp_write_func_8(uint32_t address, void *context, uint8_t value, void *data)
{
	write_8_fun f = (write_8_fun)data;
	f(address, context, value);
}

uint16_t interp_read_map_16(uint32_t address, void *context, void *data)
{
	const memmap_chunk *chunk = data;
	cpu_options * opts = *(cpu_options **)context;
	if (address < chunk->start || address >= chunk->end)
	{
		const memmap_chunk *map_end = opts->memmap + opts->memmap_chunks;
		for (chunk++; chunk < map_end; chunk++)
		{
			if (address >= chunk->start && address < chunk->end) {
				break;
			}
		}
		if (chunk == map_end) {
			return 0xFFFF;
		}
	}
	uint32_t offset = address & chunk->mask;
	if (chunk->shift > 0) {
		offset <<= chunk->shift;
	} else if (chunk->shift < 0){
		offset >>= -chunk->shift;
	}
	if (chunk->flags & MMAP_READ) {
		uint8_t *base;
		if (chunk->flags & MMAP_PTR_IDX) {
			uint8_t ** mem_pointers = (uint8_t**)(opts->mem_ptr_off + (uint8_t *)context);
			base = mem_pointers[chunk->ptr_index];
		} else {
			base = chunk->buffer;
		}
		if (base) {
			uint16_t val;
			if ((chunk->flags & MMAP_ONLY_ODD) || (chunk->flags & MMAP_ONLY_EVEN)) {
				offset /= 2;
				val = base[offset];
				if (chunk->flags & MMAP_ONLY_ODD) {
					val |= 0xFF00;
				} else {
					val = val << 8 | 0xFF;
				}
			} else {
				val = *(uint16_t *)(base + offset);
			}
			return val;
		}
	}
	if ((!(chunk->flags & MMAP_READ) || (chunk->flags & MMAP_FUNC_NULL)) && chunk->read_16) {
		return chunk->read_16(offset, context);
	}
	return 0xFFFF;
}

uint8_t interp_read_map_8(uint32_t address, void *context, void *data)
{
	const memmap_chunk *chunk = data;
	cpu_options * opts = *(cpu_options **)context;
	if (address < chunk->start || address >= chunk->end)
	{
		const memmap_chunk *map_end = opts->memmap + opts->memmap_chunks;
		for (chunk++; chunk < map_end; chunk++)
		{
			if (address >= chunk->start && address < chunk->end) {
				break;
			}
		}
		
		if (chunk == map_end) {
			return 0xFF;
		}
	}
	uint32_t offset = address & chunk->mask;
	if (chunk->shift) {
		uint32_t low_bit = offset & 1;
		offset &= ~1;
		if (chunk->shift > 0) {
			offset <<= chunk->shift;
		} else {
			offset >>= -chunk->shift;
		}
		offset |= low_bit;
	}
	if (chunk->flags & MMAP_READ) {
		uint8_t *base;
		if (chunk->flags & MMAP_PTR_IDX) {
			uint8_t ** mem_pointers = (uint8_t**)(opts->mem_ptr_off + (uint8_t *)context);
			base = mem_pointers[chunk->ptr_index];
		} else {
			base = chunk->buffer;
		}
		if (base) {
			if ((chunk->flags & MMAP_ONLY_ODD) || (chunk->flags & MMAP_ONLY_EVEN)) {
				if (address & 1) {
					if (chunk->flags & MMAP_ONLY_EVEN) {
						return 0xFF;
					}
				} else if (chunk->flags & MMAP_ONLY_ODD) {
					return 0xFF;
				}
				offset /= 2;
			} else if(opts->byte_swap) {
				offset ^= 1;
			}
			return base[offset];
		}
	}
	if ((!(chunk->flags & MMAP_READ) || (chunk->flags & MMAP_FUNC_NULL)) && chunk->read_8) {
		return chunk->read_8(offset, context);
	}
	return 0xFF;
}

void  interp_write_map_16(uint32_t address, void *context, uint16_t value, void *data)
{
	const memmap_chunk *chunk = data;
	cpu_options * opts = *(cpu_options **)context;
	if (address < chunk->start || address >= chunk->end)
	{
		const memmap_chunk *map_end = opts->memmap + opts->memmap_chunks;
		for (chunk++; chunk < map_end; chunk++)
		{
			if (address >= chunk->start && address < chunk->end) {
				break;
			}
		}
		if (chunk == map_end) {
			return;
		}
	}
	uint32_t offset = address & chunk->mask;	
	if (chunk->shift > 0) {
		offset <<= chunk->shift;
	} else if (chunk->shift < 0){
		offset >>= -chunk->shift;
	}
	if (chunk->flags & MMAP_WRITE) {
		uint8_t *base;
		if (chunk->flags & MMAP_PTR_IDX) {
			uint8_t ** mem_pointers = (uint8_t**)(opts->mem_ptr_off + (uint8_t *)context);
			base = mem_pointers[chunk->ptr_index];
		} else {
			base = chunk->buffer;
		}
		if (base) {
			if ((chunk->flags & MMAP_ONLY_ODD) || (chunk->flags & MMAP_ONLY_EVEN)) {
				offset /= 2;
				if (chunk->flags & MMAP_ONLY_EVEN) {
					value >>= 16;
				}
				base[offset] = value;
			} else {
				*(uint16_t *)(base + offset) = value;
			}
			return;
		}
	}
	if ((!(chunk->flags & MMAP_WRITE) || (chunk->flags & MMAP_FUNC_NULL)) && chunk->write_16) {
		chunk->write_16(offset, context, value);
	}
}

void  interp_write_map_8(uint32_t address, void *context, uint8_t value, void *data)
{
	const memmap_chunk *chunk = data;
	cpu_options * opts = *(cpu_options **)context;
	if (address < chunk->start || address >= chunk->end)
	{
		const memmap_chunk *map_end = opts->memmap + opts->memmap_chunks;
		for (chunk++; chunk < map_end; chunk++)
		{
			if (address >= chunk->start && address < chunk->end) {
				break;
			}
		}
		if (chunk == map_end) {
			return;
		}
	}
	uint32_t offset = address & chunk->mask;
	if (chunk->shift) {
		uint32_t low_bit = offset & 1;
		offset &= ~1;
		if (chunk->shift > 0) {
			offset <<= chunk->shift;
		} else {
			offset >>= -chunk->shift;
		}
		offset |= low_bit;
	}
	if (chunk->flags & MMAP_WRITE) {
		uint8_t *base;
		if (chunk->flags & MMAP_PTR_IDX) {
			uint8_t ** mem_pointers = (uint8_t**)(opts->mem_ptr_off + (uint8_t *)context);
			base = mem_pointers[chunk->ptr_index];
		} else {
			base = chunk->buffer;
		}
		if (base) {
			if ((chunk->flags & MMAP_ONLY_ODD) || (chunk->flags & MMAP_ONLY_EVEN)) {
				if (address & 1) {
					if (chunk->flags & MMAP_ONLY_EVEN) {
						return;
					}
				} else if (chunk->flags & MMAP_ONLY_ODD) {
					return;
				}
				offset /= 2;
			} else if(opts->byte_swap) {
				offset ^= 1;
			}
			base[offset] = value;
			return;
		}
	}
	if ((!(chunk->flags & MMAP_WRITE) || (chunk->flags & MMAP_FUNC_NULL)) && chunk->write_8) {
		chunk->write_8(offset, context, value);
	}
}

interp_read_16 get_interp_read_16(void *context, cpu_options *opts, uint32_t start, uint32_t end, void **data_out)
{
	const memmap_chunk *chunk;
	for (chunk = opts->memmap; chunk < opts->memmap + opts->memmap_chunks; chunk++)
	{
		if (chunk->end > start && chunk->start < end) {
			break;
		}
	}
	if (chunk == opts->memmap + opts->memmap_chunks) {
		*data_out = (void *)(uintptr_t)0xFFFF;
		return interp_read_fixed_16;
	}
	if (chunk->end < end || chunk->start > start || chunk->shift) {
		goto use_map;
	}
	if (chunk->flags & MMAP_READ) {
		if ((chunk->flags & (MMAP_ONLY_ODD|MMAP_ONLY_EVEN|MMAP_FUNC_NULL))) {
			goto use_map;
		}
		if (!chunk->mask && !(chunk->flags & ~MMAP_READ)) {
			uintptr_t value = *(uint16_t *)chunk->buffer;
			*data_out = (void *)value;
			return interp_read_fixed_16;
		}
		if ((chunk->mask & 0xFFFF) != 0xFFFF) {
			goto use_map;
		}
		if (chunk->flags & MMAP_PTR_IDX) {
			if (chunk->mask != 0xFFFF && start > 0) {
				goto use_map;
			}
			*data_out = (void *)(chunk->ptr_index + (void **)(((char *)context) + opts->mem_ptr_off));
			return interp_read_indexed_16;
		} else {
			*data_out = (start & chunk->mask) + (uint8_t *)chunk->buffer;
			return interp_read_direct_16;
		}
	}
	if (chunk->read_16 && chunk->mask == opts->address_mask) {
#ifdef __EMSCRIPTEN__
		*data_out = chunk->read_16;
		return interp_read_func_16;
#else
		*data_out = NULL;
		//This is not safe for all calling conventions due to the extra param
		//but should work for the ones we actually care about except WASM
		return (interp_read_16)chunk->read_16;
#endif
	}
use_map:
	*data_out = (void *)chunk;
	return interp_read_map_16;
}

interp_read_8 get_interp_read_8(void *context, cpu_options *opts, uint32_t start, uint32_t end, void **data_out)
{
	const memmap_chunk *chunk;
	for (chunk = opts->memmap; chunk < opts->memmap + opts->memmap_chunks; chunk++)
	{
		if (chunk->end > start && chunk->start < end) {
			break;
		}
	}
	if (chunk == opts->memmap + opts->memmap_chunks) {
		*data_out = (void *)(uintptr_t)0xFFFF;
		return interp_read_fixed_8;
	}
	if (chunk->end != end || chunk->start != start || chunk->shift) {
		goto use_map;
	}
	if (chunk->flags & MMAP_READ) {
		if ((chunk->flags & (MMAP_ONLY_ODD|MMAP_ONLY_EVEN|MMAP_FUNC_NULL)) || !opts->byte_swap) {
			goto use_map;
		}
		if (!chunk->mask && !(chunk->flags & ~MMAP_READ)) {
			uintptr_t value = *(uint8_t *)chunk->buffer;
			*data_out = (void *)value;
			return interp_read_fixed_8;
		}
		if ((chunk->mask & 0xFFFF) != 0xFFFF) {
			goto use_map;
		}
		if (chunk->flags & MMAP_PTR_IDX) {
			if (chunk->mask != 0xFFFF && start > 0) {
				goto use_map;
			}
			*data_out = (void *)(chunk->ptr_index + (void **)(((char *)context) + opts->mem_ptr_off));
			return interp_read_indexed_8;
		} else {
			*data_out = (start & chunk->mask) + (uint8_t *)chunk->buffer;
			return interp_read_direct_8;
		}
	}
	if (chunk->read_8 && chunk->mask == opts->address_mask) {
#ifdef __EMSCRIPTEN__
		*data_out = chunk->read_8;
		return interp_read_func_8;
#else
		*data_out = NULL;
		//This is not safe for all calling conventions due to the extra param
		//but should work for the ones we actually care about except WASM
		return (interp_read_8)chunk->read_8;
#endif
	}
use_map:
	*data_out = (void *)chunk;
	return interp_read_map_8;
}

interp_write_16 get_interp_write_16(void *context, cpu_options *opts, uint32_t start, uint32_t end, void **data_out)
{
	const memmap_chunk *chunk;
	for (chunk = opts->memmap; chunk < opts->memmap + opts->memmap_chunks; chunk++)
	{
		if (chunk->end > start && chunk->start < end) {
			break;
		}
	}
	if (chunk == opts->memmap + opts->memmap_chunks) {
		*data_out = NULL;
		return interp_write_ignored_16;
	}
	if (chunk->end != end || chunk->start != start || chunk->shift) {
		goto use_map;
	}
	if (chunk->flags & MMAP_WRITE) {
		if ((chunk->flags & (MMAP_ONLY_ODD|MMAP_ONLY_EVEN|MMAP_FUNC_NULL)) || (chunk->mask & 0xFFFF) != 0xFFFF) {
			goto use_map;
		}
		if (chunk->flags & MMAP_PTR_IDX) {
			if (chunk->mask != 0xFFFF && start > 0) {
				goto use_map;
			}
			*data_out = (void *)(chunk->ptr_index + (void **)(((char *)context) + opts->mem_ptr_off));
			return interp_write_indexed_16;
		} else {
			*data_out = (start & chunk->mask) + (uint8_t *)chunk->buffer;
			return interp_write_direct_16;
		}
	}
	if (chunk->write_16 && chunk->mask == opts->address_mask) {
#ifdef __EMSCRIPTEN__
		*data_out = chunk->write_16;
		return interp_write_func_16;
#else
		*data_out = NULL;
		//This is not safe for all calling conventions due to the extra param
		//but should work for the ones we actually care about except WASM
		return (interp_write_16)chunk->write_16;
#endif
	}
use_map:
	*data_out = (void *)chunk;
	return interp_write_map_16;
}

interp_write_8 get_interp_write_8(void *context, cpu_options *opts, uint32_t start, uint32_t end, void **data_out)
{
	const memmap_chunk *chunk;
	for (chunk = opts->memmap; chunk < opts->memmap + opts->memmap_chunks; chunk++)
	{
		if (chunk->end > start && chunk->start < end) {
			break;
		}
	}
	if (chunk == opts->memmap + opts->memmap_chunks) {
		*data_out = NULL;
		return interp_write_ignored_8;
	}
	if (chunk->end != end || chunk->start != start || chunk->shift) {
		goto use_map;
	}
	if (chunk->flags & MMAP_WRITE) {
		if ((chunk->flags & (MMAP_ONLY_ODD|MMAP_ONLY_EVEN|MMAP_FUNC_NULL))
			|| (chunk->mask & 0xFFFF) != 0xFFFF || !opts->byte_swap
		) {
			goto use_map;
		}
		if (chunk->flags & MMAP_PTR_IDX) {
			if (chunk->mask != 0xFFFF && start > 0) {
				goto use_map;
			}
			*data_out = (void *)(chunk->ptr_index + (void **)(((char *)context) + opts->mem_ptr_off));
			return interp_write_indexed_8;
		} else {
			*data_out = (start & chunk->mask) + (uint8_t *)chunk->buffer;
			return interp_write_direct_8;
		}
	}
	if (chunk->write_8 && chunk->mask == opts->address_mask) {
#ifdef __EMSCRIPTEN__
		*data_out = chunk->write_8;
		return interp_write_func_8;
#else
		*data_out = NULL;
		//This is not safe for all calling conventions due to the extra param
		//but should work for the ones we actually care about
		return (interp_write_8)chunk->write_8;
#endif
	}
use_map:
	*data_out = (void *)chunk;
	return interp_write_map_8;
}
