// Sharp X68000 PPU (Text & Graphic合成描画) in Goose

import .x68k_bridge;
import .m68k_mmu;
namespace ppu;


// BG / スプライト / テキストの作業用ラインバッファは、左に LINE_PAD ドットの余白を持つ。
// 画面の x は添字 x + LINE_PAD。スプライトが左端からはみ出しても添字が負にならない。
let ::LINE_PAD = 16;
let ::LINE_BUF_W = 1040; // 1024 + LINE_PAD

struct X68kPPU {
    line_bg: u16[LINE_BUF_W] = [0; LINE_BUF_W],
    line_tr: u8[LINE_BUF_W] = [0; LINE_BUF_W],
    line_bpri: u16[LINE_BUF_W] = [0; LINE_BUF_W],
    grp: u16[1024] = [0; 1024],
    grp_mix: u8[1024] = [0; 1024],
    grp_argb: u32[1024] = [0; 1024],
    sp: u16[1024] = [0; 1024],
    sp2: u16[1024] = [0; 1024],
    scr: u16[1024] = [0; 1024],
    scr_mix: u8[1024] = [0; 1024],
    scr_argb: u32[1024] = [0; 1024],
    fb: u32[393216] = [0; 393216],
    // 画面の大きさ (フレームの始めと終わりに CRTC から決める)。ホストへは session が 1 フレームごとに伝える
    screen_w: i32 = 768,
    screen_h: i32 = 512,
    frame_ready: bool = false,  // このフレームを描き始めた。リセットやステートの復元で落ちる
}
type ::X68kPPU = ppu::X68kPPU;

fn pal_text_idx(mmu: M68kMMU&, idx: i32) -> u16 {
    // テキストパレットは pal の 0x200 から。マスクは境界検査を外すためで、値は変わらない。
    let o = 0x200 + (idx & 255) * 2;
    return ((mmu.pal[o & 0x3FF] as u16) << 8) | (mmu.pal[(o + 1) & 0x3FF]);
}

fn sprites_to_line(ppu: X68kPPU&, mmu: M68kMMU&, pri: i32, width: i32, sy: i32) {
    assert(width >= 0 && width <= 1024);
    let crtc_hstart = mmu.crtc_word(CRTC_HSTART) & 1023;
    let crtc_vstart = mmu.crtc_word(CRTC_VSTART) & 1023;
    let reg0d: i32 = mmu.crtc_regs[0x0D];
    let reg29: i32 = mmu.crtc_regs[0x29];
    let bgreg_0d: i32 = mmu.bgreg[0x0D];
    let bgreg_0f: i32 = mmu.bgreg[0x0F];
    let bgreg_11: i32 = mmu.bgreg[0x11];
    let s1 = (if (bgreg_11 & 4) != 0 { 2 } else { 1 }) - (if (bgreg_11 & 16) != 0 { 1 } else { 0 });
    let s2 = (if (reg29 & 4) != 0 { 2 } else { 1 }) - (if (reg29 & 16) != 0 { 1 } else { 0 });
    var vlinebg: u32 = sy as u32;
    vlinebg = vlinebg << s1;
    vlinebg = vlinebg >> s2;
    if (bgreg_11 & 16) == 0 {
        let left = (bgreg_0f >> s1) as u32;
        let right = (reg0d >> s2) as u32;
        vlinebg -= (left - right);
    }
    let bg_vline = (bgreg_0f - crtc_vstart) / (if (bgreg_11 & 4) != 0 { 1 } else { 2 });
    let h_adj = (bgreg_0d - (crtc_hstart + 4)) * 8;
    // 番号の大きいスプライトから順に見る (cur が番号)。
    var n = 127;
    while n >= 0 {
        let cur = n;
        n -= 1;
        let base = cur * 8;
        let raw_x = ((mmu.sprite[base] as u16) << 8) | (mmu.sprite[base + 1]);
        let raw_y = ((mmu.sprite[base + 2] as u16) << 8) | (mmu.sprite[base + 3]);
        let ctrl = ((mmu.sprite[base + 4] as u16) << 8) | (mmu.sprite[base + 5]);
        let ply = mmu.sprite[base + 7];
        if (ply & 3) != (pri as u8) { continue; }
        let t0 = (((raw_x) + h_adj) & 0x3FF) as u32;
        if t0 >= ((width + LINE_PAD) as u32) { continue; }
        // このラインがスプライトの何行目に当たるか。スプライト座標は画面の上端が 16。
        // 符号なし 32 bit で折り返すので、スプライトの外のラインは 15 より大きな値になる。
        let line_y = vlinebg - (bg_vline as! u32);
        let row: u32 = line_y + 16 - (raw_y & 0x3FF);
        if row > 15 { continue; }
        let ctrl_i: i32 = ctrl;
        let pat = ctrl_i & 0xFF;
        let flip_x = (ctrl_i & 0x4000) != 0;
        let flip_y = (ctrl_i & 0x8000) != 0;
        let src_y = if flip_y { 15 - (row as i32) } else { row as i32 };
        let pal_bank = (ctrl_i & 0x0F00) >> 4;
        var px = 0;
        var t = t0;
        while px < 16 {
            let src_x = if flip_x { 15 - px } else { px };
            let tt = t;
            px += 1;
            t += 1;
            if tt < LINE_PAD || tt >= ((width + LINE_PAD) as u32) || tt >= LINE_BUF_W { continue; }
            let src = pat * 256 + src_y * 16 + src_x;
            let col = mmu.bg_chr16[src] & 0x0F;
            if col == 0 { continue; }
            let ti: i64 = tt;
            let pri_n = (cur * 8) as u16;
            if ppu.line_bpri[ti] < pri_n { continue; }
            ppu.line_bg[ti] = pal_text_idx(mmu, pal_bank | (col));
            ppu.line_tr[ti] |= 2;
            ppu.line_bpri[ti] = pri_n;
        }
    }
}

