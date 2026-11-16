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
    let c .= mmu.dmac.ch[1];
    if (c.csr & DMA_CSR_ACT) == 0 || c.halted() || (c.csr & DMA_CSR_COC) != 0 { return; }
    let ocr = c.ocr;
    let scr = c.scr;
    let kind = ((ocr >> 4) & 3) + ((c.dcr >> 1) & 4);
    let dev_to_mem = (ocr & 0x80) != 0;
    let n = if kind == 1 { 2 } else if kind == 2 { 4 } else { 1 };
    let step = if kind == 5 { 2 } else if kind == 6 { 4 } else { 1 };
    // デバイス側の番地は、ワードのポートなら 1 バイトごとに 2 進む
    let dev_step: u32 = if kind == 4 { step as u32 } else { (step * 2) as u32 };
    while c.running() && mmu.sasi.is_ready() {
        var src = if dev_to_mem { c.dar } else { c.mar };
        var dst = if dev_to_mem { c.mar } else { c.dar };
        for _ in n {
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
                bump(src, scr, 1, 2, dev_step);
                c.mar = dst;
                c.dar = src;
            } else {
                bump(src, scr, 4, 8, step as u32);
                bump(dst, scr, 1, 2, dev_step);
                c.mar = src;
                c.dar = dst;
            }
        }
        if c.mtc != 0 { c.mtc -= 1; }
        if c.mtc == 0 {
            c.finish();
            if (c.ccr & DMA_CCR_INT) != 0 {
                mmu.dmac.int_ch |= 2;
                mmu.dmac.int_pending = true;
            }
        }
    }
}

// ch2 の割り込み要求 (CCR の INT が立っているとき)。
fn ch2_raise(mmu: M68kMMU&) {
    if (mmu.dmac.ch[2].ccr & DMA_CCR_INT) != 0 {
        mmu.dmac.int_ch |= 4;
        mmu.dmac.int_pending = true;
    }
}

// ch2 をエラーで止める。err は CER に入るエラーの種類。
fn ch2_fail(mmu: M68kMMU&, err: u8) {
    let c .= mmu.dmac.ch[2];
    c.cer = err;
    c.csr |= DMA_CSR_ERR;
    c.csr &= ~DMA_CSR_ACT;
    c.ccr &= ~DMA_CCR_STR;
    ch2_raise(mmu);
}

// px68k DMA_Exec(2)。沙羅曼蛇はスプライト 1024 バイトを ch2 のバーストで $EB0000 へ書く。
// OCR&3==2 は Mercury の Ready 待ちなので、ここでは動かさない。
fn ch2_unit(mmu: M68kMMU&) -> i32 {
    let c .= mmu.dmac.ch[2];
    let ocr = c.ocr;
    let scr = c.scr;
    let kind = ((ocr >> 4) & 3) + ((c.dcr >> 1) & 4);
    let dev_to_mem = (ocr & 0x80) != 0;
    // kind ごとの、1 回の転送の読み書きの回数、番地の進み方、1 回の幅
    if kind == 7 { return 0; }
    let n: i32 = if kind == 1 { 2 } else if kind == 2 { 4 } else { 1 };
    let mar_step: u32 = if kind == 5 { 2 } else if kind == 6 { 4 } else { 1 };
    let dar_step: u32 = if kind == 4 { 1 } else if kind == 6 { 4 } else { 2 };
    let width: i32 = if kind == 5 { 2 } else if kind == 6 { 4 } else { 1 };
    for _ in n {
        let src = if dev_to_mem { c.dar } else { c.mar };
        let dst = if dev_to_mem { c.mar } else { c.dar };
        if width != 1 && ((src & 1) != 0 || (dst & 1) != 0) {
            // 奇数番地へのワード / ロングの転送。転送元が奇数かどうかを先に見て、
            // 奇数の側がメモリなら 5 (メモリの番地のエラー)、デバイスなら 6 (デバイスの番地のエラー)
            let err: u8 = if (src & 1) != 0 { if dev_to_mem { 0x06 } else { 0x05 } }
                else { if dev_to_mem { 0x05 } else { 0x06 } };
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
        bump(c.mar, scr, 4, 8, mar_step);
        bump(c.dar, scr, 1, 2, dar_step);
    }
    return 0;
}

// ch2 の MTC が 0 になったあと: チェーンなら次のブロックを読み、コンティニューなら用意したブロックへ移る。
fn ch2_on_zero(mmu: M68kMMU&) {
    let c .= mmu.dmac.ch[2];
    let ocr = c.ocr;
    if (ocr & 8) != 0 {
        if (ocr & 4) != 0 {
            // リンクアレイ: 表の各項が次の項の番地を持つ
            if c.bar != 0 {
                let bar = c.bar;
                c.mar = mmu.read32(bar) & ADDR_MASK;
                c.mtc = mmu.read16(bar + 4);
                c.bar = mmu.read32(bar + 6) & ADDR_MASK;
                if c.mtc == 0 { ch2_fail(mmu, 0x0D); }
            }
        } else {
            // アレイ: 表の項が BTC 個並んでいる
            c.btc -= 1;
            if c.btc != 0 {
                let bar = c.bar;
                c.mar = mmu.read32(bar) & ADDR_MASK;
                c.mtc = mmu.read16(bar + 4);
                c.bar = bar + 6;
                if c.mtc == 0 { ch2_fail(mmu, 0x0D); }
            }
        }
    } else if (c.ccr & DMA_CCR_CNT) != 0 {
        c.csr |= DMA_CSR_BTC;
        ch2_raise(mmu);
        if c.bar != 0 {
            c.mar = c.bar;
            c.mtc = c.btc;
            c.csr |= DMA_CSR_ACT;
            c.bar = 0;
            c.btc = 0;
            c.ccr &= ~DMA_CCR_CNT;
            if c.mtc == 0 { ch2_fail(mmu, 0x0D); }
        }
    }
    if c.mtc == 0 && (c.csr & DMA_CSR_ERR) == 0 {
        c.finish();
        ch2_raise(mmu);
    }
}

fn exec_ch2(mmu: M68kMMU&) {
    let c .= mmu.dmac.ch[2];
    if (c.ocr & 3) == 2 { return; }
    var left: i32 = 65536;
    while left > 0 && c.running() && !c.halted() {
        left -= 1;
        if ch2_unit(mmu) != 0 { return; }
        if c.mtc != 0 { c.mtc -= 1; }
        if c.mtc == 0 { ch2_on_zero(mmu); }
        if (c.ocr & 3) != 1 { return; }
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
        // すべて送り終えた
        c.finish();
        dmac::adpcm_raise(mmu.dmac);
    }
    return true;
}

fn exec_adpcm(mmu: M68kMMU&) {
    let c .= mmu.dmac.ch[3];
    var rounds = 0;
    while c.running() && !c.halted() && rounds < 65536 {
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
