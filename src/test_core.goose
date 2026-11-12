// コアの単体テスト。BIOS もディスクイメージも要らない。
//   goose build src/test_core.goose -o test_core.exe && ./test_core.exe
// 失敗があれば内容を出して終了コード 1 で終わる。

import std;
import .m68k_types;
import .m68k_cpu;
import .m68k_mmu;
import .m68k_exec;
import .x68k_ram;
import .x68k_input;
import .x68k_fdc;
import .x68k_dmac;
import .x68k_rtc;

var g_checks = 0;
var g_failures = 0;
var g_cpu = M68kCPU {};
var g_mmu = M68kMMU {};

fn check(name: const u8[:], ok: bool) {
    g_checks++;
    if !ok {
        g_failures++;
        print("FAIL: ", name);
    }
}

fn check_eq(name: const u8[:], got: u32, want: u32) {
    g_checks++;
    if got != want {
        g_failures++;
        var line: u8[>..] = [];
        format(line, "FAIL: ", name, ": got 0x");
        format_uint(line, got, 16, 8, '0');
        format(line, ", want 0x");
        format_uint(line, want, 16, 8, '0');
        print(line);
    }
}

// CCR の 5 ビットを "XNZVC" の順の 0/1 で比べる。
fn check_ccr(name: const u8[:], want: u16) {
    check_eq(name, g_cpu.sr & 0x1F, want);
}

// ---------------------------------------------------------------- CPU を RAM 上のプログラムで動かす

let CODE = 0x1000;

fn fresh() {
    g_cpu = M68kCPU {};
    mmu_init(g_mmu);
    g_mmu.reset_overlay = false;
    g_cpu.a[REG_A7] = 0x8000;
    g_cpu.ssp = 0x8000;
    g_cpu.pc = CODE;
}

fn poke(addr: u32, words: u16[:]) {
    for i in words.len {
        x68k_ram_write16((addr + (i as u32) * 2) as i32, words[i]);
    }
}

// CODE にプログラムを置き、steps 命令だけ実行する。
fn run(words: u16[:], steps: i32) {
    fresh();
    poke(CODE, words);
    for _ in steps { m68k_step(g_cpu, g_mmu); }
}

fn test_flag_helpers() {
    var cpu = M68kCPU {};
    cpu.sr = 0;
    cpu_flags_add(cpu, 1, 0x01, 0x7F, 0x80);
    check_eq("add8 0x7F+1 sets N V", cpu.sr & 0x1F, SR_N | SR_V);
    cpu_flags_add(cpu, 2, 0x0001, 0xFFFF, 0x10000);
    check_eq("add16 0xFFFF+1 sets X Z C", cpu.sr & 0x1F, SR_X | SR_Z | SR_C);
    cpu_flags_add(cpu, 4, 0x80000000, 0x80000000, 0);
    check_eq("add32 overflow sets X Z V C", cpu.sr & 0x1F, SR_X | SR_Z | SR_V | SR_C);

    cpu.sr = SR_X;
    cpu_flags_sub(cpu, 1, 0x01, 0x00, 0xFF, false);
    check_eq("cmp8 0-1 keeps X, sets N C", cpu.sr & 0x1F, SR_X | SR_N | SR_C);
    cpu.sr = SR_X;
    cpu_flags_sub(cpu, 4, 5, 5, 0, true);
    check_eq("sub32 equal clears X, sets Z", cpu.sr & 0x1F, SR_Z);
    cpu_flags_sub(cpu, 2, 0x0001, 0x8000, 0x7FFF, true);
    check_eq("sub16 0x8000-1 sets V", cpu.sr & 0x1F, SR_V);

    cpu.sr = SR_Z;
    cpu_flags_addx(cpu, 4, 0, 0, 0);
    check_eq("addx zero result keeps Z", cpu.sr & 0x1F, SR_Z);
    cpu_flags_addx(cpu, 4, 0, 1, 1);
    check_eq("addx non-zero result clears Z", cpu.sr & 0x1F, 0);
    cpu.sr = 0;
    cpu_flags_subx(cpu, 1, 1, 0, 0xFF);
    check_eq("subx8 borrow sets X N C", cpu.sr & 0x1F, SR_X | SR_N | SR_C);

    cpu.sr = SR_C | SR_X;
    cpu_set_nz(cpu, 2, 0x8000);
    check_eq("set_nz clears C, keeps X", cpu.sr & 0x1F, SR_X | SR_N);
    cpu.sr = SR_C;
    cpu_set_nz_only(cpu, 1, 0x100);
    check_eq("set_nz_only looks at the low byte, keeps C", cpu.sr & 0x1F, SR_Z | SR_C);
}

