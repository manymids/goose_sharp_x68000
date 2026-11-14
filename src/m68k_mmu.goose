// Sharp X68000 メモリ管理ユニット (MMU) in Goose

import .x68k_bridge;
import .x68k_mfp;
import .x68k_fdc;
import .x68k_dmac;
import .x68k_sasi;
import .x68k_ram;
import .x68k_rom;
import .x68k_rtc;
namespace mmu;

let ::ADDR_MASK = 0x00FFFFFF; // 68000 のアドレスバスは 24 bit
let ::BGRAM_BYTES = 32768;   // BG マップと PCG ($EB8000-$EBFFFF)
let ::PCG8_BYTES = 16384;    // 8x8 パターンを 1 ドット 1 バイトに展開したもの
let ::PCG16_BYTES = 65536;   // 16x16 パターンを 1 ドット 1 バイトに展開したもの
let ::VRAM_BYTES = 524288;    // TVRAM と GVRAM はそれぞれ 512 KB

// YM2151 に書いた値の控え。音源そのものは C++ (fmgen) にあり、状態を読み返す手段が無いので、
// ツール (arcl_opm) が見るぶんをここに残す。
struct OpmShadow {
    addr: u8 = 0,              // $E90001 に最後に書いたレジスタ番号
    regs: u8[256] = [0; 256],  // レジスタごとの最後の書き込み値
    key_on: u8[8] = [0; 8],    // チャンネルごとのキーオン中のスロット (レジスタ $08 の bit 3-6)
}

struct M68kMMU {
    reset_overlay: bool = true,
    crtc_regs: u8[64] = [0; 64],
    crtc_mode: u8 = 0,
    crtc_fast_clr: i32 = 0,
    mfp: X68kMFP = X68kMFP {},
    fdc: X68kFDC = X68kFDC {},
    dmac: X68kDMAC = X68kDMAC {},
    sasi: X68kSASI = X68kSASI {},
    pal: u8[1024] = [0; 1024],
    vcreg: u8[1024] = [0; 1024],
    sprite: u8[2048] = [0; 2048],
    bgreg: u8[32] = [0; 32],
    bgram: u8[BGRAM_BYTES] = [0; BGRAM_BYTES],
    bg_chr8: u8[PCG8_BYTES] = [0; PCG8_BYTES],
    bg_chr16: u8[PCG16_BYTES] = [0; PCG16_BYTES],
    tvram: u8[VRAM_BYTES] = [0; VRAM_BYTES],
    gvram: u8[VRAM_BYTES] = [0; VRAM_BYTES],
    ioc_int_stat: u8 = 0,
    ioc_int_vect: u8 = 0,
    sasi_irq: bool = false,
    sysport_contrast: u8 = 0,
    sysport_monitor: u8 = 0,
    sysport_keyctrl: u8 = 0,
    sysport_cputype: u8 = 0xFF, // 68000, 10MHz (px68k sysport.c)
    joy1: u8 = 0xFF,
    joy2: u8 = 0xFF,
    pia_c: u8 = 0x0B,           // 8255 ポート C。bit 0-3 が ADPCM のパンとサンプリング周波数
    opm: OpmShadow = OpmShadow {},
    // 68000 group 0 exceptions. Checks apply only while the CPU runs an instruction.
    cpu_access: bool = false,
    user_mode: bool = false,
    fault: i32 = 0,              // 0 none, 2 bus error, 3 address error
    fault_addr: u32 = 0,
    fault_write: bool = false,
    cur_ir: u16 = 0,
    // Bus wait of the current instruction in 1/40 cycles (m68k::step adds whole cycles).
    wait40: i32 = 0,
    // Main RAM below this is supervisor-only ($E86001, 8 KB units).
    svs_limit: u32 = 0x2000,
    // $EAFF81-$EAFF89: supervisor-only 256 KB blocks from $200000 (index = address >> 18).
    ram_super: u8[48] = [0; 48],
    xb2_area: u8[16] = [0; 16],
    // Address of the instruction being executed (stacked by group 0 exceptions).
    inst_pc: u32 = 0,
    // Battery-backed: mmu::init leaves it running across machine resets.
    rtc: X68kRTC = X68kRTC {},
}
type ::M68kMMU = mmu::M68kMMU;

