#ifndef RENDER_SDL_H_
#define RENDER_SDL_H_

#include <SDL.h>

SDL_Window *render_get_window(uint8_t which);
typedef void (*event_handler)(uint8_t which, SDL_Event *);
void render_set_event_handler(uint8_t which, event_handler handler);
SDL_Joystick *render_get_joystick(int index);
SDL_GameController *render_get_controller(int index);
int render_find_joystick_index(SDL_JoystickID instanceID);
int render_lookup_button(char *name);
int render_lookup_axis(char *name);
void render_enable_gamepad_events(uint8_t enabled);
uint8_t render_are_gamepad_events_enabled(void);

#endif //RENDER_SDL_H_
