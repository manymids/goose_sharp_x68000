// Sharp X68000 メモリ管理ユニット (MMU) in Goose

import std;
import os;
import .x68k_bridge;
import .m68k_types;
import .x68k_mfp;
import .x68k_fdc;
import .x68k_dmac;
import .x68k_sasi;
import .x68k_ram;
import .x68k_rom;

struct M68kMMU {
    reset_overlay: bool = true,
    io_palette: u16[256] = [0; 256],
    crtc_regs: u8[64] = [0; 64],
    crtc_mode: u8 = 0,
    crtc_fast_clr: i32 = 0,
    crtc_rc_flag: u8 = 0,
    mfp: X68kMFP = X68kMFP {},
    fdc: X68kFDC = X68kFDC {},
    dmac: X68kDMAC = X68kDMAC {},
    sasi: X68kSASI = X68kSASI {},
    pal: u8[1024] = [0; 1024],
    vcreg: u8[1024] = [0; 1024],
    sprite: u8[2048] = [0; 2048],
    bgreg: u8[32] = [0; 32],
    bgram: u8[32768] = [0; 32768],
    bg_chr8: u8[16384] = [0; 16384],
    bg_chr16: u8[65536] = [0; 65536],
    tvram: u8[524288] = [0; 524288],
    gvram: u8[524288] = [0; 524288],
    ioc_int_stat: u8 = 0,
    ioc_int_vect: u8 = 0,
    sasi_irq: bool = false,
    sysport_contrast: u8 = 0,
    sysport_monitor: u8 = 0,
    sysport_keyctrl: u8 = 0,
    sysport_cputype: u8 = 0xFF, // 68000, 10MHz (px68k sysport.c)
    fdd_cur_track: i32 = 0,
    fdd_cur_sec: i32 = 1,
    joy1: u8 = 0xFF,
    joy2: u8 = 0xFF,
    bus_error: bool = false,
    bus_error_addr: u32 = 0,
    bus_error_write: bool = false,
    debug_io: bool = false,
    debug_pc: u32 = 0,
    trace_steps: i32 = 0
}

fn mmu_init(mmu: M68kMMU&) {
    mmu.reset_overlay = true;
    mmu.crtc_mode = 0;
    mmu.crtc_fast_clr = 0;
    mmu.crtc_rc_flag = 0;
    mmu.fdd_cur_track = 0;
    mmu.fdd_cur_sec = 1;
    mmu.joy1 = 0xFF;
    mmu.joy2 = 0xFF;
    mmu.sysport_contrast = 0;
    mmu.sysport_monitor = 0;
    mmu.sysport_keyctrl = 0;
    mmu.sysport_cputype = 0xFF; // 68000, 10MHz
    mmu.bus_error = false;
    mmu.bus_error_addr = 0;
    mmu.bus_error_write = false;
    mmu.debug_io = false;
    mmu.debug_pc = 0;
    mmu.trace_steps = 0;

    for i in 256 {
        mmu.io_palette[i] = 0;
    }
    for i in 64 {
        mmu.crtc_regs[i] = 0;
    }
    mmu.mfp = X68kMFP {};
    mmu.fdc = X68kFDC {};
    mmu.dmac = X68kDMAC {};
    mmu.sasi = X68kSASI {};
    mfp_init(mmu.mfp);
    fdc_init(mmu.fdc);
    dmac_init(mmu.dmac);
    sasi_reset(mmu.sasi);
    mmu.ioc_int_stat = 0;
    mmu.ioc_int_vect = 0;
    mmu.sasi_irq = false;
}

fn mmu_clear_video(mmu: M68kMMU&) {
    mmu.pal = [0; 1024]; mmu.vcreg = [0; 1024];
    mmu.sprite = [0; 2048]; mmu.bgreg = [0; 32]; mmu.bgram = [0; 32768];
    mmu.bg_chr8 = [0; 16384]; mmu.bg_chr16 = [0; 65536];
    mmu.tvram = [0; 524288]; mmu.gvram = [0; 524288];
}

fn gvram_type(r20: u8) -> i32 {
    if (r20 & 8) != 0 { return 4; }
    if (r20 & 4) != 0 { return 0; }
    return ((r20 & 3) as i32) + 1;
}

