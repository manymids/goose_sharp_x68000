#ifndef X68K_BRIDGE_H
#define X68K_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>
#include "x68k_config.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct { uint8_t *data; int64_t len; } X68kByteView;
typedef struct { uint32_t *data; int64_t len; } X68kPixelView;
typedef struct {
    X68kByteView ram, ipl, cgrom, sram, tvram, gvram, pal, vc;
    X68kByteView sprite, bgreg, bgram, chr8, chr16;
    X68kPixelView fb;
    int32_t *ram_limit, *screen_w, *screen_h, *dma_vec, *media_irq;
} X68kHostViews;
// One active borrowed machine. Validate every view before changing registration.
// Keep MMU/PPU owners at a stable address until replacement/unbind/destroy;
// process-lifetime RAM/ROM/SRAM views remain until destroy. C never frees them.
uint64_t c_machine_bind(X68kByteView ram, X68kByteView ipl, X68kByteView cgrom, X68kByteView sram,
    X68kByteView tvram, X68kByteView gvram, X68kByteView pal, X68kByteView vc, X68kByteView sprite,
    X68kByteView bgreg, X68kByteView bgram, X68kByteView chr8, X68kByteView chr16, X68kPixelView fb,
    int32_t *ram_limit, int32_t *screen_w, int32_t *screen_h, int32_t *dma_vec, int32_t *media_irq);
int c_machine_unbind(uint64_t epoch); // Stale epochs cannot detach a newer owner.
uint64_t c_machine_epoch(void);
void c_mem_test_fail_init(int after);
void c_machine_reset_devices(void);

// Stdio IO helpers for MCP
int c_io_read_line(void *out_buf, int max_len);
int c_io_poll_line(void *out_buf, int max_len, int wait_ms);
void c_io_write_line(const void *data, int len);
int c_audio_init(void);
void c_audio_shutdown(void);
void c_audio_discard(void);
void c_host_input_discard(void);

// Win32 UI & Window management for 512x512 X68000 Display
bool win32_ui_init(const uint8_t *title, int title_len, int w, int h, int scale);
uint32_t win32_ui_poll(void);
void win32_ui_render_fb(void);
bool win32_ui_is_open(void);
void win32_ui_destroy(void);
void win32_ui_sleep(int ms);
uint64_t win32_ui_get_ticks_ms(void);
uint64_t win32_ui_get_time_us(void);
void win32_ui_wait_until_us(uint64_t target_us);
int win32_ui_get_command(void);
int win32_ui_get_char(void);
int win32_ui_get_key_scancode(void);
void c_host_key_joy(int vk, int down);
void c_host_joy_reset(void);
int c_host_joy_byte(void);
int c_set_cpu_mhz(int mhz);
int c_get_cpu_mhz(void);
void c_gui_settings_store(void);
void c_startup_error(void);

// Raw File IO helpers
int c_file_read(const uint8_t *path, int path_len, void *out_buf, int max_len);
int c_file_write(const uint8_t *path, int path_len, const void *buf, int len);
int c_last_path_len(void);

// BMP screenshot saver
int c_save_fb_bmp(const uint8_t *path, int path_len);
int c_save_fb_png(const uint8_t *path, int path_len);
int c_default_system_dir(char *out, int cap);
int c_default_disk_path(char *out, int cap);
int c_vk_to_x68k(int vk, int extended);
int c_extra_save(int bank, int idx);
int c_extra_load(int bank, int idx);
void c_extra_drop(int bank, int idx);
int c_extra_bytes(int bank, int idx);
int c_extra_total(int bank);
int c_state_capture(int bank, int idx);
int c_state_validate(int bank, int idx);
int c_state_restore(int bank, int idx);
uint64_t c_state_generation(int bank, int idx);
void c_state_drop(int bank, int idx);
int c_state_bytes(int bank, int idx);
void c_audio_capture_start(void);
void c_audio_capture_status(int *active, int *frames, int *truncated);
int c_audio_capture_stop(const uint8_t *path, int path_len, int *frames, int *truncated, int *peak, int *silent);
int c_opm_shadow_byte(int index);
int c_opm_key_on(int ch);
int c_host_list_dir(const uint8_t *path, int path_len, char *out, int cap);

// ARCL Hardware State Save/Load
/* Native-only helpers; machine checkpoints are coordinated by x68k_state. */
int c_mem_save_state(int slot);
int c_mem_load_state(int slot);
int c_mem_test_break_version(int slot);
void c_mem_test_fail_alloc(int after);
int c_mem_test_alloc_count(void);
int c_mem_test_corrupt_slot(int slot, int kind);
int c_ppu_get_phase(void);
void c_ppu_set_phase(int phase);
void c_sound_render(int16_t *buf, int32_t samples);

