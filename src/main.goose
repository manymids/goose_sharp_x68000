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

fn write_dump(path: u8[>..]&) {
    var buf: u8[>..] = [];
    buf.append(path);
    buf.push(0);
    if c_save_fb_png(buf[0], buf.len as i32) == 0 {
        write_stderr("dump-frame: FAILED to write\n");
    } else {
        write_stderr("dump-frame: wrote\n");
    }
}

fn print_banner(content_path: u8[>..]&, sys_dir: u8[>..]&) {
    print("=================================================");
    print("  Goose Sharp X68000 Native Emulator (Win32)     ");
    print("=================================================");
    print("Motorola 68000 CPU, MMU, PPU written in Goose!");
    print("Content Disk : ", content_path);
    print("System ROMs  : ", sys_dir);
    print("Clock / RAM  : ", c_get_cpu_mhz(), " MHz / 12 MB");
    print("Floppy Loaded: ", if c_fdd_is_loaded(0) { "Yes" } else { "No" });
    print("-------------------------------------------------");
}

fn open_window(screen_w: i32, screen_h: i32, scale: i32) -> bool {
    c_set_screen_mode(screen_w, screen_h);
    var title: u8[>..] = [];
    title.append("Sharp X68000 Emulator - Goose Native");
    title.push('\0');
    return win32_ui_init(title[0], title.len as i32, screen_w, screen_h, scale);
}

// ホストのキー入力をリングへ積むだけ。CPU への割り込みはフレーム内の Keyboard_Int が出す。
fn pump_host_keys(emu: X68kEmulator&) {
    var sc = win32_ui_get_key_scancode();
    while sc >= 0 {
        input_host_scancode(emu, sc as u8);
        sc = win32_ui_get_key_scancode();
    }
}

let UI_COMMAND_RESET = 3; // メニュー / F5

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
            if win32_ui_get_command() == UI_COMMAND_RESET { mcp_reset(emu); }
        }

        let wait_ms: i32 = if emu.is_paused { 20 } else { 0 };
        let read_len = c_io_poll_line(io_buf[0], 65536, wait_ms);
        if read_len < 0 { break; }
        if read_len > 0 { mcp_dispatch(emu, io_buf[..read_len], is_running); }

        if !emu.is_paused {
            emu.clock_mhz = c_get_cpu_mhz();
            session_run_frame(emu);
            if window_ok && win32_ui_is_open() { win32_ui_render_fb(); }
            win32_ui_sleep(1);
        }
    }

    // win32_ui_destroy は音声も止める。ウィンドウがなければ音声だけ止める。
    if window_ok { win32_ui_destroy(); } else { c_audio_shutdown(); }
}

// Win32 ウィンドウで実時間に合わせて動かす。max_frames > 0 ならその数で終わる。
fn run_gui(emu: X68kEmulator&, screen_w: i32, screen_h: i32, scale: i32, max_frames: i64, dump_path: u8[>..]&, dump_after: i64) {
    if !open_window(screen_w, screen_h, scale) {
        print("ERROR: Failed to create Win32 window!");
        return;
    }
    print("Window opened (", screen_w, "x", screen_h, "). Close window or press ESC to exit.");

    var dumped = false;
    var target_time_us: u64 = win32_ui_get_time_us();
    while win32_ui_is_open() {
        let keys = win32_ui_poll();
        if (keys & (1 << 8)) != 0 { break; } // ESC

        pump_host_keys(emu);
        emu.mmu.joy1 = c_host_joy_byte() as u8;

        if win32_ui_get_command() == UI_COMMAND_RESET {
            session_reset(emu);
            win32_ui_render_fb();
            session_resume(emu, win32_ui_get_ticks_ms()); // GUI resumes; MCP stays paused.
            target_time_us = win32_ui_get_time_us();
        }

        if !emu.is_paused {
            emu.clock_mhz = c_get_cpu_mhz();
            session_run_frame(emu);
        }

        if max_frames > 0 && emu.total_frames >= max_frames { break; }
        if dump_path.len > 0 && !dumped && emu.total_frames >= dump_after {
            write_dump(dump_path);
            dumped = true;
        }

        win32_ui_render_fb();

        // The frame the CRTC programs (768x512 31 kHz: about 18031 us, 55.46 Hz).
        let frame_period_us: u64 = (emu::frame_cycles10(emu.mmu) / 10) as u64;
        target_time_us += frame_period_us;
        let now_us = win32_ui_get_time_us();
        if target_time_us > now_us {
            win32_ui_wait_until_us(target_time_us);
        } else if (now_us - target_time_us) > (frame_period_us * 3) {
            // 3 フレーム以上遅れたら追いかけない。
            target_time_us = now_us;
        }
    }

    c_gui_settings_store();
    win32_ui_destroy();
}

