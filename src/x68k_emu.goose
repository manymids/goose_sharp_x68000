// エミュレータ本体: 機械の構造体、リセット、フレームの進行

import .x68k_bridge;
import .m68k_types;
import .m68k_cpu;
import .m68k_mmu;
import .m68k_exec;
import .x68k_mfp;
import .x68k_ppu;
import .x68k_fdc;
import .x68k_dmac;
import .x68k_dma_bus;
import .x68k_sasi;
import .x68k_disk;
import .x68k_adpcm;
import .x68k_opm;
import .x68k_output;
import .x68k_ram;
import .x68k_rom;
import .x68k_session_types;
namespace emu;


struct X68kEmulator {
    session: X68kSession = X68kSession {},
    binding_epoch: u64 = 0,
    cpu: M68kCPU = M68kCPU {},
    mmu: M68kMMU = M68kMMU {},
    ppu: X68kPPU = X68kPPU {},
    total_frames: i64 = 0,
    total_cycles: i64 = 0,
    is_paused: bool = false,
    clock_mhz: i32 = 10,
    clk_used: i32 = 0,
    break_armed: bool = false,
    break_pc: u32 = 0,
    hit_break: bool = false,
    // 直前のフレームで作った音 (右、左の順に交互)。ホストへは session が渡す
    audio: i16[AUDIO_FRAME_MAX * 2] = [0; AUDIO_FRAME_MAX * 2],
    audio_samples: i32 = 0,
}
type ::X68kEmulator = emu::X68kEmulator;

fn bind(emu: X68kEmulator&) -> bool {
    let epoch = c_machine_bind(g_x68k_ram[..], g_iplrom[..], g_cgrom[..], g_sram[..], emu.ppu.fb[..], g_ram_limit);
    if epoch == 0 { return false; }
    emu.binding_epoch = epoch;
    return true;
}

fn active(emu: X68kEmulator&) -> bool {
    return emu.binding_epoch != 0 && emu.binding_epoch == c_machine_epoch();
}

fn init(emu: X68kEmulator&) {
    emu.session = X68kSession {};
    assert(emu.bind());
    emu.mmu.fm.power_on();
    emu.reset();
    emu.is_paused = false;
}

fn reset(emu: X68kEmulator&) {
    assert(emu.active());
    // 機械のリセットは資源を確保せず、ファイルを読み直さず、ビューも結び直さない。
    emu.cpu = M68kCPU {};
    emu.mmu.init();
    x68k_sram_set_write_enable(0);
    c_machine_reset_devices();
    emu.mmu.fm.machine_reset();
    disk::machine_reset();
    emu.ppu.screen_w = 768;
    emu.ppu.screen_h = 512;
    emu.ppu.clear(0xFF000000);
    emu.ppu.frame_ready = false;
    emu.present();

    // リセット時の初期 SSP と PC を IPLROM (0x00FF0000) から取得
    let ssp = emu.mmu.read32(0x00FF0000);
    let pc = emu.mmu.read32(0x00FF0004);

    emu.cpu.ssp = ssp;
    emu.cpu.a[REG_A7] = ssp;
    emu.cpu.pc = pc;
    emu.cpu.sr = 0x2700;
    emu.cpu.halted = false;
    emu.mmu.sasi.reset();

    emu.total_frames = 0;
    emu.total_cycles = 0;
    emu.clk_used = 0;
    emu.clock_mhz = c_get_cpu_mhz();
    emu.hit_break = false;
    emu.is_paused = true;
    emu.session.keys = [false; 128];
    emu.session.speed_live = false;
    emu.session.speed_have = false;
}

// 1命令ステップ実行
fn step(emu: X68kEmulator&) -> i32 {
    assert(emu.active());
    return emu.step_core();
}

