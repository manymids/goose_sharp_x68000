#ifndef X68K_CONFIG_H
#define X68K_CONFIG_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#define X68K_CPU_CLOCK_LIST 10, 16, 25, 50, 75, 100, 150, 200, 250
enum { GUI_CLOCK = 0, GUI_SCALE = 1, GUI_WIDTH = 2 };
enum { GUI_BIOS = 0, GUI_FD0 = 1, GUI_FD1 = 2, GUI_HDD = 3 };

/* Host preferences only. Disabled for ARCL/headless sessions; never checkpointed. */
void c_gui_settings_open(int enabled);
int c_gui_settings_int(int key);
int c_gui_settings_set_int(int key, int value);
int c_gui_settings_path(int key, uint8_t *out, int cap);
int c_gui_settings_set_path(int key, const uint8_t *path, int len);
int c_gui_settings_save(void);
#ifdef __cplusplus
}
#endif
#endif