fn gvram_addr1024(adr: u32) -> u32 {
    return ((adr & 0xFF800) >> 1) + (adr & 0x3FF);
}

fn gvram_get(mmu: M68kMMU&, i: u32) -> u8 {
    if i >= 524288 { return 0; }
    return mmu.gvram[i as i64];
}

fn gvram_set(mmu: M68kMMU&, i: u32, val: u8) {
    if i >= 524288 { return; }
    mmu.gvram[i as i64] = val;
}

fn gvram_and16(mmu: M68kMMU&, off: u32, mask: u16) {
    if off + 1 >= 524288 { return; }
    let lo = mmu.gvram[off as i64] as u16;
    let hi = mmu.gvram[(off + 1) as i64] as u16;
    let next = (lo | (hi << 8)) & mask;
    mmu.gvram[off as i64] = next as! u8;
    mmu.gvram[(off + 1) as i64] = (next >> 8) as! u8;
}

fn mmu_gvram_fast_clear(mmu: M68kMMU&, reg2b: u8, reg29: u8, scroll_x: u32, scroll_y: u32) {
    let masks: u16[16] = [
        0xFFFF, 0xFFF0, 0xFF0F, 0xFF00, 0xF0FF, 0xF0F0, 0xF00F, 0xF000,
        0x0FFF, 0x0FF0, 0x0F0F, 0x0F00, 0x00FF, 0x00F0, 0x000F, 0x0000
    ];
    let mask = masks[(reg2b & 0x0F) as i64];
    let v: u32 = if (reg29 & 4) != 0 { 512 } else { 256 };
    let h: u32 = if (reg29 & 3) != 0 { 512 } else { 256 };
    var w0 = h;
    var w1: u32 = 0;
    let sx = scroll_x & 0x1FF;
    if sx + w0 > (512 as u32) {
        w1 = sx + w0 - 512;
        w0 = 512 - sx;
    }
    let sy = scroll_y & 0x1FF;
    var y: u32 = 0;
    while y < v {
        let offset = (((y + sy) & 0x1FF) << 10);
        var x: u32 = 0;
        var p = offset + (sx * 2);
        while x < w0 {
            gvram_and16(mmu, p, mask);
            p = p + 2;
            x = x + 1;
        }
        if w1 > 0 {
            x = 0;
            p = offset;
            while x < w1 {
                gvram_and16(mmu, p, mask);
                p = p + 2;
                x = x + 1;
            }
        }
        y = y + 1;
    }
}

fn mmu_gvram_cpu_read(mmu: M68kMMU&, off: i32, r20: u8) -> u8 {
    if off < 0 { return 0; }
    let adr = (off as u32) & 0x1FFFFF;
    let kind = gvram_type(r20);
    if kind == 0 {
        if (adr & 1) == 0 { return 0; }
        var i = gvram_addr1024(adr);
        if (adr & 0x100000) == 0 { i = i ^ 1; }
        if i >= 524288 { return 0; }
        let b = gvram_get(mmu, i);
        if (adr & 0x400) != 0 { return b >> 4; }
        return b & 0x0F;
    }
    if kind == 1 {
        if (adr & 1) == 0 { return 0; }
        if adr < 0x80000 { return gvram_get(mmu, adr ^ 1) & 0x0F; }
        let i = adr & 0x7FFFF;
        if adr < 0x100000 { return gvram_get(mmu, i ^ 1) >> 4; }
        if adr < 0x180000 { return gvram_get(mmu, i) & 0x0F; }
        return gvram_get(mmu, i) >> 4;
    }
    if kind == 2 || kind == 3 {
        if adr < 0x80000 {
            if (adr & 1) != 0 { return gvram_get(mmu, adr ^ 1); }
            return 0;
        }
        if adr < 0x100000 {
            let i = adr & 0x7FFFF;
            if (i & 1) != 0 { return gvram_get(mmu, i); }
            return 0;
        }
        return 0;
    }
    if adr < 0x80000 { return gvram_get(mmu, adr ^ 1); }
    return 0;
}

