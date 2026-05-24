/*
 * mgba-config.h
 * EmulateurGBA
 *
 * Common preprocessor defines for all mGBA compilation units.
 * Must be included at the top of every mgba-compile-*.c file.
 */
#ifndef MGBA_CONFIG_H
#define MGBA_CONFIG_H

// Core configuration
#define MINIMAL_CORE 1
#define M_CORE_GBA 1
#define M_CORE_GB 1
#define DISABLE_THREADING 1
#define ENABLE_VFS 1
#define ENABLE_VFS_FD 1
#define ENABLE_DIRECTORIES 1

// Platform capabilities (iOS)
// HAVE_LOCALE must be defined — without it, formatting.h tries to
// typedef locale_t as const char*, which conflicts with the system's
// locale_t (struct _xlocale*) pulled in by Clang modules.
// HAVE_XLOCALE includes <xlocale.h> which provides newlocale/freelocale
// and snprintf_l/strtof_l that formatting.c needs.
#define HAVE_LOCALE 1
#define HAVE_XLOCALE 1
#define HAVE_SNPRINTF_L 1
#define HAVE_STRTOF_L 1
#define HAVE_LOCALTIME_R 1
#define HAVE_STRDUP 1
#define HAVE_STRLCPY 1

// Suppress warnings in vendor code
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wshorten-64-to-32"
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wunused-variable"
#pragma clang diagnostic ignored "-Wmissing-field-initializers"
#pragma clang diagnostic ignored "-Wconditional-uninitialized"
#pragma clang diagnostic ignored "-Wcomma"
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic ignored "-Wstrict-prototypes"
#pragma clang diagnostic ignored "-Wimplicit-fallthrough"
#pragma clang diagnostic ignored "-Wswitch"
#pragma clang diagnostic ignored "-Wmacro-redefined"

#endif
