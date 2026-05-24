/* mGBA compilation unit: Game Boy / Game Boy Color core
 *
 * Note: gb/audio.c is in its own file (mgba-compile-gb-audio.c)
 * due to SAMPLE_INTERVAL conflict with gba/audio.c.
 */
#include "mgba-config.h"

#include "../../../Vendor/mgba/src/gb/gb.c"
#include "../../../Vendor/mgba/src/gb/core.c"
#include "../../../Vendor/mgba/src/gb/cheats.c"
#include "../../../Vendor/mgba/src/gb/input.c"
#include "../../../Vendor/mgba/src/gb/io.c"
#include "../../../Vendor/mgba/src/gb/mbc.c"
#include "../../../Vendor/mgba/src/gb/memory.c"
#include "../../../Vendor/mgba/src/gb/overrides.c"
#include "../../../Vendor/mgba/src/gb/serialize.c"
#include "../../../Vendor/mgba/src/gb/sio.c"
#include "../../../Vendor/mgba/src/gb/timer.c"
#include "../../../Vendor/mgba/src/gb/video.c"

// MBC (Memory Bank Controller) implementations
#include "../../../Vendor/mgba/src/gb/mbc/huc-3.c"
#include "../../../Vendor/mgba/src/gb/mbc/licensed.c"
#include "../../../Vendor/mgba/src/gb/mbc/mbc.c"
#include "../../../Vendor/mgba/src/gb/mbc/pocket-cam.c"
#include "../../../Vendor/mgba/src/gb/mbc/tama5.c"
#include "../../../Vendor/mgba/src/gb/mbc/unlicensed.c"

// GB renderers
#include "../../../Vendor/mgba/src/gb/renderers/cache-set.c"
// gb/renderers/software.c is in its own file (_cleanOAM conflicts with gb/video.c)

#pragma clang diagnostic pop
