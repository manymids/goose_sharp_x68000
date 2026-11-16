// YM2151 (OPM)。FM Sound Generator (fmgen) の OPM を Goose に書き直したもの。
//
//   FM Sound Generator with OPN/OPM interface
//   Copyright (C) by cisc 1998, 2003.
//
// 元のコード (fmgen.cpp / fmgeninl.h / opm.cpp / fmtimer.cpp) の条件は
// src/sound/fmgen-readme.txt にあり、その本文を改変せずに添えています。
//
// 書き直しで変えた点:
//   - C++ のクラスを構造体と関数にした。チップへのポインタ (chip_) は引数で渡し、表を指すポインタ
//     (ams_, pms, in / out) は表の行番号や配列の添字にした。
//   - OPM が使わない機能 (SSG 型エンベロープ、OPN 用の LFO 表) を除いた。
//   - 初期化されていなかったメンバは 0 から始まる (元のコードではヒープに残っていた値だった)。
//   - LFO の波形 3 (ノイズ) は、C の rand() ではなく、状態を構造体に持つ線形合同法で作る。
//   - C で符号付き整数があふれていた式 (自己帰還の位相、LFO による位相の揺れ) は、
//     MSVC と同じ 2 の補数の折り返しを明示して計算する。
//   - EG の曲線の数え (eg_curve_count_) は下位 3 ビットしか使わないので、そこで折り返す。
// 計算の結果は元のコードと同じになるよう、式の順序と型を合わせてある。

import std;
import math;
namespace opm;

// ---------------------------------------------------------------
// 定数
// ---------------------------------------------------------------

let CL_ENTS = 8192;        // FM_CLENTS: 対数→線形の表の長さ
let SIN_ENTS = 1024;       // FM_OPSINENTS
let LFO_ENTS = 256;        // FM_LFOENTS
let OPM_LFO_ENTS = 512;    // OPM_LFOENTS
let EG_BOTTOM = 955;       // FM_EG_BOTTOM
let RATIO_BITS = 7;        // FM_RATIOBITS
let EG_COUNT_RESET = 786048; // (2047 * 3) << FM_RATIOBITS
let TYPE_M = 1;            // OPM のオペレータ (fmgen の OpType)
let ::OPM_VOLUME_DB = -16; // px68k の既定 OPM_VOL 12 = -8 dB

// EG の段階 (fmgen の EGPhase)。次の段階へは +1 で進むので整数で持つ。
let PH_NEXT = 0;
let PH_ATTACK = 1;
let PH_DECAY = 2;
let PH_SUSTAIN = 3;
let PH_RELEASE = 4;
let PH_OFF = 5;

let FB_TABLE: u32[8] = [31, 7, 6, 5, 4, 3, 2, 1];
let KC_TABLE: u32[16] = [5197, 5506, 5833, 6180, 6180, 6547, 6937, 7349, 7349, 7786, 8249, 8740, 8740, 9259, 9810, 10394];
// アルゴリズムごとの、OP1-3 の入力と出力のつなぎ先 (CalcN だけが使う)
let ALGO_TABLE: u8[48] = [
    0, 1, 1, 2, 2, 3,   1, 0, 0, 1, 1, 2,
    1, 1, 1, 0, 0, 2,   0, 1, 2, 1, 1, 2,
    0, 1, 2, 2, 2, 1,   0, 1, 0, 1, 0, 1,
    0, 1, 2, 1, 2, 1,   1, 0, 1, 0, 1, 0,
];
let SL_TABLE: u32[16] = [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 124];
let SLOT_TABLE: u32[4] = [0, 2, 1, 3];

// fmgen.cpp の固定の表 (ソースから機械的に写したもの)
let NOTE_TABLE: u8[128] = [
    0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 3, 3, 3, 3, 3, 3,
    4, 4, 4, 4, 4, 4, 4, 5, 6, 7, 7, 7, 7, 7, 7, 7,
    8, 8, 8, 8, 8, 8, 8, 9, 10, 11, 11, 11, 11, 11, 11, 11,
    12, 12, 12, 12, 12, 12, 12, 13, 14, 15, 15, 15, 15, 15, 15, 15,
    16, 16, 16, 16, 16, 16, 16, 17, 18, 19, 19, 19, 19, 19, 19, 19,
    20, 20, 20, 20, 20, 20, 20, 21, 22, 23, 23, 23, 23, 23, 23, 23,
    24, 24, 24, 24, 24, 24, 24, 25, 26, 27, 27, 27, 27, 27, 27, 27,
    28, 28, 28, 28, 28, 28, 28, 29, 30, 31, 31, 31, 31, 31, 31, 31,
];

let DT_TABLE: i8[256] = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 4, 4, 4, 4,
    4, 6, 6, 6, 8, 8, 8, 10, 10, 12, 12, 14, 16, 16, 16, 16,
    2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10,
    10, 12, 12, 14, 16, 16, 18, 20, 22, 24, 26, 28, 32, 32, 32, 32,
    4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 12, 12, 14,
    16, 16, 18, 20, 22, 24, 26, 28, 32, 34, 38, 40, 44, 44, 44, 44,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, -2, -2, -2, -2, -2, -2, -2, -2, -4, -4, -4, -4,
    -4, -6, -6, -6, -8, -8, -8, -10, -10, -12, -12, -14, -16, -16, -16, -16,
    -2, -2, -2, -2, -4, -4, -4, -4, -4, -6, -6, -6, -8, -8, -8, -10,
    -10, -12, -12, -14, -16, -16, -18, -20, -22, -24, -26, -28, -32, -32, -32, -32,
    -4, -4, -4, -4, -4, -6, -6, -6, -8, -8, -8, -10, -10, -12, -12, -14,
    -16, -16, -18, -20, -22, -24, -26, -28, -32, -34, -38, -40, -44, -44, -44, -44,
];

