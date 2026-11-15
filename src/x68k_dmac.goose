// Sharp X68000 の DMA コントローラ (HD63450 / DMAC)

// ch0 は FDC、ch1 は SASI、ch2 は汎用、ch3 は ADPCM。
// ここにあるのはレジスタと割り込みだけで、MMU は知らない。DMAC はバスマスタなので転送は
// MMU の読み書きを通る: ch0 (FDC) は m68k_mmu の fdc_dma、ch1–3 は x68k_dma_bus にある。

import .x68k_bridge;
import .x68k_ram;
namespace dmac;

struct X68kDMAChannel {
    csr: u8 = 0,
    cer: u8 = 0,
    dcr: u8 = 0,
    ocr: u8 = 0,
    scr: u8 = 0,
    ccr: u8 = 0,
    mtc: u16 = 0,
    mar: u32 = 0,
    dar: u32 = 0,
    btc: u16 = 0,
    bar: u32 = 0,
    niv: u8 = 0,
    eiv: u8 = 0,
    mfc: u8 = 0,
    cpr: u8 = 0,
    dfc: u8 = 0,
    bfc: u8 = 0,
    gcr: u8 = 0,
}
type ::X68kDMAChannel = dmac::X68kDMAChannel;

struct X68kDMAC {
    ch: X68kDMAChannel[4] = [X68kDMAChannel {}; 4],
    int_ch: i32 = 0,
    int_pending: bool = false,
    last_int: i32 = 0,
    adpcm_vec: i32 = -1, // ch3 が要求している割り込みのベクタ。-1 は要求なし
}
type ::X68kDMAC = dmac::X68kDMAC;

fn init(dmac: X68kDMAC&) {
    dmac = X68kDMAC {};
}

fn in_ram(addr: u32, nbytes: u32) -> bool {
    let lim = x68k_ram_limit() as u32;
    if addr >= lim { return false; }
    return addr + nbytes <= lim;
}

fn readmem24_dword(addr: u32) -> u32 {
    let a = addr & ADDR_MASK;
    if in_ram(a, 4) {
        return x68k_ram_read32(a as! i32);
    }
    return 0;
}

fn readmem24_word(addr: u32) -> u16 {
    let a = addr & ADDR_MASK;
    if in_ram(a, 2) {
        return x68k_ram_read16(a as! i32);
    }
    return 0;
}

// レジスタは 1 チャネル 64 バイト。24 bit アドレスの最上位バイト (0x0C, 0x14, 0x1C) は 0 が読める。
fn read(dmac: X68kDMAC&, addr: u32) -> u8 {
    if addr >= 0x00E84100 { return 0; }
    let ch = ((addr >> 6) & 0x03) as i32;
    let c .= dmac.ch[ch];
    match addr & 0x3F {
        0x00 => c.csr,
        0x01 => c.cer,
        0x04 => c.dcr,
        0x05 => c.ocr,
        0x06 => c.scr,
        0x07 => c.ccr,
        0x0A => (c.mtc >> 8) as! u8,
        0x0B => c.mtc as! u8,
        0x0D => (c.mar >> 16) as! u8,
        0x0E => (c.mar >> 8) as! u8,
        0x0F => c.mar as! u8,
        0x15 => (c.dar >> 16) as! u8,
        0x16 => (c.dar >> 8) as! u8,
        0x17 => c.dar as! u8,
        0x1A => (c.btc >> 8) as! u8,
        0x1B => c.btc as! u8,
        0x1D => (c.bar >> 16) as! u8,
        0x1E => (c.bar >> 8) as! u8,
        0x1F => c.bar as! u8,
        0x25 => c.niv,
        0x27 => c.eiv,
        0x29 => c.mfc,
        0x2D => c.cpr,
        0x31 => c.dfc,
        0x39 => c.bfc,
        0x3F => c.gcr,
        _ => 0,
    }
}

// CCR ($07): bit7 STR で転送開始、bit4 SAB で動作中の転送を中断する。
fn write_ccr(c: X68kDMAChannel&, data: u8) {
    let old = c.ccr;
    c.ccr = (data & 0xEF) | (old & 0x80);
    if (data & 0x10) != 0 && (old & 0x80) != 0 {
        // ソフトウェアアボート
        c.cer = 0x11;
        c.csr |= 0x10;
        c.csr &= 0xF7;
        c.ccr &= 0x7F;
        return;
    }
    if (data & 0x80) != 0 {
        // DMA 開始
        c.csr |= 0x08; // ACT bit
        c.cer = 0x00;
        if (c.ocr & 8) != 0 {
            // アレイ / リンクアレイのチェーン
            c.mar = readmem24_dword(c.bar) & ADDR_MASK;
            c.mtc = readmem24_word(c.bar + 4);
            if (c.ocr & 4) != 0 {
                c.bar = readmem24_dword(c.bar + 6) & ADDR_MASK;
            } else {
                c.bar += 6;
            }
        }
    }
}

