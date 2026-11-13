// Sharp X68000 DMAコントローラ (HD63450 / DMAC) in Goose
// ※実機 ROM / ブートセクタ自走用

// ch0 は FDC、ch1 は SASI、ch2 は汎用、ch3 は ADPCM。
// DMAC はバスマスタなので、転送は MMU の読み書きを通る。MMU の側も、DMAC と FDC の
// レジスタに書かれたときにここの転送を呼ぶ。そのため m68k_mmu とは互いを import している。

import .x68k_bridge;
import .x68k_fdc;
import .x68k_ram;
import .x68k_sasi;
import .m68k_mmu;

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

struct X68kDMAC {
    ch: X68kDMAChannel[4] = [X68kDMAChannel {}; 4],
    int_ch: i32 = 0,
    int_pending: bool = false,
    last_int: i32 = 0,
}

fn dmac_init(dmac: X68kDMAC&) {
    dmac = X68kDMAC {};
}

fn dma_in_ram(addr: u32, nbytes: u32) -> bool {
    let lim = x68k_ram_limit() as u32;
    if addr >= lim { return false; }
    return addr + nbytes <= lim;
}

fn dma_readmem24_dword(addr: u32) -> u32 {
    let a = addr & ADDR_MASK;
    if dma_in_ram(a, 4) {
        return x68k_ram_read32(a as! i32);
    }
    return 0;
}

fn dma_readmem24_word(addr: u32) -> u16 {
    let a = addr & ADDR_MASK;
    if dma_in_ram(a, 2) {
        return x68k_ram_read16(a as! i32);
    }
    return 0;
}

// レジスタは 1 チャネル 64 バイト。24 bit アドレスの最上位バイト (0x0C, 0x14, 0x1C) は 0 が読める。
fn dmac_read(dmac: X68kDMAC&, addr: u32) -> u8 {
    if addr >= 0x00E84100 { return 0; }
    let ch = ((addr >> 6) & 0x03) as i32;
    // ch3 は C 側 DMA[3] が進めた MTC/CSR を、読む前に Goose へ戻す。
    if ch == 3 { dmac_sound_pull(dmac); }
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
fn dmac_write_ccr(c: X68kDMAChannel&, data: u8) {
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
            c.mar = dma_readmem24_dword(c.bar) & ADDR_MASK;
            c.mtc = dma_readmem24_word(c.bar + 4);
            if (c.ocr & 4) != 0 {
                c.bar = dma_readmem24_dword(c.bar + 6) & ADDR_MASK;
            } else {
                c.bar += 6;
            }
        }
    }
}

