#include <string.h>
#include <stdlib.h>
#include "blastem.h"
#include "util.h"
#include "config.h"
#include "paths.h"
#ifdef _WIN32
#define WINVER 0x501
#include <windows.h>
#include <versionhelpers.h>
#include <shlobj.h>
#else
#include <unistd.h>
#include <errno.h>
#endif
#ifdef __ANDROID__
#include <SDL_system.h>
#include <jni.h>
#endif

static char **current_path;

static char *sticky_path_path(void)
{
	if (is_config_in_exe_dir(config)) {
		return path_append(get_exe_dir(), "sticky_path");
	} else {
		return path_append(get_config_dir(), "sticky_path");
	}
}

static void persist_path(void)
{
	char *pathfname = sticky_path_path();
	FILE *f = fopen(pathfname, "wb");
	if (f) {
		if (fwrite(*current_path, 1, strlen(*current_path), f) != strlen(*current_path)) {
			warning("Failed to save menu path");
		}
		fclose(f);
	} else {
		warning("Failed to save menu path: Could not open %s for writing\n", pathfname);
		
	}
	free(pathfname);
}

#ifdef __ANDROID__
static char *get_external_storage_path()
{
	static char *ret;
	if (ret) {
		return ret;
	}
	JNIEnv *env = SDL_AndroidGetJNIEnv();
	if ((*env)->PushLocalFrame(env, 8) < 0) {
		return NULL;
	}

	jclass Environment = (*env)->FindClass(env, "android/os/Environment");
	jmethodID getExternalStorageDirectory =
		(*env)->GetStaticMethodID(env, Environment, "getExternalStorageDirectory", "()Ljava/io/File;");
	jobject file = (*env)->CallStaticObjectMethod(env, Environment, getExternalStorageDirectory);
	if (!file) {
		goto cleanup;
	}

	jmethodID getAbsolutePath = (*env)->GetMethodID(env, (*env)->GetObjectClass(env, file),
		"getAbsolutePath", "()Ljava/lang/String;");
	jstring path = (*env)->CallObjectMethod(env, file, getAbsolutePath);

	char const *tmp = (*env)->GetStringUTFChars(env, path, NULL);
	ret = strdup(tmp);
	(*env)->ReleaseStringUTFChars(env, path, tmp);

cleanup:
	(*env)->PopLocalFrame(env, NULL);
	return ret;
}
#endif

uint8_t get_initial_browse_path(char **dst)
{
	char *base = NULL;
#ifdef __ANDROID__
	static const char activity_class_name[] = "com/retrodev/blastem/BlastEmActivity";
	static const char get_rom_path_name[] = "getRomPath";
	JNIEnv *env = SDL_AndroidGetJNIEnv();
	jclass act_class = (*env)->FindClass(env, activity_class_name);
	if (!act_class) {
		fatal_error("Failed to find activity class %s\n", activity_class_name);
	}
	jmethodID meth = (*env)->GetMethodID(env, act_class, get_rom_path_name, "()Ljava/lang/String;");
	if (!meth) {
		fatal_error("Failed to find method %s\n", get_rom_path_name);
	}
	jobject activity = SDL_AndroidGetActivity();
	jobject ret = (*env)->CallObjectMethod(env, activity, meth);
	char *res = NULL;
	if (ret) {
		const char*utf = (*env)->GetStringUTFChars(env, (jstring)ret, NULL);
		jsize len = (*env)->GetStringUTFLength(env, (jstring)ret);
		res = calloc(len + 1, 1);
		memcpy(res, utf, len);
		debug_message("Got initial browse path: %s\n", res);
		(*env)->ReleaseStringUTFChars(env, (jstring)ret, utf);
		(*env)->DeleteLocalRef(env, ret);
	}
	
	(*env)->DeleteLocalRef(env, activity);
	if (res) {
		*dst = res;
		return 1;
	}
	return 0;
#else
	char *remember_path = tern_find_path(config, "ui\0remember_path\0", TVAL_PTR).ptrval;
	if (!remember_path || !strcmp("on", remember_path)) {
		char *pathfname = sticky_path_path();
		FILE *f = fopen(pathfname, "rb");
		if (f) {
			long pathsize = file_size(f);
			if (pathsize > 0) {
				base = malloc(pathsize + 1);
				if (fread(base, 1, pathsize, f) != pathsize) {
					warning("Error restoring saved file browser path");
					free(base);
					base = NULL;
				} else {
					base[pathsize] = 0;
				}
			}
			fclose(f);
		}
		free(pathfname);
		if (!current_path) {
			atexit(persist_path);
			current_path = dst;
		}
	}
	if (!base) {
		base = strdup(tern_find_path(config, "ui\0initial_path\0", TVAL_PTR).ptrval);
	}
#endif
	if (!base){
#ifdef __ANDROID__
		
		base = get_external_storage_path();
#else
		base = strdup("$HOME");
#endif
	}
	tern_node *vars = tern_insert_ptr(NULL, "HOME", get_home_dir());
	vars = tern_insert_ptr(vars, "EXEDIR", get_exe_dir());
	*dst = replace_vars(base, vars, 1);
	free(base);
	tern_free(vars);
	return 1;
}