// ウィンドウなしで frames フレームだけ進める。
fn run_headless(emu: X68kEmulator&, frames: i64, dump_path: u8[>..]&) {
    for _ in frames {
        emu.clock_mhz = c_get_cpu_mhz();
        session_run_frame(emu);
    }
    if dump_path.len > 0 { write_dump(dump_path); }
    write_stderr(str("frames: ", emu.total_frames, "\n"));
}

fn main() {
    var content_path: u8[>..] = [];
    var sys_dir: u8[>..] = [];
    var clock_mhz: i32 = 10;
    var mcp_mode = false;
    var no_window = false;
    var max_frames: i64 = -1;
    var frames_set = false;
    var screen_w: i32 = 768; // デフォルト 768x512
    var screen_h: i32 = 512;
    var sys_set = false;
    var clock_set = false;
    var mode_set = false;
    var scale_set = false;
    var content_set = false;
    var scale: i32 = 1;
    var help = false;
    var positional = false;
    var dump_path: u8[>..] = [];
    var dump_after: i64 = 1200;

    let cmd_args = args();
    var arg_idx = 1;
    while arg_idx < cmd_args.len {
        let arg = cmd_args[arg_idx];
        if positional {
            content_path.clear(); content_path.append(arg); content_set = true;
        } else if arg == "--" {
            positional = true;
        } else if arg == "--help" || arg == "-h" {
            help = true;
        } else if arg == "--mcp" {
            mcp_mode = true;
        } else if arg == "--no-window" {
            no_window = true;
        } else if arg == "--mode" && arg_idx + 1 < cmd_args.len {
            arg_idx++;
            let m = cmd_args[arg_idx];
            if m == "512" || m == "512x512" {
                screen_w = 512;
            } else if m == "768" || m == "768x512" {
                screen_w = 768;
            } else { launch_error("--mode must be 512 or 768\n"); }
            mode_set = true;
        } else if arg == "-768" || arg == "--768" {
            screen_w = 768;
            mode_set = true;
        } else if arg == "-512" || arg == "--512" {
            screen_w = 512;
            mode_set = true;
        } else if arg == "--system-dir" && arg_idx + 1 < cmd_args.len {
            arg_idx++;
            sys_dir.clear();
            sys_dir.append(cmd_args[arg_idx]);
            sys_set = true;
        } else if arg == "--clock" && arg_idx + 1 < cmd_args.len {
            arg_idx++;
            let n, ok = parse_int(cmd_args[arg_idx]);
            if !ok || n < 1 || n > 250 { launch_error("invalid --clock value\n"); }
            clock_mhz = n as i32; clock_set = true;
        } else if arg == "--scale" && arg_idx + 1 < cmd_args.len {
            arg_idx++;
            let n, ok = parse_int(cmd_args[arg_idx]);
            if !ok || n < 1 || n > 2 { launch_error("--scale must be 1 or 2\n"); }
            scale = n as i32; scale_set = true;
        } else if arg == "--no-disk" {
            content_path.clear(); content_set = true;
        } else if arg == "--frames" && arg_idx + 1 < cmd_args.len {
            arg_idx++;
            let n, ok = parse_int(cmd_args[arg_idx]);
            if !ok || n < 1 { launch_error("--frames must be a positive integer\n"); }
            max_frames = n; frames_set = true;
        } else if arg == "--dump-frame" && arg_idx + 1 < cmd_args.len {
            arg_idx++;
            dump_path.clear();
            dump_path.append(cmd_args[arg_idx]);
        } else if arg == "--dump-after-frames" && arg_idx + 1 < cmd_args.len {
            arg_idx++;
            let n, ok = parse_int(cmd_args[arg_idx]);
            if !ok || n < 1 { launch_error("--dump-after-frames must be positive\n"); }
            dump_after = n;
        } else if arg == "--mcp-layers" && arg_idx + 1 < cmd_args.len {
            arg_idx++;
            let mask = mcp_parse_layers(cmd_args[arg_idx]);
            if mask < 0 {
                launch_error("--mcp-layers: expected l0,l1,l2,l3,l4 or all\n");
            }
            mcp_set_layers(mask);
        } else if arg == "--ram" && arg_idx + 1 < cmd_args.len {
            // 互換のために受け取る。RAM は 12 MB 固定なので、違う値には一言出す。
            arg_idx++;
            let n, ok = parse_int(cmd_args[arg_idx]);
            if !ok || n != 12 { write_stderr("warning: --ram is ignored; RAM is fixed at 12 MB\n"); }
        } else {
            if arg.len > 0 && arg[0] == '-' { launch_error("unknown option or missing option value (use --help)\n"); }
            content_path.clear();
            content_path.append(arg);
            content_set = true;
        }
        arg_idx++;
    }

    if help { print_help(); return; }
    if no_window && !mcp_mode && !frames_set && dump_path.len == 0 {
        launch_error("--no-window requires --frames N or --dump-frame PATH\n");
    }
    let gui_preferences = !mcp_mode && !no_window;
    c_gui_settings_open(if gui_preferences { 1 } else { 0 });
    // ARCL とヘッドレス実行は毎回同じ SRAM から始める。終了時に sram.dat を書き戻すのは GUI だけ。
    c_sram_set_persist(if gui_preferences { 1 } else { 0 });
    if !sys_set { sys_dir = gui_settings_path(GUI_BIOS); }
    if !clock_set { clock_mhz = c_gui_settings_int(GUI_CLOCK); }
    if !mode_set { screen_w = c_gui_settings_int(GUI_WIDTH); }
    if !scale_set { scale = c_gui_settings_int(GUI_SCALE); }
    c_gui_settings_set_int(GUI_WIDTH, screen_w);
    if sys_dir.len == 0 { launch_error("BIOS directory is empty; use --system-dir PATH\n"); }

    if c_set_cpu_mhz(clock_mhz) == 0 {
        launch_error("--clock must be 10, 16, 25, 50, 75, 100, 150, 200, or 250\n");
    }
    if c_mem_set_ram_mb(12) == 0 {
        write_stderr("failed to set RAM size\n");
        return;
    }

    var sys_buf: u8[>..] = []; sys_buf.append(sys_dir); sys_buf.push('\0');
    var cnt_buf: u8[>..] = []; cnt_buf.append(content_path); cnt_buf.push('\0');

    // ハードウェアメモリ (RAM 12MB, ROM, VRAM, FDD) の初期化
    let mem_ok = x68k_mem_init(sys_buf[0], sys_buf.len as i32, cnt_buf[0], cnt_buf.len as i32);
    if mem_ok == 0 {
        write_stderr(str("Could not initialize BIOS/memory from: ", sys_dir, " (iplrom.dat 128 KiB, cgrom.dat 768 KiB required)\n"));
        if !mcp_mode && !no_window { c_startup_error(); }
        exit(1);
    }
    if content_path.len > 0 && !c_fdd_is_loaded(0) && !c_hdd_is_loaded(0) {
        x68k_mem_destroy();
        launch_error("disk image could not be loaded\n");
    }
    if gui_preferences && !content_set { gui_mount_saved_media(); }

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
        run_gui(emu, screen_w, screen_h, scale, max_frames, dump_path, dump_after);
    } else {
        print_banner(content_path, sys_dir);
        // Without --frames the earlier check guarantees --dump-frame.
        run_headless(emu, if frames_set { max_frames } else { dump_after }, dump_path);
    }
    x68k_mem_destroy();
}