let DECAY_TABLE1: i8[512] = [
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 0, 1, 1, 1, 0,
    1, 1, 1, 0, 1, 1, 1, 0,
    1, 0, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 1, 1, 0,
    1, 1, 1, 1, 1, 1, 1, 0,
    1, 0, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 1, 1, 0,
    1, 1, 1, 1, 1, 1, 1, 0,
    1, 0, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 1, 1, 0,
    1, 1, 1, 1, 1, 1, 1, 0,
    1, 0, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 1, 1, 0,
    1, 1, 1, 1, 1, 1, 1, 0,
    1, 0, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 1, 1, 0,
    1, 1, 1, 1, 1, 1, 1, 0,
    1, 0, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 1, 1, 0,
    1, 1, 1, 1, 1, 1, 1, 0,
    1, 0, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 1, 1, 0,
    1, 1, 1, 1, 1, 1, 1, 0,
    1, 0, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 1, 1, 0,
    1, 1, 1, 1, 1, 1, 1, 0,
    1, 0, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 1, 1, 0,
    1, 1, 1, 1, 1, 1, 1, 0,
    1, 0, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 0, 1, 0,
    1, 1, 1, 0, 1, 1, 1, 0,
    1, 1, 1, 1, 1, 1, 1, 0,
    1, 1, 1, 1, 1, 1, 1, 1,
    2, 1, 1, 1, 2, 1, 1, 1,
    2, 1, 2, 1, 2, 1, 2, 1,
    2, 2, 2, 1, 2, 2, 2, 1,
    2, 2, 2, 2, 2, 2, 2, 2,
    4, 2, 2, 2, 4, 2, 2, 2,
    4, 2, 4, 2, 4, 2, 4, 2,
    4, 4, 4, 2, 4, 4, 4, 2,
    4, 4, 4, 4, 4, 4, 4, 4,
    8, 4, 4, 4, 8, 4, 4, 4,
    8, 4, 8, 4, 8, 4, 8, 4,
    8, 8, 8, 4, 8, 8, 8, 4,
    16, 16, 16, 16, 16, 16, 16, 16,
    16, 16, 16, 16, 16, 16, 16, 16,
    16, 16, 16, 16, 16, 16, 16, 16,
    16, 16, 16, 16, 16, 16, 16, 16,
];

let DECAY_TABLE2: i32[16] = [
    1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2047, 2047, 2047, 2047, 2047,
];

let ATTACK_TABLE: i8[512] = [
    -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1,
    4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, -1, 4, 4, 4, -1,
    4, 4, 4, -1, 4, 4, 4, -1,
    4, -1, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, 4, 4, -1,
    4, 4, 4, 4, 4, 4, 4, -1,
    4, -1, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, 4, 4, -1,
    4, 4, 4, 4, 4, 4, 4, -1,
    4, -1, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, 4, 4, -1,
    4, 4, 4, 4, 4, 4, 4, -1,
    4, -1, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, 4, 4, -1,
    4, 4, 4, 4, 4, 4, 4, -1,
    4, -1, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, 4, 4, -1,
    4, 4, 4, 4, 4, 4, 4, -1,
    4, -1, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, 4, 4, -1,
    4, 4, 4, 4, 4, 4, 4, -1,
    4, -1, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, 4, 4, -1,
    4, 4, 4, 4, 4, 4, 4, -1,
    4, -1, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, 4, 4, -1,
    4, 4, 4, 4, 4, 4, 4, -1,
    4, -1, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, 4, 4, -1,
    4, 4, 4, 4, 4, 4, 4, -1,
    4, -1, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, -1, 4, -1,
    4, 4, 4, -1, 4, 4, 4, -1,
    4, 4, 4, 4, 4, 4, 4, -1,
    4, 4, 4, 4, 4, 4, 4, 4,
    3, 4, 4, 4, 3, 4, 4, 4,
    3, 4, 3, 4, 3, 4, 3, 4,
    3, 3, 3, 4, 3, 3, 3, 4,
    3, 3, 3, 3, 3, 3, 3, 3,
    2, 3, 3, 3, 2, 3, 3, 3,
    2, 3, 2, 3, 2, 3, 2, 3,
    2, 2, 2, 3, 2, 2, 2, 3,
    2, 2, 2, 2, 2, 2, 2, 2,
    1, 2, 2, 2, 1, 2, 2, 2,
    1, 2, 1, 2, 1, 2, 1, 2,
    1, 1, 1, 2, 1, 1, 1, 2,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
];


// ---------------------------------------------------------------
// 計算で作る表 (プログラムの開始時に 1 回だけ作る)
// ---------------------------------------------------------------

var g_built = false;
var g_cl: i32[CL_ENTS] = [0; CL_ENTS];          // 対数の減衰量から線形の振幅へ
var g_sine: u32[SIN_ENTS] = [0; SIN_ENTS];      // 正弦波の対数。下位ビットが符号
var g_pm: i32[2 * 8 * LFO_ENTS] = [0; 2 * 8 * LFO_ENTS];   // PM の深さ (種類, PMS, 位置)
var g_am: u32[2 * 4 * LFO_ENTS] = [0; 2 * 4 * LFO_ENTS];   // AM の深さ (種類, AMS, 位置)
var g_kf: i32[64] = [0; 64];                    // KF (1/64 半音) ごとの倍率
var g_lfo_am: i32[4 * OPM_LFO_ENTS] = [0; 4 * OPM_LFO_ENTS];  // OPM の LFO 波形 (波形, 位置)
var g_lfo_pm: i32[4 * OPM_LFO_ENTS] = [0; 4 * OPM_LFO_ENTS];

