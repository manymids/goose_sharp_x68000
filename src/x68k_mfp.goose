// Sharp X68000 MC68901 MFP (Multi-Function Peripheral) in Goose

let MFP_GPIP = 0;
let MFP_AER = 1;
let MFP_DDR = 2;
let MFP_IERA = 3;
let MFP_IERB = 4;
let MFP_IPRA = 5;
let MFP_IPRB = 6;
let MFP_ISRA = 7;
let MFP_ISRB = 8;
let MFP_IMRA = 9;
let MFP_IMRB = 10;
let MFP_VR = 11;
let MFP_TACR = 12;
let MFP_TBCR = 13;
let MFP_TCDCR = 14;
let MFP_TADR = 15;
let MFP_TBDR = 16;
let MFP_TCDR = 17;
let MFP_TDDR = 18;
let MFP_SCR = 19;
let MFP_UCR = 20;
let MFP_RSR = 21;
let MFP_TSR = 22;
let MFP_UDR = 23;

// 割り込み要因の番号 (mfp_trigger_int の irq)。0 が最優先で、ベクタは VR の上位 4 bit + (15 - 番号)。
let MFP_IRQ_HSYNC = 0;    // GPIP7: 水平同期
let MFP_IRQ_RASTER = 1;   // GPIP6: CRTC のラスタ割り込み
let MFP_IRQ_TIMER_A = 2;
let MFP_IRQ_KEY = 3;      // キーボードの受信バッファフル
let MFP_IRQ_TIMER_B = 7;
let MFP_IRQ_VDISP = 9;    // GPIP4: 垂直表示期間
let MFP_IRQ_TIMER_C = 10;
let MFP_IRQ_TIMER_D = 11;
let MFP_IRQ_OPM = 12;     // GPIP3: FM 音源

struct X68kMFP {
    regs: u8[24] = [0; 24],
    timer_reload: u8[4] = [0; 4],
    timer_tick: i32[4] = [0; 4],
    last_key: u8 = 0,
    key_buf: u8[128] = [0; 128],
    key_wp: i32 = 0,
    key_rp: i32 = 0,
    key_int_flag: bool = false,
    key_line_div: i32 = 0,
    in_vdisp: bool = true,
    cur_vline: i32 = 0,
    line_cycles: i32 = 0,
    hsync_clk: i32 = 600,
    hsync_start: i32 = 150,
    hsync_end: i32 = 450,
    crtc_intline: i32 = 0,
}

// プリスケーラ分周テーブル (4MHz MFP クロック / 10MHz CPU 基準: px68k mfp.c 準拠)
fn mfp_get_prescaler(mode: i32) -> i32 {
    let m = mode & 7;
    if m == 1 { return 10; }  // 1/4分周: 4 / 0.4 = 10 cycles
    if m == 2 { return 25; }  // 1/10分周: 10 / 0.4 = 25 cycles
    if m == 3 { return 40; }  // 1/16分周: 16 / 0.4 = 40 cycles
    if m == 4 { return 125; } // 1/50分周: 50 / 0.4 = 125 cycles
    if m == 5 { return 160; } // 1/64分周: 64 / 0.4 = 160 cycles
    if m == 6 { return 250; } // 1/100分周: 100 / 0.4 = 250 cycles
    if m == 7 { return 500; } // 1/200分周: 200 / 0.4 = 500 cycles
    return 1;
}

fn mfp_init(mfp: X68kMFP&) {
    mfp = X68kMFP {};
    // X68000 実機デフォルト初期値
    mfp.regs[MFP_GPIP] = 0x7B;
    mfp.regs[MFP_AER] = 0x06;
    mfp.regs[MFP_DDR] = 0x00;
    mfp.regs[MFP_IERA] = 0x18;
    mfp.regs[MFP_IERB] = 0x3E; // (px68k mfp.c 準拠)
    mfp.regs[MFP_IPRA] = 0x00;
    mfp.regs[MFP_IPRB] = 0x00;
    mfp.regs[MFP_ISRA] = 0x00;
    mfp.regs[MFP_ISRB] = 0x00;
    mfp.regs[MFP_IMRA] = 0x18;
    mfp.regs[MFP_IMRB] = 0x3E; // (px68k mfp.c 準拠)
    mfp.regs[MFP_VR] = 0x40; // (ベクタベース = 0x40 = 64)
    mfp.regs[MFP_TACR] = 0x08;
    mfp.regs[MFP_TBCR] = 0x01;
    mfp.regs[MFP_TCDCR] = 0x77;
    mfp.regs[MFP_TADR] = 0x01;
    mfp.regs[MFP_TBDR] = 0x0D;
    mfp.regs[MFP_TCDR] = 0xC8;
    mfp.regs[MFP_TDDR] = 0x14;
    mfp.regs[MFP_SCR] = 0x00;
    mfp.regs[MFP_UCR] = 0x88;
    mfp.regs[MFP_RSR] = 0x01;
    mfp.regs[MFP_TSR] = 0x81;
    mfp.regs[MFP_UDR] = 0x00;
}

