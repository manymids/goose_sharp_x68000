// Sharp X68000 PPU (Text & Graphic合成描画) in Goose

import std;
import .x68k_bridge;
import .m68k_types;
import .m68k_mmu;

var g_screen_w: i32 = 768;
var g_screen_h: i32 = 512;

fn x68k_screen_bind() {
    c_screen_bind(g_screen_w, g_screen_h);
}

struct X68kPPU {
    frame_ready: bool = false,
    scanline: i32 = 0,
    line_bg: u16[1040] = [0; 1040],
    line_tr: u8[1040] = [0; 1040],
    line_bpri: u16[1040] = [0; 1040],
    grp: u16[1024] = [0; 1024],
    grp_mix: u8[1024] = [0; 1024],
    grp_argb: u32[1024] = [0; 1024],
    sp: u16[1024] = [0; 1024],
    sp2: u16[1024] = [0; 1024],
    scr: u16[1024] = [0; 1024],
    scr_mix: u8[1024] = [0; 1024],
    scr_argb: u32[1024] = [0; 1024],
    fb: u32[393216] = [0; 393216]
}

fn ppu_init(ppu: X68kPPU&) {
    ppu.frame_ready = false;
    ppu.scanline = 0;
}

fn pal_text_idx(mmu: M68kMMU&, idx: i32) -> u16 {
    let i = idx & 255;
    let o = 0x200 + i * 2;
    if o + 1 >= 1024 { return 0; }
    return ((mmu.pal[o] as u16) << 8) | (mmu.pal[o + 1] as u16);
}

fn ppu_sprites_to_line(ppu: X68kPPU&, mmu: M68kMMU&, pri: i32, width: i32, sy: i32) {
    let crtc_hstart = (((mmu.crtc_regs[0x04] as i32) << 8) | (mmu.crtc_regs[0x05] as i32)) & 1023;
    let crtc_vstart = (((mmu.crtc_regs[0x0C] as i32) << 8) | (mmu.crtc_regs[0x0D] as i32)) & 1023;
    let reg0d = mmu.crtc_regs[0x0D] as i32;
    let reg29 = mmu.crtc_regs[0x29] as i32;
    let bgreg_0d = mmu.bgreg[0x0D] as i32;
    let bgreg_0f = mmu.bgreg[0x0F] as i32;
    let bgreg_11 = mmu.bgreg[0x11] as i32;
    let s1 = (if (bgreg_11 & 4) != 0 { 2 } else { 1 }) - (if (bgreg_11 & 16) != 0 { 1 } else { 0 });
    let s2 = (if (reg29 & 4) != 0 { 2 } else { 1 }) - (if (reg29 & 16) != 0 { 1 } else { 0 });
    var vlinebg: u32 = sy as u32;
    vlinebg = vlinebg << s1;
    vlinebg = vlinebg >> s2;
    if (bgreg_11 & 16) == 0 {
        let left = (bgreg_0f >> s1) as u32;
        let right = (reg0d >> s2) as u32;
        vlinebg = vlinebg - (left - right);
    }
    let bg_vline = (bgreg_0f - crtc_vstart) / (if (bgreg_11 & 4) != 0 { 1 } else { 2 });
    let h_adj = (bgreg_0d - (crtc_hstart + 4)) * 8;
    var n = 127;
    while n >= 0 {
        let cur = n;
        n = n - 1;
        let base = cur * 8;
        let raw_x = ((mmu.sprite[base] as u16) << 8) | (mmu.sprite[base + 1] as u16);
        let raw_y = ((mmu.sprite[base + 2] as u16) << 8) | (mmu.sprite[base + 3] as u16);
        let ctrl = ((mmu.sprite[base + 4] as u16) << 8) | (mmu.sprite[base + 5] as u16);
        let ply = mmu.sprite[base + 7];
        if (ply & 3) != (pri as u8) { continue; }
        let t0 = (((raw_x as i32) + h_adj) & 0x3FF) as u32;
        if t0 >= ((width + 16) as u32) { continue; }
        var y: u32 = (raw_y & 0x3FF) as u32;
        y = y - vlinebg;
        y = y + (bg_vline as! u32);
        y = 0 - y;
        y = y + 16;
        if y > 15 { continue; }
        let ctrl_i = ctrl as i32;
        let pat = ctrl_i & 0xFF;
        let flip_x = (ctrl_i & 0x4000) != 0;
        let flip_y = (ctrl_i & 0x8000) != 0;
        let src_y = if flip_y { 15 - (y as i32) } else { y as i32 };
        let pal_bank = (ctrl_i & 0x0F00) >> 4;
        var px = 0;
        var t = t0;
        while px < 16 {
            let src_x = if flip_x { 15 - px } else { px };
            let tt = t;
            px = px + 1;
            t = t + 1;
            if tt < 16 || tt >= ((width + 16) as u32) || tt >= 1040 { continue; }
            let src = pat * 256 + src_y * 16 + src_x;
            let col = mmu.bg_chr16[src] & 0x0F;
            if col == 0 { continue; }
            let ti = tt as i64;
            let pri_n = (cur * 8) as u16;
            if ppu.line_bpri[ti] < pri_n { continue; }
            ppu.line_bg[ti] = pal_text_idx(mmu, pal_bank | (col as i32));
            ppu.line_tr[ti] = ppu.line_tr[ti] | 2;
            ppu.line_bpri[ti] = pri_n;
        }
    }
}