fn test_conditions() {
    var cpu = M68kCPU {};
    cpu.sr = 0;
    check("HI with C=0 Z=0", cpu_check_condition(cpu, 2));
    check("GE with N=V=0", cpu_check_condition(cpu, 12));
    check("GT with N=V=0 Z=0", cpu_check_condition(cpu, 14));
    cpu.sr = SR_Z;
    check("EQ with Z", cpu_check_condition(cpu, 7));
    check("LS with Z", cpu_check_condition(cpu, 3));
    check("LE with Z", cpu_check_condition(cpu, 15));
    check("not GT with Z", !cpu_check_condition(cpu, 14));
    cpu.sr = SR_N;
    check("LT with N!=V", cpu_check_condition(cpu, 13));
    check("MI with N", cpu_check_condition(cpu, 11));
    cpu.sr = SR_N | SR_V;
    check("GE with N=V=1", cpu_check_condition(cpu, 12));
    cpu.sr = SR_C;
    check("CS with C", cpu_check_condition(cpu, 5));
    check("not HI with C", !cpu_check_condition(cpu, 2));
    check("T", cpu_check_condition(cpu, 0));
    check("F", !cpu_check_condition(cpu, 1));
}

fn test_arithmetic() {
    // MOVEQ #-1,D0 / MOVEQ #1,D1 / ADD.L D1,D0
    run([0x70FF, 0x7201, 0xD081], 1);
    check_eq("MOVEQ #-1", g_cpu.d[0], 0xFFFFFFFF);
    check_ccr("MOVEQ #-1 sets N", SR_N);
    run([0x70FF, 0x7201, 0xD081], 3);
    check_eq("ADD.L wraps to 0", g_cpu.d[0], 0);
    check_ccr("ADD.L carry out", SR_X | SR_Z | SR_C);

    // MOVE.L #$1234567F,D0 / MOVEQ #1,D1 / ADD.B D1,D0
    run([0x203C, 0x1234, 0x567F, 0x7201, 0xD001], 3);
    check_eq("ADD.B changes the low byte only", g_cpu.d[0], 0x12345680);
    check_ccr("ADD.B 0x7F+1", SR_N | SR_V);

    // MOVE.L #$00010000,D0 / MOVEQ #1,D1 / SUB.W D1,D0
    run([0x203C, 0x0001, 0x0000, 0x7201, 0x9041], 3);
    check_eq("SUB.W borrows within the low word", g_cpu.d[0], 0x0001FFFF);
    check_ccr("SUB.W 0-1", SR_X | SR_N | SR_C);

    // MOVEQ #5,D0 / MOVEQ #5,D1 / CMP.L D1,D0 / BEQ.S +2 / MOVEQ #1,D2 / NOP
    run([0x7005, 0x7205, 0xB081, 0x6702, 0x7401, 0x4E71], 5);
    check_ccr("CMP.L equal", SR_Z);
    check_eq("BEQ skips the next instruction", g_cpu.d[2], 0);
    check_eq("BEQ target", g_cpu.pc, CODE + 12);

    // X を立ててから ADDX.L D1,D0: 0 + 0 + X
    // MOVEQ #-1,D0 / MOVEQ #1,D1 / ADD.L D1,D0 / MOVEQ #0,D0 / MOVEQ #0,D1 / ADDX.L D1,D0
    run([0x70FF, 0x7201, 0xD081, 0x7000, 0x7200, 0xD181], 6);
    check_eq("ADDX adds X", g_cpu.d[0], 1);
    check_ccr("ADDX non-zero clears Z", 0);
    // MOVEQ #0,D0 / MOVEQ #0,D1 / ADDX.L D1,D0 (X = 0): Z は MOVEQ が立てたまま
    run([0x7000, 0x7200, 0xD181], 3);
    check_ccr("ADDX zero keeps Z", SR_Z);

    // MOVE.L #$0000FFFF,D0 / MOVE.L #$0000FFFF,D1 / MULU D1,D0
    run([0x203C, 0x0000, 0xFFFF, 0x223C, 0x0000, 0xFFFF, 0xC0C1], 3);
    check_eq("MULU 0xFFFF*0xFFFF", g_cpu.d[0], 0xFFFE0001);
    // MOVE.L #100000,D0 / MOVEQ #7,D1 / DIVU D1,D0
    run([0x203C, 0x0001, 0x86A0, 0x7207, 0x80C1], 3);
    check_eq("DIVU remainder:quotient", g_cpu.d[0], 0x000537CD);

    // MOVEQ #$19,D0 / MOVEQ #$28,D1 / ABCD D1,D0
    run([0x7019, 0x7228, 0xC101], 3);
    check_eq("ABCD 19+28", g_cpu.d[0] & 0xFF, 0x47);
}