fn plot_bg(ppu: X68kPPU&, mmu: M68kMMU&, sx: i32, screen_w: i32, idx: u8) {
    if idx == 0 || sx < 0 || sx >= screen_w { return; }
    let pal = 0x200 + (idx as i32) * 2;
    if pal + 1 >= 1024 { return; }
    let p_val = ((mmu.pal[pal] as u16) << 8) | (mmu.pal[pal + 1]);
    let t = sx + LINE_PAD;
    if t >= LINE_PAD && t < LINE_BUF_W {
        ppu.line_bg[t] = p_val;
        ppu.line_tr[t] |= 2;
    }
}

fn draw_bg_map(ppu: X68kPPU&, mmu: M68kMMU&, screen_w: i32, sy: i32, scroll_x: i32, scroll_y: i32, adjust: i32, vline: i32, top: i32, wide: bool, ng: bool) {
    let line = (scroll_y as u32) + (sy as u32) - (vline as! u32);
    let span: i32 = if wide { 16 } else { 8 };
    let rel = scroll_x - adjust;
    // x_phase: 画面左端でのタイル内の横位置。map_col: BG マップ上の列 (1 タイル 2 バイト)。
    let x_phase = (rel & (span - 1)) ^ 15;
    var shift: i32 = 2;
    var xmask: i32 = 0x1F8;
    if wide {
        shift = 3;
        xmask = 0x3F0;
    }
    var map_col = (rel & xmask) >> shift;
    let row_shift: i32 = if wide { 3 } else { 4 };
    let row = ((line & (xmask as u32)) << row_shift) as i32;
    let fine = (line & ((span - 1) as u32)) as i32;
    let tiles = screen_w / span + 2;
    var sx0: i32 = x_phase - 15;
    let chr_bytes: i32 = if wide { PCG16_BYTES } else { PCG8_BYTES };
    var tile: i32 = 0;
    while tile < tiles {
        let map = top + row + (map_col & 0x7F);
        map_col = (map_col + 2) & 0x7F;
        if map < 0 || map + 1 >= BGRAM_BYTES {
            sx0 += span;
            tile += 1;
            continue;
        }
        let attr = mmu.bgram[map];
        let attr_i: i32 = attr;
        // pat_base: パターン番号から求めた PCG 内の先頭。pat_row: そのパターン内の行の位置。
        let pat_base = if wide { (mmu.bgram[map + 1] as i32) << 8 } else { (mmu.bgram[map + 1] as i32) << 6 };
        let pat_row = if wide { fine << 4 } else { fine << 3 };
        var origin: i32 = 0;
        var d: i32 = 1;
        if attr_i < 0x40 {
            origin = pat_base + pat_row;
            d = 1;
        } else if ((attr_i - 0x40) & 0x80) != 0 {
            origin = pat_base + (if wide { 0xFF } else { 0x3F }) - pat_row;
            d = -1;
        } else if (attr as! i8) >= 0x40 {
            origin = pat_base + pat_row + (span - 1);
            d = -1;
        } else {
            origin = pat_base + (if wide { 0xF0 } else { 0x38 }) - pat_row;
            d = 1;
        }
        let pal_hi = ((attr_i << 4) & 0xFF) as u8;
        for j: i32 in span {
            let src = origin + j * d;
            if src >= 0 && src < chr_bytes {
                // パターンのニブルが 0 のドットは、px68k の ng 経路では描かない。
                // gd 経路でも、すでに BG かスプライトがある画素は上書きしない。
                // 上書きすると色 0 のタイルが手前の地面を消して格子になる。
                let nib = if wide { mmu.bg_chr16[src] & 0x0F } else { mmu.bg_chr8[src] & 0x0F };
                let t = sx0 + j + LINE_PAD;
                let covered = t >= 0 && t < LINE_BUF_W && (ppu.line_tr[t] & 2) != 0;
                if nib != 0 || (!ng && !covered) {
                    ppu.plot_bg(mmu, sx0 + j, screen_w, nib | pal_hi);
                }
            }
        }
        sx0 += span;
        tile += 1;
    }
}

fn bg_plane(ppu: X68kPPU&, mmu: M68kMMU&, which: i32, width: i32, sy: i32, ng: bool) {
    assert(width >= 0 && width <= 1024);
    let r0 = mmu.crtc_regs;
    let hstart = (((r0[0x04] as i32) << 8) | (r0[0x05])) & 1023;
    let vstart = (((r0[0x0C] as i32) << 8) | (r0[0x0D])) & 1023;
    let adjust = ((mmu.bgreg[0x0D]) - (hstart + 4)) * 8;
    let vdiv: i32 = if (mmu.bgreg[0x11] & 4) != 0 { 1 } else { 2 };
    let vline = ((mmu.bgreg[0x0F]) - vstart) / vdiv;
    let cfg = mmu.bgreg[0x09];
    if which == 1 {
        if (cfg & 8) == 0 || (mmu.bgreg[0x11] & 3) != 0 { return; }
        let top: i32 = if (cfg & 0x30) != 0 { 0x6000 } else { 0x4000 };
        var mask: i32 = 511;
        let sx1 = (((mmu.bgreg[0x04] as i32) << 8) | (mmu.bgreg[0x05])) & mask;
        let sy1 = (((mmu.bgreg[0x06] as i32) << 8) | (mmu.bgreg[0x07])) & mask;
        ppu.draw_bg_map(mmu, width, sy, sx1, sy1, adjust, vline, top, false, ng);
        return;
    }
    if (cfg & 1) == 0 { return; }
    let chr16 = (mmu.bgreg[0x11] & 3) != 0;
    let mask: i32 = if chr16 { 1023 } else { 511 };
    let top: i32 = if (cfg & 0x06) != 0 { 0x6000 } else { 0x4000 };
    let sx0 = (((mmu.bgreg[0x00] as i32) << 8) | (mmu.bgreg[0x01])) & mask;
    let sy0 = (((mmu.bgreg[0x02] as i32) << 8) | (mmu.bgreg[0x03])) & mask;
    ppu.draw_bg_map(mmu, width, sy, sx0, sy0, adjust, vline, top, chr16, ng);
}

