#include <string.h>
#include <stdlib.h>
#if defined(X86_32) || defined(X86_64)
#include "gen_x86.h"
#endif
#ifdef SH2_DEBUG_LOG
#include "sh2_decode.h"
#endif

#ifdef DO_DEBUG_PRINT
#define dprintf printf
#else
#define dprintf
#endif

uint8_t sh2_read_external_8(uint32_t address, sh2_context *sh2)
{
	return read_byte_cycles(address, (void**)sh2->mem_pointers, &sh2->opts->gen, sh2, &sh2->cycles);
}

uint16_t sh2_read_external_16(uint32_t address, sh2_context *sh2)
{
	uint16_t ret = read_word_cycles(address, (void**)sh2->mem_pointers, &sh2->opts->gen, sh2, &sh2->cycles);
	/*if (address == sh2->pc) {
		uint8_t is_main = sh2 == ((sh2_context **)sh2->system)[1];
		printf("%s SH2 fetch16: %06X: %04X\n", is_main ? "Main" : "Sub", address, ret);
	}*/
	return ret;
}

uint32_t sh2_read_external_32(uint32_t address, sh2_context *sh2)
{
	uint32_t ret = read_word_cycles(address, (void**)sh2->mem_pointers, &sh2->opts->gen, sh2, &sh2->cycles) << 16;
	ret |= read_word_cycles(address | 2, (void**)sh2->mem_pointers, &sh2->opts->gen, sh2, &sh2->cycles);
	/*if (address == sh2->pc) {
		uint8_t is_main = sh2 == ((sh2_context **)sh2->system)[1];
		printf("%s SH2 fetch32: %06X: %04X %04X\n", is_main ? "Main" : "Sub", address, ret >> 16, ret & 0xFFFF);
	}*/
	return ret;
}

uint32_t sh2_read_external_32_native_wrapper(uint32_t address, sh2_context *sh2)
{
	uint32_t ret = sh2->read16[1](address, sh2) << 16;
	ret |= sh2->read16[1](address | 2, sh2);
	/*if (address == sh2->pc) {
		uint8_t is_main = sh2 == ((sh2_context **)sh2->system)[1];
		printf("%s SH2 fetch32: %06X: %04X %04X\n", is_main ? "Main" : "Sub", address, ret >> 16, ret & 0xFFFF);
	}*/
	return ret;
}

void sh2_write_external_8(uint32_t address, sh2_context *sh2, uint8_t value)
{
	write_byte_cycles(address, value, (void**)sh2->mem_pointers, &sh2->opts->gen, sh2, &sh2->cycles);
}

void sh2_write_external_16(uint32_t address, sh2_context *sh2, uint16_t value)
{
	write_word_cycles(address, value, (void**)sh2->mem_pointers, &sh2->opts->gen, sh2, &sh2->cycles);
}

void sh2_write_external_32(uint32_t address, sh2_context *sh2, uint32_t value)
{
	write_word_cycles(address, value >> 16, (void**)sh2->mem_pointers, &sh2->opts->gen, sh2, &sh2->cycles);
	write_word_cycles(address | 2, value, (void**)sh2->mem_pointers, &sh2->opts->gen, sh2, &sh2->cycles);
}

void sh2_write_external_32_native_wrapper(uint32_t address, sh2_context *sh2, uint32_t value)
{
	sh2->write16[1](address, sh2, value >> 16);
	sh2->write16[1](address | 2, sh2, value);
}

