#ifndef FILECHOOSER_H_
#define FILECHOOSER_H_

uint8_t native_filechooser_available(void);
char* native_filechooser_pick(const char *title, const char *start_directory);

#endif //FILECHOOSER_H_