// MFP レジスタ Read
fn mfp_read(mfp: X68kMFP&, reg_idx: i32) -> u8 {
    if reg_idx < 0 || reg_idx >= 24 {
        return 0xFF;
    }

    if reg_idx == MFP_GPIP {
        // X68000 MFP GPIP: px68k mfp.c GetGPIP 準拠
        // bit 0, 1: 常に 1 (0x03)
        // bit 4: V-DISP (1 = 表示中 0x10, 0 = 垂直帰線期間 0x00)
        // bit 5: 常に 1 (0x20)
        // bit 6: 1 (vline != CRTC_IntLine)
        // bit 7: H-SYNC (hpos がアクティブ領域外なら 0x80、アクティブなら 0x00)
        var ret: u8 = 0x20;
        if mfp.in_vdisp {
            ret |= 0x13;
        } else {
            ret |= 0x03;
        }

        let hpos = if mfp.hsync_clk > 0 { mfp.line_cycles % mfp.hsync_clk } else { 0 };
        if hpos >= mfp.hsync_start && hpos < mfp.hsync_end {
            ret &= 0x7F;
        } else {
            ret |= 0x80;
        }

        if mfp.cur_vline != mfp.crtc_intline {
            ret |= 0x40;
        }
        return ret;
    }
    if reg_idx == MFP_UDR {
        // 読んだら受け取り済み。次のバイトは Keyboard_Int が出す。
        mfp.key_int_flag = false;
        return mfp.last_key;
    }
    if reg_idx == MFP_RSR {
        // バッファに残りがあるとき bit7 を落とす。空なら立てる。
        if mfp.key_wp != mfp.key_rp {
            return mfp.regs[MFP_RSR] & 0x7F;
        }
        return mfp.regs[MFP_RSR] | 0x80;
    }
    return mfp.regs[reg_idx];
}

// MFP レジスタ Write
fn mfp_write(mfp: X68kMFP&, reg_idx: i32, val: u8) {
    if reg_idx < 0 || reg_idx >= 24 {
        return;
    }

    if reg_idx == MFP_IERA || reg_idx == MFP_IERB {
        mfp.regs[reg_idx] = val;
        mfp.regs[reg_idx + 2] &= val;
        return;
    }
    if reg_idx == MFP_IPRA || reg_idx == MFP_IPRB ||
       reg_idx == MFP_ISRA || reg_idx == MFP_ISRB {
        mfp.regs[reg_idx] &= val;
        return;
    }
    if reg_idx == MFP_IMRA || reg_idx == MFP_IMRB {
        mfp.regs[reg_idx] = val;
        return;
    }
    if reg_idx >= MFP_TADR && reg_idx <= MFP_TDDR {
        let chan = reg_idx - MFP_TADR;
        mfp.timer_reload[chan] = val;
        mfp.regs[reg_idx] = val;
        return;
    }
    if reg_idx == MFP_TSR {
        mfp.regs[reg_idx] = val | 0x80;
        return;
    }
    mfp.regs[reg_idx] = val;
}

// 割り込み要求を発行 (irq: 0..15)
fn mfp_trigger_int(mfp: X68kMFP&, irq: i32) {
    if irq < 8 {
        let flag = (0x80 as u8) >> (irq as u8);
        if (mfp.regs[MFP_IERA] & flag) != 0 {
            mfp.regs[MFP_IPRA] |= flag;
        }
    } else {
        let flag = (0x80 as u8) >> ((irq - 8) as u8);
        if (mfp.regs[MFP_IERB] & flag) != 0 {
            mfp.regs[MFP_IPRB] |= flag;
        }
    }
}

// 割り込みベクタの取得と受付処理 (Level 6 割り込み発生時)
fn mfp_ack_interrupt(mfp: X68kMFP&) -> i32 {
    var flag: u8 = 0x80;
    var vect: i32 = 15;
    while flag != 0 {
        if (mfp.regs[MFP_IPRA] & flag) != 0 && (mfp.regs[MFP_IMRA] & flag) != 0 && (mfp.regs[MFP_ISRA] & flag) == 0 {
            mfp.regs[MFP_IPRA] &= ~flag;
            if (mfp.regs[MFP_VR] & 8) != 0 {
                mfp.regs[MFP_ISRA] |= flag;
            }
            return ((mfp.regs[MFP_VR] & 0xF0)) | vect;
        }
        flag >>= 1;
        vect--;
    }

    flag = 0x80;
    vect = 7;
    while flag != 0 {
        if (mfp.regs[MFP_IPRB] & flag) != 0 && (mfp.regs[MFP_IMRB] & flag) != 0 && (mfp.regs[MFP_ISRB] & flag) == 0 {
            mfp.regs[MFP_IPRB] &= ~flag;
            if (mfp.regs[MFP_VR] & 8) != 0 {
                mfp.regs[MFP_ISRB] |= flag;
            }
            return ((mfp.regs[MFP_VR] & 0xF0)) | vect;
        }
        flag >>= 1;
        vect--;
    }

    return -1;
}