fn write(dmac: X68kDMAC&, addr: u32, data: u8) {
    if addr >= 0x00E84100 { return; }
    let ch = ((addr >> 6) & 0x03) as i32;
    let c .= dmac.ch[ch];
    let d16: u16 = data;
    let d32: u32 = data;
    match addr & 0x3F {
        0x00 => { c.csr &= ~data | 0x09; }, // 1 を書いたビットを落とす。ACT と PCS は残る
        0x01 => { c.cer &= ~data; },
        0x04 => { c.dcr = data; },
        0x05 => { c.ocr = data; },
        0x06 => { c.scr = data; },
        0x07 => { c.write_ccr(data); },
        0x0A => { c.mtc = (c.mtc & 0x00FF) | (d16 << 8); },
        0x0B => { c.mtc = (c.mtc & 0xFF00) | d16; },
        0x0D => { c.mar = (c.mar & 0x0000FFFF) | (d32 << 16); },
        0x0E => { c.mar = (c.mar & 0x00FF00FF) | (d32 << 8); },
        0x0F => { c.mar = (c.mar & 0x00FFFF00) | d32; },
        0x15 => { c.dar = (c.dar & 0x0000FFFF) | (d32 << 16); },
        0x16 => { c.dar = (c.dar & 0x00FF00FF) | (d32 << 8); },
        0x17 => { c.dar = (c.dar & 0x00FFFF00) | d32; },
        0x1A => { c.btc = (c.btc & 0x00FF) | (d16 << 8); },
        0x1B => { c.btc = (c.btc & 0xFF00) | d16; },
        0x1D => { c.bar = (c.bar & 0x0000FFFF) | (d32 << 16); },
        0x1E => { c.bar = (c.bar & 0x00FF00FF) | (d32 << 8); },
        0x1F => { c.bar = (c.bar & 0x00FFFF00) | d32; },
        0x25 => { c.niv = data; },
        0x27 => { c.eiv = data; },
        0x29 => { c.mfc = data; },
        0x2D => { c.cpr = data; },
        0x31 => { c.dfc = data; },
        0x39 => { c.bfc = data; },
        0x3F => { if ch == 3 { c.gcr = data; } }, // GCR は ch3 にだけある
        _ => {},
    }
}

// 割り込み要求中の ch0–2 のうち、前回受け付けた次から巡回して最初のもの。なければ -1。
fn irq_channel(dmac: X68kDMAC&) -> i32 {
    if !dmac.int_pending { return -1; }
    let start = if dmac.last_int < 0 || dmac.last_int > 2 { 0 } else { dmac.last_int };
    for n: i32 in 3 {
        let i = (start + n) % 3;
        if (dmac.int_ch & (1 << i)) != 0 { return i; }
    }
    return -1;
}

// ch0–2 の完了ベクタ。ERR (CSR bit4) なら EIV、なければ NIV。消さない。
fn peek_irq(dmac: X68kDMAC&) -> i32 {
    let i = dmac.irq_channel();
    if i < 0 { return -1; }
    return if (dmac.ch[i].csr & 0x10) != 0 { dmac.ch[i].eiv } else { dmac.ch[i].niv };
}

fn ack_irq(dmac: X68kDMAC&) {
    let i = dmac.irq_channel();
    if i < 0 {
        dmac.int_pending = false;
        return;
    }
    dmac.int_ch &= ~(1 << i);
    dmac.last_int = i;
    if (dmac.int_ch & 7) == 0 { dmac.int_pending = false; }
}


// ch3 (ADPCM) の転送で使う、MMU を通らない読み出しと割り込み。転送そのものは x68k_dma_bus。

fn adpcm_mem_read(addr: u32) -> u8 {
    return x68k_ram_read((addr & ADDR_MASK) as! i32);
}

fn adpcm_mem_read16(addr: u32) -> u16 {
    return ((adpcm_mem_read(addr) as u16) << 8) | adpcm_mem_read(addr + 1);
}

fn adpcm_mem_read32(addr: u32) -> u32 {
    return ((adpcm_mem_read16(addr) as u32) << 16) | adpcm_mem_read16(addr + 2);
}

// 完了 / エラーの割り込み。CCR の INT が立っていれば、ERR なら EIV、なければ NIV を要求する。
fn adpcm_raise(dmac: X68kDMAC&) {
    let c .= dmac.ch[3];
    if (c.ccr & 0x08) == 0 { return; }
    let vec: i32 = if (c.csr & 0x10) != 0 { c.eiv } else { c.niv };
    if vec > 0 { dmac.adpcm_vec = vec; }
}

// 番地レジスタを 24 ビットの範囲で進める / 戻す。
fn step24(addr: u32, up: bool, down: bool, step: u32) -> u32 {
    if up { return (addr + step) & ADDR_MASK; }
    if down { return ((addr & ADDR_MASK) + 0x1000000 - step) & ADDR_MASK; }
    return addr;
}

