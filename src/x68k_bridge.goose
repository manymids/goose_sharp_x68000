// C 側 (Win32 のウィンドウ、入力、音声、ファイル選択) の関数の宣言
//
// ここを通るパスとファイル名は、どちら向きもすべて UTF-8。
let HOST_PATH_BYTES = 800; // C が返す最も長いパスが入る大きさ (x68k_path.h の PATH_CAP)

// スライスはポインタと 64 ビットの個数の組で渡る。個数は fb 以外はバイト数。
// x68k_mem_destroy まで借りたまま。参照を含む構造体は渡さない。
extern fn c_machine_bind(ram: u8[:], ipl: u8[:], cgrom: u8[:], sram: u8[:], fb: u32[:], ram_limit: i32&) -> u64;
extern fn c_machine_epoch() -> u64;
extern fn c_machine_reset_devices();
extern fn c_startup_error();
extern fn c_audio_discard();
extern fn c_host_input_discard();

extern fn c_io_poll_line(out_buf: u8&, max_len: i32, wait_ms: i32) -> i32;
extern fn c_io_write_line(data: const u8&, len: i32);
extern fn c_audio_init() -> i32;

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
extern fn c_ui_warning(text: const u8[:]);
extern fn win32_ui_get_key_scancode() -> i32;
extern fn c_host_joy_byte() -> i32;
extern fn c_set_cpu_mhz(mhz: i32) -> i32;
extern fn c_get_cpu_mhz() -> i32;
extern fn c_get_scale() -> i32;
// ウィンドウの先読みの設定 (0〜4 フレーム)。Run-Ahead メニューで変わる。
extern fn c_set_run_ahead(frames: i32) -> i32;
extern fn c_get_run_ahead() -> i32;
// 前回の呼び出しからウィンドウのメニューで設定が変わったら 1 を返し、メニューで選んだ初期の画面幅も返す
// (選んでいなければ 0)。設定そのものは x68k_config.goose が持つ。
extern fn c_gui_take_settings_changes(width: i32&) -> i32;
// UTF-8 のパスの絶対パス (GetFullPathNameW) を UTF-8 で out に入れる。長さを返し、失敗なら 0。
extern fn c_full_path(path: const u8[:], out: u8&, cap: i32) -> i32;
// ANSI コードページの文字列を UTF-8 にして out に入れる。長さを返し、失敗なら 0。
extern fn c_ansi_to_utf8(text: const u8[:], out: u8&, cap: i32) -> i32;
extern fn c_cpu_mhz_ok(mhz: i32) -> i32;

extern fn c_host_local_seconds() -> i64;

extern fn c_host_list_dir(path: const u8[:], out: u8&, cap: i32) -> i32;

// メモリの準備 (BIOS の読み込み)、メニューで選んだディスク、RAM の大きさ。

extern fn x68k_mem_init(sys_dir: const u8[:]) -> i32;
// ユーザーがウィンドウのメニューで選んだディスク: MEDIA_* のどれかで、挿入ならパスも。0 はなし。
extern fn c_gui_take_media_request(path: u8&, cap: i32, path_len: i32&) -> i32;
extern fn c_mem_set_ram_mb(mb: i32) -> i32;
extern fn x68k_mem_destroy();
extern fn c_sram_set_persist(enabled: i32);






extern fn c_line_zero(grp: u16&, mix: u8&, sp: u16&, sp2: u16&, bg: u16&, tr: u8&);

extern fn c_set_screen_mode(w: i32, h: i32);
extern fn c_get_screen_width() -> i32;
extern fn c_get_screen_height() -> i32;

// 音声
// でき上がった 1 フレーム分のステレオのサンプル (左右交互)。音声デバイスへ渡す。
extern fn c_audio_output(samples: const i16[:]);