fn build_tables() {
    if g_built { return; }
    g_built = true;

    // Operator::MakeTable
    for i in 256 {
        var v = floor(pow(2.0, 13.0 - i / 256.0)) as i32;
        v = (v + 2) & ~3;
        g_cl[i * 2] = v;
        g_cl[i * 2 + 1] = 0 - v;
    }
    for p in 512..CL_ENTS { g_cl[p] = g_cl[p - 512] / 2; }

    let log2 = log(2.0);
    let pi_f: f32 = 3.14159265358979323846;
    for i in SIN_ENTS / 2 {
        // 元のコードは単精度の FM_PI で計算している
        let r32: f32 = (i * 2 + 1) * pi_f / SIN_ENTS;
        let r: f64 = r32;
        let q = -256.0 * log(sin(r)) / log2;
        let s = ((floor(q + 0.5) as i32) + 1) as u32;
        g_sine[i] = s * 2;
        g_sine[SIN_ENTS / 2 + i] = s * 2 + 1;
    }

    // MakeLFOTable
    let pms: f64[16] = [
        0.0, 1.0 / 360.0, 2.0 / 360.0, 3.0 / 360.0, 4.0 / 360.0, 6.0 / 360.0, 12.0 / 360.0, 24.0 / 360.0,
        0.0, 1.0 / 480.0, 2.0 / 480.0, 4.0 / 480.0, 10.0 / 480.0, 20.0 / 480.0, 80.0 / 480.0, 140.0 / 480.0,
    ];
    let amt: i32[8] = [31, 6, 4, 3, 31, 2, 1, 0];
    let pi_d = 3.14159265358979323846;
    for kind in 2 {
        for i in 8 {
            let pmb = pms[kind * 8 + i];
            for j in LFO_ENTS {
                let w = 0.6 * pmb * sin(2 * j * pi_d / LFO_ENTS) + 1.0;
                g_pm[(kind * 8 + i) * LFO_ENTS + j] = (65536.0 * (w - 1.0)) as! i32; // C の int() と同じく 0 へ向けて切り捨てる
            }
        }
        for i in 4 {
            for j in LFO_ENTS {
                g_am[(kind * 4 + i) * LFO_ENTS + j] = ((((j * 4) >> amt[kind * 4 + i]) * 2) << 2) as u32;
            }
        }
    }

    // Channel4::MakeTable: 100/64 セント刻み
    for i in 64 { g_kf[i] = (65536.0 * pow(2.0, i / 768.0)) as! i32; }

    // OPM::BuildLFOTable。波形 3 (ノイズ) の行は使わない (LFO() がその場で作る)
    for kind in 4 {
        for c in OPM_LFO_ENTS {
            var a: i64 = 0;
            var p: i64 = 0;
            if kind == 0 {
                p = (((c + 0x100) & 0x1ff) / 2) - 0x80;
                a = 0xff - c / 2;
            } else if kind == 1 {
                a = if c < 0x100 { 0xff } else { 0 };
                p = if c < 0x100 { 0x7f } else { -0x80 };
            } else if kind == 2 {
                p = (c + 0x80) & 0x1ff;
                p = if p < 0x100 { p - 0x80 } else { 0x17f - p };
                a = if c < 0x100 { 0xff - c } else { c - 0x100 };
            }
            g_lfo_am[kind * OPM_LFO_ENTS + c] = a as i32;
            g_lfo_pm[kind * OPM_LFO_ENTS + c] = (0 - p - 1) as i32;
        }
    }
}

// ---------------------------------------------------------------
// チップ全体で共有する値 (fmgen の Chip)
// ---------------------------------------------------------------

struct FmChip {
    ratio: u32 = 0,
    aml: u32 = 0,       // AM の LFO の位置 (0-255)
    pml: u32 = 0,       // PM の LFO の位置 (0-255)
    pmv: i32 = 0,       // 今のチャンネルの PM の量
    multable: u32[64] = [0; 64],   // (DT2, MUL) ごとの位相の増分の倍率
}

fn set_ratio(chip: FmChip&, ratio: u32) {
    if chip.ratio == ratio { return; }
    chip.ratio = ratio;
    let dt2lv: f32[4] = [1.0, 1.414, 1.581, 1.732];
    for h in 4 {
        let rr: f64 = (dt2lv[h] as f64) * ratio;
        for l in 16 {
            let mul: i32 = if l != 0 { (l * 2) as i32 } else { 1 };
            chip.multable[h * 16 + l] = (mul * rr) as! u32;
        }
    }
}

// ---------------------------------------------------------------
// オペレータ (fmgen の Operator)
// ---------------------------------------------------------------

struct FmOperator {
    out: i32 = 0,
    out2: i32 = 0,
    // 位相
    dp: u32 = 0,
    detune: u32 = 0,
    detune2: u32 = 0,
    multiple: u32 = 0,
    pg_count: u32 = 0,
    pg_diff: u32 = 0,
    pg_diff_lfo: i32 = 0,
    // エンベロープ
    optype: i32 = 0,
    bn: u32 = 0,                // ブロックとノート
    eg_level: i32 = 0,
    eg_next: i32 = 0,           // この値に達したら次の段階へ (eg_level_on_next_phase_)
    eg_count: i32 = 0,
    eg_count_diff: i32 = 0,
    eg_out: i32 = 0,
    tl_out: i32 = 0,
    eg_rate: i32 = 0,
    eg_curve_count: i32 = 0,
    ksr: u32 = 0,               // key_scale_rate_
    eg_phase: i32 = 0,
    ams_row: i32 = 0,           // g_am の行 (種類 * 4 + AMS)
    ms: u32 = 0,
    tl: u32 = 0,
    tl_latch: u32 = 0,
    ar: u32 = 0,
    dr: u32 = 0,
    sr: u32 = 0,
    sl: u32 = 0,
    rr: u32 = 0,
    ks: u32 = 0,
    keyon: bool = false,
    amon: bool = false,
    param_changed: bool = false,
    mute: bool = false,
}

fn rate_limit(base: u32, ksr: u32) -> u32 {
    return min(63, base + ksr);
}

fn eg_update(op: FmOperator&) {
    op.eg_out = min(op.tl_out + op.eg_level, 0x3ff) << 3;
}

fn set_eg_rate(op: FmOperator&, chip: FmChip&, rate: u32) {
    op.eg_rate = rate as i32;
    op.eg_count_diff = ((DECAY_TABLE2[(rate / 4) & 15] as! u32) * chip.ratio) as! i32;
}

