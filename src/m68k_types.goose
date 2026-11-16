// Motorola 68000 & Sharp X68000 基本定数・型定義

// M68000 SR (Status Register) フラグビット
let SR_C: u16 = 0x0001; // キャリー
let SR_V: u16 = 0x0002; // オーバーフロー
let SR_Z: u16 = 0x0004; // ゼロ
let SR_N: u16 = 0x0008; // ネガティブ
let SR_X: u16 = 0x0010; // エクステンド
let SR_S: u16 = 0x2000; // スーパーバイザモード
let SR_T: u16 = 0x8000; // トレースモード

// 符号拡張。下位のワード (バイト) を符号付きとみなして広げる (68000 の EXT と同じ)。
inline fn sext16(v: u32) -> i32 { return v as! i16; }
inline fn sext8(v: u32) -> i32 { return v as! i8; }
// ワードを符号拡張したロングを、レジスタの値 (u32) として返す (アドレスレジスタへのワードの書き込みなど)。
inline fn sext16_u32(v: u32) -> u32 { return sext16(v) as! u32; }

// アドレスレジスタのインデックス (cpu.a[])
let REG_A0 = 0;
let REG_A1 = 1;
let REG_A2 = 2;
let REG_A3 = 3;
let REG_A4 = 4;
let REG_A5 = 5;
let REG_A6 = 6;
let REG_A7 = 7; // SP
