#ifndef PATHS_H_
#define PATHS_H_
#include <stdint.h>
#include "util.h"

uint8_t get_initial_browse_path(char **dst);
char *path_append(const char *base, const char *suffix);
char *path_current_dir(void);
//Determines whether a character is a valid path separator for the current platform
char is_path_sep(char c);
//Determines whether a path is considered an absolute path on the current platform
char is_absolute_path(char *path);
//Returns the basename of a path with th extension (if any) stripped
char * basename_no_extension(const char *path);
//Returns the extension from a path or NULL if there is no extension
char *path_extension(char const *path);
//Returns true if the given path matches one of the extensions in the list
uint8_t path_matches_extensions(char *path, const char **ext_list, uint32_t num_exts);
//Returns the directory portion of a path or NULL if there is no directory part
char *path_dirname(const char *path);
//Should be called by main with the value of argv[0] for use by get_exe_dir
void set_exe_str(char * str);
//Returns the directory the executable is in
char * get_exe_dir();
//Returns the user's home directory
char * get_home_dir();
//Returns an appropriate path for storing config files
char const *get_config_dir();
//Returns an appropriate path for saving non-config data like savestates
char const *get_userdata_dir();
//Returns the path of a file bundled with the executable
char *bundled_file_path(char *name);
//Reads a file bundled with the executable
char *read_bundled_file(char *name, uint32_t *sizeret);
//Returns an array of normal files and directories residing in a bundled directory
dir_entry *get_bundled_dir_list(char *name, size_t *num_out);


#endif //PATHS_H_