fn ppu_plot_bg(ppu: X68kPPU&, mmu: M68kMMU&, sx: i32, screen_w: i32, idx: u8) {
    if idx == 0 || sx < 0 || sx >= screen_w { return; }
    let pal = 0x200 + (idx as i32) * 2;
    if pal + 1 >= 1024 { return; }
    let p_val = ((mmu.pal[pal] as u16) << 8) | (mmu.pal[pal + 1] as u16);
    let t = sx + 16;
    if t >= 16 && t < 1040 {
        ppu.line_bg[t] = p_val;
        ppu.line_tr[t] = ppu.line_tr[t] | 2;
    }
}

fn ppu_draw_bg_map(ppu: X68kPPU&, mmu: M68kMMU&, screen_w: i32, sy: i32, scroll_x: i32, scroll_y: i32, adjust: i32, vline: i32, top: i32, wide: i32, ng: i32) {
    let line = (scroll_y as u32) + (sy as u32) - (vline as! u32);
    var span: i32 = 8;
    if wide != 0 { span = 16; }
    let rel = scroll_x - adjust;
    let edi = (rel & (span - 1)) ^ 15;
    var shift: i32 = 2;
    var xmask: i32 = 0x1F8;
    if wide != 0 {
        shift = 3;
        xmask = 0x3F0;
    }
    var ecx = (rel & xmask) >> shift;
    var row_shift: i32 = 4;
    if wide != 0 { row_shift = 3; }
    let row = ((line & (xmask as u32)) << row_shift) as i32;
    let fine = (line & ((span - 1) as u32)) as i32;
    let tiles = screen_w / span + 2;
    var sx0: i32 = edi - 15;
    var chr_bytes: i32 = 16384;
    if wide != 0 { chr_bytes = 65536; }
    var tile: i32 = 0;
    while tile < tiles {
        let map = top + row + (ecx & 0x7F);
        ecx = (ecx + 2) & 0x7F;
        if map < 0 || map + 1 >= 32768 {
            sx0 = sx0 + span;
            tile = tile + 1;
            continue;
        }
        let attr = mmu.bgram[map];
        let attr_i = attr as i32;
        let si = if wide != 0 { (mmu.bgram[map + 1] as i32) << 8 } else { (mmu.bgram[map + 1] as i32) << 6 };
        let ebp = if wide != 0 { fine << 4 } else { fine << 3 };
        var origin: i32 = 0;
        var d: i32 = 1;
        if attr_i < 0x40 {
            origin = si + ebp;
            d = 1;
        } else if ((attr_i - 0x40) & 0x80) != 0 {
            origin = si + (if wide != 0 { 0xFF } else { 0x3F }) - ebp;
            d = -1;
        } else if (attr as! i8) >= 0x40 {
            origin = si + ebp + (span - 1);
            d = -1;
        } else {
            origin = si + (if wide != 0 { 0xF0 } else { 0x38 }) - ebp;
            d = 1;
        }
        let pal_hi = ((attr_i << 4) & 0xFF) as u8;
        var j: i32 = 0;
        while j < span {
            let src = origin + j * d;
            if src >= 0 && src < chr_bytes {
                // パターンのニブルが 0 のドットは、px68k の ng 経路では描かない。
                // gd 経路でも、すでに BG かスプライトがある画素は上書きしない。
                // 上書きすると色 0 のタイルが手前の地面を消して格子になる。
                let nib = if wide != 0 { mmu.bg_chr16[src] & 0x0F } else { mmu.bg_chr8[src] & 0x0F };
                let t = sx0 + j + 16;
                var covered: i32 = 0;
                if t >= 0 && t < 1040 && (ppu.line_tr[t] & 2) != 0 { covered = 1; }
                if nib != 0 || (ng == 0 && covered == 0) {
                    ppu_plot_bg(ppu, mmu, sx0 + j, screen_w, nib | pal_hi);
                }
            }
            j = j + 1;
        }
        sx0 = sx0 + span;
        tile = tile + 1;
    }
}

fn ppu_bg_plane(ppu: X68kPPU&, mmu: M68kMMU&, which: i32, width: i32, sy: i32, ng: i32) {
    let r0 = mmu.crtc_regs;
    let hstart = (((r0[0x04] as i32) << 8) | (r0[0x05] as i32)) & 1023;
    let vstart = (((r0[0x0C] as i32) << 8) | (r0[0x0D] as i32)) & 1023;
    let adjust = ((mmu.bgreg[0x0D] as i32) - (hstart + 4)) * 8;
    var vdiv: i32 = 2;
    if (mmu.bgreg[0x11] & 4) != 0 { vdiv = 1; }
    let vline = ((mmu.bgreg[0x0F] as i32) - vstart) / vdiv;
    let cfg = mmu.bgreg[0x09];
    if which == 1 {
        if (cfg & 8) == 0 || (mmu.bgreg[0x11] & 3) != 0 { return; }
        var top: i32 = 0x4000;
        if (cfg & 0x30) != 0 { top = 0x6000; }
        var mask: i32 = 511;
        let sx1 = (((mmu.bgreg[0x04] as i32) << 8) | (mmu.bgreg[0x05] as i32)) & mask;
        let sy1 = (((mmu.bgreg[0x06] as i32) << 8) | (mmu.bgreg[0x07] as i32)) & mask;
        ppu_draw_bg_map(ppu, mmu, width, sy, sx1, sy1, adjust, vline, top, 0, ng);
        return;
    }
    if (cfg & 1) == 0 { return; }
    var chr16: i32 = 0;
    if (mmu.bgreg[0x11] & 3) != 0 { chr16 = 1; }
    var mask: i32 = 511;
    if chr16 != 0 { mask = 1023; }
    var top: i32 = 0x4000;
    if (cfg & 0x06) != 0 { top = 0x6000; }
    let sx0 = (((mmu.bgreg[0x00] as i32) << 8) | (mmu.bgreg[0x01] as i32)) & mask;
    let sy0 = (((mmu.bgreg[0x02] as i32) << 8) | (mmu.bgreg[0x03] as i32)) & mask;
    ppu_draw_bg_map(ppu, mmu, width, sy, sx0, sy0, adjust, vline, top, chr16, ng);
}

