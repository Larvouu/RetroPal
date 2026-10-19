#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "../util.h"
#include "sfnt.h"

char **preferred_font_paths(uint32_t *num_out)
{
	char ** ret;
#ifdef FONT_PATH
	FILE *f = fopen(FONT_PATH, "rb");
	if (f) {
		fclose(f);
		ret = calloc(1, sizeof(char*));
		ret[0] = strdup(FONT_PATH);
		*num_out = 1;
		return ret;
	}
#endif
	//TODO: specify language dynamically once BlastEm is localized
	FILE *fc_pipe = popen("fc-match -s -f '%{file}\n' :lang=en", "r");
	if (!fc_pipe) {
		return NULL;
	}
	size_t buf_size = 2048;
	char *buffer = NULL;
	size_t total = 0, read = 0;
	do {
		total += read;
		buf_size *= 2;
		buffer = realloc(buffer, buf_size);
		if (!buffer) {
			return NULL;
		}
		read = fread(buffer + total, 1, buf_size - total, fc_pipe);
	} while (read == (buf_size - total));
	total += read;
	buffer[total] = 0;
	*num_out = 0;
	for (size_t i = 0; i < total; i++)
	{
		if (buffer[i] == '\n') {
			buffer[i] = 0;
			if (i + 1 != total) {
				(*num_out)++;
			}
		}
	}
	ret = calloc(*num_out, sizeof(char*));
	size_t entry = 0;
	ret[entry++] = buffer;
	for (size_t i = 0; i < total - 1 && entry < *num_out; i++)
	{
		if (!buffer[i]) {
			ret[entry++] = buffer + i + 1;
		}
	}
	return ret;
}

uint8_t *default_font(uint32_t *size_out)
{
	uint8_t *ret = NULL;
	uint32_t num_fonts;
	char **paths = preferred_font_paths(&num_fonts);
	if (!paths) {
		goto error;
	}
	for (uint32_t i = 0; i < num_fonts && !ret; i++)
	{
		FILE *f = fopen(paths[i], "rb");
		if (!f) {
			fprintf(stderr, "Failed to open font file %s\n", paths[i]);
			continue;
		}
		long size = file_size(f);
		uint8_t *buffer = malloc(size);
		if (size != fread(buffer, 1, size, f)) {
			fprintf(stderr, "Failed to read font file %s\n", paths[i]);
			fclose(f);
			continue;
		}
		fclose(f);
		sfnt_container *sfnt = load_sfnt(buffer, size);
		if (!sfnt) {
			fprintf(stderr, "File %s does not contain SFNT resources\n", paths[i]);
			free(buffer);
			continue;
		}
		for (uint8_t j = 0; j < sfnt->num_fonts; j++)
		{
			if (sfnt_has_truetype_glyphs(sfnt->tables + j)) {
				ret = sfnt_flatten(sfnt->tables + j, size_out);
				sfnt = NULL;
				break;
			}
			fprintf(stderr, "Font %s in file %s doesn't have TrueType glyphs\n", sfnt_name(sfnt->tables + j, SFNT_POSTSCRIPT), paths[i]);
		}
		if (sfnt) {
			sfnt_free(sfnt);
		}
	}
	free(paths[0]);
	free(paths);
error:
	//TODO: try to find a suitable font in /usr/share/fonts as a fallback
	return ret;
}