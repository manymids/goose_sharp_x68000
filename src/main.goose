// Sharp X68000 Native Emulator & ARCL MCP Server in Goose

import std;
import os;
import .x68k_bridge;
import .x68k_mfp;
import .x68k_fdc;
import .x68k_emu;
import .mcp_server;
import .x68k_session;
import .x68k_input;
import .x68k_config;
import .launch_args;
import .x68k_disk;
import .x68k_output;
import .x68k_ahead;

fn launch_error(message: const u8[:]) {
    write_stderr(message);
    exit(1);
}

fn print_help() {
    write_stderr(str(
        "Goose Sharp X68000\n",
        "Usage: arcl_windows_x68k_goose.exe [options] [disk-image]\n",
        "  --system-dir PATH    BIOS directory (default: .\\keropi)\n",
        "  --clock MHZ          10,16,25,50,75,100,150,200,250 (default: 10)\n",
        "  --scale 1|2          Initial GUI window scale\n",
        "  --mode 512|768       Initial display width (guest CRTC may change it)\n",
        "  --run-ahead N        Show the window N frames ahead (0-4) to cut input lag\n",
        "  --no-disk            Ignore all remembered GUI media; start empty\n",
        "  --mcp                ARCL MCP over stdio; ignores GUI preferences\n",
        "  --mcp-layers LIST    l0,l1,l2,l3,l4 or all (default: l0,l1)\n",
        "  --no-window          Headless; ignores GUI preferences\n",
        "  --frames N           Stop after N frames (non-MCP)\n",
        "  --dump-frame PATH    Write a BMP screenshot (non-MCP)\n",
        "  --dump-after-frames N  Screenshot frame (default: 1200)\n",
        "  --ram N              Compatibility option; RAM is fixed at 12 MB\n",
        "  --help               Show this help\n",
        "No default disk. GUI preferences: .\\arcl_windows_x68k_goose.ini\n"));
}

fn write_dump(emu: X68kEmulator&, path: const u8[:]) {
    if !output::save_image(path, emu.ppu.fb[..], emu.ppu.screen_w, emu.ppu.screen_h) {
        write_stderr("dump-frame: FAILED to write\n");
    } else {
        write_stderr("dump-frame: wrote\n");
    }
}

fn print_banner(content_path: const u8[:], sys_dir: const u8[:]) {
    print("=================================================");
    print("  Goose Sharp X68000 Native Emulator (Win32)     ");
    print("=================================================");
    print("Motorola 68000 CPU, MMU, PPU written in Goose!");
    print("Content Disk : ", content_path);
    print("System ROMs  : ", sys_dir);
    print("Clock / RAM  : ", c_get_cpu_mhz(), " MHz / 12 MB");
    print("Floppy Loaded: ", if disk::fd_loaded(0) { "Yes" } else { "No" });
    print("-------------------------------------------------");
}

fn open_window(screen_w: i32, screen_h: i32, scale: i32) -> bool {
    c_set_screen_mode(screen_w, screen_h);
    return win32_ui_init("Sharp X68000 Emulator - Goose Native", screen_w, screen_h, scale);
}

// ホストのキー入力をリングへ積むだけ。CPU への割り込みはフレーム内の Keyboard_Int が出す。
fn pump_host_keys(emu: X68kEmulator&) {
    var sc = win32_ui_get_key_scancode();
    while sc >= 0 {
        input::host_scancode(emu, sc as u8);
        sc = win32_ui_get_key_scancode();
    }
}

let UI_COMMAND_RESET = 3; // メニュー / F5

// ウィンドウのメニューが出すディスクの出し入れ (c_gui_take_media_request の戻り値)
let MEDIA_FD0_INSERT = 1;
let MEDIA_FD0_EJECT = 2;
let MEDIA_FD1_INSERT = 3;
let MEDIA_FD1_EJECT = 4;
let MEDIA_HDD_INSERT = 5;
let MEDIA_HDD_EJECT = 6;

