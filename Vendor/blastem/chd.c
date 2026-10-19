#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include "chd.h"
#include "util.h"
#include "lzma/LzmaEnc.h"

uint16_t bswap16(uint16_t in)
{
	return in << 8 | in >> 8;
}

uint32_t bswap32(uint32_t in)
{
	return in << 24 | in >> 24 | (in << 8 & 0xFF0000) | (in >> 8 & 0xFF00);
}

uint64_t bswap64(uint64_t in)
{
	return in << 56 | in >> 56 | (in << 40 & 0xFF000000000000ULL) | (in >> 40 & 0xFF00)
		| (in << 24 & 0xFF0000000000ULL) | (in >> 24 & 0xFF0000) | (in << 8 & 0xFF00000000ULL) | (in >> 8 & 0xFF000000);
}

static void chd_bswap(chd_header *chd)
{
#ifndef BLASTEM_BIG_ENDIAN
	chd->length = bswap32(chd->length);
	chd->version = bswap32(chd->version);
	if (chd->version < 5) {
		chd->v.old.flags = bswap32(chd->v.old.flags);
		chd->v.old.compression = bswap32(chd->v.old.compression);
		//TODO: other <V5 fields if I ever have reason to support <V5 images
	} else if (chd->version == 5) {
		for (int i = 0; i < 4; i++)
		{
			chd->v.v5.compressors[i] = bswap32(chd->v.v5.compressors[i]);
		}
		chd->v.v5.logical_bytes = bswap64(chd->v.v5.logical_bytes);
		chd->v.v5.map_offset = bswap64(chd->v.v5.map_offset);
		chd->v.v5.meta_offset = bswap64(chd->v.v5.meta_offset);
		chd->v.v5.hunk_bytes = bswap32(chd->v.v5.hunk_bytes);
		chd->v.v5.unit_bytes = bswap32(chd->v.v5.unit_bytes);
	}
	
#endif
}

#define DEFAULT_META_STORAGE 8

static uint8_t chd_read_meta(chd *chd, uint64_t meta_offset)
{
	while (meta_offset)
	{
		//TODO: fix this for files >2GB on systems with 32-bit long 
		fseek(chd->f, meta_offset, SEEK_SET);
		uint8_t buf[16];
		if (sizeof(buf) != fread(buf, 1, sizeof(buf), chd->f)) {
			return 0;
		}
		uint8_t flags = buf[4];
		buf[4] = 0;
		chd_meta_list *list = tern_find_ptr(chd->meta, (char *)buf);
		if (!list) {
			list = calloc(1, sizeof(chd_meta_list) + DEFAULT_META_STORAGE * sizeof(chd_meta));
			list->storage = DEFAULT_META_STORAGE;
			chd->meta = tern_insert_ptr(chd->meta, (char *)buf, list);
		}
		if (list->storage == list->num_entries) {
			size_t old_size = sizeof(chd_meta_list) + list->storage * sizeof(chd_meta);
			list->storage *= 2;
			size_t new_size = sizeof(chd_meta_list) + list->storage * sizeof(chd_meta);
			chd_meta_list *tmp = list;
			list = calloc(1, new_size);
			memcpy(list, tmp, old_size);
			memset(((char *)list) + old_size, 0, new_size - old_size);
			tern_insert_ptr(chd->meta, (char *)buf, list);
		}
		uint32_t size = buf[5] << 16 | buf[6] << 8 | buf[7];
		list->entries[list->num_entries].flags = flags;
		list->entries[list->num_entries].data = calloc(1, size + 1);
		if (size != fread(list->entries[list->num_entries++].data, 1, size, chd->f)) {
			return 1;
		}
		meta_offset = 0;
		for (int i = 0; i < sizeof(buf); i++)
		{
			meta_offset <<= 8;
			meta_offset |= buf[i];
		}
	}
	return 1;
}

typedef struct {
	int offset;
	uint64_t bits;
	uint32_t avail_bits;
} bitpos;