fn mmu_gvram_cpu_write(mmu: M68kMMU&, off: i32, val: u8, r20: u8) {
    if off < 0 { return; }
    let adr = (off as u32) & 0x1FFFFF;
    let kind = gvram_type(r20);
    if kind == 0 {
        if (adr & 1) == 0 { return; }
        var i = gvram_addr1024(adr);
        if (adr & 0x100000) == 0 { i = i ^ 1; }
        if i >= 524288 { return; }
        let cur = gvram_get(mmu, i);
        if (adr & 0x400) != 0 {
            gvram_set(mmu, i, (cur & 0x0F) | ((val & 0x0F) << 4));
        } else {
            gvram_set(mmu, i, (cur & 0xF0) | (val & 0x0F));
        }
        return;
    }
    if kind == 1 {
        if (adr & 1) == 0 { return; }
        if adr < 0x80000 {
            let i = adr ^ 1;
            gvram_set(mmu, i, (gvram_get(mmu, i) & 0xF0) | (val & 0x0F));
            return;
        }
        var i = adr & 0x7FFFF;
        if adr < 0x100000 {
            i = i ^ 1;
            gvram_set(mmu, i, (gvram_get(mmu, i) & 0x0F) | ((val << 4) & 0xF0));
            return;
        }
        if adr < 0x180000 {
            gvram_set(mmu, i, (gvram_get(mmu, i) & 0xF0) | (val & 0x0F));
            return;
        }
        gvram_set(mmu, i, (gvram_get(mmu, i) & 0x0F) | ((val << 4) & 0xF0));
        return;
    }
    if kind == 2 || kind == 3 {
        if (adr & 1) == 0 { return; }
        if adr < 0x80000 {
            gvram_set(mmu, adr ^ 1, val);
            return;
        }
        if adr < 0x100000 {
            gvram_set(mmu, adr & 0x7FFFF, val);
        }
        return;
    }
    if adr < 0x80000 {
        gvram_set(mmu, adr ^ 1, val);
    }
}

fn tvram_store(mmu: M68kMMU&, adr: u32, data: u8) {
    if adr < 524288 {
        mmu.tvram[adr as i64] = data;
    }
}

fn tvram_store_mask(mmu: M68kMMU&, adr: u32, data: u8, r2e: u8, r2f: u8) {
    if adr >= 524288 { return; }
    let m = if (adr & 1) != 0 { r2f } else { r2e };
    let cur = mmu.tvram[adr as i64];
    mmu.tvram[adr as i64] = (cur & m) | (data & (m ^ 0xFF));
}

fn mmu_write_tvram_access(mmu: M68kMMU&, off: i32, val: u8, r2a: u8, r2b: u8, r2e: u8, r2f: u8) {
    if off < 0 { return; }
    var adr = (off as u32) & 0x7FFFF;
    if (r2a & 1) != 0 {
        adr = adr & 0x1FFFF;
        if (r2a & 2) != 0 {
            if (r2b & 0x10) != 0 { tvram_store_mask(mmu, adr, val, r2e, r2f); }
            if (r2b & 0x20) != 0 { tvram_store_mask(mmu, adr + 0x20000, val, r2e, r2f); }
            if (r2b & 0x40) != 0 { tvram_store_mask(mmu, adr + 0x40000, val, r2e, r2f); }
            if (r2b & 0x80) != 0 { tvram_store_mask(mmu, adr + 0x60000, val, r2e, r2f); }
        } else {
            if (r2b & 0x10) != 0 { tvram_store(mmu, adr, val); }
            if (r2b & 0x20) != 0 { tvram_store(mmu, adr + 0x20000, val); }
            if (r2b & 0x40) != 0 { tvram_store(mmu, adr + 0x40000, val); }
            if (r2b & 0x80) != 0 { tvram_store(mmu, adr + 0x60000, val); }
        }
    } else if (r2a & 2) != 0 {
        tvram_store_mask(mmu, adr, val, r2e, r2f);
    } else {
        tvram_store(mmu, adr, val);
    }
}

