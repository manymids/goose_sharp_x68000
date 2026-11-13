// Keyboard/joypad operations independent of transport.
import std;
import .x68k_emu;
import .x68k_mfp;
import .x68k_bridge;

// Explicit key events emit repeats; text composition uses type_set_key.
fn input_key(emu: X68kEmulator&, code: i32, down: bool) {
    if code < 0 || code >= 128 { return; }
    let sc = if down { code as u8 } else { (code as u8) | 0x80 };
    emu.mmu.mfp.send_key(sc);
    note_key(emu, code, down);
}

fn input_host_scancode(emu: X68kEmulator&, sc: u8) {
    emu.mmu.mfp.send_key(sc);
    note_key(emu, (sc & 0x7F), (sc & 0x80) == 0);
}

fn input_joy(emu: X68kEmulator&, port: i32, mask: u8, down: bool) -> bool {
    if (port != 0 && port != 1) || mask == 0 { return false; }
    if port == 0 {
        if down { emu.mmu.joy1 &= ~mask; } else { emu.mmu.joy1 |= mask; }
    } else {
        if down { emu.mmu.joy2 &= ~mask; } else { emu.mmu.joy2 |= mask; }
    }
    return true;
}

// No synthetic releases into a restored MFP queue; joystick bytes stay saved.
fn input_discard(emu: X68kEmulator&) {
    emu.session.keys = [false; 128];
    c_host_input_discard();
}

fn az_code(ch: u8) -> i32 {
    let codes: u8[26] = [0x1e, 0x2e, 0x2c, 0x20, 0x13, 0x21, 0x22, 0x23, 0x18, 0x24, 0x25, 0x26, 0x30, 0x2f, 0x19, 0x1a, 0x11, 0x14, 0x1f, 0x15, 0x17, 0x2d, 0x12, 0x2b, 0x16, 0x2a];
    if ch < 'a' || ch > 'z' { return -1; }
    return codes[(ch - 'a') as i32];
}

fn digit_code(ch: u8) -> i32 {
    let codes: u8[10] = [0x0b, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a];
    if ch < '0' || ch > '9' { return -1; }
    return codes[(ch - '0') as i32];
}

// key_code がスキャンコードの代わりに返す値
let KEY_UNKNOWN = -1; // 対応するキーがない
let KEY_BLOCKED = -2; // エミュレータ側の機能に割り当てているので送らない

fn key_code(name: const u8[:]) -> i32 {
    if name == "f12" || name == "scrolllock" { return KEY_BLOCKED; }
    if name.len == 1 {
        let ch = name[0];
        if ch >= 'a' && ch <= 'z' { return az_code(ch); }
        if ch >= '0' && ch <= '9' { return digit_code(ch); }
    }
    if name == "space" { return 0x35; }
    if name == "return" || name == "enter" { return 0x1d; }
    if name == "tab" { return 0x10; }
    if name == "backspace" { return 0x0f; }
    if name == "escape" { return 0x01; }
    if name == "up" { return 0x3c; }
    if name == "down" { return 0x3e; }
    if name == "left" { return 0x3b; }
    if name == "right" { return 0x3d; }
    if name == "shift" || name == "lshift" { return 0x70; }
    if name == "ctrl" { return 0x71; }
    if name == "opt1" { return 0x72; }
    if name == "opt2" { return 0x73; }
    // F1-F10 は 0x63 から、XF1-XF5 は 0x55 から並ぶ。
    if name.len >= 2 && name[0] == 'f' {
        let n, ok = parse_int(name[1..]);
        if ok && n >= 1 && n <= 10 { return (0x62 + n) as i32; }
    }
    if name.len == 3 && name[0] == 'x' && name[1] == 'f' && name[2] >= '1' && name[2] <= '5' {
        return 0x55 + (name[2] - '1');
    }
    if name == "home" { return 0x36; }
    if name == "del" || name == "delete" { return 0x37; }
    if name == "rollup" { return 0x38; }
    if name == "rolldown" { return 0x39; }
    if name == "undo" { return 0x3a; }
    if name == "clr" { return 0x3f; }
    if name == "help" { return 0x54; }
    if name == "kana" { return 0x5a; }
    if name == "romaji" { return 0x5b; }
    if name == "code" { return 0x5c; }
    if name == "caps" { return 0x5d; }
    if name == "ins" || name == "insert" { return 0x5e; }
    if name == "hiragana" { return 0x5f; }
    if name == "zenkaku" { return 0x60; }
    if name == "break" { return 0x61; }
    if name == "copy" { return 0x62; }
    return KEY_UNKNOWN;
}

