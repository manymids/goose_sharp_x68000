// ウィンドウで起動したときの設定 (arcl_windows_x68k_goose.ini)。機械のチェックポイントとは別のもの。
//
// ファイルは UTF-8 で、[gui] の見出しの下に key=value の行が並ぶ。読み書きは標準ライブラリで行い、
// 絶対パスへの変換と、旧版が ANSI で書いたパスの変換だけを C (Win32) に頼む。
// ARCL (--mcp) とウィンドウなしの起動では、ファイルを読みも書きもしない。

import std;
import os;
import .x68k_bridge;
namespace config;

let ::GUI_CLOCK = 0;
let ::GUI_SCALE = 1;
let ::GUI_WIDTH = 2;
let ::GUI_AHEAD = 3;   // ウィンドウで先読みして見せるフレーム数 (0 で使わない)
let ::AHEAD_SHOW_MAX = 4;
let INT_COUNT = 4;
let ::GUI_BIOS = 0;
let ::GUI_FD0 = 1;
let ::GUI_FD1 = 2;
let ::GUI_HDD = 3;

let CONFIG_FILE = "arcl_windows_x68k_goose.ini";
let MAX_FILE_BYTES = 16383;   // これより後ろは読まない
let PATH_BYTES = 781;         // Win32 の MAX_PATH (260) 文字を UTF-8 にした長さ + 1
let CLOCKS: i32[9] = [10, 16, 25, 50, 75, 100, 150, 200, 250];
let INT_KEYS: const u8[:][INT_COUNT] = ["clock_mhz", "scale", "screen_width", "run_ahead"];
let PATH_KEYS: const u8[:][4] = ["bios_dir", "fd0", "fd1", "hdd"];

struct Settings {
    enabled: bool = false,                   // ファイルへ書く (ウィンドウで起動したときだけ)
    values: i32[INT_COUNT] = [10, 1, 768, 0], // GUI_CLOCK、GUI_SCALE、GUI_WIDTH、GUI_AHEAD
    paths: u8[..PATH_BYTES][4] = [[]; 4],    // GUI_BIOS、GUI_FD0、GUI_FD1、GUI_HDD (絶対パス)
}

var g_settings = Settings {};

fn int_value(key: i32) -> i32 {
    return if key >= 0 && key < INT_COUNT { g_settings.values[key] } else { 0 };
}

// 値が範囲に合っていれば入れて true。クロックは選べる値のどれか、拡大率は 1 か 2、幅は 512 か 768。
fn set_int(key: i32, value: i32) -> bool {
    var ok = false;
    if key == GUI_CLOCK {
        for c in CLOCKS { if c == value { ok = true; } }
    } else if key == GUI_SCALE {
        ok = value == 1 || value == 2;
    } else if key == GUI_WIDTH {
        ok = value == 512 || value == 768;
    } else if key == GUI_AHEAD {
        ok = value >= 0 && value <= AHEAD_SHOW_MAX;
    }
    if ok { g_settings.values[key] = value; }
    return ok;
}

fn path(key: i32) -> const u8[:] {
    return if key >= 0 && key < 4 { g_settings.paths[key][..] } else { "" };
}

// path を絶対パスにして入れる。空なら消す (BIOS のフォルダは消せない)。改行を含むものや長すぎるものは断る。
fn set_path(key: i32, value: const u8[:]) -> bool {
    if key < 0 || key >= 4 { return false; }
    var n: i64 = 0;
    while n < value.len && value[n] != 0 {
        if n >= PATH_BYTES - 2 || value[n] == '\r' || value[n] == '\n' { return false; }
        n += 1;
    }
    if n == 0 {
        if key == GUI_BIOS { return false; }
        g_settings.paths[key].clear();
        return true;
    }
    var full: u8[PATH_BYTES] = [0; PATH_BYTES];
    let len = c_full_path(value[..n], full[0], PATH_BYTES);
    if len <= 0 { return false; }
    g_settings.paths[key].clear();
    g_settings.paths[key].append(full[..len]);
    return true;
}

// ---------------------------------------------------------------
// ファイルの中身
// ---------------------------------------------------------------

// "key=" で始まる最初の行の、= より後ろ。無ければ false。見出しは見ない (元の C の実装と同じ)。
fn ini_value(text: const u8[:], key: const u8[:]) -> const u8[:], bool {
    var at: i64 = 0;
    while at < text.len {
        var end = at;
        while end < text.len && text[end] != '\r' && text[end] != '\n' { end += 1; }
        let line = text[at..end];
        if line.len > key.len && line[..key.len] == key && line[key.len] == '=' {
            return line[key.len + 1..], true;
        }
        at = end;
        while at < text.len && (text[at] == '\r' || text[at] == '\n') { at += 1; }
    }
    return text[0..0], false;
}

fn is_space(c: u8) -> bool {
    return c == ' ' || c == '\t' || c == '\n' || c == 11 || c == 12 || c == '\r';
}