fn shift_phase(op: FmOperator&, chip: FmChip&, next: i32) {
    var phase = next;
    if phase == PH_ATTACK {
        op.tl = op.tl_latch;
        if op.ar + op.ksr < 62 {
            set_eg_rate(op, chip, if op.ar != 0 { rate_limit(op.ar, op.ksr) } else { 0 });
            op.eg_phase = PH_ATTACK;
            return;
        }
        phase = PH_DECAY;
    }
    if phase == PH_DECAY {
        if op.sl != 0 {
            op.eg_level = 0;
            op.eg_next = (op.sl * 8) as i32;
            set_eg_rate(op, chip, if op.dr != 0 { rate_limit(op.dr, op.ksr) } else { 0 });
            op.eg_phase = PH_DECAY;
            return;
        }
        phase = PH_SUSTAIN;
    }
    if phase == PH_SUSTAIN {
        op.eg_level = (op.sl * 8) as i32;
        op.eg_next = 0x400;
        set_eg_rate(op, chip, if op.sr != 0 { rate_limit(op.sr, op.ksr) } else { 0 });
        op.eg_phase = PH_SUSTAIN;
        return;
    }
    if phase == PH_RELEASE && (op.eg_phase == PH_ATTACK || op.eg_level < EG_BOTTOM) {
        op.eg_next = 0x400;
        set_eg_rate(op, chip, rate_limit(op.rr, op.ksr));
        op.eg_phase = PH_RELEASE;
        return;
    }
    op.eg_level = EG_BOTTOM;
    op.eg_next = EG_BOTTOM;
    op.eg_update();
    set_eg_rate(op, chip, 0);
    op.eg_phase = PH_OFF;
}

fn op_reset(op: FmOperator&, chip: FmChip&) {
    op.tl = 127;
    op.tl_latch = 127;
    shift_phase(op, chip, PH_OFF);
    op.eg_count = 0;
    op.eg_curve_count = 0;
    op.pg_count = 0;
    op.out = 0;
    op.out2 = 0;
    op.param_changed = true;
}

fn op_prepare(op: FmOperator&, chip: FmChip&) {
    guard op.param_changed else { return; }
    op.param_changed = false;
    op.pg_diff = (op.dp + (DT_TABLE[(op.detune + op.bn) & 255] as! u32)) * chip.multable[(op.detune2 * 16 + op.multiple) & 63];
    op.pg_diff_lfo = (op.pg_diff >> 11) as i32;
    op.ksr = op.bn >> (3 - op.ks);
    op.tl_out = if op.mute { 0x3ff } else { (op.tl * 8) as i32 };
    if op.eg_phase == PH_ATTACK {
        set_eg_rate(op, chip, if op.ar != 0 { rate_limit(op.ar, op.ksr) } else { 0 });
    } else if op.eg_phase == PH_DECAY {
        set_eg_rate(op, chip, if op.dr != 0 { rate_limit(op.dr, op.ksr) } else { 0 });
        op.eg_next = (op.sl * 8) as i32;
    } else if op.eg_phase == PH_SUSTAIN {
        set_eg_rate(op, chip, if op.sr != 0 { rate_limit(op.sr, op.ksr) } else { 0 });
    } else if op.eg_phase == PH_RELEASE {
        set_eg_rate(op, chip, rate_limit(op.rr, op.ksr));
    }
    op.ams_row = op.optype * 4 + (if op.amon { ((op.ms >> 4) & 3) as i32 } else { 0 });
    op.eg_update();
}

fn key_on(op: FmOperator&, chip: FmChip&) {
    if op.keyon { return; }
    op.keyon = true;
    if op.eg_phase == PH_OFF || op.eg_phase == PH_RELEASE {
        shift_phase(op, chip, PH_ATTACK);
        op.eg_update();
        op.out = 0;
        op.out2 = 0;
        op.pg_count = 0;
    }
}

fn key_off(op: FmOperator&, chip: FmChip&) {
    guard op.keyon else { return; }
    op.keyon = false;
    shift_phase(op, chip, PH_RELEASE);
}

fn eg_calc(op: FmOperator&, chip: FmChip&) {
    op.eg_count = EG_COUNT_RESET;
    let at = (op.eg_rate & 63) * 8 + (op.eg_curve_count & 7);
    if op.eg_phase == PH_ATTACK {
        let c: i32 = ATTACK_TABLE[at];
        if c >= 0 {
            op.eg_level -= 1 + (op.eg_level >> c);
            if op.eg_level <= 0 { shift_phase(op, chip, PH_DECAY); }
        }
        op.eg_update();
    } else {
        op.eg_level += DECAY_TABLE1[at];
        if op.eg_level >= op.eg_next { shift_phase(op, chip, op.eg_phase + 1); }
        op.eg_update();
    }
    op.eg_curve_count = (op.eg_curve_count + 1) & 7;
}

fn eg_step(op: FmOperator&, chip: FmChip&) {
    op.eg_count -= op.eg_count_diff;
    if op.eg_count <= 0 { eg_calc(op, chip); }
}

fn sine(s: i32) -> u32 {
    return g_sine[s & (SIN_ENTS - 1)];
}

fn log_to_lin(a: u32) -> i32 {
    return if a < CL_ENTS { g_cl[a] } else { 0 };
}

// 位相を進め、進める前の値を返す。
fn pg_calc(op: FmOperator&) -> u32 {
    let ret = op.pg_count;
    op.pg_count += op.pg_diff;
    return ret;
}

fn pg_calc_l(op: FmOperator&, chip: FmChip&) -> u32 {
    let ret = op.pg_count;
    // 元の式は int の掛け算であふれうる。MSVC と同じく 32 ビットで折り返す
    let wobble: i32 = (((op.pg_diff_lfo as i64) * chip.pmv) as! i32) >> 5;
    op.pg_count += op.pg_diff + (wobble as! u32);
    return ret;
}

// 自己帰還の変調。元の式 (in << 17) は int であふれうるので、32 ビットで折り返して計算する。
fn feedback(input: i32, fb: u32) -> i32 {
    return ((((input as! u32) << 17) as! i32) >> fb) >> 19;
}

fn op_calc(op: FmOperator&, chip: FmChip&, input: i32) -> i32 {
    eg_step(op, chip);
    op.out2 = op.out;
    let pgin = ((pg_calc(op) >> 19) as i32) + (input >> 1);
    op.out = log_to_lin((op.eg_out as! u32) + sine(pgin));
    return op.out;
}

fn op_calc_l(op: FmOperator&, chip: FmChip&, input: i32) -> i32 {
    eg_step(op, chip);
    let pgin = ((pg_calc_l(op, chip) >> 19) as i32) + (input >> 1);
    op.out = log_to_lin((op.eg_out as! u32) + sine(pgin) + g_am[(op.ams_row * LFO_ENTS + chip.aml as i32) & (2 * 4 * LFO_ENTS - 1)]);
    return op.out;
}