fn mmu_tvram_raster_copy(mmu: M68kMMU&, src_line: u32, dst_line: u32, plane_mask: u8) {
    let src = (src_line << 9) & 0x1FFFF;
    let dst = (dst_line << 9) & 0x1FFFF;
    for bit in 4 {
        let flag = (1 << bit) as u8;
        if (plane_mask & flag) != 0 {
            var plane: u32 = 0;
            if bit == 1 { plane = 0x20000; }
            if bit == 2 { plane = 0x40000; }
            if bit == 3 { plane = 0x60000; }
            for i in 512 {
                let s = (src + plane + (i as u32)) as i64;
                let d = (dst + plane + (i as u32)) as i64;
                mmu.tvram[d] = mmu.tvram[s];
            }
        }
    }
}

fn mmu_write_bgram(mmu: M68kMMU&, off: i32, val: u8) {
    if off < 0 || off >= 0x8000 { return; }
    mmu.bgram[off] = val;
    if off < 0x2000 {
        mmu.bg_chr8[off * 2] = val >> 4;
        mmu.bg_chr8[off * 2 + 1] = val & 15;
    }
    let bg16 = ((off & 3) * 2) + ((off & 0x3C) * 4) + ((off & 0x40) >> 3) + ((off & 0x7F80) * 2);
    if bg16 + 1 < 65536 {
        mmu.bg_chr16[bg16] = val >> 4;
        mmu.bg_chr16[bg16 + 1] = val & 15;
    }
}

fn sasi_note(mmu: M68kMMU&) {
    if sasi_consume_status_edge(mmu.sasi) != 0 {
        mmu.ioc_int_stat |= 0x10;
        if (mmu.ioc_int_stat & 8) != 0 {
            mmu.sasi_irq = true;
        }
    }
}