fn clear_front(ppu: X68kPPU&) {
    c_line_zero(ppu.grp[0], ppu.grp_mix[0], ppu.sp[0], ppu.sp2[0], ppu.line_bg[0], ppu.line_tr[0]);
}

fn bg_line_clear(ppu: X68kPPU&, mmu: M68kMMU&, width: i32, opaq: bool) {
    assert(width >= 0 && width <= 1024);
    let fill = pal_text_idx(mmu, 0);
    var i: i32 = LINE_PAD;
    let end = width + LINE_PAD;
    while i < end && i < LINE_BUF_W {
        ppu.line_bpri[i as i64] = 0xFFFF;
        if opaq { ppu.line_bg[i as i64] = fill; }
        i += 1;
    }
}

fn bg_fill_pal0(ppu: X68kPPU&, mmu: M68kMMU&, width: i32) {
    assert(width >= 0 && width <= 1024);
    let fill = pal_text_idx(mmu, 0);
    var i: i32 = LINE_PAD;
    let end = width + LINE_PAD;
    while i < end && i < LINE_BUF_W {
        ppu.line_bg[i as i64] = fill;
        i += 1;
    }
}

fn bg_draw_line(ppu: X68kPPU&, mmu: M68kMMU&, width: i32, sy: i32, opaq: bool, ng: bool) {
    assert(width >= 0 && width <= 1024);
    ppu.bg_line_clear(mmu, width, opaq);
    ppu.sprites_to_line(mmu, 1, width, sy);
    ppu.bg_plane(mmu, 1, width, sy, ng);
    ppu.sprites_to_line(mmu, 2, width, sy);
    ppu.bg_plane(mmu, 0, width, sy, ng);
    ppu.sprites_to_line(mmu, 3, width, sy);
}

fn crtc_pair(mmu: M68kMMU&, hi: i32) -> u32 {
    return mmu.crtc_word(hi) as u32;
}

fn grp_xhi(page: i32) -> i32 {
    if page == 1 { return 0x1C; }
    if page == 2 { return 0x20; }
    if page == 3 { return 0x24; }
    return 0x18;
}

fn grp_yhi(page: i32) -> i32 {
    if page == 1 { return 0x1E; }
    if page == 2 { return 0x22; }
    if page == 3 { return 0x26; }
    return 0x1A;
}

fn grp_mask(page: i32) -> u32 {
    if page == 0 { return 1023; }
    return 511;
}

fn gvram_at(mmu: M68kMMU&, off: u32) -> u8 {
    return mmu.gvram[(off & 0x7FFFF) as i64];
}

fn gvram_le(mmu: M68kMMU&, off: u32) -> u16 {
    let o = off & 0x7FFFF;
    let n = (o + 1) & 0x7FFFF;
    return (mmu.gvram[o as i64]) | ((mmu.gvram[n as i64] as u16) << 8);
}

fn pal_grph(mmu: M68kMMU&, idx: i32) -> u16 {
    let o: i64 = (idx & 255) * 2;
    return ((mmu.pal[o] as u16) << 8) | (mmu.pal[o + 1]);
}

