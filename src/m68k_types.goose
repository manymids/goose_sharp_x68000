// Motorola 68000 & Sharp X68000 基本定数・型定義

// フレームバッファの既定（main と c_set_screen_mode の 768x512）
let X68K_SCREEN_W = 768;
let X68K_SCREEN_H = 512;
let X68K_PIXELS = 768 * 512;

// CPU クロック周波数 (10MHz)
let X68K_CPU_FREQ = 10000000;
let X68K_CYCLES_PER_FRAME = 266666; // 16MHz (XVI Mode) / 60 FPS

// M68000 SR (Status Register) フラグビット
let SR_C = 0x0001; // Carry
let SR_V = 0x0002; // Overflow
let SR_Z = 0x0004; // Zero
let SR_N = 0x0008; // Negative
let SR_X = 0x0010; // Extend
let SR_I = 0x0700; // Interrupt Mask (3 bits: 8-10)
let SR_M = 0x1000; // Master/Interrupt
let SR_S = 0x2000; // Supervisor Mode
let SR_T = 0x8000; // Trace Mode

// レジスタインデックス (D0-D7: 0-7, A0-A7: 0-7)
let REG_D0 = 0;
let REG_D1 = 1;
let REG_D2 = 2;
let REG_D3 = 3;
let REG_D4 = 4;
let REG_D5 = 5;
let REG_D6 = 6;
let REG_D7 = 7;
let REG_A0 = 0;
let REG_A1 = 1;
let REG_A2 = 2;
let REG_A3 = 3;
let REG_A4 = 4;
let REG_A5 = 5;
let REG_A6 = 6;
let REG_A7 = 7; // SP
let REG_SP = 7;
