// 12 MB のメイン RAM。プロセスで 1 つの配列。呼ぶ側は添字で使い、
// 配列を値で受け取らない (受け取ると写しができる)。

let RAM_BYTES = 12582912; // 12 MB

var g_x68k_ram: u8[RAM_BYTES] = [0; RAM_BYTES];
// C は 2 MB から始める。c_mem_set_ram_mb が結び付けたポインタを通して書く。
var g_ram_limit: i32 = 2097152;

fn x68k_ram_limit() -> i32 {
    return g_ram_limit;
}

// 添字は i64 に広げてから範囲を確かめる。i32 のまま off + 1 のように計算すると、桁あふれの
// 可能性が残ってコンパイラが境界検査を外せない (goose check --bce-lines で確認できる)。

fn x68k_ram_in(off: i32) -> bool {
    return off >= 0 && off < g_ram_limit && off < RAM_BYTES;
}

checkfree fn x68k_ram_read(off: i32) -> u8 {
    let o: i64 = off;
    if o < 0 || o >= g_ram_limit || o >= RAM_BYTES { return 0; }
    return g_x68k_ram[o];
}

checkfree fn x68k_ram_write(off: i32, val: u8) {
    let o: i64 = off;
    if o < 0 || o >= g_ram_limit || o >= RAM_BYTES { return; }
    g_x68k_ram[o] = val;
}

// 2 バイトとも RAM の中なら直接読む。端をまたぐときは 1 バイトずつ (範囲外は 0)。
checkfree fn x68k_ram_read16(off: i32) -> u16 {
    let o: i64 = off;
    if o >= 0 && o + 1 < g_ram_limit && o + 1 < RAM_BYTES {
        let hi: u16 = g_x68k_ram[o];
        let lo: u16 = g_x68k_ram[o + 1];
        return (hi << 8) | lo;
    }
    let hi: u16 = x68k_ram_read(off);
    let lo: u16 = x68k_ram_read(off + 1);
    return (hi << 8) | lo;
}

checkfree fn x68k_ram_write16(off: i32, val: u16) {
    let o: i64 = off;
    if o >= 0 && o + 1 < g_ram_limit && o + 1 < RAM_BYTES {
        g_x68k_ram[o] = (val >> 8) as! u8;
        g_x68k_ram[o + 1] = (val & 0xFF) as u8;
        return;
    }
    x68k_ram_write(off, (val >> 8) as! u8);
    x68k_ram_write(off + 1, (val & 0xFF) as u8);
}

checkfree fn x68k_ram_read32(off: i32) -> u32 {
    let o: i64 = off;
    if o >= 0 && o + 3 < g_ram_limit && o + 3 < RAM_BYTES {
        let b0: u32 = g_x68k_ram[o];
        let b1: u32 = g_x68k_ram[o + 1];
        let b2: u32 = g_x68k_ram[o + 2];
        let b3: u32 = g_x68k_ram[o + 3];
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
    }
    let b0: u32 = x68k_ram_read(off);
    let b1: u32 = x68k_ram_read(off + 1);
    let b2: u32 = x68k_ram_read(off + 2);
    let b3: u32 = x68k_ram_read(off + 3);
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
}

checkfree fn x68k_ram_write32(off: i32, val: u32) {
    let o: i64 = off;
    if o >= 0 && o + 3 < g_ram_limit && o + 3 < RAM_BYTES {
        g_x68k_ram[o] = (val >> 24) as! u8;
        g_x68k_ram[o + 1] = (val >> 16) as! u8;
        g_x68k_ram[o + 2] = (val >> 8) as! u8;
        g_x68k_ram[o + 3] = (val & 0xFF) as u8;
        return;
    }
    x68k_ram_write(off, (val >> 24) as! u8);
    x68k_ram_write(off + 1, (val >> 16) as! u8);
    x68k_ram_write(off + 2, (val >> 8) as! u8);
    x68k_ram_write(off + 3, (val & 0xFF) as u8);
}
