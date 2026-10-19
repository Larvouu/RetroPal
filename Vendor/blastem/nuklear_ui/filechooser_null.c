#include <stddef.h>
#include <stdint.h>

uint8_t native_filechooser_available(void)
{
	return 0;
}

char* native_filechooser_pick(const char *title, const char *start_directory)
{
	return NULL;
}
