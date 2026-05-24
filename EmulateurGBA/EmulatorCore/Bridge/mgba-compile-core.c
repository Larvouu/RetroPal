/* mGBA compilation unit: Core engine
 *
 * bitmap-cache.c, map-cache.c, and tile-cache.c each define static
 * functions named _freeCache and _redoCacheSize with different
 * parameter types. They MUST be in separate translation units.
 * bitmap-cache is here; map-cache and tile-cache are in their own files.
 */
#include "mgba-config.h"
#include "../../../Vendor/mgba/src/core/bitmap-cache.c"
#include "../../../Vendor/mgba/src/core/cache-set.c"
#include "../../../Vendor/mgba/src/core/cheats.c"
#include "../../../Vendor/mgba/src/core/config.c"
#include "../../../Vendor/mgba/src/core/core.c"
#include "../../../Vendor/mgba/src/core/directories.c"
#include "../../../Vendor/mgba/src/core/input.c"
#include "../../../Vendor/mgba/src/core/interface.c"
#include "../../../Vendor/mgba/src/core/lockstep.c"
#include "../../../Vendor/mgba/src/core/log.c"
#include "../../../Vendor/mgba/src/core/mem-search.c"
#include "../../../Vendor/mgba/src/core/rewind.c"
#include "../../../Vendor/mgba/src/core/serialize.c"
#include "../../../Vendor/mgba/src/core/sync.c"
#include "../../../Vendor/mgba/src/core/thread.c"
#include "../../../Vendor/mgba/src/core/timing.c"
#pragma clang diagnostic pop
