// Sharp X68000 DMAコントローラ (HD63450 / DMAC) in Goose
// ※実機 ROM / ブートセクタ自走用

// ch0 は FDC、ch1 は SASI、ch2 は汎用、ch3 は ADPCM。
// DMAC はバスマスタなので、転送は MMU の読み書きを通る。MMU の側も、DMAC と FDC の
// レジスタに書かれたときにここの転送を呼ぶ。そのため m68k_mmu とは互いを import している。

import .x68k_bridge;
import .x68k_fdc;
import .x68k_ram;
import .x68k_sasi;
import .x68k_adpcm;
import .m68k_mmu;
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
        // Software Abort
        c.cer = 0x11;
        c.csr |= 0x10;
        c.csr &= 0xF7;
        c.ccr &= 0x7F;
        return;
    }
    if (data & 0x80) != 0 {
        // Start DMA
        c.csr |= 0x08; // ACT bit
        c.cer = 0x00;
        if (c.ocr & 8) != 0 {
            // Array/Link Array Chain
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

// FDC と DMAC Ch 0 の DMA 転送実行。
// px68k の dma_writemem24 は wm_main 経由なので、GVRAM / TVRAM も CPU と同じ書き込みになる。
fn exec_fdc(dmac: X68kDMAC&, fdc: X68kFDC&, mmu: M68kMMU&) -> bool {
    // Ch 0 が動作中 (ACT = bit 3) かチェック
    if (dmac.ch[0].csr & 0x08) == 0 {
        return false;
    }
    if fdc.exec_len() <= 0 {
        return false;
    }

    // 1 セクタ転送するたびに FDC_NextTrack。MTC が残っていれば次セクタも続ける。
    while (dmac.ch[0].csr & 0x08) != 0 && fdc.exec_len() > 0 {
        // WriteData 実行中はメモリ → FDC。OCR bit7 (デバイス → メモリ) が立っていれば方向が合わない。
        let to_disk = fdc.is_writing();
        if to_disk && (dmac.ch[0].ocr & 0x80) != 0 {
            return false;
        }
        for i in fdc.exec_len() {
            let addr = dmac.ch[0].mar & ADDR_MASK;
            let b = fdc.data_buf[i];
            if to_disk {
                fdc.data_buf[i] = mmu.read8(addr);
            } else if in_ram(addr, 1) {
                x68k_ram_write(addr as! i32, b);
            } else if addr >= 0xC00000 && addr < 0xE00000 {
                mmu.gvram_cpu_write((addr - 0xC00000) as! i32, b, mmu.crtc_regs[0x28]);
            } else if addr >= 0xE00000 && addr < 0xE80000 {
                let off = (addr - 0xE00000) as! i32;
                mmu.write_tvram_access(off, b, mmu.crtc_regs[0x2A], mmu.crtc_regs[0x2B], mmu.crtc_regs[0x2E], mmu.crtc_regs[0x2F]);
            }
            if (dmac.ch[0].scr & 8) != 0 {
                dmac.ch[0].mar--;
            } else {
                dmac.ch[0].mar++;
            }
        }

        // MTC の減算（ワード転送の場合は セクタ長 / 2、バイト転送の場合はセクタ長）
        let size_code = (dmac.ch[0].ocr >> 4) & 3;
        let units = if size_code == 1 { (fdc.exec_len() / 2) as! u16 } else { fdc.exec_len() as! u16 };
        if dmac.ch[0].mtc >= units {
            dmac.ch[0].mtc -= units;
        } else {
            dmac.ch[0].mtc = 0;
        }

        if dmac.ch[0].mtc == 0 {
            if (dmac.ch[0].ocr & 8) != 0 {
                // Next block in chain
                if (dmac.ch[0].ocr & 4) != 0 {
                    if dmac.ch[0].bar != 0 {
                        dmac.ch[0].mar = readmem24_dword(dmac.ch[0].bar) & ADDR_MASK;
                        dmac.ch[0].mtc = readmem24_word(dmac.ch[0].bar + 4);
                        dmac.ch[0].bar = readmem24_dword(dmac.ch[0].bar + 6) & ADDR_MASK;
                    }
                } else {
                    if dmac.ch[0].btc > 0 {
                        dmac.ch[0].btc--;
                        if dmac.ch[0].btc != 0 {
                            dmac.ch[0].mar = readmem24_dword(dmac.ch[0].bar) & ADDR_MASK;
                            dmac.ch[0].mtc = readmem24_word(dmac.ch[0].bar + 4);
                            dmac.ch[0].bar += 6;
                        }
                    }
                }
            }
        }

        if dmac.ch[0].mtc == 0 {
            // DMAC 転送完了フラグ
            dmac.ch[0].csr |= 0x80; // COC (Channel Operation Complete)
            dmac.ch[0].csr &= 0xF7; // ACT = 0
            dmac.ch[0].ccr &= 0x7F; // STR = 0
            // px68k DMAINT。CCR bit3 が許可のときだけ。ch3 は C 側の経路のまま。
            if (dmac.ch[0].ccr & 0x08) != 0 {
                dmac.int_ch |= 1;
                dmac.int_pending = true;
            }
        }

        if to_disk {
            // 転送カウンタが尽きたら TC。残っていれば次のセクタを待つ。
            fdc.write_buffer(dmac.ch[0].mtc == 0);
        } else {
            fdc.next_track();
        }
    }

    return true;
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

// ---------------------------------------------------------------
// ch1 (SASI) と ch2 (汎用)。CPU と同じバスを通るので、メモリの読み書きは MMU 経由。
// ---------------------------------------------------------------

fn bump(addr: u32&, scr: u8, plus_mask: u8, minus_mask: u8, step: u32) {
    if (scr & plus_mask) != 0 {
        addr += step;
    } else if (scr & minus_mask) != 0 {
        addr -= step;
    }
}

// SASI は DMAC ch1。px68k DMA_Exec(1) が 0xE96001 をメモリ空間として読む。
fn pump_sasi(mmu: M68kMMU&) {
    if (mmu.dmac.ch[1].csr & 0x08) == 0 { return; }
    if (mmu.dmac.ch[1].ccr & 0x20) != 0 { return; }
    if (mmu.dmac.ch[1].csr & 0x80) != 0 { return; }
    let ocr = mmu.dmac.ch[1].ocr;
    let scr = mmu.dmac.ch[1].scr;
    let kind = ((ocr >> 4) & 3) + ((mmu.dmac.ch[1].dcr >> 1) & 4);
    while (mmu.dmac.ch[1].csr & 0x08) != 0 && (mmu.dmac.ch[1].csr & 0x80) == 0 && mmu.dmac.ch[1].mtc != 0 && mmu.sasi.is_ready() {
        let dev_to_mem = (ocr & 0x80) != 0;
        var src = if dev_to_mem { mmu.dmac.ch[1].dar } else { mmu.dmac.ch[1].mar };
        var dst = if dev_to_mem { mmu.dmac.ch[1].mar } else { mmu.dmac.ch[1].dar };
        var n = 1;
        var step = 1;
        if kind == 1 { n = 2; }
        if kind == 2 { n = 4; }
        if kind == 5 { n = 1; step = 2; }
        if kind == 6 { n = 1; step = 4; }
        for i in n {
            if step == 2 {
                let w = mmu.read16(src);
                mmu.write16(dst, w);
            } else if step == 4 {
                let w = mmu.read32(src);
                mmu.write32(dst, w);
            } else {
                let b = mmu.read8(src);
                mmu.write8(dst, b);
            }
            if dev_to_mem {
                bump(dst, scr, 4, 8, step as u32);
                bump(src, scr, 1, 2, if kind == 4 { step as u32 } else { (step * 2) as u32 });
            } else {
                bump(src, scr, 4, 8, step as u32);
                bump(dst, scr, 1, 2, if kind == 4 { step as u32 } else { (step * 2) as u32 });
            }
            if dev_to_mem {
                mmu.dmac.ch[1].mar = dst;
                mmu.dmac.ch[1].dar = src;
            } else {
                mmu.dmac.ch[1].mar = src;
                mmu.dmac.ch[1].dar = dst;
            }
        }
        if mmu.dmac.ch[1].mtc != 0 {
            mmu.dmac.ch[1].mtc -= 1;
        }
        if mmu.dmac.ch[1].mtc == 0 {
            mmu.dmac.ch[1].csr |= 0x80;
            mmu.dmac.ch[1].csr &= 0xF7;
            if (mmu.dmac.ch[1].ccr & 0x08) != 0 {
                mmu.dmac.int_ch |= 2;
                mmu.dmac.int_pending = true;
            }
        }
    }
}

fn ch2_fail(mmu: M68kMMU&, err: u8) {
    mmu.dmac.ch[2].cer = err;
    mmu.dmac.ch[2].csr |= 0x10;
    mmu.dmac.ch[2].csr &= 0xF7;
    mmu.dmac.ch[2].ccr &= 0x7F;
    if (mmu.dmac.ch[2].ccr & 0x08) != 0 {
        mmu.dmac.int_ch |= 4;
        mmu.dmac.int_pending = true;
    }
}

fn ch2_raise(mmu: M68kMMU&) {
    if (mmu.dmac.ch[2].ccr & 0x08) != 0 {
        mmu.dmac.int_ch |= 4;
        mmu.dmac.int_pending = true;
    }
}

// px68k DMA_Exec(2)。沙羅曼蛇はスプライト 1024 バイトを ch2 のバーストで $EB0000 へ書く。
// OCR&3==2 は Mercury の Ready 待ちなので、ここでは動かさない。
fn ch2_unit(mmu: M68kMMU&) -> i32 {
    let ocr = mmu.dmac.ch[2].ocr;
    let scr = mmu.dmac.ch[2].scr;
    let kind = ((ocr >> 4) & 3) + ((mmu.dmac.ch[2].dcr >> 1) & 4);
    let dev_to_mem = (ocr & 0x80) != 0;
    var n: i32 = 1;
    var mar_step: u32 = 1;
    var dar_step: u32 = 1;
    var width: i32 = 1;
    if kind == 0 || kind == 3 {
        dar_step = 2;
    } else if kind == 1 {
        n = 2;
        dar_step = 2;
    } else if kind == 2 {
        n = 4;
        dar_step = 2;
    } else if kind == 4 {
        dar_step = 1;
    } else if kind == 5 {
        mar_step = 2;
        dar_step = 2;
        width = 2;
    } else if kind == 6 {
        mar_step = 4;
        dar_step = 4;
        width = 4;
    } else {
        return 0;
    }
    for i: i32 in n {
        var src = mmu.dmac.ch[2].mar;
        var dst = mmu.dmac.ch[2].dar;
        if dev_to_mem {
            src = mmu.dmac.ch[2].dar;
            dst = mmu.dmac.ch[2].mar;
        }
        if width != 1 && ((src & 1) != 0 || (dst & 1) != 0) {
            var err: u8 = 0x05;
            if (src & 1) != 0 {
                if dev_to_mem { err = 0x06; }
            } else if dev_to_mem {
                err = 0x05;
            } else {
                err = 0x06;
            }
            ch2_fail(mmu, err);
            return 1;
        }
        if width == 4 {
            let w = mmu.read32(src);
            mmu.write32(dst, w);
        } else if width == 2 {
            let w = mmu.read16(src);
            mmu.write16(dst, w);
        } else {
            let b = mmu.read8(src);
            mmu.write8(dst, b);
        }
        bump(mmu.dmac.ch[2].mar, scr, 4, 8, mar_step);
        bump(mmu.dmac.ch[2].dar, scr, 1, 2, dar_step);
    }
    return 0;
}

fn ch2_on_zero(mmu: M68kMMU&) {
    let ocr = mmu.dmac.ch[2].ocr;
    if (ocr & 8) != 0 {
        if (ocr & 4) != 0 {
            if mmu.dmac.ch[2].bar != 0 {
                let bar = mmu.dmac.ch[2].bar;
                mmu.dmac.ch[2].mar = mmu.read32(bar) & ADDR_MASK;
                mmu.dmac.ch[2].mtc = mmu.read16(bar + 4);
                mmu.dmac.ch[2].bar = mmu.read32(bar + 6) & ADDR_MASK;
                if mmu.dmac.ch[2].mtc == 0 { ch2_fail(mmu, 0x0D); }
            }
        } else {
            mmu.dmac.ch[2].btc -= 1;
            if mmu.dmac.ch[2].btc != 0 {
                let bar = mmu.dmac.ch[2].bar;
                mmu.dmac.ch[2].mar = mmu.read32(bar) & ADDR_MASK;
                mmu.dmac.ch[2].mtc = mmu.read16(bar + 4);
                mmu.dmac.ch[2].bar = bar + 6;
                if mmu.dmac.ch[2].mtc == 0 { ch2_fail(mmu, 0x0D); }
            }
        }
    } else if (mmu.dmac.ch[2].ccr & 0x40) != 0 {
        mmu.dmac.ch[2].csr |= 0x40;
        ch2_raise(mmu);
        if mmu.dmac.ch[2].bar != 0 {
            mmu.dmac.ch[2].mar = mmu.dmac.ch[2].bar;
            mmu.dmac.ch[2].mtc = mmu.dmac.ch[2].btc;
            mmu.dmac.ch[2].csr |= 0x08;
            mmu.dmac.ch[2].bar = 0;
            mmu.dmac.ch[2].btc = 0;
            mmu.dmac.ch[2].ccr &= 0xBF;
            if mmu.dmac.ch[2].mtc == 0 { ch2_fail(mmu, 0x0D); }
        }
    }
    if mmu.dmac.ch[2].mtc == 0 && (mmu.dmac.ch[2].csr & 0x10) == 0 {
        mmu.dmac.ch[2].csr |= 0x80;
        mmu.dmac.ch[2].csr &= 0xF7;
        ch2_raise(mmu);
    }
}

fn exec_ch2(mmu: M68kMMU&) {
    if (mmu.dmac.ch[2].ocr & 3) == 2 { return; }
    var left: i32 = 65536;
    while left > 0 && (mmu.dmac.ch[2].csr & 0x08) != 0 && (mmu.dmac.ch[2].ccr & 0x20) == 0 && (mmu.dmac.ch[2].csr & 0x80) == 0 && mmu.dmac.ch[2].mtc != 0 {
        left -= 1;
        if ch2_unit(mmu) != 0 { return; }
        if mmu.dmac.ch[2].mtc != 0 {
            mmu.dmac.ch[2].mtc -= 1;
        }
        if mmu.dmac.ch[2].mtc == 0 {
            ch2_on_zero(mmu);
        }
        if (mmu.dmac.ch[2].ocr & 3) != 1 { return; }
    }
}

// ---------------------------------------------------------------
// ch3 (ADPCM)。px68k の DMA_Exec を、メモリから $E92003 へ流す使い方に必要なぶんだけ移したもの。
// ADPCM がデータを欲しがったときに呼ばれ、MTC が尽きるか 1 回ぶん送るまで進める。
// メモリの読み書きは RAM だけを見る (I/O へは ADPCM のポート以外書かない)。
// ---------------------------------------------------------------

fn adpcm_mem_read(addr: u32) -> u8 {
    return x68k_ram_read((addr & ADDR_MASK) as! i32);
}

fn adpcm_mem_read16(addr: u32) -> u16 {
    return ((adpcm_mem_read(addr) as u16) << 8) | adpcm_mem_read(addr + 1);
}

fn adpcm_mem_read32(addr: u32) -> u32 {
    return ((adpcm_mem_read16(addr) as u32) << 16) | adpcm_mem_read16(addr + 2);
}

fn adpcm_port_write(mmu: M68kMMU&, addr: u32, val: u8) {
    let a = addr & ADDR_MASK;
    if (a & 0xFFFFFC) == 0xE92000 { mmu.adpcm.write(a, val); }
    else { x68k_ram_write(a as! i32, val); }
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

// MTC が 0 になったあとの続き方。まだ送るものがあれば true。
fn adpcm_next_block(mmu: M68kMMU&) -> bool {
    let c .= mmu.dmac.ch[3];
    if (c.ocr & 8) != 0 {
        // チェーン: BAR の指す表から次の番地と長さを読む
        if (c.ocr & 4) != 0 {
            // リンクアレイ: 表の各項が次の項の番地を持つ
            if c.bar != 0 {
                let entry = c.bar;
                c.mar = adpcm_mem_read32(entry) & ADDR_MASK;
                c.mtc = adpcm_mem_read16(entry + 4);
                c.bar = adpcm_mem_read32(entry + 6) & ADDR_MASK;
                if c.mtc == 0 { return false; }
            }
        } else if c.btc != 0 {
            // アレイ: 表の項が BTC 個並んでいる
            c.btc -= 1;
            if c.btc != 0 {
                c.mar = adpcm_mem_read32(c.bar) & ADDR_MASK;
                c.mtc = adpcm_mem_read16(c.bar + 4);
                c.bar = (c.bar + 6) & ADDR_MASK;
                if c.mtc == 0 { return false; }
            }
        }
    } else if (c.ccr & 0x40) != 0 {
        // コンティニュー: BAR / BTC に用意してあった次のブロックへ移る
        c.csr |= 0x40;
        adpcm_raise(mmu.dmac);
        if c.bar != 0 {
            c.mar = c.bar & ADDR_MASK;
            c.mtc = c.btc;
            c.csr |= 0x08;
            c.bar = 0;
            c.btc = 0;
            c.ccr &= 0xBF;
        }
    }
    if c.mtc == 0 {
        // すべて送り終えた: 完了を立てて、動作中を落とす
        c.csr |= 0x80;
        c.csr &= 0xF7;
        adpcm_raise(mmu.dmac);
    }
    return true;
}

fn exec_adpcm(mmu: M68kMMU&) {
    let c .= mmu.dmac.ch[3];
    var rounds = 0;
    while (c.csr & 0x08) != 0 && (c.ccr & 0x20) == 0 && (c.csr & 0x80) == 0 && c.mtc != 0 && rounds < 65536 {
        rounds += 1;
        let mem_to_dev = (c.ocr & 0x80) == 0;
        // オペランドの大きさ (OCR) とデバイスのポート幅 (DCR) の組み合わせ
        let kind: i32 = ((c.ocr >> 4) & 3) + ((c.dcr >> 1) & 4);
        var ops: i32 = 1;      // 1 回の転送で何回読み書きするか
        var mem_step: u32 = 1;
        var dev_step: u32 = 2;
        var width: u32 = 1;    // 1 回に読み書きするバイト数
        if kind == 1 { ops = 2; }
        else if kind == 2 { ops = 4; }
        else if kind == 4 || kind == 7 { dev_step = 1; }
        else if kind == 5 { mem_step = 2; width = 2; }
        else if kind == 6 { mem_step = 4; dev_step = 4; width = 4; }

        for _ in ops {
            let from = if mem_to_dev { c.mar } else { c.dar };
            let to = if mem_to_dev { c.dar } else { c.mar };
            for i: u32 in width { adpcm_port_write(mmu, to + i, adpcm_mem_read(from + i)); }
            c.mar = step24(c.mar, (c.scr & 4) != 0, (c.scr & 8) != 0, mem_step);
            c.dar = step24(c.dar, (c.scr & 1) != 0, (c.scr & 2) != 0, dev_step);
        }

        c.mtc -= 1;
        if c.mtc == 0 && !adpcm_next_block(mmu) { break; }
        // 1 回の要求で 1 単位だけ送るモードでなければ、ここで止まる
        if (c.ocr & 3) != 1 { break; }
    }
}
