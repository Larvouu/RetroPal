#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <ctype.h>
#include <stdint.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <errno.h>

#ifdef __ANDROID__
#include <android/log.h>
#include <SDL_system.h>
#include <jni.h>

android_LogPriority log_level_to_android(log_level)
{
	switch (log_level)
	{
	case DEBUG: return ANDROID_LOG_DEBUG;
	case INFO: ANDROID_LOG_INFO;
	case WARN: ANDROID_LOG_WARN;
	case FATAL: ANDROID_LOG_FATAL;
	}
}

#define log_puts(stream, msg, level) __android_log_write(log_level_to_android(level), "BlastEm", msg)
#define log_printf(sream, format, level, args) __android_log_vprint(log_level_to_android(level), "BlastEm", msg, args)

#else

#define log_puts(stream, msg, level) fputs(msg, stream);
#define log_printf(stream, format, level, args) vfprintf(stream, format, args)

#endif

#include "util.h"

void *aligned_calloc(size_t nmemb, size_t size, size_t align)
{
#ifdef __EMSCRIPTEN__
	return calloc(nmemb, size);
#else
	uint8_t *ret = calloc(1, nmemb * size + align);
	ret += align - (((intptr_t)ret) & (align - 1));
	ret[-1] = (uint8_t)align;
	return ret;
#endif
}

void aligned_free(void *ptr)
{
#ifdef __EMSCRIPTEN__
	free(ptr);
#else
	if (!ptr) {
		return;
	}
	uint8_t *buf = ptr;
	buf -= buf[-1];
	free(buf);
#endif
}

char * alloc_concat(char const * first, char const * second)
{
	int flen = strlen(first);
	int slen = strlen(second);
	char * ret = malloc(flen + slen + 1);
	memcpy(ret, first, flen);
	memcpy(ret+flen, second, slen+1);
	return ret;
}

char * alloc_concat_m(int num_parts, char const ** parts)
{
	int total = 0;
	for (int i = 0; i < num_parts; i++) {
		total += strlen(parts[i]);
	}
	char * ret = malloc(total + 1);
	*ret = 0;
	for (int i = 0; i < num_parts; i++) {
		strcat(ret, parts[i]);
	}
	return ret;
}

char * alloc_join(int num_parts, char const **parts, char sep)
{
	int total = num_parts ? num_parts - 1 : 0;
	for (int i = 0; i < num_parts; i++) {
		total += strlen(parts[i]);
	}
	char * ret = malloc(total + 1);
	char *cur = ret;
	for (int i = 0; i < num_parts; i++) {
		size_t s = strlen(parts[i]);
		if (i) {
			*(cur++) = sep;
		}
		memcpy(cur, parts[i], s);
		cur += s;
	}
	*cur = 0;
	return ret;
}

typedef struct {
	uint32_t start;
	uint32_t end;
	char *value;
} var_pos;

