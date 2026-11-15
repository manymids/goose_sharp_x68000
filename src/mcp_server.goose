// Sharp X68000 ARCL MCP (Model Context Protocol) サーバーモジュール in Goose

import std;
import json;
import .mcp_args;
import .x68k_bridge;
import .m68k_types;
import .x68k_types;
import .m68k_cpu;
import .m68k_mmu;
import .m68k_disasm;
import .x68k_emu;
import .x68k_rom;
import .x68k_mfp;
import .x68k_state;
import .x68k_input;
import .x68k_session;
namespace mcp;

var ::g_console_cols: i32 = 0;
var ::g_console_rows: i32 = 0;
var ::g_mcp_layers: i32 = MCP_LAYER_DEFAULT;
fn reset(emu: X68kEmulator&) {
    session::reset(emu);
    g_console_cols = 0; g_console_rows = 0;
}

fn bad_key(args: const u8[:], key: const u8[:], bad: u8[>..]&) -> bool {
    let v, present, valid = json_addr_parse(args, key);
    if valid { return false; }
    bad.append(str("invalid numeric or hex value for '", key, "'"));
    return true;
}

// Every argument read with mcp::extract_json_addr. A bad value fails the whole call up front.
fn bad_number(args: const u8[:], bad: u8[>..]&) -> bool {
    return bad_key(args, "address", bad) ||
        bad_key(args, "pc", bad) ||
        bad_key(args, "sr", bad) ||
        bad_key(args, "usp", bad) ||
        bad_key(args, "ssp", bad) ||
        bad_key(args, "isp", bad) ||
        bad_key(args, "sp", bad) ||
        bad_key(args, "d0", bad) ||
        bad_key(args, "d1", bad) ||
        bad_key(args, "d2", bad) ||
        bad_key(args, "d3", bad) ||
        bad_key(args, "d4", bad) ||
        bad_key(args, "d5", bad) ||
        bad_key(args, "d6", bad) ||
        bad_key(args, "d7", bad) ||
        bad_key(args, "a0", bad) ||
        bad_key(args, "a1", bad) ||
        bad_key(args, "a2", bad) ||
        bad_key(args, "a3", bad) ||
        bad_key(args, "a4", bad) ||
        bad_key(args, "a5", bad) ||
        bad_key(args, "a6", bad) ||
        bad_key(args, "a7", bad);
}

// "0x" 付きの 16 進文字列を追記する。
fn hex_u32(val: u32, out: u8[>..]&) {
    out.append("0x");
    format_uint(out, val, 16, 8, '0');
}

fn hex_u16(val: u16, out: u8[>..]&) {
    out.append("0x");
    format_uint(out, val, 16, 4, '0');
}

fn hex_nibble(c: u8) -> i32 {
    if c >= '0' && c <= '9' { return (c - '0'); }
    if c >= 'a' && c <= 'f' { return (c - 'a' + 10); }
    if c >= 'A' && c <= 'F' { return (c - 'A' + 10); }
    return -1;
}

fn push_hex_byte(out: u8[>..]&, v: i32) {
    out.append("\"0x");
    format_uint(out, (v & 255) as u64, 16, 2, '0');
    out.push('"');
}

fn write_error_object(id: const u8[:], err: const u8[:], obj: const u8[:]) {
    var qerr: u8[>..] = [];
    json_append_quoted(qerr, err);
    var qobj: u8[>..] = [];
    json_append_quoted(qobj, obj);
    var resp: u8[>..] = [];
    format(resp, "{\"jsonrpc\":\"2.0\",\"id\":", id, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":", qerr, "}],\"isError\":true,\"structuredContent\":", obj, "}}");
    c_io_write_line(resp[0], resp.len as i32);
}

fn append_palette(out: u8[>..]&, base: i32) {
    out.append("[");
    for i in 256 {
        if i != 0 { out.append(","); }
        let off: i32 = base + (i as i32) * 2;
        let hi: i32 = c_mem_read_pal(off);
        let lo: i32 = c_mem_read_pal(off + 1);
        let v = (hi << 8) | lo;
        let r5 = (v >> 6) & 31;
        let g5 = (v >> 11) & 31;
        let b5 = (v >> 1) & 31;
        let r = (r5 << 3) | (r5 >> 2);
        let g = (g5 << 3) | (g5 >> 2);
        let b = (b5 << 3) | (b5 >> 2);
        let inten = if (v & 1) != 0 { "true" } else { "false" };
        format(out, "{\"index\":", i, ",\"r\":", r, ",\"g\":", g, ",\"b\":", b, ",\"intensity\":", inten, "}");
    }
    out.append("]");
}

fn json_append_quoted(out: u8[>..]&, text: const u8[:]) {
    json::format_string(out, text);
}

fn format_text(id: const u8[:], text: const u8[:], is_error: bool, resp: u8[>..]&) {
    var quoted: u8[>..] = [];
    json_append_quoted(quoted, text);
    if is_error {
        format(resp, "{\"jsonrpc\":\"2.0\",\"id\":", id, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":", quoted, "}],\"isError\":true}}");
    } else {
        format(resp, "{\"jsonrpc\":\"2.0\",\"id\":", id, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":", quoted, "}]}}");
    }
}

fn write_text(id: const u8[:], text: const u8[:], is_error: bool) {
    var resp: u8[>..] = [];
    format_text(id, text, is_error, resp);
    c_io_write_line(resp[0], resp.len as i32);
}

fn write_object(id: const u8[:], obj: const u8[:]) {
    var quoted: u8[>..] = [];
    json_append_quoted(quoted, obj);
    var resp: u8[>..] = [];
    format(resp, "{\"jsonrpc\":\"2.0\",\"id\":", id, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":", quoted, "}],\"structuredContent\":", obj, "}}");
    c_io_write_line(resp[0], resp.len as i32);
}

fn append_machine(out: u8[>..]&, emu: X68kEmulator&, frames_used: i32, with_frames: bool, comma: bool) {
    let state = if emu.is_paused { "paused" } else { "running" };
    if comma { out.append(","); }
    if with_frames {
        format(out, "\"machine\":\"x68k\",\"frame\":", emu.total_frames, ",\"state\":\"", state, "\",\"frames_used\":", frames_used);
    } else {
        format(out, "\"machine\":\"x68k\",\"frame\":", emu.total_frames, ",\"state\":\"", state, "\"");
    }
}

fn set_layers(mask: i32) {
    g_mcp_layers = mask;
}

fn parse_layers(text: const u8[:]) -> i32 {
    if text.len == 0 { return MCP_LAYER_DEFAULT; }
    if text == "all" { return MCP_LAYER_ALL; }
    var layers: i32 = 0;
    var i = 0;
    while i < text.len {
        var token: u8[>..] = [];
        while i < text.len && text[i] != ',' {
            token.push(text[i]);
            i += 1;
        }
        var bit: i32 = 0;
        if token == "l0" { bit = MCP_LAYER_L0; }
        else if token == "l1" { bit = MCP_LAYER_L1; }
        else if token == "l2" { bit = MCP_LAYER_L2; }
        else if token == "l3" { bit = MCP_LAYER_L3; }
        else if token == "l4" { bit = MCP_LAYER_L4; }
        else { return -1; }
        if (layers & bit) != 0 { return -1; }
        layers |= bit;
        if i < text.len && text[i] == ',' { i = i + 1; }
    }
    if layers == 0 { return -1; }
    return layers;
}

fn tool_layer(name: const u8[:]) -> i32 {
    if name == "arcl_screenshot" || name == "arcl_joypad" || name == "arcl_key" || name == "arcl_clear_input" || name == "arcl_input_state" || name == "arcl_type" || name == "arcl_input_macro" || name == "arcl_audio_record" { return MCP_LAYER_L0; }
    if name == "arcl_console_read" || name == "arcl_mount" || name == "arcl_command" || name == "arcl_host_dir" { return MCP_LAYER_L1; }
    if name == "arcl_registers" || name == "arcl_read_mem" || name == "arcl_write_mem" || name == "arcl_write_registers" || name == "arcl_step" || name == "arcl_disasm" || name == "arcl_breakpoint" || name == "arcl_stack" { return MCP_LAYER_L2; }
    if name == "arcl_video" || name == "arcl_palette" || name == "arcl_sprites" || name == "arcl_dma" || name == "arcl_irq" || name == "arcl_vram" || name == "x68k_opm" { return MCP_LAYER_L3; }
    if name == "arcl_snapshot" || name == "arcl_rewind" || name == "arcl_speed" { return MCP_LAYER_L4; }
    return 0;
}

fn layer_allows(name: const u8[:]) -> bool {
    let layer = tool_layer(name);
    if layer == 0 { return true; }
    return (g_mcp_layers & layer) != 0;
}

fn append_named_key(emu: X68kEmulator&, out: u8[>..]&, name: const u8[:], first: bool&) {
    let code = input::key_code(name);
    if code < 0 || code >= 128 { return; }
    if !emu.session.keys[code] { return; }
    if !first { out.append(","); }
    out.append("\"");
    out.append(name);
    out.append("\"");
    first = false;
}

fn run_frames_ok(frames: i32) -> bool {
    return frames >= 1 && frames <= 36000;
}

fn live_usp(cpu: M68kCPU&) -> u32 {
    if cpu.is_supervisor() { return cpu.usp; }
    return cpu.a[7];
}

fn live_ssp(cpu: M68kCPU&) -> u32 {
    if cpu.is_supervisor() { return cpu.a[7]; }
    return cpu.ssp;
}

fn tv_ink(x: i32, y: i32) -> bool {
    let row = y & 1023;
    let col_byte = (x & 1023) >> 3;
    let bit = 7 - (x & 7);
    // TVRAM is stored in bus order, so byte x/8 of a raster is at offset x/8.
    let addr = (row * 128 + col_byte);
    var v: u8 = 0;
    if (c_mem_read_tvram(addr) & ((1 << bit) as u8)) != 0 { v = v | 1; }
    if (c_mem_read_tvram(addr + 0x20000) & ((1 << bit) as u8)) != 0 { v = v | 2; }
    if (c_mem_read_tvram(addr + 0x40000) & ((1 << bit) as u8)) != 0 { v = v | 4; }
    if (c_mem_read_tvram(addr + 0x60000) & ((1 << bit) as u8)) != 0 { v = v | 8; }
    return v != 0;
}