// ペンディング中の割り込みが存在するか判定
fn mfp_has_pending_int(mfp: X68kMFP&) -> bool {
    let pend_a = mfp.regs[MFP_IPRA] & mfp.regs[MFP_IMRA] & ~mfp.regs[MFP_ISRA];
    let pend_b = mfp.regs[MFP_IPRB] & mfp.regs[MFP_IMRB] & ~mfp.regs[MFP_ISRB];
    return pend_a != 0 || pend_b != 0;
}

// タイマ A イベントカウント (走査線ごとに呼び出し: px68k MFP_TimerA 準拠)
fn mfp_timer_a(mfp: X68kMFP&, vline: i32, vstart: i32, vend: i32, vline_total: i32) {
    if (mfp.regs[MFP_TACR] & 15) == 8 {
        var dec = false;
        if (mfp.regs[MFP_AER] & 0x10) != 0 {
            if vline == vstart { dec = true; }
        } else {
            if vend >= vline_total {
                if vline == (vline_total - 1) { dec = true; }
            } else {
                if vline == vend { dec = true; }
            }
        }
        if dec {
            mfp.regs[MFP_TADR]--;
            if mfp.regs[MFP_TADR] == 0 {
                mfp.regs[MFP_TADR] = mfp.timer_reload[0];
                mfp_trigger_int(mfp, MFP_IRQ_TIMER_A);
            }
        }
    }
}

// タイマ B HSYNC イベントカウント (走査線ごとに呼び出し: px68k モード 8 準拠)
fn mfp_timer_b_hsync(mfp: X68kMFP&) {
    if (mfp.regs[MFP_TBCR] & 15) == 8 {
        mfp.regs[MFP_TBDR]--;
        if mfp.regs[MFP_TBDR] == 0 {
            mfp.regs[MFP_TBDR] = mfp.timer_reload[1];
            mfp_trigger_int(mfp, MFP_IRQ_TIMER_B);
        }
    }
}

// タイマ進行 & 割込トリガー (プリスケーラカウント: px68k MFP_Timer 準拠)
fn mfp_step_timers(mfp: X68kMFP&, cycles: i32) {
    let timer_ints: i32[4] = [MFP_IRQ_TIMER_A, MFP_IRQ_TIMER_B, MFP_IRQ_TIMER_C, MFP_IRQ_TIMER_D];

    // タイマ A, B, C, D
    for chan in 4 {
        var mode: i32 = 0;
        if chan == 0 { mode = mfp.regs[MFP_TACR]; }
        else if chan == 1 { mode = mfp.regs[MFP_TBCR]; }
        else if chan == 2 { mode = (mfp.regs[MFP_TCDCR] >> 4); }
        else { mode = (mfp.regs[MFP_TCDCR] & 0x0F); }

        if chan == 0 && (mode & 8) != 0 {
            continue; // イベントカウントモードは走査線で実行
        }

        if (mode & 7) != 0 {
            let prescaler = mfp_get_prescaler(mode);
            mfp.timer_tick[chan] += cycles;

            while mfp.timer_tick[chan] >= prescaler {
                mfp.timer_tick[chan] -= prescaler;
                mfp.regs[MFP_TADR + chan]--;
                if mfp.regs[MFP_TADR + chan] == 0 {
                    mfp.regs[MFP_TADR + chan] = mfp.timer_reload[chan];
                    mfp_trigger_int(mfp, timer_ints[chan]);
                }
            }
        }
    }
}

// スキャンコードをリングへ積むだけ。割り込みは mfp_keyboard_int が出す。深さは px68k の 128。
fn mfp_send_key(mfp: X68kMFP&, scan_code: u8) {
    let next = (mfp.key_wp + 1) & 127;
    if next == mfp.key_rp { return; }
    mfp.key_buf[mfp.key_wp] = scan_code;
    mfp.key_wp = next;
}

// px68k Keyboard_Int。前回の UDR 読みが済んでいてバッファに残りがあれば 1 バイト出して irq 3。
fn mfp_keyboard_int(mfp: X68kMFP&) {
    if mfp.key_rp != mfp.key_wp {
        if !mfp.key_int_flag {
            mfp.last_key = mfp.key_buf[mfp.key_rp];
            mfp.key_rp = (mfp.key_rp + 1) & 127;
            mfp.key_int_flag = true;
            mfp_trigger_int(mfp, MFP_IRQ_KEY);
        }
    } else if !mfp.key_int_flag {
        mfp.last_key = 0;
    }
}

// 走査線ごとに呼ぶ。px68k は VLINE_TOTAL/4 ごとに Keyboard_Int。
fn mfp_key_scanline(mfp: X68kMFP&, vline_total: i32) {
    mfp.key_line_div += 1;
    let period = vline_total / 4;
    if period > 0 && mfp.key_line_div > period {
        mfp.key_line_div = 0;
        mfp_keyboard_int(mfp);
    }
}
