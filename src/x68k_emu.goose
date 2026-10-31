// Sharp X68000 エミュレータ本体モジュール in Goose

import std;
import .x68k_bridge;
import .m68k_types;
import .m68k_cpu;
import .m68k_mmu;
import .m68k_exec;
import .x68k_mfp;
import .x68k_ppu;
import .x68k_fdc;
import .x68k_dmac;
import .x68k_sasi;
import .x68k_ram;
import .x68k_rom;
import .x68k_session_types;

// Sound and the floppy host write these when the event happens. The step reads them.
var g_host_dma_vec: i32 = -1;
var g_fdd_media_irq: i32 = 0;

fn x68k_host_irq_bind() {
    c_dma_vec_bind(g_host_dma_vec);
    c_fdd_media_bind(g_fdd_media_irq);
}

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
    hit_break: bool = false
}

fn x68k_emu_bind(emu: X68kEmulator&) -> bool {
    let epoch = c_machine_bind(g_x68k_ram[..], g_iplrom[..], g_cgrom[..], g_sram[..],
        emu.mmu.tvram[..], emu.mmu.gvram[..], emu.mmu.pal[..], emu.mmu.vcreg[..],
        emu.mmu.sprite[..], emu.mmu.bgreg[..], emu.mmu.bgram[..], emu.mmu.bg_chr8[..],
        emu.mmu.bg_chr16[..], emu.ppu.fb[..], g_ram_limit, g_screen_w, g_screen_h,
        g_host_dma_vec, g_fdd_media_irq);
    if epoch == 0 { return false; }
    emu.binding_epoch = epoch;
    return true;
}

fn x68k_emu_active(emu: X68kEmulator&) -> bool {
    return emu.binding_epoch != 0 && emu.binding_epoch == c_machine_epoch();
}

fn x68k_emu_unbind(emu: X68kEmulator&) {
    c_machine_unbind(emu.binding_epoch);
    emu.binding_epoch = 0;
}

fn x68k_emu_init(emu: X68kEmulator&) {
    emu.session = X68kSession {};
    assert(x68k_emu_bind(emu));
    c_sound_init();
    x68k_emu_reset(emu);
    emu.is_paused = false;
}

fn x68k_emu_reset(emu: X68kEmulator&) {
    assert(x68k_emu_active(emu));
    // Machine reset does not allocate resources, reload files or rebind views.
    emu.cpu = M68kCPU {};
    mmu_init(emu.mmu);
    mmu_clear_video(emu.mmu);
    ppu_init(emu.ppu);
    x68k_sram_set_write_enable(0);
    c_machine_reset_devices();
    c_set_screen_mode(768, 512);
    c_clear_framebuffer(0xFF000000);
    c_set_frame_ready(0);

    // リセット時の初期 SSP と PC を IPLROM (0x00FF0000) から取得
    let ssp = mmu_read32(emu.mmu, 0x00FF0000);
    let pc = mmu_read32(emu.mmu, 0x00FF0004);

    emu.cpu.ssp = ssp;
    emu.cpu.a[REG_A7] = ssp;
    emu.cpu.pc = pc;
    emu.cpu.sr = 0x2700;
    emu.cpu.halted = false;
    sasi_reset(emu.mmu.sasi);

    emu.total_frames = 0;
    emu.total_cycles = 0;
    emu.clk_used = 0;
    emu.clock_mhz = c_get_cpu_mhz();
    emu.hit_break = false;
    emu.is_paused = true;
    emu.session.keys = [0; 128];
    emu.session.speed_live = false;
    emu.session.speed_have = false;
}

// 1命令ステップ実行
fn x68k_emu_step(emu: X68kEmulator&) -> i32 {
    assert(x68k_emu_active(emu));
    return x68k_emu_step_core(emu);
}