fn glyph_eq(code: i32, glyph: u8[>..]&, bold: bool) -> bool {
    let base = 0x3A800 + code * 16;
    for i in 16 {
        let src = x68k_cgrom_read((base + i) as i32);
        let shifted = (src >> 1);
        let want = if bold { (src | shifted) } else { src };
        if glyph[i] != want { return false; }
    }
    return true;
}

fn match_ank(glyph: u8[>..]&) -> i32 {
    var code: i32 = 0x20;
    while code <= 0xDF {
        if code <= 0x7E || code >= 0xA1 {
            if glyph_eq(code, glyph, false) || glyph_eq(code, glyph, true) { return code; }
        }
        code += 1;
    }
    return -1;
}

fn console_decode(emu: X68kEmulator&, text: u8[>..]&) -> i32 {
    var dot_x: i32 = 768;
    var dot_y: i32 = 512;
    let hstart = emu.mmu.crtc_word(CRTC_HSTART);
    let hend = emu.mmu.crtc_word(CRTC_HEND);
    let vstart = emu.mmu.crtc_word(CRTC_VSTART);
    let vend = emu.mmu.crtc_word(CRTC_VEND);
    if hend > hstart { dot_x = (hend - hstart) * 8; }
    if vend > vstart { dot_y = vend - vstart; }
    var cols: i32 = dot_x / 8;
    var rows: i32 = dot_y / 16;
    if cols > 200 { cols = 200; }
    if rows > 80 { rows = 80; }
    if cols < 1 { cols = 1; }
    if rows < 1 { rows = 1; }
    g_console_cols = cols;
    g_console_rows = rows;
    let scroll_x = emu.mmu.crtc_word(CRTC_TEXT_X) & 1023;
    let scroll_y = emu.mmu.crtc_word(CRTC_TEXT_Y) & 1023;
    for r in rows {
        let line_start = text.len;
        for c in cols {
            var glyph: u8[>..] = [];
            var blank = true;
            for gy in 16 {
                var byte: u8 = 0;
                for gx in 8 {
                    let tv_x = ((scroll_x + (c) * 8 + (gx as i32)) & 1023);
                    let tv_y = ((scroll_y + (r) * 16 + (gy as i32)) & 1023);
                    if tv_ink(tv_x, tv_y) { byte = byte | ((0x80 >> (gx as i32)) as u8); }
                }
                if byte != 0 { blank = false; }
                glyph.push(byte);
            }
            var code = match_ank(glyph);
            if code < 0 && !blank {
                // Human68k draws the cursor by inverting the whole cell, so
                // read a cursor cell as the character underneath it.
                var inv: u8[>..] = [];
                var inv_blank = true;
                for gy in 16 {
                    let b = glyph[gy] ^ 0xFF;
                    if b != 0 { inv_blank = false; }
                    inv.push(b);
                }
                code = if inv_blank { 0x20 } else { match_ank(inv) };
            }
            if code >= 0x20 && code <= 0x7E {
                text.push(code as u8);
            } else if code == 0xA0 {
                text.push(' ');
            } else if blank {
                text.push(' ');
            } else {
                text.push('?');
            }
        }
        while text.len > line_start && text[text.len - 1] == ' ' { text.pop(); }
        text.push(10);
    }
    return cols;
}

fn video_object(emu: X68kEmulator&, obj: u8[>..]&) {
    let hstart = emu.mmu.crtc_word(CRTC_HSTART);
    let hend = emu.mmu.crtc_word(CRTC_HEND);
    let vstart = emu.mmu.crtc_word(CRTC_VSTART);
    let vend = emu.mmu.crtc_word(CRTC_VEND);
    var dot_x = 768;
    var dot_y = 512;
    if hend > hstart { dot_x = (hend - hstart) * 8; }
    if vend > vstart { dot_y = vend - vstart; }
    let sx = emu.mmu.crtc_word(CRTC_TEXT_X) & 1023;
    let sy = emu.mmu.crtc_word(CRTC_TEXT_Y) & 1023;
    format(obj, "{\"text\":{\"dot_x\":", dot_x, ",\"dot_y\":", dot_y, ",\"scroll_x\":", sx, ",\"scroll_y\":", sy, "},\"graphic\":{\"scroll\":[");
    let xhi: i32[4] = [0x18, 0x1c, 0x20, 0x24];
    let yhi: i32[4] = [0x1a, 0x1e, 0x22, 0x26];
    for page in 4 {
        if page != 0 { obj.append(","); }
        let gx = emu.mmu.crtc_word(xhi[page]);
        let gy = emu.mmu.crtc_word(yhi[page]);
        format(obj, "{\"page\":", page, ",\"x\":", gx, ",\"y\":", gy, "}");
    }
    obj.append("]},\"crtc\":{\"vstart\":");
    format(obj, vstart, ",\"vend\":", vend, ",\"hstart\":", hstart, ",\"hend\":", hend, "}");
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
}

fn command_line(emu: X68kEmulator&, out: u8[>..]&) {
    var full: u8[>..] = [];
    console_decode(emu, full);
    var n = 0;
    var i = 0;
    while i < full.len {
        if full[i] == 10 { n = n + 1; }
        i += 1;
    }
    if n < 2 { return; }
    let target = n - 2;
    var line = 0;
    var start = 0;
    var best_start = 0;
    var best_len = 0;
    var found = false;
    i = 0;
    while i <= full.len {
        if i == full.len || full[i] == 10 {
            if line <= target && (i - start) > 0 {
                best_start = start;
                best_len = i - start;
                found = true;
            }
            line += 1;
            start = i + 1;
        }
        if i == full.len { break; }
        i += 1;
    }
    if !found { return; }
    for k in best_len {
        out.push(full[best_start + k]);
    }
}

fn control_call(emu: X68kEmulator&, tool_name: const u8[:], args: const u8[:], id_buf: const u8[:]) -> bool {
    if tool_name == "arcl_run" {
        let frames = extract_json_int(args, "frames", 1);
        if !run_frames_ok(frames) {
            write_text(id_buf, "frames must be between 1 and 36000", true);
            return true;
        }
        let used = session::run(emu, frames);
        let reason = if emu.hit_break { "breakpoint" } else { "frames" };
        var obj: u8[>..] = [];
        obj.append("{\"stop_reason\":\"");
        obj.append(reason);
        obj.append("\"");
        append_machine(obj, emu, used, true, true);
        obj.append("}");
        write_object(id_buf, obj);
        return true;
    }

    if tool_name == "arcl_pause" {
        session::pause(emu, win32_ui_get_ticks_ms());
        var resp: u8[>..] = [];
        format(resp, "{\"jsonrpc\":\"2.0\",\"id\":", id_buf, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"status\\\":\\\"paused\\\"}\"}]}}");
        c_io_write_line(resp[0], resp.len as i32);
        return true;
    }

    if tool_name == "arcl_resume" {
        session::resume(emu, win32_ui_get_ticks_ms());
        var resp: u8[>..] = [];
        format(resp, "{\"jsonrpc\":\"2.0\",\"id\":", id_buf, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"status\\\":\\\"running\\\"}\"}]}}");
        c_io_write_line(resp[0], resp.len as i32);
        return true;
    }

    if tool_name == "arcl_status" {
        var obj: u8[>..] = [];
        obj.append("{");
        append_machine(obj, emu, 0, false, false);
        obj.append("}");
        write_object(id_buf, obj);
        return true;
    }

    if tool_name == "arcl_reset" {
        reset(emu);
        var obj: u8[>..] = [];
        obj.append("{");
        append_machine(obj, emu, 0, false, false);
        obj.append("}");
        write_object(id_buf, obj);
        return true;
    }

    if tool_name == "arcl_step" {
        let pc_before = emu.cpu.pc;
        let cycles = emu.step();
        var before_str: u8[>..] = []; hex_u32(pc_before, before_str);
        var after_str: u8[>..] = []; hex_u32(emu.cpu.pc, after_str);
        var sr_str: u8[>..] = []; hex_u16(emu.cpu.sr, sr_str);
        var obj: u8[>..] = [];
        // cycles: CPU clocks the instruction took, bus waits included.
        format(obj, "{\"pc_before\":\"", before_str, "\",\"pc\":\"", after_str, "\",\"sr\":\"", sr_str, "\",\"cycles\":", cycles);
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        write_object(id_buf, obj);
        return true;
    }

    return false;
}

