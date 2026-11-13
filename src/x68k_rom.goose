// IPL ROM (128 KB), CGROM (768 KB), and SRAM (16 KB). One array each
// for the process. Callers index them. Passing an array by value would copy it.
// SRAM bytes 8-11 are the RAM-size stamp, written by C through the bound pointer.

let IPL_BYTES = 131072;   // 128 KB
let CGROM_BYTES = 786432; // 768 KB
let SRAM_BYTES = 16384;   // 16 KB

var g_iplrom: u8[IPL_BYTES] = [0; IPL_BYTES];
var g_cgrom: u8[CGROM_BYTES] = [0; CGROM_BYTES];
var g_sram: u8[SRAM_BYTES] = [0; SRAM_BYTES];
var g_sram_we: i32 = 0;

fn x68k_sram_set_write_enable(enable: i32) {
    if enable != 0 { g_sram_we = 1; } else { g_sram_we = 0; }
}

fn x68k_sram_write_enable() -> i32 {
    return g_sram_we;
}

fn x68k_sram_read(off: i32) -> u8 {
    if off < 0 || off >= SRAM_BYTES { return 0; }
    return g_sram[off as i64];
}

fn x68k_sram_write(off: i32, val: u8) {
    if g_sram_we == 0 { return; }
    if off < 0 || off >= SRAM_BYTES { return; }
    g_sram[off as i64] = val;
}

fn x68k_ipl_read(off: i32) -> u8 {
    if off < 0 || off >= IPL_BYTES { return 0; }
    return g_iplrom[off as i64];
}

fn x68k_cgrom_read(off: i32) -> u8 {
    if off < 0 || off >= CGROM_BYTES { return 0; }
    return g_cgrom[off as i64];
}