static bitpos chd_decode_map_huffman(uint8_t *compressed_map, uint32_t compressed_len, uint8_t *huff_bits, uint8_t *lookup)
{
	uint8_t is_left = 1;
	int cur = 0;
	enum {
		STATE_NORMAL,
		STATE_ONE,
		STATE_RLE
	} state = STATE_NORMAL;
	for (int i = 0; i < 16;)
	{
		uint8_t val;
		if (cur >= compressed_len) {
			return (bitpos){.offset = -1};
		}
		if (is_left) {
			val = compressed_map[cur] >> 4;
			is_left = 0;
		} else {
			val = compressed_map[cur] & 0xF;
			is_left = 1;
			cur++;
		}
		switch (state)
		{
		case STATE_NORMAL:
			if (val == 1) {
				state = STATE_ONE;
			} else {
				huff_bits[i++] = val;
			}
			break;
		case STATE_ONE:
			if (val == 1) {
				huff_bits[i++] = 1;
				state = STATE_NORMAL;
			} else {
				huff_bits[i] = val;
				state = STATE_RLE;
			}
			break;
		case STATE_RLE:
			val += 3 + i;
			for (int j = i + 1; j < val; j++)
			{
				huff_bits[j] = huff_bits[i];
			}
			i = val;
			state = STATE_NORMAL;
			break;
		}
	}
	uint32_t cur_code = 0;
	uint8_t inc = 1;
	for (int i = 8; i > 0; i--)
	{
		for (int j = 0; j < 16; j++)
		{
			if (huff_bits[j] == i) {
				for (uint32_t next = cur_code + inc; cur_code < next; cur_code++)
				{
					lookup[cur_code] = j;
				}
			}
		}
		inc += inc;
	}
	return (bitpos){.offset = cur + !is_left, .bits = is_left ? 0 : (compressed_map[cur] << 12) & 0xFFFF, .avail_bits = is_left ? 0 : 4};
}

static bitpos chd_decode_map_rle(chd *chd, uint8_t *compressed_map, uint32_t compressed_len, bitpos pos, uint8_t *huff_bits, uint8_t *lookup)
{
	int cur = pos.offset;
	if (cur >= compressed_len) {
		return (bitpos){.offset = -1};
	}
	uint32_t bits = pos.bits;
	uint32_t avail_bits = pos.avail_bits;
	enum {
		STATE_NORMAL,
		STATE_RLE4,
		STATE_RLE8_MSB,
		STATE_RLE8_LSB,
	} state = STATE_NORMAL;
	if (chd->hunk_info) {
		free(chd->hunk_info);
	}
	chd->hunk_info = calloc(chd->num_hunks, sizeof(chd_hunk_info));
	int rle_count;
	uint8_t last_val = 0;
	for (uint32_t hunk = 0; hunk < chd->num_hunks;)		
	{
		if (avail_bits < 8) {
			if (cur >= compressed_len) {
				return (bitpos){.offset = -1};
			}
			bits |= compressed_map[cur++] << (8 - avail_bits);
			avail_bits += 8;
		}
		uint8_t val = lookup[bits >> 8];
		bits <<= huff_bits[val];
		bits &= 0xFFFF;
		avail_bits -= huff_bits[val];
		switch (state)
		{
		case STATE_NORMAL:
			if (val == CHD_V5_MAP_RLE4) {
				state = STATE_RLE4;
			} else if (val == CHD_V5_MAP_RLE8) {
				state = STATE_RLE8_MSB;
			} else {
				chd->hunk_info[hunk++].compression = last_val = val;
			}
			break;
		case STATE_RLE4:
			rle_count = val + 3;
			for (; rle_count > 0 && hunk < chd->num_hunks; rle_count--)
			{
				chd->hunk_info[hunk++].compression = last_val;
			}
			state = STATE_NORMAL;
			break;
		case STATE_RLE8_MSB:
			rle_count = val << 4;
			state = STATE_RLE8_LSB;
			break;
		case STATE_RLE8_LSB:
			rle_count |= val;
			rle_count += 19;
			for (; rle_count > 0 && hunk < chd->num_hunks; rle_count--)
			{
				chd->hunk_info[hunk++].compression = last_val;
			}
			state = STATE_NORMAL;
			break;
		}
	}
	return (bitpos){
		.offset = cur,
		.bits = bits,
		.avail_bits = avail_bits
	};
}

