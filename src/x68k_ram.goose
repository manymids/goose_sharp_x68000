// 12 MB main RAM. One array for the process. Callers index it; they do not
// take the array by value (that would copy it).

var g_x68k_ram: u8[12582912] = [0; 12582912];
// C starts at 2 MB. c_mem_set_ram_mb writes this through the bound pointer.
var g_ram_limit: i32 = 2097152;

fn x68k_ram_limit() -> i32 {
    return g_ram_limit;
}

fn x68k_ram_in(off: i32) -> bool {
    return off >= 0 && off < g_ram_limit && off < 12582912;
}

fn x68k_ram_read(off: i32) -> u8 {
    if !x68k_ram_in(off) { return 0; }
    return g_x68k_ram[off as i64];
}

fn x68k_ram_write(off: i32, val: u8) {
    if !x68k_ram_in(off) { return; }
    g_x68k_ram[off as i64] = val;
}

fn x68k_ram_read16(off: i32) -> u16 {
    if off >= 0 && off + 1 < g_ram_limit && off + 1 < 12582912 {
        let hi: u16 = g_x68k_ram[off as i64];
        let lo: u16 = g_x68k_ram[(off + 1) as i64];
        return (hi << 8) | lo;
    }
    let hi: u16 = x68k_ram_read(off);
    let lo: u16 = x68k_ram_read(off + 1);
    return (hi << 8) | lo;
}

fn x68k_ram_write16(off: i32, val: u16) {
    if off >= 0 && off + 1 < g_ram_limit && off + 1 < 12582912 {
        g_x68k_ram[off as i64] = (val >> 8) as! u8;
        g_x68k_ram[(off + 1) as i64] = (val & 0xFF) as u8;
        return;
    }
    x68k_ram_write(off, (val >> 8) as! u8);
    x68k_ram_write(off + 1, (val & 0xFF) as u8);
}

fn x68k_ram_read32(off: i32) -> u32 {
    if off >= 0 && off + 3 < g_ram_limit && off + 3 < 12582912 {
        let b0: u32 = g_x68k_ram[off as i64];
        let b1: u32 = g_x68k_ram[(off + 1) as i64];
        let b2: u32 = g_x68k_ram[(off + 2) as i64];
        let b3: u32 = g_x68k_ram[(off + 3) as i64];
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
    }
    let b0: u32 = x68k_ram_read(off);
    let b1: u32 = x68k_ram_read(off + 1);
    let b2: u32 = x68k_ram_read(off + 2);
    let b3: u32 = x68k_ram_read(off + 3);
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
}

fn x68k_ram_write32(off: i32, val: u32) {
    if off >= 0 && off + 3 < g_ram_limit && off + 3 < 12582912 {
        g_x68k_ram[off as i64] = (val >> 24) as! u8;
        g_x68k_ram[(off + 1) as i64] = (val >> 16) as! u8;
        g_x68k_ram[(off + 2) as i64] = (val >> 8) as! u8;
        g_x68k_ram[(off + 3) as i64] = (val & 0xFF) as u8;
        return;
    }
    x68k_ram_write(off, (val >> 24) as! u8);
    x68k_ram_write(off + 1, (val >> 16) as! u8);
    x68k_ram_write(off + 2, (val >> 8) as! u8);
    x68k_ram_write(off + 3, (val & 0xFF) as u8);
}