// 8-bit Read
fn mmu_read8(mmu: M68kMMU&, addr: u32) -> u8 {
    let a = addr & 0x00FFFFFF;

    // Reset overlay for vector table (0x000000 - 0x000007)
    if mmu.reset_overlay && a < 8 {
        // Return initial vector from IPLROM at 0x10000
        return x68k_ipl_read((0x10000 + (a as i32)) as i32);
    }

    // 0x000000 - 0xBFFFFF: Main RAM (upto 12MB)
    if a < 0xC00000 {
        return x68k_ram_read(a as i32);
    }

    // 0xC00000 - 0xDFFFFF: GVRAM (up to 2MB plane addressing)
    if a >= 0xC00000 && a < 0xE00000 {
        return mmu_gvram_cpu_read(mmu, (a - 0xC00000) as i32, mmu.crtc_regs[0x28]);
    }

    // 0xE00000 - 0xE7FFFF: TVRAM (512KB)
    if a >= 0xE00000 && a < 0xE80000 {
        return mmu.tvram[(a - 0xE00000) as i64];
    }

    // 0xED0000 - 0xED3FFF: SRAM (16KB)
    if a >= 0xED0000 && a < 0xED4000 {
        return x68k_sram_read((a - 0xED0000) as i32);
    }

    // 0xF00000 - 0xFBFFFF: CGROM (768KB)
    if a >= 0xF00000 && a < 0xFC0000 {
        return x68k_cgrom_read((a - 0xF00000) as i32);
    }

    // 0xFE0000 - 0xFFFFFF: IPLROM (128KB)
    if a >= 0xFE0000 && a <= 0xFFFFFF {
        return x68k_ipl_read((a - 0xFE0000) as i32);
    }

    // 0x00E8E000 - 0x00E8E00F: SysPort
    if (a & 0xFFFFF0) == 0xE8E000 {
        if (a & 1) != 0 {
            let reg = ((a & 0x0F) >> 1) as i32;
            if reg == 0 { return 0xF0 | mmu.sysport_contrast; }
            if reg == 1 { return 0xF0 | mmu.sysport_monitor; }
            if reg == 3 { return 0xF0 | mmu.sysport_keyctrl; }
            if reg == 5 { return 0xF0 | mmu.sysport_cputype; }
        }
        return 0xFF;
    }

    // 0x00E80000 - 0x00E804FF: CRTC
    // 0xE80400 未満は下位 6 ビットのミラー。0xE80481 だけが操作ポート。
    if a >= 0xE80000 && a < 0xE80500 {
        if a == 0xE80481 {
            if mmu.crtc_fast_clr > 0 {
                return (mmu.crtc_mode | 0x02);
            }
            return (mmu.crtc_mode & 0xFD);
        }
        if a >= 0xE80400 {
            return 0;
        }
        let reg = (a & 0x3F) as i32;
        if reg >= 0x28 && reg <= 0x2B {
            return mmu.crtc_regs[reg];
        }
        return 0;
    }

    // 0x00E88000 - 0x00E8803F: MFP (MC68901)
    if (a & 0xFFFFC0) == 0xE88000 {
        if (a & 1) != 0 {
            let reg = ((a & 0x3F) >> 1) as i32;
            return mfp_read(mmu.mfp, reg);
        }
        return 0xFF;
    }

    // 0x00E90000 - 0x00E90003: OPM (YM2151)
    if (a & 0xFFFF00) == 0xE90000 {
        if (a & 3) == 3 {
            return c_sound_opm_read(0);
        }
        return 0;
    }

    // 0x00E92000 - 0x00E92003: ADPCM (MSM6258)
    if (a & 0xFFFF00) == 0xE92000 {
        return c_sound_adpcm_read(a);
    }

    // 0x00E94000 - 0x00E94007: FDC (uPD72065)
    if (a & 0xFFFF00) == 0xE94000 {
        let reg = (a & 0x07) as i32;
        return fdc_read(mmu.fdc, reg);
    }

    // 0x00E96000 - 0x00E97FFF: SASI
    if (a & 0x00FFE000) == 0x00E96000 {
        let v = sasi_read(mmu.sasi, a);
        sasi_note(mmu);
        return v;
    }

    // 0x00E98000 - 0x00E98007: SCC (Z85C30: Mouse / RS-232C)
    if (a & 0xFFFF00) == 0xE98000 {
        let reg = (a & 0x07) as i32;
        if reg == 5 { return 4; } // Ch A Control: Tx Empty
        return 0;
    }

    // 0x00E9A000 - 0x00E9A007: JoyPort (8255 PPI)
    if (a & 0xFFFF00) == 0xE9A000 {
        if a == 0xE9A001 { return mmu.joy1; }
        if a == 0xE9A003 { return mmu.joy2; }
        if a == 0xE9A005 { return c_pia_read_c(); }
        return 0xFF;
    }

    // 0x00E9C000 - 0x00E9C003: IOC (I/O Controller)
    if (a & 0xFFFF00) == 0xE9C000 {
        if a == 0xE9C001 {
            return mmu.ioc_int_stat;
        }
        return 0xFF;
    }

    // 0x00E8A000: RTC
    if (a & 0xFFFF00) == 0xE8A000 {
        return 0;
    }

    // 0x00E84000: DMAC
    if (a & 0xFFFF00) == 0xE84000 {
        return dmac_read(mmu.dmac, a);
    }

    // 0x00E82000 - 0x00E823FF: Palette RAM (1024 bytes)
    if a >= 0xE82000 && a < 0xE82400 {
        return mmu.pal[(a - 0xE82000) as i64];
    }

    // 0x00E82400 - 0x00E827FF: Video Controller Registers
    if a >= 0xE82400 && a < 0xE82800 {
        return mmu.vcreg[(a - 0xE82400) as i64];
    }

    // 0x00EB0000 - 0x00EB07FF: Sprite Registers
    if a >= 0xEB0000 && a < 0xEB0800 {
        return mmu.sprite[(a - 0xEB0000) as i64];
    }

    // 0x00EB0800 - 0x00EB081F: BG Control Registers
    if a >= 0xEB0800 && a < 0xEB0820 {
        return mmu.bgreg[(a - 0xEB0800) as i64];
    }

    // 0x00EB8000 - 0x00EBFFFF: BG / PCG RAM
    if a >= 0xEB8000 && a < 0xEC0000 {
        return mmu.bgram[(a - 0xEB8000) as i64];
    }

    return 0;
}

