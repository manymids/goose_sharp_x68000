// Sharp X68000 のメモリマップ (RAM、VRAM、ROM、I/O の読み書き)

import .x68k_bridge;
import .x68k_mfp;
import .x68k_fdc;
import .x68k_dmac;
import .x68k_sasi;
import .x68k_ram;
import .x68k_rom;
import .x68k_rtc;
import .x68k_adpcm;
import .x68k_opm;
namespace mmu;

let ::ADDR_MASK = 0x00FFFFFF; // 68000 のアドレスバスは 24 bit
let ::BGRAM_BYTES = 32768;   // BG マップと PCG ($EB8000-$EBFFFF)
let ::PCG8_BYTES = 16384;    // 8x8 パターンを 1 ドット 1 バイトに展開したもの
let ::PCG16_BYTES = 65536;   // 16x16 パターンを 1 ドット 1 バイトに展開したもの
let ::VRAM_BYTES = 524288;    // TVRAM と GVRAM はそれぞれ 512 KB

// YM2151 に書いた値の控え。ツール (arcl_opm) が見る。音源そのものは fm (x68k_opm)。
struct OpmShadow {
    addr: u8 = 0,              // $E90001 に最後に書いたレジスタ番号
    regs: u8[256] = [0; 256],  // レジスタごとの最後の書き込み値
    key_on: u8[8] = [0; 8],    // チャンネルごとのキーオン中のスロット (レジスタ $08 の bit 3-6)
}

// 命令の途中で起きたバスの失敗。68000 のグループ 0 例外になる。
enum Fault { None, Bus, Address }

// 失敗の種類の例外ベクタ番号 (バスエラー 2、アドレスエラー 3)。
fn fault_vector(f: Fault) -> i32 {
    match f {
        Bus => { return 2; },
        Address => { return 3; },
        None => { return 0; },
    }
}

// CRTC のレジスタは 16 bit で、crtc_regs はそのバイト列 (R00 が 0, 1)。HI が上位バイト、LO が下位バイト。
let ::CRTC_R00_LO = 0x01;    // 水平の総数
let ::CRTC_R01_LO = 0x03;    // 水平同期の終わり
let ::CRTC_R06_LO = 0x0D;    // 垂直表示の始まり
let ::CRTC_R20_HI = 0x28;    // メモリモード (グラフィックの色数など)
let ::CRTC_R20_LO = 0x29;    // 解像度 (bit 4 が 31 kHz、bit 2, 3 が縦の大きさ)
let ::CRTC_R21_HI = 0x2A;    // テキストの同時アクセス
let ::CRTC_R21_LO = 0x2B;    // テキストのプレーン選択とラスタコピー、高速クリアの面
let ::CRTC_R22_HI = 0x2C;    // ラスタコピーの元のライン
let ::CRTC_R22_LO = 0x2D;    // ラスタコピーの先のライン
let ::CRTC_R23_HI = 0x2E;    // テキストのビットマスク
let ::CRTC_R23_LO = 0x2F;

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
    sysport_cputype: u8 = 0xFF, // 68000、10 MHz (px68k sysport.c)
    joy1: u8 = 0xFF,
    joy2: u8 = 0xFF,
    pia_c: u8 = 0x0B,           // 8255 ポート C。bit 0-3 が ADPCM のパンとサンプリング周波数
    opm: OpmShadow = OpmShadow {},
    adpcm: X68kADPCM = X68kADPCM {},
    fm: X68kOPM = X68kOPM {},   // YM2151。本体のリセットでは作り直さず、チップのリセットをかける
    // 68000 のグループ 0 例外。検査するのは CPU が命令を実行している間だけ。
    cpu_access: bool = false,
    user_mode: bool = false,
    fault: Fault = Fault.None,   // 今の命令で起きたバスの失敗 (例外は命令の終わりで起こす)
    fault_addr: u32 = 0,
    fault_write: bool = false,
    cur_ir: u16 = 0,
    // 今の命令のバスウェイト (1/40 サイクル単位。m68k::step が整数のサイクルを足す)。
    wait40: i32 = 0,
    // メイン RAM のこの番地未満はスーパーバイザ専用 ($E86001、8 KB 単位)。
    svs_limit: u32 = 0x2000,
    // $EAFF81-$EAFF89: $200000 から 256 KB ごとのスーパーバイザ専用ブロック (添字 = 番地 >> 18)。
    ram_super: u8[48] = [0; 48],
    xb2_area: u8[16] = [0; 16],
    // 実行中の命令の番地 (グループ 0 例外で積む)。
    inst_pc: u32 = 0,
    // 電池で保持される: mmu::init は機械のリセットをまたいで動かし続ける。
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
    if (changed & 0x0F) != 0 { mmu.adpcm.set_pan(next & 0x0F); }
}

