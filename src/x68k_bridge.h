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
typedef struct {
    X68kByteView ram, ipl, cgrom, sram, tvram, gvram, pal, vc;
    X68kByteView sprite, bgreg, bgram, chr8, chr16;
    X68kPixelView fb;
    int32_t *ram_limit, *screen_w, *screen_h, *dma_vec;
} X68kHostViews;
// One active borrowed machine. Validate every view before changing registration.
// Keep MMU/PPU owners at a stable address until replacement/unbind/destroy;
// process-lifetime RAM/ROM/SRAM views remain until destroy. C never frees them.
uint64_t c_machine_bind(X68kByteView ram, X68kByteView ipl, X68kByteView cgrom, X68kByteView sram,
    X68kByteView tvram, X68kByteView gvram, X68kByteView pal, X68kByteView vc, X68kByteView sprite,
    X68kByteView bgreg, X68kByteView bgram, X68kByteView chr8, X68kByteView chr16, X68kPixelView fb,
    int32_t *ram_limit, int32_t *screen_w, int32_t *screen_h, int32_t *dma_vec);
int c_machine_unbind(uint64_t epoch); // Stale epochs cannot detach a newer owner.
uint64_t c_machine_epoch(void);
void c_machine_reset_devices(void);

// Stdio IO helpers for MCP
int c_io_poll_line(void *out_buf, int max_len, int wait_ms);
void c_io_write_line(const void *data, int len);
int c_audio_init(void);
void c_audio_shutdown(void);
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
void c_gui_settings_store(void);
void c_startup_error(void);

/* Host local time as seconds since 1970-01-01 of the local calendar. */
int64_t c_host_local_seconds(void);

// BMP screenshot saver
int c_save_fb_bmp(X68kByteView path);
int c_save_fb_png(X68kByteView path);
/* The state that lives in C (sound chips, I/O latches, renderer phase) as one flat image.
 * x68k_state.goose stores it; load either applies all of it or changes nothing. */
int64_t c_native_state_size(void);
int c_native_state_save(X68kByteView out);
int c_native_state_check(X68kByteView in);
int c_native_state_load(X68kByteView in);
void c_audio_capture_start(void);
void c_audio_capture_status(int *active, int *frames, int *truncated);
int c_audio_capture_stop(X68kByteView path, int *frames, int *truncated, int *peak, int *silent);
int c_opm_shadow_byte(int index);
int c_opm_key_on(int ch);
int c_host_list_dir(X68kByteView path, char *out, int cap);

// ARCL Hardware State Save/Load
/* Native-only helpers; machine checkpoints are coordinated by x68k_state. */

// Hardware Memory Buffer management
int x68k_mem_init(X68kByteView sys_dir);
int c_mem_set_ram_mb(int32_t mb);
int32_t c_ram_size(void);
void c_ram_limit_bind(int32_t *slot);
void c_ram_bind(uint8_t *ram);
uint8_t *c_ram_base(void);
void x68k_mem_destroy(void);
void c_sram_set_persist(int enabled);

uint8_t c_mem_read_tvram(int32_t off);

uint8_t c_mem_read_gvram(int32_t off);

// Palette RAM (0x00E82000 - 0x00E823FF) & Video Controller (0x00E82400 - 0x00E827FF)
uint8_t c_mem_read_pal(int32_t off);
void c_vcreg_bind(uint8_t *vcreg);

// Sprite Registers (0x00EB0000 - 0x00EB07FF)
void c_set_current_frame(int frame);
uint8_t c_mem_read_sprite(int32_t off);

// BG Control Registers (0x00EB0800 - 0x00EB081F)
uint8_t c_mem_read_bg_reg(int32_t off);

// BG / PCG RAM (0x00EB8000 - 0x00EBFFFF)

void c_ipl_bind(uint8_t *ipl);
void c_cgrom_bind(uint8_t *cgrom);
void c_sram_bind(uint8_t *sram);

/* A disk the user picked from the window menu: 1/2 FD0 insert/eject, 3/4 FD1, 5/6 HDD,
 * 0 none. For an insert, path receives the file name. Disk images live in x68k_disk.goose. */
int c_gui_take_media_request(uint8_t *path, int cap, int32_t *path_len);
/* Point the renderer and state save at Goose-owned buffers. One call, not per byte. */
void c_video_bind(uint8_t *pal, uint8_t *sprite, uint8_t *bgreg, uint8_t *bgram, uint8_t *chr8, uint8_t *chr16);
void c_tvram_bind(uint8_t *tvram);
void c_gvram_bind(uint8_t *gvram);
void c_line_zero(uint16_t *grp, uint8_t *mix, uint16_t *sp, uint16_t *sp2, uint16_t *bg, uint8_t *tr);

// Direct framebuffer operations
void c_screen_bind(int32_t *w, int32_t *h);
void c_set_screen_mode(int32_t w, int32_t h);
int32_t c_get_screen_width(void);
int32_t c_get_screen_height(void);
void c_clear_framebuffer(uint32_t argb);
void c_set_frame_ready(int32_t ready);
void c_fb_bind(uint32_t *fb);

// Hardware acceleration
void c_mem_write_tvram_concurrent(int32_t off, uint8_t val, uint8_t plane_mask);


// Audio / Sound System
void c_sound_init(void);
void c_sound_reset(void);
void c_sound_cleanup(void);
void c_sound_opm_write(uint32_t addr, uint8_t val);
uint8_t c_sound_opm_read(uint32_t addr);
void c_sound_adpcm_write(uint32_t addr, uint8_t val);
uint8_t c_sound_adpcm_read(uint32_t addr);
void c_sound_adpcm_set_pan(uint8_t pan);
void c_sound_scanline_timer(uint32_t cycles);
void c_sound_frame_update(int samples);
int c_sound_poll_irq(void);

/* ADPCM uses DMAC channel 3. The sound core runs the transfer. */
void c_dmac_push_ch3(uint8_t csr, uint8_t cer, uint8_t dcr, uint8_t ocr, uint8_t scr, uint8_t ccr,
                     uint16_t mtc, uint32_t mar, uint32_t dar, uint16_t btc, uint32_t bar,
                     uint8_t niv, uint8_t eiv);
void c_dmac_pull_ch3(uint8_t *csr, uint8_t *cer, uint8_t *ccr, uint16_t *mtc,
                     uint32_t *mar, uint32_t *dar, uint16_t *btc, uint32_t *bar);
void c_dma_vec_bind(int32_t *slot);
void c_fdd_media_bind(int32_t *slot);
void c_dmac_ack_irq(void);

#ifdef __cplusplus
}
#endif

#endif // X68K_BRIDGE_H
