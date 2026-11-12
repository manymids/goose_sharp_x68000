// Motorola 68000 & Sharp X68000 基本定数・型定義

// M68000 SR (Status Register) フラグビット
let SR_C = 0x0001; // Carry
let SR_V = 0x0002; // Overflow
let SR_Z = 0x0004; // Zero
let SR_N = 0x0008; // Negative
let SR_X = 0x0010; // Extend
let SR_S = 0x2000; // Supervisor Mode
let SR_T = 0x8000; // Trace Mode

// アドレスレジスタのインデックス (cpu.a[])
let REG_A0 = 0;
let REG_A1 = 1;
let REG_A2 = 2;
let REG_A3 = 3;
let REG_A4 = 4;
let REG_A5 = 5;
let REG_A6 = 6;
let REG_A7 = 7; // SP