fn op_calc_n(op: FmOperator&, chip: FmChip&, noise: u32) -> i32 {
    eg_step(op, chip);
    let lv = max(0, 0x3ff - (op.tl_out + op.eg_level)) << 1;
    op.out = if (noise & 1) != 0 { lv } else { 0 - lv };
    return op.out;
}

// 前回の出力を返す (元の CalcFB と同じ)
fn op_calc_fb(op: FmOperator&, chip: FmChip&, fb: u32) -> i32 {
    eg_step(op, chip);
    let input = op.out + op.out2;
    op.out2 = op.out;
    var pgin = (pg_calc(op) >> 19) as i32;
    if fb < 31 { pgin += feedback(input, fb); }
    op.out = log_to_lin((op.eg_out as! u32) + sine(pgin));
    return op.out2;
}

// こちらは新しい出力を返す (元の CalcFBL と同じ)
fn op_calc_fbl(op: FmOperator&, chip: FmChip&, fb: u32) -> i32 {
    eg_step(op, chip);
    let input = op.out + op.out2;
    op.out2 = op.out;
    var pgin = (pg_calc_l(op, chip) >> 19) as i32;
    if fb < 31 { pgin += feedback(input, fb); }
    op.out = log_to_lin((op.eg_out as! u32) + sine(pgin) + g_am[(op.ams_row * LFO_ENTS + chip.aml as i32) & (2 * 4 * LFO_ENTS - 1)]);
    return op.out;
}

// ---------------------------------------------------------------
// 4 オペレータのチャンネル (fmgen の Channel4)
// ---------------------------------------------------------------

struct FmChannel {
    fb: u32 = 0,
    buf: i32[4] = [0; 4],
    ins: u8[3] = [0; 3],    // CalcN で各 OP が読む buf の添字
    outs: u8[3] = [0; 3],   // 書く buf の添字
    pms_row: i32 = 0,       // g_pm の行 (種類 * 8 + PMS)
    algo: i32 = 0,
    op: FmOperator[4] = [FmOperator {}; 4],
}

fn set_algorithm(c: FmChannel&, algo: u32) {
    let at = (algo & 7) * 6;
    for k in 3 {
        c.ins[k] = ALGO_TABLE[at + k * 2];
        c.outs[k] = ALGO_TABLE[at + k * 2 + 1];
    }
    c.op[0].out = 0;
    c.op[0].out2 = 0;
    c.algo = (algo & 7) as i32;
}

fn set_kc_kf(c: FmChannel&, kc: u32, kf: u32) {
    let oct = 19 - ((kc >> 4) & 7);
    var kcv = KC_TABLE[kc & 15];
    kcv = (kcv + 2) / 4 * 4;
    var dp = kcv * (g_kf[kf & 63] as! u32);
    dp >>= 19;
    dp <<= 19;
    dp >>= oct;
    let bn = (kc >> 2) & 31;
    for i in 4 {
        c.op[i].dp = dp;
        c.op[i].bn = bn;
        c.op[i].param_changed = true;
    }
}

fn set_ms(c: FmChannel&, ms: u32) {
    for i in 4 {
        c.op[i].ms = ms;
        c.op[i].param_changed = true;
    }
}

fn key_control(c: FmChannel&, chip: FmChip&, key: u32) {
    for i in 4 {
        if (key & (1 << i)) != 0 { key_on(c.op[i], chip); } else { key_off(c.op[i], chip); }
    }
}

// オペレータの準備。鳴っていれば bit 0、LFO がかかっていれば bit 1 を返す。
fn ch_prepare(c: FmChannel&, chip: FmChip&) -> u32 {
    for i in 4 { op_prepare(c.op[i], chip); }
    c.pms_row = c.op[0].optype * 8 + (c.op[0].ms & 7) as i32;
    var key: u32 = 0;
    var any_am = false;
    for i in 4 {
        if c.op[i].eg_phase != PH_OFF { key = 1; }
        if c.op[i].amon { any_am = true; }
    }
    let mask: u32 = if any_am { 0x37 } else { 7 };
    return key | (if (c.op[0].ms & mask) != 0 { 2 } else { 0 });
}

fn ch_calc(c: FmChannel&, chip: FmChip&) -> i32 {
    var r: i32 = 0;
    let fb = c.fb;
    if c.algo == 0 {
        op_calc(c.op[2], chip, c.op[1].out);
        op_calc(c.op[1], chip, c.op[0].out);
        r = op_calc(c.op[3], chip, c.op[2].out);
        op_calc_fb(c.op[0], chip, fb);
    } else if c.algo == 1 {
        op_calc(c.op[2], chip, c.op[0].out + c.op[1].out);
        op_calc(c.op[1], chip, 0);
        r = op_calc(c.op[3], chip, c.op[2].out);
        op_calc_fb(c.op[0], chip, fb);
    } else if c.algo == 2 {
        op_calc(c.op[2], chip, c.op[1].out);
        op_calc(c.op[1], chip, 0);
        r = op_calc(c.op[3], chip, c.op[0].out + c.op[2].out);
        op_calc_fb(c.op[0], chip, fb);
    } else if c.algo == 3 {
        op_calc(c.op[2], chip, 0);
        op_calc(c.op[1], chip, c.op[0].out);
        r = op_calc(c.op[3], chip, c.op[1].out + c.op[2].out);
        op_calc_fb(c.op[0], chip, fb);
    } else if c.algo == 4 {
        op_calc(c.op[2], chip, 0);
        r = op_calc(c.op[1], chip, c.op[0].out);
        r += op_calc(c.op[3], chip, c.op[2].out);
        op_calc_fb(c.op[0], chip, fb);
    } else if c.algo == 5 {
        r = op_calc(c.op[2], chip, c.op[0].out);
        r += op_calc(c.op[1], chip, c.op[0].out);
        r += op_calc(c.op[3], chip, c.op[0].out);
        op_calc_fb(c.op[0], chip, fb);
    } else if c.algo == 6 {
        r = op_calc(c.op[2], chip, 0);
        r += op_calc(c.op[1], chip, c.op[0].out);
        r += op_calc(c.op[3], chip, 0);
        op_calc_fb(c.op[0], chip, fb);
    } else {
        r = op_calc(c.op[2], chip, 0);
        r += op_calc(c.op[1], chip, 0);
        r += op_calc(c.op[3], chip, 0);
        r += op_calc_fb(c.op[0], chip, fb);
    }
    return r;
}