fn dmac_write(dmac: X68kDMAC&, addr: u32, data: u8) {
    if addr >= 0x00E84100 { return; }
    let ch = ((addr >> 6) & 0x03) as i32;
    // 1 バイト書きで残りのカウンタを古い Goose 値のまま C へ戻さない。
    if ch == 3 { dmac_sound_pull(dmac); }
    let c .= dmac.ch[ch];
    let d16: u16 = data;
    let d32: u32 = data;
    match addr & 0x3F {
        0x00 => { c.csr &= ~data | 0x09; }, // 1 を書いたビットを落とす。ACT と PCS は残る
        0x01 => { c.cer &= ~data; },
        0x04 => { c.dcr = data; },
        0x05 => { c.ocr = data; },
        0x06 => { c.scr = data; },
        0x07 => { dmac_write_ccr(c, data); },
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
    if ch == 3 { dmac_sound_push(dmac); }
}

// FDC と DMAC Ch 0 の DMA 転送実行。
// px68k の dma_writemem24 は wm_main 経由なので、GVRAM / TVRAM も CPU と同じ書き込みになる。
fn dmac_exec_fdc(dmac: X68kDMAC&, fdc: X68kFDC&, mmu: M68kMMU&) -> bool {
    // Ch 0 が動作中 (ACT = bit 3) かチェック
    if (dmac.ch[0].csr & 0x08) == 0 {
        return false;
    }
    if fdc.buf_len <= 0 {
        return false;
    }

    // 1 セクタ転送するたびに FDC_NextTrack。MTC が残っていれば次セクタも続ける。
    while (dmac.ch[0].csr & 0x08) != 0 && fdc.buf_len > 0 {
        // WriteData 実行中はメモリ → FDC。OCR bit7 (デバイス → メモリ) が立っていれば方向が合わない。
        let to_disk = fdc.writing;
        if to_disk && (dmac.ch[0].ocr & 0x80) != 0 {
            return false;
        }
        for i in fdc.buf_len {
            let addr = dmac.ch[0].mar & ADDR_MASK;
            let b = fdc.data_buf[i];
            if to_disk {
                fdc.data_buf[i] = mmu_read8(mmu, addr);
            } else if dma_in_ram(addr, 1) {
                x68k_ram_write(addr as! i32, b);
            } else if addr >= 0xC00000 && addr < 0xE00000 {
                mmu_gvram_cpu_write(mmu, (addr - 0xC00000) as! i32, b, mmu.crtc_regs[0x28]);
            } else if addr >= 0xE00000 && addr < 0xE80000 {
                let off = (addr - 0xE00000) as! i32;
                mmu_write_tvram_access(mmu, off, b, mmu.crtc_regs[0x2A], mmu.crtc_regs[0x2B], mmu.crtc_regs[0x2E], mmu.crtc_regs[0x2F]);
            }
            if (dmac.ch[0].scr & 8) != 0 {
                dmac.ch[0].mar--;
            } else {
                dmac.ch[0].mar++;
            }
        }

        // MTC の減算（ワード転送の場合は buf_len / 2、バイト転送の場合は buf_len）
        let size_code = (dmac.ch[0].ocr >> 4) & 3;
        let units = if size_code == 1 { (fdc.buf_len / 2) as! u16 } else { fdc.buf_len as! u16 };
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
                        dmac.ch[0].mar = dma_readmem24_dword(dmac.ch[0].bar) & ADDR_MASK;
                        dmac.ch[0].mtc = dma_readmem24_word(dmac.ch[0].bar + 4);
                        dmac.ch[0].bar = dma_readmem24_dword(dmac.ch[0].bar + 6) & ADDR_MASK;
                    }
                } else {
                    if dmac.ch[0].btc > 0 {
                        dmac.ch[0].btc--;
                        if dmac.ch[0].btc != 0 {
                            dmac.ch[0].mar = dma_readmem24_dword(dmac.ch[0].bar) & ADDR_MASK;
                            dmac.ch[0].mtc = dma_readmem24_word(dmac.ch[0].bar + 4);
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
            fdc_write_buffer(fdc, dmac.ch[0].mtc == 0);
        } else {
            fdc_next_track(fdc);
        }
    }

    return true;
}

// 割り込み要求中の ch0–2 のうち、前回受け付けた次から巡回して最初のもの。なければ -1。
fn dmac_irq_channel(dmac: X68kDMAC&) -> i32 {
    if !dmac.int_pending { return -1; }
    let start = if dmac.last_int < 0 || dmac.last_int > 2 { 0 } else { dmac.last_int };
    for n: i32 in 3 {
        let i = (start + n) % 3;
        if (dmac.int_ch & (1 << i)) != 0 { return i; }
    }
    return -1;
}

// ch0–2 の完了ベクタ。ERR (CSR bit4) なら EIV、なければ NIV。消さない。
fn dmac_peek_irq(dmac: X68kDMAC&) -> i32 {
    let i = dmac_irq_channel(dmac);
    if i < 0 { return -1; }
    return if (dmac.ch[i].csr & 0x10) != 0 { dmac.ch[i].eiv } else { dmac.ch[i].niv };
}

fn dmac_ack_irq(dmac: X68kDMAC&) {
    let i = dmac_irq_channel(dmac);
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

fn dma_bump(addr: u32&, scr: u8, plus_mask: u8, minus_mask: u8, step: u32) {
    if (scr & plus_mask) != 0 {
        addr += step;
    } else if (scr & minus_mask) != 0 {
        addr -= step;
    }
}

// SASI は DMAC ch1。px68k DMA_Exec(1) が 0xE96001 をメモリ空間として読む。
fn dmac_pump_sasi(mmu: M68kMMU&) {
    if (mmu.dmac.ch[1].csr & 0x08) == 0 { return; }
    if (mmu.dmac.ch[1].ccr & 0x20) != 0 { return; }
    if (mmu.dmac.ch[1].csr & 0x80) != 0 { return; }
    let ocr = mmu.dmac.ch[1].ocr;
    let scr = mmu.dmac.ch[1].scr;
    let kind = ((ocr >> 4) & 3) + ((mmu.dmac.ch[1].dcr >> 1) & 4);
    while (mmu.dmac.ch[1].csr & 0x08) != 0 && (mmu.dmac.ch[1].csr & 0x80) == 0 && mmu.dmac.ch[1].mtc != 0 && sasi_is_ready(mmu.sasi) {
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
                let w = mmu_read16(mmu, src);
                mmu_write16(mmu, dst, w);
            } else if step == 4 {
                let w = mmu_read32(mmu, src);
                mmu_write32(mmu, dst, w);
            } else {
                let b = mmu_read8(mmu, src);
                mmu_write8(mmu, dst, b);
            }
            if dev_to_mem {
                dma_bump(dst, scr, 4, 8, step as u32);
                dma_bump(src, scr, 1, 2, if kind == 4 { step as u32 } else { (step * 2) as u32 });
            } else {
                dma_bump(src, scr, 4, 8, step as u32);
                dma_bump(dst, scr, 1, 2, if kind == 4 { step as u32 } else { (step * 2) as u32 });
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

fn dmac_ch2_fail(mmu: M68kMMU&, err: u8) {
    mmu.dmac.ch[2].cer = err;
    mmu.dmac.ch[2].csr |= 0x10;
    mmu.dmac.ch[2].csr &= 0xF7;
    mmu.dmac.ch[2].ccr &= 0x7F;
    if (mmu.dmac.ch[2].ccr & 0x08) != 0 {
        mmu.dmac.int_ch |= 4;
        mmu.dmac.int_pending = true;
    }
}

fn dmac_ch2_raise(mmu: M68kMMU&) {
    if (mmu.dmac.ch[2].ccr & 0x08) != 0 {
        mmu.dmac.int_ch |= 4;
        mmu.dmac.int_pending = true;
    }
}

// px68k DMA_Exec(2)。沙羅曼蛇はスプライト 1024 バイトを ch2 のバーストで $EB0000 へ書く。
// OCR&3==2 は Mercury の Ready 待ちなので、ここでは動かさない。
fn dmac_ch2_unit(mmu: M68kMMU&) -> i32 {
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
            dmac_ch2_fail(mmu, err);
            return 1;
        }
        if width == 4 {
            let w = mmu_read32(mmu, src);
            mmu_write32(mmu, dst, w);
        } else if width == 2 {
            let w = mmu_read16(mmu, src);
            mmu_write16(mmu, dst, w);
        } else {
            let b = mmu_read8(mmu, src);
            mmu_write8(mmu, dst, b);
        }
        dma_bump(mmu.dmac.ch[2].mar, scr, 4, 8, mar_step);
        dma_bump(mmu.dmac.ch[2].dar, scr, 1, 2, dar_step);
    }
    return 0;
}

fn dmac_ch2_on_zero(mmu: M68kMMU&) {
    let ocr = mmu.dmac.ch[2].ocr;
    if (ocr & 8) != 0 {
        if (ocr & 4) != 0 {
            if mmu.dmac.ch[2].bar != 0 {
                let bar = mmu.dmac.ch[2].bar;
                mmu.dmac.ch[2].mar = mmu_read32(mmu, bar) & ADDR_MASK;
                mmu.dmac.ch[2].mtc = mmu_read16(mmu, bar + 4);
                mmu.dmac.ch[2].bar = mmu_read32(mmu, bar + 6) & ADDR_MASK;
                if mmu.dmac.ch[2].mtc == 0 { dmac_ch2_fail(mmu, 0x0D); }
            }
        } else {
            mmu.dmac.ch[2].btc -= 1;
            if mmu.dmac.ch[2].btc != 0 {
                let bar = mmu.dmac.ch[2].bar;
                mmu.dmac.ch[2].mar = mmu_read32(mmu, bar) & ADDR_MASK;
                mmu.dmac.ch[2].mtc = mmu_read16(mmu, bar + 4);
                mmu.dmac.ch[2].bar = bar + 6;
                if mmu.dmac.ch[2].mtc == 0 { dmac_ch2_fail(mmu, 0x0D); }
            }
        }
    } else if (mmu.dmac.ch[2].ccr & 0x40) != 0 {
        mmu.dmac.ch[2].csr |= 0x40;
        dmac_ch2_raise(mmu);
        if mmu.dmac.ch[2].bar != 0 {
            mmu.dmac.ch[2].mar = mmu.dmac.ch[2].bar;
            mmu.dmac.ch[2].mtc = mmu.dmac.ch[2].btc;
            mmu.dmac.ch[2].csr |= 0x08;
            mmu.dmac.ch[2].bar = 0;
            mmu.dmac.ch[2].btc = 0;
            mmu.dmac.ch[2].ccr &= 0xBF;
            if mmu.dmac.ch[2].mtc == 0 { dmac_ch2_fail(mmu, 0x0D); }
        }
    }
    if mmu.dmac.ch[2].mtc == 0 && (mmu.dmac.ch[2].csr & 0x10) == 0 {
        mmu.dmac.ch[2].csr |= 0x80;
        mmu.dmac.ch[2].csr &= 0xF7;
        dmac_ch2_raise(mmu);
    }
}

fn dmac_exec_ch2(mmu: M68kMMU&) {
    if (mmu.dmac.ch[2].ocr & 3) == 2 { return; }
    var left: i32 = 65536;
    while left > 0 && (mmu.dmac.ch[2].csr & 0x08) != 0 && (mmu.dmac.ch[2].ccr & 0x20) == 0 && (mmu.dmac.ch[2].csr & 0x80) == 0 && mmu.dmac.ch[2].mtc != 0 {
        left -= 1;
        if dmac_ch2_unit(mmu) != 0 { return; }
        if mmu.dmac.ch[2].mtc != 0 {
            mmu.dmac.ch[2].mtc -= 1;
        }
        if mmu.dmac.ch[2].mtc == 0 {
            dmac_ch2_on_zero(mmu);
        }
        if (mmu.dmac.ch[2].ocr & 3) != 1 { return; }
    }
}

// ---------------------------------------------------------------
// ch3 (ADPCM)。転送そのものは C 側の音源が行い、レジスタだけを同期する。
// ---------------------------------------------------------------

fn dmac_sound_push(dmac: X68kDMAC&) {
    c_dmac_push_ch3(
        dmac.ch[3].csr, dmac.ch[3].cer, dmac.ch[3].dcr, dmac.ch[3].ocr,
        dmac.ch[3].scr, dmac.ch[3].ccr, dmac.ch[3].mtc, dmac.ch[3].mar,
        dmac.ch[3].dar, dmac.ch[3].btc, dmac.ch[3].bar, dmac.ch[3].niv,
        dmac.ch[3].eiv);
}

fn dmac_sound_pull(dmac: X68kDMAC&) {
    c_dmac_pull_ch3(
        dmac.ch[3].csr, dmac.ch[3].cer, dmac.ch[3].ccr, dmac.ch[3].mtc,
        dmac.ch[3].mar, dmac.ch[3].dar, dmac.ch[3].btc, dmac.ch[3].bar);
}