void sh2_generic_burst_read(uint32_t address, sh2_context *sh2, uint32_t *dst)
{
	memmap_chunk const *chunk = find_map_chunk(address, &sh2->opts->gen, 0, NULL);
	if (chunk) {
		if (chunk->burst_cycles) {
			sh2->cycles += chunk->burst_cycles * sh2->opts->gen.clock_divider;
		}
		uint32_t offset = address & chunk->mask;
		if (chunk->flags & MMAP_READ) {
			uint8_t *base;
			if (chunk->flags & MMAP_PTR_IDX) {
				base = sh2->mem_pointers[chunk->ptr_index];
			} else {
				base = chunk->buffer;
			}
			if (base) {
				uint16_t *ptr = (uint16_t *)(base + offset);
				*(dst++) = *ptr << 16 | *(ptr+1);
				ptr += 2;
				*(dst++) = *ptr << 16 | *(ptr+1);
				ptr += 2;
				*(dst++) = *ptr << 16 | *(ptr+1);
				ptr += 2;
				*(dst++) = *ptr << 16 | *(ptr+1);
				ptr += 2;
				return;
			}
		}
		if ((!(chunk->flags & MMAP_READ) || (chunk->flags & MMAP_FUNC_NULL)) && chunk->read_16) {
			uint32_t val = chunk->read_16(offset, sh2) << 16;
			val |= chunk->read_16(offset | 2, sh2);
			*(dst++) = val;
			val = chunk->read_16(offset | 4, sh2) << 16;
			val |= chunk->read_16(offset | 6, sh2);
			*(dst++) = val;
			val = chunk->read_16(offset | 8, sh2) << 16;
			val |= chunk->read_16(offset | 10, sh2);
			*(dst++) = val;
			val = chunk->read_16(offset | 12, sh2) << 16;
			val |= chunk->read_16(offset | 14, sh2);
			*(dst++) = val;
			return;
		}
	}
	memset(dst, 0xFF, 16);
}

uint32_t sh2_cache_fill(uint32_t address, sh2_context *sh2, uint32_t tag, uint32_t way_off)
{
	uint32_t lru = sh2->cache_lru[way_off];
	if (sh2->cache_tw) {
		lru &= 0x10;
	}
	if (lru & 0xB0) {
		if ((lru & 0x150) == 0x10) {
			sh2->cache_lru[way_off] |= 0x140; //way 2 LRU update
			sh2->cache_lru[way_off] &= 0x3E0;
			sh2->cache_address[0x80 | way_off] = tag;
			sh2->burst_read(address & ~0xF, sh2, sh2->cache + 0x200 + (way_off << 2));
			return sh2->cache[0x200 | (address >> 2 & 0xFF)];
		} else if ((lru & 0x380) == 0x380) {
			sh2->cache_lru[way_off] &= 0x70; //way 0 LRU update
			sh2->cache_address[way_off] = tag;
			sh2->burst_read(address & ~0xF, sh2, sh2->cache + (way_off << 2));
			return sh2->cache[address >> 2 & 0xFF];
		} else {
			sh2->cache_lru[way_off] |= 0x200; //way 1 LRU update
			sh2->cache_lru[way_off] &= 0x390;
			sh2->cache_address[0x40 | way_off] = tag;
			sh2->burst_read(address & ~0xF, sh2, sh2->cache + 0x100 + (way_off << 2));
			return sh2->cache[0x100 | (address >> 2 & 0xFF)];
		}
	} else {
		sh2->cache_lru[way_off] |= 0xB0; //way 3 LRU update
		sh2->cache_address[0xC0 | way_off] = tag;
		sh2->burst_read(address & ~0xF, sh2, sh2->cache + 0x300 + (way_off << 2));
		return sh2->cache[0x300 | (address >> 2 & 0xFF)];
	}
}

uint8_t sh2_cached_read_8(uint32_t address, sh2_context *sh2)
{
	uint32_t tag = (address & 0x1FFFFC00) | 4;
	uint32_t way_off = (address >> 4 & 0x3F) | 0xC0;
	uint32_t ret;
	if (sh2->cache_address[way_off] == tag) {
		way_off &= 0x3F;
		sh2->cache_lru[way_off] |= 0xB0; //way 3 LRU update
		ret = sh2->cache[0x300 | (address >> 2 & 0xFF)];
		goto hit;
	} else {
		way_off -= 0x40;
		if (sh2->cache_address[way_off] == tag) {
			way_off &= 0x3F;
			sh2->cache_lru[way_off] |= 0x140; //way 2 LRU update
			sh2->cache_lru[way_off] &= 0x3E0;
			ret = sh2->cache[0x200 | (address >> 2 & 0xFF)];
			goto hit;
		} else {
			way_off -= 0x40;
			if (sh2->cache_address[way_off] == tag) {
				way_off &= 0x3F;
				sh2->cache_lru[way_off] |= 0x200; //way 1 LRU update
				sh2->cache_lru[way_off] &= 0x390;
				ret = sh2->cache[0x100 | (address >> 2 & 0xFF)];
				goto hit;
			} else {
				way_off &= 0x3F;
				if (sh2->cache_address[way_off] == tag) {
					sh2->cache_lru[way_off] &= 0x70; //way 0 LRU update
					ret = sh2->cache[address >> 2 & 0xFF];
					goto hit;
				}
			}
		}
	}
	//cache miss
	if (address == sh2->pc) {
		//TODO: more definitive way to distinguish instruction fetch
		if (sh2->cache_id) {
			return sh2->read8[1](address, sh2);
		}
	} else if (sh2->cache_od) {
		return sh2->read8[1](address, sh2);
	}
	ret = sh2_cache_fill(address, sh2, tag, way_off);
hit:
	if (!(address & 2)) {
		ret >>= 16;
	}
	if (address & 1) {
		return ret;
	}
	return ret >> 8;
}

