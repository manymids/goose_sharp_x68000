// MCP の要求とツール引数から値を取り出す。JSON の解析は標準ライブラリの json::Reader に任せ、
// ここには「オブジェクトのメンバをキーで引く」ことと、ARCL 固有の数値の読み方だけを置く。
//
// どの関数も、JSON として壊れている入力はキーが無いものとして扱う。

import std;
import json;

// オブジェクト obj のメンバ key の値を、書かれたままの文字列で返す (前後の空白は含まない)。
// 同じキーが複数あれば最初のもの。
fn json_member(obj: const u8[:], key: const u8[:]) -> const u8[:], bool {
    var r = json::reader(obj);
    var start: i64 = -1;
    var end: i64 = -1;
    json::each_member(r) { name =>
        if start < 0 && name == key {
            json::peek(r); // 値の先頭まで空白を読み飛ばす
            start = r.pos;
            json::skip(r);
            end = r.pos;
        } else {
            json::skip(r);
        }
    };
    if start < 0 || r.error.len > 0 { return obj[0..0], false; }
    return obj[start..end], true;
}

fn json_has(obj: const u8[:], key: const u8[:]) -> bool {
    let _, found = json_member(obj, key);
    return found;
}

fn starts_number(value: const u8[:]) -> bool {
    return value.len > 0 && (value[0] == '-' || (value[0] >= '0' && value[0] <= '9'));
}

// 配列 list の要素を、書かれたままの文字列で順に out へ入れる。配列でなければ false。
fn json_elements(list: const u8[:], out: const u8[:][>..]&) -> bool {
    if list.len == 0 || list[0] != '[' { return false; }
    var r = json::reader(list);
    json::each_element(r) {
        json::peek(r);
        let start = r.pos;
        json::skip(r);
        if r.error.len == 0 { out.push(list[start..r.pos]); }
    };
    return r.error.len == 0;
}

// JSON の文字列の値 (引用符を含む、書かれたまま) を解いて out に追記する。文字列でなければ false。
fn json_string(value: const u8[:], out: u8[>..]&) -> bool {
    if value.len == 0 || value[0] != '"' { return false; }
    var r = json::reader(value);
    var scratch: u8[>..] = [];
    out.append(json::read_string(r, scratch));
    return json::finish(r);
}

// 文字列のメンバを out に追記する。キーが無いか、値が文字列でなければ false。
fn extract_json_str(obj: const u8[:], key: const u8[:], out: u8[>..]&) -> bool {
    let value, found = json_member(obj, key);
    if !found || value[0] != '"' { return false; }
    var r = json::reader(value);
    var scratch: u8[>..] = [];
    out.append(json::read_string(r, scratch));
    return true;
}

// 数値のメンバを f64 で読む。キーが無いか、値が数値でなければ false。
fn json_number(obj: const u8[:], key: const u8[:]) -> f64, bool {
    let value, found = json_member(obj, key);
    guard found && starts_number(value) else { return 0.0, false; }
    var r = json::reader(value);
    let v = json::read_number(r);
    return v, r.error.len == 0;
}

fn is_whole(v: f64) -> bool {
    if v < -4294967296.0 || v > 4294967296.0 { return false; }
    let truncated: f64 = v as! i64;
    return truncated == v;
}

// 整数のメンバ。キーが無い、数値でない、整数でない、i32 に収まらない、のどれかなら default_val。
fn extract_json_int(obj: const u8[:], key: const u8[:], default_val: i32) -> i32 {
    let v, ok = json_number(obj, key);
    if !ok || !is_whole(v) || v < -2147483648.0 || v > 2147483647.0 { return default_val; }
    return v as! i32;
}

// 番地や値を表す文字列を XEiJ と同じ規則で読む。"0x" か "$" で始まる、"h" で終わる、
// または a-f を含むなら 16 進、それ以外は 10 進 (負数は 32 bit の 2 の補数)。
fn parse_addr_text(text: const u8[:]) -> u32, bool {
    var lo: i64 = 0;
    var hi: i64 = text.len;
    while lo < hi && (text[lo] == ' ' || text[lo] == '\t') { lo += 1; }
    while hi > lo && (text[hi - 1] == ' ' || text[hi - 1] == '\t') { hi -= 1; }
    var hex = false;
    if hi - lo >= 2 && text[lo] == '0' && (text[lo + 1] == 'x' || text[lo + 1] == 'X') {
        hex = true;
        lo += 2;
    } else if hi - lo >= 1 && text[lo] == '$' {
        hex = true;
        lo += 1;
    } else if hi - lo >= 1 && (text[hi - 1] == 'h' || text[hi - 1] == 'H') {
        hex = true;
        hi -= 1;
    } else {
        for c in text[lo..hi] {
            if (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') { hex = true; }
        }
    }
    var negative = false;
    if !hex && lo < hi && text[lo] == '-' {
        negative = true;
        lo += 1;
    }
    if lo >= hi { return 0, false; }
    let base: u64 = if hex { 16 } else { 10 };
    var n: u64 = 0;
    for c in text[lo..hi] {
        var digit: i32 = -1;
        if c >= '0' && c <= '9' { digit = c - '0'; }
        else if hex && c >= 'a' && c <= 'f' { digit = c - 'a' + 10; }
        else if hex && c >= 'A' && c <= 'F' { digit = c - 'A' + 10; }
        if digit < 0 { return 0, false; }
        n = n * base + (digit as u64);
        if n > 0xFFFFFFFF { return 0, false; }
    }
    return if negative { (0x100000000 - n) as! u32 } else { n as u32 }, true;
}

// 番地や値の引数。JSON の数値でも、上の規則の文字列でもよい。
// 戻り値は、値、キーがあったか、32 bit の値として正しいか (キーが無ければ true)。
fn json_addr_parse(obj: const u8[:], key: const u8[:]) -> u32, bool, bool {
    let value, found = json_member(obj, key);
    guard found else { return 0, false, true; }
    if value[0] == '"' {
        var text: u8[>..] = [];
        extract_json_str(obj, key, text);
        let v, ok = parse_addr_text(text);
        return v, true, ok;
    }
    let v, ok = json_number(obj, key);
    if !ok || !is_whole(v) || v < -4294967295.0 || v > 4294967295.0 { return 0, true, false; }
    let n = v as! i64;
    return (if n < 0 { 0x100000000 + n } else { n }) as! u32, true, true;
}

fn extract_json_addr(obj: const u8[:], key: const u8[:], default_val: u32) -> u32 {
    let v, present, valid = json_addr_parse(obj, key);
    return if present && valid { v } else { default_val };
}
