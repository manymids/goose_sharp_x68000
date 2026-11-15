// 画面と音のファイルへの書き出し (BMP / PNG / WAV) と、音の録音。
// どれもバイト列を組み立てて標準ライブラリの write_file で書くだけで、ホストの機能は使わない。
// パスは UTF-8 (標準ライブラリが Windows のワイド文字へ変える)。

import std;
import os;
namespace output;

let ::CAPTURE_RATE = 44100;
let ::CAPTURE_SECONDS = 60;
let CAPTURE_FRAMES = 2646000;   // CAPTURE_RATE * CAPTURE_SECONDS
let SILENCE_PEAK = 256;         // これより小さい音しか無ければ「無音」とみなす

fn put16(out: u8[>..]&, v: u32) {
    out.push((v & 0xFF) as u8);
    out.push(((v >> 8) & 0xFF) as u8);
}

fn put32(out: u8[>..]&, v: u32) {
    put16(out, v & 0xFFFF);
    put16(out, v >> 16);
}

fn put32_be(out: u8[>..]&, v: u32) {
    out.push((v >> 24) as! u8);
    out.push(((v >> 16) & 0xFF) as u8);
    out.push(((v >> 8) & 0xFF) as u8);
    out.push((v & 0xFF) as u8);
}

// ---------------------------------------------------------------
// BMP: 32 ビット、下の行から。画素はメモリ上の 0xAARRGGBB をそのまま (B, G, R, A の順) 書く
// ---------------------------------------------------------------

fn bmp_bytes(px: const u32[:], w: i32, h: i32, out: u8[>..]&) {
    let image: u32 = (w * h * 4) as u32;
    out.append("BM");
    put32(out, 54 + image);
    put32(out, 0);
    put32(out, 54);
    put32(out, 40);                 // BITMAPINFOHEADER
    put32(out, w as u32);
    put32(out, h as u32);
    put16(out, 1);                  // 面の数
    put16(out, 32);                 // 1 画素のビット数
    put32(out, 0);                  // 圧縮なし
    put32(out, image);
    put32(out, 0x0B13);             // 72 dpi
    put32(out, 0x0B13);
    put32(out, 0);
    put32(out, 0);
    for y in 0..h {
        let row = (h - 1 - y) * w;
        for x in w { put32(out, px[row + x]); }
    }
}

// ---------------------------------------------------------------
// PNG: RGB 8 ビット。zlib は圧縮しないブロックだけで組む
// ---------------------------------------------------------------

fn crc_update(c: u32, data: const u8[:]) -> u32 {
    var crc = c;
    for b in data {
        crc ^= b;
        for _ in 8 { crc = (crc >> 1) ^ (0xEDB88320 & (0 - (crc & 1))); }
    }
    return crc;
}

fn png_chunk(out: u8[>..]&, kind: const u8[:], data: const u8[:]) {
    put32_be(out, data.len as u32);
    out.append(kind);
    out.append(data);
    put32_be(out, ~crc_update(crc_update(0xFFFFFFFF, kind), data));
}

fn png_bytes(px: const u32[:], w: i32, h: i32, out: u8[>..]&) {
    // 各行の先頭にフィルタの種類 (0 = そのまま) を置いた RGB の並び
    var raw: u8[>..] = [];
    for y in 0..h {
        raw.push(0);
        for x in 0..w {
            let p = px[y * w + x];
            raw.push(((p >> 16) & 0xFF) as u8);
            raw.push(((p >> 8) & 0xFF) as u8);
            raw.push((p & 0xFF) as u8);
        }
    }
    var z: u8[>..] = [];
    z.push(0x78);
    z.push(0x01);
    var s1: u32 = 1;
    var s2: u32 = 0;
    var pos: i64 = 0;
    while pos < raw.len {
        let chunk = min(raw.len - pos, 65535);
        z.push(if pos + chunk == raw.len { 1 } else { 0 });   // 最後のブロックなら 1
        put16(z, chunk as u32);
        put16(z, (~(chunk as u32)) & 0xFFFF);
        z.append(raw[pos..pos + chunk]);
        for b in raw[pos..pos + chunk] {
            s1 = (s1 + b) % 65521;
            s2 = (s2 + s1) % 65521;
        }
        pos += chunk;
    }
    put32_be(z, (s2 << 16) | s1);   // Adler-32

    var ihdr: u8[>..] = [];
    put32_be(ihdr, w as u32);
    put32_be(ihdr, h as u32);
    ihdr.append([8, 2, 0, 0, 0]);   // 8 ビット、RGB、圧縮 0、フィルタ 0、インターレースなし
    out.append([137, 80, 78, 71, 13, 10, 26, 10]);
    png_chunk(out, "IHDR", ihdr);
    png_chunk(out, "IDAT", z);
    png_chunk(out, "IEND", "");
}