char *replace_vars(char *base, tern_node *vars, uint8_t allow_env)
{
	uint32_t num_vars = 0;
	for (char *cur = base; *cur; ++cur)
	{
		//TODO: Support escaping $ and allow brace syntax
		if (*cur == '$') {
			num_vars++;
		}
	}
	var_pos *positions = calloc(num_vars, sizeof(var_pos));
	num_vars = 0;
	uint8_t in_var = 0;
	uint32_t max_var_len = 0;
	for (char *cur = base; *cur; ++cur)
	{
		if (in_var) {
			if (!isalnum(*cur)) {
				positions[num_vars].end = cur-base;
				if (positions[num_vars].end - positions[num_vars].start > max_var_len) {
					max_var_len = positions[num_vars].end - positions[num_vars].start;
				}
				num_vars++;
				in_var = 0;
			}
		} else if (*cur == '$') {
			positions[num_vars].start = cur-base+1;
			in_var = 1;
		}
	}
	if (in_var) {
		positions[num_vars].end = strlen(base);
		if (positions[num_vars].end - positions[num_vars].start > max_var_len) {
			max_var_len = positions[num_vars].end - positions[num_vars].start;
		}
		num_vars++;
	}
	char *varname = malloc(max_var_len+1);
	uint32_t total_len = 0;
	uint32_t cur = 0;
	for (uint32_t i = 0; i < num_vars; i++)
	{
		total_len += (positions[i].start - 1) - cur;
		cur = positions[i].start;
		memcpy(varname, base + positions[i].start, positions[i].end-positions[i].start);
		varname[positions[i].end-positions[i].start] = 0;
		positions[i].value = tern_find_ptr(vars, varname);
		if (!positions[i].value && allow_env) {
			positions[i].value = getenv(varname);
		}
		if (positions[i].value) {
			total_len += strlen(positions[i].value);
		}
	}
	total_len += strlen(base+cur);
	free(varname);
	char *output = malloc(total_len+1);
	cur = 0;
	char *curout = output;
	for (uint32_t i = 0; i < num_vars; i++)
	{
		if (positions[i].start-1 > cur) {
			memcpy(curout, base + cur, (positions[i].start-1) - cur);
			curout += (positions[i].start-1) - cur;
		}
		if (positions[i].value) {
			strcpy(curout, positions[i].value);
			curout += strlen(curout);
		}
		cur = positions[i].end;
	};
	if (base[cur]) {
		strcpy(curout, base+cur);
	} else {
		*curout = 0;
	}
	free(positions);
	return output;
}

void byteswap_rom(int filesize, uint16_t *cart)
{
	for(uint16_t *cur = cart; cur - cart < filesize/2; ++cur)
	{
		*cur = (*cur >> 8) | (*cur << 8);
	}
}


long file_size(FILE * f)
{
	fseek(f, 0, SEEK_END);
	long fsize = ftell(f);
	fseek(f, 0, SEEK_SET);
	return fsize;
}

char * strip_ws(char * text)
{
	while (*text && (!isprint(*text) || isblank(*text)))
	{
		text++;
	}
	char * ret = text;
	text = ret + strlen(ret) - 1;
	while (text > ret && (!isprint(*text) || isblank(*text)))
	{
		*text = 0;
		text--;
	}
	return ret;
}

char * split_keyval(char * text)
{
	while (*text && !isblank(*text))
	{
		text++;
	}
	if (!*text) {
		return text;
	}
	*text = 0;
	return text+1;
}

uint8_t startswith(const char *haystack, const char *prefix)
{
	return !strncmp(haystack, prefix, strlen(prefix));
}

void bin_to_hex(uint8_t *output, uint8_t *input, uint64_t size)
{
	while (size)
	{
		uint8_t digit = *input >> 4;
		digit += digit > 9 ? 'a' - 0xa : '0';
		*(output++) = digit;
		digit = *(input++) & 0xF;
		digit += digit > 9 ? 'a' - 0xa : '0';
		*(output++) = digit;
		size--;
	}
	*(output++) = 0;
}

char *utf16be_to_utf8(uint8_t *buf, uint32_t max_size)
{
	uint8_t *cur = buf;
	uint32_t converted_size = 0;
	for (uint32_t i = 0; i < max_size; i++, cur+=2)
	{
		uint16_t code = *cur << 16 | cur[1];
		if (!code) {
			break;
		}
		if (code < 0x80) {
			converted_size++;
		} else if (code < 0x800) {
			converted_size += 2;
		} else {
			//TODO: Deal with surrogate pairs
			converted_size += 3;
		}
	}
	char *out = malloc(converted_size + 1);
	char *cur_out = out;
	cur = buf;
	for (uint32_t i = 0; i < max_size; i++, cur+=2)
	{
		uint16_t code = *cur << 16 | cur[1];
		if (!code) {
			break;
		}
		if (code < 0x80) {
			*(cur_out++) = code;
		} else if (code < 0x800) {
			*(cur_out++) = 0xC0 | code >> 6;
			*(cur_out++) = 0x80 | (code & 0x3F);
		} else {
			//TODO: Deal with surrogate pairs
			*(cur_out++) = 0xE0 | code >> 12;
			*(cur_out++) = 0x80 | (code >> 6 & 0x3F);
			*(cur_out++) = 0x80 | (code & 0x3F);
		}
	}
	*cur_out = 0;
	return out;
}