// CRTC の 16 bit レジスタ。値は crtc_regs の上位バイト側の添字。
let ::CRTC_HSTART = 0x04; // R02 水平表示開始
let ::CRTC_HEND = 0x06;   // R03 水平表示終了
let ::CRTC_VTOTAL = 0x08; // R04 垂直トータル
let ::CRTC_VSTART = 0x0C; // R06 垂直表示開始
let ::CRTC_VEND = 0x0E;   // R07 垂直表示終了
let ::CRTC_RASTER = 0x12; // R09 ラスタ割り込み位置
let ::CRTC_TEXT_X = 0x14; // R10 テキストスクロール X
let ::CRTC_TEXT_Y = 0x16; // R11 テキストスクロール Y
let ::CRTC_GRP_X = 0x18;  // R12 グラフィックスクロール X (ページ 0)
let ::CRTC_GRP_Y = 0x1A;  // R13 グラフィックスクロール Y (ページ 0)

fn crtc_word(mmu: M68kMMU&, hi: i32) -> i32 {
    // crtc_regs は 64 バイト。マスクしておくと境界検査が要らない。
    return ((mmu.crtc_regs[hi & 63] as i32) << 8) | mmu.crtc_regs[(hi + 1) & 63];
}

// 機械のリセット。電池で保持される RTC だけを残し、VRAM やパレットも含めてほかは既定値に戻す。
// ポート C を書き換える。下位 4 ビットが変わったときだけ ADPCM へ伝える。
fn set_pia_c(mmu: M68kMMU&, next: u8) {
    let changed = mmu.pia_c ^ next;
    mmu.pia_c = next;
    if (changed & 0x0F) != 0 { c_sound_adpcm_set_pan(next & 0x0F); }
}

fn init(mmu: M68kMMU&) {
    mmu = M68kMMU { rtc: mmu.rtc, .. };
    mmu.mfp.init(); // MFP のレジスタは 0 ではない初期値を持つ
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
    if i >= VRAM_BYTES { return 0; }
    return mmu.gvram[i as i64];
}

fn gvram_set(mmu: M68kMMU&, i: u32, val: u8) {
    if i >= VRAM_BYTES { return; }
    mmu.gvram[i as i64] = val;
}

fn gvram_and16(mmu: M68kMMU&, off: u32, mask: u16) {
    let o: i64 = off;
    if o + 1 >= VRAM_BYTES { return; }
    let lo: u16 = mmu.gvram[o];
    let hi: u16 = mmu.gvram[o + 1];
    let next = (lo | (hi << 8)) & mask;
    mmu.gvram[o] = next as! u8;
    mmu.gvram[o + 1] = (next >> 8) as! u8;
}

fn gvram_fast_clear(mmu: M68kMMU&, reg2b: u8, reg29: u8, scroll_x: u32, scroll_y: u32) {
    let masks: u16[16] = [
        0xFFFF, 0xFFF0, 0xFF0F, 0xFF00, 0xF0FF, 0xF0F0, 0xF00F, 0xF000,
        0x0FFF, 0x0FF0, 0x0F0F, 0x0F00, 0x00FF, 0x00F0, 0x000F, 0x0000,
    ];
    let mask = masks[(reg2b & 0x0F) as i64];
    let v: u32 = if (reg29 & 4) != 0 { 512 } else { 256 };
    let h: u32 = if (reg29 & 3) != 0 { 512 } else { 256 };
    var w0 = h;
    var w1: u32 = 0;
    let sx = scroll_x & 0x1FF;
    if sx + w0 > (512) {
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
            mmu.gvram_and16(p, mask);
            p += 2;
            x += 1;
        }
        if w1 > 0 {
            x = 0;
            p = offset;
            while x < w1 {
                mmu.gvram_and16(p, mask);
                p += 2;
                x += 1;
            }
        }
        y += 1;
    }
}

fn gvram_cpu_read(mmu: M68kMMU&, off: i32, r20: u8) -> u8 {
    if off < 0 { return 0; }
    let adr = (off as u32) & 0x1FFFFF;
    let kind = gvram_type(r20);
    if kind == 0 {
        if (adr & 1) == 0 { return 0; }
        var i = gvram_addr1024(adr);
        if (adr & 0x100000) == 0 { i = i ^ 1; }
        if i >= VRAM_BYTES { return 0; }
        let b = mmu.gvram_get(i);
        if (adr & 0x400) != 0 { return b >> 4; }
        return b & 0x0F;
    }
    if kind == 1 {
        if (adr & 1) == 0 { return 0; }
        if adr < 0x80000 { return mmu.gvram_get(adr ^ 1) & 0x0F; }
        let i = adr & 0x7FFFF;
        if adr < 0x100000 { return mmu.gvram_get(i ^ 1) >> 4; }
        if adr < 0x180000 { return mmu.gvram_get(i) & 0x0F; }
        return mmu.gvram_get(i) >> 4;
    }
    if kind == 2 || kind == 3 {
        if adr < 0x80000 {
            if (adr & 1) != 0 { return mmu.gvram_get(adr ^ 1); }
            return 0;
        }
        if adr < 0x100000 {
            let i = adr & 0x7FFFF;
            if (i & 1) != 0 { return mmu.gvram_get(i); }
            return 0;
        }
        return 0;
    }
    if adr < 0x80000 { return mmu.gvram_get(adr ^ 1); }
    return 0;
}