uint16_t sh2_cached_read_16(uint32_t address, sh2_context *sh2)
{
	uint32_t tag = (address & 0x1FFFFC00) | 4;
	uint32_t way_off = (address >> 4 & 0x3F) | 0xC0;
	uint32_t ret;
	if (sh2->cache_address[way_off] == tag) {
		way_off &= 0x3F;
		sh2->cache_lru[way_off] |= 0xB0; //way 3 LRU update
		ret = sh2->cache[0x300 | (address >> 2 & 0xFF)];
		goto hit;
	} else {
		way_off -= 0x40;
		if (sh2->cache_address[way_off] == tag) {
			way_off &= 0x3F;
			sh2->cache_lru[way_off] |= 0x140; //way 2 LRU update
			sh2->cache_lru[way_off] &= 0x3E0;
			ret = sh2->cache[0x200 | (address >> 2 & 0xFF)];
			goto hit;
		} else {
			way_off -= 0x40;
			if (sh2->cache_address[way_off] == tag) {
				way_off &= 0x3F;
				sh2->cache_lru[way_off] |= 0x200; //way 1 LRU update
				sh2->cache_lru[way_off] &= 0x390;
				ret = sh2->cache[0x100 | (address >> 2 & 0xFF)];
				goto hit;
			} else {
				way_off &= 0x3F;
				if (sh2->cache_address[way_off] == tag) {
					sh2->cache_lru[way_off] &= 0x70; //way 0 LRU update
					ret = sh2->cache[address >> 2 & 0xFF];
					goto hit;
				}
			}
		}
	}
	//cache miss
	if (address == sh2->pc) {
		//TODO: more definitive way to distinguish instruction fetch
		if (sh2->cache_id) {
			return sh2->read16[1](address, sh2);
		}
	} else if (sh2->cache_od) {
		return sh2->read16[1](address, sh2);
	}
	ret = sh2_cache_fill(address, sh2, tag, way_off);
hit:
	if (address & 2) {
		return ret;
	}
	return ret >> 16;
}

uint32_t sh2_cached_read_32(uint32_t address, sh2_context *sh2)
{
	uint32_t tag = (address & 0x1FFFFC00) | 4;
	uint32_t way_off = (address >> 4 & 0x3F) | 0xC0;
	if (sh2->cache_address[way_off] == tag) {
		way_off &= 0x3F;
		sh2->cache_lru[way_off] |= 0xB0; //way 3 LRU update
		return sh2->cache[0x300 | (address >> 2 & 0xFF)];
	} else {
		way_off -= 0x40;
		if (sh2->cache_address[way_off] == tag) {
			way_off &= 0x3F;
			sh2->cache_lru[way_off] |= 0x140; //way 2 LRU update
			sh2->cache_lru[way_off] &= 0x3E0;
			return sh2->cache[0x200 | (address >> 2 & 0xFF)];
		} else {
			way_off -= 0x40;
			if (sh2->cache_address[way_off] == tag) {
				way_off &= 0x3F;
				sh2->cache_lru[way_off] |= 0x200; //way 1 LRU update
				sh2->cache_lru[way_off] &= 0x390;
				return sh2->cache[0x100 | (address >> 2 & 0xFF)];
			} else {
				way_off &= 0x3F;
				if (sh2->cache_address[way_off] == tag) {
					sh2->cache_lru[way_off] &= 0x70; //way 0 LRU update
					return sh2->cache[address >> 2 & 0xFF];
				}
			}
		}
	}
	//cache miss
	if (address == sh2->pc) {
		//TODO: more definitive way to distinguish instruction fetch
		if (sh2->cache_id) {
			return sh2->read32[1](address, sh2);
		}
	} else if (sh2->cache_od) {
		return sh2->read32[1](address, sh2);
	}
	return sh2_cache_fill(address, sh2, tag, way_off);
}

