// Motorola 68000 & Sharp X68000 基本定数・型定義

// M68000 SR (Status Register) フラグビット
let SR_C: u16 = 0x0001; // キャリー
let SR_V: u16 = 0x0002; // オーバーフロー
let SR_Z: u16 = 0x0004; // ゼロ
let SR_N: u16 = 0x0008; // ネガティブ
let SR_X: u16 = 0x0010; // エクステンド
let SR_S: u16 = 0x2000; // スーパーバイザモード
let SR_T: u16 = 0x8000; // トレースモード

// アドレスレジスタのインデックス (cpu.a[])
let REG_A0 = 0;
let REG_A1 = 1;
let REG_A2 = 2;
let REG_A3 = 3;
let REG_A4 = 4;
let REG_A5 = 5;
let REG_A6 = 6;
let REG_A7 = 7; // SP