fn gvram_cpu_write(mmu: M68kMMU&, off: i32, val: u8, r20: u8) {
    if off < 0 { return; }
    let adr = (off as u32) & 0x1FFFFF;
    let kind = gvram_type(r20);
    if kind == 0 {
        if (adr & 1) == 0 { return; }
        var i = gvram_addr1024(adr);
        if (adr & 0x100000) == 0 { i = i ^ 1; }
        if i >= VRAM_BYTES { return; }
        let cur = mmu.gvram_get(i);
        if (adr & 0x400) != 0 {
            mmu.gvram_set(i, (cur & 0x0F) | ((val & 0x0F) << 4));
        } else {
            mmu.gvram_set(i, (cur & 0xF0) | (val & 0x0F));
        }
        return;
    }
    if kind == 1 {
        if (adr & 1) == 0 { return; }
        if adr < 0x80000 {
            let i = adr ^ 1;
            mmu.gvram_set(i, (mmu.gvram_get(i) & 0xF0) | (val & 0x0F));
            return;
        }
        var i = adr & 0x7FFFF;
        if adr < 0x100000 {
            i ^= 1;
            mmu.gvram_set(i, (mmu.gvram_get(i) & 0x0F) | ((val << 4) & 0xF0));
            return;
        }
        if adr < 0x180000 {
            mmu.gvram_set(i, (mmu.gvram_get(i) & 0xF0) | (val & 0x0F));
            return;
        }
        mmu.gvram_set(i, (mmu.gvram_get(i) & 0x0F) | ((val << 4) & 0xF0));
        return;
    }
    if kind == 2 || kind == 3 {
        if (adr & 1) == 0 { return; }
        if adr < 0x80000 {
            mmu.gvram_set(adr ^ 1, val);
            return;
        }
        if adr < 0x100000 {
            mmu.gvram_set(adr & 0x7FFFF, val);
        }
        return;
    }
    if adr < 0x80000 {
        mmu.gvram_set(adr ^ 1, val);
    }
}

fn tvram_store(mmu: M68kMMU&, adr: u32, data: u8) {
    if adr < VRAM_BYTES {
        mmu.tvram[adr as i64] = data;
    }
}

fn tvram_store_mask(mmu: M68kMMU&, adr: u32, data: u8, r2e: u8, r2f: u8) {
    if adr >= VRAM_BYTES { return; }
    let m = if (adr & 1) != 0 { r2f } else { r2e };
    let cur = mmu.tvram[adr as i64];
    mmu.tvram[adr as i64] = (cur & m) | (data & (m ^ 0xFF));
}

fn write_tvram_access(mmu: M68kMMU&, off: i32, val: u8, r2a: u8, r2b: u8, r2e: u8, r2f: u8) {
    if off < 0 { return; }
    var adr = (off as u32) & 0x7FFFF;
    if (r2a & 1) != 0 {
        adr &= 0x1FFFF;
        if (r2a & 2) != 0 {
            if (r2b & 0x10) != 0 { mmu.tvram_store_mask(adr, val, r2e, r2f); }
            if (r2b & 0x20) != 0 { mmu.tvram_store_mask(adr + 0x20000, val, r2e, r2f); }
            if (r2b & 0x40) != 0 { mmu.tvram_store_mask(adr + 0x40000, val, r2e, r2f); }
            if (r2b & 0x80) != 0 { mmu.tvram_store_mask(adr + 0x60000, val, r2e, r2f); }
        } else {
            if (r2b & 0x10) != 0 { mmu.tvram_store(adr, val); }
            if (r2b & 0x20) != 0 { mmu.tvram_store(adr + 0x20000, val); }
            if (r2b & 0x40) != 0 { mmu.tvram_store(adr + 0x40000, val); }
            if (r2b & 0x80) != 0 { mmu.tvram_store(adr + 0x60000, val); }
        }
    } else if (r2a & 2) != 0 {
        mmu.tvram_store_mask(adr, val, r2e, r2f);
    } else {
        mmu.tvram_store(adr, val);
    }
}

