// ADPCM (OKI MSM6258V)。px68k の adpcm.c を移したもの。
//
// CPU か DMA が書いた 4 ビットのデータを 12 ビットの波形に戻し、44.1 kHz に補間してリングバッファへ
// ためる。フレームの終わりに、そのバッファから出力のサンプルを取り出す。
// データはふつう DMA チャンネル 3 がメモリから流し込む (x68k_dmac の exec_adpcm)。

import std;
namespace adpcm;

let ::ADPCM_RING = 96000;       // リングバッファの長さ (サンプル数)
let LEVEL_MAX = 2047;           // 12 ビットの波形の範囲
let LEVEL_MIN = -2048;
let IP_SCALE = 256;             // 補間の位置を 0-255 で表す
let OUTPUT_RATE = 529200;       // 44100 * 12。出力の速さ (クロックと比べるための単位)
let VOLUME = 13;                // px68k の既定の音量 15: (int)(16 / 1.189207115)
let PRE_UNIT = 10000000;

// サンプリングの速さ (クロックと分周比で決まる)。添字は bit 2 が OPM のクロック切り替え、
// bit 0-1 が 8255 ポート C の bit 2-3。
let CLOCK_RATES: i32[8] = [93750, 125000, 187500, 125000, 46875, 62500, 93750, 62500];

// ステップ幅の表: floor(16 * 1.1^n)
let STEP_SIZE: i32[49] = [
    16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66,
    73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
    337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411,
    1552,
];

struct X68kADPCM {
    left: i16[ADPCM_RING] = [0; ADPCM_RING],  // 補間済みのサンプル。パンで切った側には 0 が入る
    right: i16[ADPCM_RING] = [0; ADPCM_RING],
    wr: i32 = 0,                // リングバッファの書き込み位置
    rd: i32 = 0,                // 読み出し位置
    clock: i32 = 2,             // CLOCK_RATES の添字
    clock_rate: i32 = 187500,
    count: i32 = 0,             // 入力 1 個を出力何個にするかを数える端数
    step: i32 = 0,              // ステップ幅の番号 (0-48)
    level: i32 = 0,             // 今の波形の値
    playing: bool = false,
    pre_counter: i32 = 0,       // DMA を進める時期を数える
    backlog: i32 = 0,           // バッファにたまっているサンプルの見積もり
    pan: i32 = 0x0B,            // 8255 ポート C の下位 4 ビット。bit 0-1 が左右のミュート
    held_l: i32 = 0,            // 最後に出した値。データが尽きたら 0 へ向かって減らす
    held_r: i32 = 0,
    recent: i32[4] = [-1; 4],   // 直近 4 個の波形の値 (補間用)。先頭が -1 なら再生を始めた直後
    out_l: i32[4] = [0; 4],     // 出力側の直近 4 個
    out_r: i32[4] = [0; 4],
}
type ::X68kADPCM = adpcm::X68kADPCM;

// 4 点 y を通る 3 次の補間。x は y[1] から y[2] へ向かう位置 (0-255)。px68k の INTERPOLATE と同じ式。
fn interpolate(y: i32[4]&, x: i32) -> i32 {
    let a = ((0 - y[0] + 3 * y[1] - 3 * y[2] + y[3]) * x + IP_SCALE / 2) / IP_SCALE + 3 * (y[0] - 2 * y[1] + y[2]);
    let b = (a * x + IP_SCALE / 2) / IP_SCALE - 2 * y[0] - 3 * y[1] + 6 * y[2] - y[3];
    return (b * x + 3 * IP_SCALE) / (6 * IP_SCALE) + y[1];
}

fn shift_in(y: i32[4]&, v: i32) {
    y[0] = y[1];
    y[1] = y[2];
    y[2] = y[3];
    y[3] = v;
}

// 4 ビットのデータ 1 個ぶんの波形の変化。bit 3 が符号、bit 0-2 がステップ幅の 1 / 1/2 / 1/4 倍を足すかどうか。
// どのデータでも 1/8 は必ず足す。
fn delta(step: i32, nibble: i32) -> i32 {
    let size: i32 = STEP_SIZE[step];
    let weight: i32 = (nibble & 7) * 2 + 1; // bit 2, 1, 0 がそれぞれ 8, 4, 2。それに 1/8 のぶんの 1
    let amount = (size * weight) / 8;
    return if (nibble & 8) != 0 { 0 - amount } else { amount };
}

// データの大きさに応じてステップ幅を変える: 小さければ 1 段下げ、大きければ 2-8 段上げる。
fn next_step(step: i32, nibble: i32) -> i32 {
    let change: i32[8] = [-1, -1, -1, -1, 2, 4, 6, 8];
    return clamp(step + change[nibble & 7], 0, 48);
}

