// 起動引数の解釈。ここでは値を読み取るだけで、設定ファイルや機械には触らない。
// 何かを実行に移すのは main の役目なので、この部分だけを単体テストで確かめられる。

import std;
import .x68k_bridge;
import .mcp_server;
namespace launch;

struct Options {
    content_path: u8[..HOST_PATH_BYTES] = [], // 起動するディスクイメージ。空ならディスクなし
    sys_dir: u8[..HOST_PATH_BYTES] = [],      // BIOS のフォルダ (--system-dir)
    dump_path: u8[..HOST_PATH_BYTES] = [],    // --dump-frame の出力先。空なら書かない
    clock_mhz: i32 = 10,
    screen_w: i32 = 768,
    screen_h: i32 = 512,
    scale: i32 = 1,
    max_frames: i64 = -1,   // --frames。-1 は無制限
    dump_after: i64 = 1200, // --dump-after-frames
    layers: i32 = -1,       // --mcp-layers のビット集合。-1 は指定なし
    mcp_mode: bool = false,
    no_window: bool = false,
    help: bool = false,
    ram_ignored: bool = false, // --ram に 12 以外が指定された (RAM は 12 MB 固定)
    // 指定されたかどうか。指定のないものは、GUI では保存してある設定で補う。
    frames_set: bool = false,
    sys_set: bool = false,
    clock_set: bool = false,
    mode_set: bool = false,
    scale_set: bool = false,
    content_set: bool = false, // ディスクが指定された。--no-disk も含む
}
type ::LaunchOptions = launch::Options;

fn set_path(slot: u8[..HOST_PATH_BYTES]&, path: const u8[:]) -> bool {
    if path.len > HOST_PATH_BYTES { return false; }
    slot.clear();
    slot.append(path);
    return true;
}

// 範囲 lo..hi の整数を読む。
fn number(text: const u8[:], lo: i64, hi: i64) -> i64, bool {
    let n, ok = parse_int(text);
    return n, ok && n >= lo && n <= hi;
}

// 値を取るオプションかどうか。
fn takes_value(arg: const u8[:]) -> bool {
    return arg == "--mode" || arg == "--system-dir" || arg == "--clock" || arg == "--scale" || arg == "--frames"
        || arg == "--dump-frame" || arg == "--dump-after-frames" || arg == "--mcp-layers" || arg == "--ram";
}

// 値を取るオプション 1 つを opt に反映する。問題があればその説明を返す。
fn apply_value(opt: Options&, name: const u8[:], value: const u8[:]) -> const u8[:] {
    if name == "--mode" {
        if value == "512" || value == "512x512" { opt.screen_w = 512; }
        else if value == "768" || value == "768x512" { opt.screen_w = 768; }
        else { return "--mode must be 512 or 768\n"; }
        opt.mode_set = true;
    } else if name == "--system-dir" {
        if !set_path(opt.sys_dir, value) { return "--system-dir: the path is too long\n"; }
        opt.sys_set = true;
    } else if name == "--clock" {
        let n, ok = number(value, 1, 250);
        if !ok { return "invalid --clock value\n"; }
        opt.clock_mhz = n as i32;
        opt.clock_set = true;
    } else if name == "--scale" {
        let n, ok = number(value, 1, 2);
        if !ok { return "--scale must be 1 or 2\n"; }
        opt.scale = n as i32;
        opt.scale_set = true;
    } else if name == "--frames" {
        let n, ok = number(value, 1, 0x7FFFFFFFFFFFFFFF);
        if !ok { return "--frames must be a positive integer\n"; }
        opt.max_frames = n;
        opt.frames_set = true;
    } else if name == "--dump-frame" {
        if !set_path(opt.dump_path, value) { return "--dump-frame: the path is too long\n"; }
    } else if name == "--dump-after-frames" {
        let n, ok = number(value, 1, 0x7FFFFFFFFFFFFFFF);
        if !ok { return "--dump-after-frames must be positive\n"; }
        opt.dump_after = n;
    } else if name == "--mcp-layers" {
        let mask = mcp::parse_layers(value);
        if mask < 0 { return "--mcp-layers: expected l0,l1,l2,l3,l4 or all\n"; }
        opt.layers = mask;
    } else if name == "--ram" {
        // 互換のために受け取る。RAM は 12 MB 固定。
        let _, ok = number(value, 12, 12);
        if !ok { opt.ram_ignored = true; }
    }
    return "";
}

// args (プログラム名を除いた引数) を読んで opt に入れる。最初に見つけた問題の説明を返し、
// 問題がなければ空の文字列を返す。
fn parse(args: const u8[:][:], opt: Options&) -> const u8[:] {
    var positional = false; // "--" の後ろは、'-' で始まっていてもディスクイメージの名前
    var i = 0;
    while i < args.len {
        let arg = args[i];
        i += 1;
        if !positional && arg == "--" {
            positional = true;
        } else if !positional && takes_value(arg) && i < args.len {
            let problem = apply_value(opt, arg, args[i]);
            if problem.len > 0 { return problem; }
            i += 1;
        } else if !positional && (arg == "--help" || arg == "-h") {
            opt.help = true;
        } else if !positional && arg == "--mcp" {
            opt.mcp_mode = true;
        } else if !positional && arg == "--no-window" {
            opt.no_window = true;
        } else if !positional && (arg == "-768" || arg == "--768" || arg == "-512" || arg == "--512") {
            opt.screen_w = if arg == "-512" || arg == "--512" { 512 } else { 768 };
            opt.mode_set = true;
        } else if !positional && arg == "--no-disk" {
            opt.content_path.clear();
            opt.content_set = true;
        } else {
            if !positional && arg.len > 0 && arg[0] == '-' {
                return "unknown option or missing option value (use --help)\n";
            }
            if !set_path(opt.content_path, arg) { return "the disk image path is too long\n"; }
            opt.content_set = true;
        }
    }
    if opt.help { return ""; }
    if opt.no_window && !opt.mcp_mode && !opt.frames_set && opt.dump_path.len == 0 {
        return "--no-window requires --frames N or --dump-frame PATH\n";
    }
    return "";
}