// 結び付けの確認はフレームのループで 1 回だけ行い、この命令ごとの経路ではしない。
fn step_core(emu: X68kEmulator&) -> i32 {
    // DMA の ch1 (SASI) と ch2 は、動作中 (CSR の ACT) のときだけ進める。どちらも止まっていれば
    // 何もしないので、1 命令ごとの呼び出しを省く。
    if ((emu.mmu.dmac.ch[1].csr | emu.mmu.dmac.ch[2].csr) & 0x08) != 0 {
        dmabus::pump_sasi(emu.mmu);
        dmabus::exec_ch2(emu.mmu);
    }
    let cycles = m68k::step(emu.cpu, emu.mmu);
    emu.total_cycles += cycles;
    emu.mmu.mfp.line_cycles += cycles;

    // MFP タイマ進行 (CPUクロックに関わらず実時間4MHz基準で進める: px68k WinX68k_Exec 準拠)
    let mhz = if emu.clock_mhz > 0 { emu.clock_mhz } else { 10 };
    emu.clk_used += cycles * 10;
    let usedclk = emu.clk_used / mhz;
    emu.clk_used -= usedclk * mhz;
    if usedclk > 0 {
        emu.mmu.mfp.step_timers(usedclk);
        emu.mmu.rtc.now += usedclk; // 0.1 us
    }

    if interrupt_waiting(emu) { take_interrupt(emu); }
    return cycles;
}

// 割り込みの要求がどこかに出ているか。ほとんどの命令ではどれも出ていないので、
// 下の take_interrupt の個々の判定を省ける。
fn interrupt_waiting(emu: X68kEmulator&) -> bool {
    return emu.mmu.mfp.has_pending_int() || emu.mmu.dmac.int_pending || emu.mmu.dmac.adpcm_vec >= 0
        || (emu.mmu.ioc_int_stat & 0x80) != 0 || emu.mmu.sasi_irq || g_disk.media_pending;
}

// 要求の出ている割り込みを、CPU のマスクが許せば受け付ける。
fn take_interrupt(emu: X68kEmulator&) {
    // MFP 割り込みチェック (Level 6)
    if emu.mmu.mfp.has_pending_int() {
        if emu.cpu.int_mask() < 6 {
            let vect = emu.mmu.mfp.ack_interrupt();
            if vect >= 0 {
                m68k::interrupt(emu.cpu, emu.mmu, 6, vect);
            }
        }
    }

    // DMAC 割り込み (Level 3)。ch0–2 が先で、なければ ch3 (ADPCM)。
    var dma_vec = emu.mmu.dmac.peek_irq();
    var goose_dma = dma_vec >= 0;
    if !goose_dma {
        dma_vec = emu.mmu.dmac.adpcm_vec;
    }
    if dma_vec >= 0 {
        if emu.cpu.int_mask() < 3 {
            if goose_dma { emu.mmu.dmac.ack_irq(); } else { emu.mmu.dmac.adpcm_vec = -1; }
            m68k::interrupt(emu.cpu, emu.mmu, 3, dma_vec);
        }
    }

    // IOC 割り込みチェック (Level 1)。FDC は bit7 かつ bit2、ベクタはそのまま。
    var took_level1 = false;
    if (emu.mmu.ioc_int_stat & 0x80) != 0 && (emu.mmu.ioc_int_stat & 0x04) != 0 {
        if emu.cpu.int_mask() < 1 {
            let vect: i32 = emu.mmu.ioc_int_vect;
            emu.mmu.ioc_int_stat &= 0x7F;
            if vect > 0 {
                m68k::interrupt(emu.cpu, emu.mmu, 1, vect);
                took_level1 = true;
            }
        }
    }
    // SASI。px68k はステータス相に入ったアクセスで bit4 を立て、許可 bit3 のときベクタは +2。
    if !took_level1 && emu.mmu.sasi_irq && (emu.mmu.ioc_int_stat & 8) != 0 {
        if emu.cpu.int_mask() < 1 {
            emu.mmu.sasi_irq = false;
            let vect = (emu.mmu.ioc_int_vect as i32) + 2;
            m68k::interrupt(emu.cpu, emu.mmu, 1, vect);
            took_level1 = true;
        }
    }
    // FDD 挿抜。px68k は bit1 が立っているときだけ要求し、ベクタは +1。
    if !took_level1 && g_disk.media_pending {
        if emu.cpu.int_mask() < 1 {
            g_disk.media_pending = false;
            let vect = (emu.mmu.ioc_int_vect as i32) + 1;
            m68k::interrupt(emu.cpu, emu.mmu, 1, vect);
        }
    }
}

