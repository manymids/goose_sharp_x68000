// X68000 Win32 Bridge extern declarations in Goose
//
// Every path and file name that crosses here is UTF-8, in both directions.
let HOST_PATH_BYTES = 800; // room for the longest path C hands back (PATH_CAP in x68k_path.h)

// Slices cross as pointer/64-bit count pairs. Counts are bytes except fb.
// Borrowed until x68k_mem_destroy; no reference-containing struct crosses.
extern fn c_machine_bind(ram: u8[:], ipl: u8[:], cgrom: u8[:], sram: u8[:],
    tvram: u8[:], gvram: u8[:], pal: u8[:], vc: u8[:], sprite: u8[:],
    bgreg: u8[:], bgram: u8[:], chr8: u8[:], chr16: u8[:], fb: u32[:],
    ram_limit: i32&) -> u64;
extern fn c_machine_epoch() -> u64;
extern fn c_machine_reset_devices();
extern fn c_startup_error();
extern fn c_audio_discard();
extern fn c_host_input_discard();

extern fn c_io_poll_line(out_buf: u8&, max_len: i32, wait_ms: i32) -> i32;
extern fn c_io_write_line(data: const u8&, len: i32);
extern fn c_audio_init() -> i32;
extern fn c_audio_shutdown();

extern fn win32_ui_init(title: const u8[:], w: i32, h: i32, scale: i32) -> bool;
extern fn win32_ui_poll() -> u32;
extern fn win32_ui_render_fb();
extern fn win32_ui_is_open() -> bool;
extern fn win32_ui_destroy();
extern fn win32_ui_sleep(ms: i32);
extern fn win32_ui_get_ticks_ms() -> u64;
extern fn win32_ui_get_time_us() -> u64;
extern fn win32_ui_wait_until_us(target_us: u64);
extern fn win32_ui_get_command() -> i32;
extern fn win32_ui_get_key_scancode() -> i32;
extern fn c_host_joy_byte() -> i32;
extern fn c_set_cpu_mhz(mhz: i32) -> i32;
extern fn c_get_cpu_mhz() -> i32;
extern fn c_get_scale() -> i32;
// The window's run-ahead setting (0-4 frames). The Run-Ahead menu changes it.
extern fn c_set_run_ahead(frames: i32) -> i32;
extern fn c_get_run_ahead() -> i32;
// The window menu changed a setting since the last call: returns 1, and the initial screen width the
// menu chose (0 if it did not choose one). The settings themselves live in x68k_config.goose.
extern fn c_gui_take_settings_changes(width: i32&) -> i32;
// The absolute form of a UTF-8 path (GetFullPathNameW), as UTF-8 in out. Returns its length, 0 on failure.
extern fn c_full_path(path: const u8[:], out: u8&, cap: i32) -> i32;
// Text in the ANSI code page converted to UTF-8 in out. Returns its length, 0 on failure.
extern fn c_ansi_to_utf8(text: const u8[:], out: u8&, cap: i32) -> i32;
extern fn c_cpu_mhz_ok(mhz: i32) -> i32;

extern fn c_host_local_seconds() -> i64;

extern fn c_host_list_dir(path: const u8[:], out: u8&, cap: i32) -> i32;

// Native-only compatibility/test helpers. Machine callers use x68k_state.
// In particular, these do not snapshot Goose MMU/video or CPU metadata.

extern fn x68k_mem_init(sys_dir: const u8[:]) -> i32;
// A disk the user picked from the window menu: one of MEDIA_*, with the path for an insert. 0 = none.
extern fn c_gui_take_media_request(path: u8&, cap: i32, path_len: i32&) -> i32;
extern fn c_mem_set_ram_mb(mb: i32) -> i32;
extern fn x68k_mem_destroy();
extern fn c_sram_set_persist(enabled: i32);

extern fn c_mem_read_tvram(off: i32) -> u8;
extern fn c_frame_ready() -> i32;

extern fn c_mem_read_gvram(off: i32) -> u8;

extern fn c_mem_read_pal(off: i32) -> u8;

extern fn c_mem_read_sprite(off: i32) -> u8;

extern fn c_mem_read_bg_reg(off: i32) -> u8;

extern fn c_line_zero(grp: u16&, mix: u8&, sp: u16&, sp2: u16&, bg: u16&, tr: u8&);

extern fn c_set_screen_mode(w: i32, h: i32);
extern fn c_get_screen_width() -> i32;
extern fn c_get_screen_height() -> i32;
extern fn c_set_frame_ready(ready: i32);

// Audio / Sound API
// One frame of finished interleaved stereo samples, for the audio device.
extern fn c_audio_output(samples: const i16[:]);