// The frame loop checks the binding once, outside this instruction hot path.
fn x68k_emu_step_core(emu: X68kEmulator&) -> i32 {
    dmac_pump_sasi(emu.mmu);
    dmac_exec_ch2(emu.mmu);
    let cycles = m68k_step(emu.cpu, emu.mmu);
    emu.total_cycles += cycles as i64;
    emu.mmu.mfp.line_cycles += cycles;

    // MFP タイマ進行 (CPUクロックに関わらず実時間4MHz基準で進める: px68k WinX68k_Exec 準拠)
    let mhz = if emu.clock_mhz > 0 { emu.clock_mhz } else { 10 };
    emu.clk_used += cycles * 10;
    let usedclk = emu.clk_used / mhz;
    emu.clk_used -= usedclk * mhz;
    if usedclk > 0 {
        mfp_step_timers(emu.mmu.mfp, usedclk);
    }

    // MFP 割り込みチェック (Level 6)
    if mfp_has_pending_int(emu.mmu.mfp) {
        let cpu_mask = ((emu.cpu.sr >> 8) & 0x07) as i32;
        if cpu_mask < 6 {
            let vect = mfp_ack_interrupt(emu.mmu.mfp);
            if vect >= 0 {
                m68k_interrupt(emu.cpu, emu.mmu, 6, vect);
            }
        }
    }

    // DMAC 割り込み (Level 3)。ch0–2 は Goose。ch3 はサウンド側が g_host_dma_vec を書く。
    var dma_vec = dmac_peek_irq(emu.mmu.dmac);
    var goose_dma = dma_vec >= 0;
    if !goose_dma {
        dma_vec = g_host_dma_vec;
    }
    if dma_vec >= 0 {
        let cpu_mask = ((emu.cpu.sr >> 8) & 0x07) as i32;
        if cpu_mask < 3 {
            if goose_dma { dmac_ack_irq(emu.mmu.dmac); } else { c_dmac_ack_irq(); }
            m68k_interrupt(emu.cpu, emu.mmu, 3, dma_vec);
        }
    }

    // IOC 割り込みチェック (Level 1)。FDC は bit7 かつ bit2、ベクタはそのまま。
    var took_level1 = false;
    if (emu.mmu.ioc_int_stat & 0x80) != 0 && (emu.mmu.ioc_int_stat & 0x04) != 0 {
        let cpu_mask = ((emu.cpu.sr >> 8) & 0x07) as i32;
        if cpu_mask < 1 {
            let vect = emu.mmu.ioc_int_vect as i32;
            emu.mmu.ioc_int_stat &= 0x7F;
            if vect > 0 {
                m68k_interrupt(emu.cpu, emu.mmu, 1, vect);
                took_level1 = true;
            }
        }
    }
    // SASI。px68k はステータス相に入ったアクセスで bit4 を立て、許可 bit3 のときベクタは +2。
    if !took_level1 && emu.mmu.sasi_irq && (emu.mmu.ioc_int_stat & 8) != 0 {
        let cpu_mask = ((emu.cpu.sr >> 8) & 0x07) as i32;
        if cpu_mask < 1 {
            emu.mmu.sasi_irq = false;
            let vect = (emu.mmu.ioc_int_vect as i32) + 2;
            m68k_interrupt(emu.cpu, emu.mmu, 1, vect);
            took_level1 = true;
        }
    }
    // FDD 挿抜。px68k は bit1 が立っているときだけ要求し、ベクタは +1。
    if !took_level1 && g_fdd_media_irq != 0 {
        let cpu_mask = ((emu.cpu.sr >> 8) & 0x07) as i32;
        if cpu_mask < 1 {
            c_fdd_ack_media_irq();
            let vect = (emu.mmu.ioc_int_vect as i32) + 1;
            m68k_interrupt(emu.cpu, emu.mmu, 1, vect);
        }
    }

    return cycles;
}