// 1 フレームのライン数: R04 + 1。
fn frame_lines(mmu: M68kMMU&) -> i32 {
    let v = (mmu.crtc_word(CRTC_VTOTAL) & 1023) + 1;
    return if v > 1 { v } else { 568 };
}

// CRTC から求めた 1 フレームの長さ (0.1 us = 10 MHz のクロック単位、XEiJ と同じ求め方): HRL ($E8E007 bit 1) と
// R20 (bit 4 は高解像度、bit 1-0 は水平) が選ぶ発振器と分周比に、8 ドット、R00 + 1 桁、
// R04 + 1 ラインを掛ける。
fn frame_cycles10(mmu: M68kMMU&) -> i64 {
    let oscs: i64[3] = [38863632, 69551900, 50349800];
    let osc_of: i32[16] = [0, 0, 0, 0, 1, 1, 1, 2, 0, 0, 0, 0, 1, 1, 1, 2];
    let div_of: i64[16] = [8, 4, 8, 8, 6, 3, 2, 2, 8, 4, 8, 8, 8, 4, 2, 2];
    let r20: i32 = mmu.crtc_regs[0x29];
    let hrl: i32 = (mmu.sysport_keyctrl >> 1) & 1;
    let k = (hrl << 3) | ((r20 >> 2) & 4) | (r20 & 3);
    let columns = (mmu.crtc_regs[0x01] as i64) + 1;
    let lines: i64 = frame_lines(mmu);
    if columns < 2 { return if (r20 & 0x10) != 0 { 180310 } else { 162707 }; }
    return 8 * div_of[k] * columns * lines * 10000000 / oscs[osc_of[k]];
}

// CRTC が決める 1 秒あたりのフレーム数 (四捨五入)。768x512 の 31 kHz で 55、15 kHz で 61。
fn nominal_fps(mmu: M68kMMU&) -> i32 {
    let cycles = frame_cycles10(mmu);
    return ((10000000 + cycles / 2) / cycles) as i32;
}

// 走査線の始まり (水平同期の立ち上がり)。この時点の CRTC の設定で割り込みを起こす。
// ゲームはフレームの途中でラスタ割り込みのラインを書き換えるので、px68k と同じく毎ライン読む。
fn line_start(emu: X68kEmulator&, vline: i32, vline_total: i32) {
    let mfp .= emu.mmu.mfp;
    let crtc_vstart = emu.mmu.crtc_word(CRTC_VSTART) & 1023;
    let crtc_vend = emu.mmu.crtc_word(CRTC_VEND) & 1023;
    let crtc_intline = emu.mmu.crtc_word(CRTC_RASTER) & 1023;
    mfp.crtc_intline = crtc_intline;
    mfp.cur_vline = vline;
    mfp.line_cycles = 0;
    mfp.in_vdisp = (vline >= crtc_vstart && vline < crtc_vend);

    // HSYNC 割り込み & Timer B HSYNC イベントカウント
    mfp.trigger_int(MFP_IRQ_HSYNC);
    mfp.timer_b_hsync();

    // CRTC ラスタ割り込み (IERA bit 1 / AER bit 6 == 0)
    if (mfp.regs[MFP_AER] & 0x40) == 0 && vline == crtc_intline {
        mfp.trigger_int(MFP_IRQ_RASTER);
    }

    // V-DISP 割り込み (AER bit 4)。立ち上がりなら表示の始まり、立ち下がりなら表示の終わりで起こす。
    let vdisp_line = if (mfp.regs[MFP_AER] & 0x10) != 0 { crtc_vstart }
        else if crtc_vend >= vline_total { crtc_vend - vline_total }
        else { vline_total - 1 };
    if vline == vdisp_line { mfp.trigger_int(MFP_IRQ_VDISP); }
}