void sh2_cached_write_8(uint32_t address, sh2_context *sh2, uint8_t value)
{
	uint32_t tag = (address & 0x1FFFFC00) | 4;
	uint32_t way_off = (address >> 4 & 0x3F) | 0xC0;
	if (sh2->cache_address[way_off] == tag) {
		way_off &= 0x3F;
		sh2->cache_lru[way_off] |= 0xB0; //way 3 LRU update
		way_off = 0x300 | (address >> 2 & 0xFF);
		goto hit;
	} else {
		way_off -= 0x40;
		if (sh2->cache_address[way_off] == tag) {
			way_off &= 0x3F;
			sh2->cache_lru[way_off] |= 0x140; //way 2 LRU update
			sh2->cache_lru[way_off] &= 0x3E0;
			way_off = 0x200 | (address >> 2 & 0xFF);
			goto hit;
		} else {
			way_off -= 0x40;
			if (sh2->cache_address[way_off] == tag) {
				way_off &= 0x3F;
				sh2->cache_lru[way_off] |= 0x200; //way 1 LRU update
				sh2->cache_lru[way_off] &= 0x390;
				way_off = 0x100 | (address >> 2 & 0xFF);
				goto hit;
			} else {
				way_off &= 0x3F;
				if (sh2->cache_address[way_off] == tag) {
					sh2->cache_lru[way_off] &= 0x70; //way 0 LRU update
					way_off = address >> 2 & 0xFF;
					goto hit;
				}
			}
		}
	}
	sh2->write8[1](address, sh2, value);
	return;
	uint32_t mask;
hit:
	mask = 0xFF000000 >> ((address & 3) << 3);
	uint32_t extended = value << ((3 - (address & 3)) << 3);
	sh2->cache[way_off] &= ~mask;
	sh2->cache[way_off] |= extended;
	sh2->write8[1](address, sh2, value);
}

void sh2_cached_write_16(uint32_t address, sh2_context *sh2, uint16_t value)
{
	uint32_t tag = (address & 0x1FFFFC00) | 4;
	uint32_t way_off = (address >> 4 & 0x3F) | 0xC0;
	if (sh2->cache_address[way_off] == tag) {
		way_off &= 0x3F;
		sh2->cache_lru[way_off] |= 0xB0; //way 3 LRU update
		way_off = 0x300 | (address >> 2 & 0xFF);
		goto hit;
	} else {
		way_off -= 0x40;
		if (sh2->cache_address[way_off] == tag) {
			way_off &= 0x3F;
			sh2->cache_lru[way_off] |= 0x140; //way 2 LRU update
			sh2->cache_lru[way_off] &= 0x3E0;
			way_off = 0x200 | (address >> 2 & 0xFF);
			goto hit;
		} else {
			way_off -= 0x40;
			if (sh2->cache_address[way_off] == tag) {
				way_off &= 0x3F;
				sh2->cache_lru[way_off] |= 0x200; //way 1 LRU update
				sh2->cache_lru[way_off] &= 0x390;
				way_off = 0x100 | (address >> 2 & 0xFF);
				goto hit;
			} else {
				way_off &= 0x3F;
				if (sh2->cache_address[way_off] == tag) {
					sh2->cache_lru[way_off] &= 0x70; //way 0 LRU update
					way_off = address >> 2 & 0xFF;
					goto hit;
				}
			}
		}
	}
	sh2->write16[1](address, sh2, value);
	return;
hit:
	if (address & 2) {
		sh2->cache[way_off] &= 0xFFFF0000;
		sh2->cache[way_off] |= value;
	} else {
		sh2->cache[way_off] &= 0x0000FFFF;
		sh2->cache[way_off] |= value << 16;
	}
	sh2->write16[1](address, sh2, value);
}