fn tool_key(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var key_name: u8[>..] = [];
    if !extract_json_str(args, "key", key_name) {
        write_text(id_buf, "missing required string field 'key'", true);
        return;
    }
    var act_buf: u8[>..] = [];
    if !extract_json_str(args, "action", act_buf) {
        write_text(id_buf, "missing required string field 'action' (press/release/tap)", true);
        return;
    }
    let code = input::key_code(key_name);
    if code == KEY_BLOCKED {
        write_text(id_buf, "this key is blocked from arcl_key: it triggers a core-internal side effect (F12 opens the built-in menu, ScrollLock toggles MIDI); see x68k_mcp.md 6.1", true);
        return;
    }
    if code < 0 {
        write_text(id_buf, "unmapped key name; see x68k_mcp.md for the supported key set", true);
        return;
    }
    if act_buf == "press" {
        input::key(emu, code, true);
    } else if act_buf == "release" {
        input::key(emu, code, false);
    } else if act_buf == "tap" {
        let frames = extract_json_int(args, "frames", 1);
        if frames < 1 || frames > 3600 {
            write_text(id_buf, "frames must be between 1 and 3600", true);
            return;
        }
        session::key_tap(emu, code, frames);
        var obj: u8[>..] = [];
        format(obj, "{\"key\":\"", key_name, "\",\"action\":\"tap\"");
        append_machine(obj, emu, frames, true, true);
        obj.append("}");
        write_object(id_buf, obj);
        return;
    } else {
        write_text(id_buf, "action must be press, release, or tap", true);
        return;
    }
    var obj: u8[>..] = [];
    format(obj, "{\"key\":\"", key_name, "\",\"action\":\"", act_buf, "\"");
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_type(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var text: u8[>..] = [];
    if !extract_json_str(args, "text", text) || text.len > 256 {
        write_text(id_buf, "missing required string field 'text'", true);
        return;
    }
    let hold = extract_json_int(args, "frames", 2);
    if hold < 1 || hold > 3600 {
        write_text(id_buf, "frames must be between 1 and 3600", true);
        return;
    }
    for i in text.len {
        if !input::type_has_key(text[i]) {
            let hex = "0123456789abcdef";
            var shown = text[i];
            if shown < 0x20 || shown >= 0x7f { shown = '?'; }
            var msg: u8[>..] = [];
            msg.append("character '");
            msg.push(shown);
            msg.append("' (0x");
            msg.push(hex[((text[i] >> 4) & 0x0F) as i32]);
            msg.push(hex[(text[i] & 0x0F) as i32]);
            format(msg, ") at position ", i, " has no mapped key on this keyboard model");
            write_text(id_buf, msg, true);
            return;
        }
    }
    var frames_used: i32 = 0;
    for i in text.len {
        frames_used += session::type_char(emu, text[i], hold);
    }
    var obj: u8[>..] = [];
    format(obj, "{\"chars_typed\":", text.len);
    append_machine(obj, emu, frames_used, true, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_clear_input(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    input::release_held_keys(emu);
    var obj: u8[>..] = [];
    obj.append("{\"cleared\":true");
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_input_state(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var obj: u8[>..] = [];
    obj.append("{\"keys\":[");
    var first = true;
    append_named_key(emu, obj, "a", first);
    append_named_key(emu, obj, "b", first);
    append_named_key(emu, obj, "space", first);
    append_named_key(emu, obj, "return", first);
    append_named_key(emu, obj, "enter", first);
    append_named_key(emu, obj, "shift", first);
    append_named_key(emu, obj, "lshift", first);
    append_named_key(emu, obj, "up", first);
    append_named_key(emu, obj, "down", first);
    append_named_key(emu, obj, "left", first);
    append_named_key(emu, obj, "right", first);
    obj.append("],\"joypad\":[");
    var jfirst = true;
    for port in 2 {
        let joy = if port == 1 { emu.mmu.joy2 } else { emu.mmu.joy1 };
        if (joy & 0x01) == 0 { if !jfirst { obj.append(","); } obj.append("{\"port\":"); format(obj, port, ",\"button\":\"up\"}"); jfirst = false; }
        if (joy & 0x02) == 0 { if !jfirst { obj.append(","); } obj.append("{\"port\":"); format(obj, port, ",\"button\":\"down\"}"); jfirst = false; }
        if (joy & 0x04) == 0 { if !jfirst { obj.append(","); } obj.append("{\"port\":"); format(obj, port, ",\"button\":\"left\"}"); jfirst = false; }
        if (joy & 0x08) == 0 { if !jfirst { obj.append(","); } obj.append("{\"port\":"); format(obj, port, ",\"button\":\"right\"}"); jfirst = false; }
        if (joy & 0x20) == 0 { if !jfirst { obj.append(","); } obj.append("{\"port\":"); format(obj, port, ",\"button\":\"a\"}"); jfirst = false; }
        if (joy & 0x40) == 0 { if !jfirst { obj.append(","); } obj.append("{\"port\":"); format(obj, port, ",\"button\":\"b\"}"); jfirst = false; }
    }
    obj.append("],\"mouse\":{\"left\":false,\"right\":false,\"pending_dx\":0,\"pending_dy\":0}");
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_joypad(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var btn_buf: u8[>..] = [];
    if !extract_json_str(args, "button", btn_buf) {
        write_text(id_buf, "missing required string field 'button'", true);
        return;
    }
    var act_buf: u8[>..] = [];
    if !extract_json_str(args, "action", act_buf) {
        write_text(id_buf, "missing required string field 'action' (press/release/tap)", true);
        return;
    }
    let port = extract_json_int(args, "port", 0);
    if port != 0 && port != 1 {
        write_text(id_buf, "port must be 0 or 1", true);
        return;
    }
    let mask = input::joy_mask(btn_buf);
    if mask == 0 {
        write_text(id_buf, "unmapped joypad button name; see x68k_mcp.md for the supported set", true);
        return;
    }
    var frames_used: i32 = 0;
    if act_buf == "press" || act_buf == "release" || act_buf == "tap" {
        if act_buf == "tap" {
            let frames = extract_json_int(args, "frames", 1);
            if frames < 1 || frames > 3600 {
                write_text(id_buf, "frames must be between 1 and 3600", true);
                return;
            }
            frames_used = frames;
        }
        let pressed = act_buf == "press" || act_buf == "tap";
        if act_buf == "tap" {
            session::joy_tap(emu, port, mask, frames_used);
        } else { input::joy(emu, port, mask, pressed); }
    } else {
        write_text(id_buf, "action must be press, release, or tap", true);
        return;
    }
    var obj: u8[>..] = [];
    format(obj, "{\"port\":", port, ",\"button\":\"", btn_buf, "\",\"action\":\"", act_buf, "\"");
    append_machine(obj, emu, frames_used, act_buf == "tap", true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_command(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var command: u8[>..] = [];
    if !extract_json_str(args, "command", command) || command.len > 180 {
        write_text(id_buf, "missing required string field 'command'", true);
        return;
    }
    for i in command.len {
        if !input::type_has_key(command[i]) {
            write_text(id_buf, "arcl_type failed while echoing the command", true);
            return;
        }
    }
    var frames_used: i32 = 0;
    let hold: i32 = 2;
    for i in command.len {
        frames_used += session::type_char(emu, command[i], hold);
    }
    var after: u8[>..] = [];
    command_line(emu, after);
    var prompt: u8[>..] = [];
    var echoed = after.len >= command.len;
    if echoed {
        for j in command.len {
            if after[after.len - command.len + j] != command[j] { echoed = false; }
        }
    }
    if echoed {
        for j2 in after.len - command.len {
            prompt.push(after[j2]);
        }
    } else {
        var before: u8[>..] = [];
        command_line(emu, before);
        prompt.append(before);
    }
    frames_used += session::type_char(emu, '\n', 2);
    var matched = false;
    while frames_used < 6000 {
        for _ in 30 { session::run_frame(emu); }
        frames_used += 30;
        var lineb: u8[>..] = [];
        command_line(emu, lineb);
        var pref = true;
        for p in prompt.len {
            if p >= lineb.len || lineb[p] != prompt[p] { pref = false; }
        }
        if pref && lineb.len <= prompt.len + 1 {
            matched = true;
            break;
        }
    }
    if !matched {
        write_text(id_buf, "timed out waiting for the prompt to return (6000 frames)", true);
        return;
    }
    var obj: u8[>..] = [];
    obj.append("{\"action\":\"command\"");
    append_machine(obj, emu, frames_used, true, true);
    obj.append("}");
    write_object(id_buf, obj);
}

// マクロの 1 ステップを実行する。失敗したら理由を err に書いて false。
fn macro_step(emu: X68kEmulator&, op: const u8[:], step: const u8[:], frames_used: i32&, err: u8[>..]&) -> bool {
    var step_ok = true;
    if op == "clear_input" {
        input::release_held_keys(emu);
    } else if op == "mouse" {
        step_ok = false;
        err.append("mouse is not available until SCC");
    } else if op == "key" {
        var key_name: u8[>..] = [];
        var act_buf: u8[>..] = [];
        if !extract_json_str(step, "key", key_name) {
            step_ok = false;
            err.append("missing required string field 'key'");
        } else if !extract_json_str(step, "action", act_buf) {
            step_ok = false;
            err.append("missing required string field 'action' (press/release/tap)");
        } else {
            let code = input::key_code(key_name);
            if code < 0 {
                step_ok = false;
                err.append("unmapped key name; see x68k_mcp.md for the supported key set");
            } else if act_buf == "press" {
                input::key(emu, code, true);
            } else if act_buf == "release" {
                input::key(emu, code, false);
            } else if act_buf == "tap" {
                let frames = extract_json_int(step, "frames", 1);
                if frames < 1 || frames > 3600 || frames_used + frames > 10000 {
                    step_ok = false;
                    err.append("frames must be between 1 and 3600");
                } else {
                    session::key_tap(emu, code, frames);
                    frames_used += frames;
                }
            } else {
                step_ok = false;
                err.append("action must be press, release, or tap");
            }
        }
    } else if op == "type" {
        var text: u8[>..] = [];
        if !extract_json_str(step, "text", text) || text.len > 256 {
            step_ok = false;
            err.append("missing required string field 'text'");
        } else {
            let hold = extract_json_int(step, "frames", 2);
            if hold < 1 || hold > 3600 {
                step_ok = false;
                err.append("frames must be between 1 and 3600");
            } else {
                for i in text.len {
                    if !input::type_has_key(text[i]) {
                        step_ok = false;
                        err.append("arcl_type failed while echoing the command");
                    }
                }
                if step_ok {
                    for i in text.len {
                        frames_used += session::type_char(emu, text[i], hold);
                    }
                }
            }
        }
    } else if op == "joypad" {
        var btn: u8[>..] = [];
        var act_buf: u8[>..] = [];
        if !extract_json_str(step, "button", btn) || !extract_json_str(step, "action", act_buf) {
            step_ok = false;
            err.append("missing required string field 'button'");
        } else {
            let mask = input::joy_mask(btn);
            let port = extract_json_int(step, "port", 0);
            if mask == 0 || (port != 0 && port != 1) {
                step_ok = false;
                err.append("unmapped joypad button name; see x68k_mcp.md for the supported set");
            } else if act_buf == "press" || act_buf == "release" || act_buf == "tap" {
                let pressed = act_buf == "press" || act_buf == "tap";
                input::joy(emu, port, mask, pressed);
                if act_buf == "tap" {
                    let frames = extract_json_int(step, "frames", 1);
                    if frames < 1 || frames > 3600 || frames_used + frames > 10000 {
                        step_ok = false;
                        err.append("frames must be between 1 and 3600");
                    } else {
                        session::joy_tap(emu, port, mask, frames);
                        frames_used += frames;
                    }
                }
            } else {
                step_ok = false;
                err.append("action must be press, release, or tap");
            }
        }
    } else if op == "screenshot" {
        if c_frame_ready() == 0 {
            step_ok = false;
            err.append("no frame available yet; call arcl_run first");
        } else if json_has(step, "inline") {
            step_ok = false;
            err.append("inline PNG is not available in this build");
        } else if extract_json_int(step, "scale", 1) != 1 || extract_json_int(step, "grid", 0) != 0 {
            step_ok = false;
            err.append("scaled or cropped PNG output is not available in this build");
        } else {
            var path_buf: u8[>..] = [];
            if !extract_json_str(step, "path", path_buf) { path_buf.append("x68k_screenshot.bmp"); }
            if !save_frame(path_buf[..]) {
                step_ok = false;
                err.append("failed to write screenshot");
            }
        }
    } else if op == "run" {
        let frames = extract_json_int(step, "frames", 1);
        if frames < 1 || frames > 10000 {
            step_ok = false;
            err.append("frames must be between 1 and 10000");
        } else if frames_used + frames > 10000 {
            step_ok = false;
            err.append("macro would exceed the 10000 total-frame budget");
        } else {
            for _ in frames { session::run_frame(emu); }
            frames_used += frames;
        }
    } else {
        step_ok = false;
        err.append("unknown macro step op");
    }
    return step_ok;
}

fn tool_input_macro(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    let list, found = json_member(args, "steps");
    if !found {
        write_text(id_buf, "missing required array field 'steps'", true);
        return;
    }
    var steps: const u8[:][>..] = [];
    if !json_elements(list, steps) {
        write_text(id_buf, "'steps' must be an array", true);
        return;
    }
    var completed: i32 = 0;
    var frames_used: i32 = 0;
    var err: u8[>..] = [];
    var results: u8[>..] = [];
    results.append("{\"results\":[");
    for step in steps {
        if step[0] != '{' {
            write_text(id_buf, "each step must be a JSON object", true);
            return;
        }
        if completed >= 16 {
            write_text(id_buf, "too many steps; max is 16 per arcl_input_macro call", true);
            return;
        }
        var op: u8[>..] = [];
        if !extract_json_str(step, "op", op) {
            write_text(id_buf, "each step needs a string 'op' field", true);
            return;
        }
        let step_ok = macro_step(emu, op, step, frames_used, err);
        if completed != 0 { results.append(","); }
        let ok_txt = if step_ok { "true" } else { "false" };
        format(results, "{\"op\":\"", op, "\",\"ok\":", ok_txt, "}");
        completed += 1;
        if !step_ok { break; }
    }
    format(results, "],\"steps_completed\":", completed, ",\"steps_ok\":", if err.len == 0 { "true" } else { "false" });
    append_machine(results, emu, 0, false, true);
    results.append("}");
    if err.len != 0 {
        write_error_object(id_buf, err, results);
        return;
    }
    write_object(id_buf, results);
}

// 入力系のツール (L0 / L1)。1 ツール 1 関数。
fn input_call(emu: X68kEmulator&, tool_name: const u8[:], args: const u8[:], id_buf: const u8[:]) -> bool {
    if tool_name == "arcl_key" {
        tool_key(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_type" {
        tool_type(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_clear_input" {
        tool_clear_input(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_input_state" {
        tool_input_state(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_joypad" {
        tool_joypad(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_command" {
        tool_command(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_input_macro" {
        tool_input_macro(emu, args, id_buf);
        return true;
    }
    return false;
}

fn tool_save_state(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    let slot = extract_json_int(args, "slot", 0);
    if slot < 0 || slot > 9 {
        write_text(id_buf, "slot must be between 0 and 9", true);
        return;
    }
    // path があれば、スロットに加えてファイルにも保存する。
    var path: u8[>..] = [];
    let to_file = extract_json_str(args, "path", path);
    if to_file && path.len == 0 {
        write_text(id_buf, "path must not be empty", true);
        return;
    }
    if !session::save(emu, slot) {
        write_text(id_buf, "failed to allocate save-state buffer", true);
        return;
    }
    if to_file && !state::save_file(STATE_SLOT, slot, path) {
        write_text(id_buf, "the state was saved to the slot, but the file could not be written", true);
        return;
    }
    var obj: u8[>..] = [];
    format(obj, "{\"slot\":", slot);
    if to_file {
        obj.append(",\"path\":");
        json_append_quoted(obj, path);
    }
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_load_state(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    let slot = extract_json_int(args, "slot", 0);
    if slot < 0 || slot > 9 {
        write_text(id_buf, "slot must be between 0 and 9", true);
        return;
    }
    // path があれば、ファイルをスロットへ読み込んでから戻す。
    var path: u8[>..] = [];
    let from_file = extract_json_str(args, "path", path);
    if from_file {
        let e = session::load_file(emu, slot, path);
        if e != state::StateFileError.None {
            write_text(id_buf, state::file_error_text(e), true);
            return;
        }
    } else if !session::load(emu, slot) {
        write_text(id_buf, "save-state slot is empty or incompatible", true);
        return;
    }
    var obj: u8[>..] = [];
    format(obj, "{\"slot\":", slot);
    if from_file {
        obj.append(",\"path\":");
        json_append_quoted(obj, path);
    }
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_rewind(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var act: u8[>..] = [];
    if !extract_json_str(args, "action", act) {
        write_text(id_buf, "missing required string field 'action' (enable/disable/status/rewind)", true);
        return;
    }
    if act == "enable" {
        let interval = extract_json_int(args, "interval", 60);
        if interval < 10 || interval > 36000 {
            write_text(id_buf, "interval must be between 10 and 36000", true);
            return;
        }
        session::rewind_enable(emu, interval);
        var obj: u8[>..] = [];
        format(obj, "{\"action\":\"enable\",\"interval\":", interval, ",\"depth\":8");
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        write_object(id_buf, obj);
        return;
    }
    if act == "disable" {
        session::rewind_disable(emu);
        var obj: u8[>..] = [];
        obj.append("{\"action\":\"disable\"");
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        write_object(id_buf, obj);
        return;
    }
    if act == "status" {
        let on = if emu.session.rewind_on { "true" } else { "false" };
        var obj: u8[>..] = [];
        format(obj, "{\"action\":\"status\",\"enabled\":", on, ",\"interval\":", emu.session.rewind_interval, ",\"depth\":8,\"entries\":", emu.session.rewind_count, ",\"total_bytes\":", state::total(STATE_REWIND));
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        write_object(id_buf, obj);
        return;
    }
    if act == "rewind" {
        let steps = extract_json_int(args, "steps", 1);
        if steps < 1 || steps > emu.session.rewind_count {
            write_text(id_buf, "not enough rewind history for that many steps", true);
            return;
        }
        if !session::rewind_restore(emu, steps) {
            write_text(id_buf, "core failed to restore rewind snapshot", true);
            return;
        }
        var obj: u8[>..] = [];
        format(obj, "{\"action\":\"rewind\",\"steps\":", steps);
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        write_object(id_buf, obj);
        return;
    }
    write_text(id_buf, "action must be enable, disable, status, or rewind", true);
}

fn tool_speed(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    let nom = emu::nominal_fps(emu.mmu);
    let fps, pct, running = session::speed(emu, win32_ui_get_ticks_ms());
    let run = if running { "true" } else { "false" };
    var obj: u8[>..] = [];
    format(obj, "{\"running\":", run, ",\"fps\":", fps, ",\"nominal_fps\":", nom, ",\"speed_percent\":", pct);
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_snapshot(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var act: u8[>..] = [];
    if !extract_json_str(args, "action", act) {
        write_text(id_buf, "missing required string field 'action' (create/restore/delete/list)", true);
        return;
    }
    if act == "list" {
        var obj: u8[>..] = [];
        obj.append("{\"action\":\"list\",\"snapshots\":[");
        var first = true;
        for i: i32 in 32 {
            if state::saved(STATE_SNAPSHOT, i) {
                if !first { obj.append(","); }
                first = false;
                var name: u8[>..] = [];
                session::snapshot_name(emu, i, name);
                var quoted: u8[>..] = [];
                json_append_quoted(quoted, name);
                format(obj, "{\"name\":", quoted, ",\"frame\":", state::frame(STATE_SNAPSHOT, i), ",\"bytes\":", state::bytes(STATE_SNAPSHOT, i), "}");
            }
        }
        format(obj, "],\"total_bytes\":", state::total(STATE_SNAPSHOT));
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        write_object(id_buf, obj);
        return;
    }
    var name: u8[>..] = [];
    if !extract_json_str(args, "snapshot_name", name) || name.len == 0 || name.len > 63 {
        write_text(id_buf, "missing required string field 'snapshot_name'", true);
        return;
    }
    if act == "create" {
        let idx = session::snapshot_create(emu, name);
        if idx == SNAPSHOT_FULL {
            write_text(id_buf, "snapshot table is full (max 32) - delete one first", true);
            return;
        }
        if idx < 0 {
            write_text(id_buf, "failed to allocate snapshot buffer", true);
            return;
        }
        var quoted: u8[>..] = [];
        json_append_quoted(quoted, name);
        var obj: u8[>..] = [];
        format(obj, "{\"action\":\"create\",\"name\":", quoted, ",\"bytes\":", state::bytes(STATE_SNAPSHOT, idx), ",\"total_bytes\":", state::total(STATE_SNAPSHOT));
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        write_object(id_buf, obj);
        return;
    }
    let idx = session::snapshot_find(emu, name);
    if idx < 0 {
        write_text(id_buf, "no snapshot with that name", true);
        return;
    }
    if act == "restore" {
        if !session::snapshot_restore(emu, name) {
            write_text(id_buf, "core failed to restore state (incompatible snapshot?)", true);
            return;
        }
        var quoted: u8[>..] = [];
        json_append_quoted(quoted, name);
        var obj: u8[>..] = [];
        format(obj, "{\"action\":\"restore\",\"name\":", quoted);
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        write_object(id_buf, obj);
        return;
    }
    if act == "delete" {
        session::snapshot_delete(emu, name);
        var quoted: u8[>..] = [];
        json_append_quoted(quoted, name);
        var obj: u8[>..] = [];
        format(obj, "{\"action\":\"delete\",\"name\":", quoted, ",\"total_bytes\":", state::total(STATE_SNAPSHOT));
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        write_object(id_buf, obj);
        return;
    }
    write_text(id_buf, "action must be create, restore, delete, or list", true);
}

fn checkpoint_call(emu: X68kEmulator&, tool_name: const u8[:], args: const u8[:], id_buf: const u8[:]) -> bool {
    if tool_name == "arcl_save_state" {
        tool_save_state(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_load_state" {
        tool_load_state(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_rewind" {
        tool_rewind(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_speed" {
        tool_speed(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_snapshot" {
        tool_snapshot(emu, args, id_buf);
        return true;
    }
    return false;
}

fn tools_list(id_buf: const u8[:]) {
    var resp: u8[>..] = [];
    format(resp, "{\"jsonrpc\":\"2.0\",\"id\":", id_buf, ",\"result\":{\"tools\":[",
        "{\"name\":\"arcl_run\",\"description\":\"Advance emulation by specified frames\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"frames\":{\"type\":\"integer\"}}}},",
        "{\"name\":\"arcl_pause\",\"description\":\"Pause continuous emulation\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},",
        "{\"name\":\"arcl_resume\",\"description\":\"Resume continuous emulation\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},",
        "{\"name\":\"arcl_status\",\"description\":\"Read machine status\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},",
        "{\"name\":\"arcl_reset\",\"description\":\"Reset the X68000 CPU and MMU\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},",
        "{\"name\":\"arcl_save_state\",\"description\":\"Save emulator state in slot; with path, also write a state file\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"slot\":{\"type\":\"integer\"},\"path\":{\"type\":\"string\"}}}},",
        "{\"name\":\"arcl_load_state\",\"description\":\"Restore emulator state from slot; with path, also read it from a state file\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"slot\":{\"type\":\"integer\"},\"path\":{\"type\":\"string\"}}}}");
    if (g_mcp_layers & MCP_LAYER_L0) != 0 {
        resp.append(",{\"name\":\"arcl_screenshot\",\"description\":\"Save the current frame to a file: PNG if the path ends in .png, otherwise BMP\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}}");
        resp.append(",{\"name\":\"arcl_key\",\"description\":\"Press, release, or tap one keyboard key\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"key\":{\"type\":\"string\"},\"action\":{\"type\":\"string\"}}}}");
        resp.append(",{\"name\":\"arcl_type\",\"description\":\"Type an ASCII string\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"},\"frames\":{\"type\":\"integer\"}},\"required\":[\"text\"]}}");
        resp.append(",{\"name\":\"arcl_clear_input\",\"description\":\"Release held keys and joypad buttons\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}");
        resp.append(",{\"name\":\"arcl_joypad\",\"description\":\"Set joypad button state\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"button\":{\"type\":\"string\"},\"action\":{\"type\":\"string\"},\"port\":{\"type\":\"integer\"}}}}");
        resp.append(",{\"name\":\"arcl_input_state\",\"description\":\"Report held keys and joypad buttons\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}");
        resp.append(",{\"name\":\"arcl_input_macro\",\"description\":\"Run up to 16 input steps\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"steps\":{\"type\":\"array\"}},\"required\":[\"steps\"]}}");
        resp.append(",{\"name\":\"arcl_audio_record\",\"description\":\"Start, stop, or query audio capture\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"}}}}");
    }
    if (g_mcp_layers & MCP_LAYER_L1) != 0 {
        resp.append(",{\"name\":\"arcl_console_read\",\"description\":\"Read visible console text from TVRAM\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}");
        resp.append(",{\"name\":\"arcl_mount\",\"description\":\"Insert or eject the second floppy\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"}}}}");
        resp.append(",{\"name\":\"arcl_command\",\"description\":\"Type a command and wait for the prompt\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}}");
        resp.append(",{\"name\":\"arcl_host_dir\",\"description\":\"List a host directory\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}}");
    }
    if (g_mcp_layers & MCP_LAYER_L2) != 0 {
        resp.append(",{\"name\":\"arcl_registers\",\"description\":\"Read Motorola 68000 CPU registers\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}");
        resp.append(",{\"name\":\"arcl_read_mem\",\"description\":\"Read memory bytes\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"address\":{\"type\":\"integer\"},\"length\":{\"type\":\"integer\"}}}}");
        resp.append(",{\"name\":\"arcl_step\",\"description\":\"Execute one instruction\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}");
        resp.append(",{\"name\":\"arcl_disasm\",\"description\":\"Disassemble 68000 instructions from an address (default: PC)\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"address\":{\"type\":\"string\"},\"count\":{\"type\":\"integer\"}}}}");
        resp.append(",{\"name\":\"arcl_breakpoint\",\"description\":\"Set or clear one execution breakpoint\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"address\":{\"type\":\"string\"},\"action\":{\"type\":\"string\"}}}}");
        resp.append(",{\"name\":\"arcl_write_mem\",\"description\":\"Write hex bytes to memory\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"address\":{},\"data\":{\"type\":\"string\"}},\"required\":[\"address\",\"data\"]}}");
        resp.append(",{\"name\":\"arcl_write_registers\",\"description\":\"Set named CPU registers\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}");
        resp.append(",{\"name\":\"arcl_stack\",\"description\":\"Read words at the stack pointer\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"count\":{\"type\":\"integer\"}}}}");
    }
    if (g_mcp_layers & MCP_LAYER_L3) != 0 {
        resp.append(",{\"name\":\"arcl_video\",\"description\":\"Read CRTC and text geometry\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}");
        resp.append(",{\"name\":\"arcl_palette\",\"description\":\"Read graphic and text palettes\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}");
        resp.append(",{\"name\":\"arcl_sprites\",\"description\":\"Read sprite and BG registers\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}");
        resp.append(",{\"name\":\"arcl_dma\",\"description\":\"Read DMAC channels\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}");
        resp.append(",{\"name\":\"arcl_irq\",\"description\":\"Read MFP and IOC interrupt state\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}");
        resp.append(",{\"name\":\"arcl_vram\",\"description\":\"Read GVRAM or TVRAM bytes\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"region\":{\"type\":\"string\"}}}}");
        resp.append(",{\"name\":\"x68k_opm\",\"description\":\"Read the OPM write shadow\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}");
    }
    if (g_mcp_layers & MCP_LAYER_L4) != 0 {
        resp.append(",{\"name\":\"arcl_snapshot\",\"description\":\"Named in-memory snapshots\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\"},\"snapshot_name\":{\"type\":\"string\"}}}}");
        resp.append(",{\"name\":\"arcl_rewind\",\"description\":\"Frame-interval rewind ring\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\"},\"interval\":{\"type\":\"integer\"},\"steps\":{\"type\":\"integer\"}}}}");
        resp.append(",{\"name\":\"arcl_speed\",\"description\":\"Frames per wall-clock second since resume\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}");
    }
    resp.append("]}}");
    c_io_write_line(resp[0], resp.len as i32);
}

// 画面をファイルに書く。名前が .png で終わっていれば PNG、それ以外は BMP。
fn save_frame(path: const u8[:]) -> bool {
    var ext: u8[4] = [0; 4];
    if path.len >= 4 {
        for i in 4 {
            let c = path[path.len - 4 + i];
            ext[i] = if c >= 'A' && c <= 'Z' { c + 32 } else { c };
        }
    }
    if ext == ".png" { return c_save_fb_png(path) != 0; }
    return c_save_fb_bmp(path) != 0;
}

fn tool_screenshot(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    if c_frame_ready() == 0 {
        write_text(id_buf, "no frame available yet; call arcl_run first", true);
        return;
    }
    let have_x = json_has(args, "x");
    let have_y = json_has(args, "y");
    let have_w = json_has(args, "w");
    let have_h = json_has(args, "h");
    if (have_x || have_y || have_w || have_h) && !(have_x && have_y && have_w && have_h) {
        write_text(id_buf, "specify all of x,y,w,h together, or none for the full frame", true);
        return;
    }
    let sw = c_get_screen_width();
    let sh = c_get_screen_height();
    var x = 0;
    var y = 0;
    var w = sw;
    var h = sh;
    if have_x {
        x = extract_json_int(args, "x", 0);
        y = extract_json_int(args, "y", 0);
        w = extract_json_int(args, "w", 0);
        h = extract_json_int(args, "h", 0);
    }
    if x < 0 || y < 0 || w <= 0 || h <= 0 || x + w > sw || y + h > sh {
        write_text(id_buf, "crop rectangle out of bounds of the current frame", true);
        return;
    }
    let scale = extract_json_int(args, "scale", 1);
    if scale < 1 || scale > 16 {
        write_text(id_buf, "scale must be between 1 and 16", true);
        return;
    }
    let grid = extract_json_int(args, "grid", 0);
    if grid > 0 && scale < 2 {
        write_text(id_buf, "grid requires scale >= 2", true);
        return;
    }
    if (w * scale) * (h * scale) > 480000 {
        write_text(id_buf, "scaled output too large; crop with x/y/w/h or reduce scale", true);
        return;
    }
    if json_has(args, "inline") {
        write_text(id_buf, "inline PNG is not available in this build", true);
        return;
    }
    if scale != 1 || grid != 0 || x != 0 || y != 0 || w != sw || h != sh {
        write_text(id_buf, "scaled or cropped PNG output is not available in this build", true);
        return;
    }
    var path_buf: u8[>..] = [];
    if !extract_json_str(args, "path", path_buf) {
        path_buf.append("x68k_screenshot.bmp");
    }
    if !save_frame(path_buf[..]) {
        write_text(id_buf, "failed to write screenshot", true);
        return;
    }
    var msg: u8[>..] = [];
    msg.append("Screenshot saved to ");
    msg.append(path_buf);
    write_text(id_buf, msg, false);
}

fn tool_console_read(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var txt: u8[>..] = [];
    console_decode(emu, txt);
    var obj: u8[>..] = [];
    var quoted: u8[>..] = [];
    json_append_quoted(quoted, txt);
    format(obj, "{\"cols\":", g_console_cols, ",\"rows\":", g_console_rows, ",\"text\":", quoted);
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_mount(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var act_buf: u8[>..] = [];
    if !extract_json_str(args, "action", act_buf) {
        write_text(id_buf, "missing required string field 'action' (insert/eject)", true);
        return;
    }
    if act_buf == "insert" {
        var path_buf: u8[>..] = [];
        if !extract_json_str(args, "path", path_buf) {
            write_text(id_buf, "insert requires a string field 'path'", true);
            return;
        }
        if !disk::fd_load(1, path_buf[..]) {
            write_text(id_buf, "the core rejected the disk image (bad path or unsupported format)", true);
            return;
        }
        var quoted: u8[>..] = [];
        json_append_quoted(quoted, path_buf);
        var obj: u8[>..] = [];
        format(obj, "{\"action\":\"insert\",\"path\":", quoted);
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        write_object(id_buf, obj);
        return;
    }
    if act_buf == "eject" {
        disk::fd_eject(1);
        var obj: u8[>..] = [];
        obj.append("{\"action\":\"eject\"");
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        write_object(id_buf, obj);
        return;
    }
    write_text(id_buf, "action must be insert or eject", true);
}

fn tool_host_dir(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var path_buf: u8[>..] = [];
    if !extract_json_str(args, "path", path_buf) {
        write_text(id_buf, "missing required string field 'path'", true);
        return;
    }
    var bad = false;
    var pi = 0;
    while pi + 1 < path_buf.len {
        if path_buf[pi] == '.' && path_buf[pi + 1] == '.' { bad = true; }
        pi += 1;
    }
    if bad {
        write_text(id_buf, "path must not contain '..'", true);
        return;
    }
    var listed: u8[8192] = [0; 8192];
    if c_host_list_dir(path_buf[..], listed[0], 8192) != 1 {
        write_text(id_buf, "failed to open directory (does it exist?)", true);
        return;
    }
    var body: u8[>..] = [];
    var li = 0;
    while li < 8192 && listed[li] != 0 {
        body.push(listed[li]);
        li += 1;
    }
    var quoted: u8[>..] = [];
    json_append_quoted(quoted, path_buf);
    var obj: u8[>..] = [];
    format(obj, "{\"entries\":", body, ",\"path\":", quoted);
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_audio_record(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var act: u8[>..] = [];
    if !extract_json_str(args, "action", act) {
        write_text(id_buf, "missing required string field 'action' (start/stop/status)", true);
        return;
    }
    if act == "start" {
        c_audio_capture_start();
        var obj: u8[>..] = [];
        obj.append("{\"action\":\"start\",\"sample_rate\":44100,\"cap_seconds\":60");
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        write_object(id_buf, obj);
        return;
    }
    if act == "status" {
        var active: i32 = 0;
        var frames: i32 = 0;
        var trunc: i32 = 0;
        c_audio_capture_status(active, frames, trunc);
        let on = if active != 0 { "true" } else { "false" };
        let tr = if trunc != 0 { "true" } else { "false" };
        var obj: u8[>..] = [];
        format(obj, "{\"action\":\"status\",\"active\":", on, ",\"frames\":", frames, ",\"truncated\":", tr);
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        write_object(id_buf, obj);
        return;
    }
    if act == "stop" {
        var path_buf: u8[>..] = [];
        extract_json_str(args, "path", path_buf); // 無ければ空のまま。ファイルは書かずに結果だけ返す
        var frames: i32 = 0;
        var trunc: i32 = 0;
        var peak: i32 = 0;
        var silent: i32 = 0;
        if c_audio_capture_stop(path_buf[..], frames, trunc, peak, silent) == 0 {
            write_text(id_buf, "failed to write WAV to path", true);
            return;
        }
        let tr = if trunc != 0 { "true" } else { "false" };
        let sil = if silent != 0 { "true" } else { "false" };
        var obj: u8[>..] = [];
        format(obj, "{\"action\":\"stop\",\"frames\":", frames, ",\"truncated\":", tr, ",\"peak\":", peak, ",\"silent\":", sil);
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        write_object(id_buf, obj);
        return;
    }
    write_text(id_buf, "action must be start, stop, or status", true);
}

// 画面・コンソール・媒体・ホスト側のファイル (L0 / L1)
fn host_call(emu: X68kEmulator&, tool_name: const u8[:], args: const u8[:], id_buf: const u8[:]) -> bool {
    if tool_name == "arcl_screenshot" {
        tool_screenshot(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_console_read" {
        tool_console_read(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_mount" {
        tool_mount(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_host_dir" {
        tool_host_dir(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_audio_record" {
        tool_audio_record(emu, args, id_buf);
        return true;
    }
    return false;
}

fn tool_registers(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var d0_str: u8[>..] = []; hex_u32(emu.cpu.d[0], d0_str);
    var d1_str: u8[>..] = []; hex_u32(emu.cpu.d[1], d1_str);
    var d2_str: u8[>..] = []; hex_u32(emu.cpu.d[2], d2_str);
    var d3_str: u8[>..] = []; hex_u32(emu.cpu.d[3], d3_str);
    var d4_str: u8[>..] = []; hex_u32(emu.cpu.d[4], d4_str);
    var d5_str: u8[>..] = []; hex_u32(emu.cpu.d[5], d5_str);
    var d6_str: u8[>..] = []; hex_u32(emu.cpu.d[6], d6_str);
    var d7_str: u8[>..] = []; hex_u32(emu.cpu.d[7], d7_str);
    var a0_str: u8[>..] = []; hex_u32(emu.cpu.a[REG_A0], a0_str);
    var a1_str: u8[>..] = []; hex_u32(emu.cpu.a[REG_A1], a1_str);
    var a2_str: u8[>..] = []; hex_u32(emu.cpu.a[REG_A2], a2_str);
    var a3_str: u8[>..] = []; hex_u32(emu.cpu.a[REG_A3], a3_str);
    var a4_str: u8[>..] = []; hex_u32(emu.cpu.a[REG_A4], a4_str);
    var a5_str: u8[>..] = []; hex_u32(emu.cpu.a[REG_A5], a5_str);
    var a6_str: u8[>..] = []; hex_u32(emu.cpu.a[REG_A6], a6_str);
    var a7_str: u8[>..] = []; hex_u32(emu.cpu.a[REG_A7], a7_str);
    var pc_str: u8[>..] = []; hex_u32(emu.cpu.pc, pc_str);
    var sr_str: u8[>..] = []; hex_u16(emu.cpu.sr, sr_str);
    var sp_str: u8[>..] = []; hex_u32(emu.cpu.a[REG_A7], sp_str);
    var usp_str: u8[>..] = []; hex_u32(live_usp(emu.cpu), usp_str);
    var ssp_str: u8[>..] = []; hex_u32(live_ssp(emu.cpu), ssp_str);

    var obj: u8[>..] = [];
    format(obj, "{\"d0\":\"", d0_str, "\",\"d1\":\"", d1_str,
        "\",\"d2\":\"", d2_str, "\",\"d3\":\"", d3_str,
        "\",\"d4\":\"", d4_str, "\",\"d5\":\"", d5_str,
        "\",\"d6\":\"", d6_str, "\",\"d7\":\"", d7_str,
        "\",\"a0\":\"", a0_str, "\",\"a1\":\"", a1_str,
        "\",\"a2\":\"", a2_str, "\",\"a3\":\"", a3_str,
        "\",\"a4\":\"", a4_str, "\",\"a5\":\"", a5_str,
        "\",\"a6\":\"", a6_str, "\",\"a7\":\"", a7_str,
        "\",\"pc\":\"", pc_str, "\",\"sr\":\"", sr_str,
        "\",\"sp\":\"", sp_str, "\",\"usp\":\"", usp_str, "\",\"ssp\":\"", ssp_str, "\"");
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_read_mem(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    let addr = extract_json_addr(args, "address", 0);
    let len = extract_json_int(args, "length", 16);
    let read_len = if len <= 0 { 1 } else if len > 65536 { 65536 } else { len };
    let hex_chars = "0123456789abcdef";
    var data_hex: u8[>..] = [];
    for i in read_len {
        let b = emu.mmu.peek8(addr + (i as u32));
        data_hex.push(hex_chars[((b >> 4) & 0x0F) as i32]);
        data_hex.push(hex_chars[(b & 0x0F) as i32]);
    }
    var addr_hex: u8[>..] = [];
    hex_u32(addr, addr_hex);
    var body: u8[>..] = [];
    format(body, "{\"address\":\"", addr_hex, "\",\"length\":", read_len, ",\"data\":\"", data_hex, "\"}");
    write_text(id_buf, body, false);
}

// address から count 命令 (既定 1、最大 64) を逆アセンブルする。address を省くと現在の PC から。
// 先頭の命令は address / opcode / text / length にも入れる。
fn tool_disasm(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var addr = emu.cpu.pc & ADDR_MASK;
    if json_has(args, "address") {
        addr = extract_json_addr(args, "address", addr) & ADDR_MASK;
    }
    let count = extract_json_int(args, "count", 1);
    if count < 1 || count > 64 {
        write_text(id_buf, "count must be between 1 and 64", true);
        return;
    }
    var obj: u8[>..] = [];
    var list: u8[>..] = [];
    var at = addr;
    for i in count {
        var text: u8[>..] = [];
        let length = m68k_disasm(emu.mmu, at, text);
        if i == 0 {
            obj.append("{\"address\":\"");
            hex_u32(at, obj);
            obj.append("\",\"opcode\":\"");
            hex_u16(dis_word(emu.mmu, at), obj);
            obj.append("\",\"text\":");
            json_append_quoted(obj, text);
            format(obj, ",\"length\":", length);
        } else {
            list.push(',');
        }
        list.append("{\"address\":\"");
        hex_u32(at, list);
        list.append("\",\"bytes\":\"");
        for k in length { format_uint(list, emu.mmu.peek8(at + (k as u32)), 16, 2, '0'); }
        list.append("\",\"text\":");
        json_append_quoted(list, text);
        list.push('}');
        at = (at + (length as u32)) & ADDR_MASK;
    }
    format(obj, ",\"instructions\":[", list, "]");
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_breakpoint(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var action: u8[>..] = [];
    extract_json_str(args, "action", action);
    if action == "clear" {
        emu.break_armed = false;
        emu.hit_break = false;
    } else {
        let addr = extract_json_addr(args, "address", emu.cpu.pc & ADDR_MASK);
        emu.break_pc = addr & ADDR_MASK;
        emu.break_armed = true;
        emu.hit_break = false;
    }
    var pc_str: u8[>..] = []; hex_u32(emu.break_pc, pc_str);
    let armed = if emu.break_armed { "true" } else { "false" };
    var obj: u8[>..] = [];
    format(obj, "{\"armed\":", armed, ",\"address\":\"", pc_str, "\"");
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_write_mem(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    if !json_has(args, "address") {
        write_text(id_buf, "missing required field 'address' (integer or hex string)", true);
        return;
    }
    let addr = extract_json_addr(args, "address", 0);
    var hexdata: u8[>..] = [];
    if !extract_json_str(args, "data", hexdata) {
        write_text(id_buf, "missing required string field 'data' (hex bytes, e.g. \"deadbeef\")", true);
        return;
    }
    if hexdata.len == 0 || (hexdata.len % 2) != 0 || hexdata.len > 16384 {
        write_text(id_buf, "'data' must be a non-empty even-length hex string", true);
        return;
    }
    var nbytes: i32 = 0;
    var ok = true;
    while nbytes * 2 < hexdata.len {
        let hi = hex_nibble(hexdata[nbytes * 2]);
        let lo = hex_nibble(hexdata[nbytes * 2 + 1]);
        if hi < 0 || lo < 0 { ok = false; }
        nbytes += 1;
    }
    if !ok {
        write_text(id_buf, "'data' contains a non-hex-digit character", true);
        return;
    }
    for i: i32 in nbytes {
        let hi = hex_nibble(hexdata[i * 2]);
        let lo = hex_nibble(hexdata[i * 2 + 1]);
        emu.mmu.write8(addr + (i as u32), ((hi << 4) | lo) as u8);
    }
    var addr_hex: u8[>..] = [];
    hex_u32(addr, addr_hex);
    var obj: u8[>..] = [];
    format(obj, "{\"address\":\"", addr_hex, "\",\"length\":", nbytes);
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_write_registers(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    if json_has(args, "msp") { write_text(id_buf, "the 68000 has no 'msp' register; nothing was written", true); return; }
    if json_has(args, "vbr") { write_text(id_buf, "the 68000 has no 'vbr' register; nothing was written", true); return; }
    if json_has(args, "sfc") { write_text(id_buf, "the 68000 has no 'sfc' register; nothing was written", true); return; }
    if json_has(args, "dfc") { write_text(id_buf, "the 68000 has no 'dfc' register; nothing was written", true); return; }
    if json_has(args, "cacr") { write_text(id_buf, "the 68000 has no 'cacr' register; nothing was written", true); return; }
    if json_has(args, "caar") { write_text(id_buf, "the 68000 has no 'caar' register; nothing was written", true); return; }
    if json_has(args, "pref_addr") { write_text(id_buf, "the 68000 has no 'pref_addr' register; nothing was written", true); return; }
    if json_has(args, "pref_data") { write_text(id_buf, "the 68000 has no 'pref_data' register; nothing was written", true); return; }
    var wrote = false;
    if json_has(args, "pc") { emu.cpu.pc = extract_json_addr(args, "pc", emu.cpu.pc); wrote = true; }
    if json_has(args, "sr") { emu.cpu.set_sr(extract_json_addr(args, "sr", emu.cpu.sr) as u16); wrote = true; }
    // A7 is the stack pointer of the current mode; USP and SSP name one stack each.
    let sup = emu.cpu.is_supervisor();
    if json_has(args, "usp") {
        let v = extract_json_addr(args, "usp", 0);
        if sup { emu.cpu.usp = v; } else { emu.cpu.a[7] = v; }
        wrote = true;
    }
    if json_has(args, "ssp") || json_has(args, "isp") {
        let v = extract_json_addr(args, "isp", extract_json_addr(args, "ssp", 0));
        if sup { emu.cpu.a[7] = v; } else { emu.cpu.ssp = v; }
        wrote = true;
    }
    if json_has(args, "sp") { emu.cpu.a[7] = extract_json_addr(args, "sp", emu.cpu.a[7]); wrote = true; }
    if json_has(args, "a7") { emu.cpu.a[7] = extract_json_addr(args, "a7", emu.cpu.a[7]); wrote = true; }
    if json_has(args, "d0") { emu.cpu.d[0] = extract_json_addr(args, "d0", emu.cpu.d[0]); wrote = true; }
    if json_has(args, "d1") { emu.cpu.d[1] = extract_json_addr(args, "d1", emu.cpu.d[1]); wrote = true; }
    if json_has(args, "d2") { emu.cpu.d[2] = extract_json_addr(args, "d2", emu.cpu.d[2]); wrote = true; }
    if json_has(args, "d3") { emu.cpu.d[3] = extract_json_addr(args, "d3", emu.cpu.d[3]); wrote = true; }
    if json_has(args, "d4") { emu.cpu.d[4] = extract_json_addr(args, "d4", emu.cpu.d[4]); wrote = true; }
    if json_has(args, "d5") { emu.cpu.d[5] = extract_json_addr(args, "d5", emu.cpu.d[5]); wrote = true; }
    if json_has(args, "d6") { emu.cpu.d[6] = extract_json_addr(args, "d6", emu.cpu.d[6]); wrote = true; }
    if json_has(args, "d7") { emu.cpu.d[7] = extract_json_addr(args, "d7", emu.cpu.d[7]); wrote = true; }
    if json_has(args, "a0") { emu.cpu.a[0] = extract_json_addr(args, "a0", emu.cpu.a[0]); wrote = true; }
    if json_has(args, "a1") { emu.cpu.a[1] = extract_json_addr(args, "a1", emu.cpu.a[1]); wrote = true; }
    if json_has(args, "a2") { emu.cpu.a[2] = extract_json_addr(args, "a2", emu.cpu.a[2]); wrote = true; }
    if json_has(args, "a3") { emu.cpu.a[3] = extract_json_addr(args, "a3", emu.cpu.a[3]); wrote = true; }
    if json_has(args, "a4") { emu.cpu.a[4] = extract_json_addr(args, "a4", emu.cpu.a[4]); wrote = true; }
    if json_has(args, "a5") { emu.cpu.a[5] = extract_json_addr(args, "a5", emu.cpu.a[5]); wrote = true; }
    if json_has(args, "a6") { emu.cpu.a[6] = extract_json_addr(args, "a6", emu.cpu.a[6]); wrote = true; }
    if !wrote {
        write_text(id_buf, "no recognized register fields in request (e.g. \"pc\", \"d0\", \"a7\")", true);
        return;
    }
    var obj: u8[>..] = [];
    obj.append("{\"wrote\":true");
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_stack(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    let count = extract_json_int(args, "count", 16);
    if count < 1 || count > 256 {
        write_text(id_buf, "count must be between 1 and 256", true);
        return;
    }
    let sp = emu.cpu.a[7];
    var sp_hex: u8[>..] = [];
    hex_u32(sp, sp_hex);
    var obj: u8[>..] = [];
    format(obj, "{\"sp\":\"", sp_hex, "\",\"words\":[");
    for i in count {
        let a = sp + ((i as u32) * 4);
        let v = emu.mmu.read32(a);
        if i != 0 { obj.append(","); }
        var ah: u8[>..] = []; hex_u32(a, ah);
        var vh: u8[>..] = []; hex_u32(v, vh);
        format(obj, "{\"address\":\"", ah, "\",\"value\":\"", vh, "\"}");
    }
    obj.append("]");
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

// CPU とメモリのデバッグ (L2)
fn debug_call(emu: X68kEmulator&, tool_name: const u8[:], args: const u8[:], id_buf: const u8[:]) -> bool {
    if tool_name == "arcl_registers" {
        tool_registers(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_read_mem" {
        tool_read_mem(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_disasm" {
        tool_disasm(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_breakpoint" {
        tool_breakpoint(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_write_mem" {
        tool_write_mem(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_write_registers" {
        tool_write_registers(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_stack" {
        tool_stack(emu, args, id_buf);
        return true;
    }
    return false;
}

fn tool_video(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var obj: u8[>..] = [];
    video_object(emu, obj);
    write_object(id_buf, obj);
}

fn tool_vram(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var region: u8[>..] = [];
    if !extract_json_str(args, "region", region) {
        write_text(id_buf, "missing required string field 'region' (gvram/tvram)", true);
        return;
    }
    let gv = region == "gvram";
    if !gv && region != "tvram" {
        write_text(id_buf, "region must be gvram or tvram", true);
        return;
    }
    let address = extract_json_addr(args, "address", 0);
    let length = extract_json_int(args, "length", 256);
    if length < 1 || length > 65536 {
        write_text(id_buf, "length must be between 1 and 65536", true);
        return;
    }
    if address >= 0x80000 || (address + (length as u32)) > 0x80000 {
        write_text(id_buf, "address/length out of range for this region (0x80000 bytes each)", true);
        return;
    }
    let hex = "0123456789abcdef";
    var data_hex: u8[>..] = [];
    for i in length {
        let b = if gv { c_mem_read_gvram((address as i32) + i) } else { c_mem_read_tvram((address as i32) + i) };
        data_hex.push(hex[((b >> 4) & 0x0F) as i32]);
        data_hex.push(hex[(b & 0x0F) as i32]);
    }
    var ah: u8[>..] = [];
    hex_u32(address, ah);
    var obj: u8[>..] = [];
    format(obj, "{\"region\":\"", region, "\",\"address\":\"", ah, "\",\"length\":", length, ",\"data\":\"", data_hex, "\"");
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_irq(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    let crtc_line = emu.mmu.crtc_word(CRTC_RASTER) & 1023;
    var obj: u8[>..] = [];
    obj.append("{\"mfp\":{\"gpip\":");
    // The live input lines as the CPU reads them (V-DISP, H-SYNC, raster, RTC ALARM).
    push_hex_byte(obj, emu.mmu.read8(0xE88001));
    obj.append(",\"aer\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_AER]);
    obj.append(",\"ddr\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_DDR]);
    obj.append(",\"iera\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_IERA]);
    obj.append(",\"ierb\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_IERB]);
    obj.append(",\"ipra\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_IPRA]);
    obj.append(",\"iprb\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_IPRB]);
    obj.append(",\"isra\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_ISRA]);
    obj.append(",\"isrb\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_ISRB]);
    obj.append(",\"imra\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_IMRA]);
    obj.append(",\"imrb\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_IMRB]);
    obj.append(",\"vr\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_VR]);
    obj.append(",\"tacr\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_TACR]);
    obj.append(",\"tbcr\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_TBCR]);
    obj.append(",\"tcdcr\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_TCDCR]);
    obj.append(",\"tadr\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_TADR]);
    obj.append(",\"tbdr\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_TBDR]);
    obj.append(",\"tcdr\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_TCDR]);
    obj.append(",\"tddr\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_TDDR]);
    obj.append(",\"scr\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_SCR]);
    obj.append(",\"ucr\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_UCR]);
    obj.append(",\"rsr\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_RSR]);
    obj.append(",\"tsr\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_TSR]);
    obj.append(",\"udr\":");
    push_hex_byte(obj, emu.mmu.mfp.regs[MFP_UDR]);
    obj.append("},\"ioc\":{\"int_stat\":");
    push_hex_byte(obj, emu.mmu.ioc_int_stat);
    obj.append(",\"int_vect\":");
    push_hex_byte(obj, emu.mmu.ioc_int_vect);
    format(obj, "},\"crtc_int_line\":", crtc_line);
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_dma(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var obj: u8[>..] = [];
    obj.append("{\"channels\":[");
    for i in 4 {
        if i != 0 { obj.append(","); }
        let csr = emu.mmu.dmac.ch[i].csr;
        let cer = emu.mmu.dmac.ch[i].cer;
        let ccr = emu.mmu.dmac.ch[i].ccr;
        let mtc = emu.mmu.dmac.ch[i].mtc;
        let mar = emu.mmu.dmac.ch[i].mar;
        let dar = emu.mmu.dmac.ch[i].dar;
        let btc = emu.mmu.dmac.ch[i].btc;
        let bar = emu.mmu.dmac.ch[i].bar;
        format(obj, "{\"ch\":", i, ",\"csr\":");
        push_hex_byte(obj, csr);
        obj.append(",\"cer\":");
        push_hex_byte(obj, cer);
        obj.append(",\"dcr\":");
        push_hex_byte(obj, emu.mmu.dmac.ch[i].dcr);
        obj.append(",\"ocr\":");
        push_hex_byte(obj, emu.mmu.dmac.ch[i].ocr);
        obj.append(",\"scr\":");
        push_hex_byte(obj, emu.mmu.dmac.ch[i].scr);
        obj.append(",\"ccr\":");
        push_hex_byte(obj, ccr);
        format(obj, ",\"mtc\":", mtc, ",\"mar\":\"");
        hex_u32(mar, obj);
        obj.append("\",\"dar\":\"");
        hex_u32(dar, obj);
        format(obj, "\",\"btc\":", btc, ",\"bar\":\"");
        hex_u32(bar, obj);
        obj.append("\",\"niv\":");
        push_hex_byte(obj, emu.mmu.dmac.ch[i].niv);
        obj.append(",\"eiv\":");
        push_hex_byte(obj, emu.mmu.dmac.ch[i].eiv);
        obj.append(",\"mfc\":");
        push_hex_byte(obj, emu.mmu.dmac.ch[i].mfc);
        obj.append(",\"cpr\":");
        push_hex_byte(obj, emu.mmu.dmac.ch[i].cpr);
        obj.append(",\"dfc\":");
        push_hex_byte(obj, emu.mmu.dmac.ch[i].dfc);
        obj.append(",\"bfc\":");
        push_hex_byte(obj, emu.mmu.dmac.ch[i].bfc);
        obj.append(",\"gcr\":");
        push_hex_byte(obj, emu.mmu.dmac.ch[i].gcr);
        obj.append("}");
    }
    obj.append("]");
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_opm(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var obj: u8[>..] = [];
    format(obj, "{\"lfo\":{\"freq\":", emu.mmu.opm.regs[0x18], "},\"channels\":[");
    for ch in 8 {
        if ch != 0 { obj.append(","); }
        format(obj, "{\"ch\":", ch, ",\"key_on_mask\":", emu.mmu.opm.key_on[ch], "}");
    }
    obj.append("]");
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_palette(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    var obj: u8[>..] = [];
    obj.append("{\"graphic\":");
    append_palette(obj, 0);
    obj.append(",\"text\":");
    append_palette(obj, 0x200);
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

fn tool_sprites(emu: X68kEmulator&, args: const u8[:], id_buf: const u8[:]) {
    let hstart = emu.mmu.crtc_word(CRTC_HSTART);
    let vstart = emu.mmu.crtc_word(CRTC_VSTART);
    let b0d: i32 = c_mem_read_bg_reg(0x0D);
    let b0f: i32 = c_mem_read_bg_reg(0x0F);
    let b11: i32 = c_mem_read_bg_reg(0x11);
    let hadjust = (b0d - (hstart + 4)) * 8;
    let vdiv = if (b11 & 4) != 0 { 1 } else { 2 };
    let vline = (b0f - vstart) / vdiv;
    var obj: u8[>..] = [];
    obj.append("{\"sprites\":[");
    for i in 128 {
        if i != 0 { obj.append(","); }
        let base: i32 = (i as i32) * 8;
        let posx = (c_mem_read_sprite(base)) | ((c_mem_read_sprite(base + 1) as i32) << 8);
        let posy = (c_mem_read_sprite(base + 2)) | ((c_mem_read_sprite(base + 3) as i32) << 8);
        let ctrl = (c_mem_read_sprite(base + 4)) | ((c_mem_read_sprite(base + 5) as i32) << 8);
        let ply: i32 = c_mem_read_sprite(base + 6);
        var ctrl_hex: u8[>..] = [];
        hex_u16(ctrl as u16, ctrl_hex);
        format(obj, "{\"index\":", i, ",\"x\":", posx, ",\"y\":", posy, ",\"priority\":", ply & 3, ",\"palette\":", (ctrl >> 4) & 15, ",\"ctrl_raw\":\"", ctrl_hex, "\"}");
    }
    format(obj, "],\"bg_hadjust\":", hadjust, ",\"bg_vline\":", vline, ",\"vlinebg\":0,\"bg_regs\":\"");
    let hex = "0123456789abcdef";
    for i in 32 {
        let b = c_mem_read_bg_reg(i as i32);
        obj.push(hex[((b >> 4) & 15) as i32]);
        obj.push(hex[(b & 15) as i32]);
    }
    obj.append("\"");
    append_machine(obj, emu, 0, false, true);
    obj.append("}");
    write_object(id_buf, obj);
}

// ビデオ・割り込み・DMA・音源の状態読み出し (L3)
fn inspect_call(emu: X68kEmulator&, tool_name: const u8[:], args: const u8[:], id_buf: const u8[:]) -> bool {
    if tool_name == "arcl_video" {
        tool_video(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_vram" {
        tool_vram(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_irq" {
        tool_irq(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_dma" {
        tool_dma(emu, args, id_buf);
        return true;
    }
    if tool_name == "x68k_opm" {
        tool_opm(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_palette" {
        tool_palette(emu, args, id_buf);
        return true;
    }
    if tool_name == "arcl_sprites" {
        tool_sprites(emu, args, id_buf);
        return true;
    }
    return false;
}

// tools/call の引数オブジェクト。無ければ空のオブジェクト。
fn tool_arguments(params: const u8[:], tool_name: const u8[:]) -> const u8[:] {
    let args, found = json_member(params, "arguments");
    if !found || args[0] != '{' { return "{}"; }
    // XEiJ takes the registers as {"registers": {...}}; accept that as well as flat keys.
    let inner, nested = json_member(args, "registers");
    if tool_name == "arcl_write_registers" && nested && inner[0] == '{' { return inner; }
    return args;
}

fn dispatch(emu: X68kEmulator&, line: const u8[:], is_running: bool&) {
    if line.len == 0 { return; }

    // id は数値でも文字列でもよい。応答には書かれたままの形で返す。
    let id_buf, has_id = json_member(line, "id");

    var method: u8[>..] = [];
    extract_json_str(line, "method", method);

    if method == "notifications/initialized" || method == "initialized" || method == "notifications/cancelled" {
        return;
    }
    if !has_id {
        return;
    }
    if method == "ping" {
        var resp: u8[>..] = [];
        format(resp, "{\"jsonrpc\":\"2.0\",\"id\":", id_buf, ",\"result\":{}}");
        c_io_write_line(resp[0], resp.len as i32);
        return;
    }

    // 1. initialize
    if method == "initialize" {
        var resp: u8[>..] = [];
        format(resp, "{\"jsonrpc\":\"2.0\",\"id\":", id_buf, ",\"result\":{",
            "\"protocolVersion\":\"2024-11-05\",",
            "\"capabilities\":{\"tools\":{}},",
            "\"serverInfo\":{\"name\":\"arcl-x68k-goose\",\"version\":\"1.0.0\"},",
            "\"instructions\":\"Native Goose Motorola 68000 & Sharp X68000 ARCL MCP Server\"",
            "}}");
        c_io_write_line(resp[0], resp.len as i32);
        return;
    }

    // 3. tools/list
    if method == "tools/list" {
        tools_list(id_buf);
        return;
    }

    // 4. tools/call
    if method == "tools/call" {
        let params, _ = json_member(line, "params");
        var tool_name: u8[>..] = [];
        extract_json_str(params, "name", tool_name);
        let args = tool_arguments(params, tool_name);
        if tool_name.len > 0 && !layer_allows(tool_name) {
            write_text(id_buf, "this tool's layer was not enabled via --mcp-layers for this session (see tools/list for what's available)", true);
            return;
        }
        var bad: u8[>..] = [];
        if bad_number(args, bad) {
            write_text(id_buf, bad, true);
            return;
        }

        if control_call(emu, tool_name, args, id_buf) { return; }
        if input_call(emu, tool_name, args, id_buf) { return; }
        if checkpoint_call(emu, tool_name, args, id_buf) { return; }
        if host_call(emu, tool_name, args, id_buf) { return; }
        if debug_call(emu, tool_name, args, id_buf) { return; }
        if inspect_call(emu, tool_name, args, id_buf) { return; }

        // 未知ツール
        var resp: u8[>..] = [];
        format(resp, "{\"jsonrpc\":\"2.0\",\"id\":", id_buf, ",\"error\":{\"code\":-32601,\"message\":\"Unknown tool\"}}");
        c_io_write_line(resp[0], resp.len as i32);
        return;
    }

    // 未知メソッド
    var resp: u8[>..] = [];
    format(resp, "{\"jsonrpc\":\"2.0\",\"id\":", id_buf, ",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}");
    c_io_write_line(resp[0], resp.len as i32);
}