int utf8_codepoint(const char **text)
{
	uint8_t initial = **text;
	(*text)++;
	if (initial < 0x80) {
		return initial;
	}
	int base = 0;
	uint8_t extended_bytes = 0;
	if ((initial & 0xE0) == 0xC0) {
		base = 0x80;
		initial &= 0x1F;
		extended_bytes = 1;
	} else if ((initial & 0xF0) == 0xE0) {
		base = 0x800;
		initial &= 0xF;
		extended_bytes = 2;
	} else if ((initial & 0xF8) == 0xF0) {
		base = 0x10000;
		initial &= 0x7;
		extended_bytes = 3;
	}
	int value = initial;
	for (uint8_t i = 0; i < extended_bytes; i++)
	{
		if ((**text & 0xC0) != 0x80) {
			return -1;
		}
		value = value << 6;
		value |= (**text) & 0x3F;
		(*text)++;
	}
	if (value < base) {
		return 0;
	}
	return value;
}

wchar_t *utf8_to_utf16(const char *text)
{
	const char *cur = text;
	size_t utf16_code_units = 0;
	while (*cur)
	{
		int codepoint = utf8_codepoint(&cur);
		utf16_code_units += codepoint >= 0x10000 ? 2 : 1;
		
	}
	wchar_t *out = calloc(utf16_code_units + 1, sizeof(wchar_t));
	wchar_t *cur_out = out;
	cur = text;
	while (*cur)
	{
		int codepoint = utf8_codepoint(&cur);
		if (codepoint < 0x10000) {
			*(cur_out++) = codepoint;
		} else {
			codepoint -= 0x10000;
			*(cur_out++) = 0xD800 | codepoint >> 10;
			*(cur_out++) = 0xDC00 | (codepoint & 0x3FF);
		}
	}
	return out;
}

char *utf16_to_utf8(const wchar_t *text)
{
	size_t utf8_bytes = 0;
	for (const uint16_t *cur = (const uint16_t *)text; *cur; cur++)
	{
		int codepoint;
		if (*cur < 0xD800 || *cur >= 0xE000) {
			codepoint = *cur;
		} else if (*cur < 0xDC00 && cur[1] >= 0xDD00 && cur[1] < 0xE000) {
			//valid surrogate pair
			codepoint = 0x10000 | (*cur & 0x3FF) << 10 | (cur[1] & 0x3FF);
			cur++;
		} else {
			//take the wtf8 approach
			codepoint = *cur;
		}
		if (codepoint < 0x80) {
			utf8_bytes += 1;
		} else if (codepoint < 0x800) {
			utf8_bytes += 2;
		} else if (codepoint < 0x10000) {
			utf8_bytes += 3;
		} else {
			utf8_bytes += 4;
		}
	}
	char *out = calloc(utf8_bytes + 1, 1);
	char *cur_out = out;
	for (const uint16_t *cur = (const uint16_t *)text; *cur; cur++)
	{
		int codepoint;
		if (*cur < 0xD800 || *cur >= 0xE000) {
			codepoint = *cur;
		} else if (*cur < 0xDC00 && cur[1] >= 0xDD00 && cur[1] < 0xE000) {
			//valid surrogate pair
			codepoint = 0x10000 | (*cur & 0x3FF) << 10 | (cur[1] & 0x3FF);
			cur++;
		} else {
			//take the wtf8 approach
			codepoint = *cur;
		}
		if (codepoint < 0x80) {
			*(cur_out++) = codepoint;
		} else if (codepoint < 0x800) {
			*(cur_out++) = 0xC0 | codepoint >> 6;
			*(cur_out++) = 0x80 | (codepoint & 0x3F);
		} else if (codepoint < 0x10000) {
			*(cur_out++) = 0xE0 | codepoint >> 12;
			*(cur_out++) = 0x80 | (codepoint >> 6 & 0x3F);
			*(cur_out++) = 0x80 | (codepoint & 0x3F);
		} else {
			*(cur_out++) = 0xF0 | codepoint >> 18;
			*(cur_out++) = 0x80 | (codepoint >> 12 & 0x3F);
			*(cur_out++) = 0x80 | (codepoint >> 6 & 0x3F);
			*(cur_out++) = 0x80 | (codepoint & 0x3F);
		}
	}
	return out;
}