// 整数の値を C の strtol と同じ規則で読む (前の空白、符号、後ろの空白とタブは許す)。
// 0〜100000 の範囲に入らない、読めない、無いときは fallback。
fn read_int(text: const u8[:], key: const u8[:], fallback: i32) -> i32 {
    let value, found = ini_value(text, key);
    if !found || value.len == 0 || value.len >= 63 { return fallback; }
    var i: i64 = 0;
    while i < value.len && is_space(value[i]) { i += 1; }
    var negative = false;
    if i < value.len && (value[i] == '+' || value[i] == '-') {
        negative = value[i] == '-';
        i += 1;
    }
    var n: i64 = 0;
    var digits = 0;
    while i < value.len && value[i] >= '0' && value[i] <= '9' {
        n = min(n * 10 + (value[i] - '0'), 4294967296);
        digits += 1;
        i += 1;
    }
    if digits == 0 { i = 0; }     // 数字が無ければ strtol は先頭を指したまま
    while i < value.len && (value[i] == ' ' || value[i] == '\t') { i += 1; }
    if i < value.len { return fallback; }
    if negative { n = 0 - n; }
    if n < 0 || n > 100000 { return fallback; }
    return n as i32;
}

fn utf8_valid(s: const u8[:]) -> bool {
    var i: i64 = 0;
    while i < s.len {
        let c: u32 = s[i];
        var need: i64 = 0;
        var min_code: u32 = 0;
        var code: u32 = 0;
        if c < 0x80 { i += 1; continue; }
        else if c >= 0xC2 && c < 0xE0 { need = 1; min_code = 0x80; code = c & 0x1F; }
        else if c >= 0xE0 && c < 0xF0 { need = 2; min_code = 0x800; code = c & 0x0F; }
        else if c >= 0xF0 && c < 0xF5 { need = 3; min_code = 0x10000; code = c & 0x07; }
        else { return false; }
        if i + need >= s.len { return false; }   // 続きのバイトが足りない
        for k in 1..need + 1 {
            let b: u32 = s[i + k];
            if (b & 0xC0) != 0x80 { return false; }
            code = (code << 6) | (b & 0x3F);
        }
        if code < min_code || code > 0x10FFFF || (code >= 0xD800 && code < 0xE000) { return false; }
        i += need + 1;
    }
    return true;
}

// 旧版は ANSI でパスを書いていた。UTF-8 として正しくない値だけを、ANSI として読み直す。
fn path_from_legacy(value: const u8[:], out: u8[>..]&) {
    if utf8_valid(value) {
        out.append(value);
        return;
    }
    var converted: u8[PATH_BYTES] = [0; PATH_BYTES];
    let n = c_ansi_to_utf8(value, converted[0], PATH_BYTES);
    if n > 0 { out.append(converted[..n]); }
}

// ファイルの中身から設定を読む。読めない値は既定のまま。
fn parse(contents: const u8[:]) {
    var text = contents[..min(contents.len, MAX_FILE_BYTES)];
    for i in text.len {
        if text[i] == 0 { text = text[..i]; break; }   // C の文字列と同じく NUL で終わる
    }
    if read_int(text, "version", 1) != 1 { return; }
    for i: i32 in INT_COUNT { set_int(i, read_int(text, INT_KEYS[i], g_settings.values[i])); }
    for i: i32 in 4 {
        let value, found = ini_value(text, PATH_KEYS[i]);
        if !found || value.len >= PATH_BYTES - 1 { continue; }
        var p: u8[>..] = [];
        path_from_legacy(value, p);
        set_path(i, p);
    }
}

fn render(out: u8[>..]&) {
    out.append("[gui]\r\nversion=1\r\n");
    for i in INT_COUNT { format(out, INT_KEYS[i], "=", g_settings.values[i], "\r\n"); }
    for i in 4 { format(out, PATH_KEYS[i], "=", g_settings.paths[i][..], "\r\n"); }
}

// ---------------------------------------------------------------
// 起動と保存
// ---------------------------------------------------------------

// 既定の設定にして、allow_file ならファイルから読む。
fn open(allow_file: bool) {
    g_settings = Settings {};
    set_path(GUI_BIOS, ".\\keropi");
    if !allow_file { return; }   // ARCL ではファイルを見もしない
    g_settings.enabled = true;
    var contents: u8[>..] = [];
    if read_file(CONFIG_FILE, contents) { parse(contents); }
}

// ファイルへ書く。古い中身か新しい中身のどちらかが必ず残る。
fn save() -> bool {
    if !g_settings.enabled { return true; }
    var text: u8[>..] = [];
    render(text);
    return write_file_atomic(CONFIG_FILE, text);
}

// ホストの今の値 (クロック、拡大率) を取り込んで保存する
fn store() {
    set_int(GUI_CLOCK, c_get_cpu_mhz());
    set_int(GUI_SCALE, c_get_scale());
    if !save() { write_stderr(str("warning: could not save ", CONFIG_FILE, "\n")); }
}

// ウィンドウのメニューで設定が変わっていたら取り込んで保存する。1 フレームに 1 回呼ぶ。
fn sync_from_host() {
    var width: i32 = 0;
    if c_gui_take_settings_changes(width) == 0 { return; }
    if width != 0 { set_int(GUI_WIDTH, width); }
    store();
}