fn ppu_clear_front(ppu: X68kPPU&) {
    c_line_zero(ppu.grp[0], ppu.grp_mix[0], ppu.sp[0], ppu.sp2[0], ppu.line_bg[0], ppu.line_tr[0]);
}

fn ppu_bg_line_clear(ppu: X68kPPU&, mmu: M68kMMU&, width: i32, opaq: i32) {
    let fill = pal_text_idx(mmu, 0);
    var i: i32 = 16;
    let end = width + 16;
    while i < end && i < 1040 {
        ppu.line_bpri[i as i64] = 0xFFFF;
        if opaq != 0 { ppu.line_bg[i as i64] = fill; }
        i = i + 1;
    }
}

fn ppu_bg_fill_pal0(ppu: X68kPPU&, mmu: M68kMMU&, width: i32) {
    let fill = pal_text_idx(mmu, 0);
    var i: i32 = 16;
    let end = width + 16;
    while i < end && i < 1040 {
        ppu.line_bg[i as i64] = fill;
        i = i + 1;
    }
}

fn ppu_bg_draw_line(ppu: X68kPPU&, mmu: M68kMMU&, width: i32, sy: i32, opaq: i32, ng: i32) {
    ppu_bg_line_clear(ppu, mmu, width, opaq);
    ppu_sprites_to_line(ppu, mmu, 1, width, sy);
    ppu_bg_plane(ppu, mmu, 1, width, sy, ng);
    ppu_sprites_to_line(ppu, mmu, 2, width, sy);
    ppu_bg_plane(ppu, mmu, 0, width, sy, ng);
    ppu_sprites_to_line(ppu, mmu, 3, width, sy);
}

fn crtc_pair(mmu: M68kMMU&, hi: i32) -> u32 {
    return ((mmu.crtc_regs[hi] as u32) << 8) | (mmu.crtc_regs[hi + 1] as u32);
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
    return (mmu.gvram[o as i64] as u16) | ((mmu.gvram[n as i64] as u16) << 8);
}

fn pal_grph(mmu: M68kMMU&, idx: i32) -> u16 {
    let i = idx & 255;
    let o = i * 2;
    return ((mmu.pal[o] as u16) << 8) | (mmu.pal[o + 1] as u16);
}