char *path_append(const char *base, const char *suffix)
{
	if (!strcmp(suffix, "..")) {
#ifdef _WIN32
		//handle transition from root of a drive to virtual root
		if (base[1] == ':' && !base[2]) {
			return strdup(PATH_SEP);
		}
#endif
		size_t len = strlen(base);
		while (len > 0) {
			--len;
			if (is_path_sep(base[len])) {
				if (!len) {
					//special handling for /
					len++;
				}
				char *ret = malloc(len+1);
				memcpy(ret, base, len);
				ret[len] = 0;
				return ret;
			}
		}
		return strdup(PATH_SEP);
	} else {
#ifdef _WIN32
		if (base[0] == PATH_SEP[0] && !base[1]) {
			//handle transition from virtual root to root of a drive
			return strdup(suffix);
		}
#endif
		if (is_path_sep(base[strlen(base) - 1])) {
			return alloc_concat(base, suffix);
		} else {
			char const *pieces[] = {base, PATH_SEP, suffix};
			return alloc_concat_m(3, pieces);
		}
	}
}

char *path_current_dir(void)
{
	size_t size = 128;
	char *res = malloc(size);
	for (;;) {
#ifdef _WIN32
		DWORD actual = GetCurrentDirectoryA(size, res);
		if (actual > size) {
			res = realloc(res, actual);
			size = actual;
		} else {
			return res;
		}
#else
		errno = 0;
		char *tmp = getcwd(res, size);
		if (!tmp) {
			if (errno == ERANGE) {
				size *= 2;
				res = realloc(res, size);
			} else {
				free(res);
				return NULL;
			}
		} else {
			return res;
		}
#endif
	}
}

char is_path_sep(char c)
{
#ifdef _WIN32
	if (c == '\\') {
		return 1;
	}
#endif
	return c == '/';
}

char is_absolute_path(char *path)
{
#ifdef _WIN32
	if (path[1] == ':' && is_path_sep(path[2]) && isalpha(path[0])) {
		return 1;
	}
#endif
	return is_path_sep(path[0]);
}

char * basename_no_extension(const char *path)
{
	const char *lastdot = NULL;
	const char *lastslash = NULL;
	const char *cur;
	for (cur = path; *cur; cur++)
	{
		if (*cur == '.') {
			lastdot = cur;
		} else if (is_path_sep(*cur)) {
			lastslash = cur + 1;
		}
	}
	if (!lastdot) {
		lastdot = cur;
	}
	if (!lastslash) {
		lastslash = path;
	}
	char *barename = malloc(lastdot-lastslash+1);
	memcpy(barename, lastslash, lastdot-lastslash);
	barename[lastdot-lastslash] = 0;

	return barename;
}

char *path_extension(char const *path)
{
	char const *lastdot = NULL;
	char const *lastslash = NULL;
	char const *cur;
	for (cur = path; *cur; cur++)
	{
		if (*cur == '.') {
			lastdot = cur;
		} else if (is_path_sep(*cur)) {
			lastslash = cur + 1;
		}
	}
	if (!lastdot || (lastslash && lastslash > lastdot)) {
		//no extension
		return NULL;
	}
	return strdup(lastdot+1);
}

uint8_t path_matches_extensions(char *path, const char **ext_list, uint32_t num_exts)
{
	char *ext = path_extension(path);
	if (!ext) {
		return 0;
	}
	uint32_t extidx;
	for (extidx = 0; extidx < num_exts; extidx++)
	{
		if (!strcasecmp(ext, ext_list[extidx])) {
			free(ext);
			return 1;
		}
	}
	free(ext);
	return 0;
}