// 8-bit Write
fn mmu_write8(mmu: M68kMMU&, addr: u32, val: u8) {
    let a = addr & 0x00FFFFFF;

    // Reset overlay is disabled on any write to RAM
    if a < 0xC00000 {
        mmu.reset_overlay = false;
        x68k_ram_write(a as i32, val);
        return;
    }

    // 0xC00000 - 0xDFFFFF: GVRAM
    if a >= 0xC00000 && a < 0xE00000 {
        mmu_gvram_cpu_write(mmu, (a - 0xC00000) as i32, val, mmu.crtc_regs[0x28]);
        return;
    }

    // 0xE00000 - 0xE7FFFF: TVRAM (512KB)
    if a >= 0xE00000 && a < 0xE80000 {
        let off = (a - 0xE00000) as i32;
        if mmu.debug_io {
            write_stderr(str("[TVRAM WRITE: addr=0x", a, " off=0x", off, " val=0x", val as u32, " crtc2A=0x", mmu.crtc_regs[0x2A] as u32, " crtc2B=0x", mmu.crtc_regs[0x2B] as u32, "]\n"));
        }
        mmu_write_tvram_access(mmu, off, val, mmu.crtc_regs[0x2A], mmu.crtc_regs[0x2B], mmu.crtc_regs[0x2E], mmu.crtc_regs[0x2F]);
        return;
    }

    // 0xED0000 - 0xED3FFF: SRAM (16KB)
    if a >= 0xED0000 && a < 0xED4000 {
        x68k_sram_write((a - 0xED0000) as i32, val);
        return;
    }

    // 0x00E8E000 - 0x00E8E00F: SysPort
    if (a & 0xFFFFF0) == 0xE8E000 {
        if (a & 1) != 0 {
            let reg = ((a & 0x0F) >> 1) as i32;
            if reg == 0 { mmu.sysport_contrast = val & 0x0F; }
            else if reg == 1 { mmu.sysport_monitor = val & 0x0B; }
            else if reg == 3 { mmu.sysport_keyctrl = val & 0x0E; }
            else if reg == 6 {
                let en: i32 = if val == 0x31 { 1 } else { 0 };
                x68k_sram_set_write_enable(en);
            }
        }
        return;
    }

    // 0x00E80000 - 0x00E804FF: CRTC
    if a >= 0xE80000 && a < 0xE80500 {
        if mmu.debug_io {
            write_stderr(str("[CRTC WRITE: addr=0x", a, " val=0x", val as u32, "]\n"));
        }
        if a == 0xE80481 {
            // CRTC operation port (Raster Copy & Fast Clear)
            mmu.crtc_mode = (val | (mmu.crtc_mode & 0x02));
            if (mmu.crtc_mode & 8) != 0 {
                let src_line = mmu.crtc_regs[0x2C] as u32;
                let dst_line = mmu.crtc_regs[0x2D] as u32;
                let mask = mmu.crtc_regs[0x2B];
                mmu_tvram_raster_copy(mmu, src_line, dst_line, mask);
                mmu.crtc_rc_flag = 0;
            }
            return;
        }
        if a >= 0xE80400 {
            return;
        }
        let reg = (a & 0x3F) as i32;
        if reg >= 0x30 {
            return;
        }
        mmu.crtc_regs[reg] = val;
        if reg == 0x2C {
            mmu.crtc_rc_flag |= 1;
        } else if reg == 0x2D {
            mmu.crtc_rc_flag |= 2;
            if (mmu.crtc_mode & 8) != 0 {
                let src_line = mmu.crtc_regs[0x2C] as u32;
                let dst_line = val as u32;
                let mask = mmu.crtc_regs[0x2B];
                mmu_tvram_raster_copy(mmu, src_line, dst_line, mask);
                mmu.crtc_rc_flag = 0;
            }
        }
        return;
    }

    // 0x00E84000 - 0x00E840FF: DMAC (HD63450)
    if (a & 0xFFFF00) == 0xE84000 {
        dmac_write(mmu.dmac, a, val);
        if (mmu.dmac.ch[0].csr & 0x08) != 0 && mmu.fdc.bufnum > 0 && mmu.fdc.wexec == 0 {
            dmac_exec_fdc(mmu.dmac, mmu.fdc, mmu);
        }
        if mmu.fdc.int_pending {
            mmu.ioc_int_stat |= 0x80;
            mmu.fdc.int_pending = false;
        }
        return;
    }

    // 0x00E88000 - 0x00E8803F: MFP (MC68901)
    if (a & 0xFFFFC0) == 0xE88000 {
        if (a & 1) != 0 {
            let reg = ((a & 0x3F) >> 1) as i32;
            mfp_write(mmu.mfp, reg, val);
        }
        return;
    }

    // 0x00E90000 - 0x00E90003: OPM (YM2151)
    if (a & 0xFFFF00) == 0xE90000 {
        if a == 0xE90001 {
            c_sound_opm_write(0, val);
        } else if a == 0xE90003 {
            c_sound_opm_write(1, val);
        }
        return;
    }

    // 0x00E92000 - 0x00E92003: ADPCM (MSM6258)
    if (a & 0xFFFF00) == 0xE92000 {
        c_sound_adpcm_write(a, val);
        return;
    }

    // 0x00E9A000 - 0x00E9A007: JoyPort / PIA (8255)
    if (a & 0xFFFF00) == 0xE9A000 {
        if a == 0xE9A005 || a == 0xE9A007 {
            c_pia_write(a as i32, val);
        }
        return;
    }

    // 0x00E96000 - 0x00E97FFF: SASI
    if (a & 0x00FFE000) == 0x00E96000 {
        sasi_write(mmu.sasi, a, val);
        sasi_note(mmu);
        return;
    }

    // 0x00E94000 - 0x00E94007: FDC (uPD72065)
    if (a & 0xFFFF00) == 0xE94000 {
        let reg = (a & 0x07) as i32;
        fdc_write(mmu.fdc, reg, val);
        if (mmu.dmac.ch[0].csr & 0x08) != 0 && mmu.fdc.bufnum > 0 && mmu.fdc.wexec == 0 {
            dmac_exec_fdc(mmu.dmac, mmu.fdc, mmu);
        }
        if mmu.fdc.int_pending {
            mmu.ioc_int_stat |= 0x80;
            mmu.fdc.int_pending = false;
        }
        return;
    }

    // 0x00E98000 - 0x00E98007: SCC (Z85C30)
    if (a & 0xFFFF00) == 0xE98000 {
        return;
    }

    // 0x00E9C000 - 0x00E9C003: IOC (I/O Controller)
    if (a & 0xFFFF00) == 0xE9C000 {
        if a == 0xE9C001 {
            mmu.ioc_int_stat &= 0xF0;
            mmu.ioc_int_stat |= (val & 0x0F);
            c_fdd_set_media_enable(if (mmu.ioc_int_stat & 2) != 0 { 1 } else { 0 });
        } else if a == 0xE9C003 {
            mmu.ioc_int_vect = (val & 0xFC);
        }
        return;
    }

    // 0x00E82000 - 0x00E823FF: Palette RAM (1024 bytes)
    if a >= 0xE82000 && a < 0xE82400 {
        mmu.pal[(a - 0xE82000) as i64] = val;
        return;
    }

    // 0x00E82400 - 0x00E827FF: Video Controller Registers
    if a >= 0xE82400 && a < 0xE82800 {
        mmu.vcreg[(a - 0xE82400) as i64] = val;
        return;
    }

    // 0x00EB0000 - 0x00EB07FF: Sprite Registers
    if a >= 0xEB0000 && a < 0xEB0800 {
        mmu.sprite[(a - 0xEB0000) as i64] = val;
        return;
    }

    // 0x00EB0800 - 0x00EB081F: BG Control Registers
    if a >= 0xEB0800 && a < 0xEB0820 {
        mmu.bgreg[(a - 0xEB0800) as i64] = val;
        return;
    }

    // 0x00EB8000 - 0x00EBFFFF: BG / PCG RAM
    if a >= 0xEB8000 && a < 0xEC0000 {
        mmu_write_bgram(mmu, (a - 0xEB8000) as i32, val);
        return;
    }

    // CRTC / Palette IO fallback
    if (a & 0xFFFF00) == 0xE82000 {
        return;
    }
}

