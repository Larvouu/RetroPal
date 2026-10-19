#include <windows.h>
#include <stdint.h>
#include "../util.h"

uint8_t native_filechooser_available(void)
{
	return 1;
}

char* native_filechooser_pick(const char *title, const char *start_directory)
{
	wchar_t *wide_start = utf8_to_utf16(start_directory);
	wchar_t *wide_title = utf8_to_utf16(title);
	wchar_t file_name[32767] = L"";
	OPENFILENAMEW ofn = {
		.lStructSize = sizeof(ofn),
		.hwndOwner = NULL, //TODO: should probably get the HWND of the main window
		.lpstrFilter = 
			L"All Files\0*.*\0"
			L"All Supported Types\0*.zip;*.bin;*.bin.gz;*.gen;*.gen.gz;*.md;*.md.gz;*.sms;*.sms.gz;*.gg;*.gg.gz;*.sg;*.sg.gz;*.cue;*.toc;*.flac;*.vgm;*.vgz;*.vgm.gz\0"
			L"Genesis/MD\0.zip;*.bin;*.bin.gz;*.gen;*.gen*.gz;*.md;*.md.gz\0"
			L"Sega/Mega CD\0*.cue;*.toc\0"
			L"Sega 8-bit\0*.sms;*.sms.gz;*.gg;*.gg.gz;*.sg;*.sg.gz\0"
			L"Audio/VGM\0*.flac;*.vgm;*.vgz;*.vgm.gz\0",
		.nFilterIndex = 2,
		.lpstrFile = file_name,
		.nMaxFile = sizeof(file_name)/sizeof(file_name[0]),
		.lpstrInitialDir = wide_start,
		.lpstrTitle = wide_title,
		.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_LONGNAMES,
	};
	char *ret = NULL;
	if (GetOpenFileNameW(&ofn)) {
		ret = utf16_to_utf8(file_name);
	}
	free(wide_start);
	free(wide_title);
	return ret;
}