static uint8_t chd_read_map_v5(chd *chd)
{
	fseek(chd->f, chd->header.v.v5.map_offset, SEEK_SET);
	if (chd->header.v.v5.compressors[0]) {
		struct {
			uint32_t length;
			uint16_t offset[3];
			uint16_t crc;
			uint8_t  length_bits;
			uint8_t  self_bits;
			uint8_t  parent_bits;
			uint8_t  reserved;
		} header;
		if (1 != fread(&header, sizeof(header), 1, chd->f)) {
			return 0;
		}
#if !defined(BLASTEM_BIG_ENDIAN)
		header.length = bswap32(header.length);
		header.offset[0] = bswap16(header.offset[0]);
		header.offset[1] = bswap16(header.offset[1]);
		header.offset[2] = bswap16(header.offset[2]);
		header.crc = bswap16(header.crc);
#endif
		uint8_t *compressed_map = calloc(1, header.length);
		if (header.length != fread(compressed_map, 1, header.length, chd->f)) {
			return 0;
		}
		uint64_t offset = (uint64_t)header.offset[0] << 32 | (uint64_t)header.offset[1] << 16 | header.offset[2];
		//HERE: do huffman decode
		uint8_t huff_bits[16];
		uint8_t lookup[256];
		bitpos pos = chd_decode_map_huffman(compressed_map, header.length, huff_bits, lookup);
		if (pos.offset < 0) {
			return 0;
		}

		pos = chd_decode_map_rle(chd, compressed_map, header.length, pos, huff_bits, lookup);
		if (pos.offset < 0) {
			return 0;
		}
		enum {
			STATE_TYPE,
			STATE_LENGTH,
			STATE_CRC,
			STATE_SELF,
			STATE_PARENT
		} state = STATE_TYPE;
		uint32_t state_to_len[STATE_PARENT+1] = {0, header.length_bits, 16, header.self_bits, header.parent_bits};
		uint64_t usable_bits = 8;
		while (header.length_bits > usable_bits) {
			usable_bits += 8;
			pos.bits <<= 8;
		}
		while (header.self_bits > usable_bits) {
			usable_bits += 8;
			pos.bits <<= 8;
		}
		while (header.parent_bits > usable_bits) {
			usable_bits += 8;
			pos.bits <<= 8;
		}
		uint64_t mask = (1 << (usable_bits + 8)) - 1;
		uint64_t self_off = 0, parent_off = 0;
		for (uint32_t hunk = 0; hunk < chd->num_hunks;)
		{
			if (state == STATE_TYPE) {
				chd->hunk_info[hunk].offset = offset;
				switch (chd->hunk_info[hunk].compression)
				{
				case CHD_V5_MAP_T0:
				case CHD_V5_MAP_T1:
				case CHD_V5_MAP_T2:
				case CHD_V5_MAP_T3:
					state = STATE_LENGTH;
					break;
				case CHD_V5_MAP_NONE:
					state = STATE_CRC;
					break;
				case CHD_V5_MAP_SELF:
					state = STATE_SELF;
					break;
				case CHD_V5_MAP_PARENT:
					state = STATE_PARENT;
					break;
				case CHD_V5_MAP_SELF_LAST:
					chd->hunk_info[hunk].compression = CHD_V5_MAP_SELF;
					chd->hunk_info[hunk++].offset = self_off;
					break;
				case CHD_V5_MAP_SELF_LAST_PL1:
					chd->hunk_info[hunk].compression = CHD_V5_MAP_SELF;
					chd->hunk_info[hunk++].offset = ++self_off;
					break;
				case CHD_V5_MAP_PARENT_LAST:
					chd->hunk_info[hunk].compression = CHD_V5_MAP_PARENT;
					chd->hunk_info[hunk++].offset = parent_off;
					break;
				case CHD_V5_MAP_PARENT_LAST_PL1:
					chd->hunk_info[hunk].compression = CHD_V5_MAP_PARENT;
					chd->hunk_info[hunk++].offset = ++parent_off;
					break;
				default:
					//TODO: populate offset for PARENT_SELF
					hunk++;
					break;
				}
			} else {
				uint32_t needed_bits = state_to_len[state]; 
				while (pos.avail_bits < needed_bits)
				{
					if (pos.offset >= header.length) {
						return 0;
					}
					pos.bits |= ((uint64_t)compressed_map[pos.offset++]) << (usable_bits - (uint64_t)pos.avail_bits);
					pos.avail_bits += 8;
				}
				uint64_t value = pos.bits >> (8 + usable_bits - needed_bits);
				pos.bits <<= needed_bits;
				pos.bits &= mask;
				pos.avail_bits -= needed_bits;
				switch (state)
				{
				case STATE_LENGTH:
					chd->hunk_info[hunk].compressed_len = value;
					offset += value;
					state = STATE_CRC;
					break;
				case STATE_CRC:
					chd->hunk_info[hunk++].crc16 = value;
					state = STATE_TYPE;
					break;
				case STATE_SELF:
					chd->hunk_info[hunk++].offset = self_off = value;
					state = STATE_TYPE;
					break;
				case STATE_PARENT:
					chd->hunk_info[hunk++].offset = parent_off = value;
					state = STATE_TYPE;
					break;
				}
			}
		}
	} else {
	}
	return 1;
}

