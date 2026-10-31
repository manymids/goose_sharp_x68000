// Sharp X68000 ARCL MCP (Model Context Protocol) サーバーモジュール in Goose

import std;
import .x68k_bridge;
import .m68k_types;
import .x68k_types;
import .m68k_cpu;
import .m68k_mmu;
import .x68k_emu;
import .x68k_rom;
import .x68k_mfp;
import .x68k_state;
import .x68k_input;
import .x68k_session;

var g_console_cols: i32 = 0;
var g_console_rows: i32 = 0;
var g_mcp_layers: i32 = MCP_LAYER_DEFAULT;
fn mcp_reset(emu: X68kEmulator&) {
    session_reset(emu);
    g_console_cols = 0; g_console_rows = 0;
}

fn mcp_run_frame(emu: X68kEmulator&) { session_run_frame(emu); }

// px68k windows/mcp_json.c. Keys are matched as JSON keys, not raw substrings.

fn json_skip_ws(s: const u8[:], i: i32) -> i32 {
    var p = i;
    while p >= 0 && p < s.len {
        let c = s[p];
        if c != ' ' && c != '\t' && c != '\n' && c != '\r' { break; }
        p = p + 1;
    }
    return p;
}

fn json_skip_string(s: const u8[:], i: i32) -> i32 {
    if i < 0 || i >= s.len || s[i] != '"' { return -1; }
    var p = i + 1;
    while p < s.len {
        if s[p] == '\\' {
            if p + 1 >= s.len { return -1; }
            p = p + 2;
        } else if s[p] == '"' {
            return p + 1;
        } else {
            p = p + 1;
        }
    }
    return -1;
}

fn json_value_end(s: const u8[:], i: i32) -> i32 {
    if i < 0 || i >= s.len { return -1; }
    if s[i] == '"' { return json_skip_string(s, i); }
    if s[i] == '{' || s[i] == '[' {
        var depth = 0;
        var p = i;
        while p < s.len {
            if s[p] == '"' {
                p = json_skip_string(s, p);
                if p < 0 { return -1; }
            } else {
                if s[p] == '{' || s[p] == '[' { depth = depth + 1; }
                else if s[p] == '}' || s[p] == ']' {
                    depth = depth - 1;
                    if depth == 0 { return p + 1; }
                }
                p = p + 1;
            }
        }
        return -1;
    }
    var p = i;
    while p < s.len {
        let c = s[p];
        if c == ',' || c == '}' || c == ']' || c == ' ' || c == '\t' || c == '\n' || c == '\r' { break; }
        p = p + 1;
    }
    return p;
}

fn json_key_eq(s: const u8[:], start: i32, end: i32, key: const u8[:]) -> bool {
    if start < 0 || end < start + 2 || end > s.len { return false; }
    if s[start] != '"' || s[end - 1] != '"' { return false; }
    let inner = end - start - 2;
    if inner != key.len { return false; }
    for j in 0..key.len {
        if s[start + 1 + (j as i32)] != key[j] { return false; }
    }
    return true;
}

fn json_key_value(s: const u8[:], from: i32, key: const u8[:]) -> i32 {
    var p = json_skip_ws(s, from);
    if p >= s.len || s[p] != '{' { return -1; }
    p = p + 1;
    while p < s.len {
        p = json_skip_ws(s, p);
        if p >= s.len { return -1; }
        if s[p] == '}' { return -1; }
        let key_end = json_skip_string(s, p);
        if key_end < 0 { return -1; }
        let matched = json_key_eq(s, p, key_end, key);
        p = json_skip_ws(s, key_end);
        if p >= s.len || s[p] != ':' { return -1; }
        p = json_skip_ws(s, p + 1);
        if matched { return p; }
        p = json_value_end(s, p);
        if p < 0 { return -1; }
        p = json_skip_ws(s, p);
        if p < s.len && s[p] == ',' { p = p + 1; }
        else { return -1; }
    }
    return -1;
}

fn json_find_any_value(s: const u8[:], key: const u8[:]) -> i32 {
    var p: i32 = 0;
    while p < s.len {
        if s[p] != '"' {
            p = p + 1;
        } else {
            let key_end = json_skip_string(s, p);
            if key_end < 0 { return -1; }
            let matched = json_key_eq(s, p, key_end, key);
            let value = json_skip_ws(s, key_end);
            if matched && value < s.len && s[value] == ':' {
                return json_skip_ws(s, value + 1);
            }
            p = key_end;
        }
    }
    return -1;
}

fn json_hex4(s: const u8[:], i: i32) -> i32 {
    if i < 0 || i + 4 > s.len { return -1; }
    var v: i32 = 0;
    for k in 4 {
        let c = s[i + k];
        v = v * 16;
        if c >= '0' && c <= '9' { v = v + ((c - '0') as i32); }
        else if c >= 'a' && c <= 'f' { v = v + ((c - 'a' + 10) as i32); }
        else if c >= 'A' && c <= 'F' { v = v + ((c - 'A' + 10) as i32); }
        else { return -1; }
    }
    return v;
}

fn json_push_utf8(out: u8[>..]&, cp: i32) {
    if cp < 0 { return; }
    if cp <= 0x7F {
        out.push(cp as u8);
    } else if cp <= 0x7FF {
        out.push((0xC0 | (cp >> 6)) as u8);
        out.push((0x80 | (cp & 0x3F)) as u8);
    } else if cp <= 0xFFFF {
        out.push((0xE0 | (cp >> 12)) as u8);
        out.push((0x80 | ((cp >> 6) & 0x3F)) as u8);
        out.push((0x80 | (cp & 0x3F)) as u8);
    } else {
        out.push((0xF0 | (cp >> 18)) as u8);
        out.push((0x80 | ((cp >> 12) & 0x3F)) as u8);
        out.push((0x80 | ((cp >> 6) & 0x3F)) as u8);
        out.push((0x80 | (cp & 0x3F)) as u8);
    }
}

fn json_read_string(s: const u8[:], i: i32, out: u8[>..]&) -> bool {
    if i < 0 || i >= s.len || s[i] != '"' { return false; }
    var p = i + 1;
    while p < s.len && s[p] != '"' {
        if s[p] == '\\' {
            if p + 1 >= s.len { return false; }
            let e = s[p + 1];
            if e == '"' || e == '\\' || e == '/' {
                out.push(e);
                p = p + 2;
            } else if e == 'b' {
                out.push(8);
                p = p + 2;
            } else if e == 'f' {
                out.push(12);
                p = p + 2;
            } else if e == 'n' {
                out.push(10);
                p = p + 2;
            } else if e == 'r' {
                out.push(13);
                p = p + 2;
            } else if e == 't' {
                out.push(9);
                p = p + 2;
            } else if e == 'u' {
                let cp = json_hex4(s, p + 2);
                if cp < 0 { return false; }
                p = p + 6;
                var code = cp;
                if cp >= 0xD800 && cp <= 0xDBFF {
                    if p + 6 > s.len || s[p] != '\\' || s[p + 1] != 'u' { return false; }
                    let lo = json_hex4(s, p + 2);
                    if lo < 0xDC00 || lo > 0xDFFF { return false; }
                    code = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    p = p + 6;
                } else if cp >= 0xDC00 && cp <= 0xDFFF {
                    return false;
                }
                json_push_utf8(out, code);
            } else {
                return false;
            }
        } else {
            out.push(s[p]);
            p = p + 1;
        }
    }
    if p >= s.len || s[p] != '"' { return false; }
    return true;
}

fn json_read_long(s: const u8[:], i: i32) -> i32 {
    if i < 0 || i >= s.len { return 0; }
    var p = i;
    var neg = false;
    if s[p] == '-' {
        neg = true;
        p = p + 1;
    }
    if p >= s.len || s[p] < '0' || s[p] > '9' { return 0; }
    var n: i32 = 0;
    var saw = false;
    while p < s.len && s[p] >= '0' && s[p] <= '9' {
        n = n * 10 + ((s[p] - '0') as i32);
        saw = true;
        p = p + 1;
    }
    if !saw { return 0; }
    if neg { return 0 - n; }
    return n;
}

fn json_read_long_ok(s: const u8[:], i: i32) -> bool {
    if i < 0 || i >= s.len { return false; }
    var p = i;
    if s[p] == '-' { p = p + 1; }
    if p >= s.len || s[p] < '0' || s[p] > '9' { return false; }
    return true;
}

fn json_top_string(s: const u8[:], key: const u8[:], out: u8[>..]&) -> bool {
    let at = json_key_value(s, 0, key);
    if at < 0 { return false; }
    return json_read_string(s, at, out);
}

fn json_any_string(s: const u8[:], key: const u8[:], out: u8[>..]&) -> bool {
    let at = json_find_any_value(s, key);
    if at < 0 { return false; }
    return json_read_string(s, at, out);
}

fn json_extract_object(s: const u8[:], key: const u8[:], out: u8[>..]&) -> bool {
    let start = json_find_any_value(s, key);
    if start < 0 || start >= s.len || s[start] != '{' { return false; }
    let end = json_value_end(s, start);
    if end < 0 || end < start { return false; }
    out.append(s[start..end]);
    return true;
}

