// X68000 Win32 Bridge extern declarations in Goose

// Slices cross as pointer/64-bit count pairs. Counts are bytes except fb.
// Borrowed until machine_unbind/destroy; no reference-containing struct crosses.
extern fn c_machine_bind(ram: u8[:], ipl: u8[:], cgrom: u8[:], sram: u8[:],
    tvram: u8[:], gvram: u8[:], pal: u8[:], vc: u8[:], sprite: u8[:],
    bgreg: u8[:], bgram: u8[:], chr8: u8[:], chr16: u8[:], fb: u32[:],
    ram_limit: i32&, screen_w: i32&, screen_h: i32&, dma_vec: i32&, media_irq: i32&) -> u64;
extern fn c_machine_unbind(epoch: u64) -> i32;
extern fn c_machine_epoch() -> u64;
extern fn c_mem_test_fail_init(after: i32);
extern fn c_machine_reset_devices();
extern fn c_gui_settings_open(enabled: i32);
extern fn c_gui_settings_int(key: i32) -> i32;
extern fn c_gui_settings_set_int(key: i32, value: i32) -> i32;
extern fn c_gui_settings_path(key: i32, out: u8&, cap: i32) -> i32;
extern fn c_gui_settings_set_path(key: i32, path: const u8&, len: i32) -> i32;
extern fn c_gui_settings_save() -> i32;
extern fn c_gui_settings_store();
extern fn c_startup_error();
extern fn c_audio_discard();
extern fn c_host_input_discard();

extern fn c_io_read_line(out_buf: u8&, max_len: i32) -> i32;
extern fn c_io_poll_line(out_buf: u8&, max_len: i32, wait_ms: i32) -> i32;
extern fn c_io_write_line(data: const u8&, len: i32);
extern fn c_audio_init() -> i32;
extern fn c_audio_shutdown();

extern fn win32_ui_init(title: const u8&, title_len: i32, w: i32, h: i32, scale: i32) -> bool;
extern fn win32_ui_poll() -> u32;
extern fn win32_ui_render_fb();
extern fn win32_ui_is_open() -> bool;
extern fn win32_ui_destroy();
extern fn win32_ui_sleep(ms: i32);
extern fn win32_ui_get_ticks_ms() -> u64;
extern fn win32_ui_get_time_us() -> u64;
extern fn win32_ui_wait_until_us(target_us: u64);
extern fn win32_ui_get_command() -> i32;
extern fn win32_ui_get_char() -> i32;
extern fn win32_ui_get_key_scancode() -> i32;
extern fn c_host_key_joy(vk: i32, down: i32);
extern fn c_host_joy_reset();
extern fn c_host_joy_byte() -> i32;
extern fn c_set_cpu_mhz(mhz: i32) -> i32;
extern fn c_get_cpu_mhz() -> i32;

extern fn c_file_read(path: const u8&, path_len: i32, out_buf: u8&, max_len: i32) -> i32;
extern fn c_file_write(path: const u8&, path_len: i32, buf: const u8&, len: i32) -> i32;
extern fn c_last_path_len() -> i32;

extern fn c_save_fb_bmp(path: const u8&, path_len: i32) -> i32;
extern fn c_save_fb_png(path: const u8&, path_len: i32) -> i32;
extern fn c_default_system_dir(out: u8&, cap: i32) -> i32;
extern fn c_default_disk_path(out: u8&, cap: i32) -> i32;
extern fn c_vk_to_x68k(vk: i32, extended: i32) -> i32;
extern fn c_extra_save(bank: i32, idx: i32) -> i32;
extern fn c_extra_load(bank: i32, idx: i32) -> i32;
extern fn c_extra_drop(bank: i32, idx: i32);
extern fn c_extra_bytes(bank: i32, idx: i32) -> i32;
extern fn c_extra_total(bank: i32) -> i32;
extern fn c_state_capture(bank: i32, idx: i32) -> i32;
extern fn c_state_validate(bank: i32, idx: i32) -> i32;
extern fn c_state_restore(bank: i32, idx: i32) -> i32;
extern fn c_state_generation(bank: i32, idx: i32) -> u64;
extern fn c_state_drop(bank: i32, idx: i32);
extern fn c_state_bytes(bank: i32, idx: i32) -> i32;
extern fn c_audio_capture_start();
extern fn c_audio_capture_status(active: i32&, frames: i32&, truncated: i32&);
extern fn c_audio_capture_stop(path: const u8&, path_len: i32, frames: i32&, truncated: i32&, peak: i32&, silent: i32&) -> i32;
extern fn c_opm_shadow_byte(index: i32) -> i32;
extern fn c_opm_key_on(ch: i32) -> i32;
extern fn c_host_list_dir(path: const u8&, path_len: i32, out: u8&, cap: i32) -> i32;