// 表示期間の走査線 1 本を描く。px68k WinDraw_DrawLine と同じく、ラインの終わりのレジスタで描く。
fn draw_scanline(emu: X68kEmulator&, vline: i32, crtc_vstart: i32) {
    let mode29 = emu.mmu.crtc_regs[0x29];
    let vstep: i32 = if (mode29 & 0x14) == 0x10 { 1 } else if (mode29 & 0x14) == 0x04 { 4 } else { 2 };
    let sy = ((vline - crtc_vstart) * vstep) / 2;
    if vstep == 1 {
        // 走査線 2 本で画面の 1 行
        if (vline & 1) != 0 { emu.ppu.draw_line(emu.mmu, sy); }
    } else if vstep == 4 {
        // 走査線 1 本で画面の 2 行
        emu.ppu.draw_line(emu.mmu, sy);
        emu.ppu.draw_line(emu.mmu, sy + 1);
    } else {
        emu.ppu.draw_line(emu.mmu, sy);
    }
}

// 走査線の終わり。CPU がこのラインで書いた設定を使う。
fn line_end(emu: X68kEmulator&, vline: i32, vline_total: i32, clk_line: i32) {
    let crtc_vstart = emu.mmu.crtc_word(CRTC_VSTART) & 1023;
    let crtc_vend = emu.mmu.crtc_word(CRTC_VEND) & 1023;
    let crtc_intline = emu.mmu.crtc_word(CRTC_RASTER) & 1023;
    emu.mmu.mfp.crtc_intline = crtc_intline;
    emu.mmu.mfp.timer_a(vline, crtc_vstart, crtc_vend, vline_total);
    if (emu.mmu.mfp.regs[MFP_AER] & 0x40) != 0 && vline == crtc_intline {
        emu.mmu.mfp.trigger_int(MFP_IRQ_RASTER);
    }

    // 音源を 1 ライン分進める。ADPCM は、たまっているデータが尽きる頃合いで DMA に次を運ばせる。
    for _ in emu.mmu.adpcm.pre_update(clk_line) { dmabus::exec_adpcm(emu.mmu); }
    emu.mmu.fm.count2(clk_line as u32);
    if emu.mmu.fm.irq {
        emu.mmu.fm.irq = false;
        emu.mmu.mfp.trigger_int(MFP_IRQ_OPM);
    }

    if vline >= crtc_vstart && vline < crtc_vend { draw_scanline(emu, vline, crtc_vstart); }
    emu.mmu.mfp.key_scanline(vline_total);
}

// CRTC の高速クリア。指示のあったフレームの終わりに GVRAM を消し、数フレーム後にビットを落とす。
fn fast_clear(emu: X68kEmulator&, is_31k: bool) {
    if (emu.mmu.crtc_mode & 2) == 0 { return; }
    if emu.mmu.crtc_fast_clr > 0 {
        emu.mmu.crtc_fast_clr--;
        if emu.mmu.crtc_fast_clr == 0 {
            emu.mmu.crtc_mode &= 0xFD;
        }
    } else {
        // 確認メモ: ビットが立っているとき 1、落ちているとき 2。入れ替えない。
        emu.mmu.crtc_fast_clr = if is_31k { 1 } else { 2 };
        let sx = (emu.mmu.crtc_word(CRTC_GRP_X) & 511) as u32;
        let sy = (emu.mmu.crtc_word(CRTC_GRP_Y) & 511) as u32;
        emu.mmu.gvram_fast_clear(emu.mmu.crtc_regs[0x2B], emu.mmu.crtc_regs[0x29], sx, sy);
    }
}

let ::AUDIO_FRAME_MAX = 2048; // 1 フレームに作るサンプル数の上限

// このフレームで合成する音のサンプル数 (44.1 kHz)。31 kHz の画面は 55.46 Hz、15 kHz の画面は 61.46 Hz。
// 端数を持ち越すので、フレームごとに 1 サンプル違うことがある。
fn frame_samples(total_frames: i64, is_31k: bool) -> i32 {
    let rate: i64 = if is_31k { 5546 } else { 6146 };
    return (((total_frames + 1) * 4410000) / rate - (total_frames * 4410000) / rate) as i32;
}