// メニューで選ばれた出し入れを行う。新しいディスクから起動し直すべきなら true。
fn apply_menu_media() -> bool {
    var path: u8[HOST_PATH_BYTES] = [0; HOST_PATH_BYTES];
    var len: i32 = 0;
    let request = c_gui_take_media_request(path[0], HOST_PATH_BYTES, len);
    if request == MEDIA_FD0_INSERT { return disk::fd_load(0, path[..len]); }
    if request == MEDIA_FD0_EJECT { disk::fd_eject(0); }
    if request == MEDIA_FD1_INSERT { disk::fd_load(1, path[..len]); }
    if request == MEDIA_FD1_EJECT { disk::fd_eject(1); }
    if request == MEDIA_HDD_INSERT && disk::hdd_load(path[..len]) {
        // IPL は SASI より先にフロッピーから起動するので、フロッピーは抜いておく。
        disk::fd_eject(0);
        disk::fd_eject(1);
        return true;
    }
    if request == MEDIA_HDD_EJECT { disk::hdd_eject(); }
    return false;
}

// 保存してある前回のディスク (x68k_config) を入れ直す。
fn mount_saved(key: i32, value: const u8[:]) {
    if value.len == 0 { return; }
    let ok = if key == GUI_HDD { disk::hdd_load(value) } else { disk::fd_load(key - GUI_FD0, value) };
    if !ok { write_stderr(str("warning: saved disk could not be loaded: ", value, "\n")); }
}

// 前回の終了時に入っていたディスクを、空のドライブへ入れ直す。
// 読めなかったものは設定からも消え、次回は試さない。
fn mount_saved_media() {
    var fd0: u8[>..] = [];
    var fd1: u8[>..] = [];
    var hdd: u8[>..] = [];
    fd0.append(config::path(GUI_FD0));
    fd1.append(config::path(GUI_FD1));
    hdd.append(config::path(GUI_HDD));
    disk::power_on();
    mount_saved(GUI_FD0, fd0);
    mount_saved(GUI_FD1, fd1);
    mount_saved(GUI_HDD, hdd);
}

// リセットの操作 (メニュー / F5) か、起動し直しの要るディスクの出し入れがあったか。
fn reset_requested() -> bool {
    let command = win32_ui_get_command();
    return apply_menu_media() || command == UI_COMMAND_RESET;
}

// ARCL MCP を標準入出力で受ける。C 版と同じく resume まで止めておき、stdin は待たずに見る。
fn run_mcp(emu: X68kEmulator&, want_window: bool, screen_w: i32, screen_h: i32, scale: i32) {
    emu.is_paused = true;
    if c_audio_init() == 0 {
        write_stderr("warning: no audio output device available; running silently\n");
    }

    var window_ok = false;
    if want_window {
        window_ok = open_window(screen_w, screen_h, scale);
        if !window_ok {
            write_stderr("warning: failed to open window; continuing MCP without one\n");
        }
    }

    var io_buf: u8[65536] = [0; 65536];
    var is_running = true;
    while is_running {
        if window_ok && win32_ui_is_open() {
            win32_ui_poll();
            pump_host_keys(emu);
            if reset_requested() { mcp::reset(emu); }
        }

        let wait_ms: i32 = if emu.is_paused { 20 } else { 0 };
        let read_len = c_io_poll_line(io_buf[0], 65536, wait_ms);
        if read_len < 0 { break; }
        if read_len > 0 { mcp::dispatch(emu, io_buf[..read_len], is_running); }

        if !emu.is_paused {
            emu.clock_mhz = c_get_cpu_mhz();
            session::run_frame(emu);
            if window_ok && win32_ui_is_open() { win32_ui_render_fb(); }
            win32_ui_sleep(1);
        }
    }

    // win32_ui_destroy は音声も止める。ウィンドウがなければ音声だけ止める。
    if window_ok { win32_ui_destroy(); } else { c_audio_shutdown(); }
}