fn json_top_id(s: const u8[:], out: u8[>..]&) -> bool {
    let start = json_key_value(s, 0, "id");
    if start < 0 || start >= s.len { return false; }
    var end = start;
    if s[start] == '"' {
        end = json_skip_string(s, start);
    } else {
        while end < s.len {
            let c = s[end];
            if c == ',' || c == '}' || c == ' ' || c == '\t' || c == '\n' || c == '\r' { break; }
            end = end + 1;
        }
    }
    if end < 0 || end == start { return false; }
    out.append(s[start..end]);
    return true;
}

fn extract_json_str(line: const u8[:], key: const u8[:], out: u8[>..]&) -> bool {
    let at = json_key_value(line, 0, key);
    if at < 0 { return false; }
    return json_read_string(line, at, out);
}

fn extract_json_int(line: const u8[:], key: const u8[:], default_val: i32) -> i32 {
    let at = json_key_value(line, 0, key);
    if at < 0 || !json_read_long_ok(line, at) { return default_val; }
    return json_read_long(line, at);
}

fn extract_json_addr(line: const u8[:], key: const u8[:], default_val: u32) -> u32 {
    let at = json_key_value(line, 0, key);
    if at < 0 || at >= line.len { return default_val; }
    if json_read_long_ok(line, at) {
        // CPU registers span u32: an i32 accumulator traps on valid high bits.
        var p = at;
        let neg = line[p] == '-';
        if neg { p += 1; }
        var n: u64 = 0;
        while p < line.len && line[p] >= '0' && line[p] <= '9' {
            let digit = (line[p] - '0') as u64;
            if n > (0xFFFFFFFF as u64 - digit) / 10 { return default_val; }
            n = n * 10 + digit;
            p += 1;
        }
        if neg { return (0x100000000 as u64 - n) as! u32; }
        return n as u32;
    }
    var text: u8[>..] = [];
    if !json_read_string(line, at, text) || text.len == 0 { return default_val; }
    var idx: i32 = 0;
    var hex = false;
    if text.len >= 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X') {
        idx = 2;
        hex = true;
    }
    if idx >= text.len { return default_val; }
    var addr: u32 = 0;
    var saw = false;
    while idx < text.len {
        let c = text[idx];
        var nibble = -1;
        if c >= '0' && c <= '9' { nibble = (c - '0') as i32; }
        else if hex && c >= 'a' && c <= 'f' { nibble = (c - 'a' + 10) as i32; }
        else if hex && c >= 'A' && c <= 'F' { nibble = (c - 'A' + 10) as i32; }
        else { return default_val; }
        if hex { addr = (addr << 4) | (nibble as u32); }
        else { addr = addr * 10 + (nibble as u32); }
        saw = true;
        idx = idx + 1;
    }
    if !saw { return default_val; }
    return addr;
}

// 16進数フォーマットヘルパー (32bit)
fn hex_u32(val: u32, out: u8[>..]&) {
    let hex_chars = "0123456789abcdef";
    out.append("0x");
    for i in 8 {
        let shift = (7 - i) * 4;
        let nibble = ((val >> shift) & 0x0F) as i32;
        out.push(hex_chars[nibble]);
    }
}

// 16進数フォーマットヘルパー (16bit)
fn hex_u16(val: u16, out: u8[>..]&) {
    let hex_chars = "0123456789abcdef";
    out.append("0x");
    for i in 4 {
        let shift = (3 - i) * 4;
        let nibble = (((val as u32) >> shift) & 0x0F) as i32;
        out.push(hex_chars[nibble]);
    }
}

fn hex_nibble(c: u8) -> i32 {
    if c >= '0' && c <= '9' { return (c - '0') as i32; }
    if c >= 'a' && c <= 'f' { return (c - 'a' + 10) as i32; }
    if c >= 'A' && c <= 'F' { return (c - 'A' + 10) as i32; }
    return -1;
}

fn push_hex_byte(out: u8[>..]&, v: i32) {
    let hex = "0123456789abcdef";
    out.append("\"0x");
    out.push(hex[(v >> 4) & 15]);
    out.push(hex[v & 15]);
    out.push('"');
}

