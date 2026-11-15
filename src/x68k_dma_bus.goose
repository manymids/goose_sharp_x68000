// DMAC の転送のうち、MMU の読み書きを通るもの: ch1 (SASI)、ch2 (汎用)、ch3 (ADPCM)。
// フレームの進行 (x68k_emu) から呼ぶ。レジスタは x68k_dmac、ch0 (FDC) は m68k_mmu の fdc_dma。
// x68k_dmac は MMU を知らず、MMU はこのファイルを知らないので、import は一方向だけになる。

import .x68k_bridge;
import .x68k_ram;
import .x68k_sasi;
import .x68k_adpcm;
import .x68k_dmac;
import .m68k_mmu;
namespace dmabus;

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

fn adpcm_port_write(mmu: M68kMMU&, addr: u32, val: u8) {
    let a = addr & ADDR_MASK;
    if (a & 0xFFFFFC) == 0xE92000 { mmu.adpcm.write(a, val); }
    else { x68k_ram_write(a as! i32, val); }
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
                c.mar = dmac::adpcm_mem_read32(entry) & ADDR_MASK;
                c.mtc = dmac::adpcm_mem_read16(entry + 4);
                c.bar = dmac::adpcm_mem_read32(entry + 6) & ADDR_MASK;
                if c.mtc == 0 { return false; }
            }
        } else if c.btc != 0 {
            // アレイ: 表の項が BTC 個並んでいる
            c.btc -= 1;
            if c.btc != 0 {
                c.mar = dmac::adpcm_mem_read32(c.bar) & ADDR_MASK;
                c.mtc = dmac::adpcm_mem_read16(c.bar + 4);
                c.bar = (c.bar + 6) & ADDR_MASK;
                if c.mtc == 0 { return false; }
            }
        }
    } else if (c.ccr & 0x40) != 0 {
        // コンティニュー: BAR / BTC に用意してあった次のブロックへ移る
        c.csr |= 0x40;
        dmac::adpcm_raise(mmu.dmac);
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
        dmac::adpcm_raise(mmu.dmac);
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
            for i: u32 in width { adpcm_port_write(mmu, to + i, dmac::adpcm_mem_read(from + i)); }
            c.mar = dmac::step24(c.mar, (c.scr & 4) != 0, (c.scr & 8) != 0, mem_step);
            c.dar = dmac::step24(c.dar, (c.scr & 1) != 0, (c.scr & 2) != 0, dev_step);
        }

        c.mtc -= 1;
        if c.mtc == 0 && !adpcm_next_block(mmu) { break; }
        // 1 回の要求で 1 単位だけ送るモードでなければ、ここで止まる
        if (c.ocr & 3) != 1 { break; }
    }
}