void sh2_cached_write_32(uint32_t address, sh2_context *sh2, uint32_t value)
{
	uint32_t tag = (address & 0x1FFFFC00) | 4;
	uint32_t way_off = (address >> 4 & 0x3F) | 0xC0;
	if (sh2->cache_address[way_off] == tag) {
		way_off &= 0x3F;
		sh2->cache_lru[way_off] |= 0xB0; //way 3 LRU update
		sh2->cache[0x300 | (address >> 2 & 0xFF)] = value;
	} else {
		way_off -= 0x40;
		if (sh2->cache_address[way_off] == tag) {
			way_off &= 0x3F;
			sh2->cache_lru[way_off] |= 0x140; //way 2 LRU update
			sh2->cache_lru[way_off] &= 0x3E0;
			sh2->cache[0x200 | (address >> 2 & 0xFF)] = value;
		} else {
			way_off -= 0x40;
			if (sh2->cache_address[way_off] == tag) {
				way_off &= 0x3F;
				sh2->cache_lru[way_off] |= 0x200; //way 1 LRU update
				sh2->cache_lru[way_off] &= 0x390;
				sh2->cache[0x100 | (address >> 2 & 0xFF)] = value;
			} else {
				way_off &= 0x3F;
				if (sh2->cache_address[way_off] == tag) {
					sh2->cache_lru[way_off] &= 0x70; //way 0 LRU update
					sh2->cache[address >> 2 & 0xFF] = value;
				}
			}
		}
	}
	sh2->write32[1](address, sh2, value);
}

uint8_t sh2_read_cache_8(uint32_t address, sh2_context *sh2)
{
	uint32_t val = sh2->cache[address >> 2 & 0x3FF];
	if (!(address & 2)) {
		val >>= 16;
	}
	if (!(address & 1)) {
		val >>= 8;
	}
	return val;
}

uint16_t sh2_read_cache_16(uint32_t address, sh2_context *sh2)
{
	uint32_t val = sh2->cache[address >> 2 & 0x3FF];
	if (!(address & 2)) {
		val >>= 16;
	}
	return val;
}

uint32_t sh2_read_cache_32(uint32_t address, sh2_context *sh2)
{
	return sh2->cache[address >> 2 & 0x3FF];
}

void sh2_write_cache_8(uint32_t address, sh2_context *sh2, uint8_t value)
{
	uint32_t val = sh2->cache[address >> 2 & 0x3FF];
	switch (address & 3)
	{
	case 0:
		val &= 0x00FFFFFF;
		val |= value << 24;
		break;
	case 1:
		val &= 0xFF00FFFF;
		val |= value << 16;
		break;
	case 2:
		val &= 0xFFFF00FF;
		val |= value << 8;
		break;
	case 3:
		val &= 0xFFFFFF00;
		val |= value;
		break;
	}
	sh2->cache[address >> 2 & 0x3FF] = val;
}

void sh2_write_cache_16(uint32_t address, sh2_context *sh2, uint16_t value)
{
	uint32_t val = sh2->cache[address >> 2 & 0x3FF];
	if (address & 2) {
		val &= 0xFFFF0000;
		val |= value;
	} else {
		val &= 0x0000FFFF;
		val |= value << 16;
	}
	sh2->cache[address >> 2 & 0x3FF] = val;
}

void sh2_write_cache_32(uint32_t address, sh2_context *sh2, uint32_t value)
{
	sh2->cache[address >> 2 & 0x3FF] = value;
}

uint8_t sh2_read_addrarr_8(uint32_t address, sh2_context *sh2)
{
	uint32_t entry = address >> 4 & 0x3F;
	uint32_t val = sh2->cache_address[sh2->current_way_off | entry] | sh2->cache_lru[entry];
	if (!(address & 2)) {
		val >>= 16;
	}
	if (!(address & 1)) {
		val >>= 8;
	}
	return val;
}

uint16_t sh2_read_addrarr_16(uint32_t address, sh2_context *sh2)
{
	uint32_t entry = address >> 4 & 0x3F;
	uint32_t val = sh2->cache_address[sh2->current_way_off | entry] | sh2->cache_lru[entry];
	if (!(address & 2)) {
		val >>= 16;
	}
	return val;
}

uint32_t sh2_read_addrarr_32(uint32_t address, sh2_context *sh2)
{
	uint32_t entry = address >> 4 & 0x3F;
	return sh2->cache_address[sh2->current_way_off | entry] | sh2->cache_lru[entry];
}

void sh2_write_addrarr_8(uint32_t address, sh2_context *sh2, uint8_t value)
{
	//Do byte writes even work?
	uint32_t entry = address >> 4 & 0x3F;
	sh2->cache_address[sh2->current_way_off | entry] = address & 0x1FFFFC04;
	if (address & 2) {
		if (address & 1) {
			sh2->cache_lru[entry] &= 0x300;
			sh2->cache_lru[entry] |= 0x0F0 & value;
		} else {
			sh2->cache_lru[entry] &= 0x0F0;
			sh2->cache_lru[entry] |= 0x300 & value << 8;
		}
	}
}