fn tvram_raster_copy(mmu: M68kMMU&, src_line: u32, dst_line: u32, plane_mask: u8) {
    let src = (src_line << 9) & 0x1FFFF;
    let dst = (dst_line << 9) & 0x1FFFF;
    for bit in 4 {
        let flag: u8 = 1 << bit;
        if (plane_mask & flag) != 0 {
            var plane: u32 = 0;
            if bit == 1 { plane = 0x20000; }
            if bit == 2 { plane = 0x40000; }
            if bit == 3 { plane = 0x60000; }
            for i in 512 {
                let s: i64 = src + plane + (i as u32);
                let d: i64 = dst + plane + (i as u32);
                mmu.tvram[d] = mmu.tvram[s];
            }
        }
    }
}

fn write_bgram(mmu: M68kMMU&, off: i32, val: u8) {
    if off < 0 || off >= 0x8000 { return; }
    mmu.bgram[off] = val;
    if off < 0x2000 {
        mmu.bg_chr8[off * 2] = val >> 4;
        mmu.bg_chr8[off * 2 + 1] = val & 15;
    }
    let bg16 = ((off & 3) * 2) + ((off & 0x3C) * 4) + ((off & 0x40) >> 3) + ((off & 0x7F80) * 2);
    if bg16 + 1 < PCG16_BYTES {
        mmu.bg_chr16[bg16] = val >> 4;
        mmu.bg_chr16[bg16 + 1] = val & 15;
    }
}

fn sasi_note(mmu: M68kMMU&) {
    if mmu.sasi.consume_status_edge() {
        mmu.ioc_int_stat |= 0x10;
        if (mmu.ioc_int_stat & 8) != 0 {
            mmu.sasi_irq = true;
        }
    }
}

fn raise_fault(mmu: M68kMMU&, kind: i32, a: u32, write: bool) {
    if mmu.fault == 0 {
        mmu.fault = kind;
        mmu.fault_addr = a;
        mmu.fault_write = write;
    }
}

// User mode reaches only main RAM above the supervisor area.
fn user_denied(mmu: M68kMMU&, a: u32) -> bool {
    if a >= 0xC00000 || a < mmu.svs_limit { return true; }
    return a >= 0x200000 && mmu.ram_super[(a >> 18) as i64] != 0;
}

// 8-bit I/O ports ($E86000-$E9DFFF): a word access touches only the odd byte.
fn byte_port(a: u32) -> bool {
    return a >= 0xE86000 && a < 0xE9E000;
}

// Sprite RAM and registers do not answer at dot clocks of 25 MHz and above (R20 %1xx1x).
fn sprite_absent(mmu: M68kMMU&, a: u32) -> bool {
    if (mmu.crtc_regs[0x29] & 0x12) != 0x12 { return false; }
    return a < 0xEB0800 || (a >= 0xEB0840 && a < 0xEB4000) || a >= 0xEB8000;
}

// X68000 (EXPERT, no expansion boards) byte accesses that end in a bus error, as in XEiJ.
fn bus_error8(mmu: M68kMMU&, a: u32, write: bool) -> bool {
    if mmu.user_mode && mmu.user_denied(a) { return true; }
    if a < 0xE86000 { return false; }
    if a < 0xE88000 { return !write || (a & 1) == 0; } // area set: write-only odd port
    if a < 0xE9E000 {
        if a >= 0xE8C000 && a < 0xE90000 { return false; } // printer, system port
        return (a & 1) == 0;
    }
    if a < 0xEB0000 {
        return !(a >= 0xEAFF81 && a <= 0xEAFF89 && (a & 1) != 0);
    }
    if a < 0xEC0000 { return mmu.sprite_absent(a); }
    if a < 0xED0000 { return true; }
    if a < 0xED4000 { return false; } // SRAM
    if a < 0xF00000 { return true; }
    return write; // CGROM, IPLROM
}

// True when the byte access must not reach the device.
fn check8(mmu: M68kMMU&, a: u32, write: bool) -> bool {
    if mmu.fault != 0 { return true; }
    if mmu.bus_error8(a, write) {
        mmu.raise_fault(2, a, write);
        return true;
    }
    return false;
}

// Checks shared by word and long accesses: pending fault, odd address, user area.
fn check_wide(mmu: M68kMMU&, a: u32, write: bool) -> bool {
    if mmu.fault != 0 { return true; }
    if (a & 1) != 0 {
        mmu.raise_fault(3, a, write);
        return true;
    }
    if mmu.user_mode && mmu.user_denied(a) {
        mmu.raise_fault(2, a, write);
        return true;
    }
    return false;
}