fn ch_calc_l(c: FmChannel&, chip: FmChip&) -> i32 {
    chip.pmv = g_pm[(c.pms_row * LFO_ENTS + chip.pml as i32) & (2 * 8 * LFO_ENTS - 1)];
    var r: i32 = 0;
    let fb = c.fb;
    if c.algo == 0 {
        op_calc_l(c.op[2], chip, c.op[1].out);
        op_calc_l(c.op[1], chip, c.op[0].out);
        r = op_calc_l(c.op[3], chip, c.op[2].out);
        op_calc_fbl(c.op[0], chip, fb);
    } else if c.algo == 1 {
        op_calc_l(c.op[2], chip, c.op[0].out + c.op[1].out);
        op_calc_l(c.op[1], chip, 0);
        r = op_calc_l(c.op[3], chip, c.op[2].out);
        op_calc_fbl(c.op[0], chip, fb);
    } else if c.algo == 2 {
        op_calc_l(c.op[2], chip, c.op[1].out);
        op_calc_l(c.op[1], chip, 0);
        r = op_calc_l(c.op[3], chip, c.op[0].out + c.op[2].out);
        op_calc_fbl(c.op[0], chip, fb);
    } else if c.algo == 3 {
        op_calc_l(c.op[2], chip, 0);
        op_calc_l(c.op[1], chip, c.op[0].out);
        r = op_calc_l(c.op[3], chip, c.op[1].out + c.op[2].out);
        op_calc_fbl(c.op[0], chip, fb);
    } else if c.algo == 4 {
        op_calc_l(c.op[2], chip, 0);
        r = op_calc_l(c.op[1], chip, c.op[0].out);
        r += op_calc_l(c.op[3], chip, c.op[2].out);
        op_calc_fbl(c.op[0], chip, fb);
    } else if c.algo == 5 {
        r = op_calc_l(c.op[2], chip, c.op[0].out);
        r += op_calc_l(c.op[1], chip, c.op[0].out);
        r += op_calc_l(c.op[3], chip, c.op[0].out);
        op_calc_fbl(c.op[0], chip, fb);
    } else if c.algo == 6 {
        r = op_calc_l(c.op[2], chip, 0);
        r += op_calc_l(c.op[1], chip, c.op[0].out);
        r += op_calc_l(c.op[3], chip, 0);
        op_calc_fbl(c.op[0], chip, fb);
    } else {
        r = op_calc_l(c.op[2], chip, 0);
        r += op_calc_l(c.op[1], chip, 0);
        r += op_calc_l(c.op[3], chip, 0);
        r += op_calc_fbl(c.op[0], chip, fb);
    }
    return r;
}

// チャンネル 8 のノイズ。OP4 がノイズになり、つなぎ方は ALGO_TABLE に従う。
fn ch_calc_n(c: FmChannel&, chip: FmChip&, noise: u32, lfo: bool) -> i32 {
    if lfo { chip.pmv = g_pm[(c.pms_row * LFO_ENTS + chip.pml as i32) & (2 * 8 * LFO_ENTS - 1)]; }
    c.buf[1] = 0;
    c.buf[2] = 0;
    c.buf[3] = 0;
    c.buf[0] = c.op[0].out;
    if lfo { op_calc_fbl(c.op[0], chip, c.fb); } else { op_calc_fb(c.op[0], chip, c.fb); }
    let a = if lfo { op_calc_l(c.op[1], chip, c.buf[c.ins[0] & 3]) } else { op_calc(c.op[1], chip, c.buf[c.ins[0] & 3]) };
    c.buf[c.outs[0] & 3] += a;
    let b = if lfo { op_calc_l(c.op[2], chip, c.buf[c.ins[1] & 3]) } else { op_calc(c.op[2], chip, c.buf[c.ins[1] & 3]) };
    c.buf[c.outs[1] & 3] += b;
    let o = c.op[3].out;
    op_calc_n(c.op[3], chip, noise);
    return c.buf[c.outs[2] & 3] + o;
}

// ---------------------------------------------------------------
// OPM 本体 (fmgen の OPM と Timer、px68k の MyOPM)
// ---------------------------------------------------------------

struct X68kOPM {
    ch: FmChannel[8] = [FmChannel {}; 8],
    chip: FmChip = FmChip {},
    fmvolume: i32 = 0,
    clock: u32 = 0,
    rate: u32 = 0,
    pmd: u32 = 0,
    amd: u32 = 0,
    lfo_count: u32 = 0,
    lfo_count_diff: u32 = 0,
    lfo_step: u32 = 0,
    lfo_count_prev: u32 = 0,
    lfo_noise: u32 = 0,
    lfowaveform: u32 = 0,
    rateratio: u32 = 0,
    noise: u32 = 0,
    noisecount: i32 = 0,
    noisedelta: u32 = 0,
    lfofreq: u32 = 0,
    status: u32 = 0,        // bit 0 タイマー A、bit 1 タイマー B
    reg01: u32 = 0,
    kc: u32[8] = [0; 8],
    kf: u32[8] = [0; 8],
    pan: u32[8] = [0; 8],
    // タイマー
    regtc: u32 = 0,
    regta: u32[2] = [0; 2],
    timera: i32 = 0,
    timera_count: i32 = 0,
    timerb: i32 = 0,
    timerb_count: i32 = 0,
    timer_step: i32 = 0,
    // px68k の MyOPM
    cur_reg: u32 = 0,
    cur_count: u32 = 0,
    irq: bool = false,      // 割り込みの要求。受け取った側が落とす
}
type ::X68kOPM = opm::X68kOPM;

fn set_status(o: X68kOPM&, bit: u32) {
    if (o.status & bit) == 0 {
        o.status |= bit;
        o.irq = true;
    }
}

fn reset_status(o: X68kOPM&, bit: u32) {
    if (o.status & bit) != 0 { o.status &= ~bit; }
}

