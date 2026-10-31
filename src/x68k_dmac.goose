// Sharp X68000 DMAコントローラ (HD63450 / DMAC) in Goose
// ※実機 ROM / ブートセクタ自走用

import std;
import os;
import .x68k_bridge;
import .m68k_types;
import .x68k_fdc;
import .x68k_ram;
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
    gcr: u8 = 0
}

struct X68kDMAC {
    ch: X68kDMAChannel[4] = [X68kDMAChannel{}; 4],
    int_ch: i32 = 0,
    int_pending: bool = false,
    last_int: i32 = 0
}

fn dmac_init(dmac: X68kDMAC&) {
    dmac.int_ch = 0;
    dmac.int_pending = false;
    dmac.last_int = 0;
    for i in 4 {
        dmac.ch[i].csr = 0;
        dmac.ch[i].cer = 0;
        dmac.ch[i].dcr = 0;
        dmac.ch[i].ocr = 0;
        dmac.ch[i].scr = 0;
        dmac.ch[i].ccr = 0;
        dmac.ch[i].mtc = 0;
        dmac.ch[i].mar = 0;
        dmac.ch[i].dar = 0;
        dmac.ch[i].btc = 0;
        dmac.ch[i].bar = 0;
        dmac.ch[i].niv = 0;
        dmac.ch[i].eiv = 0;
        dmac.ch[i].mfc = 0;
        dmac.ch[i].cpr = 0;
        dmac.ch[i].dfc = 0;
        dmac.ch[i].bfc = 0;
        dmac.ch[i].gcr = 0;
    }
}

fn dma_in_ram(addr: u32, nbytes: u32) -> bool {
    let lim = x68k_ram_limit() as u32;
    if addr >= lim { return false; }
    return addr + nbytes <= lim;
}

fn dma_readmem24_dword(addr: u32) -> u32 {
    let a = addr & 0x00FFFFFF;
    if dma_in_ram(a, 4) {
        return x68k_ram_read32(a as! i32);
    }
    return 0;
}

fn dma_readmem24_word(addr: u32) -> u16 {
    let a = addr & 0x00FFFFFF;
    if dma_in_ram(a, 2) {
        return x68k_ram_read16(a as! i32);
    }
    return 0;
}

fn dmac_read(dmac: X68kDMAC&, addr: u32) -> u8 {
    let off = (addr & 0x3F) as! i32;
    let ch = ((addr >> 6) & 0x03) as! i32;

    if addr >= 0x00E84100 {
        return 0;
    }

    // ch3 は C 側 DMA[3] が進めた MTC/CSR を、読む前に Goose へ戻す。
    if ch == 3 {
        dmac_sound_pull(dmac);
    }

    if off == 0x00 {
        return dmac.ch[ch].csr;
    } else if off == 0x01 {
        return dmac.ch[ch].cer;
    } else if off == 0x04 {
        return dmac.ch[ch].dcr;
    } else if off == 0x05 {
        return dmac.ch[ch].ocr;
    } else if off == 0x06 {
        return dmac.ch[ch].scr;
    } else if off == 0x07 {
        return dmac.ch[ch].ccr;
    } else if off == 0x0A {
        return ((dmac.ch[ch].mtc >> 8) & 0xFF) as! u8;
    } else if off == 0x0B {
        return (dmac.ch[ch].mtc & 0xFF) as! u8;
    } else if off == 0x0C {
        return 0;
    } else if off == 0x0D {
        return ((dmac.ch[ch].mar >> 16) & 0xFF) as! u8;
    } else if off == 0x0E {
        return ((dmac.ch[ch].mar >> 8) & 0xFF) as! u8;
    } else if off == 0x0F {
        return (dmac.ch[ch].mar & 0xFF) as! u8;
    } else if off == 0x14 {
        return 0;
    } else if off == 0x15 {
        return ((dmac.ch[ch].dar >> 16) & 0xFF) as! u8;
    } else if off == 0x16 {
        return ((dmac.ch[ch].dar >> 8) & 0xFF) as! u8;
    } else if off == 0x17 {
        return (dmac.ch[ch].dar & 0xFF) as! u8;
    } else if off == 0x1A {
        return ((dmac.ch[ch].btc >> 8) & 0xFF) as! u8;
    } else if off == 0x1B {
        return (dmac.ch[ch].btc & 0xFF) as! u8;
    } else if off == 0x1C {
        return 0;
    } else if off == 0x1D {
        return ((dmac.ch[ch].bar >> 16) & 0xFF) as! u8;
    } else if off == 0x1E {
        return ((dmac.ch[ch].bar >> 8) & 0xFF) as! u8;
    } else if off == 0x1F {
        return (dmac.ch[ch].bar & 0xFF) as! u8;
    } else if off == 0x25 {
        return dmac.ch[ch].niv;
    } else if off == 0x27 {
        return dmac.ch[ch].eiv;
    } else if off == 0x29 {
        return dmac.ch[ch].mfc;
    } else if off == 0x2D {
        return dmac.ch[ch].cpr;
    } else if off == 0x31 {
        return dmac.ch[ch].dfc;
    } else if off == 0x39 {
        return dmac.ch[ch].bfc;
    } else if off == 0x3F {
        return dmac.ch[ch].gcr;
    }

    return 0;
}