// Wait per CPU bus access on a 68000 X68000, in 1/40 cycles (XEiJ mpuSetWait, measured on
// hardware): DRAM refresh 1/8, video controller 0.6, CRTC/ports/sprites/SRAM/ROM 1, GVRAM 1.1,
// RTC/OPM/ADPCM/FDC/HDC/PPI/IOI 1.7, TVRAM 2, SRAM 2, palette 2.6, MFP 4.3, SCC 6, DMAC 15.
fn bus_wait40(a: u32) -> i32 {
    if a < 0xC00000 { return 5; }
    if a < 0xE00000 { return 44; }
    if a < 0xE80000 { return 80; }
    if a < 0xE82000 { return 40; }
    if a < 0xE82400 { return 104; }
    if a < 0xE84000 { return 24; }
    if a < 0xE86000 { return 600; }
    if a < 0xE88000 { return 40; }
    if a < 0xE8A000 { return 172; }
    if a < 0xE8C000 { return 68; }
    if a < 0xE90000 { return 40; }
    if a < 0xE98000 { return 68; }
    if a < 0xE9A000 { return 240; }
    if a < 0xE9E000 { return 68; }
    if a >= 0xED0000 && a < 0xED4000 { return 80; } // SRAM: XEiJ charges its wait twice
    return 40;
}

