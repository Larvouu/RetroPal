/* mGBA compilation unit: GBA platform */
#include "mgba-config.h"

// GB audio is in its own file (SAMPLE_INTERVAL conflicts with gba/audio.c)

// GBA SIO Game Boy Player support — needed by gba/sio.c
#include "../../../Vendor/mgba/src/gba/sio/gbp.c"

#include "../../../Vendor/mgba/src/gba/audio.c"
#include "../../../Vendor/mgba/src/gba/bios.c"
#include "../../../Vendor/mgba/src/gba/cheats.c"
#include "../../../Vendor/mgba/src/gba/core.c"
#include "../../../Vendor/mgba/src/gba/dma.c"
#include "../../../Vendor/mgba/src/gba/gba.c"
#include "../../../Vendor/mgba/src/gba/hle-bios.c"
#include "../../../Vendor/mgba/src/gba/input.c"
#include "../../../Vendor/mgba/src/gba/io.c"
#include "../../../Vendor/mgba/src/gba/memory.c"
#include "../../../Vendor/mgba/src/gba/overrides.c"
#include "../../../Vendor/mgba/src/gba/savedata.c"
#include "../../../Vendor/mgba/src/gba/serialize.c"
#include "../../../Vendor/mgba/src/gba/sharkport.c"
#include "../../../Vendor/mgba/src/gba/sio.c"
#include "../../../Vendor/mgba/src/gba/timer.c"
#include "../../../Vendor/mgba/src/gba/video.c"

// Cartridge hardware
#include "../../../Vendor/mgba/src/gba/cart/ereader.c"
#include "../../../Vendor/mgba/src/gba/cart/gpio.c"
#include "../../../Vendor/mgba/src/gba/cart/matrix.c"
#include "../../../Vendor/mgba/src/gba/cart/unlicensed.c"
#include "../../../Vendor/mgba/src/gba/cart/vfame.c"

// Cheats
#include "../../../Vendor/mgba/src/gba/cheats/codebreaker.c"
#include "../../../Vendor/mgba/src/gba/cheats/gameshark.c"
#include "../../../Vendor/mgba/src/gba/cheats/parv3.c"

// Renderers
#include "../../../Vendor/mgba/src/gba/renderers/cache-set.c"
#include "../../../Vendor/mgba/src/gba/renderers/common.c"
#include "../../../Vendor/mgba/src/gba/renderers/software-bg.c"
#include "../../../Vendor/mgba/src/gba/renderers/software-mode0.c"
#include "../../../Vendor/mgba/src/gba/renderers/software-obj.c"
#include "../../../Vendor/mgba/src/gba/renderers/video-software.c"

#pragma clang diagnostic pop