static void chd_print_meta_each(char *key, tern_val val, uint8_t valtype, void *data)
{
	const char *indent = data;
	printf("%s%s\n", indent, key);
	fflush(stdout);
	chd_meta_list *list = val.ptrval;
	for (uint32_t i = 0; i < list->num_entries; i++)
	{
		printf("%s\tFlags: %0X, Data: %s\n", indent, list->entries[i].flags, list->entries[i].data);
		fflush(stdout);
	}
}

void chd_print_meta(chd *chd, const char *indent)
{
	tern_foreach(chd->meta, chd_print_meta_each, (void *)indent);
}

const char* chd_compressor_name(uint32_t comp)
{
	switch (comp)
	{
	case 0: return "none";
	case CHD_ZLIB: return "zlib";
	case CHD_ZSTD: return "zstd";
	case CHD_HUFF: return "huff";
	case CHD_FLAC: return "flac";
	case CHD_LZMA: return "lzma";
	case CHD_CD_ZLIB: return "cdzl";
	case CHD_CD_ZSTD: return "cdzs";
	case CHD_CD_LZMA: return "cdlz";
	case CHD_CD_FLAC: return "cdfl";
	}
	return NULL;
}

void chd_print_hunk_info(chd *chd)
{
	for (uint32_t i = 0; i < chd->num_hunks; i++)
	{
		const char *type_name = "INVD";
		uint8_t comp = chd->hunk_info[i].compression;
		switch (comp)
		{
		case CHD_V5_MAP_T0:
		case CHD_V5_MAP_T1:
		case CHD_V5_MAP_T2:
		case CHD_V5_MAP_T3:
			type_name = chd_compressor_name(chd->header.v.v5.compressors[comp]);
			break;
		case CHD_V5_MAP_NONE:
			type_name = "none";
			break;
		case CHD_V5_MAP_SELF:
			type_name = "self";
			break;
		case CHD_V5_MAP_PARENT:
			type_name = "prnt";
			break;
		}
		printf("%s %" PRIX64 "\n", type_name, chd->hunk_info[i].offset);
	}
}

uint8_t chd_init(FILE *f, chd *out)
{
	memset(out, 0, sizeof(chd));
	fseek(f, 0, SEEK_SET);
	if (1 != fread(&out->header, sizeof(chd_header), 1, f)) {
		return 0;
	}
	chd_bswap(&out->header);
	out->f = f;
	uint64_t meta_offset = 0;
	switch (out->header.version)
	{
	default:
		out->num_hunks = out->header.v.old.v.v2.total_hunks;
		break;
	case 3:
		meta_offset = out->header.v.old.v.v3.meta_offset;
		out->num_hunks = out->header.v.old.v.v3.total_hunks;
		break;
	case 4:
		meta_offset = out->header.v.old.v.v4.meta_offset;
		out->num_hunks = out->header.v.old.v.v4.total_hunks;
		break;
	case 5:
		meta_offset = out->header.v.v5.meta_offset;
		out->num_hunks = (out->header.v.v5.logical_bytes + out->header.v.v5.hunk_bytes - 1) / out->header.v.v5.hunk_bytes;
		break;
	}
	if (!chd_read_meta(out, meta_offset)) {
		return 0;
	}
	if (out->header.version == 5) {
		if (!chd_read_map_v5(out)) {
			return 0;
		}
	}
	return 1;
}