fn test_shifts_and_unary() {
    // MOVE.L #$80000001,D0 / LSL.L #1,D0
    run([0x203C, 0x8000, 0x0001, 0xE388], 2);
    check_eq("LSL.L #1", g_cpu.d[0], 0x00000002);
    check_ccr("LSL.L shifts out into X and C", SR_X | SR_C);
    // MOVE.W #$8001,D0 / ASR.W #1,D0
    run([0x303C, 0x8001, 0xE240], 2);
    check_eq("ASR.W keeps the sign", g_cpu.d[0] & 0xFFFF, 0xC000);
    check_ccr("ASR.W", SR_X | SR_N | SR_C);
    // MOVE.W #$0081,D0 / ROL.B #1,D0
    run([0x303C, 0x0081, 0xE318], 2);
    check_eq("ROL.B", g_cpu.d[0] & 0xFF, 0x03);
    check_ccr("ROL.B sets C, leaves X", SR_C);

    // MOVE.L #$12345678,D0 / SWAP D0
    run([0x203C, 0x1234, 0x5678, 0x4840], 2);
    check_eq("SWAP", g_cpu.d[0], 0x56781234);
    // MOVE.W #$00FF,D0 / EXT.W D0
    run([0x303C, 0x00FF, 0x4880], 2);
    check_eq("EXT.W", g_cpu.d[0] & 0xFFFF, 0xFFFF);
    // MOVEQ #1,D0 / NEG.L D0
    run([0x7001, 0x4480], 2);
    check_eq("NEG.L", g_cpu.d[0], 0xFFFFFFFF);
    check_ccr("NEG.L of non-zero", SR_X | SR_N | SR_C);
    // MOVEQ #$0F,D0 / NOT.B D0
    run([0x700F, 0x4600], 2);
    check_eq("NOT.B", g_cpu.d[0], 0x000000F0);
    // MOVEQ #-1,D0 / CLR.W D0
    run([0x70FF, 0x4240], 2);
    check_eq("CLR.W", g_cpu.d[0], 0xFFFF0000);
    check_ccr("CLR sets Z", SR_Z);
}