char * path_dirname(const char *path)
{
	const char *lastslash = NULL;
	const char *cur;
	for (cur = path; *cur; cur++)
	{
		if (is_path_sep(*cur)) {
			lastslash = cur;
		}
	}
	if (!lastslash) {
		return NULL;
	}
	char *dir = malloc(lastslash-path+1);
	memcpy(dir, path, lastslash-path);
	dir[lastslash-path] = 0;

	return dir;
}

static char * exe_str;

void set_exe_str(char * str)
{
	exe_str = str;
}

#ifdef _WIN32

typedef HRESULT (WINAPI *SHGetKnownFolderPath_t)(REFKNOWNFOLDERID, DWORD, HANDLE, PWSTR *);
static SHGetKnownFolderPath_t SHGetKnownFolderPath_ptr;
static void maybe_get_shgetknownfolderpath(void)
{
	if (!SHGetKnownFolderPath_ptr && IsWindowsVistaOrGreater()) {
		SHGetKnownFolderPath_ptr = (SHGetKnownFolderPath_t)GetProcAddress(GetModuleHandle("shell32.dll"), "SHGetKnownFolderPath");
	}
}

char *get_home_dir()
{
	static char *ret;
	static wchar_t path[MAX_PATH];
	if (!ret) {
		maybe_get_shgetknownfolderpath();		
		if (SHGetKnownFolderPath_ptr) {
			//{5E6C858F-0E22-4760-9AFE-EA3317B67173}
	static GUID my_folderid_profile = {0x5E6C858F, 0x0E22, 0x4760, {0x9A, 0xFE, 0xEA, 0x33, 0x17, 0xB6, 0x71, 0x73}};
			wchar_t *wide_ret = NULL;
			if (S_OK == SHGetKnownFolderPath_ptr(&my_folderid_profile, 0, NULL, &wide_ret)) {
				ret = utf16_to_utf8(wide_ret);
			}
			if (wide_ret) {
				CoTaskMemFree(wide_ret);
			}
		} else {
			SHGetFolderPathW(NULL, CSIDL_PROFILE, NULL, 0, path);
			ret = utf16_to_utf8(path);
		}
	}
	return ret;
}

char *get_exe_dir()
{
	static char *ret;
	if (!ret) {
		static wchar_t path[32767];
		HMODULE module = GetModuleHandleW(NULL);
		GetModuleFileNameW(module, path, sizeof(path)/sizeof(*path));

		int pathsize = wcslen(path);
		for(wchar_t * cur = path + pathsize - 1; cur != path; cur--)
		{
			if (*cur == L'\\') {
				*cur = 0;
				break;
			}
		}
		ret = utf16_to_utf8(path);
	}
	return ret;
}

char const *get_userdata_dir()
{
	static char *ret;
	static wchar_t path[MAX_PATH];
	if (!ret) {
		maybe_get_shgetknownfolderpath();
		if (SHGetKnownFolderPath_ptr) {
			//{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}
			static GUID my_folderid_localappdata = {0xF1B32785, 0x6FBA, 0x4FCF, {0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91}};
			wchar_t *wide_ret = NULL;
			//KF_FLAG_CREATE = 0x00008000
			if (S_OK == SHGetKnownFolderPath_ptr(&my_folderid_localappdata, 0x00008000, NULL, &wide_ret)) {
				ret = utf16_to_utf8(wide_ret);
			}
			if (wide_ret) {
				CoTaskMemFree(wide_ret);
			}
		} else {
			if (S_OK != SHGetFolderPathW(NULL, CSIDL_LOCAL_APPDATA | CSIDL_FLAG_CREATE, NULL, 0, path)) {
				return NULL;
			}
			ret = utf16_to_utf8(path);
		}
	}
	return ret;
}

char const *get_config_dir()
{
	static char* confdir;
	if (!confdir) {
		char const *base = get_userdata_dir();
		if (base) {
			confdir = alloc_concat(base,  PATH_SEP "blastem");
		}
	}
	return confdir;
}

#else

char * get_home_dir()
{
	return getenv("HOME");
}