void sh2_write_addrarr_16(uint32_t address, sh2_context *sh2, uint16_t value)
{
	//Do word writes even work?
	uint32_t entry = address >> 4 & 0x3F;
	sh2->cache_address[sh2->current_way_off | entry] = address & 0x1FFFFC04;
	if (address & 2) {
		sh2->cache_lru[entry] = value & 0x3F0;
	}
}

void sh2_write_addrarr_32(uint32_t address, sh2_context *sh2, uint32_t value)
{
	uint32_t entry = address >> 4 & 0x3F;
	sh2->cache_address[sh2->current_way_off | entry] = address & 0x1FFFFC04;
	sh2->cache_lru[entry] = value & 0x3F0;
}

void sh2_write_purge(uint32_t address, sh2_context *sh2)
{
	uint32_t tag = address & 0x1FFFFC00;
	for (uint32_t way_off = address >> 4 & 0x3F; way_off < 0x100; way_off += 0x40)
	{
		if ((sh2->cache_address[way_off] & 0x1FFFFC00) == tag) {
			//clear valid bit
			sh2->cache_address[way_off] &= ~4;
		}
	}
}

void sh2_write_purge_8(uint32_t address, sh2_context *sh2, uint8_t value)
{
	sh2_write_purge(address, sh2);
}

void sh2_write_purge_16(uint32_t address, sh2_context *sh2, uint16_t value)
{
	sh2_write_purge(address, sh2);
}

void sh2_write_purge_32(uint32_t address, sh2_context *sh2, uint32_t value)
{
	sh2_write_purge(address, sh2);
}

uint8_t sh2_read_unmapped_8(uint32_t address, sh2_context *sh2)
{
	return 0xFF;
}

uint16_t sh2_read_unmapped_16(uint32_t address, sh2_context *sh2)
{
	return 0xFFFF;
}

uint32_t sh2_read_unmapped_32(uint32_t address, sh2_context *sh2)
{
	return 0xFFFFFFFF;
}

void sh2_write_unmapped_8(uint32_t address, sh2_context *sh2, uint8_t value)
{
}

void sh2_write_unmapped_16(uint32_t address, sh2_context *sh2, uint16_t value)
{
}

void sh2_write_unmapped_32(uint32_t address, sh2_context *sh2, uint32_t value)
{
}

void init_sh2_opts(sh2_options *opts, const memmap_chunk *chunks, uint32_t num_chunks)
{
	memset(opts, 0, sizeof(*opts));
	opts->gen.memmap = chunks;
	opts->gen.memmap_chunks = num_chunks;
	opts->gen.address_mask = 0x7FFFFFF;
	opts->gen.max_address = 0x8000000;
	opts->gen.clock_divider = 7;
	opts->gen.byte_swap = 1;
#if defined(X86_32) || defined(X86_64)
	opts->gen.address_size = SZ_D;
	opts->gen.mem_ptr_off = offsetof(sh2_context, mem_pointers);
	opts->gen.cycles_off = offsetof(sh2_context, cycles);
	opts->gen.cycles = -1;
	opts->gen.limit = -1;
	init_code_info(&opts->gen.code);
	opts->gen.code.stack_off = 0;
#endif
}

