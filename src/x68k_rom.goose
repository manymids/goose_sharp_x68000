// IPL ROM (128 KB), CGROM (768 KB), and SRAM (16 KB). One array each
// for the process. Callers index them. Passing an array by value would copy it.
// SRAM bytes 8-11 are the RAM-size stamp, written by C through the bound pointer.

import .x68k_bridge;

var g_iplrom: u8[131072] = [0; 131072];
var g_cgrom: u8[786432] = [0; 786432];
var g_sram: u8[16384] = [0; 16384];
var g_sram_we: i32 = 0;

fn x68k_rom_bind() {
    c_ipl_bind(g_iplrom[0]);
    c_cgrom_bind(g_cgrom[0]);
    c_sram_bind(g_sram[0]);
}

fn x68k_sram_set_write_enable(enable: i32) {
    if enable != 0 { g_sram_we = 1; } else { g_sram_we = 0; }
}

fn x68k_sram_write_enable() -> i32 {
    return g_sram_we;
}

fn x68k_sram_read(off: i32) -> u8 {
    if off < 0 || off >= 16384 { return 0; }
    return g_sram[off as i64];
}

fn x68k_sram_write(off: i32, val: u8) {
    if g_sram_we == 0 { return; }
    if off < 0 || off >= 16384 { return; }
    g_sram[off as i64] = val;
}

fn x68k_ipl_read(off: i32) -> u8 {
    if off < 0 || off >= 131072 { return 0; }
    return g_iplrom[off as i64];
}

fn x68k_cgrom_read(off: i32) -> u8 {
    if off < 0 || off >= 786432 { return 0; }
    return g_cgrom[off as i64];
}
