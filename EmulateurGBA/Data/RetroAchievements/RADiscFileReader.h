//
//  RADiscFileReader.h
//  EmulateurGBA
//
//  Reading a disc image as one flat byte stream: a PlayStation `.chd`, a PSP
//  `.chd` or `.cso` (decompressed), anything else as the file it is.
//
//  DELIBERATELY KNOWS NOTHING ABOUT RETROACHIEVEMENTS. Its five entry points
//  have the shapes rcheevos' file reader wants, and that is the only trace of
//  its caller: the binding itself lives in RAClient, which is the file that
//  already speaks rcheevos. Reading a disc image is a self-contained capability
//  and this is where it lives.
//
//  It was not always split this way. The binding started in here, which meant a
//  plain C file including `rc_hash.h`, and rcheevos reaches this project as a
//  local Swift package: its headers arrive through a generated module map
//  rather than a plain include path, and the C translation unit found the
//  header without receiving a single declaration from it. Nothing about a CHD
//  needed that header, so nothing about a CHD includes it now.
//

#ifndef RADiscFileReader_h
#define RADiscFileReader_h

#include <stddef.h>
#include <stdint.h>

// C LINKAGE, EXPLICITLY. This is a C file and its only caller is RAClient.mm,
// which is Objective-C++: without this the caller looks for C++-mangled symbols
// (`RADiscOpen(char const*)`) that a C translation unit never emits, and the
// build gets all the way to the linker before saying so. rcheevos wraps its own
// headers the same way, through RC_BEGIN_C_DECLS.
#ifdef __cplusplus
extern "C" {
#endif

/// Opens a disc image. A PlayStation `.chd` (a raw CD track) is decompressed
/// on demand and presented as the raw 2352-byte sectors of its first track; a
/// `.chd` holding 2048-byte sectors (a DVD image, how a PSP UMD becomes one, or
/// a CD made from a plain `.iso`) and a `.cso` (the PSP's compressed ISO) as
/// the ISO they hold; anything else is opened as an ordinary file. NULL if it
/// cannot be read.
void *RADiscOpen(const char *path);

/// Whether the opened image is a `.chd` read as a flat 2048-byte ISO (see
/// `RADiscOpen`). A raw CD `.chd` (every PlayStation one) answers 0, and so
/// does any other file.
int RADiscIsFlatImage(void *handle);

/// Standard `fseek` parameters, against that flat view.
void RADiscSeek(void *handle, int64_t offset, int origin);

/// The current position in the flat view.
int64_t RADiscTell(void *handle);

/// Reads from the current position. A short read means "there is no more disc
/// here", which is a real answer and not an error.
size_t RADiscRead(void *handle, void *buffer, size_t requestedBytes);

void RADiscClose(void *handle);

#ifdef __cplusplus
}
#endif

#endif /* RADiscFileReader_h */