fn test_control_and_memory() {
    // MOVEQ #3,D0 / MOVEQ #0,D1 / loop: ADDQ.L #1,D1 / DBRA D0,loop
    run([0x7003, 0x7200, 0x5281, 0x51C8, 0xFFFC], 10);
    check_eq("DBRA runs count+1 times", g_cpu.d[1], 4);
    check_eq("DBRA leaves -1 in the low word", g_cpu.d[0] & 0xFFFF, 0xFFFF);
    check_eq("DBRA falls through", g_cpu.pc, CODE + 10);

    // MOVEA.L #$2000,A0 / MOVE.L #$12345678,D0 / MOVE.L D0,(A0) / MOVE.L (A0),D1 / LEA $10(A0),A1
    run([0x207C, 0x0000, 0x2000, 0x203C, 0x1234, 0x5678, 0x2080, 0x2210, 0x43E8, 0x0010], 5);
    check_eq("memory is big-endian", x68k_ram_read(0x2000), 0x12);
    check_eq("memory low byte", x68k_ram_read(0x2003), 0x78);
    check_eq("MOVE.L (A0),D1", g_cpu.d[1], 0x12345678);
    check_eq("LEA d16(A0)", g_cpu.a[1], 0x2010);

    // アドレス計算は 32 bit で折り返す。上位ビットの立ったベースとインデックスでも桁あふれにしない。
    // MOVEA.L #$68000000,A0 / MOVE.L #$20080000,D0 / LEA (0,A0,D0.L),A1 / LEA -2(A0),A2
    run([0x207C, 0x6800, 0x0000, 0x203C, 0x2008, 0x0000, 0x43F0, 0x0800, 0x45E8, 0xFFFE], 4);
    check_eq("indexed address wraps in 32 bits", g_cpu.a[1], 0x88080000);
    check_eq("negative displacement", g_cpu.a[2], 0x67FFFFFE);

    // JSR $3000.L / NOP        $3000: MOVEQ #7,D3 / RTS
    fresh();
    poke(CODE, [0x4EB9, 0x0000, 0x3000, 0x4E71]);
    poke(0x3000, [0x7607, 0x4E75]);
    m68k_step(g_cpu, g_mmu);
    check_eq("JSR target", g_cpu.pc, 0x3000);
    check_eq("JSR pushes 4 bytes", g_cpu.a[REG_A7], 0x7FFC);
    check_eq("JSR pushes the return address", x68k_ram_read32(0x7FFC), CODE + 6);
    m68k_step(g_cpu, g_mmu);
    m68k_step(g_cpu, g_mmu);
    check_eq("RTS returns", g_cpu.pc, CODE + 6);
    check_eq("RTS restores SP", g_cpu.a[REG_A7], 0x8000);
    check_eq("subroutine ran", g_cpu.d[3], 7);
}