sh2_context *init_sh2_context(sh2_options *opts, sh2_fun *next_int)
{
	char *tmp = calloc(1, sizeof(sh2_context) + 16);
	intptr_t align_off = 0x10 - (((intptr_t)tmp + offsetof(sh2_context, cache)) & 0xF);
	tmp[align_off - 1] = align_off;
	sh2_context *sh2 = (sh2_context *)(tmp + align_off);
	sh2->opts = opts;
	sh2->need_reset = 1;
	sh2->calc_next_interrupt = next_int;
	//cache starts disabled, so first 2 memory spaces use the uncached external space
#if defined(X86_32) || defined(X86_64)
	opts->gen.code.stack_off = 0;
	sh2->write16[0] = sh2->write16[1] = (sh2_write16 *)gen_mem_fun(&opts->gen, opts->gen.memmap, opts->gen.memmap_chunks, WRITE_16, NULL, 1);
	opts->gen.code.stack_off = 0;
	sh2->read16[0] = sh2->read16[1] = (sh2_read16 *)gen_mem_fun(&opts->gen, opts->gen.memmap, opts->gen.memmap_chunks, READ_16, NULL, 1);
	opts->gen.code.stack_off = 0;
	sh2->write8[0] = sh2->write8[1] = (sh2_write8 *)gen_mem_fun(&opts->gen, opts->gen.memmap, opts->gen.memmap_chunks, WRITE_8, NULL, 1);
	opts->gen.code.stack_off = 0;
	sh2->read8[0] = sh2->read8[1] = (sh2_read8 *)gen_mem_fun(&opts->gen, opts->gen.memmap, opts->gen.memmap_chunks, READ_8, NULL, 1);
	sh2->burst_read = (sh2_burst_read *)gen_burst_read(&opts->gen, opts->gen.memmap, opts->gen.memmap_chunks);
	sh2->write32[0] = sh2->write32[1] = sh2_write_external_32_native_wrapper;
	sh2->read32[0] = sh2->read32[1] = sh2_read_external_32_native_wrapper;
#else
	sh2->write32[0] = sh2->write32[1] = sh2_write_external_32;
	sh2->read32[0] = sh2->read32[1] = sh2_read_external_32;
	sh2->write16[0] = sh2->write16[1] = sh2_write_external_16;
	sh2->read16[0] = sh2->read16[1] = sh2_read_external_16;
	sh2->write8[0] = sh2->write8[1] = sh2_write_external_8;
	sh2->read8[0] = sh2->read8[1] = sh2_read_external_8;
	sh2->burst_read = sh2_generic_burst_read;
#endif
	//associative purge space
	sh2->write32[2] = sh2_write_purge_32;
	sh2->write16[2] = sh2_write_purge_16;
	sh2->write8[2] = sh2_write_purge_8;
	sh2->read32[2] = sh2_read_unmapped_32;
	sh2->read16[2] = sh2_read_unmapped_16;
	sh2->read8[2] = sh2_read_unmapped_8;
	//address array space
	sh2->write32[3] = sh2_write_addrarr_32;
	sh2->write16[3] = sh2_write_addrarr_16;
	sh2->write8[3] = sh2_write_addrarr_8;
	sh2->read32[3] = sh2_read_addrarr_32;
	sh2->read16[3] = sh2_read_addrarr_16;
	sh2->read8[3] = sh2_read_addrarr_8;
	for (int i = 4; i < 8; i++)
	{
		if (i == 6) {
			continue;
		}
		sh2->write32[i] = sh2_write_unmapped_32;
		sh2->write16[i] = sh2_write_unmapped_16;
		sh2->write8[i] = sh2_write_unmapped_8;
		sh2->read32[i] = sh2_read_unmapped_32;
		sh2->read16[i] = sh2_read_unmapped_16;
		sh2->read8[i] = sh2_read_unmapped_8;
	}
	sh2->write32[6] = sh2_write_cache_32;
	sh2->write16[6] = sh2_write_cache_16;
	sh2->write8[6] = sh2_write_cache_8;
	sh2->read32[6] = sh2_read_cache_32;
	sh2->read16[6] = sh2_read_cache_16;
	sh2->read8[6] = sh2_read_cache_8;
	return sh2;
}

void sh2_free(sh2_context *sh2)
{
	if (!sh2) {
		return;
	}
	char *tmp = (char *)sh2;
	--tmp;
	tmp -= *tmp - 1;
	free(tmp);
}

void sh2_assert_reset(sh2_context *sh2)
{
	sh2->reset = 1;
}

void sh2_clear_reset(sh2_context *sh2)
{
	sh2->need_reset |= sh2->reset;
	sh2->reset = 0;
}

void sh2_set_cache_enabled(sh2_context *sh2, uint8_t enabled)
{
	if (enabled != sh2->cache_enabled) {
		sh2->cache_enabled = enabled;
		if (enabled) {
			sh2->write32[0] = sh2_cached_write_32;
			sh2->write16[0] = sh2_cached_write_16;
			sh2->write8[0] = sh2_cached_write_8;
			sh2->read32[0] = sh2_cached_read_32;
			sh2->read16[0] = sh2_cached_read_16;
			sh2->read8[0] = sh2_cached_read_8;
		} else {
			sh2->write32[0] = sh2->write32[1];
			sh2->write16[0] = sh2->write16[1];
			sh2->write8[0] = sh2->write8[1];
			sh2->read32[0] = sh2->read32[1];
			sh2->read16[0] = sh2->read16[1];
			sh2->read8[0] = sh2->read8[1];
		}
	}
}