fn type_set_key(emu: X68kEmulator&, code: i32, down: bool) {
    if code < 0 || code >= 128 { return; }
    let was = emu.session.keys[code];
    if down && !was {
        emu.mmu.mfp.send_key(code as u8);
        emu.session.keys[code] = true;
    } else if !down && was {
        emu.mmu.mfp.send_key((code as u8) | 0x80);
        emu.session.keys[code] = false;
    }
}

// 文字を打つためのスキャンコードと、SHIFT が要るかどうか。3 つ目は対応するキーがあるか。
fn type_scancode(ch: u8) -> i32, bool, bool {
    if ch >= 'a' && ch <= 'z' { return az_code(ch), false, true; }
    if ch >= 'A' && ch <= 'Z' { return az_code(ch - 'A' + 'a'), true, true; }
    if ch >= '0' && ch <= '9' { return digit_code(ch), false, true; }
    if ch == ' ' { return 0x35, false, true; }
    if ch == '\t' { return 0x10, false, true; }
    if ch == '\n' || ch == '\r' { return 0x1d, false, true; }
    if ch == '!' { return 0x02, true, true; }
    if ch == '"' { return 0x03, true, true; }
    if ch == '#' { return 0x04, true, true; }
    if ch == '$' { return 0x05, true, true; }
    if ch == '%' { return 0x06, true, true; }
    if ch == '&' { return 0x07, true, true; }
    if ch == '\'' { return 0x08, true, true; }
    if ch == '(' { return 0x09, true, true; }
    if ch == ')' { return 0x0a, true, true; }
    if ch == ',' { return 0x31, false, true; }
    if ch == '<' { return 0x31, true, true; }
    if ch == '-' { return 0x0c, false, true; }
    if ch == '=' { return 0x0c, true, true; }
    if ch == '.' { return 0x32, false, true; }
    if ch == '>' { return 0x32, true, true; }
    if ch == '/' { return 0x33, false, true; }
    if ch == '?' { return 0x33, true, true; }
    if ch == ';' { return 0x27, false, true; }
    if ch == '+' { return 0x27, true, true; }
    if ch == ':' { return 0x28, false, true; }
    if ch == '*' { return 0x28, true, true; }
    if ch == '@' { return 0x1b, false, true; }
    if ch == '`' { return 0x1b, true, true; }
    if ch == '^' { return 0x0d, false, true; }
    if ch == '~' { return 0x0d, true, true; }
    if ch == '_' { return 0x34, true, true; }
    if ch == '[' { return 0x1c, false, true; }
    if ch == '{' { return 0x1c, true, true; }
    if ch == '\\' { return 0x0e, false, true; }
    if ch == '|' { return 0x0e, true, true; }
    if ch == ']' { return 0x29, false, true; }
    if ch == '}' { return 0x29, true, true; }
    return -1, false, false;
}

fn type_has_key(ch: u8) -> bool {
    let code, shift, ok = type_scancode(ch);
    return ok;
}

fn note_key(emu: X68kEmulator&, code: i32, down: bool) {
    if code < 0 || code >= 128 { return; }
    emu.session.keys[code] = down;
}

fn release_held_keys(emu: X68kEmulator&) {
    for i in 128 {
        if emu.session.keys[i] {
            emu.mmu.mfp.send_key((i as u8) | 0x80);
            emu.session.keys[i] = false;
        }
    }
    emu.mmu.joy1 = 0xFF;
    emu.mmu.joy2 = 0xFF;
    c_host_input_discard();
}

fn joy_mask(name: const u8[:]) -> u8 {
    if name == "up" { return 0x01; }
    if name == "down" { return 0x02; }
    if name == "left" { return 0x04; }
    if name == "right" { return 0x08; }
    if name == "a" || name == "trg1" { return 0x20; }
    if name == "b" || name == "trg2" { return 0x40; }
    return 0;
}