// 4 ビットのデータ 1 個を波形にして、出力の速さに合わせた数のサンプルをバッファへ入れる。
fn write_nibble(a: X68kADPCM&, data: i32) {
    // 無音を 0x00 / 0x88 で書かれると、ステップ幅が大きいとき値が端へ流れていく。0 のデータは、
    // 値を 0 から遠ざける向きになるなら逆の符号として読む (XEiJ の補正)。
    var nibble = data;
    if nibble == 0 && a.level >= 0 { nibble = 8; }
    else if nibble == 8 && a.level < 0 { nibble = 0; }

    a.level = clamp(a.level + delta(a.step, nibble), LEVEL_MIN, LEVEL_MAX);
    a.step = next_step(a.step, nibble);

    if a.recent[0] == -1 { a.recent = [a.level; 4]; }
    else { shift_in(a.recent, a.level); }

    while OUTPUT_RATE > a.count {
        if a.playing {
            let ratio = ((a.count / 100) * IP_SCALE) / (OUTPUT_RATE / 100);
            let v = clamp(interpolate(a.recent, ratio), LEVEL_MIN, LEVEL_MAX) as! i16;
            a.right[a.wr] = if (a.pan & 1) == 0 { v } else { 0 };
            a.left[a.wr] = if (a.pan & 2) == 0 { v } else { 0 };
            a.wr = (a.wr + 1) % ADPCM_RING;
        }
        a.count += a.clock_rate;
    }
    a.count -= OUTPUT_RATE;
}

// $E92001 がコマンド (bit 0 停止、bit 1 再生)、$E92003 がデータ (下位 4 ビット、上位 4 ビットの順)。
fn write(a: X68kADPCM&, addr: u32, data: u8) {
    if addr == 0xE92001 {
        if (data & 1) != 0 {
            a.playing = false;
        } else if (data & 2) != 0 {
            if !a.playing {
                a.step = 0;
                a.level = 0;
                a.held_l = -2;
                a.held_r = -2;
                a.playing = true;
            }
            a.recent = [-1; 4];
        }
    } else if addr == 0xE92003 && a.playing {
        a.write_nibble(data & 15);
        a.write_nibble((data >> 4) & 15);
    }
}

fn read(a: X68kADPCM&, addr: u32) -> u8 {
    if addr == 0xE92001 { return if a.playing { 0xC0 } else { 0x40 }; }
    return 0;
}

fn set_clock_index(a: X68kADPCM&, index: i32) {
    a.count = 0;
    a.clock = index;
    a.clock_rate = CLOCK_RATES[index & 7];
}

// 8255 ポート C の下位 4 ビット。bit 2-3 が変わるとサンプリングの速さが変わる。
fn set_pan(a: X68kADPCM&, n: i32) {
    if (a.pan & 0x0C) != (n & 0x0C) { a.set_clock_index((a.clock & 4) | ((n >> 2) & 3)); }
    a.pan = n;
}

// OPM のレジスタ $1B の bit 7 (CT1) でクロックが 8 MHz / 4 MHz に切り替わる。n は 0 か 4。
fn set_clock(a: X68kADPCM&, n: i32) {
    if (a.clock & 4) != n { a.set_clock_index(n | ((a.pan >> 2) & 3)); }
}

// clock だけ時間が進んだ。たまっているぶんが尽きる頃合いになった回数を返すので、
// 呼んだ側がその回数だけ DMA を進める。
fn pre_update(a: X68kADPCM&, clock: i32) -> i32 {
    var runs: i32 = 0;
    a.pre_counter += (a.clock_rate / 24) * clock;
    while a.pre_counter >= PRE_UNIT {
        a.backlog -= (OUTPUT_RATE * 400) / a.clock_rate;
        if a.backlog <= 0 {
            a.backlog = 0;
            runs += 1;
        }
        a.pre_counter -= PRE_UNIT;
    }
    return runs;
}

fn empty(a: X68kADPCM&) -> bool {
    return a.wr == a.rd;
}

// 0 へ 1 ずつ近づける。データが来ないときに、出力へ直流を残さないため。
fn decay(v: i32) -> i32 {
    return if v < 0 { v + 1 } else if v > 0 { v - 1 } else { 0 };
}

// 出力のサンプル 1 個 (左右) を取り出して、16 ビットに収めて返す。
fn next_sample(a: X68kADPCM&) -> i16, i16 {
    if a.empty() {
        a.held_r = decay(a.held_r);
        a.held_l = decay(a.held_l);
    } else {
        a.held_r = a.left[a.rd];
        a.held_l = a.right[a.rd];
        a.rd = (a.rd + 1) % ADPCM_RING;
    }
    shift_in(a.out_r, a.held_r * VOLUME);
    shift_in(a.out_l, a.held_l * VOLUME);
    // 位置 0 の補間なので 1 つ前の値が出る。px68k と同じ遅れを保つために式はそのまま使う。
    let r = clamp(interpolate(a.out_r, 0), -32768, 32767) as! i16;
    let l = clamp(interpolate(a.out_l, 0), -32768, 32767) as! i16;
    return r, l;
}

// サンプルを取り出し終えたあと、たまっている量を数え直す。
fn note_backlog(a: X68kADPCM&) {
    a.backlog = a.wr - a.rd;
    if a.backlog < 0 { a.backlog += ADPCM_RING; }
}
