/*
 * flags.h — iOS build configuration for mGBA
 *
 * Must match the defines in mgba-config.h exactly.
 * Included by MGBABridge.mm so mGBA headers see the correct feature flags.
 */
#ifndef FLAGS_H
#define FLAGS_H

#ifndef MINIMAL_CORE
#define MINIMAL_CORE 1
#endif

#ifndef M_CORE_GBA
#define M_CORE_GBA 1
#endif

#ifndef M_CORE_GB
#define M_CORE_GB 1
#endif

#ifndef DISABLE_THREADING
#define DISABLE_THREADING 1
#endif

#ifndef ENABLE_VFS
#define ENABLE_VFS 1
#endif

#ifndef ENABLE_VFS_FD
#define ENABLE_VFS_FD 1
#endif

#ifndef ENABLE_DIRECTORIES
#define ENABLE_DIRECTORIES 1
#endif

#ifndef HAVE_LOCALE
#define HAVE_LOCALE 1
#endif

#ifndef HAVE_XLOCALE
#define HAVE_XLOCALE 1
#endif

#ifndef HAVE_SNPRINTF_L
#define HAVE_SNPRINTF_L 1
#endif

#ifndef HAVE_STRTOF_L
#define HAVE_STRTOF_L 1
#endif

#ifndef HAVE_LOCALTIME_R
#define HAVE_LOCALTIME_R 1
#endif

#ifndef HAVE_STRDUP
#define HAVE_STRDUP 1
#endif

#ifndef HAVE_STRLCPY
#define HAVE_STRLCPY 1
#endif

#endif