fn is_png_path(path: const u8[:]) -> bool {
    if path.len < 4 { return false; }
    var ext: u8[4] = [0; 4];
    for i in 4 {
        let c = path[path.len - 4 + i];
        ext[i] = if c >= 'A' && c <= 'Z' { c + 32 } else { c };
    }
    return ext == ".png";
}

// w x h の画素を path に書く。名前が .png で終わっていれば PNG、それ以外は BMP。
fn save_image(path: const u8[:], px: const u32[:], w: i32, h: i32) -> bool {
    if path.len == 0 || w <= 0 || h <= 0 || w > 768 || h > 512 || w * h > px.len { return false; }
    var bytes: u8[>..] = [];
    if is_png_path(path) { png_bytes(px, w, h, bytes); } else { bmp_bytes(px, w, h, bytes); }
    return write_file(path, bytes);
}

// ---------------------------------------------------------------
// 音の録音と WAV (44.1 kHz、16 ビット、ステレオ)
// ---------------------------------------------------------------

struct Capture {
    active: bool = false,
    frames: i64 = 0,        // たまったサンプル数 (左右で 1)
    truncated: bool = false, // 上限 (60 秒) を超えたぶんを捨てた
}

var g_capture = Capture {};
var g_capture_buf: i16[CAPTURE_FRAMES * 2] = [0; CAPTURE_FRAMES * 2];

fn capture_start() {
    g_capture = Capture { active: true, .. };
}

fn capture_status() -> Capture {
    return g_capture;
}

// 1 フレームぶんの音 (左右交互) を録音に足す
fn capture_push(samples: const i16[:]) {
    if !g_capture.active { return; }
    let room = CAPTURE_FRAMES - g_capture.frames;
    let frames = samples.len / 2;
    let n = clamp(frames, 0, room);
    if n < frames { g_capture.truncated = true; }
    if n == 0 { return; }
    let at = g_capture.frames * 2;
    copy_into(g_capture_buf[at..at + n * 2], samples[..n * 2]);
    g_capture.frames += n;
}

fn wav_bytes(samples: const i16[:], out: u8[>..]&) {
    let data = (samples.len * 2) as u32;
    out.append("RIFF");
    put32(out, 36 + data);
    out.append("WAVEfmt ");
    put32(out, 16);
    put16(out, 1);                  // PCM
    put16(out, 2);                  // ステレオ
    put32(out, CAPTURE_RATE);
    put32(out, CAPTURE_RATE * 4);   // 1 秒のバイト数
    put16(out, 4);                  // 1 サンプルのバイト数
    put16(out, 16);
    out.append("data");
    put32(out, data);
    for s in samples { put16(out, s as! u16); }
}

// 録音を止める。path が空でなければ WAV に書く。
// 戻り値は、書けたか、サンプル数、捨てたぶんがあるか、最大の振幅、無音だったか。
fn capture_stop(path: const u8[:]) -> bool, i64, bool, i32, bool {
    g_capture.active = false;
    let n = g_capture.frames;
    let recorded = g_capture_buf[..n * 2];
    var peak: i32 = 0;
    for s in recorded { peak = max(peak, abs(s as i32)); }
    var ok = true;
    if path.len > 0 {
        // 1 サンプルも無いときは、元の C の実装と同じくファイルを作らずに失敗とする
        if n == 0 {
            ok = false;
        } else {
            var bytes: u8[>..] = [];
            wav_bytes(recorded, bytes);
            ok = write_file(path, bytes);
        }
    }
    return ok, n, g_capture.truncated, peak, peak < SILENCE_PEAK;
}