// Both bytes sit in the RAM window (through 0xBFFFFF). The last byte stays on the byte path.
fn mmu_ram16(addr: u32) -> bool {
    let a = addr & 0x00FFFFFF;
    return a < 0xBFFFFF;
}

fn mmu_ram32(addr: u32) -> bool {
    let a = addr & 0x00FFFFFF;
    return a < 0xBFFFFD;
}

// 16-bit Big-Endian Read
fn mmu_read16(mmu: M68kMMU&, addr: u32) -> u16 {
    let a = addr & 0x00FFFFFF;
    if !(mmu.reset_overlay && a < 8) && mmu_ram16(addr) {
        return x68k_ram_read16(a as i32);
    }
    let hi = mmu_read8(mmu, addr) as u16;
    let lo = mmu_read8(mmu, addr + 1) as u16;
    return (hi << 8) | lo;
}

// 16-bit Big-Endian Write
fn mmu_write16(mmu: M68kMMU&, addr: u32, val: u16) {
    let a = addr & 0x00FFFFFF;
    if mmu_ram16(addr) {
        mmu.reset_overlay = false;
        x68k_ram_write16(a as i32, val);
        return;
    }
    mmu_write8(mmu, addr, ((val >> 8) & 0xFF) as u8);
    mmu_write8(mmu, addr + 1, (val & 0xFF) as u8);
}

