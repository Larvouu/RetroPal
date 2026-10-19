#ifndef DEBUG_UI_H_
#define DEBUG_UI_H_

#include "../render.h"

uint8_t debug_create_window(uint8_t debug_type, char *caption, uint32_t width, uint32_t height, window_close_handler close_handler);

#endif //DEBUG_UI_H_