uint32_t nearest_pow2(uint32_t val)
{
	uint32_t ret = 1;
	while (ret < val)
	{
		ret = ret << 1;
	}
	return ret;
}

static uint8_t output_enabled = 1;
static log_fun log_handler;
void log_msg(char *format, log_level level, va_list args)
{
	FILE *stream = level >= WARN ? stderr : stdout;
	if (log_handler) {
		//take a guess at the final size
		int32_t size = strlen(format) * 2;
		char *buf = malloc(size);
		va_list tmp;
		va_copy(tmp, args);
		int32_t actual = vsnprintf(buf, size, format, tmp);
		va_end(tmp);
		if (actual >= size || actual < 0) {
			if (actual < 0) {
				//seems on windows, vsnprintf is returning -1 when the buffer is too small
				//since we don't know the proper size, a generous multiplier will hopefully suffice
				actual = size * 4;
			} else {
				actual++;
			}
			free(buf);
			buf = malloc(actual);
			vsnprintf(buf, actual, format, args);
		}
		if (output_enabled || level >= WARN) {
			log_puts(stream, buf, log_level);
		}
		log_handler(level, buf);
		free(buf);
	} else if (output_enabled || level >= WARN) {
		log_printf(stream, format, log_level, args);
	}
}
void fatal_error(char *format, ...)
{
	va_list args;
	va_start(args, format);
	log_msg(format, FATAL, args);
	va_end(args);
	exit(1);
}

void warning(char *format, ...)
{
	va_list args;
	va_start(args, format);
	log_msg(format, WARN, args);
	va_end(args);
}

void info_message(char *format, ...)
{
	va_list args;
	va_start(args, format);
	log_msg(format, INFO, args);
	va_end(args);
}

void debug_message(char *format, ...)
{
	va_list args;
	va_start(args, format);
	log_msg(format, DEBUG, args);
	va_end(args);
}

void disable_stdout_messages(void)
{
	output_enabled = 0;
}

uint8_t is_stdout_enabled(void)
{
	return output_enabled;
}

void register_log_handler(log_fun handler)
{
	log_handler = handler;
}

#ifdef _WIN32
#define WINVER 0x501
#include <windows.h>

static void fix_slashes(wchar_t *path)
{
	for (; *path; path++)
	{
		if (*path == L'/') {
			*path = L'\\';
		}
	}
}