fn init(mmu: M68kMMU&) {
    mmu = M68kMMU { rtc: mmu.rtc, fm: mmu.fm, .. };
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
    // 1 行は 512 ドット。右端を越えたぶん (w1) は行の先頭へ折り返す
    for y: u32 in v {
        let offset = ((y + sy) & 0x1FF) << 10;
        for x: u32 in w0 { mmu.gvram_and16(offset + (sx + x) * 2, mask); }
        for x: u32 in w1 { mmu.gvram_and16(offset + x * 2, mask); }
    }
}

fn gvram_cpu_read(mmu: M68kMMU&, off: i32, r20: u8) -> u8 {
    if off < 0 { return 0; }
    let adr = (off as u32) & 0x1FFFFF;
    let kind = gvram_type(r20);
    if kind == 0 {
        if (adr & 1) == 0 { return 0; }
        var i = gvram_addr1024(adr);
        if (adr & 0x100000) == 0 { i ^= 1; }
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
        if (adr & 0x100000) == 0 { i ^= 1; }
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
            let plane: u32 = (bit as u32) * 0x20000;   // プレーンは 128 KB ずつ並ぶ
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

// 31 kHz で縦 1024 ライン (インターレース) のモード。描画は 1 ラインおきの面を重ねる。
fn crtc_1024_lines(mmu: M68kMMU&) -> bool {
    return (mmu.crtc_regs[CRTC_R20_LO] & 0x1C) == 0x1C;
}

// この命令で失敗が起きている。
fn failed(mmu: M68kMMU&) -> bool {
    return mmu.fault != Fault.None;
}

// 最初の失敗だけを記録する (例外のスタックフレームに積むのはそれ)。
fn raise_fault(mmu: M68kMMU&, kind: Fault, a: u32, write: bool) {
    if mmu.fault == Fault.None {
        mmu.fault = kind;
        mmu.fault_addr = a;
        mmu.fault_write = write;
    }
}

// ユーザーモードで届くのは、スーパーバイザ領域より上のメイン RAM だけ。
fn user_denied(mmu: M68kMMU&, a: u32) -> bool {
    if a >= 0xC00000 || a < mmu.svs_limit { return true; }
    return a >= 0x200000 && mmu.ram_super[(a >> 18) as i64] != 0;
}

// 8 ビットの I/O ポート ($E86000-$E9DFFF): ワードのアクセスは奇数番地のバイトだけに届く。
fn byte_port(a: u32) -> bool {
    return a >= 0xE86000 && a < 0xE9E000;
}

// ドットクロックが 25 MHz 以上 (R20 %1xx1x) のとき、スプライトの RAM とレジスタは応答しない。
fn sprite_absent(mmu: M68kMMU&, a: u32) -> bool {
    if (mmu.crtc_regs[CRTC_R20_LO] & 0x12) != 0x12 { return false; }
    return a < 0xEB0800 || (a >= 0xEB0840 && a < 0xEB4000) || a >= 0xEB8000;
}

// X68000 (EXPERT、拡張ボードなし) でバスエラーになるバイトのアクセス (XEiJ と同じ)。
fn bus_error8(mmu: M68kMMU&, a: u32, write: bool) -> bool {
    if mmu.user_mode && mmu.user_denied(a) { return true; }
    if a < 0xE86000 { return false; }
    if a < 0xE88000 { return !write || (a & 1) == 0; } // エリアセット: 書き込み専用の奇数番地のポート
    if a < 0xE9E000 {
        if a >= 0xE8C000 && a < 0xE90000 { return false; } // プリンタ、システムポート
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

// バイトのアクセスを機器へ届けてはいけないとき true。
fn check8(mmu: M68kMMU&, a: u32, write: bool) -> bool {
    if mmu.failed() { return true; }
    if mmu.bus_error8(a, write) {
        mmu.raise_fault(Fault.Bus, a, write);
        return true;
    }
    return false;
}

// ワードとロングのアクセスで共通の検査: 失敗の保留、奇数番地、ユーザー領域。
fn check_wide(mmu: M68kMMU&, a: u32, write: bool) -> bool {
    if mmu.failed() { return true; }
    if (a & 1) != 0 {
        mmu.raise_fault(Fault.Address, a, write);
        return true;
    }
    if mmu.user_mode && mmu.user_denied(a) {
        mmu.raise_fault(Fault.Bus, a, write);
        return true;
    }
    return false;
}

// 68000 の X68000 で CPU のバスアクセス 1 回ごとのウェイト (1/40 サイクル単位。XEiJ mpuSetWait、
// 実機で測った値): DRAM のリフレッシュ 1/8、ビデオコントローラ 0.6、CRTC/ポート/スプライト/SRAM/ROM 1、GVRAM 1.1、
// RTC/OPM/ADPCM/FDC/HDC/PPI/IOI 1.7、TVRAM 2、SRAM 2、パレット 2.6、MFP 4.3、SCC 6、DMAC 15。
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
    if a >= 0xED0000 && a < 0xED4000 { return 80; } // SRAM: XEiJ はウェイトを 2 回数える
    return 40;
}

// I/O 領域 ($E80000-$EBFFFF) は 8 KB ごとに 1 つの機器が受け持つ。番地を 13 ビット右へずらした
// 値 (区画の番号) で振り分ける。区画の中で応答する範囲は、機器ごとの腕で確かめる。
let PAGE_CRTC: u32 = 0x740;      // $E80000 CRTC (R00-R23 と操作ポート $E80481)
let PAGE_VIDEO: u32 = 0x741;     // $E82000 パレット ($E82000-$E823FF) とビデオコントローラ ($E82400-$E827FF)
let PAGE_DMAC: u32 = 0x742;      // $E84000 DMAC (HD63450)
let PAGE_AREA: u32 = 0x743;      // $E86000 スーパーバイザ領域の設定 (書き込みだけ)
let PAGE_MFP: u32 = 0x744;       // $E88000 MFP (MC68901)
let PAGE_RTC: u32 = 0x745;       // $E8A000 RTC (RP5C15)
let PAGE_SYSPORT: u32 = 0x747;   // $E8E000 システムポート
let PAGE_OPM: u32 = 0x748;       // $E90000 OPM (YM2151)
let PAGE_ADPCM: u32 = 0x749;     // $E92000 ADPCM (MSM6258)
let PAGE_FDC: u32 = 0x74A;       // $E94000 FDC (uPD72065)
let PAGE_SASI: u32 = 0x74B;      // $E96000 SASI
let PAGE_SCC: u32 = 0x74C;       // $E98000 SCC (Z85C30: マウス、RS-232C)
let PAGE_PIA: u32 = 0x74D;       // $E9A000 8255 (ジョイスティック、ADPCM の設定)
let PAGE_IOC: u32 = 0x74E;       // $E9C000 IOC (割り込みの状態とベクタ)
let PAGE_XAREA: u32 = 0x757;     // $EAE000 拡張 RAM のエリアセット ($EAFF81-$EAFF89)
let PAGE_SPRITE: u32 = 0x758;    // $EB0000 スプライト ($EB0000-$EB07FF) と BG レジスタ ($EB0800-$EB081F)

// 区画の先頭から 256 バイトだけで応答する機器かどうか。
fn in_first_256(a: u32) -> bool {
    return (a & 0x1F00) == 0;
}

// 0xE80000 以上からの 8 bit 読み出し。応答しない番地は 0。
// CRTC の読み出し。読めるのは R20-R21 (0x28-0x2B) と操作ポートだけ。
fn read_crtc(mmu: M68kMMU&, a: u32) -> u8 {
    if a == 0xE80481 {
        // 高速クリアの実行中は bit 1 が立って見える
        return if mmu.crtc_fast_clr > 0 { mmu.crtc_mode | 0x02 } else { mmu.crtc_mode & 0xFD };
    }
    if a >= 0xE80400 { return 0; }
    let reg = (a & 0x3F) as i32;
    return if reg >= 0x28 && reg <= 0x2B { mmu.crtc_regs[reg] } else { 0 };
}

// MFP のレジスタは奇数番地に並ぶ。
fn read_mfp(mmu: M68kMMU&, a: u32) -> u8 {
    if (a & 1) == 0 { return 0xFF; }
    let reg = ((a & 0x3F) >> 1) as i32;
    let v = mmu.mfp.read(reg);
    // GPIP0 は RTC の ALARM 出力。
    if reg == 0 { return (v & 0xFE) | (if mmu.rtc.alarm_pin() { 1 } else { 0 }); }
    return v;
}

fn read_sysport(mmu: M68kMMU&, a: u32) -> u8 {
    if (a & 1) != 0 {
        let reg = ((a & 0x0F) >> 1) as i32;
        if reg == 0 { return 0xF0 | mmu.sysport_contrast; }
        if reg == 1 { return 0xF0 | mmu.sysport_monitor; }
        if reg == 3 { return 0xF0 | mmu.sysport_keyctrl; }
        if reg == 5 { return 0xF0 | mmu.sysport_cputype; }
    }
    return 0xFF;
}

fn io_read8(mmu: M68kMMU&, a: u32) -> u8 {
    match a >> 13 {
        // $E80400 未満は下位 6 ビットのミラー。$E80481 だけが操作ポート。
        PAGE_CRTC => { return if a < 0xE80500 { mmu.read_crtc(a) } else { 0 }; },
        PAGE_VIDEO => {
            if a < 0xE82400 { return mmu.pal[a & 0x3FF]; }
            if a < 0xE82800 { return mmu.vcreg[a & 0x3FF]; }
            return 0;
        },
        PAGE_DMAC => { return if in_first_256(a) { mmu.dmac.read(a) } else { 0 }; },
        PAGE_MFP => { return if (a & 0x1FC0) == 0 { mmu.read_mfp(a) } else { 0 }; },
        PAGE_RTC => { return mmu.rtc.read((a & 31) as i32); },
        PAGE_SYSPORT => { return if (a & 0x1FF0) == 0 { mmu.read_sysport(a) } else { 0 }; },
        PAGE_OPM => { return if in_first_256(a) && (a & 3) == 3 { mmu.fm.read_status() } else { 0 }; },
        PAGE_ADPCM => { return if in_first_256(a) { mmu.adpcm.read(a) } else { 0 }; },
        PAGE_FDC => { return if in_first_256(a) { mmu.fdc.read((a & 0x07) as i32) } else { 0 }; },
        PAGE_SASI => {
            let v = mmu.sasi.read(a);
            mmu.sasi_note();
            return v;
        },
        // チャネル A のコントロールは送信バッファが空 (bit 2) とだけ答える
        PAGE_SCC => { return if in_first_256(a) && (a & 7) == 5 { 4 } else { 0 }; },
        PAGE_PIA => {
            guard in_first_256(a) else { return 0; }
            if a == 0xE9A001 { return mmu.joy1; }
            if a == 0xE9A003 { return mmu.joy2; }
            if a == 0xE9A005 { return mmu.pia_c; }
            return 0xFF;
        },
        PAGE_IOC => {
            guard in_first_256(a) else { return 0; }
            return if a == 0xE9C001 { mmu.ioc_int_stat } else { 0xFF };
        },
        // 書き込み専用だが、XEiJ と同じく書いた値を読み返せる
        PAGE_XAREA => { return if a >= 0xEAFF80 && a < 0xEAFF90 { mmu.xb2_area[(a & 0x0F) as i64] } else { 0 }; },
        PAGE_SPRITE => {
            if a < 0xEB0800 { return mmu.sprite[a & 0x7FF]; }
            if a < 0xEB0820 { return mmu.bgreg[a & 0x1F]; }
            return 0;
        },
        _ => {},
    }
    // I/O の区画の外: BG / PCG RAM、SRAM、CGROM、IPL ROM
    if a >= 0xEB8000 && a < 0xEC0000 { return mmu.bgram[a & 0x7FFF]; }
    if a >= 0xED0000 && a < 0xED4000 { return x68k_sram_read((a - 0xED0000) as i32); }
    if a >= 0xF00000 && a < 0xFC0000 { return x68k_cgrom_read((a - 0xF00000) as i32); }
    if a >= 0xFE0000 { return x68k_ipl_read((a - 0xFE0000) as i32); }
    return 0;
}

// 8 bit 読み出し。RAM、GVRAM、TVRAM の順に見て、残りは mmu::io_read8 へ。
fn read8(mmu: M68kMMU&, addr: u32) -> u8 {
    let a = addr & ADDR_MASK;
    if mmu.cpu_access {
        if (mmu.failed() || mmu.user_mode || a >= 0xE86000) && mmu.check8(a, false) { return 0xFF; }
        mmu.wait40 += bus_wait40(a);
    }

    // リセット直後のベクタテーブル (0x000000-0x000007) の重ね合わせ
    if mmu.reset_overlay && a < 8 {
        // IPL ROM の 0x10000 にある初期ベクタを返す
        return x68k_ipl_read((0x10000 + (a as i32)));
    }

    // 0x000000-0xBFFFFF: メイン RAM (最大 12 MB)
    if a < 0xC00000 {
        return x68k_ram_read(a as i32);
    }

    // 0xC00000-0xDFFFFF: GVRAM (プレーンの番地付けで最大 2 MB)
    if a < 0xE00000 {
        return mmu.gvram_cpu_read((a - 0xC00000) as i32, mmu.crtc_regs[CRTC_R20_HI]);
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
// テキスト VRAM のラスタコピー (CRTC R22 の転送元 / 転送先、R21 のプレーン選択)。
fn crtc_raster_copy(mmu: M68kMMU&) {
    let src_line: u32 = mmu.crtc_regs[CRTC_R22_HI];
    let dst_line: u32 = mmu.crtc_regs[CRTC_R22_LO];
    mmu.tvram_raster_copy(src_line, dst_line, mmu.crtc_regs[CRTC_R21_LO]);
}

// CRTC への書き込み。0xE80481 は操作ポートで、bit 3 がラスタコピー、bit 1 が高速クリア。
// ラスタコピーは、操作ポートで指示したときと、指示が出ている間に転送先 (R22 下位) を書いたときに行う。
fn write_crtc(mmu: M68kMMU&, a: u32, val: u8) {
    if a == 0xE80481 {
        mmu.crtc_mode = (val | (mmu.crtc_mode & 0x02));
        if (mmu.crtc_mode & 8) != 0 { mmu.crtc_raster_copy(); }
        return;
    }
    if a >= 0xE80400 { return; }
    let reg = (a & 0x3F) as i32;
    if reg >= 0x30 { return; }
    mmu.crtc_regs[reg] = val;
    if reg == 0x2D && (mmu.crtc_mode & 8) != 0 { mmu.crtc_raster_copy(); }
}

// FDC と DMAC Ch 0 の DMA 転送実行 (DMAC がバスマスタになって MMU の読み書きを使う)。
// px68k の dma_writemem24 は wm_main 経由なので、GVRAM / TVRAM も CPU と同じ書き込みになる。
fn fdc_dma(dmac: X68kDMAC&, fdc: X68kFDC&, mmu: M68kMMU&) -> bool {
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
            } else if dmac::in_ram(addr, 1) {
                x68k_ram_write(addr as! i32, b);
            } else if addr >= 0xC00000 && addr < 0xE00000 {
                mmu.gvram_cpu_write((addr - 0xC00000) as! i32, b, mmu.crtc_regs[CRTC_R20_HI]);
            } else if addr >= 0xE00000 && addr < 0xE80000 {
                let off = (addr - 0xE00000) as! i32;
                mmu.write_tvram_access(off, b, mmu.crtc_regs[CRTC_R21_HI], mmu.crtc_regs[CRTC_R21_LO], mmu.crtc_regs[CRTC_R23_HI], mmu.crtc_regs[CRTC_R23_LO]);
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
                // チェーンの次のブロック
                if (dmac.ch[0].ocr & 4) != 0 {
                    if dmac.ch[0].bar != 0 {
                        dmac.ch[0].mar = dmac::readmem24_dword(dmac.ch[0].bar) & ADDR_MASK;
                        dmac.ch[0].mtc = dmac::readmem24_word(dmac.ch[0].bar + 4);
                        dmac.ch[0].bar = dmac::readmem24_dword(dmac.ch[0].bar + 6) & ADDR_MASK;
                    }
                } else {
                    if dmac.ch[0].btc > 0 {
                        dmac.ch[0].btc--;
                        if dmac.ch[0].btc != 0 {
                            dmac.ch[0].mar = dmac::readmem24_dword(dmac.ch[0].bar) & ADDR_MASK;
                            dmac.ch[0].mtc = dmac::readmem24_word(dmac.ch[0].bar + 4);
                            dmac.ch[0].bar += 6;
                        }
                    }
                }
            }
        }

        if dmac.ch[0].mtc == 0 {
            // DMAC 転送完了フラグ
            dmac.ch[0].csr |= 0x80; // COC (チャネル動作完了)
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

// FDC か DMAC に書いたあとに呼ぶ。転送の準備がそろっていれば DMA を進め、
// FDC が割り込みを要求していれば IOC に伝える。
fn fdc_service(mmu: M68kMMU&) {
    if (mmu.dmac.ch[0].csr & 0x08) != 0 && mmu.fdc.exec_len() > 0 {
        // DMA の読み書きは CPU のアクセスではないので、保護の検査を外して行う
        let cpu_access = mmu.cpu_access;
        mmu.cpu_access = false;
        fdc_dma(mmu.dmac, mmu.fdc, mmu);
        mmu.cpu_access = cpu_access;
    }
    if mmu.fdc.int_pending {
        mmu.ioc_int_stat |= 0x80;
        mmu.fdc.int_pending = false;
    }
}

fn write_sysport(mmu: M68kMMU&, a: u32, val: u8) {
    if (a & 1) == 0 { return; }
    let reg = ((a & 0x0F) >> 1) as i32;
    if reg == 0 { mmu.sysport_contrast = val & 0x0F; }
    else if reg == 1 { mmu.sysport_monitor = val & 0x0B; }
    else if reg == 3 { mmu.sysport_keyctrl = val & 0x0E; }
    else if reg == 6 { x68k_sram_set_write_enable(if val == 0x31 { 1 } else { 0 }); } // 0x31 で SRAM 書き込み許可
}

// OPM: $E90001 がレジスタ番号、$E90003 がデータ。書いた値は控えにも残す。
fn write_opm(mmu: M68kMMU&, a: u32, val: u8) {
    if a == 0xE90001 {
        mmu.opm.addr = val;
        mmu.fm.write_io(0, val);
    } else if a == 0xE90003 {
        mmu.opm.regs[mmu.opm.addr] = val;
        if mmu.opm.addr == 0x08 { mmu.opm.key_on[val & 7] = (val >> 3) & 15; }
        // レジスタ $1B の bit 7 (CT1) は ADPCM のクロックの切り替えにつながっている
        if mmu.opm.addr == 0x1B { mmu.adpcm.set_clock((val >> 5) & 4); }
        mmu.fm.write_io(1, val);
    }
}

// 8255: $E9A005 がポート C、$E9A007 がコントロール。
fn write_pia(mmu: M68kMMU&, a: u32, val: u8) {
    if a == 0xE9A005 {
        mmu.set_pia_c(val);
    } else if a == 0xE9A007 && (val & 0x80) == 0 {
        // ビットセット / リセット: bit 1-3 がポート C のビット番号、bit 0 が値
        let mask: u8 = 1 << ((val >> 1) & 7);
        mmu.set_pia_c(if (val & 1) != 0 { mmu.pia_c | mask } else { mmu.pia_c & ~mask });
    }
}

// エリアセット ($EAFF81-$EAFF89 の奇数番地): 256 KB のブロックごとに 1 ビットで、
// スーパーバイザ専用にするかどうかを決める。1 ポートが 2 MB ぶんで、$200000 から始まる。
fn write_area_set(mmu: M68kMMU&, a: u32, val: u8) {
    mmu.xb2_area[(a & 0x0F) as i64] = val;
    let first = (((a & 14) + 2) << 20) >> 18;
    for m in 8 {
        mmu.ram_super[(first + (m as u32)) as i64] = (val >> (m as u8)) & 1;
    }
}

fn io_write8(mmu: M68kMMU&, a: u32, val: u8) {
    match a >> 13 {
        PAGE_CRTC => { if a < 0xE80500 { mmu.write_crtc(a, val); } },
        PAGE_VIDEO => {
            if a < 0xE82400 { mmu.pal[a & 0x3FF] = val; }
            else if a < 0xE82800 { mmu.vcreg[a & 0x3FF] = val; }
        },
        PAGE_DMAC => {
            if in_first_256(a) {
                mmu.dmac.write(a, val);
                mmu.fdc_service();
            }
        },
        // $E86001: メイン RAM の (n + 1) * 8 KB 未満をスーパーバイザ専用にする
        PAGE_AREA => { if (a & 1) != 0 { mmu.svs_limit = ((val as u32) + 1) << 13; } },
        PAGE_MFP => { if (a & 0x1FC0) == 0 && (a & 1) != 0 { mmu.mfp.write(((a & 0x3F) >> 1) as i32, val); } },
        PAGE_RTC => { mmu.rtc.write((a & 31) as i32, val); },
        PAGE_SYSPORT => { if (a & 0x1FF0) == 0 { mmu.write_sysport(a, val); } },
        PAGE_OPM => { if in_first_256(a) { mmu.write_opm(a, val); } },
        PAGE_ADPCM => { if in_first_256(a) { mmu.adpcm.write(a, val); } },
        PAGE_FDC => {
            if in_first_256(a) {
                mmu.fdc.write((a & 0x07) as i32, val);
                mmu.fdc_service();
            }
        },
        PAGE_SASI => {
            mmu.sasi.write(a, val);
            mmu.sasi_note();
        },
        PAGE_SCC => {},   // マウスと RS-232C は未実装。書き込みは捨てる
        PAGE_PIA => { if in_first_256(a) { mmu.write_pia(a, val); } },
        PAGE_IOC => {
            if a == 0xE9C001 {
                mmu.ioc_int_stat &= 0xF0;
                mmu.ioc_int_stat |= val & 0x0F;
                g_disk.media_enable = (mmu.ioc_int_stat & 2) != 0;
            } else if a == 0xE9C003 {
                mmu.ioc_int_vect = val & 0xFC;
            }
        },
        // $EAFF81-$EAFF89 の奇数番地: 256 KB ごとに 1 ビット、1 ポートで 2 MB ぶん ($200000 から)
        PAGE_XAREA => { if a >= 0xEAFF81 && a <= 0xEAFF89 && (a & 1) != 0 { mmu.write_area_set(a, val); } },
        PAGE_SPRITE => {
            if a < 0xEB0800 { mmu.sprite[a & 0x7FF] = val; }
            else if a < 0xEB0820 { mmu.bgreg[a & 0x1F] = val; }
        },
        _ => {
            if a >= 0xEB8000 && a < 0xEC0000 { mmu.write_bgram((a - 0xEB8000) as i32, val); }
            else if a >= 0xED0000 && a < 0xED4000 { x68k_sram_write((a - 0xED0000) as i32, val); }
        },
    }
}

// 8 bit 書き込み。RAM、GVRAM、TVRAM の順に見て、残りは mmu::io_write8 へ。
fn write8(mmu: M68kMMU&, addr: u32, val: u8) {
    let a = addr & ADDR_MASK;
    if mmu.cpu_access {
        if (mmu.failed() || mmu.user_mode || a >= 0xE86000) && mmu.check8(a, true) { return; }
        mmu.wait40 += bus_wait40(a);
    }

    // RAM へ書くとリセット直後の重ね合わせは外れる
    if a < 0xC00000 {
        mmu.reset_overlay = false;
        x68k_ram_write(a as i32, val);
        return;
    }

    // 0xC00000-0xDFFFFF: GVRAM
    if a < 0xE00000 {
        mmu.gvram_cpu_write((a - 0xC00000) as i32, val, mmu.crtc_regs[CRTC_R20_HI]);
        return;
    }

    // 0xE00000 - 0xE7FFFF: TVRAM (512KB)
    if a < 0xE80000 {
        let off = (a - 0xE00000) as i32;
        mmu.write_tvram_access(off, val, mmu.crtc_regs[CRTC_R21_HI], mmu.crtc_regs[CRTC_R21_LO], mmu.crtc_regs[CRTC_R23_HI], mmu.crtc_regs[CRTC_R23_LO]);
        return;
    }

    // 0xE80000 以上: I/O、スプライト / BG、SRAM、ROM
    mmu.io_write8(a, val);
}

// 2 バイトとも RAM の窓 (0xBFFFFF まで) にある。最後のバイトはバイトの経路のまま。
fn ram16(addr: u32) -> bool {
    let a = addr & ADDR_MASK;
    return a < 0xBFFFFF;
}

fn ram32(addr: u32) -> bool {
    let a = addr & ADDR_MASK;
    return a < 0xBFFFFD;
}

// 16 ビット、ビッグエンディアンの読み出し
fn read16(mmu: M68kMMU&, addr: u32) -> u16 {
    let a = addr & ADDR_MASK;
    if mmu.cpu_access && (mmu.failed() || (a & 1) != 0 || mmu.user_mode) && mmu.check_wide(a, false) { return 0xFFFF; }
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

// 16 ビット、ビッグエンディアンの書き込み
fn write16(mmu: M68kMMU&, addr: u32, val: u16) {
    let a = addr & ADDR_MASK;
    if mmu.cpu_access && (mmu.failed() || (a & 1) != 0 || mmu.user_mode) && mmu.check_wide(a, true) { return; }
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

// 32 ビット、ビッグエンディアンの読み出し
fn read32(mmu: M68kMMU&, addr: u32) -> u32 {
    let a = addr & ADDR_MASK;
    if mmu.cpu_access && (mmu.failed() || (a & 1) != 0 || mmu.user_mode) && mmu.check_wide(a, false) { return 0xFFFFFFFF; }
    if !(mmu.reset_overlay && a < 8) && ram32(addr) {
        if mmu.cpu_access { mmu.wait40 += 10; }
        return x68k_ram_read32(a as i32);
    }
    let hi: u32 = mmu.read16(addr);
    let lo: u32 = mmu.read16(addr + 2);
    return (hi << 16) | lo;
}

// 32 ビット、ビッグエンディアンの書き込み
fn write32(mmu: M68kMMU&, addr: u32, val: u32) {
    let a = addr & ADDR_MASK;
    if mmu.cpu_access && (mmu.failed() || (a & 1) != 0 || mmu.user_mode) && mmu.check_wide(a, true) { return; }
    if ram32(addr) {
        if mmu.cpu_access { mmu.wait40 += 10; }
        mmu.reset_overlay = false;
        x68k_ram_write32(a as i32, val);
        return;
    }
    mmu.write16(addr, ((val >> 16) & 0xFFFF) as u16);
    mmu.write16(addr + 2, (val & 0xFFFF) as u16);
}