fn mcp_write_error_object(id: const u8[:], err: const u8[:], obj: const u8[:]) {
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
        let hi = c_mem_read_pal(off) as i32;
        let lo = c_mem_read_pal(off + 1) as i32;
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

// MCP リクエスト処理 (Goose ネイティブエミュレータ直結)
fn append_mnemonic(op: u16, out: u8[>..]&) {
    let hi = (op >> 12) & 0x0F;
    if hi == 0 { out.append("OP0"); }
    else if hi == 1 { out.append("MOVE.B"); }
    else if hi == 2 { out.append("MOVE.L"); }
    else if hi == 3 { out.append("MOVE.W"); }
    else if hi == 4 {
        if op == 0x4E71 { out.append("NOP"); }
        else if op == 0x4E73 { out.append("RTE"); }
        else if op == 0x4E75 { out.append("RTS"); }
        else if (op & 0xFFF0) == 0x4E40 { out.append("TRAP"); }
        else { out.append("MISC"); }
    }
    else if hi == 5 { out.append("ADDQ"); }
    else if hi == 6 { out.append("Bcc"); }
    else if hi == 7 { out.append("MOVEQ"); }
    else if hi == 8 { out.append("OR"); }
    else if hi == 9 { out.append("SUB"); }
    else if hi == 10 { out.append("LINEA"); }
    else if hi == 11 { out.append("CMP"); }
    else if hi == 12 { out.append("AND"); }
    else if hi == 13 { out.append("ADD"); }
    else if hi == 14 { out.append("SHIFT"); }
    else { out.append("LINEF"); }
}

fn json_append_quoted(out: u8[>..]&, text: const u8[:]) {
    let hex = "0123456789abcdef";
    out.push('"');
    for i in 0..text.len {
        let c = text[i];
        if c == '"' { out.append("\\\""); }
        else if c == '\\' { out.append("\\\\"); }
        else if c == 8 { out.append("\\b"); }
        else if c == 12 { out.append("\\f"); }
        else if c == 10 { out.append("\\n"); }
        else if c == 13 { out.append("\\r"); }
        else if c == 9 { out.append("\\t"); }
        else if c < 32 {
            out.append("\\u00");
            out.push(hex[((c >> 4) & 15) as i32]);
            out.push(hex[(c & 15) as i32]);
        } else {
            out.push(c);
        }
    }
    out.push('"');
}

fn mcp_format_text(id: const u8[:], text: const u8[:], is_error: bool, resp: u8[>..]&) {
    var quoted: u8[>..] = [];
    json_append_quoted(quoted, text);
    if is_error {
        format(resp, "{\"jsonrpc\":\"2.0\",\"id\":", id, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":", quoted, "}],\"isError\":true}}");
    } else {
        format(resp, "{\"jsonrpc\":\"2.0\",\"id\":", id, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":", quoted, "}]}}");
    }
}

fn mcp_write_text(id: const u8[:], text: const u8[:], is_error: bool) {
    var resp: u8[>..] = [];
    mcp_format_text(id, text, is_error, resp);
    c_io_write_line(resp[0], resp.len as i32);
}

fn mcp_write_object(id: const u8[:], obj: const u8[:]) {
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

fn mcp_set_layers(mask: i32) {
    g_mcp_layers = mask;
}

fn mcp_parse_layers(text: const u8[:]) -> i32 {
    if text.len == 0 { return MCP_LAYER_DEFAULT; }
    if text == "all" { return MCP_LAYER_ALL; }
    var layers: i32 = 0;
    var i = 0;
    while i < text.len {
        var token: u8[>..] = [];
        while i < text.len && text[i] != ',' {
            token.push(text[i]);
            i = i + 1;
        }
        var bit: i32 = 0;
        if token == "l0" { bit = MCP_LAYER_L0; }
        else if token == "l1" { bit = MCP_LAYER_L1; }
        else if token == "l2" { bit = MCP_LAYER_L2; }
        else if token == "l3" { bit = MCP_LAYER_L3; }
        else if token == "l4" { bit = MCP_LAYER_L4; }
        else { return -1; }
        if (layers & bit) != 0 { return -1; }
        layers = layers | bit;
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

fn mcp_layer_allows(name: const u8[:]) -> bool {
    let layer = tool_layer(name);
    if layer == 0 { return true; }
    return (g_mcp_layers & layer) != 0;
}

fn append_named_key(emu: X68kEmulator&, out: u8[>..]&, name: const u8[:], first: bool&) {
    let code = key_code(name);
    if code < 0 || code >= 128 { return; }
    if emu.session.keys[code] == 0 { return; }
    if !first { out.append(","); }
    out.append("\"");
    out.append(name);
    out.append("\"");
    first = false;
}

fn h3_frames_ok(frames: i32) -> bool {
    return frames >= 1 && frames <= 36000;
}

fn live_usp(cpu: M68kCPU&) -> u32 {
    if cpu_is_supervisor(cpu) { return cpu.usp; }
    return cpu.a[7];
}

fn live_ssp(cpu: M68kCPU&) -> u32 {
    if cpu_is_supervisor(cpu) { return cpu.a[7]; }
    return cpu.ssp;
}

fn tv_ink(x: i32, y: i32) -> bool {
    let row = y & 1023;
    let col_byte = (x & 1023) >> 3;
    let bit = 7 - (x & 7);
    let addr = ((row * 128 + col_byte) ^ 1) as i32;
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
        let shifted = (src >> 1) as u8;
        let want = if bold { (src | shifted) as u8 } else { src };
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
        code = code + 1;
    }
    return -1;
}

fn console_decode(emu: X68kEmulator&, text: u8[>..]&) -> i32 {
    var dot_x: i32 = 768;
    var dot_y: i32 = 512;
    let hstart = ((emu.mmu.crtc_regs[0x04] as i32) << 8) | (emu.mmu.crtc_regs[0x05] as i32);
    let hend = ((emu.mmu.crtc_regs[0x06] as i32) << 8) | (emu.mmu.crtc_regs[0x07] as i32);
    let vstart = ((emu.mmu.crtc_regs[0x0C] as i32) << 8) | (emu.mmu.crtc_regs[0x0D] as i32);
    let vend = ((emu.mmu.crtc_regs[0x0E] as i32) << 8) | (emu.mmu.crtc_regs[0x0F] as i32);
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
    let scroll_x = (((emu.mmu.crtc_regs[0x14] as i32) << 8) | (emu.mmu.crtc_regs[0x15] as i32)) & 1023;
    let scroll_y = (((emu.mmu.crtc_regs[0x16] as i32) << 8) | (emu.mmu.crtc_regs[0x17] as i32)) & 1023;
    for r in rows {
        let line_start = text.len;
        for c in cols {
            var glyph: u8[>..] = [];
            var blank = true;
            for gy in 16 {
                var byte: u8 = 0;
                for gx in 8 {
                    let tv_x = ((scroll_x + (c as i32) * 8 + (gx as i32)) & 1023) as i32;
                    let tv_y = ((scroll_y + (r as i32) * 16 + (gy as i32)) & 1023) as i32;
                    if tv_ink(tv_x, tv_y) { byte = byte | ((0x80 >> (gx as i32)) as u8); }
                }
                if byte != 0 { blank = false; }
                glyph.push(byte);
            }
            let code = match_ank(glyph);
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

fn command_line(emu: X68kEmulator&, out: u8[>..]&) {
    var full: u8[>..] = [];
    console_decode(emu, full);
    var n = 0;
    var i = 0;
    while i < full.len {
        if full[i] == 10 { n = n + 1; }
        i = i + 1;
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
            line = line + 1;
            start = i + 1;
        }
        if i == full.len { break; }
        i = i + 1;
    }
    if !found { return; }
    var k = 0;
    while k < best_len {
        out.push(full[best_start + k]);
        k = k + 1;
    }
}

fn mcp_control_call(emu: X68kEmulator&, tool_name: const u8[:], args: const u8[:], id_buf: const u8[:]) -> bool {
    if tool_name == "arcl_run" {
        let frames = extract_json_int(args, "frames", 1);
        if !h3_frames_ok(frames) {
            mcp_write_text(id_buf, "frames must be between 1 and 36000", true);
            return true;
        }
        let used = session_run(emu, frames);
        let reason = if emu.hit_break { "breakpoint" } else { "frames" };
        var obj: u8[>..] = [];
        obj.append("{\"stop_reason\":\"");
        obj.append(reason);
        obj.append("\"");
        append_machine(obj, emu, used, true, true);
        obj.append("}");
        mcp_write_object(id_buf, obj);
        return true;
    }

    if tool_name == "arcl_pause" {
        session_pause(emu, win32_ui_get_ticks_ms());
        var resp: u8[>..] = [];
        format(resp, "{\"jsonrpc\":\"2.0\",\"id\":", id_buf, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"status\\\":\\\"paused\\\"}\"}]}}");
        c_io_write_line(resp[0], resp.len as i32);
        return true;
    }

    if tool_name == "arcl_resume" {
        session_resume(emu, win32_ui_get_ticks_ms());
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
        mcp_write_object(id_buf, obj);
        return true;
    }

    if tool_name == "arcl_reset" {
        mcp_reset(emu);
        var obj: u8[>..] = [];
        obj.append("{");
        append_machine(obj, emu, 0, false, false);
        obj.append("}");
        mcp_write_object(id_buf, obj);
        return true;
    }

    if tool_name == "arcl_step" {
        let pc_before = emu.cpu.pc;
        x68k_emu_step(emu);
        var before_str: u8[>..] = []; hex_u32(pc_before, before_str);
        var after_str: u8[>..] = []; hex_u32(emu.cpu.pc, after_str);
        var sr_str: u8[>..] = []; hex_u16(emu.cpu.sr, sr_str);
        var obj: u8[>..] = [];
        format(obj, "{\"pc_before\":\"", before_str, "\",\"pc\":\"", after_str, "\",\"sr\":\"", sr_str, "\"");
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        mcp_write_object(id_buf, obj);
        return true;
    }

    return false;
}

fn mcp_input_call(emu: X68kEmulator&, tool_name: const u8[:], args: const u8[:], id_buf: const u8[:]) -> bool {
    if tool_name == "arcl_key" {
        var key_name: u8[>..] = [];
        if !extract_json_str(args, "key", key_name) {
            mcp_write_text(id_buf, "missing required string field 'key'", true);
            return true;
        }
        var act_buf: u8[>..] = [];
        if !extract_json_str(args, "action", act_buf) {
            mcp_write_text(id_buf, "missing required string field 'action' (press/release/tap)", true);
            return true;
        }
        let code = key_code(key_name);
        if code == -2 {
            mcp_write_text(id_buf, "this key is blocked from arcl_key: it triggers a core-internal side effect (F12 opens the built-in menu, ScrollLock toggles MIDI); see x68k_mcp.md 6.1", true);
            return true;
        }
        if code < 0 {
            mcp_write_text(id_buf, "unmapped key name; see x68k_mcp.md for the supported key set", true);
            return true;
        }
        if act_buf == "press" {
            input_key(emu, code, true);
        } else if act_buf == "release" {
            input_key(emu, code, false);
        } else if act_buf == "tap" {
            let frames = extract_json_int(args, "frames", 1);
            if frames < 1 || frames > 3600 {
                mcp_write_text(id_buf, "frames must be between 1 and 3600", true);
                return true;
            }
            session_key_tap(emu, code, frames);
            var obj: u8[>..] = [];
            format(obj, "{\"key\":\"", key_name, "\",\"action\":\"tap\"");
            append_machine(obj, emu, frames, true, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return true;
        } else {
            mcp_write_text(id_buf, "action must be press, release, or tap", true);
            return true;
        }
        var obj: u8[>..] = [];
        format(obj, "{\"key\":\"", key_name, "\",\"action\":\"", act_buf, "\"");
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        mcp_write_object(id_buf, obj);
        return true;
    }

    if tool_name == "arcl_type" {
        var text: u8[>..] = [];
        if !extract_json_str(args, "text", text) || text.len > 256 {
            mcp_write_text(id_buf, "missing required string field 'text'", true);
            return true;
        }
        let hold = extract_json_int(args, "frames", 2);
        if hold < 1 || hold > 3600 {
            mcp_write_text(id_buf, "frames must be between 1 and 3600", true);
            return true;
        }
        for i in text.len {
            var code: i32 = 0;
            var shift: i32 = 0;
            if !type_scancode(text[i], code, shift) {
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
                mcp_write_text(id_buf, msg, true);
                return true;
            }
        }
        var frames_used: i32 = 0;
        for i in text.len {
            frames_used += session_type_char(emu, text[i], hold);
        }
        var obj: u8[>..] = [];
        format(obj, "{\"chars_typed\":", text.len);
        append_machine(obj, emu, frames_used, true, true);
        obj.append("}");
        mcp_write_object(id_buf, obj);
        return true;
    }

    if tool_name == "arcl_clear_input" {
        release_held_keys(emu);
        var obj: u8[>..] = [];
        obj.append("{\"cleared\":true");
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        mcp_write_object(id_buf, obj);
        return true;
    }

    if tool_name == "arcl_input_state" {
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
            var joy = emu.mmu.joy1;
            if port == 1 { joy = emu.mmu.joy2; }
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
        mcp_write_object(id_buf, obj);
        return true;
    }

    if tool_name == "arcl_joypad" {
        var btn_buf: u8[>..] = [];
        if !extract_json_str(args, "button", btn_buf) {
            mcp_write_text(id_buf, "missing required string field 'button'", true);
            return true;
        }
        var act_buf: u8[>..] = [];
        if !extract_json_str(args, "action", act_buf) {
            mcp_write_text(id_buf, "missing required string field 'action' (press/release/tap)", true);
            return true;
        }
        let port = extract_json_int(args, "port", 0);
        if port != 0 && port != 1 {
            mcp_write_text(id_buf, "port must be 0 or 1", true);
            return true;
        }
        let mask = joy_mask(btn_buf);
        if mask == 0 {
            mcp_write_text(id_buf, "unmapped joypad button name; see x68k_mcp.md for the supported set", true);
            return true;
        }
        var frames_used: i32 = 0;
        if act_buf == "press" || act_buf == "release" || act_buf == "tap" {
            if act_buf == "tap" {
                let frames = extract_json_int(args, "frames", 1);
                if frames < 1 || frames > 3600 {
                    mcp_write_text(id_buf, "frames must be between 1 and 3600", true);
                    return true;
                }
                frames_used = frames;
            }
            let pressed = act_buf == "press" || act_buf == "tap";
            if act_buf == "tap" {
                session_joy_tap(emu, port, mask, frames_used);
            } else { input_joy(emu, port, mask, pressed); }
        } else {
            mcp_write_text(id_buf, "action must be press, release, or tap", true);
            return true;
        }
        var obj: u8[>..] = [];
        format(obj, "{\"port\":", port, ",\"button\":\"", btn_buf, "\",\"action\":\"", act_buf, "\"");
        append_machine(obj, emu, frames_used, act_buf == "tap", true);
        obj.append("}");
        mcp_write_object(id_buf, obj);
        return true;
    }

    if tool_name == "arcl_command" {
        var command: u8[>..] = [];
        if !extract_json_str(args, "command", command) || command.len > 180 {
            mcp_write_text(id_buf, "missing required string field 'command'", true);
            return true;
        }
        for i in command.len {
            var code: i32 = 0;
            var shift: i32 = 0;
            if !type_scancode(command[i], code, shift) {
                mcp_write_text(id_buf, "arcl_type failed while echoing the command", true);
                return true;
            }
        }
        var frames_used: i32 = 0;
        let hold: i32 = 2;
        for i in command.len {
            frames_used += session_type_char(emu, command[i], hold);
        }
        var after: u8[>..] = [];
        command_line(emu, after);
        var prompt: u8[>..] = [];
        var echoed = after.len >= command.len;
        if echoed {
            var j = 0;
            while j < command.len {
                if after[after.len - command.len + j] != command[j] { echoed = false; }
                j = j + 1;
            }
        }
        if echoed {
            var j2 = 0;
            while j2 < after.len - command.len {
                prompt.push(after[j2]);
                j2 = j2 + 1;
            }
        } else {
            var before: u8[>..] = [];
            command_line(emu, before);
            prompt.append(before);
        }
        frames_used += session_type_char(emu, '\n', 2);
        var matched = false;
        while frames_used < 6000 {
            for _ in 30 { mcp_run_frame(emu); }
            frames_used = frames_used + 30;
            var lineb: u8[>..] = [];
            command_line(emu, lineb);
            var pref = true;
            var p = 0;
            while p < prompt.len {
                if p >= lineb.len || lineb[p] != prompt[p] { pref = false; }
                p = p + 1;
            }
            if pref && lineb.len <= prompt.len + 1 {
                matched = true;
                break;
            }
        }
        if !matched {
            mcp_write_text(id_buf, "timed out waiting for the prompt to return (6000 frames)", true);
            return true;
        }
        var obj: u8[>..] = [];
        obj.append("{\"action\":\"command\"");
        append_machine(obj, emu, frames_used, true, true);
        obj.append("}");
        mcp_write_object(id_buf, obj);
        return true;
    }

    if tool_name == "arcl_input_macro" {
        let at = json_key_value(args, 0, "steps");
        if at < 0 {
            mcp_write_text(id_buf, "missing required array field 'steps'", true);
            return true;
        }
        if at >= args.len || args[at] != '[' {
            mcp_write_text(id_buf, "'steps' must be an array", true);
            return true;
        }
        var cursor = at + 1;
        var completed: i32 = 0;
        var frames_used: i32 = 0;
        var err: u8[>..] = [];
        var results: u8[>..] = [];
        results.append("{\"results\":[");
        while cursor < args.len {
            while cursor < args.len && (args[cursor] == ' ' || args[cursor] == ',' || args[cursor] == '\n' || args[cursor] == '\t' || args[cursor] == '\r') { cursor = cursor + 1; }
            if cursor >= args.len || args[cursor] == ']' { break; }
            if args[cursor] != '{' {
                mcp_write_text(id_buf, "each step must be a JSON object", true);
                return true;
            }
            if completed >= 16 {
                mcp_write_text(id_buf, "too many steps; max is 16 per arcl_input_macro call", true);
                return true;
            }
            var depth = 0;
            var end = cursor;
            var in_str = false;
            while end < args.len {
                let c = args[end];
                if in_str {
                    if c == '\\' && end + 1 < args.len { end = end + 2; continue; }
                    if c == '"' { in_str = false; }
                    end = end + 1;
                    continue;
                }
                if c == '"' { in_str = true; end = end + 1; continue; }
                if c == '{' { depth = depth + 1; }
                else if c == '}' {
                    depth = depth - 1;
                    if depth == 0 { end = end + 1; break; }
                }
                end = end + 1;
            }
            var step: u8[>..] = [];
            var k = cursor;
            while k < end { step.push(args[k]); k = k + 1; }
            var op: u8[>..] = [];
            if !extract_json_str(step, "op", op) {
                mcp_write_text(id_buf, "each step needs a string 'op' field", true);
                return true;
            }
            var step_ok = true;
            if op == "clear_input" {
                release_held_keys(emu);
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
                    let code = key_code(key_name);
                    if code < 0 {
                        step_ok = false;
                        err.append("unmapped key name; see x68k_mcp.md for the supported key set");
                    } else if act_buf == "press" {
                        input_key(emu, code, true);
                    } else if act_buf == "release" {
                        input_key(emu, code, false);
                    } else if act_buf == "tap" {
                        let frames = extract_json_int(step, "frames", 1);
                        if frames < 1 || frames > 3600 || frames_used + frames > 10000 {
                            step_ok = false;
                            err.append("frames must be between 1 and 3600");
                        } else {
                            session_key_tap(emu, code, frames);
                            frames_used = frames_used + frames;
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
                            var code: i32 = 0;
                            var shift: i32 = 0;
                            if !type_scancode(text[i], code, shift) {
                                step_ok = false;
                                err.append("arcl_type failed while echoing the command");
                            }
                        }
                        if step_ok {
                            for i in text.len {
                                frames_used += session_type_char(emu, text[i], hold);
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
                    let mask = joy_mask(btn);
                    let port = extract_json_int(step, "port", 0);
                    if mask == 0 || (port != 0 && port != 1) {
                        step_ok = false;
                        err.append("unmapped joypad button name; see x68k_mcp.md for the supported set");
                    } else if act_buf == "press" || act_buf == "release" || act_buf == "tap" {
                        let pressed = act_buf == "press" || act_buf == "tap";
                        input_joy(emu, port, mask, pressed);
                        if act_buf == "tap" {
                            let frames = extract_json_int(step, "frames", 1);
                            if frames < 1 || frames > 3600 || frames_used + frames > 10000 {
                                step_ok = false;
                                err.append("frames must be between 1 and 3600");
                            } else {
                                session_joy_tap(emu, port, mask, frames);
                                frames_used = frames_used + frames;
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
                } else if json_key_value(step, 0, "inline") >= 0 {
                    step_ok = false;
                    err.append("inline PNG is not available in this build");
                } else if extract_json_int(step, "scale", 1) != 1 || extract_json_int(step, "grid", 0) != 0 {
                    step_ok = false;
                    err.append("scaled or cropped PNG output is not available in this build");
                } else {
                    var path_buf: u8[>..] = [];
                    if !extract_json_str(step, "path", path_buf) { path_buf.append("x68k_screenshot.bmp"); }
                    var path_null: u8[>..] = [];
                    path_null.append(path_buf);
                    path_null.push(0);
                    if c_save_fb_bmp(path_null[0], path_null.len as i32) == 0 {
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
                    for _ in frames { mcp_run_frame(emu); }
                    frames_used = frames_used + frames;
                }
            } else {
                step_ok = false;
                err.append("unknown macro step op");
            }
            if completed != 0 { results.append(","); }
            let ok_txt = if step_ok { "true" } else { "false" };
            format(results, "{\"op\":\"", op, "\",\"ok\":", ok_txt, "}");
            completed = completed + 1;
            cursor = end;
            if !step_ok { break; }
        }
        format(results, "],\"steps_completed\":", completed, ",\"steps_ok\":", if err.len == 0 { "true" } else { "false" });
        append_machine(results, emu, 0, false, true);
        results.append("}");
        if err.len != 0 {
            mcp_write_error_object(id_buf, err, results);
            return true;
        }
        mcp_write_object(id_buf, results);
        return true;
    }

    return false;
}

fn mcp_checkpoint_call(emu: X68kEmulator&, tool_name: const u8[:], args: const u8[:], id_buf: const u8[:]) -> bool {
    if tool_name == "arcl_save_state" {
        let slot = extract_json_int(args, "slot", 0);
        if slot < 0 || slot > 9 {
            mcp_write_text(id_buf, "slot must be between 0 and 9", true);
            return true;
        }
        if !session_save(emu, slot) {
            mcp_write_text(id_buf, "failed to allocate save-state buffer", true);
            return true;
        }
        var obj: u8[>..] = [];
        format(obj, "{\"slot\":", slot);
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        mcp_write_object(id_buf, obj);
        return true;
    }

    if tool_name == "arcl_load_state" {
        let slot = extract_json_int(args, "slot", 0);
        if slot < 0 || slot > 9 {
            mcp_write_text(id_buf, "slot must be between 0 and 9", true);
            return true;
        }
        if !session_load(emu, slot) {
            mcp_write_text(id_buf, "save-state slot is empty or incompatible", true);
            return true;
        }
        var obj: u8[>..] = [];
        format(obj, "{\"slot\":", slot);
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        mcp_write_object(id_buf, obj);
        return true;
    }

    if tool_name == "arcl_rewind" {
        var act: u8[>..] = [];
        if !extract_json_str(args, "action", act) {
            mcp_write_text(id_buf, "missing required string field 'action' (enable/disable/status/rewind)", true);
            return true;
        }
        if act == "enable" {
            let interval = extract_json_int(args, "interval", 60);
            if interval < 10 || interval > 36000 {
                mcp_write_text(id_buf, "interval must be between 10 and 36000", true);
                return true;
            }
            rewind_enable(emu, interval);
            var obj: u8[>..] = [];
            format(obj, "{\"action\":\"enable\",\"interval\":", interval, ",\"depth\":8");
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return true;
        }
        if act == "disable" {
            rewind_disable(emu);
            var obj: u8[>..] = [];
            obj.append("{\"action\":\"disable\"");
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return true;
        }
        if act == "status" {
            let on = if emu.session.rewind_on { "true" } else { "false" };
            var obj: u8[>..] = [];
            format(obj, "{\"action\":\"status\",\"enabled\":", on, ",\"interval\":", emu.session.rewind_interval, ",\"depth\":8,\"entries\":", emu.session.rewind_count, ",\"total_bytes\":", state_total(STATE_REWIND));
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return true;
        }
        if act == "rewind" {
            let steps = extract_json_int(args, "steps", 1);
            if steps < 1 || steps > emu.session.rewind_count {
                mcp_write_text(id_buf, "not enough rewind history for that many steps", true);
                return true;
            }
            if !rewind_restore(emu, steps) {
                mcp_write_text(id_buf, "core failed to restore rewind snapshot", true);
                return true;
            }
            var obj: u8[>..] = [];
            format(obj, "{\"action\":\"rewind\",\"steps\":", steps);
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return true;
        }
        mcp_write_text(id_buf, "action must be enable, disable, status, or rewind", true);
        return true;
    }

    if tool_name == "arcl_speed" {
        let nom = if (emu.mmu.crtc_regs[0x29] & 0x10) != 0 { 55 } else { 61 };
        var fps: i32 = 0;
        var pct: i32 = 0;
        var running = false;
        session_speed(emu, win32_ui_get_ticks_ms(), fps, pct, running);
        let run = if running { "true" } else { "false" };
        var obj: u8[>..] = [];
        format(obj, "{\"running\":", run, ",\"fps\":", fps, ",\"nominal_fps\":", nom, ",\"speed_percent\":", pct);
        append_machine(obj, emu, 0, false, true);
        obj.append("}");
        mcp_write_object(id_buf, obj);
        return true;
    }

    if tool_name == "arcl_snapshot" {
        var act: u8[>..] = [];
        if !extract_json_str(args, "action", act) {
            mcp_write_text(id_buf, "missing required string field 'action' (create/restore/delete/list)", true);
            return true;
        }
        if act == "list" {
            var obj: u8[>..] = [];
            obj.append("{\"action\":\"list\",\"snapshots\":[");
            var first = true;
            var i: i32 = 0;
            while i < 32 {
                if state_saved(STATE_SNAPSHOT, i) {
                    if !first { obj.append(","); }
                    first = false;
                    var name: u8[>..] = [];
                    snapshot_name(emu, i, name);
                    var quoted: u8[>..] = [];
                    json_append_quoted(quoted, name);
                    format(obj, "{\"name\":", quoted, ",\"frame\":", state_frame(STATE_SNAPSHOT, i), ",\"bytes\":", state_bytes(STATE_SNAPSHOT, i), "}");
                }
                i = i + 1;
            }
            format(obj, "],\"total_bytes\":", state_total(STATE_SNAPSHOT));
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return true;
        }
        var name: u8[>..] = [];
        if !extract_json_str(args, "snapshot_name", name) || name.len == 0 || name.len > 63 {
            mcp_write_text(id_buf, "missing required string field 'snapshot_name'", true);
            return true;
        }
        if act == "create" {
            let idx = snapshot_create(emu, name);
            if idx == SNAPSHOT_FULL {
                mcp_write_text(id_buf, "snapshot table is full (max 32) - delete one first", true);
                return true;
            }
            if idx < 0 {
                mcp_write_text(id_buf, "failed to allocate snapshot buffer", true);
                return true;
            }
            var quoted: u8[>..] = [];
            json_append_quoted(quoted, name);
            var obj: u8[>..] = [];
            format(obj, "{\"action\":\"create\",\"name\":", quoted, ",\"bytes\":", state_bytes(STATE_SNAPSHOT, idx), ",\"total_bytes\":", state_total(STATE_SNAPSHOT));
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return true;
        }
        let idx = snapshot_find(emu, name);
        if idx < 0 {
            mcp_write_text(id_buf, "no snapshot with that name", true);
            return true;
        }
        if act == "restore" {
            if !snapshot_restore(emu, name) {
                mcp_write_text(id_buf, "core failed to restore state (incompatible snapshot?)", true);
                return true;
            }
            var quoted: u8[>..] = [];
            json_append_quoted(quoted, name);
            var obj: u8[>..] = [];
            format(obj, "{\"action\":\"restore\",\"name\":", quoted);
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return true;
        }
        if act == "delete" {
            snapshot_delete(emu, name);
            var quoted: u8[>..] = [];
            json_append_quoted(quoted, name);
            var obj: u8[>..] = [];
            format(obj, "{\"action\":\"delete\",\"name\":", quoted, ",\"total_bytes\":", state_total(STATE_SNAPSHOT));
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return true;
        }
        mcp_write_text(id_buf, "action must be create, restore, delete, or list", true);
        return true;
    }

    return false;
}

fn mcp_dispatch(emu: X68kEmulator&, line: const u8[:], is_running: bool&) {
    if line.len == 0 { return; }

    var id_buf: u8[>..] = [];
    let has_id = json_top_id(line, id_buf);

    var method: u8[>..] = [];
    json_top_string(line, "method", method);

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
        var resp: u8[>..] = [];
        format(resp, "{\"jsonrpc\":\"2.0\",\"id\":", id_buf, ",\"result\":{\"tools\":[",
            "{\"name\":\"arcl_run\",\"description\":\"Advance emulation by specified frames\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"frames\":{\"type\":\"integer\"}}}},",
            "{\"name\":\"arcl_pause\",\"description\":\"Pause continuous emulation\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},",
            "{\"name\":\"arcl_resume\",\"description\":\"Resume continuous emulation\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},",
            "{\"name\":\"arcl_status\",\"description\":\"Read machine status\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},",
            "{\"name\":\"arcl_reset\",\"description\":\"Reset the X68000 CPU and MMU\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},",
            "{\"name\":\"arcl_save_state\",\"description\":\"Save emulator state in slot\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"slot\":{\"type\":\"integer\"}}}},",
            "{\"name\":\"arcl_load_state\",\"description\":\"Restore emulator state from slot\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"slot\":{\"type\":\"integer\"}}}}");
        if (g_mcp_layers & MCP_LAYER_L0) != 0 {
            resp.append(",{\"name\":\"arcl_screenshot\",\"description\":\"Capture framebuffer screenshot\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}}");
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
            resp.append(",{\"name\":\"arcl_disasm\",\"description\":\"Disassemble one instruction\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"address\":{\"type\":\"string\"}}}}");
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
        return;
    }

    // 4. tools/call
    if method == "tools/call" {
        var args: u8[>..] = [];
        if !json_extract_object(line, "arguments", args) {
            args.append("{}");
        }
        var tool_name: u8[>..] = [];
        json_any_string(line, "name", tool_name);
        if tool_name.len > 0 && !mcp_layer_allows(tool_name) {
            mcp_write_text(id_buf, "this tool's layer was not enabled via --mcp-layers for this session (see tools/list for what's available)", true);
            return;
        }

        if mcp_control_call(emu, tool_name, args, id_buf) { return; }
        if mcp_input_call(emu, tool_name, args, id_buf) { return; }
        if mcp_checkpoint_call(emu, tool_name, args, id_buf) { return; }

        if tool_name == "arcl_screenshot" {
            if c_frame_ready() == 0 {
                mcp_write_text(id_buf, "no frame available yet; call arcl_run first", true);
                return;
            }
            let have_x = json_key_value(args, 0, "x") >= 0;
            let have_y = json_key_value(args, 0, "y") >= 0;
            let have_w = json_key_value(args, 0, "w") >= 0;
            let have_h = json_key_value(args, 0, "h") >= 0;
            if (have_x || have_y || have_w || have_h) && !(have_x && have_y && have_w && have_h) {
                mcp_write_text(id_buf, "specify all of x,y,w,h together, or none for the full frame", true);
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
                mcp_write_text(id_buf, "crop rectangle out of bounds of the current frame", true);
                return;
            }
            let scale = extract_json_int(args, "scale", 1);
            if scale < 1 || scale > 16 {
                mcp_write_text(id_buf, "scale must be between 1 and 16", true);
                return;
            }
            let grid = extract_json_int(args, "grid", 0);
            if grid > 0 && scale < 2 {
                mcp_write_text(id_buf, "grid requires scale >= 2", true);
                return;
            }
            if (w * scale) * (h * scale) > 480000 {
                mcp_write_text(id_buf, "scaled output too large; crop with x/y/w/h or reduce scale", true);
                return;
            }
            if json_key_value(args, 0, "inline") >= 0 {
                mcp_write_text(id_buf, "inline PNG is not available in this build", true);
                return;
            }
            if scale != 1 || grid != 0 || x != 0 || y != 0 || w != sw || h != sh {
                mcp_write_text(id_buf, "scaled or cropped PNG output is not available in this build", true);
                return;
            }
            var path_buf: u8[>..] = [];
            if !extract_json_str(args, "path", path_buf) {
                path_buf.append("x68k_screenshot.bmp");
            }
            var path_null: u8[>..] = [];
            path_null.append(path_buf);
            path_null.push('\0');
            if c_save_fb_bmp(path_null[0], path_null.len as i32) == 0 {
                mcp_write_text(id_buf, "failed to write screenshot", true);
                return;
            }
            var msg: u8[>..] = [];
            msg.append("Screenshot saved to ");
            msg.append(path_buf);
            mcp_write_text(id_buf, msg, false);
            return;
        }

        if tool_name == "arcl_registers" {
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
            mcp_write_object(id_buf, obj);
            return;
        }

        if tool_name == "arcl_console_read" {
            var txt: u8[>..] = [];
            console_decode(emu, txt);
            var obj: u8[>..] = [];
            var quoted: u8[>..] = [];
            json_append_quoted(quoted, txt);
            format(obj, "{\"cols\":", g_console_cols, ",\"rows\":", g_console_rows, ",\"text\":", quoted);
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return;
        }

        if tool_name == "arcl_read_mem" {
            let addr = extract_json_addr(args, "address", 0);
            let len = extract_json_int(args, "length", 16);
            let read_len = if len <= 0 { 1 } else if len > 65536 { 65536 } else { len };
            let hex_chars = "0123456789abcdef";
            var data_hex: u8[>..] = [];
            for i in read_len {
                let b = mmu_read8(emu.mmu, addr + (i as u32));
                data_hex.push(hex_chars[((b >> 4) & 0x0F) as i32]);
                data_hex.push(hex_chars[(b & 0x0F) as i32]);
            }
            var addr_hex: u8[>..] = [];
            hex_u32(addr, addr_hex);
            var body: u8[>..] = [];
            format(body, "{\"address\":\"", addr_hex, "\",\"length\":", read_len, ",\"data\":\"", data_hex, "\"}");
            mcp_write_text(id_buf, body, false);
            return;
        }

        if tool_name == "arcl_mount" {
            var act_buf: u8[>..] = [];
            if !extract_json_str(args, "action", act_buf) {
                mcp_write_text(id_buf, "missing required string field 'action' (insert/eject)", true);
                return;
            }
            if act_buf == "insert" {
                var path_buf: u8[>..] = [];
                if !extract_json_str(args, "path", path_buf) {
                    mcp_write_text(id_buf, "insert requires a string field 'path'", true);
                    return;
                }
                var path_null: u8[>..] = [];
                path_null.append(path_buf);
                path_null.push('\0');
                if c_fdd_load_file(1, path_null[0], path_null.len as i32) == 0 {
                    mcp_write_text(id_buf, "the core rejected the disk image (bad path or unsupported format)", true);
                    return;
                }
                var quoted: u8[>..] = [];
                json_append_quoted(quoted, path_buf);
                var obj: u8[>..] = [];
                format(obj, "{\"action\":\"insert\",\"path\":", quoted);
                append_machine(obj, emu, 0, false, true);
                obj.append("}");
                mcp_write_object(id_buf, obj);
                return;
            }
            if act_buf == "eject" {
                c_fdd_eject(1);
                var obj: u8[>..] = [];
                obj.append("{\"action\":\"eject\"");
                append_machine(obj, emu, 0, false, true);
                obj.append("}");
                mcp_write_object(id_buf, obj);
                return;
            }
            mcp_write_text(id_buf, "action must be insert or eject", true);
            return;
        }

        if tool_name == "arcl_disasm" {
            var addr = emu.cpu.pc & 0x00FFFFFF;
            if json_key_value(args, 0, "address") >= 0 {
                addr = extract_json_addr(args, "address", addr);
            }
            let op = mmu_read16(emu.mmu, addr);
            var addr_str: u8[>..] = []; hex_u32(addr, addr_str);
            var op_str: u8[>..] = []; hex_u16(op, op_str);
            var text: u8[>..] = [];
            append_mnemonic(op, text);
            var obj: u8[>..] = [];
            format(obj, "{\"address\":\"", addr_str, "\",\"opcode\":\"", op_str, "\",\"text\":\"", text, "\"");
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return;
        }

        if tool_name == "arcl_breakpoint" {
            var action: u8[>..] = [];
            extract_json_str(args, "action", action);
            if action == "clear" {
                emu.break_armed = false;
                emu.hit_break = false;
            } else {
                let addr = extract_json_addr(args, "address", emu.cpu.pc & 0x00FFFFFF);
                emu.break_pc = addr & 0x00FFFFFF;
                emu.break_armed = true;
                emu.hit_break = false;
            }
            var pc_str: u8[>..] = []; hex_u32(emu.break_pc, pc_str);
            let armed = if emu.break_armed { "true" } else { "false" };
            var obj: u8[>..] = [];
            format(obj, "{\"armed\":", armed, ",\"address\":\"", pc_str, "\"");
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return;
        }

        if tool_name == "arcl_write_mem" {
            if json_key_value(args, 0, "address") < 0 {
                mcp_write_text(id_buf, "missing required field 'address' (integer or hex string)", true);
                return;
            }
            let addr = extract_json_addr(args, "address", 0);
            var hexdata: u8[>..] = [];
            if !extract_json_str(args, "data", hexdata) {
                mcp_write_text(id_buf, "missing required string field 'data' (hex bytes, e.g. \"deadbeef\")", true);
                return;
            }
            if hexdata.len == 0 || (hexdata.len % 2) != 0 || hexdata.len > 16384 {
                mcp_write_text(id_buf, "'data' must be a non-empty even-length hex string", true);
                return;
            }
            var nbytes: i32 = 0;
            var ok = true;
            while nbytes * 2 < hexdata.len {
                let hi = hex_nibble(hexdata[nbytes * 2]);
                let lo = hex_nibble(hexdata[nbytes * 2 + 1]);
                if hi < 0 || lo < 0 { ok = false; }
                nbytes = nbytes + 1;
            }
            if !ok {
                mcp_write_text(id_buf, "'data' contains a non-hex-digit character", true);
                return;
            }
            var i: i32 = 0;
            while i < nbytes {
                let hi = hex_nibble(hexdata[i * 2]);
                let lo = hex_nibble(hexdata[i * 2 + 1]);
                mmu_write8(emu.mmu, addr + (i as u32), ((hi << 4) | lo) as u8);
                i = i + 1;
            }
            var addr_hex: u8[>..] = [];
            hex_u32(addr, addr_hex);
            var obj: u8[>..] = [];
            format(obj, "{\"address\":\"", addr_hex, "\",\"length\":", nbytes);
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return;
        }

        if tool_name == "arcl_write_registers" {
            var wrote = false;
            if json_key_value(args, 0, "pc") >= 0 { emu.cpu.pc = extract_json_addr(args, "pc", emu.cpu.pc); wrote = true; }
            if json_key_value(args, 0, "sr") >= 0 { emu.cpu.sr = extract_json_addr(args, "sr", emu.cpu.sr as u32) as u16; wrote = true; }
            if json_key_value(args, 0, "usp") >= 0 { emu.cpu.usp = extract_json_addr(args, "usp", emu.cpu.usp); wrote = true; }
            if json_key_value(args, 0, "a7") >= 0 { emu.cpu.a[7] = extract_json_addr(args, "a7", emu.cpu.a[7]); wrote = true; }
            if json_key_value(args, 0, "sp") >= 0 { wrote = true; }
            if json_key_value(args, 0, "isp") >= 0 { wrote = true; }
            if json_key_value(args, 0, "msp") >= 0 { wrote = true; }
            if json_key_value(args, 0, "vbr") >= 0 { wrote = true; }
            if json_key_value(args, 0, "sfc") >= 0 { wrote = true; }
            if json_key_value(args, 0, "dfc") >= 0 { wrote = true; }
            if json_key_value(args, 0, "cacr") >= 0 { wrote = true; }
            if json_key_value(args, 0, "caar") >= 0 { wrote = true; }
            if json_key_value(args, 0, "pref_addr") >= 0 { wrote = true; }
            if json_key_value(args, 0, "pref_data") >= 0 { wrote = true; }
            if json_key_value(args, 0, "d0") >= 0 { emu.cpu.d[0] = extract_json_addr(args, "d0", emu.cpu.d[0]); wrote = true; }
            if json_key_value(args, 0, "d1") >= 0 { emu.cpu.d[1] = extract_json_addr(args, "d1", emu.cpu.d[1]); wrote = true; }
            if json_key_value(args, 0, "d2") >= 0 { emu.cpu.d[2] = extract_json_addr(args, "d2", emu.cpu.d[2]); wrote = true; }
            if json_key_value(args, 0, "d3") >= 0 { emu.cpu.d[3] = extract_json_addr(args, "d3", emu.cpu.d[3]); wrote = true; }
            if json_key_value(args, 0, "d4") >= 0 { emu.cpu.d[4] = extract_json_addr(args, "d4", emu.cpu.d[4]); wrote = true; }
            if json_key_value(args, 0, "d5") >= 0 { emu.cpu.d[5] = extract_json_addr(args, "d5", emu.cpu.d[5]); wrote = true; }
            if json_key_value(args, 0, "d6") >= 0 { emu.cpu.d[6] = extract_json_addr(args, "d6", emu.cpu.d[6]); wrote = true; }
            if json_key_value(args, 0, "d7") >= 0 { emu.cpu.d[7] = extract_json_addr(args, "d7", emu.cpu.d[7]); wrote = true; }
            if json_key_value(args, 0, "a0") >= 0 { emu.cpu.a[0] = extract_json_addr(args, "a0", emu.cpu.a[0]); wrote = true; }
            if json_key_value(args, 0, "a1") >= 0 { emu.cpu.a[1] = extract_json_addr(args, "a1", emu.cpu.a[1]); wrote = true; }
            if json_key_value(args, 0, "a2") >= 0 { emu.cpu.a[2] = extract_json_addr(args, "a2", emu.cpu.a[2]); wrote = true; }
            if json_key_value(args, 0, "a3") >= 0 { emu.cpu.a[3] = extract_json_addr(args, "a3", emu.cpu.a[3]); wrote = true; }
            if json_key_value(args, 0, "a4") >= 0 { emu.cpu.a[4] = extract_json_addr(args, "a4", emu.cpu.a[4]); wrote = true; }
            if json_key_value(args, 0, "a5") >= 0 { emu.cpu.a[5] = extract_json_addr(args, "a5", emu.cpu.a[5]); wrote = true; }
            if json_key_value(args, 0, "a6") >= 0 { emu.cpu.a[6] = extract_json_addr(args, "a6", emu.cpu.a[6]); wrote = true; }
            if !wrote {
                mcp_write_text(id_buf, "no recognized register fields in request (e.g. \"pc\", \"d0\", \"a7\")", true);
                return;
            }
            var obj: u8[>..] = [];
            obj.append("{\"wrote\":true");
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return;
        }

        if tool_name == "arcl_stack" {
            let count = extract_json_int(args, "count", 16);
            if count < 1 || count > 256 {
                mcp_write_text(id_buf, "count must be between 1 and 256", true);
                return;
            }
            let sp = emu.cpu.a[7];
            var sp_hex: u8[>..] = [];
            hex_u32(sp, sp_hex);
            var obj: u8[>..] = [];
            format(obj, "{\"sp\":\"", sp_hex, "\",\"words\":[");
            for i in count {
                let a = sp + ((i as u32) * 4);
                let v = mmu_read32(emu.mmu, a);
                if i != 0 { obj.append(","); }
                var ah: u8[>..] = []; hex_u32(a, ah);
                var vh: u8[>..] = []; hex_u32(v, vh);
                format(obj, "{\"address\":\"", ah, "\",\"value\":\"", vh, "\"}");
            }
            obj.append("]");
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return;
        }

        if tool_name == "arcl_host_dir" {
            var path_buf: u8[>..] = [];
            if !extract_json_str(args, "path", path_buf) {
                mcp_write_text(id_buf, "missing required string field 'path'", true);
                return;
            }
            var bad = false;
            var pi = 0;
            while pi + 1 < path_buf.len {
                if path_buf[pi] == '.' && path_buf[pi + 1] == '.' { bad = true; }
                pi = pi + 1;
            }
            if bad {
                mcp_write_text(id_buf, "path must not contain '..'", true);
                return;
            }
            var path_z: u8[>..] = [];
            path_z.append(path_buf);
            path_z.push(0);
            var listed: u8[8192] = [0; 8192];
            if c_host_list_dir(path_z[0], path_z.len as i32, listed[0], 8192) != 1 {
                mcp_write_text(id_buf, "failed to open directory (does it exist?)", true);
                return;
            }
            var body: u8[>..] = [];
            var li = 0;
            while li < 8192 && listed[li] != 0 {
                body.push(listed[li]);
                li = li + 1;
            }
            var quoted: u8[>..] = [];
            json_append_quoted(quoted, path_buf);
            var obj: u8[>..] = [];
            format(obj, "{\"entries\":", body, ",\"path\":", quoted);
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return;
        }

        if tool_name == "arcl_audio_record" {
            var act: u8[>..] = [];
            if !extract_json_str(args, "action", act) {
                mcp_write_text(id_buf, "missing required string field 'action' (start/stop/status)", true);
                return;
            }
            if act == "start" {
                c_audio_capture_start();
                var obj: u8[>..] = [];
                obj.append("{\"action\":\"start\",\"sample_rate\":44100,\"cap_seconds\":60");
                append_machine(obj, emu, 0, false, true);
                obj.append("}");
                mcp_write_object(id_buf, obj);
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
                mcp_write_object(id_buf, obj);
                return;
            }
            if act == "stop" {
                var path_buf: u8[>..] = [];
                var z: u8[512] = [0; 512];
                if extract_json_str(args, "path", path_buf) && path_buf.len > 0 {
                    if path_buf.len >= 511 {
                        mcp_write_text(id_buf, "failed to write WAV to path", true);
                        return;
                    }
                    var pi = 0;
                    while pi < path_buf.len {
                        z[pi] = path_buf[pi];
                        pi = pi + 1;
                    }
                }
                var frames: i32 = 0;
                var trunc: i32 = 0;
                var peak: i32 = 0;
                var silent: i32 = 0;
                if c_audio_capture_stop(z[0], z.len as i32, frames, trunc, peak, silent) == 0 {
                    mcp_write_text(id_buf, "failed to write WAV to path", true);
                    return;
                }
                let tr = if trunc != 0 { "true" } else { "false" };
                let sil = if silent != 0 { "true" } else { "false" };
                var obj: u8[>..] = [];
                format(obj, "{\"action\":\"stop\",\"frames\":", frames, ",\"truncated\":", tr, ",\"peak\":", peak, ",\"silent\":", sil);
                append_machine(obj, emu, 0, false, true);
                obj.append("}");
                mcp_write_object(id_buf, obj);
                return;
            }
            mcp_write_text(id_buf, "action must be start, stop, or status", true);
            return;
        }

        if tool_name == "arcl_video" {
            let hstart = ((emu.mmu.crtc_regs[0x04] as i32) << 8) | (emu.mmu.crtc_regs[0x05] as i32);
            let hend = ((emu.mmu.crtc_regs[0x06] as i32) << 8) | (emu.mmu.crtc_regs[0x07] as i32);
            let vstart = ((emu.mmu.crtc_regs[0x0C] as i32) << 8) | (emu.mmu.crtc_regs[0x0D] as i32);
            let vend = ((emu.mmu.crtc_regs[0x0E] as i32) << 8) | (emu.mmu.crtc_regs[0x0F] as i32);
            var dot_x = 768;
            var dot_y = 512;
            if hend > hstart { dot_x = (hend - hstart) * 8; }
            if vend > vstart { dot_y = vend - vstart; }
            let sx = (((emu.mmu.crtc_regs[0x14] as i32) << 8) | (emu.mmu.crtc_regs[0x15] as i32)) & 1023;
            let sy = (((emu.mmu.crtc_regs[0x16] as i32) << 8) | (emu.mmu.crtc_regs[0x17] as i32)) & 1023;
            var obj: u8[>..] = [];
            format(obj, "{\"text\":{\"dot_x\":", dot_x, ",\"dot_y\":", dot_y, ",\"scroll_x\":", sx, ",\"scroll_y\":", sy, "},\"graphic\":{\"scroll\":[");
            let xhi: i32[4] = [0x18, 0x1c, 0x20, 0x24];
            let yhi: i32[4] = [0x1a, 0x1e, 0x22, 0x26];
            for page in 4 {
                if page != 0 { obj.append(","); }
                let gx = ((emu.mmu.crtc_regs[xhi[page]] as i32) << 8) | (emu.mmu.crtc_regs[xhi[page] + 1] as i32);
                let gy = ((emu.mmu.crtc_regs[yhi[page]] as i32) << 8) | (emu.mmu.crtc_regs[yhi[page] + 1] as i32);
                format(obj, "{\"page\":", page, ",\"x\":", gx, ",\"y\":", gy, "}");
            }
            obj.append("]},\"crtc\":{\"vstart\":");
            format(obj, vstart, ",\"vend\":", vend, ",\"hstart\":", hstart, ",\"hend\":", hend);
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return;
        }

        if tool_name == "arcl_vram" {
            var region: u8[>..] = [];
            if !extract_json_str(args, "region", region) {
                mcp_write_text(id_buf, "missing required string field 'region' (gvram/tvram)", true);
                return;
            }
            var gv = false;
            if region == "gvram" { gv = true; }
            else if region != "tvram" {
                mcp_write_text(id_buf, "region must be gvram or tvram", true);
                return;
            }
            let address = extract_json_addr(args, "address", 0);
            let length = extract_json_int(args, "length", 256);
            if length < 1 || length > 65536 {
                mcp_write_text(id_buf, "length must be between 1 and 65536", true);
                return;
            }
            if address >= 0x80000 || (address + (length as u32)) > 0x80000 {
                mcp_write_text(id_buf, "address/length out of range for this region (0x80000 bytes each)", true);
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
            mcp_write_object(id_buf, obj);
            return;
        }

        if tool_name == "arcl_irq" {
            let crtc_line = (((emu.mmu.crtc_regs[0x12] as i32) << 8) | (emu.mmu.crtc_regs[0x13] as i32)) & 1023;
            var obj: u8[>..] = [];
            obj.append("{\"mfp\":{\"gpip\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_GPIP] as i32);
            obj.append(",\"aer\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_AER] as i32);
            obj.append(",\"ddr\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_DDR] as i32);
            obj.append(",\"iera\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_IERA] as i32);
            obj.append(",\"ierb\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_IERB] as i32);
            obj.append(",\"ipra\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_IPRA] as i32);
            obj.append(",\"iprb\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_IPRB] as i32);
            obj.append(",\"isra\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_ISRA] as i32);
            obj.append(",\"isrb\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_ISRB] as i32);
            obj.append(",\"imra\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_IMRA] as i32);
            obj.append(",\"imrb\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_IMRB] as i32);
            obj.append(",\"vr\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_VR] as i32);
            obj.append(",\"tacr\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_TACR] as i32);
            obj.append(",\"tbcr\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_TBCR] as i32);
            obj.append(",\"tcdcr\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_TCDCR] as i32);
            obj.append(",\"tadr\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_TADR] as i32);
            obj.append(",\"tbdr\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_TBDR] as i32);
            obj.append(",\"tcdr\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_TCDR] as i32);
            obj.append(",\"tddr\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_TDDR] as i32);
            obj.append(",\"scr\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_SCR] as i32);
            obj.append(",\"ucr\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_UCR] as i32);
            obj.append(",\"rsr\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_RSR] as i32);
            obj.append(",\"tsr\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_TSR] as i32);
            obj.append(",\"udr\":");
            push_hex_byte(obj, emu.mmu.mfp.regs[MFP_UDR] as i32);
            obj.append("},\"ioc\":{\"int_stat\":");
            push_hex_byte(obj, emu.mmu.ioc_int_stat as i32);
            obj.append(",\"int_vect\":");
            push_hex_byte(obj, emu.mmu.ioc_int_vect as i32);
            format(obj, "},\"crtc_int_line\":", crtc_line);
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return;
        }

        if tool_name == "arcl_dma" {
            var c3_csr: u8 = 0;
            var c3_cer: u8 = 0;
            var c3_ccr: u8 = 0;
            var c3_mtc: u16 = 0;
            var c3_mar: u32 = 0;
            var c3_dar: u32 = 0;
            var c3_btc: u16 = 0;
            var c3_bar: u32 = 0;
            c_dmac_pull_ch3(c3_csr, c3_cer, c3_ccr, c3_mtc, c3_mar, c3_dar, c3_btc, c3_bar);
            var obj: u8[>..] = [];
            obj.append("{\"channels\":[");
            for i in 4 {
                if i != 0 { obj.append(","); }
                var csr = emu.mmu.dmac.ch[i].csr;
                var cer = emu.mmu.dmac.ch[i].cer;
                var ccr = emu.mmu.dmac.ch[i].ccr;
                var mtc = emu.mmu.dmac.ch[i].mtc;
                var mar = emu.mmu.dmac.ch[i].mar;
                var dar = emu.mmu.dmac.ch[i].dar;
                var btc = emu.mmu.dmac.ch[i].btc;
                var bar = emu.mmu.dmac.ch[i].bar;
                if i == 3 {
                    csr = c3_csr;
                    cer = c3_cer;
                    ccr = c3_ccr;
                    mtc = c3_mtc;
                    mar = c3_mar;
                    dar = c3_dar;
                    btc = c3_btc;
                    bar = c3_bar;
                }
                format(obj, "{\"ch\":", i, ",\"csr\":");
                push_hex_byte(obj, csr as i32);
                obj.append(",\"cer\":");
                push_hex_byte(obj, cer as i32);
                obj.append(",\"dcr\":");
                push_hex_byte(obj, emu.mmu.dmac.ch[i].dcr as i32);
                obj.append(",\"ocr\":");
                push_hex_byte(obj, emu.mmu.dmac.ch[i].ocr as i32);
                obj.append(",\"scr\":");
                push_hex_byte(obj, emu.mmu.dmac.ch[i].scr as i32);
                obj.append(",\"ccr\":");
                push_hex_byte(obj, ccr as i32);
                format(obj, ",\"mtc\":", mtc, ",\"mar\":", mar, ",\"dar\":", dar, ",\"btc\":", btc, ",\"bar\":", bar, ",\"niv\":");
                push_hex_byte(obj, emu.mmu.dmac.ch[i].niv as i32);
                obj.append(",\"eiv\":");
                push_hex_byte(obj, emu.mmu.dmac.ch[i].eiv as i32);
                obj.append(",\"mfc\":");
                push_hex_byte(obj, emu.mmu.dmac.ch[i].mfc as i32);
                obj.append(",\"cpr\":");
                push_hex_byte(obj, emu.mmu.dmac.ch[i].cpr as i32);
                obj.append(",\"dfc\":");
                push_hex_byte(obj, emu.mmu.dmac.ch[i].dfc as i32);
                obj.append(",\"bfc\":");
                push_hex_byte(obj, emu.mmu.dmac.ch[i].bfc as i32);
                obj.append(",\"gcr\":");
                push_hex_byte(obj, emu.mmu.dmac.ch[i].gcr as i32);
                obj.append("}");
            }
            obj.append("]");
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return;
        }

        if tool_name == "x68k_opm" {
            var obj: u8[>..] = [];
            format(obj, "{\"lfo\":{\"freq\":", c_opm_shadow_byte(0x18), "},\"channels\":[");
            for ch in 8 {
                if ch != 0 { obj.append(","); }
                format(obj, "{\"ch\":", ch, ",\"key_on_mask\":", c_opm_key_on(ch as i32), "}");
            }
            obj.append("]");
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return;
        }

        if tool_name == "arcl_palette" {
            var obj: u8[>..] = [];
            obj.append("{\"graphic\":");
            append_palette(obj, 0);
            obj.append(",\"text\":");
            append_palette(obj, 0x200);
            append_machine(obj, emu, 0, false, true);
            obj.append("}");
            mcp_write_object(id_buf, obj);
            return;
        }

        if tool_name == "arcl_sprites" {
            let hstart = ((emu.mmu.crtc_regs[0x04] as i32) << 8) | (emu.mmu.crtc_regs[0x05] as i32);
            let vstart = ((emu.mmu.crtc_regs[0x0C] as i32) << 8) | (emu.mmu.crtc_regs[0x0D] as i32);
            let b0d = c_mem_read_bg_reg(0x0D) as i32;
            let b0f = c_mem_read_bg_reg(0x0F) as i32;
            let b11 = c_mem_read_bg_reg(0x11) as i32;
            let hadjust = (b0d - (hstart + 4)) * 8;
            let vdiv = if (b11 & 4) != 0 { 1 } else { 2 };
            let vline = (b0f - vstart) / vdiv;
            var obj: u8[>..] = [];
            obj.append("{\"sprites\":[");
            for i in 128 {
                if i != 0 { obj.append(","); }
                let base: i32 = (i as i32) * 8;
                let posx = (c_mem_read_sprite(base) as i32) | ((c_mem_read_sprite(base + 1) as i32) << 8);
                let posy = (c_mem_read_sprite(base + 2) as i32) | ((c_mem_read_sprite(base + 3) as i32) << 8);
                let ctrl = (c_mem_read_sprite(base + 4) as i32) | ((c_mem_read_sprite(base + 5) as i32) << 8);
                let ply = c_mem_read_sprite(base + 6) as i32;
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
            mcp_write_object(id_buf, obj);
            return;
        }

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
