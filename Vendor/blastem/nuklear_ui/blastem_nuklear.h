#ifndef BLASTEM_NUKLEAR_H_
#define BLASTEM_NUKLEAR_H_

#define NK_INCLUDE_FIXED_TYPES
#define NK_INCLUDE_STANDARD_IO
#define NK_INCLUDE_STANDARD_VARARGS
#define NK_INCLUDE_DEFAULT_ALLOCATOR
#define NK_INCLUDE_VERTEX_BUFFER_OUTPUT
#define NK_INCLUDE_FONT_BAKING
#include "nuklear.h"
#include "nuklear_sdl_gles2.h"

struct nk_context *shared_nuklear_init(uint8_t window);
void blastem_nuklear_init(uint8_t file_loaded);
void show_pause_menu(void);
void show_play_view(void);
uint8_t is_nuklear_active(void);
uint8_t is_nuklear_available(void);
//ui_idle_loop calls these automatically, needed externally for browser target
void ui_enter(void);
void ui_exit(void);
void ui_idle_loop(void);
uint8_t show_freeze_choice(uint8_t *session_default, const char *msg);

#endif //BLASTEM_NUKLEAR_H_