fn pal_to_argb(pal_val: u16) -> u32 {
    let gg: u32 = pal_val & 1;
    let pv: u32 = pal_val;
    let r6 = ((pv >> 5) & 62) | gg;
    let g6 = ((pv >> 10) & 62) | gg;
    let b6 = (pv & 62) | gg;
    let scale: u32 = 238 * 16645;
    let r = (r6 * scale) >> 20;
    let g = (g6 * scale) >> 20;
    let b = (b6 * scale) >> 20;
    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

fn argb_avg(a: u32, b: u32) -> u32 {
    let r = (((a >> 16) & 255) + ((b >> 16) & 255)) >> 1;
    let g = (((a >> 8) & 255) + ((b >> 8) & 255)) >> 1;
    let bl = ((a & 255) + (b & 255)) >> 1;
    return 0xFF000000 | (r << 16) | (g << 8) | bl;
}

fn grp4_store(ppu: X68kPPU&, mmu: M68kMMU&, sx: i32, v: u16, high: bool, opaq: bool) {
    let idx: i32 = if high { ((v >> 4) & 0x0F) } else { (v & 0x0F) };
    if opaq || idx != 0 {
        ppu.grp[sx] = pal_grph(mmu, idx);
        ppu.grp_mix[sx] = 0;
    }
}

fn grp4_line(ppu: X68kPPU&, mmu: M68kMMU&, page: i32, sy: i32, width: i32, opaq: bool) {
    assert(width >= 0 && width <= 1024);
    let p = page & 3;
    let scroll_x = crtc_pair(mmu, grp_xhi(p)) & grp_mask(p);
    let scroll_y = crtc_pair(mmu, grp_yhi(p)) & grp_mask(p);
    let high = (p & 1) != 0;
    var y = scroll_y + (sy as u32);
    if (mmu.crtc_regs[0x29] & 0x1C) == 0x1C { y = y + (sy as u32); }
    y = (y & 0x1FF) << 10;
    let xs = scroll_x & 0x1FF;
    var off = y + xs * 2 + ((p >> 1) as u32);
    let span = xs ^ 0x1FF;
    var sx: i32 = 0;
    if span < (width as u32) {
        while sx < (span as i32) {
            ppu.grp4_store(mmu, sx, gvram_le(mmu, off), high, opaq);
            off += 2;
            sx += 1;
        }
        off -= 0x400;
    }
    while sx < width {
        ppu.grp4_store(mmu, sx, gvram_le(mmu, off), high, opaq);
        off += 2;
        sx += 1;
    }
}

fn grp4_sp_line(ppu: X68kPPU&, mmu: M68kMMU&, page: i32, sy: i32, width: i32) {
    assert(width >= 0 && width <= 1024);
    let p = page & 3;
    let scroll_x = crtc_pair(mmu, grp_xhi(p)) & grp_mask(p);
    let scroll_y = crtc_pair(mmu, grp_yhi(p)) & grp_mask(p);
    var y = scroll_y + (sy as u32);
    if (mmu.crtc_regs[0x29] & 0x1C) == 0x1C { y = y + (sy as u32); }
    y = (y & 0x1FF) << 10;
    let x = scroll_x & 0x1FF;
    let add: u32 = if (p & 2) != 0 { 1 } else { 0 };
    var off = y + x * 2 + add;
    var left = (x ^ 0x1FF) + 1;
    let high = (p & 1) != 0;
    for i: i32 in width {
        let b = gvram_at(mmu, off);
        let nib = if high { b >> 4 } else { b };
        let bit0 = (nib & 1) != 0;
        let col = pal_grph(mmu, (nib & 0x0E));
        if !bit0 {
            ppu.sp[i] = 0;
            ppu.sp2[i] = col;
        } else {
            ppu.sp[i] = col;
            ppu.sp2[i] = 0;
        }
        off += 2;
        left -= 1;
        if left == 0 { off = off - 0x400; }
    }
}

fn grp4_tr_line(ppu: X68kPPU&, mmu: M68kMMU&, page: i32, sy: i32, width: i32, opaq: bool) {
    assert(width >= 0 && width <= 1024);
    let p = page & 3;
    let scroll_x = crtc_pair(mmu, grp_xhi(p)) & grp_mask(p);
    let scroll_y = crtc_pair(mmu, grp_yhi(p)) & grp_mask(p);
    var y = scroll_y + (sy as u32);
    if (mmu.crtc_regs[0x29] & 0x1C) == 0x1C { y = y + (sy as u32); }
    y = (y & 0x1FF) << 10;
    y += ((p >> 1) as u32);
    let high = (p & 1) != 0;
    var x = scroll_x & 0x1FF;
    for i: i32 in width {
        let b = gvram_at(mmu, y + x * 2);
        let nib: i32 = if high { ((b >> 4) & 0x0F) } else { (b & 0x0F) };
        let v0 = ppu.sp[i];
        var wrote = false;
        if v0 != 0 && nib != 0 {
            let gp = pal_grph(mmu, nib);
            if gp != 0 {
                ppu.grp_argb[i] = argb_avg(pal_to_argb(v0), pal_to_argb(gp));
                ppu.grp_mix[i] = 1;
                ppu.grp[i] = 1;
                wrote = true;
            }
        }
        if !wrote && (opaq || (v0 == 0 && nib != 0)) {
            let stored: u16 = if v0 == 0 { pal_grph(mmu, nib) } else { 0 };
            ppu.grp[i] = stored;
            ppu.grp_mix[i] = 0;
        } else if !wrote && !opaq && v0 != 0 && nib == 0 {
            ppu.grp[i] = 0;
            ppu.grp_mix[i] = 0;
        }
        x = (x + 1) & 0x1FF;
    }
}

fn grp4h_line(ppu: X68kPPU&, mmu: M68kMMU&, sy: i32, width: i32, special: bool) {
    assert(width >= 0 && width <= 1024);
    let scroll_x = crtc_pair(mmu, CRTC_GRP_X) & 1023;
    let scroll_y = crtc_pair(mmu, CRTC_GRP_Y) & 1023;
    var y = scroll_y + (sy as u32);
    if (mmu.crtc_regs[0x29] & 0x1C) == 0x1C { y = y + (sy as u32); }
    y &= 0x3FF;
    var bits: u32 = 0;
    if (y & 0x200) == 0 {
        y = y << 10;
        if (scroll_x & 0x200) != 0 { bits = 4; }
    } else {
        y = (y & 0x1FF) << 10;
        bits = 8;
        if (scroll_x & 0x200) != 0 { bits = 12; }
    }
    let xs = scroll_x & 0x1FF;
    var off = y + xs * 2;
    var left = (xs ^ 0x1FF) + 1;
    for sx: i32 in width {
        let v = gvram_le(mmu, off);
        let idx = ((v as u32) >> bits) & 0x0F;
        if special {
            let col = pal_grph(mmu, (idx & 0x0E) as i32);
            if (idx & 1) == 0 {
                ppu.sp[sx] = 0;
                ppu.sp2[sx] = col;
            } else {
                ppu.sp[sx] = col;
                ppu.sp2[sx] = 0;
            }
        } else {
            ppu.grp[sx] = pal_grph(mmu, idx as i32);
            ppu.grp_mix[sx] = 0;
        }
        off += 2;
        left -= 1;
        if left == 0 {
            off -= 0x400;
            if !special { bits = bits ^ 4; }
            left = 512;
        }
    }
}

fn grp8_line(ppu: X68kPPU&, mmu: M68kMMU&, page: i32, sy: i32, width: i32, opaq: bool) {
    assert(width >= 0 && width <= 1024);
    let p = page & 1;
    let p0 = p * 2;
    let p1 = p0 + 1;
    var y = (crtc_pair(mmu, grp_yhi(p0)) & grp_mask(p0)) + (sy as u32);
    var y0 = (crtc_pair(mmu, grp_yhi(p1)) & grp_mask(p1)) + (sy as u32);
    if (mmu.crtc_regs[0x29] & 0x1C) == 0x1C {
        y += (sy as u32);
        y0 += (sy as u32);
    }
    y = ((y & 0x1FF) << 10) + (p as u32);
    y0 = ((y0 & 0x1FF) << 10) + (p as u32);
    let x = (crtc_pair(mmu, grp_xhi(p0)) & grp_mask(p0)) & 0x1FF;
    let x0 = (crtc_pair(mmu, grp_xhi(p1)) & grp_mask(p1)) & 0x1FF;
    var src = y + x * 2;
    var off = y0 + x0 * 2;
    var left = (x ^ 0x1FF) + 1;
    var wrapped = false;
    for i: i32 in width {
        let vw = gvram_le(mmu, src);
        let idx = (gvram_at(mmu, off) & 0xF0) | ((vw & 0x0F) as u8);
        if opaq || idx != 0 {
            ppu.grp[i] = pal_grph(mmu, idx);
            ppu.grp_mix[i] = 0;
        }
        src += 2;
        off += 2;
        if (off & 0x3FE) == 0 { off = off - 0x400; }
        left -= 1;
        if !wrapped && left == 0 {
            src -= 0x400;
            wrapped = true;
        }
    }
}

fn grp8_sp_line(ppu: X68kPPU&, mmu: M68kMMU&, page: i32, sy: i32, width: i32) {
    assert(width >= 0 && width <= 1024);
    let p = page & 1;
    let p0 = p * 2;
    let p1 = p0 + 1;
    var y = (crtc_pair(mmu, grp_yhi(p0)) & grp_mask(p0)) + (sy as u32);
    var y0 = (crtc_pair(mmu, grp_yhi(p1)) & grp_mask(p1)) + (sy as u32);
    if (mmu.crtc_regs[0x29] & 0x1C) == 0x1C {
        y += (sy as u32);
        y0 += (sy as u32);
    }
    y = (y & 0x1FF) << 10;
    y0 = (y0 & 0x1FF) << 10;
    let x = (crtc_pair(mmu, grp_xhi(p0)) & grp_mask(p0)) & 0x1FF;
    let x0 = (crtc_pair(mmu, grp_xhi(p1)) & grp_mask(p1)) & 0x1FF;
    var off = y + x * 2 + (p as u32);
    var off0 = y0 + x0 * 2 + (p as u32);
    var left = (x ^ 0x1FF) + 1;
    for i: i32 in width {
        let raw = (gvram_at(mmu, off) & 0x0F) | (gvram_at(mmu, off0) & 0xF0);
        let v = raw & 0xFE;
        if (raw & 1) == 0 {
            let col: u16 = if v != 0 { pal_grph(mmu, v) } else { 0 };
            ppu.sp[i] = 0;
            ppu.sp2[i] = col;
        } else {
            let col: u16 = if v != 0 { pal_grph(mmu, v) | 1 } else { 0 };
            ppu.sp[i] = col;
            ppu.sp2[i] = 0;
        }
        off += 2;
        off0 += 2;
        if (off0 & 0x3FE) == 0 { off0 = off0 - 0x400; }
        left -= 1;
        if left == 0 { off = off - 0x400; }
    }
}

fn pal16_adr(b: i32) -> i32 {
    let n = b & 255;
    return ((n & 0xFE) << 1) | (n & 1);
}

fn grp16_line(ppu: X68kPPU&, mmu: M68kMMU&, sy: i32, width: i32) {
    assert(width >= 0 && width <= 1024);
    var y = (crtc_pair(mmu, CRTC_GRP_Y) & 1023) + (sy as u32);
    if (mmu.crtc_regs[0x29] & 0x1C) == 0x1C { y = y + (sy as u32); }
    y = (y & 0x1FF) << 10;
    let x = (crtc_pair(mmu, CRTC_GRP_X) & 1023) & 0x1FF;
    var src = y + x * 2;
    var left = (x ^ 0x1FF) + 1;
    var wrapped = false;
    for i: i32 in width {
        let vw = gvram_le(mmu, src);
        var out: u16 = 0;
        if vw != 0 {
            let a_lo = pal16_adr((vw & 0xFF));
            let a_hi = pal16_adr(((vw >> 8) & 0xFF)) + 2;
            if a_hi < 1024 {
                out = ((mmu.pal[a_hi] as u16) << 8) | (mmu.pal[a_lo]);
            }
        }
        ppu.grp[i] = out;
        ppu.grp_mix[i] = 0;
        src += 2;
        left -= 1;
        if !wrapped && left == 0 {
            src -= 0x400;
            wrapped = true;
        }
    }
}

fn grp16_sp_line(ppu: X68kPPU&, mmu: M68kMMU&, sy: i32, width: i32) {
    assert(width >= 0 && width <= 1024);
    var y = (crtc_pair(mmu, CRTC_GRP_Y) & 1023) + (sy as u32);
    if (mmu.crtc_regs[0x29] & 0x1C) == 0x1C { y = y + (sy as u32); }
    y = (y & 0x1FF) << 10;
    let x = (crtc_pair(mmu, CRTC_GRP_X) & 1023) & 0x1FF;
    var off = y + x * 2;
    var left = (x ^ 0x1FF) + 1;
    for i: i32 in width {
        let b0 = gvram_at(mmu, off);
        let b1 = gvram_at(mmu, off + 1);
        var v = ((mmu.pal[(b1 as i32) * 2] as u16) << 8) | (mmu.pal[(b0 as i32) * 2 + 1]);
        v &= 0xFFFE;
        if (b0 & 1) == 0 {
            ppu.sp[i] = 0;
            ppu.sp2[i] = v;
        } else {
            ppu.sp[i] = v;
            ppu.sp2[i] = 0;
        }
        off += 2;
        left -= 1;
        if left == 0 { off = off - 0x400; }
    }
}

// グラフィック面を 1 ライン描く。戻り値は順に、通常のグラフィックを描いたか、半透明用の面を描いたか、
// 特殊プライオリティ用の面を描いたか。
fn grp_lines(ppu: X68kPPU&, mmu: M68kMMU&, sy: i32, width: i32) -> bool, bool, bool {
    assert(width >= 0 && width <= 1024);
    let vc0 = mmu.vcreg[1];
    let vc1_1 = mmu.vcreg[0x101];
    let vc2_0 = mmu.vcreg[0x200];
    let vc2_1 = mmu.vcreg[0x201];
    var gon = false;
    var tron = false;
    var pron = false;
    let kind = vc0 & 3;
    if kind == 0 {
        if (vc0 & 4) != 0 {
            if (vc2_1 & 0x10) != 0 {
                if (vc2_0 & 0x14) == 0x14 {
                    ppu.grp4h_line(mmu, sy, width, true);
                    pron = true;
                    tron = true;
                } else {
                    ppu.grp4h_line(mmu, sy, width, false);
                    gon = true;
                }
            }
        } else {
            if (vc2_0 & 0x10) != 0 && (vc2_1 & 1) != 0 {
                ppu.grp4_sp_line(mmu, (vc1_1 & 3), sy, width);
                pron = true;
                tron = true;
            }
            var opaq = true;
            if (vc2_1 & 8) != 0 {
                ppu.grp4_line(mmu, ((vc1_1 >> 6) & 3), sy, width, true);
                opaq = false;
                gon = true;
            }
            if (vc2_1 & 4) != 0 {
                ppu.grp4_line(mmu, ((vc1_1 >> 4) & 3), sy, width, opaq);
                opaq = false;
                gon = true;
            }
            if (vc2_1 & 2) != 0 {
                if (vc2_0 & 0x1E) == 0x1E && tron {
                    ppu.grp4_tr_line(mmu, ((vc1_1 >> 2) & 3), sy, width, opaq);
                } else {
                    ppu.grp4_line(mmu, ((vc1_1 >> 2) & 3), sy, width, opaq);
                }
                opaq = false;
                gon = true;
            }
            if (vc2_1 & 1) != 0 && (vc2_0 & 0x14) != 0x14 {
                ppu.grp4_line(mmu, (vc1_1 & 3), sy, width, opaq);
                gon = true;
            }
        }
    } else if kind == 1 || kind == 2 {
        var opaq = true;
        let page_first: i32 = if (vc1_1 & 3) > ((vc1_1 >> 4) & 3) { 1 } else { 0 };
        let page_second = page_first ^ 1;
        if (vc2_0 & 0x10) != 0 && (vc2_1 & 1) != 0 {
            ppu.grp8_sp_line(mmu, page_first, sy, width);
            tron = true;
            pron = true;
        }
        if (vc2_1 & 4) != 0 {
            ppu.grp8_line(mmu, page_second, sy, width, true);
            opaq = false;
            gon = true;
        }
        if (vc2_1 & 1) != 0 && (vc2_0 & 0x14) != 0x14 {
            ppu.grp8_line(mmu, page_first, sy, width, opaq);
            gon = true;
        }
    } else if kind == 3 {
        if (vc2_1 & 15) != 0 {
            if (vc2_0 & 0x14) == 0x14 {
                ppu.grp16_sp_line(mmu, sy, width);
                tron = true;
                pron = true;
            } else {
                ppu.grp16_line(mmu, sy, width);
                gon = true;
            }
        }
    }
    return gon, tron, pron;
}

fn scr_put_raw(ppu: X68kPPU&, i: i32, w: u16, opaq: bool) {
    if opaq || w != 0 {
        ppu.scr[i] = w;
        ppu.scr_mix[i] = 0;
    }
}

fn scr_put_argb(ppu: X68kPPU&, i: i32, c: u32) {
    ppu.scr_argb[i] = c;
    ppu.scr_mix[i] = 1;
    ppu.scr[i] = 1;
}

fn blit_grp(ppu: X68kPPU&, width: i32, opaq: bool) {
    assert(width >= 0 && width <= 1024);
    for i: i32 in width {
        if ppu.grp_mix[i] != 0 {
            ppu.scr_put_argb(i, ppu.grp_argb[i]);
        } else {
            ppu.scr_put_raw(i, ppu.grp[i], opaq);
        }
    }
}

fn blit_sp2(ppu: X68kPPU&, width: i32, opaq: bool) {
    assert(width >= 0 && width <= 1024);
    for i: i32 in width {
        ppu.scr_put_raw(i, ppu.sp2[i], opaq);
    }
}

fn blit_bg(ppu: X68kPPU&, width: i32, opaq: bool, td: bool, flagbit: i32) {
    assert(width >= 0 && width <= 1024);
    var i: i32 = 0;
    while i < width {
        let t = i + LINE_PAD;
        if !opaq && td && (ppu.line_tr[t] & (flagbit as u8)) == 0 {
            i += 1;
            continue;
        }
        ppu.scr_put_raw(i, ppu.line_bg[t], opaq);
        i += 1;
    }
}

fn blit_text_tr(ppu: X68kPPU&, width: i32, opaq: bool) {
    assert(width >= 0 && width <= 1024);
    for i: i32 in width {
        let t = i + LINE_PAD;
        let w = ppu.sp[i];
        let v = ppu.line_bg[t];
        if opaq {
            if w != 0 {
                ppu.scr_put_argb(i, argb_avg(pal_to_argb(w), pal_to_argb(v)));
            } else if (ppu.line_tr[t] & 1) != 0 {
                ppu.scr_put_raw(i, v, true);
            } else {
                ppu.scr_put_raw(i, 0, true);
            }
        } else if (ppu.line_tr[t] & 1) != 0 && v != 0 {
            if w != 0 {
                ppu.scr_put_argb(i, argb_avg(pal_to_argb(w), pal_to_argb(v)));
            } else {
                ppu.scr_put_raw(i, v, false);
            }
        }
    }
}

fn blit_bg_tr(ppu: X68kPPU&, width: i32, opaq: bool) {
    assert(width >= 0 && width <= 1024);
    for i: i32 in width {
        let t = i + LINE_PAD;
        let w = ppu.sp[i];
        let v = ppu.line_bg[t];
        if opaq {
            if w != 0 {
                ppu.scr_put_argb(i, argb_avg(pal_to_argb(w), pal_to_argb(v)));
            } else {
                ppu.scr_put_raw(i, v, true);
            }
        } else if (ppu.line_tr[t] & 2) != 0 && v != 0 {
            if w != 0 {
                ppu.scr_put_argb(i, argb_avg(pal_to_argb(w), pal_to_argb(v)));
            } else {
                ppu.scr_put_raw(i, v, false);
            }
        }
    }
}

fn text_one_line(ppu: X68kPPU&, mmu: M68kMMU&, width: i32, sy: i32, opaq: bool) {
    assert(width >= 0 && width <= 1024);
    let scroll_y = crtc_pair(mmu, CRTC_TEXT_Y) & 1023;
    let scroll_x = crtc_pair(mmu, CRTC_TEXT_X) & 1023;
    var vram_y = ((sy as u32) + scroll_y) & 1023;
    if (mmu.crtc_regs[0x29] & 0x1C) == 0x1C {
        vram_y = (vram_y + (sy as u32)) & 1023;
    }
    let line_base = (vram_y as i32) * 128;
    let col_bytes = width / 8;
    let start_col = ((scroll_x / 8) & 127) as i32;
    for col: i32 in col_bytes {
        let off = line_base + ((start_col + col) & 127);
        let b0: u32 = mmu.tvram[off];
        let b1: u32 = mmu.tvram[off + 0x20000];
        let b2: u32 = mmu.tvram[off + 0x40000];
        let b3: u32 = mmu.tvram[off + 0x60000];
        let any_bits = b0 | b1 | b2 | b3;
        for px: i32 in 8 {
            let x = col * 8 + px;
            if x >= width { return; }
            let t = x + LINE_PAD;
            let mask: u32 = 0x80 >> (px as u32);
            var c_idx: i32 = 0;
            if (any_bits & mask) != 0 {
                var bit0: i32 = 0;
                var bit1: i32 = 0;
                var bit2: i32 = 0;
                var bit3: i32 = 0;
                if (b0 & mask) != 0 { bit0 = 1; }
                if (b1 & mask) != 0 { bit1 = 2; }
                if (b2 & mask) != 0 { bit2 = 4; }
                if (b3 & mask) != 0 { bit3 = 8; }
                c_idx = bit0 | bit1 | bit2 | bit3;
            }
            if c_idx != 0 {
                ppu.line_bg[t] = pal_text_idx(mmu, c_idx);
                if opaq {
                    ppu.line_tr[t] = 1;
                } else {
                    ppu.line_tr[t] |= 1;
                }
            } else if opaq {
                ppu.line_bg[t] = pal_text_idx(mmu, 0);
                ppu.line_tr[t] = 0;
            }
        }
    }
}

fn compose_back(ppu: X68kPPU&, sy: i32, screen_w: i32, width: i32, gon: bool, ton: bool, bgon: bool, tron: bool, pron: bool, vc1_0: i32, vc2_0: i32) {
    assert(width >= 0 && width <= 1024);
    for i: i32 in width {
        ppu.scr[i] = 0;
        ppu.scr_mix[i] = 0;
    }
    var tdrawed = false;
    var opaq = true;
    if (vc1_0 & 0x02) != 0 && gon {
        ppu.blit_grp(width, opaq);
        opaq = false;
    }
    if (vc1_0 & 0x02) != 0 && tron {
        ppu.blit_sp2(width, opaq);
        opaq = false;
    }
    if (vc1_0 & 0x20) != 0 && bgon {
        if (vc2_0 & 0x5D) == 0x1D && (vc1_0 & 0x03) != 0x02 && tron && (vc1_0 & 3) < ((vc1_0 >> 2) & 3) {
            ppu.blit_bg_tr(width, opaq);
            tdrawed = true;
            opaq = false;
        } else {
            ppu.blit_bg(width, opaq, tdrawed, 2);
            tdrawed = true;
            opaq = false;
        }
    }
    if (vc1_0 & 0x08) != 0 && ton {
        if (vc2_0 & 0x5D) == 0x1D && (vc1_0 & 0x03) != 0x02 && tron {
            ppu.blit_text_tr(width, opaq);
        } else {
            ppu.blit_bg(width, opaq, tdrawed, 1);
        }
        opaq = false;
        tdrawed = true;
    }
    if (vc1_0 & 0x03) == 0x01 && gon {
        ppu.blit_grp(width, opaq);
        opaq = false;
    }
    if (vc1_0 & 0x30) == 0x10 && bgon {
        if (vc2_0 & 0x5D) == 0x1D && (vc1_0 & 0x03) == 0 && tron && (vc1_0 & 3) < ((vc1_0 >> 2) & 3) {
            ppu.blit_bg_tr(width, opaq);
            tdrawed = true;
            opaq = false;
        } else {
            let td = (vc1_0 & 0x0C) == 0x08;
            ppu.blit_bg(width, opaq, td, 2);
            tdrawed = true;
            opaq = false;
        }
    }
    if (vc1_0 & 0x0C) == 0x04 && (vc2_0 & 0x5D) == 0x1D && (vc1_0 & 0x03) != 0 && ((vc1_0 >> 4) & 3) > (vc1_0 & 3) && bgon && tron {
        ppu.blit_bg_tr(width, opaq);
        tdrawed = true;
        opaq = false;
        ppu.blit_sp2(width, opaq);
    } else if (vc1_0 & 0x03) == 0x01 && tron && gon && (vc2_0 & 0x10) != 0 {
        ppu.blit_sp2(width, opaq);
        opaq = false;
    }
    if (vc1_0 & 0x0C) == 0x04 && ton {
        if (vc2_0 & 0x5D) == 0x1D && (vc1_0 & 0x03) == 0 && tron {
            ppu.blit_text_tr(width, opaq);
        } else {
            let td2 = (vc1_0 & 0x30) >= 0x10;
            ppu.blit_bg(width, opaq, td2, 1);
        }
        opaq = false;
        tdrawed = true;
    }
    if (vc1_0 & 0x03) == 0 && gon {
        ppu.blit_grp(width, opaq);
        opaq = false;
    }
    if (vc1_0 & 0x30) == 0 && bgon {
        let td3 = (vc1_0 & 0x0C) >= 0x04;
        ppu.blit_bg(width, opaq, td3, 2);
        tdrawed = true;
        opaq = false;
    }
    if (vc1_0 & 0x0C) == 0 && (vc2_0 & 0x5D) == 0x1D && ((vc1_0 >> 4) & 3) > (vc1_0 & 3) && bgon && tron {
        ppu.blit_bg_tr(width, opaq);
        tdrawed = true;
        opaq = false;
        ppu.blit_sp2(width, opaq);
    } else if (vc1_0 & 0x03) == 0 && tron && (vc2_0 & 0x10) != 0 {
        ppu.blit_sp2(width, opaq);
        opaq = false;
    }
    if (vc1_0 & 0x0C) == 0 && ton {
        ppu.blit_bg(width, opaq, true, 1);
        tdrawed = true;
        opaq = false;
    }
    if (vc2_0 & 0x5C) == 0x14 && pron {
        for j: i32 in width {
            ppu.scr_put_raw(j, ppu.sp[j], false);
        }
    } else if (vc2_0 & 0x5D) == 0x1C && tron {
        var black: u32 = 0xFF000000;
        for j: i32 in width {
            if ppu.sp[j] != 0 && ppu.scr_mix[j] == 0 && ppu.scr[j] == 0 {
                ppu.scr_put_argb(j, argb_avg(pal_to_argb(ppu.sp[j]), black));
            }
        }
    }
    if opaq {
        for k: i32 in width {
            ppu.scr[k] = 0;
            ppu.scr_mix[k] = 0;
        }
    }
    for x: i32 in width {
        let c = if ppu.scr_mix[x] != 0 { ppu.scr_argb[x] } else { pal_to_argb(ppu.scr[x]) };
        ppu.fb[sy * screen_w + x] = c;
    }
}

fn apply_screen(ppu: X68kPPU&, mmu: M68kMMU&) {
    var dot_x: i32 = 768;
    let hstart = mmu.crtc_word(CRTC_HSTART) & 1023;
    let hend = mmu.crtc_word(CRTC_HEND) & 1023;
    if hend > hstart { dot_x = (hend - hstart) * 8; }
    var dot_y: i32 = 512;
    let vstart = mmu.crtc_word(CRTC_VSTART) & 1023;
    let vend = mmu.crtc_word(CRTC_VEND) & 1023;
    if vend > vstart { dot_y = vend - vstart; }
    let mode: i32 = mmu.crtc_regs[0x29];
    if (mode & 0x14) == 0x10 {
        dot_y = dot_y / 2;
    } else if (mode & 0x14) == 0x04 {
        dot_y = dot_y * 2;
    }
    // フレームバッファは 768x512 まで。200 ラインなどの CRTC は px68k と同じくそのまま使う。
    if dot_x < 1 || dot_x > 768 || dot_y < 1 || dot_y > 512 {
        dot_x = 768;
        dot_y = 512;
    }
    ppu.screen_w = dot_x;
    ppu.screen_h = dot_y;
}

fn begin_frame(ppu: X68kPPU&, mmu: M68kMMU&) {
    ppu.apply_screen(mmu);
    ppu.clear(0xFF000000);
    ppu.frame_ready = true;
}

// 画面の大きさの範囲を色 argb で塗る
fn clear(ppu: X68kPPU&, argb: u32) {
    let pixels = clamp(ppu.screen_w * ppu.screen_h, 0, 393216);
    fill(ppu.fb[..pixels], argb);
}

// 画面の 1 ライン (sy) を描く。グラフィック、テキスト、BG、スプライトを面ごとに作り、
// ビデオコントローラの優先順位で合成してフレームバッファへ書く。
fn draw_line(ppu: X68kPPU&, mmu: M68kMMU&, sy: i32) {
    if sy < 0 || sy >= ppu.screen_h { return; }
    var width = ppu.screen_w;
    if width > 1024 { width = 1024; }
    if width < 1 { return; }
    ppu.clear_front();
    let vc1_0: i32 = mmu.vcreg[0x100];
    let vc2_0: i32 = mmu.vcreg[0x200];
    let vc2_1: i32 = mmu.vcreg[0x201];
    let gon, tron, pron = ppu.grp_lines(mmu, sy, width);
    let sp_on = (vc2_1 & 0x40) != 0 && (mmu.bgreg[0x11] & 2) == 0;
    let text_on = (vc2_1 & 0x20) != 0;
    var ton = false;
    var bgon = false;
    if ((vc1_0 & 0x30) >> 2) < (vc1_0 & 0x0C) {
        if text_on {
            ppu.text_one_line(mmu, width, sy, true);
            ton = true;
        }
        if sp_on {
            let opaq = !ton;
            // px68k BG_DrawLine(..., gd=0)。パターン 0 は描かない。
            ppu.bg_draw_line(mmu, width, sy, opaq, true);
            bgon = true;
        }
    } else {
        if sp_on {
            // px68k BG_DrawLine(..., gd=1)。パレットだけのドットも描く。
            ppu.bg_draw_line(mmu, width, sy, true, false);
            bgon = true;
        } else {
            if text_on { ppu.bg_fill_pal0(mmu, width); }
            bgon = true;
        }
        if text_on {
            let opaq = !bgon;
            ppu.text_one_line(mmu, width, sy, opaq);
            ton = true;
        }
    }
    ppu.compose_back(sy, ppu.screen_w, width, gon, ton, bgon, tron, pron, vc1_0, vc2_0);
}