char * get_exe_dir()
{
	static char * exe_dir;
	if (!exe_dir) {
		char * cur;
#ifdef HAS_PROC
		char * linktext = readlink_alloc("/proc/self/exe");
		if (!linktext) {
			goto fallback;
		}
		int linksize = strlen(linktext);
		for(cur = linktext + linksize - 1; cur != linktext; cur--)
		{
			if (is_path_sep(*cur)) {
				*cur = 0;
				break;
			}
		}
		if (cur == linktext) {
			free(linktext);
fallback:
#endif
			if (!exe_str) {
				fputs("/proc/self/exe is not available and set_exe_str was not called!", stderr);
			}
			int pathsize = strlen(exe_str);
			for(cur = exe_str + pathsize - 1; cur != exe_str; cur--)
			{
				if (is_path_sep(*cur)) {
					exe_dir = malloc(cur-exe_str+1);
					memcpy(exe_dir, exe_str, cur-exe_str);
					exe_dir[cur-exe_str] = 0;
					break;
				}
			}
#ifdef HAS_PROC
		} else {
			exe_dir = linktext;
		}
#endif
	}
	return exe_dir;
}

#ifdef __ANDROID__
#include <SDL.h>

char const *get_config_dir()
{
	return SDL_AndroidGetInternalStoragePath();
}

char const *get_userdata_dir()
{
	return SDL_AndroidGetInternalStoragePath();
}

#ifndef IS_LIB
char *read_bundled_file(char *name, uint32_t *sizeret)
{
	SDL_RWops *rw = SDL_RWFromFile(name, "rb");
	if (!rw) {
		if (sizeret) {
			*sizeret = -1;
		}
		return NULL;
	}

	long fsize = rw->size(rw);
	if (sizeret) {
		*sizeret = fsize;
	}
	char *ret;
	if (fsize) {
		ret = malloc(fsize);
		if (SDL_RWread(rw, ret, 1, fsize) != fsize) {
			free(ret);
			ret = NULL;
		}
	} else {
		ret = NULL;
	}
	SDL_RWclose(rw);
	return ret;
}

dir_entry *get_bundled_dir_list(char *name, size_t *num_out)
{
	static const char activity_class_name[] = "com/retrodev/blastem/BlastEmActivity";
	static const char get_assets_list_name[] = "getAssetsList";
	JNIEnv *env = SDL_AndroidGetJNIEnv();
	jclass act_class = (*env)->FindClass(env, activity_class_name);
	if (!act_class) {
		fatal_error("Failed to find activity class %s\n", activity_class_name);
	}
	jmethodID meth = (*env)->GetMethodID(env, act_class, get_assets_list_name, "(Ljava/lang/String;)[Ljava/lang/String;");
	if (!meth) {
		fatal_error("Failed to find method %s\n", get_assets_list_name);
	}
	return jdir_list_helper(env, meth, name, num_out);
}
#endif
#else


#define CONFIG_PREFIX "/.config"
#define USERDATA_SUFFIX "/.local/share"

char const *get_config_dir()
{
	static char* confdir;
	if (!confdir) {
		char const *base = get_home_dir();
		if (base) {
			confdir = alloc_concat(base, CONFIG_PREFIX PATH_SEP "blastem");
		}
	}
	return confdir;
}

char const *get_userdata_dir()
{
	static char* savedir;
	if (!savedir) {
		char const *base = get_home_dir();
		if (base) {
			savedir = alloc_concat(base, USERDATA_SUFFIX);
		}
	}
	return savedir;
}

#endif //__ANDROID__

#endif //_WIN32

#if !defined(__ANDROID__) && !defined(IS_LIB)
char *bundled_file_path(char *name)
{
#ifdef DATA_PATH
	char *data_dir = DATA_PATH;
#else
	char *data_dir = get_exe_dir();
	if (!data_dir) {
		return NULL;
	}
#endif
	char const *pieces[] = {data_dir, PATH_SEP, name};
	return alloc_concat_m(3, pieces);
}

char *read_bundled_file(char *name, uint32_t *sizeret)
{
	char *path = bundled_file_path(name);
	if (!path) {
		if (sizeret) {
			*sizeret = -1;
		}
		return NULL;
	}
	FILE *f = fopen(path, "rb");
	free(path);
	if (!f) {
		if (sizeret) {
			*sizeret = -1;
		}
		return NULL;
	}

	long fsize = file_size(f);
	if (sizeret) {
		*sizeret = fsize;
	}
	char *ret;
	if (fsize) {
		//reserve an extra byte in case caller wants
		//to null terminate the data
		ret = malloc(fsize+1);
		if (fread(ret, 1, fsize, f) != fsize) {
			free(ret);
			ret = NULL;
		}
	} else {
		ret = NULL;
	}
	fclose(f);
	return ret;
}

dir_entry *get_bundled_dir_list(char *name, size_t *num_out)
{
	char *path = bundled_file_path(name);
	dir_entry *ret = get_dir_list(path, num_out);
	free(path);
	return ret;
}
#endif