fn test_exceptions() {
    // TRAP #0 はベクタ 32。次の命令のアドレスと SR を積む。
    fresh();
    x68k_ram_write32(0x80, 0x6000);
    poke(CODE, [0x4E40]);
    m68k_step(g_cpu, g_mmu);
    check_eq("TRAP #0 vector", g_cpu.pc, 0x6000);
    check_eq("TRAP frame is 6 bytes", g_cpu.a[REG_A7], 0x7FFA);
    check_eq("TRAP stacks the next PC", x68k_ram_read32(0x7FFC), CODE + 2);
    check_eq("TRAP stacks SR", x68k_ram_read16(0x7FFA), 0x2700);

    // ゼロ除算はベクタ 5。 MOVEQ #1,D0 / MOVEQ #0,D1 / DIVU D1,D0
    fresh();
    x68k_ram_write32(0x14, 0x4000);
    poke(CODE, [0x7001, 0x7200, 0x80C1]);
    for _ in 3 { m68k_step(g_cpu, g_mmu); }
    check_eq("divide by zero vector", g_cpu.pc, 0x4000);

    // 奇数アドレスのワードアクセスはアドレスエラー (ベクタ 3、14 バイトのフレーム)。
    // MOVEA.L #1,A0 / MOVE.W (A0),D0
    fresh();
    x68k_ram_write32(0x0C, 0x5000);
    poke(CODE, [0x207C, 0x0000, 0x0001, 0x3010]);
    m68k_step(g_cpu, g_mmu);
    m68k_step(g_cpu, g_mmu);
    check_eq("address error vector", g_cpu.pc, 0x5000);
    check_eq("address error frame is 14 bytes", g_cpu.a[REG_A7], 0x8000 - 14);
    check_eq("address error stacks the fault address", x68k_ram_read32(0x8000 - 12), 1);
    check_eq("address error stacks the opcode", x68k_ram_read16(0x8000 - 8), 0x3010);
    check_eq("address error stacks the instruction address", x68k_ram_read32(0x8000 - 4), CODE + 6);

    // ILLEGAL はベクタ 4。その命令自身のアドレスを積む。
    fresh();
    x68k_ram_write32(0x10, 0x6200);
    poke(CODE, [0x4AFC]);
    m68k_step(g_cpu, g_mmu);
    check_eq("illegal instruction vector", g_cpu.pc, 0x6200);
    check_eq("illegal instruction stacks its own address", x68k_ram_read32(0x7FFC), CODE);

    // 特権命令をユーザモードで実行するとベクタ 8。どの命令でもその命令自身のアドレスを積む。
    // RESET / STOP #$2000 / MOVE A0,USP / RTE / MOVE #$2700,SR
    let privileged: u16[5] = [0x4E70, 0x4E72, 0x4E60, 0x4E73, 0x46FC];
    for i in privileged.len {
        fresh();
        g_cpu.usp = 0x7000;
        cpu_set_sr(g_cpu, 0x0000);
        x68k_ram_write32(0x20, 0x6400);
        // ユーザモードは $2000 未満 (スーパーバイザ領域) を読めないので、その上に置く。
        poke(0x4800, [privileged[i], 0x2700]);
        g_cpu.pc = 0x4800;
        m68k_step(g_cpu, g_mmu);
        check_eq("privilege violation vector", g_cpu.pc, 0x6400);
        check_eq("privilege violation stacks the instruction address", x68k_ram_read32(0x7FFC), 0x4800);
        check_eq("privilege violation stacks the user SR", x68k_ram_read16(0x7FFA), 0x0000);
        check("privilege violation enters supervisor mode", cpu_is_supervisor(g_cpu));
    }

    // トレース: T が立っていると 1 命令ごとにベクタ 9。次の命令のアドレスと T 付きの SR を積む。
    // MOVEQ #1,D0 / MOVEQ #2,D1
    fresh();
    g_cpu.sr = 0xA700;
    x68k_ram_write32(0x24, 0x6600);
    poke(CODE, [0x7001, 0x7202]);
    m68k_step(g_cpu, g_mmu);
    check_eq("traced instruction still runs", g_cpu.d[0], 1);
    check_eq("trace vector", g_cpu.pc, 0x6600);
    check_eq("trace stacks the next instruction", x68k_ram_read32(0x7FFC), CODE + 2);
    check_eq("trace stacks SR with T set", x68k_ram_read16(0x7FFA), 0xA700);
    check_eq("trace handler runs with T clear", g_cpu.sr & SR_T, 0);
    check_eq("second instruction has not run", g_cpu.d[1], 0);

    // 命令が自分で例外に入ったときはトレースを重ねない。 TRAP #0
    fresh();
    g_cpu.sr = 0xA700;
    x68k_ram_write32(0x80, 0x6000);
    x68k_ram_write32(0x24, 0x6600);
    poke(CODE, [0x4E40]);
    m68k_step(g_cpu, g_mmu);
    check_eq("TRAP under trace goes to the TRAP handler", g_cpu.pc, 0x6000);
    check_eq("TRAP under trace builds one frame", g_cpu.a[REG_A7], 0x7FFA);

    // ユーザモードから割り込みを受けると SSP に切り替わる。
    fresh();
    g_cpu.usp = 0x7000;
    cpu_set_sr(g_cpu, 0x0000);
    check_eq("user mode uses USP", g_cpu.a[REG_A7], 0x7000);
    x68k_ram_write32(0x100, 0x6800);
    m68k_interrupt(g_cpu, g_mmu, 6, 0x40);
    check_eq("interrupt vector", g_cpu.pc, 0x6800);
    check_eq("interrupt uses SSP", g_cpu.a[REG_A7], 0x8000 - 6);
    check_eq("interrupt sets S and the level", g_cpu.sr & 0x2700, 0x2600);
    check_eq("USP is kept", g_cpu.usp, 0x7000);
}