// 0xE80000 以上からの 8 bit 読み出し。番地順。応答しない番地は 0。
fn io_read8(mmu: M68kMMU&, a: u32) -> u8 {
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

    // 0x00E82000 - 0x00E823FF: Palette RAM (1024 bytes)
    if a >= 0xE82000 && a < 0xE82400 {
        return mmu.pal[a & 0x3FF];
    }

    // 0x00E82400 - 0x00E827FF: Video Controller Registers
    if a >= 0xE82400 && a < 0xE82800 {
        return mmu.vcreg[a & 0x3FF];
    }

    // 0x00E84000: DMAC
    if (a & 0xFFFF00) == 0xE84000 {
        return mmu.dmac.read(a);
    }

    // 0x00E88000 - 0x00E8803F: MFP (MC68901)
    if (a & 0xFFFFC0) == 0xE88000 {
        if (a & 1) != 0 {
            let reg = ((a & 0x3F) >> 1) as i32;
            let v = mmu.mfp.read(reg);
            // GPIP0 is the RTC ALARM output.
            if reg == 0 { return (v & 0xFE) | (if mmu.rtc.alarm_pin() { 1 } else { 0 }); }
            return v;
        }
        return 0xFF;
    }

    // 0x00E8A000 - 0x00E8BFFF: RTC (RP5C15)
    if (a & 0xFFE000) == 0xE8A000 {
        return mmu.rtc.read((a & 31) as i32);
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
        return mmu.fdc.read(reg);
    }

    // 0x00E96000 - 0x00E97FFF: SASI
    if (a & 0x00FFE000) == 0x00E96000 {
        let v = mmu.sasi.read(a);
        mmu.sasi_note();
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
        if a == 0xE9A005 { return mmu.pia_c; }
        return 0xFF;
    }

    // 0x00E9C000 - 0x00E9C003: IOC (I/O Controller)
    if (a & 0xFFFF00) == 0xE9C000 {
        if a == 0xE9C001 {
            return mmu.ioc_int_stat;
        }
        return 0xFF;
    }

    // $EAFF81-$EAFF89: expansion RAM supervisor area (write-only; XEiJ reads back the value)
    if a >= 0xEAFF80 && a < 0xEAFF90 {
        return mmu.xb2_area[(a & 0x0F) as i64];
    }

    // 0x00EB0000 - 0x00EB07FF: Sprite Registers
    if a >= 0xEB0000 && a < 0xEB0800 {
        return mmu.sprite[a & 0x7FF];
    }

    // 0x00EB0800 - 0x00EB081F: BG Control Registers
    if a >= 0xEB0800 && a < 0xEB0820 {
        return mmu.bgreg[a & 0x1F];
    }

    // 0x00EB8000 - 0x00EBFFFF: BG / PCG RAM
    if a >= 0xEB8000 && a < 0xEC0000 {
        return mmu.bgram[a & 0x7FFF];
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

    return 0;
}

// 8 bit 読み出し。RAM、GVRAM、TVRAM の順に見て、残りは mmu::io_read8 へ。
fn read8(mmu: M68kMMU&, addr: u32) -> u8 {
    let a = addr & ADDR_MASK;
    if mmu.cpu_access {
        if (mmu.fault != 0 || mmu.user_mode || a >= 0xE86000) && mmu.check8(a, false) { return 0xFF; }
        mmu.wait40 += bus_wait40(a);
    }

    // Reset overlay for vector table (0x000000 - 0x000007)
    if mmu.reset_overlay && a < 8 {
        // Return initial vector from IPLROM at 0x10000
        return x68k_ipl_read((0x10000 + (a as i32)));
    }

    // 0x000000 - 0xBFFFFF: Main RAM (upto 12MB)
    if a < 0xC00000 {
        return x68k_ram_read(a as i32);
    }

    // 0xC00000 - 0xDFFFFF: GVRAM (up to 2MB plane addressing)
    if a < 0xE00000 {
        return mmu.gvram_cpu_read((a - 0xC00000) as i32, mmu.crtc_regs[0x28]);
    }

    // 0xE00000 - 0xE7FFFF: TVRAM (512KB)
    if a < 0xE80000 {
        return mmu.tvram[a & 0x7FFFF];
    }

    // 0xE80000 以上: I/O、スプライト / BG、SRAM、ROM
    return mmu.io_read8(a);
}

// デバッガ用の読み出し。読むと状態が変わるレジスタ (MFP の UDR、FDC のデータ、SASI) は
// 状態を進めずに値だけ返す。それ以外は mmu::read8 と同じ。
fn peek8(mmu: M68kMMU&, addr: u32) -> u8 {
    let a = addr & ADDR_MASK;
    if (a & 0xFFFFC0) == 0xE88000 && (a & 1) != 0 && ((a & 0x3F) >> 1) == MFP_UDR {
        return mmu.mfp.last_key;
    }
    if (a & 0xFFFF00) == 0xE94000 { return mmu.fdc.peek((a & 0x07) as i32); }
    if (a & 0x00FFE000) == 0x00E96000 { return mmu.sasi.peek(a); }
    return mmu.read8(addr);
}

// 0xE80000 以上への 8 bit 書き込み。番地順。応答しない番地は何もしない。
fn io_write8(mmu: M68kMMU&, a: u32, val: u8) {
    // 0x00E80000 - 0x00E804FF: CRTC
    if a >= 0xE80000 && a < 0xE80500 {
        if a == 0xE80481 {
            // CRTC operation port (Raster Copy & Fast Clear)
            mmu.crtc_mode = (val | (mmu.crtc_mode & 0x02));
            if (mmu.crtc_mode & 8) != 0 {
                let src_line: u32 = mmu.crtc_regs[0x2C];
                let dst_line: u32 = mmu.crtc_regs[0x2D];
                let mask = mmu.crtc_regs[0x2B];
                mmu.tvram_raster_copy(src_line, dst_line, mask);
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
        if reg == 0x2D {
            if (mmu.crtc_mode & 8) != 0 {
                let src_line: u32 = mmu.crtc_regs[0x2C];
                let dst_line: u32 = val;
                let mask = mmu.crtc_regs[0x2B];
                mmu.tvram_raster_copy(src_line, dst_line, mask);
            }
        }
        return;
    }

    // 0x00E82000 - 0x00E823FF: Palette RAM (1024 bytes)
    if a >= 0xE82000 && a < 0xE82400 {
        mmu.pal[a & 0x3FF] = val;
        return;
    }

    // 0x00E82400 - 0x00E827FF: Video Controller Registers
    if a >= 0xE82400 && a < 0xE82800 {
        mmu.vcreg[a & 0x3FF] = val;
        return;
    }

    // 0x00E84000 - 0x00E840FF: DMAC (HD63450)
    if (a & 0xFFFF00) == 0xE84000 {
        mmu.dmac.write(a, val);
        if (mmu.dmac.ch[0].csr & 0x08) != 0 && mmu.fdc.exec_len() > 0 {
            let cpu_access = mmu.cpu_access;
            mmu.cpu_access = false;
            mmu.dmac.exec_fdc(mmu.fdc, mmu);
            mmu.cpu_access = cpu_access;
        }
        if mmu.fdc.int_pending {
            mmu.ioc_int_stat |= 0x80;
            mmu.fdc.int_pending = false;
        }
        return;
    }

    // $E86001: main RAM below (n + 1) * 8 KB is supervisor-only
    if a >= 0xE86000 && a < 0xE88000 {
        if (a & 1) != 0 { mmu.svs_limit = ((val as u32) + 1) << 13; }
        return;
    }

    // 0x00E88000 - 0x00E8803F: MFP (MC68901)
    if (a & 0xFFFFC0) == 0xE88000 {
        if (a & 1) != 0 {
            let reg = ((a & 0x3F) >> 1) as i32;
            mmu.mfp.write(reg, val);
        }
        return;
    }

    // 0x00E8A000 - 0x00E8BFFF: RTC (RP5C15)
    if (a & 0xFFE000) == 0xE8A000 {
        mmu.rtc.write((a & 31) as i32, val);
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

    // 0x00E90000 - 0x00E90003: OPM (YM2151)
    if (a & 0xFFFF00) == 0xE90000 {
        if a == 0xE90001 {
            mmu.opm.addr = val;
            c_sound_opm_write(0, val);
        } else if a == 0xE90003 {
            mmu.opm.regs[mmu.opm.addr] = val;
            if mmu.opm.addr == 0x08 { mmu.opm.key_on[val & 7] = (val >> 3) & 15; }
            c_sound_opm_write(1, val);
        }
        return;
    }

    // 0x00E92000 - 0x00E92003: ADPCM (MSM6258)
    if (a & 0xFFFF00) == 0xE92000 {
        c_sound_adpcm_write(a, val);
        return;
    }

    // 0x00E94000 - 0x00E94007: FDC (uPD72065)
    if (a & 0xFFFF00) == 0xE94000 {
        let reg = (a & 0x07) as i32;
        mmu.fdc.write(reg, val);
        if (mmu.dmac.ch[0].csr & 0x08) != 0 && mmu.fdc.exec_len() > 0 {
            let cpu_access = mmu.cpu_access;
            mmu.cpu_access = false;
            mmu.dmac.exec_fdc(mmu.fdc, mmu);
            mmu.cpu_access = cpu_access;
        }
        if mmu.fdc.int_pending {
            mmu.ioc_int_stat |= 0x80;
            mmu.fdc.int_pending = false;
        }
        return;
    }

    // 0x00E96000 - 0x00E97FFF: SASI
    if (a & 0x00FFE000) == 0x00E96000 {
        mmu.sasi.write(a, val);
        mmu.sasi_note();
        return;
    }

    // 0x00E98000 - 0x00E98007: SCC (Z85C30)
    if (a & 0xFFFF00) == 0xE98000 {
        return;
    }

    // 0x00E9A000 - 0x00E9A007: JoyPort / PIA (8255)
    if (a & 0xFFFF00) == 0xE9A000 {
        if a == 0xE9A005 {
            mmu.set_pia_c(val);
        } else if a == 0xE9A007 && (val & 0x80) == 0 {
            // ビットセット / リセット: bit 1-3 がポート C のビット番号、bit 0 が値
            let mask: u8 = 1 << ((val >> 1) & 7);
            mmu.set_pia_c(if (val & 1) != 0 { mmu.pia_c | mask } else { mmu.pia_c & ~mask });
        }
        return;
    }

    // 0x00E9C000 - 0x00E9C003: IOC (I/O Controller)
    if (a & 0xFFFF00) == 0xE9C000 {
        if a == 0xE9C001 {
            mmu.ioc_int_stat &= 0xF0;
            mmu.ioc_int_stat |= (val & 0x0F);
            g_disk.media_enable = (mmu.ioc_int_stat & 2) != 0;
        } else if a == 0xE9C003 {
            mmu.ioc_int_vect = (val & 0xFC);
        }
        return;
    }

    // $EAFF81-$EAFF89 (odd): one bit per 256 KB block, 2 MB per port starting at $200000
    if a >= 0xEAFF81 && a <= 0xEAFF89 && (a & 1) != 0 {
        mmu.xb2_area[(a & 0x0F) as i64] = val;
        let first = (((a & 14) + 2) << 20) >> 18;
        for m in 8 {
            mmu.ram_super[(first + (m as u32)) as i64] = (val >> (m as u8)) & 1;
        }
        return;
    }

    // 0x00EB0000 - 0x00EB07FF: Sprite Registers
    if a >= 0xEB0000 && a < 0xEB0800 {
        mmu.sprite[a & 0x7FF] = val;
        return;
    }

    // 0x00EB0800 - 0x00EB081F: BG Control Registers
    if a >= 0xEB0800 && a < 0xEB0820 {
        mmu.bgreg[a & 0x1F] = val;
        return;
    }

    // 0x00EB8000 - 0x00EBFFFF: BG / PCG RAM
    if a >= 0xEB8000 && a < 0xEC0000 {
        mmu.write_bgram((a - 0xEB8000) as i32, val);
        return;
    }

    // 0xED0000 - 0xED3FFF: SRAM (16KB)
    if a >= 0xED0000 && a < 0xED4000 {
        x68k_sram_write((a - 0xED0000) as i32, val);
        return;
    }
}

// 8 bit 書き込み。RAM、GVRAM、TVRAM の順に見て、残りは mmu::io_write8 へ。
fn write8(mmu: M68kMMU&, addr: u32, val: u8) {
    let a = addr & ADDR_MASK;
    if mmu.cpu_access {
        if (mmu.fault != 0 || mmu.user_mode || a >= 0xE86000) && mmu.check8(a, true) { return; }
        mmu.wait40 += bus_wait40(a);
    }

    // Reset overlay is disabled on any write to RAM
    if a < 0xC00000 {
        mmu.reset_overlay = false;
        x68k_ram_write(a as i32, val);
        return;
    }

    // 0xC00000 - 0xDFFFFF: GVRAM
    if a < 0xE00000 {
        mmu.gvram_cpu_write((a - 0xC00000) as i32, val, mmu.crtc_regs[0x28]);
        return;
    }

    // 0xE00000 - 0xE7FFFF: TVRAM (512KB)
    if a < 0xE80000 {
        let off = (a - 0xE00000) as i32;
        mmu.write_tvram_access(off, val, mmu.crtc_regs[0x2A], mmu.crtc_regs[0x2B], mmu.crtc_regs[0x2E], mmu.crtc_regs[0x2F]);
        return;
    }

    // 0xE80000 以上: I/O、スプライト / BG、SRAM、ROM
    mmu.io_write8(a, val);
}

// Both bytes sit in the RAM window (through 0xBFFFFF). The last byte stays on the byte path.
fn ram16(addr: u32) -> bool {
    let a = addr & ADDR_MASK;
    return a < 0xBFFFFF;
}

fn ram32(addr: u32) -> bool {
    let a = addr & ADDR_MASK;
    return a < 0xBFFFFD;
}

// 16-bit Big-Endian Read
fn read16(mmu: M68kMMU&, addr: u32) -> u16 {
    let a = addr & ADDR_MASK;
    if mmu.cpu_access && (mmu.fault != 0 || (a & 1) != 0 || mmu.user_mode) && mmu.check_wide(a, false) { return 0xFFFF; }
    if !(mmu.reset_overlay && a < 8) && ram16(addr) {
        if mmu.cpu_access { mmu.wait40 += 5; }
        return x68k_ram_read16(a as i32);
    }
    let wait = mmu.wait40 + bus_wait40(a);
    var v: u16 = 0;
    if byte_port(a) {
        v = 0xFF00 | (mmu.read8(addr + 1) as u16);
    } else {
        let hi: u16 = mmu.read8(addr);
        let lo: u16 = mmu.read8(addr + 1);
        v = (hi << 8) | lo;
    }
    if mmu.cpu_access { mmu.wait40 = wait; }
    return v;
}

// 16-bit Big-Endian Write
fn write16(mmu: M68kMMU&, addr: u32, val: u16) {
    let a = addr & ADDR_MASK;
    if mmu.cpu_access && (mmu.fault != 0 || (a & 1) != 0 || mmu.user_mode) && mmu.check_wide(a, true) { return; }
    if ram16(addr) {
        if mmu.cpu_access { mmu.wait40 += 5; }
        mmu.reset_overlay = false;
        x68k_ram_write16(a as i32, val);
        return;
    }
    let wait = mmu.wait40 + bus_wait40(a);
    if byte_port(a) {
        mmu.write8(addr + 1, (val & 0xFF) as u8);
    } else {
        mmu.write8(addr, ((val >> 8) & 0xFF) as u8);
        mmu.write8(addr + 1, (val & 0xFF) as u8);
    }
    if mmu.cpu_access { mmu.wait40 = wait; }
}

// 32-bit Big-Endian Read
fn read32(mmu: M68kMMU&, addr: u32) -> u32 {
    let a = addr & ADDR_MASK;
    if mmu.cpu_access && (mmu.fault != 0 || (a & 1) != 0 || mmu.user_mode) && mmu.check_wide(a, false) { return 0xFFFFFFFF; }
    if !(mmu.reset_overlay && a < 8) && ram32(addr) {
        if mmu.cpu_access { mmu.wait40 += 10; }
        return x68k_ram_read32(a as i32);
    }
    let hi: u32 = mmu.read16(addr);
    let lo: u32 = mmu.read16(addr + 2);
    return (hi << 16) | lo;
}

// 32-bit Big-Endian Write
fn write32(mmu: M68kMMU&, addr: u32, val: u32) {
    let a = addr & ADDR_MASK;
    if mmu.cpu_access && (mmu.fault != 0 || (a & 1) != 0 || mmu.user_mode) && mmu.check_wide(a, true) { return; }
    if ram32(addr) {
        if mmu.cpu_access { mmu.wait40 += 10; }
        mmu.reset_overlay = false;
        x68k_ram_write32(a as i32, val);
        return;
    }
    mmu.write16(addr, ((val >> 16) & 0xFFFF) as u16);
    mmu.write16(addr + 2, (val & 0xFFFF) as u16);
}