// Native-only compatibility/test helpers. Machine callers use x68k_state.
// In particular, these do not snapshot Goose MMU/video or CPU metadata.
extern fn c_mem_save_state(slot: i32) -> i32;
extern fn c_mem_load_state(slot: i32) -> i32;
extern fn c_mem_test_break_version(slot: i32) -> i32;
extern fn c_mem_test_fail_alloc(after: i32);
extern fn c_mem_test_alloc_count() -> i32;
extern fn c_mem_test_corrupt_slot(slot: i32, kind: i32) -> i32;
extern fn c_ppu_get_phase() -> i32;
extern fn c_ppu_set_phase(phase: i32);
extern fn c_sound_render(buf: i16&, samples: i32);

extern fn x68k_mem_init(sys_dir: const u8&, sys_len: i32, floppy_path: const u8&, floppy_len: i32) -> i32;
extern fn c_mem_set_ram_mb(mb: i32) -> i32;
extern fn x68k_mem_destroy();

extern fn c_ram_size() -> i32;
extern fn c_ram_bind(ram: u8&);
extern fn c_ram_limit_bind(slot: i32&);

extern fn c_mem_read_tvram(off: i32) -> u8;
extern fn c_mem_write_tvram(off: i32, val: u8);
extern fn c_mem_clear_tvram();
extern fn c_mem_reset_display();
extern fn c_frame_ready() -> i32;

extern fn c_mem_read_gvram(off: i32) -> u8;
extern fn c_mem_write_gvram(off: i32, val: u8);
extern fn c_mem_clear_gvram();
extern fn c_fb_at(x: i32, y: i32) -> u32;
extern fn c_mem_gvram_cpu_read(off: i32, r20: u8) -> u8;
extern fn c_mem_gvram_cpu_write(off: i32, val: u8, r20: u8);

extern fn c_mem_read_pal(off: i32) -> u8;
extern fn c_mem_write_pal(off: i32, val: u8);
extern fn c_vcreg_bind(vcreg: u8&);

extern fn c_set_current_frame(frame: i32);
extern fn c_get_current_frame() -> i32;
extern fn c_log_duff(a5: u32, a6: u32, d7: u32, ret_pc: u32);
extern fn c_log_ram_write(addr: u32, val: u8, pc: u32);
extern fn c_mem_read_sprite(off: i32) -> u8;
extern fn c_mem_write_sprite(off: i32, val: u8);

extern fn c_mem_read_bg_reg(off: i32) -> u8;
extern fn c_mem_write_bg_reg(off: i32, val: u8);

extern fn c_mem_read_bgram(off: i32) -> u8;
extern fn c_mem_write_bgram(off: i32, val: u8);

extern fn c_ipl_bind(ipl: u8&);
extern fn c_cgrom_bind(cgrom: u8&);
extern fn c_sram_bind(sram: u8&);