fn test_input() {
    var missing: u8[>..] = [];
    for ch: i32 in 0x20..0x7F {
        let code, shift, ok = type_scancode(ch as u8);
        if !ok || code < 1 || code > 0x7F { missing.push(ch as u8); }
    }
    check("every printable ASCII character has a key", missing.len == 0);
    if missing.len > 0 { print("  no key for: ", missing); }

    let colon, colon_shift, colon_ok = type_scancode(':');
    check("':' is key 0x28", colon_ok && colon == 0x28 && !colon_shift);
    let star, star_shift, star_ok = type_scancode('*');
    check("'*' is SHIFT + 0x28", star_ok && star == 0x28 && star_shift);
    let big, big_shift, big_ok = type_scancode('A');
    check("'A' is SHIFT + 'a'", big_ok && big == 0x1E && big_shift);
    check("control characters have no key", !type_has_key(0x01));
    check("key name return", key_code("return") == 0x1D);
    check("key name a", key_code("a") == 0x1E);
    check("unknown key name", key_code("nosuchkey") == -1);
    check("joypad up", joy_mask("up") == 0x01);
    check("joypad trg2", joy_mask("b") == 0x40);
}

fn test_fdc_tables() {
    check("ReadData takes 8 parameter bytes", fdc_cmd_prm_len(FDC_READ_DATA) == 8);
    check("ReadData returns 7 result bytes", fdc_cmd_rsp_len(FDC_READ_DATA) == 7);
    check("Seek takes 2 parameter bytes", fdc_cmd_prm_len(FDC_SEEK) == 2);
    check("Seek has no result phase", fdc_cmd_rsp_len(FDC_SEEK) == 0);
    check("SenseIntStatus takes none", fdc_cmd_prm_len(FDC_SENSE_INT) == 0);
    check("SenseIntStatus returns 2", fdc_cmd_rsp_len(FDC_SENSE_INT) == 2);
    check("WriteID takes 5", fdc_cmd_prm_len(FDC_WRITE_ID) == 5);
    check("invalid command", fdc_cmd_prm_len(0) == 0 && fdc_cmd_rsp_len(0) == 0);

    // ドライブを選んでいない Seek は「ドライブなし」で終わり、SenseIntStatus で読める。
    var fdc = X68kFDC {};
    fdc_write(fdc, 7, 0x00);
    fdc_write(fdc, 3, 0x0F);
    fdc_write(fdc, 3, 0x00);
    fdc_write(fdc, 3, 0x05);
    check("Seek raises the interrupt", fdc.int_pending);
    fdc_write(fdc, 3, 0x08);
    check("peeking the result does not consume it", fdc_peek(fdc, 3) == 0x48 && fdc_peek(fdc, 3) == 0x48);
    check("SenseIntStatus: ST0 abnormal, not ready", fdc_read(fdc, 3) == 0x48);
    check("reading moves on to the cylinder byte", fdc_peek(fdc, 3) == 0x00 && fdc.rdnum == 1);
}

// デバッガ用の読み出しは、読むと状態が変わるレジスタを進めない。
fn test_peek() {
    fresh();
    g_mmu.mfp.last_key = 0x41;
    g_mmu.mfp.key_int_flag = true;
    check("peek of MFP UDR returns the key", mmu_peek8(g_mmu, 0xE8802F) == 0x41);
    check("peek of MFP UDR keeps the receive flag", g_mmu.mfp.key_int_flag);
    check("read of MFP UDR returns the key", mmu_read8(g_mmu, 0xE8802F) == 0x41);
    check("read of MFP UDR clears the receive flag", !g_mmu.mfp.key_int_flag);

    x68k_ram_write(0x2000, 0x5A);
    check("peek of RAM is an ordinary read", mmu_peek8(g_mmu, 0x2000) == 0x5A);
}

