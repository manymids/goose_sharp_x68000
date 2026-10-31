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

extern fn exit(status: i32);

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

fn write_dump(path: u8[>..] &) {
    var buf: u8[>..] = [];
    buf.append(path);
    buf.push(0);
    if c_save_fb_png(buf[0], buf.len as i32) == 0 {
        write_stderr(str("dump-frame: FAILED to write\n"));
    } else {
        write_stderr(str("dump-frame: wrote\n"));
    }
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
    var dumped = false;

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
            } else { launch_error("--mode must be 512 or 768\n"); return; }
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
            if !ok || n < 1 || n > 250 { launch_error("invalid --clock value\n"); return; }
            clock_mhz = n as i32; clock_set = true;
        } else if arg == "--scale" && arg_idx + 1 < cmd_args.len {
            arg_idx++;
            let n, ok = parse_int(cmd_args[arg_idx]);
            if !ok || n < 1 || n > 2 { launch_error("--scale must be 1 or 2\n"); return; }
            scale = n as i32; scale_set = true;
        } else if arg == "--no-disk" {
            content_path.clear(); content_set = true;
        } else if arg == "--frames" && arg_idx + 1 < cmd_args.len {
            arg_idx++;
            let n, ok = parse_int(cmd_args[arg_idx]);
            if !ok || n < 1 { launch_error("--frames must be a positive integer\n"); return; }
            max_frames = n as i64; frames_set = true;
        } else if arg == "--dump-frame" && arg_idx + 1 < cmd_args.len {
            arg_idx++;
            dump_path.clear();
            dump_path.append(cmd_args[arg_idx]);
        } else if arg == "--dump-after-frames" && arg_idx + 1 < cmd_args.len {
            arg_idx++;
            let n, ok = parse_int(cmd_args[arg_idx]);
            if !ok || n < 1 { launch_error("--dump-after-frames must be positive\n"); return; }
            dump_after = n as i64;
        } else if arg == "--mcp-layers" && arg_idx + 1 < cmd_args.len {
            arg_idx++;
            let mask = mcp_parse_layers(cmd_args[arg_idx]);
            if mask < 0 {
                launch_error("--mcp-layers: expected l0,l1,l2,l3,l4 or all\n");
                return;
            }
            mcp_set_layers(mask);
        } else if arg == "--ram" && arg_idx + 1 < cmd_args.len {
            arg_idx++;
        } else {
            if arg.len > 0 && arg[0] == '-' { launch_error("unknown option or missing option value (use --help)\n"); return; }
            content_path.clear();
            content_path.append(arg);
            content_set = true;
        }
        arg_idx++;
    }

    if help { print_help(); return; }
    if no_window && !mcp_mode && !frames_set && dump_path.len == 0 {
        launch_error("--no-window requires --frames N or --dump-frame PATH\n"); return;
    }
    let gui_preferences = !mcp_mode && !no_window;
    c_gui_settings_open(if gui_preferences { 1 } else { 0 });
    if !sys_set { sys_dir = gui_settings_path(GUI_BIOS); }
    if !clock_set { clock_mhz = c_gui_settings_int(GUI_CLOCK); }
    if !mode_set { screen_w = c_gui_settings_int(GUI_WIDTH); }
    if !scale_set { scale = c_gui_settings_int(GUI_SCALE); }
    c_gui_settings_set_int(GUI_WIDTH, screen_w);
    if sys_dir.len == 0 { launch_error("BIOS directory is empty; use --system-dir PATH\n"); return; }

    if c_set_cpu_mhz(clock_mhz) == 0 {
        launch_error("--clock must be 10, 16, 25, 50, 75, 100, 150, 200, or 250\n");
        return;
    }
    if c_mem_set_ram_mb(12) == 0 {
        write_stderr(str("failed to set RAM size\n"));
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
        return;
    }
    if content_path.len > 0 && !c_fdd_is_loaded(0) && !c_hdd_is_loaded(0) {
        x68k_mem_destroy();
        launch_error("disk image could not be loaded\n"); return;
    }
    if gui_preferences && !content_set { gui_mount_saved_media(); }

    // Goose ネイティブ X68000 エミュレータ本体の初期化
    var emu = X68kEmulator {};
    emu.clock_mhz = c_get_cpu_mhz();
    x68k_emu_init(emu);

    if !mcp_mode {
        print("=================================================");
        print("  Goose Sharp X68000 Native Emulator (Win32)     ");
        print("=================================================");
        print("Motorola 68000 CPU, MMU, PPU written in Goose!");
        print("Content Disk : ", content_path);
        print("System ROMs  : ", sys_dir);
        print("Clock / RAM  : ", c_get_cpu_mhz(), " MHz / 12 MB");
        print("Floppy Loaded: ", if c_fdd_is_loaded(0) { "Yes (Booting Human68k)" } else { "No" });
        print("-------------------------------------------------");
    }

    if mcp_mode {
        // C 版と同じく、MCP は resume まで止めておく。stdin は待たずに見る。
        emu.is_paused = true;
        if c_audio_init() == 0 {
            write_stderr(str("warning: no audio output device available; running silently\n"));
        }

        var window_ok = false;
        if !no_window {
            c_set_screen_mode(screen_w, screen_h);
            var title: u8[>..] = [];
            title.append("Sharp X68000 Emulator - Goose Native");
            title.push('\0');
            if win32_ui_init(title[0], title.len as i32, screen_w, screen_h, scale) {
                window_ok = true;
            } else {
                write_stderr(str("warning: failed to open window; continuing MCP without one\n"));
            }
        }

        var io_buf: u8[65536] = [0; 65536];
        var is_running = true;

        while is_running {
            if window_ok && win32_ui_is_open() {
                win32_ui_poll();
                var sc = win32_ui_get_key_scancode();
                while sc >= 0 {
                    input_host_scancode(emu, sc as u8);
                    sc = win32_ui_get_key_scancode();
                }
                if win32_ui_get_command() == 3 {
                    mcp_reset(emu);
                }
            }

            let wait_ms: i32 = if emu.is_paused { 20 } else { 0 };
            let read_len = c_io_poll_line(io_buf[0], 65536, wait_ms);
            if read_len < 0 {
                break;
            }
            if read_len > 0 {
                mcp_dispatch(emu, io_buf[..read_len], is_running);
            }

            if !emu.is_paused {
                emu.clock_mhz = c_get_cpu_mhz();
                session_run_frame(emu);
                if window_ok && win32_ui_is_open() {
                    win32_ui_render_fb();
                }
                win32_ui_sleep(1);
            }
        }

        if window_ok {
            win32_ui_destroy();
        } else {
            c_audio_shutdown();
        }
        x68k_mem_destroy();
        return;
    }

    // Win32 GUI ウィンドウモード (768x512 / 512x512)
    if !no_window {
        c_set_screen_mode(screen_w, screen_h);

        var title: u8[>..] = [];
        title.append("Sharp X68000 Emulator - Goose Native");
        title.push('\0');

        if !win32_ui_init(title[0], title.len as i32, screen_w, screen_h, scale) {
            print("ERROR: Failed to create Win32 window!");
            x68k_mem_destroy();
            return;
        }

        print("Window opened (", screen_w, "x", screen_h, "). Close window or press ESC to exit.");

        var target_time_us: u64 = win32_ui_get_time_us();

        while win32_ui_is_open() {
            // ウィンドウイベント処理
            let keys = win32_ui_poll();
            if (keys & (1 << 8)) != 0 { // ESC
                break;
            }

            // スキャンコードはリングへ積むだけ。CPU への割り込みはフレーム内の Keyboard_Int が出す。
            var sc = win32_ui_get_key_scancode();
            while sc >= 0 {
                input_host_scancode(emu, sc as u8);
                sc = win32_ui_get_key_scancode();
            }
            emu.mmu.joy1 = c_host_joy_byte() as u8;

            // メニューコマンド処理
            let cmd = win32_ui_get_command();
            if cmd == 3 { // F5: Reset
                session_reset(emu);
                win32_ui_render_fb();
                session_resume(emu, win32_ui_get_ticks_ms()); // GUI resumes; MCP stays paused.
                target_time_us = win32_ui_get_time_us();
            }

            // 1フレームエミュレーション実行
            if !emu.is_paused {
                emu.clock_mhz = c_get_cpu_mhz();
                session_run_frame(emu);
            }

            if max_frames > 0 && emu.total_frames >= max_frames {
                break;
            }
            if dump_path.len > 0 && !dumped && emu.total_frames >= dump_after {
                write_dump(dump_path);
                dumped = true;
            }

            // 画面描画
            win32_ui_render_fb();

            // CRTC 0x29 bit4 が立っているときが 31kHz（約 55.46Hz、18031 us）。
            // 落ちているときが 15kHz（超連射68K、約 61.46Hz、16271 us）。
            let is_31k = (emu.mmu.crtc_regs[0x29] & 0x10) != 0;
            let frame_period_us: u64 = if is_31k { 18031 } else { 16271 };

            target_time_us += frame_period_us;
            let now_us = win32_ui_get_time_us();

            if target_time_us > now_us {
                win32_ui_wait_until_us(target_time_us);
            } else if (now_us - target_time_us) > (frame_period_us * 3) {
                target_time_us = now_us;
            }
        }

        c_gui_settings_store();
        win32_ui_destroy();
    } else {
        if !frames_set {
            if dump_path.len > 0 {
                max_frames = dump_after;
            } else {
                write_stderr(str("--no-window requires --frames N or --dump-frame PATH\n"));
                x68k_mem_destroy();
                return;
            }
        }
        var left = max_frames;
        while left > 0 {
            emu.clock_mhz = c_get_cpu_mhz();
            session_run_frame(emu);
            left = left - 1;
        }
        if dump_path.len > 0 {
            write_dump(dump_path);
        }
        write_stderr(str("frames: ", emu.total_frames, "\n"));
    }

    x68k_mem_destroy();
}