fn pal_to_argb(pal_val: u16) -> u32 {
    let gg = (pal_val & 1) as u32;
    let pv = pal_val as u32;
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

fn ppu_grp4_store(ppu: X68kPPU&, mmu: M68kMMU&, sx: i32, v: u16, high: i32, opaq: i32) {
    var idx: i32 = (v & 0x0F) as i32;
    if high != 0 { idx = ((v >> 4) & 0x0F) as i32; }
    if opaq != 0 || idx != 0 {
        ppu.grp[sx] = pal_grph(mmu, idx);
        ppu.grp_mix[sx] = 0;
    }
}

fn ppu_grp4_line(ppu: X68kPPU&, mmu: M68kMMU&, page: i32, sy: i32, width: i32, opaq: i32) {
    let p = page & 3;
    let scroll_x = crtc_pair(mmu, grp_xhi(p)) & grp_mask(p);
    let scroll_y = crtc_pair(mmu, grp_yhi(p)) & grp_mask(p);
    var high: i32 = 0;
    if (p & 1) != 0 { high = 1; }
    var y = scroll_y + (sy as u32);
    if (mmu.crtc_regs[0x29] & 0x1C) == 0x1C { y = y + (sy as u32); }
    y = (y & 0x1FF) << 10;
    let xs = scroll_x & 0x1FF;
    var off = y + xs * 2 + ((p >> 1) as u32);
    let span = xs ^ 0x1FF;
    var sx: i32 = 0;
    if span < (width as u32) {
        while sx < (span as i32) {
            ppu_grp4_store(ppu, mmu, sx, gvram_le(mmu, off), high, opaq);
            off = off + 2;
            sx = sx + 1;
        }
        off = off - 0x400;
    }
    while sx < width {
        ppu_grp4_store(ppu, mmu, sx, gvram_le(mmu, off), high, opaq);
        off = off + 2;
        sx = sx + 1;
    }
}

fn ppu_grp4_sp_line(ppu: X68kPPU&, mmu: M68kMMU&, page: i32, sy: i32, width: i32) {
    let p = page & 3;
    let scroll_x = crtc_pair(mmu, grp_xhi(p)) & grp_mask(p);
    let scroll_y = crtc_pair(mmu, grp_yhi(p)) & grp_mask(p);
    var y = scroll_y + (sy as u32);
    if (mmu.crtc_regs[0x29] & 0x1C) == 0x1C { y = y + (sy as u32); }
    y = (y & 0x1FF) << 10;
    let x = scroll_x & 0x1FF;
    var add: u32 = 0;
    if (p & 2) != 0 { add = 1; }
    var off = y + x * 2 + add;
    var left = (x ^ 0x1FF) + 1;
    var high: i32 = 0;
    if (p & 1) != 0 { high = 1; }
    var i: i32 = 0;
    while i < width {
        let b = gvram_at(mmu, off);
        var nib = b;
        if high != 0 { nib = b >> 4; }
        let bit0 = (nib & 1) != 0;
        let col = pal_grph(mmu, (nib & 0x0E) as i32);
        if !bit0 {
            ppu.sp[i] = 0;
            ppu.sp2[i] = col;
        } else {
            ppu.sp[i] = col;
            ppu.sp2[i] = 0;
        }
        off = off + 2;
        left = left - 1;
        if left == 0 { off = off - 0x400; }
        i = i + 1;
    }
}

fn ppu_grp4_tr_line(ppu: X68kPPU&, mmu: M68kMMU&, page: i32, sy: i32, width: i32, opaq: i32) {
    let p = page & 3;
    let scroll_x = crtc_pair(mmu, grp_xhi(p)) & grp_mask(p);
    let scroll_y = crtc_pair(mmu, grp_yhi(p)) & grp_mask(p);
    var y = scroll_y + (sy as u32);
    if (mmu.crtc_regs[0x29] & 0x1C) == 0x1C { y = y + (sy as u32); }
    y = (y & 0x1FF) << 10;
    y = y + ((p >> 1) as u32);
    var high: i32 = 0;
    if (p & 1) != 0 { high = 1; }
    var x = scroll_x & 0x1FF;
    var i: i32 = 0;
    while i < width {
        let b = gvram_at(mmu, y + x * 2);
        var nib: i32 = (b & 0x0F) as i32;
        if high != 0 { nib = ((b >> 4) & 0x0F) as i32; }
        let v0 = ppu.sp[i];
        var wrote: i32 = 0;
        if v0 != 0 && nib != 0 {
            let gp = pal_grph(mmu, nib);
            if gp != 0 {
                ppu.grp_argb[i] = argb_avg(pal_to_argb(v0), pal_to_argb(gp));
                ppu.grp_mix[i] = 1;
                ppu.grp[i] = 1;
                wrote = 1;
            }
        }
        if wrote == 0 && (opaq != 0 || (v0 == 0 && nib != 0)) {
            var stored: u16 = 0;
            if v0 == 0 { stored = pal_grph(mmu, nib); }
            ppu.grp[i] = stored;
            ppu.grp_mix[i] = 0;
        } else if wrote == 0 && opaq == 0 && v0 != 0 && nib == 0 {
            ppu.grp[i] = 0;
            ppu.grp_mix[i] = 0;
        }
        x = (x + 1) & 0x1FF;
        i = i + 1;
    }
}

fn ppu_grp4h_line(ppu: X68kPPU&, mmu: M68kMMU&, sy: i32, width: i32, special: i32) {
    let scroll_x = crtc_pair(mmu, 0x18) & 1023;
    let scroll_y = crtc_pair(mmu, 0x1A) & 1023;
    var y = scroll_y + (sy as u32);
    if (mmu.crtc_regs[0x29] & 0x1C) == 0x1C { y = y + (sy as u32); }
    y = y & 0x3FF;
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
    var sx: i32 = 0;
    while sx < width {
        let v = gvram_le(mmu, off);
        let idx = ((v as u32) >> bits) & 0x0F;
        if special != 0 {
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
        off = off + 2;
        left = left - 1;
        if left == 0 {
            off = off - 0x400;
            if special == 0 { bits = bits ^ 4; }
            left = 512;
        }
        sx = sx + 1;
    }
}

fn ppu_grp8_line(ppu: X68kPPU&, mmu: M68kMMU&, page: i32, sy: i32, width: i32, opaq: i32) {
    let p = page & 1;
    let p0 = p * 2;
    let p1 = p0 + 1;
    var y = (crtc_pair(mmu, grp_yhi(p0)) & grp_mask(p0)) + (sy as u32);
    var y0 = (crtc_pair(mmu, grp_yhi(p1)) & grp_mask(p1)) + (sy as u32);
    if (mmu.crtc_regs[0x29] & 0x1C) == 0x1C {
        y = y + (sy as u32);
        y0 = y0 + (sy as u32);
    }
    y = ((y & 0x1FF) << 10) + (p as u32);
    y0 = ((y0 & 0x1FF) << 10) + (p as u32);
    let x = (crtc_pair(mmu, grp_xhi(p0)) & grp_mask(p0)) & 0x1FF;
    let x0 = (crtc_pair(mmu, grp_xhi(p1)) & grp_mask(p1)) & 0x1FF;
    var src = y + x * 2;
    var off = y0 + x0 * 2;
    var left = (x ^ 0x1FF) + 1;
    var wrapped: i32 = 0;
    var i: i32 = 0;
    while i < width {
        let vw = gvram_le(mmu, src);
        let idx = (gvram_at(mmu, off) & 0xF0) | ((vw & 0x0F) as u8);
        if opaq != 0 || idx != 0 {
            ppu.grp[i] = pal_grph(mmu, idx as i32);
            ppu.grp_mix[i] = 0;
        }
        src = src + 2;
        off = off + 2;
        if (off & 0x3FE) == 0 { off = off - 0x400; }
        left = left - 1;
        if wrapped == 0 && left == 0 {
            src = src - 0x400;
            wrapped = 1;
        }
        i = i + 1;
    }
}

fn ppu_grp8_sp_line(ppu: X68kPPU&, mmu: M68kMMU&, page: i32, sy: i32, width: i32) {
    let p = page & 1;
    let p0 = p * 2;
    let p1 = p0 + 1;
    var y = (crtc_pair(mmu, grp_yhi(p0)) & grp_mask(p0)) + (sy as u32);
    var y0 = (crtc_pair(mmu, grp_yhi(p1)) & grp_mask(p1)) + (sy as u32);
    if (mmu.crtc_regs[0x29] & 0x1C) == 0x1C {
        y = y + (sy as u32);
        y0 = y0 + (sy as u32);
    }
    y = (y & 0x1FF) << 10;
    y0 = (y0 & 0x1FF) << 10;
    let x = (crtc_pair(mmu, grp_xhi(p0)) & grp_mask(p0)) & 0x1FF;
    let x0 = (crtc_pair(mmu, grp_xhi(p1)) & grp_mask(p1)) & 0x1FF;
    var off = y + x * 2 + (p as u32);
    var off0 = y0 + x0 * 2 + (p as u32);
    var left = (x ^ 0x1FF) + 1;
    var i: i32 = 0;
    while i < width {
        let raw = (gvram_at(mmu, off) & 0x0F) | (gvram_at(mmu, off0) & 0xF0);
        let v = raw & 0xFE;
        if (raw & 1) == 0 {
            var col: u16 = 0;
            if v != 0 { col = pal_grph(mmu, v as i32); }
            ppu.sp[i] = 0;
            ppu.sp2[i] = col;
        } else {
            var col: u16 = 0;
            if v != 0 { col = pal_grph(mmu, v as i32) | 1; }
            ppu.sp[i] = col;
            ppu.sp2[i] = 0;
        }
        off = off + 2;
        off0 = off0 + 2;
        if (off0 & 0x3FE) == 0 { off0 = off0 - 0x400; }
        left = left - 1;
        if left == 0 { off = off - 0x400; }
        i = i + 1;
    }
}

fn pal16_adr(b: i32) -> i32 {
    let n = b & 255;
    return ((n & 0xFE) << 1) | (n & 1);
}

fn ppu_grp16_line(ppu: X68kPPU&, mmu: M68kMMU&, sy: i32, width: i32) {
    var y = (crtc_pair(mmu, 0x1A) & 1023) + (sy as u32);
    if (mmu.crtc_regs[0x29] & 0x1C) == 0x1C { y = y + (sy as u32); }
    y = (y & 0x1FF) << 10;
    let x = (crtc_pair(mmu, 0x18) & 1023) & 0x1FF;
    var src = y + x * 2;
    var left = (x ^ 0x1FF) + 1;
    var wrapped: i32 = 0;
    var i: i32 = 0;
    while i < width {
        let vw = gvram_le(mmu, src);
        var out: u16 = 0;
        if vw != 0 {
            let a_lo = pal16_adr((vw & 0xFF) as i32);
            let a_hi = pal16_adr(((vw >> 8) & 0xFF) as i32) + 2;
            if a_hi < 1024 {
                out = ((mmu.pal[a_hi] as u16) << 8) | (mmu.pal[a_lo] as u16);
            }
        }
        ppu.grp[i] = out;
        ppu.grp_mix[i] = 0;
        src = src + 2;
        left = left - 1;
        if wrapped == 0 && left == 0 {
            src = src - 0x400;
            wrapped = 1;
        }
        i = i + 1;
    }
}

fn ppu_grp16_sp_line(ppu: X68kPPU&, mmu: M68kMMU&, sy: i32, width: i32) {
    var y = (crtc_pair(mmu, 0x1A) & 1023) + (sy as u32);
    if (mmu.crtc_regs[0x29] & 0x1C) == 0x1C { y = y + (sy as u32); }
    y = (y & 0x1FF) << 10;
    let x = (crtc_pair(mmu, 0x18) & 1023) & 0x1FF;
    var off = y + x * 2;
    var left = (x ^ 0x1FF) + 1;
    var i: i32 = 0;
    while i < width {
        let b0 = gvram_at(mmu, off);
        let b1 = gvram_at(mmu, off + 1);
        var v = ((mmu.pal[(b1 as i32) * 2] as u16) << 8) | (mmu.pal[(b0 as i32) * 2 + 1] as u16);
        v = v & 0xFFFE;
        if (b0 & 1) == 0 {
            ppu.sp[i] = 0;
            ppu.sp2[i] = v;
        } else {
            ppu.sp[i] = v;
            ppu.sp2[i] = 0;
        }
        off = off + 2;
        left = left - 1;
        if left == 0 { off = off - 0x400; }
        i = i + 1;
    }
}

fn ppu_grp_lines(ppu: X68kPPU&, mmu: M68kMMU&, sy: i32, width: i32, gon: i32&, tron: i32&, pron: i32&) {
    let vc0 = mmu.vcreg[1];
    let vc1_1 = mmu.vcreg[0x101];
    let vc2_0 = mmu.vcreg[0x200];
    let vc2_1 = mmu.vcreg[0x201];
    gon = 0;
    tron = 0;
    pron = 0;
    let kind = vc0 & 3;
    if kind == 0 {
        if (vc0 & 4) != 0 {
            if (vc2_1 & 0x10) != 0 {
                if (vc2_0 & 0x14) == 0x14 {
                    ppu_grp4h_line(ppu, mmu, sy, width, 1);
                    pron = 1;
                    tron = 1;
                } else {
                    ppu_grp4h_line(ppu, mmu, sy, width, 0);
                    gon = 1;
                }
            }
        } else {
            if (vc2_0 & 0x10) != 0 && (vc2_1 & 1) != 0 {
                ppu_grp4_sp_line(ppu, mmu, (vc1_1 & 3) as i32, sy, width);
                pron = 1;
                tron = 1;
            }
            var opaq: i32 = 1;
            if (vc2_1 & 8) != 0 {
                ppu_grp4_line(ppu, mmu, ((vc1_1 >> 6) & 3) as i32, sy, width, 1);
                opaq = 0;
                gon = 1;
            }
            if (vc2_1 & 4) != 0 {
                ppu_grp4_line(ppu, mmu, ((vc1_1 >> 4) & 3) as i32, sy, width, opaq);
                opaq = 0;
                gon = 1;
            }
            if (vc2_1 & 2) != 0 {
                if (vc2_0 & 0x1E) == 0x1E && tron != 0 {
                    ppu_grp4_tr_line(ppu, mmu, ((vc1_1 >> 2) & 3) as i32, sy, width, opaq);
                } else {
                    ppu_grp4_line(ppu, mmu, ((vc1_1 >> 2) & 3) as i32, sy, width, opaq);
                }
                opaq = 0;
                gon = 1;
            }
            if (vc2_1 & 1) != 0 && (vc2_0 & 0x14) != 0x14 {
                ppu_grp4_line(ppu, mmu, (vc1_1 & 3) as i32, sy, width, opaq);
                gon = 1;
            }
        }
    } else if kind == 1 || kind == 2 {
        var opaq: i32 = 1;
        var page_first: i32 = 0;
        if (vc1_1 & 3) > ((vc1_1 >> 4) & 3) { page_first = 1; }
        let page_second = page_first ^ 1;
        if (vc2_0 & 0x10) != 0 && (vc2_1 & 1) != 0 {
            ppu_grp8_sp_line(ppu, mmu, page_first, sy, width);
            tron = 1;
            pron = 1;
        }
        if (vc2_1 & 4) != 0 {
            ppu_grp8_line(ppu, mmu, page_second, sy, width, 1);
            opaq = 0;
            gon = 1;
        }
        if (vc2_1 & 1) != 0 && (vc2_0 & 0x14) != 0x14 {
            ppu_grp8_line(ppu, mmu, page_first, sy, width, opaq);
            gon = 1;
        }
    } else if kind == 3 {
        if (vc2_1 & 15) != 0 {
            if (vc2_0 & 0x14) == 0x14 {
                ppu_grp16_sp_line(ppu, mmu, sy, width);
                tron = 1;
                pron = 1;
            } else {
                ppu_grp16_line(ppu, mmu, sy, width);
                gon = 1;
            }
        }
    }
}

fn scr_raw(ppu: X68kPPU&, i: i32, w: u16, opaq: i32) {
    if opaq != 0 || w != 0 {
        ppu.scr[i] = w;
        ppu.scr_mix[i] = 0;
    }
}

fn scr_argb(ppu: X68kPPU&, i: i32, c: u32) {
    ppu.scr_argb[i] = c;
    ppu.scr_mix[i] = 1;
    ppu.scr[i] = 1;
}

fn ppu_blit_grp(ppu: X68kPPU&, width: i32, opaq: i32) {
    var i: i32 = 0;
    while i < width {
        if ppu.grp_mix[i] != 0 {
            scr_argb(ppu, i, ppu.grp_argb[i]);
        } else {
            scr_raw(ppu, i, ppu.grp[i], opaq);
        }
        i = i + 1;
    }
}

fn ppu_blit_sp2(ppu: X68kPPU&, width: i32, opaq: i32) {
    var i: i32 = 0;
    while i < width {
        scr_raw(ppu, i, ppu.sp2[i], opaq);
        i = i + 1;
    }
}

fn ppu_blit_bg(ppu: X68kPPU&, width: i32, opaq: i32, td: i32, flagbit: i32) {
    var i: i32 = 0;
    while i < width {
        let t = i + 16;
        if opaq == 0 && td != 0 && (ppu.line_tr[t] & (flagbit as u8)) == 0 {
            i = i + 1;
            continue;
        }
        scr_raw(ppu, i, ppu.line_bg[t], opaq);
        i = i + 1;
    }
}

fn ppu_blit_text_tr(ppu: X68kPPU&, width: i32, opaq: i32) {
    var i: i32 = 0;
    while i < width {
        let t = i + 16;
        let w = ppu.sp[i];
        let v = ppu.line_bg[t];
        if opaq != 0 {
            if w != 0 {
                scr_argb(ppu, i, argb_avg(pal_to_argb(w), pal_to_argb(v)));
            } else if (ppu.line_tr[t] & 1) != 0 {
                scr_raw(ppu, i, v, 1);
            } else {
                scr_raw(ppu, i, 0, 1);
            }
        } else if (ppu.line_tr[t] & 1) != 0 && v != 0 {
            if w != 0 {
                scr_argb(ppu, i, argb_avg(pal_to_argb(w), pal_to_argb(v)));
            } else {
                scr_raw(ppu, i, v, 0);
            }
        }
        i = i + 1;
    }
}

fn ppu_blit_bg_tr(ppu: X68kPPU&, width: i32, opaq: i32) {
    var i: i32 = 0;
    while i < width {
        let t = i + 16;
        let w = ppu.sp[i];
        let v = ppu.line_bg[t];
        if opaq != 0 {
            if w != 0 {
                scr_argb(ppu, i, argb_avg(pal_to_argb(w), pal_to_argb(v)));
            } else {
                scr_raw(ppu, i, v, 1);
            }
        } else if (ppu.line_tr[t] & 2) != 0 && v != 0 {
            if w != 0 {
                scr_argb(ppu, i, argb_avg(pal_to_argb(w), pal_to_argb(v)));
            } else {
                scr_raw(ppu, i, v, 0);
            }
        }
        i = i + 1;
    }
}

fn ppu_text_one_line(ppu: X68kPPU&, mmu: M68kMMU&, width: i32, sy: i32, opaq: i32) {
    let scroll_y = crtc_pair(mmu, 0x16) & 1023;
    let scroll_x = crtc_pair(mmu, 0x14) & 1023;
    var vram_y = ((sy as u32) + scroll_y) & 1023;
    if (mmu.crtc_regs[0x29] & 0x1C) == 0x1C {
        vram_y = (vram_y + (sy as u32)) & 1023;
    }
    let line_base = (vram_y as i32) * 128;
    let col_bytes = width / 8;
    let start_col = ((scroll_x / 8) & 127) as i32;
    var col: i32 = 0;
    while col < col_bytes {
        let off = line_base + ((start_col + col) & 127);
        let b0 = mmu.tvram[off] as u32;
        let b1 = mmu.tvram[off + 0x20000] as u32;
        let b2 = mmu.tvram[off + 0x40000] as u32;
        let b3 = mmu.tvram[off + 0x60000] as u32;
        let any_bits = b0 | b1 | b2 | b3;
        var px: i32 = 0;
        while px < 8 {
            let x = col * 8 + px;
            if x >= width { return; }
            let t = x + 16;
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
                if opaq != 0 {
                    ppu.line_tr[t] = 1;
                } else {
                    ppu.line_tr[t] = ppu.line_tr[t] | 1;
                }
            } else if opaq != 0 {
                ppu.line_bg[t] = pal_text_idx(mmu, 0);
                ppu.line_tr[t] = 0;
            }
            px = px + 1;
        }
        col = col + 1;
    }
}

fn ppu_compose_back(ppu: X68kPPU&, sy: i32, screen_w: i32, width: i32, gon: i32, ton: i32, bgon: i32, tron: i32, pron: i32, vc1_0: i32, vc2_0: i32) {
    var i: i32 = 0;
    while i < width {
        ppu.scr[i] = 0;
        ppu.scr_mix[i] = 0;
        i = i + 1;
    }
    var tdrawed: i32 = 0;
    var opaq: i32 = 1;
    if (vc1_0 & 0x02) != 0 && gon != 0 {
        ppu_blit_grp(ppu, width, opaq);
        opaq = 0;
    }
    if (vc1_0 & 0x02) != 0 && tron != 0 {
        ppu_blit_sp2(ppu, width, opaq);
        opaq = 0;
    }
    if (vc1_0 & 0x20) != 0 && bgon != 0 {
        if (vc2_0 & 0x5D) == 0x1D && (vc1_0 & 0x03) != 0x02 && tron != 0 && (vc1_0 & 3) < ((vc1_0 >> 2) & 3) {
            ppu_blit_bg_tr(ppu, width, opaq);
            tdrawed = 1;
            opaq = 0;
        } else {
            ppu_blit_bg(ppu, width, opaq, tdrawed, 2);
            tdrawed = 1;
            opaq = 0;
        }
    }
    if (vc1_0 & 0x08) != 0 && ton != 0 {
        if (vc2_0 & 0x5D) == 0x1D && (vc1_0 & 0x03) != 0x02 && tron != 0 {
            ppu_blit_text_tr(ppu, width, opaq);
        } else {
            ppu_blit_bg(ppu, width, opaq, tdrawed, 1);
        }
        opaq = 0;
        tdrawed = 1;
    }
    if (vc1_0 & 0x03) == 0x01 && gon != 0 {
        ppu_blit_grp(ppu, width, opaq);
        opaq = 0;
    }
    if (vc1_0 & 0x30) == 0x10 && bgon != 0 {
        if (vc2_0 & 0x5D) == 0x1D && (vc1_0 & 0x03) == 0 && tron != 0 && (vc1_0 & 3) < ((vc1_0 >> 2) & 3) {
            ppu_blit_bg_tr(ppu, width, opaq);
            tdrawed = 1;
            opaq = 0;
        } else {
            var td: i32 = 0;
            if (vc1_0 & 0x0C) == 0x08 { td = 1; }
            ppu_blit_bg(ppu, width, opaq, td, 2);
            tdrawed = 1;
            opaq = 0;
        }
    }
    if (vc1_0 & 0x0C) == 0x04 && (vc2_0 & 0x5D) == 0x1D && (vc1_0 & 0x03) != 0 && ((vc1_0 >> 4) & 3) > (vc1_0 & 3) && bgon != 0 && tron != 0 {
        ppu_blit_bg_tr(ppu, width, opaq);
        tdrawed = 1;
        opaq = 0;
        ppu_blit_sp2(ppu, width, opaq);
    } else if (vc1_0 & 0x03) == 0x01 && tron != 0 && gon != 0 && (vc2_0 & 0x10) != 0 {
        ppu_blit_sp2(ppu, width, opaq);
        opaq = 0;
    }
    if (vc1_0 & 0x0C) == 0x04 && ton != 0 {
        if (vc2_0 & 0x5D) == 0x1D && (vc1_0 & 0x03) == 0 && tron != 0 {
            ppu_blit_text_tr(ppu, width, opaq);
        } else {
            var td2: i32 = 0;
            if (vc1_0 & 0x30) >= 0x10 { td2 = 1; }
            ppu_blit_bg(ppu, width, opaq, td2, 1);
        }
        opaq = 0;
        tdrawed = 1;
    }
    if (vc1_0 & 0x03) == 0 && gon != 0 {
        ppu_blit_grp(ppu, width, opaq);
        opaq = 0;
    }
    if (vc1_0 & 0x30) == 0 && bgon != 0 {
        var td3: i32 = 0;
        if (vc1_0 & 0x0C) >= 0x04 { td3 = 1; }
        ppu_blit_bg(ppu, width, opaq, td3, 2);
        tdrawed = 1;
        opaq = 0;
    }
    if (vc1_0 & 0x0C) == 0 && (vc2_0 & 0x5D) == 0x1D && ((vc1_0 >> 4) & 3) > (vc1_0 & 3) && bgon != 0 && tron != 0 {
        ppu_blit_bg_tr(ppu, width, opaq);
        tdrawed = 1;
        opaq = 0;
        ppu_blit_sp2(ppu, width, opaq);
    } else if (vc1_0 & 0x03) == 0 && tron != 0 && (vc2_0 & 0x10) != 0 {
        ppu_blit_sp2(ppu, width, opaq);
        opaq = 0;
    }
    if (vc1_0 & 0x0C) == 0 && ton != 0 {
        ppu_blit_bg(ppu, width, opaq, 1, 1);
        tdrawed = 1;
        opaq = 0;
    }
    if (vc2_0 & 0x5C) == 0x14 && pron != 0 {
        var j: i32 = 0;
        while j < width {
            scr_raw(ppu, j, ppu.sp[j], 0);
            j = j + 1;
        }
    } else if (vc2_0 & 0x5D) == 0x1C && tron != 0 {
        var black: u32 = 0xFF000000;
        var j: i32 = 0;
        while j < width {
            if ppu.sp[j] != 0 && ppu.scr_mix[j] == 0 && ppu.scr[j] == 0 {
                scr_argb(ppu, j, argb_avg(pal_to_argb(ppu.sp[j]), black));
            }
            j = j + 1;
        }
    }
    if opaq != 0 {
        var k: i32 = 0;
        while k < width {
            ppu.scr[k] = 0;
            ppu.scr_mix[k] = 0;
            k = k + 1;
        }
    }
    var x: i32 = 0;
    while x < width {
        var c = pal_to_argb(ppu.scr[x]);
        if ppu.scr_mix[x] != 0 { c = ppu.scr_argb[x]; }
        ppu.fb[sy * screen_w + x] = c;
        x = x + 1;
    }
    if tdrawed != 0 { return; }
}

fn ppu_apply_screen(mmu: M68kMMU&) {
    var dot_x: i32 = 768;
    let hstart = (((mmu.crtc_regs[0x04] as i32) << 8) | (mmu.crtc_regs[0x05] as i32)) & 1023;
    let hend = (((mmu.crtc_regs[0x06] as i32) << 8) | (mmu.crtc_regs[0x07] as i32)) & 1023;
    if hend > hstart { dot_x = (hend - hstart) * 8; }
    var dot_y: i32 = 512;
    let vstart = (((mmu.crtc_regs[0x0C] as i32) << 8) | (mmu.crtc_regs[0x0D] as i32)) & 1023;
    let vend = (((mmu.crtc_regs[0x0E] as i32) << 8) | (mmu.crtc_regs[0x0F] as i32)) & 1023;
    if vend > vstart { dot_y = vend - vstart; }
    let mode = mmu.crtc_regs[0x29] as i32;
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
    c_set_screen_mode(dot_x, dot_y);
}

fn ppu_begin_frame(ppu: X68kPPU&, mmu: M68kMMU&) {
    ppu_apply_screen(mmu);
    var black: u32 = 0xFF000000;
    c_clear_framebuffer(black);
    c_set_frame_ready(1);
}

fn ppu_draw_sprite_line(ppu: X68kPPU&, mmu: M68kMMU&, sy: i32) {
    if sy < 0 || sy >= g_screen_h { return; }
    var width = g_screen_w;
    if width > 1024 { width = 1024; }
    if width < 1 { return; }
    ppu_clear_front(ppu);
    var gon: i32 = 0;
    var tron: i32 = 0;
    var pron: i32 = 0;
    let vc1_0 = mmu.vcreg[0x100] as i32;
    let vc2_0 = mmu.vcreg[0x200] as i32;
    let vc2_1 = mmu.vcreg[0x201] as i32;
    ppu_grp_lines(ppu, mmu, sy, width, gon, tron, pron);
    let sp_on = (vc2_1 & 0x40) != 0 && (mmu.bgreg[0x11] & 2) == 0;
    let text_on = (vc2_1 & 0x20) != 0;
    var ton: i32 = 0;
    var bgon: i32 = 0;
    if ((vc1_0 & 0x30) >> 2) < (vc1_0 & 0x0C) {
        if text_on {
            ppu_text_one_line(ppu, mmu, width, sy, 1);
            ton = 1;
        }
        if sp_on {
            var opaq: i32 = 0;
            if ton == 0 { opaq = 1; }
            // px68k BG_DrawLine(..., gd=0)。パターン 0 は描かない。
            ppu_bg_draw_line(ppu, mmu, width, sy, opaq, 1);
            bgon = 1;
        }
    } else {
        if sp_on {
            // px68k BG_DrawLine(..., gd=1)。パレットだけのドットも描く。
            ppu_bg_draw_line(ppu, mmu, width, sy, 1, 0);
            bgon = 1;
        } else {
            if text_on { ppu_bg_fill_pal0(ppu, mmu, width); }
            bgon = 1;
        }
        if text_on {
            var opaq: i32 = 0;
            if bgon == 0 { opaq = 1; }
            ppu_text_one_line(ppu, mmu, width, sy, opaq);
            ton = 1;
        }
    }
    ppu_compose_back(ppu, sy, g_screen_w, width, gon, ton, bgon, tron, pron, vc1_0, vc2_0);
}

fn ppu_render_frame(ppu: X68kPPU&, mmu: M68kMMU&) {
    ppu_apply_screen(mmu);
    ppu.frame_ready = true;
}