extern fn c_pia_write(adr: i32, data: u8);
extern fn c_pia_read_c() -> u8;
extern fn c_pia_joy_strobe(port: i32) -> u8;
extern fn c_fdd_load_file(drive: i32, path: const u8&, path_len: i32) -> i32;
extern fn c_fdd_eject(drive: i32);
extern fn c_fdd_media_reset();
extern fn c_fdd_set_media_enable(enable: i32);
extern fn c_fdd_media_tick(enable: i32);
extern fn c_fdd_peek_media_irq() -> i32;
extern fn c_fdd_ack_media_irq();
extern fn c_fdd_read_sector(drive: i32, trk: i32, sec: i32, dst_1024: u8&) -> i32;
extern fn c_fdd_write_sector(drive: i32, trk: i32, sec: i32, src_1024: const u8&) -> i32;
extern fn c_fdd_seek(drive: i32, trk: i32) -> i32;
extern fn c_fdd_read_fdc(drive: i32, trk: i32, c: i32, h: i32, r: i32, n: i32, dst: u8&) -> i32;
extern fn c_fdd_write_fdc(drive: i32, trk: i32, c: i32, h: i32, r: i32, n: i32, src: const u8&) -> i32;
extern fn c_fdd_current_id(drive: i32, c: u8&, h: u8&, r: u8&, n: u8&) -> i32;
extern fn c_fdd_load_to_ram(disk_offset: i32, ram_addr: i32, bytes: i32) -> i32;
extern fn c_fdd_is_loaded(drive: i32) -> bool;

extern fn c_hdd_load_file(drive: i32, path: const u8&, path_len: i32) -> i32;
extern fn c_hdd_eject(drive: i32);
extern fn c_hdd_is_loaded(drive: i32) -> bool;
extern fn c_hdd_read_sector(sector: u32, dst: u8&) -> i32;
extern fn c_hdd_write_sector(sector: u32, src: const u8&) -> i32;
extern fn c_hdd_unit_ok() -> i32;
extern fn c_hdd_take_sasi_reset() -> i32;
extern fn c_video_bind(pal: u8&, sprite: u8&, bgreg: u8&, bgram: u8&, chr8: u8&, chr16: u8&);
extern fn c_tvram_bind(tvram: u8&);
extern fn c_gvram_bind(gvram: u8&);
extern fn c_line_zero(grp: u16&, mix: u8&, sp: u16&, sp2: u16&, bg: u16&, tr: u8&);

extern fn c_screen_bind(w: i32&, h: i32&);
extern fn c_set_screen_mode(w: i32, h: i32);
extern fn c_get_screen_width() -> i32;
extern fn c_get_screen_height() -> i32;
extern fn c_clear_framebuffer(argb: u32);
extern fn c_set_frame_ready(ready: i32);
extern fn c_fb_bind(fb: u32&);
extern fn c_set_pixel(x: i32, y: i32, argb: u32);
extern fn c_mem_write_tvram_access(off: i32, val: u8, r2a: u8, r2b: u8, r2e: u8, r2f: u8);
extern fn c_mem_tvram_raster_copy(src_line: u32, dst_line: u32, plane_mask: u8);
extern fn c_print_hex(val: u32);
extern fn c_print_hex16(val: u16);
extern fn c_eprint_hex(val: u32);
extern fn c_eprint_hex16(val: u16);

// Audio / Sound API
extern fn c_sound_init();
extern fn c_sound_reset();
extern fn c_sound_cleanup();
extern fn c_sound_opm_write(addr: u32, val: u8);
extern fn c_sound_opm_read(addr: u32) -> u8;
extern fn c_sound_adpcm_write(addr: u32, val: u8);
extern fn c_sound_adpcm_read(addr: u32) -> u8;
extern fn c_sound_adpcm_set_pan(pan: u8);
extern fn c_sound_scanline_timer(cycles: u32);
extern fn c_sound_frame_update(samples: i32);
extern fn c_sound_poll_irq() -> i32;
extern fn c_sound_get_stats(opm_w: u32&, adpcm_w: u32&, peak: i32&, total_rendered: u32&);
extern fn c_dmac_push_ch3(csr: u8, cer: u8, dcr: u8, ocr: u8, scr: u8, ccr: u8, mtc: u16, mar: u32, dar: u32, btc: u16, bar: u32, niv: u8, eiv: u8);
extern fn c_dmac_pull_ch3(csr: u8&, cer: u8&, ccr: u8&, mtc: u16&, mar: u32&, dar: u32&, btc: u16&, bar: u32&);
extern fn c_dmac_peek_irq() -> i32;
extern fn c_dma_vec_bind(slot: i32&);
extern fn c_fdd_media_bind(slot: i32&);
extern fn c_dmac_ack_irq();