static void chd_metadata_free_each(char *key, tern_val val, uint8_t valtype, void *data)
{
	free(val.ptrval);
}

void chd_free(chd *chd)
{
	tern_foreach(chd->meta, chd_metadata_free_each, NULL);
	free(chd->hunk_info);
	fclose(chd->f);
}

void chd_decompression_state_free(chd_decompression_state *decomp)
{
	free(decomp->src_buffer);
	free(decomp->dst_buffer);
	free(decomp->subcode_buffer);
	if (decomp->flac) {
		free(decomp->flac->subframes);
		free(decomp->flac->seekpoints);
	}
	free(decomp->flac);
}

uint32_t chd_hunk_size(chd *chd)
{
	switch (chd->header.version)
	{
	case 1:
	case 2: return chd->header.v.old.v.v2.hunksize;
	case 3: return chd->header.v.old.v.v3.hunk_bytes;
	case 4: return chd->header.v.old.v.v4.hunk_bytes;
	case 5: return chd->header.v.v5.hunk_bytes;
	default: return 0;
	}
}

uint64_t chd_total_size(chd *chd)
{
	switch (chd->header.version)
	{
	case 1:
	case 2: return ((uint64_t)chd->header.v.old.v.v2.hunksize) * ((uint64_t)chd->header.v.old.v.v2.total_hunks);
	case 3: return chd->header.v.old.v.v3.logical_bytes;
	case 4: return chd->header.v.old.v.v4.logical_bytes;
	case 5: return chd->header.v.v5.logical_bytes;
	default: return 0;
	}
}

uint8_t chd_is_cd_compressor(uint32_t compressor)
{
	return (compressor & CHD_COMPRESSOR(0xFF, 0xFF, 0, 0)) == CHD_COMPRESSOR('c', 'd', 0, 0);
}

#ifndef DISABLE_LZMA
static void *lzma_libc_malloc(ISzAllocPtr p, size_t size)
{
	return malloc(size);
}

static void lzma_libc_free(ISzAllocPtr p, void *address)
{
	free(address);
}

static ISzAlloc lzma_libc_alloc = {
	.Alloc = lzma_libc_malloc,
	.Free = lzma_libc_free
};
#endif

static uint32_t get_cd_codec_base_size(chd *chd, chd_decompression_state *decomp, uint32_t hunk, uint32_t *header_len)
{
	uint32_t sectors = chd_hunk_size(chd) / (2352 + 96);
	uint32_t base_size_off = (sectors + 7) >> 3; //1-bit per sector rounded to the nearest byte
	uint32_t base_size;
	if (chd_hunk_size(chd) < 0x10000) {
		*header_len = base_size_off + 2;
		base_size = decomp->src_buffer[base_size_off] << 8 | decomp->src_buffer[base_size_off+1];
	} else {
		*header_len = base_size_off + 3;
		base_size = decomp->src_buffer[base_size_off] << 16 | decomp->src_buffer[base_size_off+1] << 8 | decomp->src_buffer[base_size_off+2];
	}
	if (base_size + *header_len > chd->hunk_info[hunk].compressed_len) {
		warning("Invalid base compressed length %u in CHD hunk %u\n", base_size, hunk);
		base_size = chd->hunk_info[hunk].compressed_len - *header_len;
	}
	return base_size;
}

