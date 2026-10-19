#ifndef CHD_H_
#define CHD_H_

#include <stdint.h>

#include "tern.h"
#ifndef DISABLE_ZLIB
#include "zlib/zlib.h"
#endif
#ifndef DISABLE_LZMA
#include "lzma/LzmaDec.h"
#endif
#ifndef DISABLE_ZSTD
#include "zstd.h"
#endif
#include "flac.h"

typedef struct {
	uint64_t offset;
	uint32_t compressed_len;
	uint16_t crc16;
	uint8_t  compression;
} chd_hunk_info;

typedef struct {
	char tag[8];
	uint32_t length;
	uint32_t version;
	union {
		struct {
			uint32_t flags;
			uint32_t compression;
			union {
				struct {
					uint32_t hunksize;
					uint32_t total_hunks;
					uint32_t cylinders;
					uint32_t heads;
					uint32_t sectors;
					uint8_t  md5[16];
					uint8_t  parent_md5[16];
					uint32_t seclen;
				} v2; //v1 is the same as v2, but lacks seclen
				struct {
					uint32_t total_hunks;
					uint64_t logical_bytes;
					uint64_t meta_offset;
					uint8_t  md5[16];
					uint8_t  parent_md5[16];
					uint32_t hunk_bytes;
					uint8_t  sha1[20];
					uint8_t  parentsha1[20];
				} v3;
				struct {
					uint32_t total_hunks;
					uint64_t logical_bytes;
					uint64_t meta_offset;
					uint32_t hunk_bytes;
					uint8_t  sha1[20];
					uint8_t  parentsha1[20];
					uint8_t  rawsha1[20];
				} v4;
			} v;
		} old;
		struct {
			uint32_t compressors[4];
			uint64_t logical_bytes;
			uint64_t map_offset;
			uint64_t meta_offset;
			uint32_t hunk_bytes;
			uint32_t unit_bytes;
			uint8_t  rawsha1[20];
			uint8_t  sha1[20];
			uint8_t  parentsha1[20];
		} v5;
	} v;
} chd_header;

typedef struct {
	char    *data;
	uint8_t flags;
} chd_meta;

typedef struct {
	uint32_t num_entries;
	uint32_t storage;
	chd_meta entries[];
} chd_meta_list;

typedef struct {
	FILE          *f;
	chd_header    header;
	tern_node     *meta;
	chd_hunk_info *hunk_info;
	uint32_t      num_hunks;
} chd;

typedef struct {
#ifndef DISABLE_ZLIB
	z_stream  zlib;
#endif
#ifndef DISABLE_LZMA
	CLzmaDec  *lzma;
	Byte      lzma_props[LZMA_PROPS_SIZE];
#endif
#ifndef DISABLE_ZSTD
	ZSTD_DStream *zstd;
	ZSTD_inBuffer zstd_in;
	ZSTD_outBuffer zstd_out;
#endif
	flac_file *flac;
	uint8_t   *src_buffer;
	uint8_t   *dst_buffer;
	uint8_t   *subcode_buffer;
	uint32_t  src_buffer_size;
	uint32_t  current_hunk;
	uint32_t  hunk_decode_progress;
	uint32_t  compressor;
} chd_decompression_state;

enum {
	CHD_V5_MAP_T0,
	CHD_V5_MAP_T1,
	CHD_V5_MAP_T2,
	CHD_V5_MAP_T3,
	CHD_V5_MAP_NONE,
	CHD_V5_MAP_SELF,
	CHD_V5_MAP_PARENT,
	CHD_V5_MAP_RLE4,
	CHD_V5_MAP_RLE8,
	CHD_V5_MAP_SELF_LAST,
	CHD_V5_MAP_SELF_LAST_PL1,
	CHD_V5_MAP_PARENT_SELF,
	CHD_V5_MAP_PARENT_LAST,
	CHD_V5_MAP_PARENT_LAST_PL1,
};

#define CHD_COMPRESSOR(a,b,c,d) (((uint32_t)a) << 24 | ((uint32_t)b)<< 16 | ((uint32_t)c) << 8 | ((uint32_t)d))

#define CHD_ZLIB CHD_COMPRESSOR('z','l','i','b')
#define CHD_ZSTD CHD_COMPRESSOR('z','s','t','d')
#define CHD_HUFF CHD_COMPRESSOR('h','u','f','f')
#define CHD_FLAC CHD_COMPRESSOR('f','l','a','c')
#define CHD_LZMA CHD_COMPRESSOR('l','z','m','a')
#define CHD_CD_ZLIB CHD_COMPRESSOR('c','d','z','l')
#define CHD_CD_ZSTD CHD_COMPRESSOR('c','d','z','s')
#define CHD_CD_LZMA CHD_COMPRESSOR('c','d','l','z')
#define CHD_CD_FLAC CHD_COMPRESSOR('c','d','f','l')

enum {
	CHD_MEDIA_HD,
	CHD_MEDIA_CD,
	CHD_MEDIA_GD,
	CHD_MEDIA_DVD,
	CHD_MEDIA_AV
};

void chd_print_hunk_info(chd *chd);
uint8_t chd_init(FILE *f, chd *out);
void chd_print_meta(chd *chd, const char *indent);
void chd_print_hunk_info(chd *chd);
uint8_t chd_read(chd *chd, chd_decompression_state *decomp, uint32_t hunk, uint32_t offset, uint32_t length);
uint32_t chd_hunk_size(chd *chd);
uint64_t chd_total_size(chd *chd);
uint8_t chd_is_cd_compressor(uint32_t compressor);
void chd_free(chd *chd);

const char* chd_compressor_name(uint32_t comp);

#endif //CHD_H_
