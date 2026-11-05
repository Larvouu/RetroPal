// Apple's <compression.h>, as much of it as PSPBridge's state format uses,
// over the reference LZFSE (github.com/lzfse/lzfse, BSD-3-Clause, by Apple):
// the same algorithm and the same raw stream compression_encode_buffer
// writes with COMPRESSION_LZFSE, so a state file packed here unpacks on the
// phone and the other way round. build.sh compiles the reference sources
// beside the harness when it is given their folder.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include "lzfse.h"

// COMPRESSION_LZ4 (CTRBridge's rewind steps) packs with LZFSE here: the
// harness checks that a step comes back whole, which any lossless round trip
// shows; the phone uses Apple's LZ4.
typedef enum { COMPRESSION_LZFSE = 0x801, COMPRESSION_LZ4 = 0x100 } compression_algorithm;

static inline size_t compression_encode_buffer(uint8_t *dst, size_t dstSize, const uint8_t *src,
                                               size_t srcSize, void *scratch, compression_algorithm) {
    return lzfse_encode_buffer(dst, dstSize, src, srcSize, scratch);
}

static inline size_t compression_decode_buffer(uint8_t *dst, size_t dstSize, const uint8_t *src,
                                               size_t srcSize, void *scratch, compression_algorithm) {
    return lzfse_decode_buffer(dst, dstSize, src, srcSize, scratch);
}
