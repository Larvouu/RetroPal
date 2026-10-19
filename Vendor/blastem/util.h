#ifndef UTIL_H_
#define UTIL_H_

#include <stdio.h>
#include <time.h>
#include <wchar.h>
#include <stdarg.h>
#include "tern.h"

typedef struct {
	char    *name;
	uint8_t is_dir;
} dir_entry;

typedef enum {
	DEBUG,
	INFO,
	WARN,
	FATAL
} log_level;
typedef void (*log_fun)(log_level level, char *message);

#ifdef _WIN32
#define PATH_SEP "\\"
#else
#define PATH_SEP "/"
#endif

#ifdef _WIN32
//redirect standard fopen to a wrapper that does utf8/utf16 conversion and uses _wfopen
FILE *fopen_utf8(const char *path, const char *mode);
#define fopen(path, mode) fopen_utf8(path, mode)
//does UTF-8 to UTF-16 conversion, ensures all slashes are backslashes and prepends \\?\ for long path access
wchar_t *to_windows_path(const char *path);
#endif

//Utility functions

//equivalent to calloc, but with forced alignment
//align must be a power of 2
void *aligned_calloc(size_t nmemb, size_t size, size_t align);
//memory allocated with aligned_alloc must be freed with align_free
void aligned_free(void *ptr);
//Allocates a new string containing the concatenation of first and second
char * alloc_concat(char const * first, char const * second);
//Allocates a new string containing the concatenation of the strings pointed to by parts
char * alloc_concat_m(int num_parts, char const ** parts);
//Allocates a new string containing the concatenation of the strings pointed to by parts separated by sep
char * alloc_join(int num_parts, char const **parts, char sep);
//Returns a newly allocated string in which all variables in based are replaced with values from vars or the environment
char *replace_vars(char *base, tern_node *vars, uint8_t allow_env);
//Byteswaps a ROM image in memory
void byteswap_rom(int filesize, uint16_t *cart);
//Returns the size of a file using fseek and ftell
long file_size(FILE * f);
//Strips whitespace and non-printable characters from the beginning and end of a string
char * strip_ws(char * text);
//Inserts a null after the first word, returns a pointer to the second word
char * split_keyval(char * text);
//Checks if haystack starts with prefix
uint8_t startswith(const char *haystack, const char *prefix);
//Takes a binary byte buffer and produces a lowercase hex string
void bin_to_hex(uint8_t *output, uint8_t *input, uint64_t size);
//Takes an (optionally) null-terminated UTF16-BE string and converts a maximum of max_size code-units to UTF-8
char *utf16be_to_utf8(uint8_t *buf, uint32_t max_size);
//Returns the next Unicode codepoint from a utf-8 string
int utf8_codepoint(const char **text);
//Converts a UTF-8 string to a UTF-16 string in system endianness
wchar_t *utf8_to_utf16(const char *text);
//Converts a UTF-16 string in system endianness to UTF-8
char *utf16_to_utf8(const wchar_t *text);
//Gets the smallest power of two that is >= a certain value, won't work for values > 0x80000000
uint32_t nearest_pow2(uint32_t val);
//Returns an array of normal files and directories residing in a directory
dir_entry *get_dir_list(char *path, size_t *numret);
//Frees a dir list returned by get_dir_list
void free_dir_list(dir_entry *list, size_t numentries);
//Performs a case-insensitive sort by file name on a dir list
void sort_dir_list(dir_entry *list, size_t num_entries);
//Gets the modification time of a file
time_t get_modification_time(char *path);
//Recusrively creates a directory if it does not exist
int ensure_dir_exists(const char *path);
//Returns the contents of a symlink in a newly allocated string
char * readlink_alloc(char * path);
//Prints an error message to stderr and to a message box if not in headless mode and then exits
void fatal_error(char *format, ...);
//Prints an information message to stdout and to a message box if not in headless mode and not attached to a console
void info_message(char *format, ...);
//Prints an information message to stderr and to a message box if not in headless mode and not attached to a console
void warning(char *format, ...);
//Prints a debug message to stdout
void debug_message(char *format, ...);
//Prints a log message of the specified level
void log_msg(char *format, log_level level, va_list args);
//Disables output of info and debug messages to stdout
void disable_stdout_messages(void);
//Returns stdout disable status
uint8_t is_stdout_enabled(void);
//Register a method to receive log messages in addition to or in place of stderr/stdout
void register_log_handler(log_fun handler);
//Deletes a file, returns true on success, false on failure
uint8_t delete_file(char *path);
//works like fgets, but calls timeout_cb every timeout_usec microseconds while waiting for input
char *fgets_timeout(char *dst, size_t size, FILE *f, uint64_t timeout_usec, void (*timeout_cb)(void));
#if defined(__ANDROID__) && !defined(IS_LIB)
FILE* fopen_wrapper(const char *path, const char *mode);
#endif

#endif //UTIL_H_