fn set_timer_control(o: X68kOPM&, data: u32) {
    let changed = o.regtc ^ data;
    o.regtc = data & 0xFF;
    if (data & 0x10) != 0 { o.reset_status(1); }
    if (data & 0x20) != 0 { o.reset_status(2); }
    if (changed & 1) != 0 { o.timera_count = if (data & 1) != 0 { o.timera } else { 0 }; }
    if (changed & 2) != 0 { o.timerb_count = if (data & 2) != 0 { o.timerb } else { 0 }; }
}

fn set_timer_a(o: X68kOPM&, addr: u32, data: u32) {
    o.regta[addr & 1] = data & 0xFF;
    let tmp = ((o.regta[0] << 2) + (o.regta[1] & 3)) as i32;
    o.timera = (1024 - tmp) * o.timer_step;
}

// タイマー A が満了したとき。CSM モードなら全チャンネルをキーオンし直す。
fn timer_a_event(o: X68kOPM&) {
    if (o.regtc & 0x80) == 0 { return; }
    for i in 8 {
        key_control(o.ch[i], o.chip, 0);
        key_control(o.ch[i], o.chip, 0xF);
    }
}

// us マイクロ秒だけタイマーを進める
fn count(o: X68kOPM&, us: i32) {
    if o.timera_count != 0 {
        o.timera_count -= us << 16;
        if o.timera_count <= 0 {
            o.timer_a_event();
            while o.timera_count <= 0 { o.timera_count += o.timera; }
            if (o.regtc & 4) != 0 { o.set_status(1); }
        }
    }
    if o.timerb_count != 0 {
        o.timerb_count -= us << 12;
        if o.timerb_count <= 0 {
            while o.timerb_count <= 0 { o.timerb_count += o.timerb; }
            if (o.regtc & 8) != 0 { o.set_status(2); }
        }
    }
}

// 0.1 マイクロ秒単位の時間を進める (px68k の Count2)。端数は次に持ち越す。
fn count2(o: X68kOPM&, clock: u32) {
    o.cur_count += clock;
    o.count((o.cur_count / 10) as i32);
    o.cur_count %= 10;
}

fn set_parameter(o: X68kOPM&, addr: u32, data: u32) {
    let slot = SLOT_TABLE[(addr >> 3) & 3];
    let op .= o.ch[addr & 7].op[slot];
    let group = (addr >> 5) & 7;
    if group == 2 {         // 40-5F DT1 / MUL
        op.detune = ((data >> 4) & 7) * 0x20;
        op.multiple = data & 0x0F;
    } else if group == 3 {  // 60-7F TL。CSM モード中はキーオンまで保留する
        if (o.regtc & 0x80) == 0 {
            op.tl = data & 0x7F;
            op.param_changed = true;
        }
        op.tl_latch = data & 0x7F;
        return;
    } else if group == 4 {  // 80-9F KS / AR
        op.ks = (data >> 6) & 3;
        op.ar = (data & 0x1F) * 2;
    } else if group == 5 {  // A0-BF D1R / AMS-EN
        op.dr = (data & 0x1F) * 2;
        op.amon = (data & 0x80) != 0;
    } else if group == 6 {  // C0-DF D2R / DT2
        op.sr = (data & 0x1F) * 2;
        op.detune2 = (data >> 6) & 3;
    } else if group == 7 {  // E0-FF D1L / RR
        op.sl = SL_TABLE[(data >> 4) & 15];
        op.rr = (data & 0x0F) * 4 + 2;
    }
    op.param_changed = true;
}

fn set_reg(o: X68kOPM&, addr: u32, data: u32) {
    if addr >= 0x100 { return; }
    let c = addr & 7;
    if addr == 0x01 {                       // TEST (LFO のやり直し)
        if (data & 2) != 0 {
            o.lfo_count = 0;
            o.lfo_count_prev = 0xFFFFFFFF;
        }
        o.reg01 = data;
    } else if addr == 0x08 {                // キーオン
        let ch .= o.ch[data & 7];
        if (o.regtc & 0x80) == 0 {
            key_control(ch, o.chip, data >> 3);
        } else {
            for i in 4 {
                if (data & (0x08 << i)) == 0 { key_off(ch.op[i], o.chip); }
            }
        }
    } else if addr == 0x10 || addr == 0x11 {
        o.set_timer_a(addr, data);
    } else if addr == 0x12 {
        o.timerb = (256 - data as i32) * o.timer_step;
    } else if addr == 0x14 {
        o.set_timer_control(data);
    } else if addr == 0x18 {                // LFO の周波数
        o.lfofreq = data;
        let one: u32 = 1;
        o.lfo_count_diff = o.rateratio * ((16 + (data & 15)) << (16 - 4 - RATIO_BITS)) / (one << (15 - (data >> 4)));
    } else if addr == 0x19 {                // PMD / AMD
        if (data & 0x80) != 0 { o.pmd = data & 0x7F; } else { o.amd = data & 0x7F; }
    } else if addr == 0x1B {                // CT / LFO の波形
        o.lfowaveform = data & 3;
    } else if addr >= 0x20 && addr < 0x28 { // RL / FB / CONNECT
        o.ch[c].fb = FB_TABLE[(data >> 3) & 7];
        set_algorithm(o.ch[c], data & 7);
        o.pan[c] = (data >> 6) & 3;
    } else if addr >= 0x28 && addr < 0x30 { // KC
        o.kc[c] = data;
        set_kc_kf(o.ch[c], o.kc[c], o.kf[c]);
    } else if addr >= 0x30 && addr < 0x38 { // KF
        o.kf[c] = data >> 2;
        set_kc_kf(o.ch[c], o.kc[c], o.kf[c]);
    } else if addr >= 0x38 && addr < 0x40 { // PMS / AMS
        set_ms(o.ch[c], (data << 4) | (data >> 4));
    } else if addr == 0x0F {                // ノイズ
        o.noisedelta = data;
        o.noisecount = 0;
    } else if addr >= 0x40 {
        o.set_parameter(addr, data);
    }
}

fn set_volume(o: X68kOPM&, db_in: i32) {
    let db = min(db_in, 20);
    if db > -192 {
        let ten: f32 = 10.0;
        let scale: f32 = 16384.0;
        let forty: f32 = 40.0;
        let exponent: f32 = db / forty;
        o.fmvolume = (scale * pow(ten, exponent)) as! i32;
    } else {
        o.fmvolume = 0;
    }
}