// Hardware Memory Buffer management
int x68k_mem_init(const uint8_t *sys_dir, int sys_len, const uint8_t *floppy_path, int floppy_len);
int c_mem_set_ram_mb(int32_t mb);
int32_t c_ram_size(void);
void c_ram_limit_bind(int32_t *slot);
void c_ram_bind(uint8_t *ram);
uint8_t *c_ram_base(void);
void x68k_mem_destroy(void);

uint8_t c_mem_read_tvram(int32_t off);
void c_mem_write_tvram(int32_t off, uint8_t val);
void c_mem_clear_tvram(void);

uint8_t c_mem_read_gvram(int32_t off);
void c_mem_write_gvram(int32_t off, uint8_t val);

// Palette RAM (0x00E82000 - 0x00E823FF) & Video Controller (0x00E82400 - 0x00E827FF)
uint8_t c_mem_read_pal(int32_t off);
void c_mem_write_pal(int32_t off, uint8_t val);
void c_vcreg_bind(uint8_t *vcreg);

// Sprite Registers (0x00EB0000 - 0x00EB07FF)
void c_set_current_frame(int frame);
int c_get_current_frame();
void c_log_duff(uint32_t a5, uint32_t a6, uint32_t d7, uint32_t ret_pc);
void c_log_ram_write(uint32_t addr, uint8_t val, uint32_t pc);
uint8_t c_mem_read_sprite(int32_t off);
void c_mem_write_sprite(int32_t off, uint8_t val);

// BG Control Registers (0x00EB0800 - 0x00EB081F)
uint8_t c_mem_read_bg_reg(int32_t off);
void c_mem_write_bg_reg(int32_t off, uint8_t val);

// BG / PCG RAM (0x00EB8000 - 0x00EBFFFF)
uint8_t c_mem_read_bgram(int32_t off);
void c_mem_write_bgram(int32_t off, uint8_t val);

void c_ipl_bind(uint8_t *ipl);
void c_cgrom_bind(uint8_t *cgrom);
void c_sram_bind(uint8_t *sram);

// Floppy disk helpers (FD0, FD1)
int c_fdd_load_file(int32_t drive, const uint8_t *path, int path_len);
void c_fdd_eject(int32_t drive);
void c_fdd_media_reset(void);
void c_fdd_set_media_enable(int32_t enable);
void c_fdd_media_tick(int32_t enable);
int c_fdd_peek_media_irq(void);
void c_fdd_ack_media_irq(void);
int c_fdd_read_sector(int32_t drive, int32_t trk, int32_t sec, uint8_t *dst_1024);
int c_fdd_write_sector(int32_t drive, int32_t trk, int32_t sec, const uint8_t *src_1024);
int c_fdd_load_to_ram(int32_t disk_offset, int32_t ram_addr, int32_t bytes);
bool c_fdd_is_loaded(int32_t drive);

// Hard disk helpers (HDD0)
int c_hdd_load_file(int32_t drive, const uint8_t *path, int path_len);
void c_hdd_eject(int32_t drive);
bool c_hdd_is_loaded(int32_t drive);
/* One 256-byte sector of the RAM image. 1 = copied, 0 = past the image, -1 = no image.
 * Does not write the host file and does not change SASI phase. */
int c_hdd_read_sector(uint32_t sector, uint8_t *dst);
int c_hdd_write_sector(uint32_t sector, const uint8_t *src);
int c_hdd_unit_ok(void);
int c_hdd_take_sasi_reset(void);
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
void c_set_pixel(int32_t x, int32_t y, uint32_t argb);

// Hardware acceleration
void c_mem_write_tvram_concurrent(int32_t off, uint8_t val, uint8_t plane_mask);
void c_mem_tvram_raster_copy(uint32_t src_line, uint32_t dst_line, uint8_t plane_mask);

void c_print_hex(uint32_t val);
void c_print_hex16(uint16_t val);
void c_eprint_hex(uint32_t val);
void c_eprint_hex16(uint16_t val);

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
void c_sound_get_stats(uint32_t *opm_w, uint32_t *adpcm_w, int32_t *peak, uint32_t *total_rendered);

/* ADPCM uses DMAC channel 3. The sound core runs the transfer. */
void c_dmac_push_ch3(uint8_t csr, uint8_t cer, uint8_t dcr, uint8_t ocr, uint8_t scr, uint8_t ccr,
                     uint16_t mtc, uint32_t mar, uint32_t dar, uint16_t btc, uint32_t bar,
                     uint8_t niv, uint8_t eiv);
void c_dmac_pull_ch3(uint8_t *csr, uint8_t *cer, uint8_t *ccr, uint16_t *mtc,
                     uint32_t *mar, uint32_t *dar, uint16_t *btc, uint32_t *bar);
int c_dmac_peek_irq(void);
void c_dma_vec_bind(int32_t *slot);
void c_fdd_media_bind(int32_t *slot);
void c_dmac_ack_irq(void);

#ifdef __cplusplus
}
#endif

#endif // X68K_BRIDGE_H