fn dmac_write(dmac: X68kDMAC&, addr: u32, data: u8) {
    let off = (addr & 0x3F) as! i32;
    let ch = ((addr >> 6) & 0x03) as! i32;

    if addr >= 0x00E84100 {
        return;
    }

    // 1 バイト書きで残りのカウンタを古い Goose 値のまま C へ戻さない。
    if ch == 3 {
        dmac_sound_pull(dmac);
    }

    if off == 0x00 {
        dmac.ch[ch].csr &= ((~data) | 0x09);
    } else if off == 0x01 {
        dmac.ch[ch].cer &= (~data);
    } else if off == 0x04 {
        dmac.ch[ch].dcr = data;
    } else if off == 0x05 {
        dmac.ch[ch].ocr = data;
        // print("[DMAC Ch", ch, " write OCR=0x", data as! u32, "]\n");
    } else if off == 0x06 {
        dmac.ch[ch].scr = data;
    } else if off == 0x07 {
        let old = dmac.ch[ch].ccr;
        dmac.ch[ch].ccr = (data & 0xEF) | (old & 0x80);
        if (data & 0x10) != 0 && (old & 0x80) != 0 {
            // Software Abort
            dmac.ch[ch].cer = 0x11;
            dmac.ch[ch].csr |= 0x10;
            dmac.ch[ch].csr &= 0xF7;
            dmac.ch[ch].ccr &= 0x7F;
            if ch == 3 {
                dmac_sound_push(dmac);
            }
            return;
        }
        if (data & 0x80) != 0 {
            // Start DMA
            dmac.ch[ch].csr |= 0x08; // ACT bit
            dmac.ch[ch].cer = 0x00;
            /* print("[DMAC Ch", ch, " START DMA: MAR=0x", dmac.ch[ch].mar, " MTC=", dmac.ch[ch].mtc,
                  " OCR=0x", dmac.ch[ch].ocr as! u32, " SCR=0x", dmac.ch[ch].scr as! u32,
                  " BAR=0x", dmac.ch[ch].bar, " BTC=", dmac.ch[ch].btc, "]\n"); */
            if (dmac.ch[ch].ocr & 8) != 0 {
                // Array/Link Array Chain
                dmac.ch[ch].mar = dma_readmem24_dword(dmac.ch[ch].bar) & 0x00FFFFFF;
                dmac.ch[ch].mtc = dma_readmem24_word(dmac.ch[ch].bar + 4);
                if (dmac.ch[ch].ocr & 4) != 0 {
                    dmac.ch[ch].bar = dma_readmem24_dword(dmac.ch[ch].bar + 6) & 0x00FFFFFF;
                } else {
                    dmac.ch[ch].bar += 6;
                }
                /* print("   Chain initial loaded: MAR=0x", dmac.ch[ch].mar, " MTC=", dmac.ch[ch].mtc,
                      " next BAR=0x", dmac.ch[ch].bar, "\n"); */
            }
        }
    } else if off == 0x0A {
        dmac.ch[ch].mtc = (dmac.ch[ch].mtc & 0x00FF) | ((data as! u16) << 8);
    } else if off == 0x0B {
        dmac.ch[ch].mtc = (dmac.ch[ch].mtc & 0xFF00) | (data as! u16);
    } else if off == 0x0C {
        // dummy / unused on 24-bit bus
    } else if off == 0x0D {
        dmac.ch[ch].mar = (dmac.ch[ch].mar & 0x0000FFFF) | ((data as! u32) << 16);
    } else if off == 0x0E {
        dmac.ch[ch].mar = (dmac.ch[ch].mar & 0x00FF00FF) | ((data as! u32) << 8);
    } else if off == 0x0F {
        dmac.ch[ch].mar = (dmac.ch[ch].mar & 0x00FFFF00) | (data as! u32);
        // print("[DMAC Ch", ch, " set MAR=", dmac.ch[ch].mar, "]\n");
    } else if off == 0x14 {
        // dummy / unused
    } else if off == 0x15 {
        dmac.ch[ch].dar = (dmac.ch[ch].dar & 0x0000FFFF) | ((data as! u32) << 16);
    } else if off == 0x16 {
        dmac.ch[ch].dar = (dmac.ch[ch].dar & 0x00FF00FF) | ((data as! u32) << 8);
    } else if off == 0x17 {
        dmac.ch[ch].dar = (dmac.ch[ch].dar & 0x00FFFF00) | (data as! u32);
    } else if off == 0x1A {
        dmac.ch[ch].btc = (dmac.ch[ch].btc & 0x00FF) | ((data as! u16) << 8);
    } else if off == 0x1B {
        dmac.ch[ch].btc = (dmac.ch[ch].btc & 0xFF00) | (data as! u16);
    } else if off == 0x1C {
        // dummy / unused
    } else if off == 0x1D {
        dmac.ch[ch].bar = (dmac.ch[ch].bar & 0x0000FFFF) | ((data as! u32) << 16);
    } else if off == 0x1E {
        dmac.ch[ch].bar = (dmac.ch[ch].bar & 0x00FF00FF) | ((data as! u32) << 8);
    } else if off == 0x1F {
        dmac.ch[ch].bar = (dmac.ch[ch].bar & 0x00FFFF00) | (data as! u32);
    } else if off == 0x25 {
        dmac.ch[ch].niv = data;
    } else if off == 0x27 {
        dmac.ch[ch].eiv = data;
    } else if off == 0x29 {
        dmac.ch[ch].mfc = data;
    } else if off == 0x2D {
        dmac.ch[ch].cpr = data;
    } else if off == 0x31 {
        dmac.ch[ch].dfc = data;
    } else if off == 0x39 {
        dmac.ch[ch].bfc = data;
    } else if off == 0x3F {
        if ch == 3 {
            dmac.ch[ch].gcr = data;
        }
    }

    if ch == 3 {
        dmac_sound_push(dmac);
    }
}