// Win32 ウィンドウで実時間に合わせて動かす。max_frames > 0 ならその数で終わる。
fn run_gui(emu: X68kEmulator&, screen_w: i32, screen_h: i32, scale: i32, max_frames: i64, dump_path: const u8[:], dump_after: i64) {
    if !open_window(screen_w, screen_h, scale) {
        print("ERROR: Failed to create Win32 window!");
        return;
    }
    print("Window opened (", screen_w, "x", screen_h, "). Close window or press ESC to exit.");

    var dumped = false;
    var pace = AheadPace { frames: c_get_run_ahead(), .. };
    var target_time_us: u64 = win32_ui_get_time_us();
    while win32_ui_is_open() {
        let keys = win32_ui_poll();
        if (keys & (1 << 8)) != 0 { break; } // ESC

        pump_host_keys(emu);
        emu.mmu.joy1 = c_host_joy_byte() as u8;
        config::sync_from_host();

        if reset_requested() {
            session::reset(emu);
            win32_ui_render_fb();
            session::resume(emu, win32_ui_get_ticks_ms()); // GUI resumes; MCP stays paused.
            target_time_us = win32_ui_get_time_us();
        }

        let work_start_us = win32_ui_get_time_us();
        if !emu.is_paused {
            emu.clock_mhz = c_get_cpu_mhz();
            session::run_frame(emu);
        }

        if max_frames > 0 && emu.total_frames >= max_frames { break; }
        if dump_path.len > 0 && !dumped && emu.total_frames >= dump_after {
            write_dump(emu, dump_path);
            dumped = true;
        }

        // 先読みを使うなら、本当のフレームの代わりに run_ahead フレーム先の画面を出す (x68k_ahead)。
        // メニューの値は上限。実時間に間に合う数まで pace が下げる (高いクロックでは減る)。
        let run_ahead = pace.frames;
        if !emu.is_paused && run_ahead > 0 && ahead::begin(emu, run_ahead) {
            c_set_screen_mode(emu.ppu.screen_w, emu.ppu.screen_h);
            c_set_frame_ready(if emu.ppu.frame_ready { 1 } else { 0 });
            win32_ui_render_fb();
            ahead::end(emu);
        } else {
            win32_ui_render_fb();
        }

        // The frame the CRTC programs (768x512 31 kHz: about 18031 us, 55.46 Hz).
        let frame_period_us: u64 = (emu::frame_cycles10(emu.mmu) / 10) as u64;
        if !emu.is_paused {
            let before = pace.frames;
            ahead::pace(pace, c_get_run_ahead(), win32_ui_get_time_us() - work_start_us, frame_period_us);
            if pace.frames != before { write_stderr(str("run-ahead: ", pace.frames, " frames\n")); }
        } else {
            pace.frames = min(pace.frames, c_get_run_ahead());
        }
        target_time_us += frame_period_us;
        let now_us = win32_ui_get_time_us();
        if target_time_us > now_us {
            win32_ui_wait_until_us(target_time_us);
        } else if (now_us - target_time_us) > (frame_period_us * 3) {
            // 3 フレーム以上遅れたら追いかけない。
            target_time_us = now_us;
        }
    }

    config::store();
    win32_ui_destroy();
}

// ウィンドウなしで frames フレームだけ進める。
// run_ahead > 0 なら毎フレーム先読みして戻す (見せる画面はないが、戻したあとが同じかを確かめられる)。
fn run_headless(emu: X68kEmulator&, frames: i64, dump_path: const u8[:], run_ahead: i32) {
    for _ in frames {
        emu.clock_mhz = c_get_cpu_mhz();
        session::run_frame(emu);
        if run_ahead > 0 && ahead::begin(emu, run_ahead) { ahead::end(emu); }
    }
    if dump_path.len > 0 { write_dump(emu, dump_path); }
    write_stderr(str("frames: ", emu.total_frames, "\n"));
}

