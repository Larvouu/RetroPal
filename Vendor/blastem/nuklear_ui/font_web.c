#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>
#include "sfnt.h"
#include "../util.h"

uint8_t *default_font(uint32_t *size_out)
{
	sfnt_container *sfnt = NULL;
	FILE *f = fopen("DroidSans.ttf", "rb");
	if (!f) {
		fprintf(stderr, "Failed to open font file DroidSans.ttf\n");
		return NULL;
	}
	long size = file_size(f);
	uint8_t *buffer = malloc(size);
	if (size != fread(buffer, 1, size, f)) {
		fprintf(stderr, "Failed to read font file\n");
		goto cleanup;
	}
	fclose(f);
	f = NULL;
	sfnt = load_sfnt(buffer, size);
	if (!sfnt) {
		fprintf(stderr, "File does not contain SFNT resources\n");
		goto cleanup;
	}
	for (uint8_t j = 0; j < sfnt->num_fonts; j++)
	{
		if (sfnt_has_truetype_glyphs(sfnt->tables + j)) {
			return sfnt_flatten(sfnt->tables + j, size_out);
		}
		fprintf(stderr, "Font %s in file doesn't have TrueType glyphs\n", sfnt_name(sfnt->tables + j, SFNT_POSTSCRIPT));
	}
cleanup:
	if (sfnt) {
		sfnt_free(sfnt);
	} else {
		free(buffer);
	}
	if (f) {
		fclose(f);
	}
	return NULL;
}
