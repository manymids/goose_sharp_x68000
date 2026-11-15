#ifndef X68K_BRIDGE_H
#define X68K_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>
#include "x68k_config.h"

#ifdef __cplusplus
extern "C" {
#endif

/* A Goose slice. Paths and file names come as one of these, in UTF-8, without a terminator. */
typedef struct { uint8_t *data; int64_t len; } X68kByteView;
typedef struct { uint32_t *data; int64_t len; } X68kPixelView;
typedef struct { int16_t *data; int64_t len; } X68kSampleView;
typedef struct {
    X68kByteView ram, ipl, cgrom, sram;
    X68kPixelView fb;
    int32_t *ram_limit;
} X68kHostViews;
// One active borrowed machine. Validate every view before changing registration.
// Keep MMU/PPU owners at a stable address until replacement/unbind/destroy;
// process-lifetime RAM/ROM/SRAM views remain until destroy. C never frees them.
uint64_t c_machine_bind(X68kByteView ram, X68kByteView ipl, X68kByteView cgrom, X68kByteView sram,
    X68kPixelView fb, int32_t *ram_limit);
uint64_t c_machine_epoch(void);
void c_machine_reset_devices(void);

// Stdio IO helpers for MCP
int c_io_poll_line(void *out_buf, int max_len, int wait_ms);
void c_io_write_line(const void *data, int len);
int c_audio_init(void);
void c_audio_discard(void);
void c_host_input_discard(void);

// Win32 UI & Window management for 512x512 X68000 Display
bool win32_ui_init(X68kByteView title, int w, int h, int scale);
uint32_t win32_ui_poll(void);
void win32_ui_render_fb(void);
bool win32_ui_is_open(void);
void win32_ui_destroy(void);
void win32_ui_sleep(int ms);
uint64_t win32_ui_get_ticks_ms(void);
uint64_t win32_ui_get_time_us(void);
void win32_ui_wait_until_us(uint64_t target_us);
int win32_ui_get_command(void);
int win32_ui_get_key_scancode(void);
void c_host_key_joy(int vk, int down);
void c_host_joy_reset(void);
int c_host_joy_byte(void);
int c_set_cpu_mhz(int mhz);
int c_get_cpu_mhz(void);
int c_cpu_mhz_ok(int mhz);
int c_get_scale(void);
int c_set_run_ahead(int frames);
int c_get_run_ahead(void);
int c_gui_take_settings_changes(int32_t *width);
int c_full_path(X68kByteView path, uint8_t *out, int cap);
int c_ansi_to_utf8(X68kByteView text, uint8_t *out, int cap);
void c_startup_error(void);

/* Host local time as seconds since 1970-01-01 of the local calendar. */
int64_t c_host_local_seconds(void);

// Directory listing for arcl_host_dir (names, kinds and sizes as JSON)
int c_host_list_dir(X68kByteView path, char *out, int cap);

// Hardware Memory Buffer management
int x68k_mem_init(X68kByteView sys_dir);
int c_mem_set_ram_mb(int32_t mb);
int32_t c_ram_size(void);
void c_ram_limit_bind(int32_t *slot);
void c_ram_bind(uint8_t *ram);
uint8_t *c_ram_base(void);
void x68k_mem_destroy(void);
void c_sram_set_persist(int enabled);

void c_ipl_bind(uint8_t *ipl);
void c_cgrom_bind(uint8_t *cgrom);
void c_sram_bind(uint8_t *sram);

/* A disk the user picked from the window menu: 1/2 FD0 insert/eject, 3/4 FD1, 5/6 HDD,
 * 0 none. For an insert, path receives the file name. Disk images live in x68k_disk.goose. */
int c_gui_take_media_request(uint8_t *path, int cap, int32_t *path_len);
void c_line_zero(uint16_t *grp, uint8_t *mix, uint16_t *sp, uint16_t *sp2, uint16_t *bg, uint8_t *tr);

// Direct framebuffer operations
void c_set_screen_mode(int32_t w, int32_t h);
int32_t c_get_screen_width(void);
int32_t c_get_screen_height(void);
void c_fb_bind(uint32_t *fb);



// Audio output. The sound chips (x68k_opm.goose, x68k_adpcm.goose) make the samples; C only plays
// and captures them.
void c_audio_output(X68kSampleView frame);

#ifdef __cplusplus
}
#endif

#endif // X68K_BRIDGE_H