fn main() {
    var opt = LaunchOptions {};
    // 引数 0 はプログラム名。読むだけなので const のスライスの並びに写す
    // (u8[:] の並びは、そのままでは const u8[:] の並びとして渡せない)。
    let raw_args = args();
    var cmd_args: const u8[:][>..] = [];
    for arg in raw_args[1..] { cmd_args.push(arg); }
    let problem = launch::parse(cmd_args, opt);
    if problem.len > 0 { launch_error(problem); }
    if opt.help { print_help(); return; }
    if opt.ram_ignored { write_stderr("warning: --ram is ignored; RAM is fixed at 12 MB\n"); }
    if opt.layers >= 0 { mcp::set_layers(opt.layers); }

    let mcp_mode = opt.mcp_mode;
    let no_window = opt.no_window;
    let content_path = opt.content_path[..];
    var sys_dir: u8[>..] = [];
    sys_dir.append(opt.sys_dir);
    var clock_mhz = opt.clock_mhz;
    var screen_w = opt.screen_w;
    let screen_h = opt.screen_h;
    var scale = opt.scale;
    let gui_preferences = !mcp_mode && !no_window;
    config::open(gui_preferences);
    // ARCL とヘッドレス実行は毎回同じ SRAM から始める。終了時に sram.dat を書き戻すのは GUI だけ。
    c_sram_set_persist(if gui_preferences { 1 } else { 0 });
    if !opt.sys_set { sys_dir.clear(); sys_dir.append(config::path(GUI_BIOS)); }
    if !opt.clock_set { clock_mhz = config::int_value(GUI_CLOCK); }
    if !opt.mode_set { screen_w = config::int_value(GUI_WIDTH); }
    if !opt.scale_set { scale = config::int_value(GUI_SCALE); }
    let run_ahead = if opt.ahead_set { opt.run_ahead } else { config::int_value(GUI_AHEAD) };
    config::set_int(GUI_AHEAD, run_ahead);
    c_set_run_ahead(run_ahead); // メニューの印。ウィンドウでは毎フレームここから読む
    config::set_int(GUI_WIDTH, screen_w);
    if sys_dir.len == 0 { launch_error("BIOS directory is empty; use --system-dir PATH\n"); }

    if c_set_cpu_mhz(clock_mhz) == 0 {
        launch_error("--clock must be 10, 16, 25, 50, 75, 100, 150, 200, or 250\n");
    }
    if c_mem_set_ram_mb(12) == 0 {
        write_stderr("failed to set RAM size\n");
        return;
    }

    // ハードウェアメモリ (RAM 12MB, ROM, VRAM) の初期化
    let mem_ok = x68k_mem_init(sys_dir[..]);
    if mem_ok != 0 { config::set_path(GUI_BIOS, sys_dir[..]); } // 保存するときに書く BIOS のフォルダ
    if mem_ok == 0 {
        write_stderr(str("Could not initialize BIOS/memory from: ", sys_dir, " (iplrom.dat 128 KiB, cgrom.dat 768 KiB required)\n"));
        if !mcp_mode && !no_window { c_startup_error(); }
        exit(1);
    }
    if gui_preferences && !opt.content_set {
        mount_saved_media();
    } else {
        disk::power_on();
        if content_path.len > 0 {
            let loaded = if disk::path_is_hdd(content_path) { disk::hdd_load(content_path) } else { disk::fd_load(0, content_path) };
            if !loaded {
                x68k_mem_destroy();
                launch_error("disk image could not be loaded\n");
            }
        }
    }

    // Goose ネイティブ X68000 エミュレータ本体の初期化
    var emu = X68kEmulator {};
    emu.clock_mhz = c_get_cpu_mhz();
    emu.init();
    // The GUI clock follows the host; ARCL and headless runs start at XEiJ's fixed 2026-01-01
    // so that runs replay identically.
    if !mcp_mode && !no_window { emu.mmu.rtc.init(c_host_local_seconds()); }

    if mcp_mode {
        run_mcp(emu, !no_window, screen_w, screen_h, scale);
    } else if !no_window {
        print_banner(content_path, sys_dir);
        run_gui(emu, screen_w, screen_h, scale, opt.max_frames, opt.dump_path[..], opt.dump_after);
    } else {
        print_banner(content_path, sys_dir);
        // Without --frames the earlier check guarantees --dump-frame.
        run_headless(emu, if opt.frames_set { opt.max_frames } else { opt.dump_after }, opt.dump_path[..], run_ahead);
    }
    x68k_mem_destroy();
}