// 1フレーム分のエミュレーション実行 (px68k WinX68k_Exec 走査線駆動準拠)
fn x68k_emu_run_frame(emu: X68kEmulator&) {
    assert(x68k_emu_active(emu));
    c_set_current_frame(emu.total_frames as i32);
    // bit4 が立っているのは 31kHz（px68k VID_MODE = MODE_HIGH）。サイクル予算の数値はそのまま。
    let is_31k = (emu.mmu.crtc_regs[0x29] & 0x10) != 0;
    let vsync_base: i32 = if is_31k { 180310 } else { 162707 };
    let mhz = if emu.clock_mhz > 0 { emu.clock_mhz } else { 10 };
    let clk_total = (vsync_base * mhz) / 10;

    var vline_total = ((((emu.mmu.crtc_regs[8] as i32) << 8) | (emu.mmu.crtc_regs[9] as i32)) & 1023);
    if vline_total <= 0 {
        vline_total = if is_31k { 263 } else { 567 };
    }

    // ゲームはフレーム途中でラスタ割り込みラインを書き換える。px68k は毎ライン
    // CRTC_IntLine / VSTART / VEND を読む。先頭で固定すると下側のスプライト更新が走らない。
    var crtc_vstart = ((((emu.mmu.crtc_regs[0x0C] as i32) << 8) | (emu.mmu.crtc_regs[0x0D] as i32)) & 1023);
    var crtc_vend   = ((((emu.mmu.crtc_regs[0x0E] as i32) << 8) | (emu.mmu.crtc_regs[0x0F] as i32)) & 1023);
    var crtc_intline = ((((emu.mmu.crtc_regs[0x12] as i32) << 8) | (emu.mmu.crtc_regs[0x13] as i32)) & 1023);

    let hsync_clk = clk_total / vline_total;
    let htotal = if emu.mmu.crtc_regs[0x01] > 0 { emu.mmu.crtc_regs[0x01] as i32 } else { 137 };
    let hstart = ((emu.mmu.crtc_regs[0x05] as i32) * hsync_clk) / htotal;
    let hend   = ((emu.mmu.crtc_regs[0x07] as i32) * hsync_clk) / htotal;

    emu.mmu.mfp.hsync_clk = hsync_clk;
    emu.mmu.mfp.hsync_start = hstart;
    emu.mmu.mfp.hsync_end = hend;
    emu.mmu.mfp.crtc_intline = crtc_intline;

    ppu_begin_frame(emu.ppu, emu.mmu);

    var vline: i32 = 0;
    var clk_count: i32 = 0;

    while vline < vline_total {
        // 走査線開始時 (hsync = 1)。比較ラインは今の CRTC レジスタ。
        crtc_vstart = ((((emu.mmu.crtc_regs[0x0C] as i32) << 8) | (emu.mmu.crtc_regs[0x0D] as i32)) & 1023);
        crtc_vend = ((((emu.mmu.crtc_regs[0x0E] as i32) << 8) | (emu.mmu.crtc_regs[0x0F] as i32)) & 1023);
        crtc_intline = ((((emu.mmu.crtc_regs[0x12] as i32) << 8) | (emu.mmu.crtc_regs[0x13] as i32)) & 1023);
        emu.mmu.mfp.crtc_intline = crtc_intline;
        emu.mmu.mfp.cur_vline = vline;
        emu.mmu.mfp.line_cycles = 0;
        emu.mmu.mfp.in_vdisp = (vline >= crtc_vstart && vline < crtc_vend);

        // HSYNC 割り込み & Timer B HSYNC イベントカウント
        mfp_trigger_int(emu.mmu.mfp, 0);
        mfp_timer_b_hsync(emu.mmu.mfp);

        // CRTC ラスタ割り込み (IERA bit 1 / AER bit 6 == 0)
        if (emu.mmu.mfp.regs[MFP_AER] & 0x40) == 0 && vline == crtc_intline {
            mfp_trigger_int(emu.mmu.mfp, 1);
        }

        // V-DISP 割り込み (AER bit 4)
        if (emu.mmu.mfp.regs[MFP_AER] & 0x10) != 0 {
            if vline == crtc_vstart {
                mfp_trigger_int(emu.mmu.mfp, 9);
            }
        } else {
            if crtc_vend >= vline_total {
                if vline == (crtc_vend - vline_total) {
                    mfp_trigger_int(emu.mmu.mfp, 9);
                }
            } else {
                if vline == (vline_total - 1) {
                    mfp_trigger_int(emu.mmu.mfp, 9);
                }
            }
        }

        // 走査線内のサイクル実行
        let clk_next = ((clk_total as i64) * ((vline + 1) as i64) / (vline_total as i64)) as i32;
        while clk_count < clk_next {
            if emu.break_armed && (emu.cpu.pc & 0x00FFFFFF) == (emu.break_pc & 0x00FFFFFF) {
                emu.hit_break = true;
                return;
            }
            let cycles = x68k_emu_step_core(emu);
            clk_count += cycles;
        }

        // 走査線終了時。CPU がこのラインで書いた比較ラインを使う。
        crtc_vstart = ((((emu.mmu.crtc_regs[0x0C] as i32) << 8) | (emu.mmu.crtc_regs[0x0D] as i32)) & 1023);
        crtc_vend = ((((emu.mmu.crtc_regs[0x0E] as i32) << 8) | (emu.mmu.crtc_regs[0x0F] as i32)) & 1023);
        crtc_intline = ((((emu.mmu.crtc_regs[0x12] as i32) << 8) | (emu.mmu.crtc_regs[0x13] as i32)) & 1023);
        emu.mmu.mfp.crtc_intline = crtc_intline;
        mfp_timer_a(emu.mmu.mfp, vline, crtc_vstart, crtc_vend, vline_total);
        if (emu.mmu.mfp.regs[MFP_AER] & 0x40) != 0 && vline == crtc_intline {
            mfp_trigger_int(emu.mmu.mfp, 1);
        }

        // 音源タイマーステップ (clk_line = vsync_base / vline_total)
        let clk_line = vsync_base / vline_total;
        dmac_sound_push(emu.mmu.dmac);
        c_sound_scanline_timer(clk_line as u32);
        dmac_sound_pull(emu.mmu.dmac);
        if c_sound_poll_irq() != 0 {
            mfp_trigger_int(emu.mmu.mfp, 12);
        }

        // px68k WinDraw_DrawLine: sprites from the registers at the end of this scanline
        if vline >= crtc_vstart && vline < crtc_vend {
            let mode29 = emu.mmu.crtc_regs[0x29];
            let vstep = if (mode29 & 0x14) == 0x10 { 1 } else if (mode29 & 0x14) == 0x04 { 4 } else { 2 };
            if vstep == 1 {
                if (vline & 1) != 0 {
                    let sy = ((vline - crtc_vstart) * vstep) / 2;
                    ppu_draw_sprite_line(emu.ppu, emu.mmu, sy as i32);
                }
            } else if vstep == 4 {
                let sy = ((vline - crtc_vstart) * vstep) / 2;
                ppu_draw_sprite_line(emu.ppu, emu.mmu, sy as i32);
                ppu_draw_sprite_line(emu.ppu, emu.mmu, (sy + 1) as i32);
            } else {
                let sy = ((vline - crtc_vstart) * vstep) / 2;
                ppu_draw_sprite_line(emu.ppu, emu.mmu, sy as i32);
            }
        }

        mfp_key_scanline(emu.mmu.mfp, vline_total);
        vline++;
    }

    // CRTC 高速クリア (Fast Clear) 処理
    if (emu.mmu.crtc_mode & 2) != 0 {
        if emu.mmu.crtc_fast_clr > 0 {
            emu.mmu.crtc_fast_clr--;
            if emu.mmu.crtc_fast_clr == 0 {
                emu.mmu.crtc_mode &= 0xFD;
            }
        } else {
            // 確認メモ: ビットが立っているとき 1、落ちているとき 2。入れ替えない。
            emu.mmu.crtc_fast_clr = if is_31k { 1 } else { 2 };
            let sx = (((emu.mmu.crtc_regs[0x18] as u32) << 8) | (emu.mmu.crtc_regs[0x19] as u32)) & 511;
            let sy = (((emu.mmu.crtc_regs[0x1A] as u32) << 8) | (emu.mmu.crtc_regs[0x1B] as u32)) & 511;
            mmu_gvram_fast_clear(emu.mmu, emu.mmu.crtc_regs[0x2B], emu.mmu.crtc_regs[0x29], sx, sy);
        }
    }

    // 画面描画
    ppu_render_frame(emu.ppu, emu.mmu);

    // 44.1kHz。31kHz 画面は 55.46Hz（5546）、15kHz 画面は 61.46Hz（6146）。
    let samples: i32 = if is_31k {
        let s_cur = ((emu.total_frames + 1) * 4410000) / 5546;
        let s_prev = (emu.total_frames * 4410000) / 5546;
        (s_cur - s_prev) as i32
    } else {
        let s_cur = ((emu.total_frames + 1) * 4410000) / 6146;
        let s_prev = (emu.total_frames * 4410000) / 6146;
        (s_cur - s_prev) as i32
    };
    dmac_sound_push(emu.mmu.dmac);
    c_sound_frame_update(samples);
    dmac_sound_pull(emu.mmu.dmac);

    let media_en: i32 = if (emu.mmu.ioc_int_stat & 2) != 0 { 1 } else { 0 };
    c_fdd_media_tick(media_en);

    emu.total_frames++;
}