fn test_dmac() {
    var dmac = X68kDMAC {};
    dmac_write(dmac, 0xE8400D, 0x12);
    dmac_write(dmac, 0xE8400E, 0x34);
    dmac_write(dmac, 0xE8400F, 0x56);
    check_eq("MAR is 24 bits wide", dmac.ch[0].mar, 0x123456);
    check("MAR reads back", dmac_read(dmac, 0xE8400D) == 0x12 && dmac_read(dmac, 0xE8400F) == 0x56);
    dmac_write(dmac, 0xE8404A, 0x04);
    dmac_write(dmac, 0xE8404B, 0x00);
    check_eq("channel 1 MTC", dmac.ch[1].mtc, 0x0400);
    check("channel 0 MTC untouched", dmac.ch[0].mtc == 0);

    dmac.ch[2].csr = 0xF8;
    dmac_write(dmac, 0xE84080, 0xF0);
    check_eq("writing 1s to CSR clears them, ACT stays", dmac.ch[2].csr, 0x08);

    dmac_write(dmac, 0xE84007, 0x80);
    check_eq("CCR STR sets ACT", dmac.ch[0].csr & 0x08, 0x08);
    dmac_write(dmac, 0xE84007, 0x10);
    check_eq("software abort sets ERR and clears ACT", dmac.ch[0].csr & 0x18, 0x10);
    check_eq("software abort error code", dmac.ch[0].cer, 0x11);

    check("no interrupt pending", dmac_peek_irq(dmac) == -1);
    dmac.ch[1].niv = 0x6C;
    dmac.ch[1].eiv = 0x6D;
    dmac.ch[1].csr = 0x80;
    dmac.int_ch = 2;
    dmac.int_pending = true;
    check("normal completion uses NIV", dmac_peek_irq(dmac) == 0x6C);
    dmac.ch[1].csr = 0x10;
    check("an error uses EIV", dmac_peek_irq(dmac) == 0x6D);
    dmac_ack_irq(dmac);
    check("acknowledge clears the request", !dmac.int_pending && dmac_peek_irq(dmac) == -1);
}

fn test_rtc() {
    check("1970-01-01 is day 0", rtc_days_from_civil(1970, 1, 1) == 0);
    check("2026-01-01", rtc_days_from_civil(2026, 1, 1) * 86400 == RTC_EPOCH_2026);
    check("month 13 rolls into the next year", rtc_days_from_civil(2025, 13, 1) == rtc_days_from_civil(2026, 1, 1));
    var ok = true;
    for day in -800..40000 {
        var y: i64 = 0;
        var m: i64 = 0;
        var d: i64 = 0;
        rtc_civil_from_days(day, y, m, d);
        if rtc_days_from_civil(y, m, d) != day || m < 1 || m > 12 || d < 1 || d > 31 { ok = false; }
    }
    check("civil date round trip", ok);

    // 既定の時計は 2026-01-01 00:00:00 (木曜)。年は 1980 起点の 2 桁。
    var rtc = X68kRTC {};
    check("year digits", rtc_digit(rtc, 12) == 4 && rtc_digit(rtc, 11) == 6);
    check("month digits", rtc_digit(rtc, 10) == 0 && rtc_digit(rtc, 9) == 1);
    check("day digits", rtc_digit(rtc, 8) == 0 && rtc_digit(rtc, 7) == 1);
    check("weekday is Thursday", rtc_digit(rtc, 6) == 4);
    check("leap counter", rtc_read(rtc, 0x1B) == 0x08);
    rtc.now = 3661 * RTC_UNITS_PER_SEC;
    check("clock runs with emulated time", rtc_digit(rtc, 4) == 1 && rtc_digit(rtc, 2) == 1 && rtc_digit(rtc, 0) == 1);
    rtc_write(rtc, 0x0D, 0x03);
    check("writing the weekday changes only the weekday", rtc_digit(rtc, 6) == 3 && rtc_digit(rtc, 7) == 1);
    rtc_write(rtc, 0x13, 0x02);
    check("writing the month re-dates the clock", rtc_digit(rtc, 9) == 2 && rtc_digit(rtc, 4) == 1);
}

fn main() {
    test_flag_helpers();
    test_conditions();
    test_arithmetic();
    test_shifts_and_unary();
    test_control_and_memory();
    test_exceptions();
    test_input();
    test_fdc_tables();
    test_peek();
    test_dmac();
    test_rtc();
    print(g_checks - g_failures, " / ", g_checks, " checks passed");
    if g_failures > 0 { exit(1); }
}