// fmgen の OPM::Reset
fn chip_reset(o: X68kOPM&) {
    for i: u32 in 0x100 { o.set_reg(i, 0); }
    o.set_reg(0x19, 0x80);
    o.timera_count = 0;
    o.timerb_count = 0;
    o.status = 0;
    o.lfo_step = 0;
    o.lfo_noise = 1;
    o.noise = 12345;
    o.noisecount = 0;
    for i in 8 {
        for k in 4 { op_reset(o.ch[i].op[k], o.chip); }
    }
}

// 電源を入れたとき (px68k の new MyOPM と Init(4 MHz, 44.1 kHz))
fn power_on(o: X68kOPM&) {
    build_tables();
    o = X68kOPM {};
    o.lfo_count_prev = 0xFFFFFFFF;
    o.lfo_noise = 1;
    for i in 8 {
        set_algorithm(o.ch[i], 0);
        for k in 4 { o.ch[i].op[k].optype = TYPE_M; }
    }
    o.clock = 4000000;
    o.rate = 44100;
    let fmclock = o.clock / 64;
    o.rateratio = ((fmclock << RATIO_BITS) + o.rate / 2) / o.rate;
    o.timer_step = (1000000.0 * 65536.0 / fmclock) as! i32;
    set_ratio(o.chip, o.rateratio);
    o.chip_reset();
    o.set_volume(0);
    for i in 8 {
        for k in 4 {
            o.ch[i].op[k].mute = false;
            o.ch[i].op[k].param_changed = true;
        }
    }
    o.set_volume(OPM_VOLUME_DB);
}

// 本体のリセット (px68k の x68k_sound_reset)
fn machine_reset(o: X68kOPM&) {
    o.chip_reset();
    o.cur_reg = 0;
    o.cur_count = 0;
    o.set_volume(OPM_VOLUME_DB);
    o.irq = false;
}

// $E90001 (port 0) がレジスタ番号、$E90003 (port 1) がデータ
fn write_io(o: X68kOPM&, port: u32, data: u8) {
    if (port & 1) != 0 { o.set_reg(o.cur_reg, data); } else { o.cur_reg = data; }
}

fn read_status(o: X68kOPM&) -> u8 {
    return (o.status & 3) as u8;
}

fn lfo(o: X68kOPM&) {
    if o.lfowaveform != 3 {
        let c = ((o.lfo_count >> 15) & 0x1FE) as i32;
        let row = (o.lfowaveform as i32) * OPM_LFO_ENTS;
        // 元の式は int と uint32_t の掛け算なので、符号なしで計算する
        o.chip.pml = ((g_lfo_pm[(row + c) & (4 * OPM_LFO_ENTS - 1)] as! u32) * o.pmd / 128 + 0x80) & 0xFF;
        o.chip.aml = ((g_lfo_am[(row + c) & (4 * OPM_LFO_ENTS - 1)] as! u32) * o.amd / 128) & 0xFF;
    } else if ((o.lfo_count ^ o.lfo_count_prev) & ~((1 << 17) - 1)) != 0 {
        o.lfo_noise = o.lfo_noise * 1103515245 + 12345;
        let c: u32 = (((o.lfo_noise >> 16) & 0x7FFF) / 17) & 0xFF;
        o.chip.pml = ((c - 0x80) * o.pmd / 128 + 0x80) & 0xFF;
        o.chip.aml = (c * o.amd / 128) & 0xFF;
    }
    o.lfo_count_prev = o.lfo_count;
    o.lfo_step += 1;
    if (o.lfo_step & 7) == 0 { o.lfo_count += o.lfo_count_diff; }
}

fn next_noise(o: X68kOPM&) -> u32 {
    o.noisecount += (2 * o.rateratio) as i32;
    if o.noisecount >= (32 << RATIO_BITS) {
        let n = max(32 - (o.noisedelta & 0x1F) as i32, 2);   // 1 は 2 として数える
        o.noisecount -= n << RATIO_BITS;
        if (o.noisedelta & 0x1F) == 0x1F { o.noisecount -= RATIO_BITS; }
        o.noise = (o.noise >> 1) ^ (if (o.noise & 1) != 0 { 0x8408 } else { 0 });
    }
    return o.noise;
}

fn to_sample(o: X68kOPM&, s: i32) -> i32 {
    return (clamp(s, -0x10000, 0xFFFF) * o.fmvolume) >> 14;
}

// 1 サンプルぶん、鳴っているチャンネルを合成して、パンに従って bins (0 は捨てる、1 右、2 左、3 両方) へ足す。
fn mix_one(o: X68kOPM&, active: u32, bins: i32[4]&) {
    let with_lfo = (active & 0xAAAA) != 0;
    for i in 8 {
        if (active & (0x4000 >> (i * 2))) == 0 { continue; }
        let to = (o.pan[i] & 3) as i64;
        if i == 7 && (o.noisedelta & 0x80) != 0 {
            let n = o.next_noise();
            bins[to] += ch_calc_n(o.ch[7], o.chip, n, with_lfo);
        } else if with_lfo {
            bins[to] += ch_calc_l(o.ch[i], o.chip);
        } else {
            bins[to] += ch_calc(o.ch[i], o.chip);
        }
    }
}

// 左右交互に並んだ samples に OPM の音を足し込む (fmgen の OPM::Mix)。
fn mix(o: X68kOPM&, samples: i16[:]) {
    var active: u32 = 0;
    for i in 8 { active = (active << 2) | ch_prepare(o.ch[i], o.chip); }
    if (active & 0x5555) == 0 { return; }
    // LFO の波形を初期化中 (TEST の bit 1) なら LFO はかけない
    if (o.reg01 & 2) != 0 { active &= 0x5555; }
    var bins: i32[4] = [0; 4];
    for i in samples.len / 2 {
        bins = [0; 4];
        o.lfo();
        o.mix_one(active, bins);
        let first = clamp(samples[i * 2] + o.to_sample(bins[1] + bins[3]), -0x8000, 0x7FFF);
        let second = clamp(samples[i * 2 + 1] + o.to_sample(bins[2] + bins[3]), -0x8000, 0x7FFF);
        samples[i * 2] = first as! i16;
        samples[i * 2 + 1] = second as! i16;
    }
}