// 1 フレームぶんの音を作って emu.audio に置く。ADPCM を取り出して、その上に OPM を足し込む。
fn mix_audio(emu: X68kEmulator&, samples: i32) {
    emu.audio_samples = 0;
    if samples <= 0 { return; }
    let buf .= emu.audio;
    let count = min(samples, AUDIO_FRAME_MAX);
    for i in count {
        // データが尽きていて、続きのブロックが予約されていなければ、DMA に運ばせる
        if emu.mmu.adpcm.empty() && (emu.mmu.dmac.ch[3].ccr & 0x40) == 0 { dmabus::exec_adpcm(emu.mmu); }
        let r, l = emu.mmu.adpcm.next_sample();
        buf[i * 2] = r;
        buf[i * 2 + 1] = l;
    }
    emu.mmu.adpcm.note_backlog();
    emu.mmu.fm.mix(buf[..count * 2]);
    emu.audio_samples = count;
}

// 本体の画面と音をホスト (ウィンドウ、音声出力、スクリーンショット) へ渡す。
// run_frame はホストに触らないので、写しの機械を別スレッドで進めても本体に影響しない。
fn present(emu: X68kEmulator&) {
    c_set_screen_mode(emu.ppu.screen_w, emu.ppu.screen_h);
    if emu.audio_samples > 0 {
        let frame = emu.audio[..emu.audio_samples * 2];
        output::capture_push(frame);
        c_audio_output(frame);
    }
    emu.audio_samples = 0;
}

// 1 フレーム分進める (px68k WinX68k_Exec と同じ走査線単位の進め方)。
// ホストの状態には触らない (画面の大きさ、フレームバッファ、音は emu の中に置くだけ)。
// ブレークポイントに当たったら、フレームの途中でも hit_break を立てて戻る。
fn run_frame(emu: X68kEmulator&) {
    assert(emu.active());
    // bit4 が立っているのは 31kHz（px68k VID_MODE = MODE_HIGH）。サイクル予算の数値はそのまま。
    let is_31k = (emu.mmu.crtc_regs[0x29] & 0x10) != 0;
    // 1 フレームの長さ (0.1 us 単位 = 10 MHz のクロック数)
    let frame_len10: i32 = frame_cycles10(emu.mmu) as i32;
    let mhz = if emu.clock_mhz > 0 { emu.clock_mhz } else { 10 };
    let clk_total = (frame_len10 * mhz) / 10;
    let vline_total = frame_lines(emu.mmu);

    let hsync_clk = clk_total / vline_total;
    let htotal = if emu.mmu.crtc_regs[0x01] > 0 { emu.mmu.crtc_regs[0x01] as i32 } else { 137 };
    // GPIP7 は水平同期パルスの間だけ high (XEiJ): R00 + 1 桁のうち R01 + 1 桁。
    emu.mmu.mfp.hsync_clk = hsync_clk;
    emu.mmu.mfp.hsync_start = (((emu.mmu.crtc_regs[0x03] as i32) + 1) * hsync_clk) / (htotal + 1);
    emu.mmu.mfp.hsync_end = hsync_clk;

    emu.ppu.begin_frame(emu.mmu);

    var clk_count: i32 = 0;
    for vline: i32 in vline_total {
        line_start(emu, vline, vline_total);

        // この走査線のぶんだけ CPU を進める
        let clk_next = ((clk_total as i64) * ((vline + 1)) / (vline_total)) as i32;
        while clk_count < clk_next {
            if emu.break_armed && (emu.cpu.pc & ADDR_MASK) == (emu.break_pc & ADDR_MASK) {
                emu.hit_break = true;
                return;
            }
            clk_count += emu.step_core();
        }

        line_end(emu, vline, vline_total, frame_len10 / vline_total);
    }

    fast_clear(emu, is_31k);
    // フレーム末の CRTC 設定を画面サイズへ反映
    emu.ppu.apply_screen(emu.mmu);

    mix_audio(emu, frame_samples(emu.total_frames, is_31k));

    disk::media_tick((emu.mmu.ioc_int_stat & 2) != 0);

    emu.total_frames++;
}