uint8_t chd_read(chd *chd, chd_decompression_state *decomp, uint32_t hunk, uint32_t offset, uint32_t length)
{
	if (hunk != decomp->current_hunk || !decomp->dst_buffer) {
		chd_hunk_info *info = chd->hunk_info + hunk;
		if (info->compression == CHD_V5_MAP_SELF) {
			hunk = info->offset;
			info = chd->hunk_info + hunk;
		}
		if (hunk != decomp->current_hunk || !decomp->dst_buffer) {
			decomp->current_hunk = hunk;
			decomp->hunk_decode_progress = 0;
			if (decomp->src_buffer_size < info->compressed_len) {
				decomp->src_buffer_size = decomp->src_buffer_size ? decomp->src_buffer_size * 3 / 2 : info->compressed_len;
				if (decomp->src_buffer_size < info->compressed_len) {
					decomp->src_buffer_size = info->compressed_len;
				}
				decomp->src_buffer = realloc(decomp->src_buffer, decomp->src_buffer_size);
			}
			if (!decomp->dst_buffer) {
				decomp->dst_buffer = calloc(chd_hunk_size(chd), 1);
			}
			if (info->compression < CHD_V5_MAP_NONE) {
				decomp->compressor = chd->header.v.v5.compressors[info->compression];
			} else {
				decomp->compressor = 0;
			}
			if (decomp->compressor) {
				if (chd_is_cd_compressor(decomp->compressor) && !decomp->subcode_buffer) {
					uint32_t sectors = chd_hunk_size(chd) / (2352 + 96);
					decomp->subcode_buffer = calloc(sectors, 96);
				}
				fseek(chd->f, info->offset, SEEK_SET);
				if (info->compressed_len != fread(decomp->src_buffer, 1, info->compressed_len, chd->f)) {
					warning("Failed to read %d bytes from CHD file for hunk %u\n", info->compressed_len, hunk);
					return 0;
				}
				switch (decomp->compressor)
				{
				case CHD_ZLIB:
				case CHD_CD_ZLIB:
#ifdef DISABLE_ZLIB
					warning("CHD requires zlib decompression for hunk %u, but zlib is disabled\n", hunk)
					return 0;
#else
					if (decomp->compressor == CHD_CD_ZLIB) {
						uint32_t header_len;
						decomp->zlib.avail_in = get_cd_codec_base_size(chd, decomp, hunk, &header_len);
						decomp->zlib.next_in = decomp->src_buffer + header_len;
					} else {
						decomp->zlib.avail_in = info->compressed_len;
						decomp->zlib.next_in = decomp->src_buffer;
					}
					decomp->zlib.total_in = 0;
					decomp->zlib.next_out = decomp->dst_buffer;
					decomp->zlib.avail_out = chd_hunk_size(chd);
					decomp->zlib.total_out = 0;
					if (Z_OK != inflateInit2(&decomp->zlib, -15)) {
						warning("Failed to initialize inflate for CHD hunk %u\n", hunk);
						return 0;
					}
#endif
					break;
				case CHD_LZMA:
				case CHD_CD_LZMA:
#ifdef DISABLE_LZMA
					warning("CHD requires lzma decompression for hunk %u, but lzma is disabled\n", hunk);
					return 0;
#else
					if (!decomp->lzma) {
						CLzmaEncProps props;
						LzmaEncProps_Init(&props);
						props.level = 8;
						props.reduceSize = chd_hunk_size(chd);
						LzmaEncProps_Normalize(&props);
						CLzmaEncHandle tmpEnc = LzmaEnc_Create(&lzma_libc_alloc);
						LzmaEnc_SetProps(tmpEnc, &props);
						SizeT size = sizeof(decomp->lzma_props);
						LzmaEnc_WriteProperties(tmpEnc, decomp->lzma_props, &size);
						LzmaEnc_Destroy(tmpEnc, &lzma_libc_alloc, &lzma_libc_alloc);
						
						decomp->lzma = calloc(1, sizeof(CLzmaDec));
						LzmaDec_Construct(decomp->lzma);
						
						
						LzmaDec_Allocate(decomp->lzma, decomp->lzma_props, size, &lzma_libc_alloc);
					}
					LzmaDec_Init(decomp->lzma);
					
					SizeT main_len = info->compressed_len;
					SizeT dstSize = chd_hunk_size(chd);
					Byte *start = decomp->src_buffer;
					if (decomp->compressor == CHD_CD_LZMA) {
						uint32_t header_len;
						uint32_t base_size = get_cd_codec_base_size(chd, decomp, hunk, &header_len);
						decomp->zlib.next_in = decomp->src_buffer + base_size + header_len;
						decomp->zlib.avail_in = main_len - base_size;
						decomp->zlib.next_out = decomp->subcode_buffer;
						decomp->zlib.avail_out = 96 * (chd_hunk_size(chd) / (2352 + 96));
						dstSize -= decomp->zlib.avail_out;
						decomp->zlib.total_in = decomp->zlib.total_out;
						if (Z_OK != inflateInit2(&decomp->zlib, -15)) {
							warning("Failed to initialize inflate for CHD hunk %u subcode data\n", hunk);
						}
						if (Z_STREAM_END != inflate(&decomp->zlib, Z_FINISH)) {
							warning("subocde inflate failed for hunk %u\n", hunk);
						}
						main_len = base_size;
						start += header_len;
					}
					ELzmaStatus status;
					if (SZ_OK != LzmaDecode(
						decomp->dst_buffer, &dstSize, start, &main_len, decomp->lzma_props, 
						sizeof(decomp->lzma_props), LZMA_FINISH_ANY, &status, &lzma_libc_alloc
					)) {
						warning("Failed to LZMA decompress hunk %u\n", hunk);
						return 0;
					}
					decomp->hunk_decode_progress = chd_hunk_size(chd);
#endif
					break;
				case CHD_ZSTD:
				case CHD_CD_ZSTD:
#ifdef DISABLE_ZSTD
					warning("CHD requires lzma decompression for hunk %u, but zstd is disabled\n", hunk);
					return 0;
#else
					if (!decomp->zstd) {
						decomp->zstd = ZSTD_createDStream();
					}
					if (ZSTD_isError(ZSTD_initDStream(decomp->zstd))) {
						warning("Failed to initialize zstd decompression stream");
						return 0;
					}
					decomp->zstd_out.dst = decomp->dst_buffer;
					decomp->zstd_out.size = chd_hunk_size(chd);
					decomp->zstd_out.pos = 0;
					if (decomp->compressor == CHD_CD_ZSTD) {
						uint32_t header_len;
						decomp->zstd_in.size = get_cd_codec_base_size(chd, decomp, hunk, &header_len);
						decomp->zstd_in.src = decomp->src_buffer + header_len;
						ZSTD_inBuffer sub_in = {
							.src = decomp->src_buffer + header_len + decomp->zstd_in.size,
							.size = info->compressed_len - header_len - decomp->zstd_in.size,
							.pos = 0
						};
						ZSTD_outBuffer sub_out = {
							.dst = decomp->subcode_buffer,
							.size = 96 * chd_hunk_size(chd) / (2352 + 96),
							.pos = 0
						};
						while (sub_out.pos < sub_out.size)
						{
							if (ZSTD_isError(ZSTD_decompressStream(decomp->zstd, &sub_out, &sub_in))) {
								warning("Failed to decompress subcode data for hunk %u\n", hunk);
								break;
							}
						}
						//reinit decomporessor after subcode decompression
						if (ZSTD_isError(ZSTD_initDStream(decomp->zstd))) {
							warning("Failed to initialize zstd decompression stream");
							return 0;
						}
					} else {
						decomp->zstd_in.size = info->compressed_len;
						decomp->zstd_in.src = decomp->src_buffer;
					}
					decomp->zstd_in.pos = 0;
					decomp->hunk_decode_progress = 0;
#endif
					break;
				case CHD_FLAC:
				case CHD_CD_FLAC: {
					//first byte indicates endianness??? for non-CD FLAC
					uint32_t offset = decomp->compressor == CHD_FLAC;
					if (decomp->flac) {
						flac_reset_buffer_raw(decomp->flac, decomp->src_buffer + offset, info->compressed_len - offset);
					} else {
						decomp->flac = flac_file_from_buffer_raw(decomp->src_buffer + offset, info->compressed_len - offset, 44100, 2, 16);
					}
					break;
				}
				default:
					warning("Unsupported compressor type %s for hunk %u\n", chd_compressor_name(decomp->compressor), hunk);
					return 0;
				}
			}
		}
	}
	uint32_t end = offset + length;
	if (end > decomp->hunk_decode_progress) {
		switch (decomp->compressor)
		{
		case 0: {
			chd_hunk_info *info = chd->hunk_info + hunk;
			fseek(chd->f, info->offset, SEEK_SET);
			decomp->hunk_decode_progress += fread(decomp->dst_buffer + decomp->hunk_decode_progress, 1, end - decomp->hunk_decode_progress, chd->f);
			break;
		}
		case CHD_ZLIB:
#ifndef DISABLE_ZLIB
			while (end > decomp->hunk_decode_progress)
			{
				int ret = inflate(&decomp->zlib, Z_BLOCK);
				if (ret != Z_OK && ret != Z_STREAM_END) {
					warning("inflate failed for hunk %u\n", hunk);
					return 0;
				}
				decomp->hunk_decode_progress = decomp->zlib.total_out;
				if (ret == Z_STREAM_END) {
					break;
				}
			}
#endif
			break;
		case CHD_CD_ZLIB: {
#ifndef DISABLE_ZLIB
			//TODO: handle a final hunk that is not full sized
			uint32_t sectors = chd_hunk_size(chd) / (2352 + 96);
			if (Z_STREAM_END != inflate(&decomp->zlib, Z_FINISH)) {
				warning("inflate failed for hunk %u\n", hunk);
				return 0;
			}
			chd_hunk_info *info = chd->hunk_info + hunk;
			decomp->zlib.avail_in = chd->hunk_info[hunk].compressed_len - decomp->zlib.total_in;
			decomp->zlib.total_in = 0;
			decomp->zlib.next_out = decomp->subcode_buffer;
			decomp->zlib.avail_out = sectors * 96;
			decomp->zlib.total_out = 0;
			if (Z_OK != inflateInit2(&decomp->zlib, -15)) {
				warning("Failed to initialize inflate for CHD hunk %u subcode data\n", hunk);
			}
			if (Z_STREAM_END != inflate(&decomp->zlib, Z_FINISH)) {
				warning("inflate failed for hunk %u subcode data\n", hunk);
			}
			decomp->hunk_decode_progress = chd_hunk_size(chd);
#endif
			break;
		}
		case CHD_CD_ZSTD:
			{
				uint32_t sector = end / (2352 + 96);
				uint32_t sector_off = end % (2352 + 96);
				if (sector_off > 2352) {
					sector_off = 2352;
				}
				end = sector * 2352 + sector_off;
			}
		case CHD_ZSTD:
#ifndef DISABLE_ZSTD
			while (end > decomp->zstd_out.pos)
			{
				if (ZSTD_isError(ZSTD_decompressStream(decomp->zstd, &decomp->zstd_out, &decomp->zstd_in))) {
					warning("Failed to decompress data for hunk %u\n", hunk);
					return 0;
				}
			}
			if (decomp->compressor == CHD_CD_ZSTD) {
				uint32_t sector = decomp->zstd_out.pos / 2352;
				uint32_t sector_off = decomp->zstd_out.pos % 2352;
				decomp->hunk_decode_progress = sector * (2352 + 96) + sector_off;
			} else {
				decomp->hunk_decode_progress = decomp->zstd_out.pos;
			}
#endif
			break;
		case CHD_FLAC:
			while (end > decomp->hunk_decode_progress)
			{
				if (!flac_get_sample(decomp->flac, (int16_t *)(decomp->dst_buffer + decomp->hunk_decode_progress), 2)) {
					warning("FLAC decode failed for hunk %u\n", hunk);
					return 0;
				}
				decomp->hunk_decode_progress += 4;
			}
			break;
		case CHD_CD_FLAC:{
			//TODO: handle a final hunk that is not full sized
			uint32_t sectors = chd_hunk_size(chd) / (2352 + 96);
			uint32_t samples = sectors * (44100 / 75);
			for (uint32_t i = 0; i < samples; i++)
			{
				if (!flac_get_sample(decomp->flac, (int16_t *)(decomp->dst_buffer + i * 4), 2)) {
					warning("FLAC decode failed for hunk %u\n", hunk);
					return 0;
				}
			}
			chd_hunk_info *info = chd->hunk_info + hunk;
			decomp->zlib.avail_in = info->compressed_len - decomp->flac->offset;
			decomp->zlib.next_in = decomp->src_buffer + decomp->flac->offset;
			decomp->zlib.total_in = 0;
			decomp->zlib.next_out = decomp->subcode_buffer;
			decomp->zlib.avail_out = sectors * 96;
			decomp->zlib.total_out = 0;
			if (Z_OK != inflateInit2(&decomp->zlib, -15)) {
				warning("Failed to initialize inflate for CHD hunk %u subcode data\n", hunk);
			}
			if (Z_STREAM_END != inflate(&decomp->zlib, Z_FINISH)) {
				warning("inflate failed for hunk %u subcode data\n", hunk);
			}
			decomp->hunk_decode_progress = chd_hunk_size(chd);
			break;
		}
		}
	}
	return 1;
}