wchar_t *to_windows_path(const char *path)
{
	char *tmp = NULL;
	uint8_t need_working = 0;
	if (!startswith(path, "\\\\?\\")) {
		if ((path[0] == '\\' || path[0] == '/') && (path[1] == '\\' || path[1] == '/')) {
			//absolute UNC path
			tmp = alloc_concat("\\\\?\\UNC", path + 1);
		} else if (isalpha(path[0]) && path[1] == ':' && (path[2] == '\\' || path[2] == '/')) {
			//full absolute path with drive letter
			tmp = alloc_concat("\\\\?\\", path);
			path = tmp;
		} else {
			need_working = 1;
		}
	}
	wchar_t *widepath = utf8_to_utf16(path);
	free(tmp);
	fix_slashes(widepath);
	DWORD unc_length = 0;
	if (need_working) {
		DWORD res = GetCurrentDirectoryW(0, NULL);
		if (!res) {
			return widepath;
		}
		wchar_t *working = calloc(sizeof(wchar_t), res);
		res = GetCurrentDirectoryW(res, working);
		if (res) {
			size_t rel_len = wcslen(widepath);
			if (widepath[0] == L'\\') {
				//path is relative to current drive root rather than current directory
				//truncate the 
				if (working[0] == L'\\') {
					//current drive is a network share
					uint8_t found_server_share_sep = 0;
					for (DWORD i = 2; i < res; i++)
					{
						if (working[i] == L'\\') {
							if (found_server_share_sep) {
								unc_length = res = i;
								break;
							} else {
								found_server_share_sep = 1;
							}
						}
					}
				} else {
					res = 3;
				}
			}
			wchar_t *final = calloc(sizeof(wchar_t), res + rel_len + 6);
			final[0] = L'\\';
			final[1] = L'\\';
			final[2] = L'?';
			final[3] = L'\\';
			memcpy(final + 4, working, sizeof(*working) * res);
			if (final[3 + res] != L'\\') {
				final[4 + res] = L'\\';
				res++;
			}
			if (*widepath == L'\\') {
				res--;
			}
			memcpy(final + 4 + res, widepath, sizeof(*widepath) * (rel_len + 1));
			free(widepath);
			widepath = final;
		}
		free(working);
	}
	// the \\?\ prefix disables processing of .. and . so we need to do it manually
	//portion of the path after drive specification
	wchar_t *dir_start = widepath + (unc_length ? unc_length : 6);
	uint8_t last_was_sep = 0;
	for (wchar_t *cur = dir_start; *cur; cur++)
	{
		if (*cur == L'\\') {
			last_was_sep = 1;
		} else if (last_was_sep && *cur == L'.') {
			if (cur[1] == L'.' && cur[2] == L'\\') {
				//.. -> remove the last path component
				wchar_t *src = cur + 2;
				cur -= 2;
				for(; cur > dir_start; --cur)
				{
					if (*cur == L'\\') {
						break;
					}
				}
				memmove(cur, src, sizeof(wchar_t) * (wcslen(src) + 1));
			} else if (cur[1] == L'\\') {
				//. -> just remove this path component
				cur--;
				memmove(cur, cur + 2, sizeof(wchar_t) * (wcslen(cur + 2) + 1));
			} else {
				last_was_sep = 0;
			}
		} else {
			last_was_sep = 0;
		}
	}
	return widepath;
}

FILE *fopen_utf8(const char *path, const char *mode)
{
	wchar_t *widepath = to_windows_path(path);
	wchar_t *widemode = utf8_to_utf16(mode);
	FILE *ret = _wfopen(widepath, widemode);
	free(widepath);
	free(widemode);
	return ret;
}