void sh2_run(sh2_context *sh2, uint32_t target_cycle)
{
	if (sh2->reset) {
		sh2->cycles = target_cycle;
		return;
	}
	if (target_cycle > sh2->cycles && sh2->need_reset) {
		sh2_reset(sh2);
		sh2->need_reset = 0;
	}
	if (sh2->sleeping) {
		if (sh2->int_cycle < target_cycle) {
			if (sh2->int_cycle > sh2->cycles) {
				sh2->cycles = sh2->int_cycle;
			}
		} else {
			sh2->cycles = target_cycle;
		}
	}
	sh2_execute(sh2, target_cycle);
	sh2->periph_run(sh2);
}

void sh2_sync_cycle(sh2_context *context, uint32_t target_cycle)
{
	context->calc_next_interrupt(context);
}

void sh2_insert_breakpoint(sh2_context *sh2, uint32_t address, sh2_fun *handler)
{
	char buf[MAX_INT_KEY_SIZE];
	sh2->breakpoints = tern_insert_ptr(sh2->breakpoints, tern_int_key(address, buf), handler);
}

void sh2_remove_breakpoint(sh2_context *sh2, uint32_t address)
{
	char buf[MAX_INT_KEY_SIZE];
	tern_delete(&sh2->breakpoints, tern_int_key(address, buf), NULL);
}

#ifdef SH2_DEBUG_LOG
void sh2_debug_log(sh2_context *sh2)
{
	static sh2_context *comp[2];
	static const char *disasm[65536];
	if (!sh2->main) {
		return;
	}
	if (!comp[sh2->main]) {
		comp[sh2->main] = calloc(1, sizeof(sh2_context));
		memcpy(comp[sh2->main], sh2, sizeof(sh2_context));
	}
	sh2_inst inst = sh2_decode(sh2->prefetch_cur);
	if (!disasm[sh2->prefetch_cur]) {
		char buf[128];
		sh2_disasm(buf, inst, sh2->pc, NULL);
		disasm[sh2->prefetch_cur] = strdup(buf);
	}
	printf("%c %X %s %d%d%d%d", sh2->main ? 'M' : 'S', sh2->pc, disasm[sh2->prefetch_cur], sh2->t, sh2->s, sh2->q, sh2->m);
	uint8_t print_gpr[16];
	for (int i = 0; i < 16; i++)
	{
		if (sh2->gpr[i] != comp[sh2->main]->gpr[i]) {
			comp[sh2->main]->gpr[i] = sh2->gpr[i];
			print_gpr[i] = 1;
		} else {
			print_gpr[i] = 0;
		}
	}
	if (inst.src >= SH2_R0 && inst.src <= SH2_DISP_SP) {
		print_gpr[(inst.src - SH2_R0) & 15] = 1;
		if (inst.src >= SH2_IDX_R0_R0 && inst.src <= SH2_IDX_R0_SP) {
			print_gpr[0] = 1;
		}
	}
	if (inst.dst >= SH2_R0 && inst.dst <= SH2_DISP_SP) {
		print_gpr[(inst.dst - SH2_R0) & 15] = 1;
		if (inst.dst >= SH2_IDX_R0_R0 && inst.dst <= SH2_IDX_R0_SP) {
			print_gpr[0] = 1;
		}
	}
	for (int i = 0; i < 16; i++)
	{
		if (print_gpr[i]) {
			printf(" r%d:%X", i, sh2->gpr[i]);
		}
	}
	uint8_t print_mach = 0;
	if (sh2->mach != comp[sh2->main]->mach) {
		print_mach = 1;
		comp[sh2->main]->mach = sh2->mach;
	} else if (inst.src == SH2_MACH || inst.dst == SH2_MACH) {
		print_mach = 1;
	}
	if (print_mach) {
		printf(" mach:%X", sh2->mach);
	}
	uint8_t print_macl = 0;
	if (sh2->macl != comp[sh2->main]->macl) {
		print_macl = 1;
		comp[sh2->main]->macl = sh2->macl;
	} else if (inst.src == SH2_MACL || inst.dst == SH2_MACL) {
		print_macl = 1;
	}
	if (print_macl) {
		printf(" macl:%X", sh2->macl);
	}
	putchar('\n');
}
#endif