// 32-bit Big-Endian Read
fn mmu_read32(mmu: M68kMMU&, addr: u32) -> u32 {
    let a = addr & 0x00FFFFFF;
    if !(mmu.reset_overlay && a < 8) && mmu_ram32(addr) {
        return x68k_ram_read32(a as i32);
    }
    let hi = mmu_read16(mmu, addr) as u32;
    let lo = mmu_read16(mmu, addr + 2) as u32;
    return (hi << 16) | lo;
}

// 32-bit Big-Endian Write
fn mmu_write32(mmu: M68kMMU&, addr: u32, val: u32) {
    let a = addr & 0x00FFFFFF;
    if mmu_ram32(addr) {
        mmu.reset_overlay = false;
        x68k_ram_write32(a as i32, val);
        return;
    }
    mmu_write16(mmu, addr, ((val >> 16) & 0xFFFF) as u16);
    mmu_write16(mmu, addr + 2, (val & 0xFFFF) as u16);
}

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
    while (mmu.dmac.ch[1].csr & 0x08) != 0 && (mmu.dmac.ch[1].csr & 0x80) == 0 && mmu.dmac.ch[1].mtc != 0 && sasi_is_ready(mmu.sasi) != 0 {
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
            src = mmu.dmac.ch[1].dar;
            dst = mmu.dmac.ch[1].mar;
            if !dev_to_mem {
                src = mmu.dmac.ch[1].mar;
                dst = mmu.dmac.ch[1].dar;
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
    var i: i32 = 0;
    while i < n {
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
        i = i + 1;
    }
    return 0;
}

fn dmac_ch2_on_zero(mmu: M68kMMU&) {
    let ocr = mmu.dmac.ch[2].ocr;
    if (ocr & 8) != 0 {
        if (ocr & 4) != 0 {
            if mmu.dmac.ch[2].bar != 0 {
                let bar = mmu.dmac.ch[2].bar;
                mmu.dmac.ch[2].mar = mmu_read32(mmu, bar) & 0x00FFFFFF;
                mmu.dmac.ch[2].mtc = mmu_read16(mmu, bar + 4);
                mmu.dmac.ch[2].bar = mmu_read32(mmu, bar + 6) & 0x00FFFFFF;
                if mmu.dmac.ch[2].mtc == 0 { dmac_ch2_fail(mmu, 0x0D); }
            }
        } else {
            mmu.dmac.ch[2].btc = mmu.dmac.ch[2].btc - 1;
            if mmu.dmac.ch[2].btc != 0 {
                let bar = mmu.dmac.ch[2].bar;
                mmu.dmac.ch[2].mar = mmu_read32(mmu, bar) & 0x00FFFFFF;
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
        left = left - 1;
        if dmac_ch2_unit(mmu) != 0 { return; }
        if mmu.dmac.ch[2].mtc != 0 {
            mmu.dmac.ch[2].mtc = mmu.dmac.ch[2].mtc - 1;
        }
        if mmu.dmac.ch[2].mtc == 0 {
            dmac_ch2_on_zero(mmu);
        }
        if (mmu.dmac.ch[2].ocr & 3) != 1 { return; }
    }
}