dir_entry *get_dir_list(char *path, size_t *numret)
{
	dir_entry *ret;
	if (path[0] == PATH_SEP[0] && !path[1]) {
		int drives = GetLogicalDrives();
		size_t count = 0;
		for (int i = 0; i < 26; i++)
		{
			if (drives & (1 << i)) {
				count++;
			}
		}
		ret = calloc(count, sizeof(dir_entry));
		dir_entry *cur = ret;
		for (int i = 0; i < 26; i++)
		{
			if (drives & (1 << i)) {
				cur->name = malloc(4);
				cur->name[0] = 'A' + i;
				cur->name[1] = ':';
				cur->name[2] = PATH_SEP[0];
				cur->name[3] = 0;
				cur->is_dir = 1;
				cur++;
			}
		}
		if (numret) {
			*numret = count;
		}
	} else {
		HANDLE dir;
		WIN32_FIND_DATAW file;
		char *pattern;
		if (startswith(path, "\\\\?\\")) {
			pattern = alloc_concat(path, "\\*.*");
		} else {
			const char *parts[] = {"\\\\?\\", path, "\\*.*"};
			pattern = alloc_concat_m(3, parts);
		}
		wchar_t *wide_pattern = utf8_to_utf16(pattern);
		fix_slashes(wide_pattern);
		dir = FindFirstFileW(wide_pattern, &file);
		free(pattern);
		free(wide_pattern);
		if (dir == INVALID_HANDLE_VALUE) {
			if (numret) {
				*numret = 0;
			}
			return NULL;
		}

		size_t storage = 64;
		ret = malloc(sizeof(dir_entry) * storage);
		size_t pos = 0;

		if (path[1] == ':' && (!path[2] || (path[2] == PATH_SEP[0] && !path[3]))) {
			//we are in the root of a drive, add a virtual .. entry
			//for navigating to the virtual root directory
			ret[pos].name = strdup("..");
			ret[pos++].is_dir = 1;
		}

		do {
			if (pos == storage) {
				storage = storage * 2;
				ret = realloc(ret, sizeof(dir_entry) * storage);
			}
			ret[pos].name = utf16_to_utf8(file.cFileName);
			ret[pos++].is_dir = (file.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
		} while (FindNextFileW(dir, &file));

		FindClose(dir);
		if (numret) {
			*numret = pos;
		}
	}
	return ret;
}

time_t get_modification_time(char *path)
{
	HANDLE results;
	WIN32_FIND_DATAW file;
	wchar_t *widepath = to_windows_path(path);
	results = FindFirstFileW(widepath, &file);
	free(widepath);
	if (results == INVALID_HANDLE_VALUE) {
		return 0;
	}
	FindClose(results);
	uint64_t wintime = ((uint64_t)file.ftLastWriteTime.dwHighDateTime) << 32 | file.ftLastWriteTime.dwLowDateTime;
	//convert to seconds
	wintime /= 10000000;
	//adjust for difference between Windows and Unix Epoch
	wintime -= 11644473600LL;
	return (time_t)wintime;
}

static int ensure_dir_exists_wide(const wchar_t *widepath)
{
	if (CreateDirectoryW(widepath, NULL)) {
		return 1;
	}
	if (GetLastError() == ERROR_ALREADY_EXISTS) {
		return 1;
	}
	if (GetLastError() != ERROR_PATH_NOT_FOUND) {
		warning("CreateDirectory failed with unexpected error code %X\n", GetLastError());
		return 0;
	}
	wchar_t *parent = _wcsdup(widepath);
	wchar_t *sep = wcsrchr(parent, '\\');
	int ret;
	if (!sep || sep == parent) {
		//relative path, but for some reason we failed
		ret = 0;
		goto done;
	}
	*sep = 0;
	if (!ensure_dir_exists_wide(parent)) {
		ret = 0;
		goto done;
	}
	ret = CreateDirectoryW(widepath, NULL);
done:
	free(parent);
	return ret;
}

int ensure_dir_exists(const char *path)
{
	wchar_t *widepath = to_windows_path(path);
	return ensure_dir_exists_wide(widepath);
}

typedef struct {
	HANDLE           request_event;
	HANDLE           reply_event;
	CRITICAL_SECTION lock;
	FILE             *f;
	char             *dst;
	size_t           size;
} stdio_timeout_state;

static DWORD WINAPI stdio_timeout_thread(LPVOID param)
{
	stdio_timeout_state *state = param;
	EnterCriticalSection(&state->lock);
		for(;;)
		{
			while (!state->f)
			{
				LeaveCriticalSection(&state->lock);
				WaitForSingleObject(state->request_event, INFINITE);
				EnterCriticalSection(&state->lock);
			}
			char *dst = state->dst;
			size_t size = state->size;
			FILE *f = state->f;
			LeaveCriticalSection(&state->lock);
			dst = fgets(dst, size, f);
			EnterCriticalSection(&state->lock);
			state->dst = dst;
			state->f = NULL;
			SetEvent(&state->reply_event);
		}
	LeaveCriticalSection(&state->lock);
	
	return 0;
}

char *fgets_timeout(char *dst, size_t size, FILE *f, uint64_t timeout_usec, void (*timeout_cb)(void))
{
	static HANDLE workerThread;
	static stdio_timeout_state state;
	if (!workerThread) {
		InitializeCriticalSection(&state.lock);
		state.request_event = CreateEventA(NULL, FALSE, FALSE, NULL);
		state.reply_event = CreateEventA(NULL, FALSE, FALSE, NULL);
		workerThread = CreateThread(NULL, 64 * 1024, stdio_timeout_thread, &state, 0, NULL);
	}
	EnterCriticalSection(&state.lock);
		state.f = f;
		state.dst = dst;
		state.size = size;
		SetEvent(state.request_event);
		while (state.f)
		{
			LeaveCriticalSection(&state.lock);
			WaitForSingleObject(state.reply_event, timeout_usec / 1000);
			EnterCriticalSection(&state.lock);
			if (state.f) {
				timeout_cb();
			}
		}
	LeaveCriticalSection(&state.lock);
	return state.dst;
}

#else
#include <fcntl.h>
#include <unistd.h>

char * readlink_alloc(char * path)
{
	char * linktext = NULL;
	ssize_t linksize = 512;
	ssize_t cursize = 0;
	do {
		if (linksize > cursize) {
			cursize = linksize;
			if (linktext) {
				free(linktext);
			}
		}
		linktext = malloc(cursize);
		linksize = readlink(path, linktext, cursize-1);
		if (linksize == -1) {
			perror("readlink");
			free(linktext);
			return NULL;
		}
	} while ((linksize+1) > cursize);
	linktext[linksize] = 0;
	return linktext;
}

char *fgets_timeout(char *dst, size_t size, FILE *f, uint64_t timeout_usec, void (*timeout_cb)(void))
{
	int wait = 1;
	fd_set read_fds;
	FD_ZERO(&read_fds);
	struct timeval timeout;
	do {
		timeout.tv_sec = timeout_usec / 1000000;
		timeout.tv_usec = timeout_usec % 1000000;
		FD_SET(fileno(stdin), &read_fds);
		if(select(fileno(stdin) + 1, &read_fds, NULL, NULL, &timeout) >= 1) {
			wait = 0;
		} else {
			timeout_cb();
		}
	} while (wait);
	return fgets(dst, size, f);
}

#include <dirent.h>

#ifdef __ANDROID__
static dir_entry *jdir_list_helper(JNIEnv *env, jmethodID meth, char *path, size_t *numret)
{
	jstring jpath = (*env)->NewStringUTF(env, path);
	jobject activity = SDL_AndroidGetActivity();
	jobject ret = (*env)->CallObjectMethod(env, activity, meth, jpath);
	dir_entry *res = NULL;
	if (ret) {
		jsize num = (*env)->GetArrayLength(env, ret);
		if (numret) {
			*numret = num;
		}
		res = calloc(num, sizeof(dir_entry));
		for (jsize i = 0; i < num; i++)
		{
			jstring entry = (*env)->GetObjectArrayElement(env, ret, i);
			char const *tmp = (*env)->GetStringUTFChars(env, entry, NULL);
			jsize len = (*env)->GetStringUTFLength(env, entry);
			res[i].name = calloc(len + 1, 1);
			res[i].is_dir = tmp[len-1] == '/';
			memcpy(res[i].name, tmp, res[i].is_dir ? len -1 : len);
			(*env)->ReleaseStringUTFChars(env, entry, tmp);
		}
		(*env)->DeleteLocalRef(env, ret);
	}
	
	(*env)->DeleteLocalRef(env, activity);
	if (!res) {
		if (numret) {
			*numret = 0;
		}
		return NULL;
	}
	return res;
}
#endif

dir_entry *get_dir_list(char *path, size_t *numret)
{
#ifdef __ANDROID__
	debug_message("get_dir_list(%s)\n", path);
	if (startswith(path, "content://")) {
		static const char activity_class_name[] = "com/retrodev/blastem/BlastEmActivity";
		static const char read_uri_dir_name[] = "readUriDir";
		JNIEnv *env = SDL_AndroidGetJNIEnv();
		jclass act_class = (*env)->FindClass(env, activity_class_name);
		if (!act_class) {
			fatal_error("Failed to find activity class %s\n", activity_class_name);
		}
		jmethodID meth = (*env)->GetMethodID(env, act_class, read_uri_dir_name, "(Ljava/lang/String;)[Ljava/lang/String;");
		if (!meth) {
			fatal_error("Failed to find method %s\n", read_uri_dir_name);
		}
		debug_message("get_dir_list(%s) using Storage Access Framework\n", path);
		return jdir_list_helper(env, meth, path, numret);
	}
#endif
	DIR *d = opendir(path);
	if (!d) {
		if (numret) {
			*numret = 0;
		}
		return NULL;
	}
	size_t storage = 64;
	dir_entry *ret = malloc(sizeof(dir_entry) * storage);
	size_t pos = 0;
	struct dirent* entry;
	while (entry = readdir(d))
	{
		if (entry->d_type != DT_REG && entry->d_type != DT_LNK && entry->d_type != DT_DIR) {
			continue;
		}
		if (pos == storage) {
			storage = storage * 2;
			ret = realloc(ret, sizeof(dir_entry) * storage);
		}
		ret[pos].name = strdup(entry->d_name);
		ret[pos++].is_dir = entry->d_type == DT_DIR;
	}
	if (numret) {
		*numret = pos;
	}
	closedir(d);
	return ret;
}

time_t get_modification_time(char *path)
{
	struct stat st;
	if (stat(path, &st)) {
		return 0;
	}
#ifdef __APPLE__
    return st.st_mtimespec.tv_sec;
#else
	//Android's Bionic doesn't support the new style so we'll use the old one instead
	return st.st_mtime;
#endif
}

int ensure_dir_exists(const char *path)
{
	struct stat st;
	if (stat(path, &st)) {
		if (errno == ENOENT) {
			char *parent = strdup(path);
			char *sep = strrchr(parent, '/');
			if (sep && sep != parent) {
				*sep = 0;
				if (!ensure_dir_exists(parent)) {
					free(parent);
					return 0;
				}
				free(parent);
			}
			return mkdir(path, 0777) == 0;
		} else {
			char buf[80];
			strerror_r(errno, buf, sizeof(buf));
			warning("stat failed with error: %s", buf);
			return 0;
		}
	}
	return S_ISDIR(st.st_mode);
}

#endif

void free_dir_list(dir_entry *list, size_t numentries)
{
	for (size_t i = 0; i < numentries; i++)
	{
		free(list[i].name);
	}
	free(list);
}

static int sort_dir_alpha(const void *a, const void *b)
{
	const dir_entry *da, *db;
	da = a;
	db = b;
	if (da->is_dir != db->is_dir) {
		return db->is_dir - da->is_dir;
	}
	return strcasecmp(((dir_entry *)a)->name, ((dir_entry *)b)->name);
}

void sort_dir_list(dir_entry *list, size_t num_entries)
{
	qsort(list, num_entries, sizeof(dir_entry), sort_dir_alpha);
}

uint8_t delete_file(char *path)
{
#ifdef _WIN32
	//TODO: Call Unicode version and prepend special string to remove max path limitation
	wchar_t *widepath = to_windows_path(path);
	uint8_t ret = 0 != DeleteFileW(widepath);
	free(widepath);
	return ret;
#else
	return 0 == unlink(path);
#endif
}

#if defined(__ANDROID__) && !defined(IS_LIB)

#include <SDL.h>
static int open_uri(const char *path, const char *mode)
{
	static const char activity_class_name[] = "com/retrodev/blastem/BlastEmActivity";
	static const char open_uri_as_fd_name[] = "openUriAsFd";
	JNIEnv *env = SDL_AndroidGetJNIEnv();
	jclass act_class = (*env)->FindClass(env, activity_class_name);
	if (!act_class) {
		fatal_error("Failed to find activity class %s\n", activity_class_name);
	}
	jmethodID meth = (*env)->GetMethodID(env, act_class, open_uri_as_fd_name, "(Ljava/lang/String;Ljava/lang/String;)I");
	if (!meth) {
		fatal_error("Failed to find method %s\n", open_uri_as_fd_name);
	}
	jobject activity = SDL_AndroidGetActivity();
	jstring jpath = (*env)->NewStringUTF(env, path);
	jstring jmode = (*env)->NewStringUTF(env, mode);
	int fd = (*env)->CallIntMethod(env, activity, meth, jpath, jmode);
	(*env)->DeleteLocalRef(env, activity);
	return fd;
}

FILE* fopen_wrapper(const char *path, const char *mode)
{
	if (startswith(path, "content://")) {
		debug_message("fopen_wrapper(%s, %s) - Using Storage Access Framework\n", path, mode);
		int fd = open_uri(path, mode);
		if (!fd) {
			return NULL;
		}
		return fdopen(fd, mode);
	} else {
		debug_message("fopen_wrapper(%s, %s) - Norma fopen\n", path, mode);
		return fopen(path, mode);
	}
}

#endif //defined(__ANDROID__) && !defined(IS_LIB)

