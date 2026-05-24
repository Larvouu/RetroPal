/* mGBA compilation unit: Utilities, VFS, platform, third-party */
#include "mgba-config.h"

// Utilities
#include "../../../Vendor/mgba/src/util/audio-buffer.c"
#include "../../../Vendor/mgba/src/util/audio-resampler.c"
#include "../../../Vendor/mgba/src/util/circle-buffer.c"
#include "../../../Vendor/mgba/src/util/configuration.c"
#include "../../../Vendor/mgba/src/util/convolve.c"
#include "../../../Vendor/mgba/src/util/crc32.c"
#include "../../../Vendor/mgba/src/util/formatting.c"
#include "../../../Vendor/mgba/src/util/gbk-table.c"
#include "../../../Vendor/mgba/src/util/geometry.c"
#include "../../../Vendor/mgba/src/util/hash.c"
#include "../../../Vendor/mgba/src/util/image.c"
#include "../../../Vendor/mgba/src/util/image/export.c"
#include "../../../Vendor/mgba/src/util/image/font.c"
#include "../../../Vendor/mgba/src/util/interpolator.c"
#include "../../../Vendor/mgba/src/util/md5.c"
#include "../../../Vendor/mgba/src/util/patch.c"
#include "../../../Vendor/mgba/src/util/patch-fast.c"
#include "../../../Vendor/mgba/src/util/patch-ips.c"
// patch-ups.c is in its own file (BUFFER_SIZE enum conflicts with crc32.c)
#include "../../../Vendor/mgba/src/util/ring-fifo.c"
#include "../../../Vendor/mgba/src/util/sfo.c"
#include "../../../Vendor/mgba/src/util/sha1.c"
#include "../../../Vendor/mgba/src/util/string.c"
#include "../../../Vendor/mgba/src/util/table.c"
#include "../../../Vendor/mgba/src/util/text-codec.c"
#include "../../../Vendor/mgba/src/util/vector.c"
#include "../../../Vendor/mgba/src/util/vfs.c"

// VFS implementations (POSIX)
#include "../../../Vendor/mgba/src/util/vfs/vfs-fd.c"
#include "../../../Vendor/mgba/src/util/vfs/vfs-dirent.c"
#include "../../../Vendor/mgba/src/util/vfs/vfs-fifo.c"
#include "../../../Vendor/mgba/src/util/vfs/vfs-mem.c"

// Platform (POSIX memory mapping)
#include "../../../Vendor/mgba/src/platform/posix/memory.c"

// Third-party (INI parser)
#include "../../../Vendor/mgba/src/third-party/inih/ini.c"

#pragma clang diagnostic pop