// FDC と DMAC Ch 0 の DMA 転送実行。
// px68k の dma_writemem24 は wm_main 経由なので、GVRAM / TVRAM も CPU と同じ書き込みになる。
fn dmac_exec_fdc(dmac: X68kDMAC&, fdc: X68kFDC&, mmu: M68kMMU&) -> bool {
    // Ch 0 が動作中 (ACT = bit 3) かチェック
    if (dmac.ch[0].csr & 0x08) == 0 {
        return false;
    }
    if fdc.bufnum <= 0 {
        return false;
    }

    // 1 セクタ転送するたびに FDC_NextTrack。MTC が残っていれば次セクタも続ける。
    while (dmac.ch[0].csr & 0x08) != 0 && fdc.bufnum > 0 {
    for i in fdc.bufnum {
        let b = fdc.data_buf[i];
        let addr = dmac.ch[0].mar & 0x00FFFFFF;
        if dma_in_ram(addr, 1) {
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

    // MTC の減算（ワード転送の場合は bufnum / 2、バイト転送の場合は bufnum）
    let size_code = (dmac.ch[0].ocr >> 4) & 3;
    let units = if size_code == 1 { (fdc.bufnum / 2) as! u16 } else { fdc.bufnum as! u16 };
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
                    dmac.ch[0].mar = dma_readmem24_dword(dmac.ch[0].bar) & 0x00FFFFFF;
                    dmac.ch[0].mtc = dma_readmem24_word(dmac.ch[0].bar + 4);
                    dmac.ch[0].bar = dma_readmem24_dword(dmac.ch[0].bar + 6) & 0x00FFFFFF;
                    write_stderr(str("   Chain next link block: MAR=0x", dmac.ch[0].mar, " MTC=", dmac.ch[0].mtc,
                          " next BAR=0x", dmac.ch[0].bar, "\n"));
                }
            } else {
                if dmac.ch[0].btc > 0 {
                    dmac.ch[0].btc--;
                    if dmac.ch[0].btc != 0 {
                        dmac.ch[0].mar = dma_readmem24_dword(dmac.ch[0].bar) & 0x00FFFFFF;
                        dmac.ch[0].mtc = dma_readmem24_word(dmac.ch[0].bar + 4);
                        dmac.ch[0].bar += 6;
                        write_stderr(str("   Chain next array block: MAR=0x", dmac.ch[0].mar, " MTC=", dmac.ch[0].mtc,
                              " next BAR=0x", dmac.ch[0].bar, "\n"));
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

    fdc_next_track(fdc);
    }

    return true;
}

// ch0–2 の完了ベクタ。ERR (CSR bit4) なら EIV、なければ NIV。消さない。
fn dmac_peek_irq(dmac: X68kDMAC&) -> i32 {
    if !dmac.int_pending { return -1; }
    var start = dmac.last_int;
    if start < 0 || start > 2 { start = 0; }
    for n in 3 {
        let i = ((start + n) % 3) as i32;
        let bit = 1 << i;
        if (dmac.int_ch & bit) != 0 {
            if (dmac.ch[i].csr & 0x10) != 0 { return dmac.ch[i].eiv as i32; }
            return dmac.ch[i].niv as i32;
        }
    }
    return -1;
}

fn dmac_ack_irq(dmac: X68kDMAC&) {
    if !dmac.int_pending { return; }
    var start = dmac.last_int;
    if start < 0 || start > 2 { start = 0; }
    for n in 3 {
        let i = ((start + n) % 3) as i32;
        let bit = 1 << i;
        if (dmac.int_ch & bit) != 0 {
            dmac.int_ch &= ~(bit as i32);
            dmac.last_int = i;
            if (dmac.int_ch & 7) == 0 { dmac.int_pending = false; }
            return;
        }
    }
    dmac.int_pending = false;
}

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
