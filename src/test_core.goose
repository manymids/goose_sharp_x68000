// コアの単体テスト。BIOS もディスクイメージも要らない。
//   goose build src/test_core.goose -o test_core.exe && ./test_core.exe
// 失敗があれば内容を出して終了コード 1 で終わる。

import std;
import .m68k_types;
import .m68k_cpu;
import .m68k_mmu;
import .m68k_exec;
import .m68k_disasm;
import .x68k_ram;
import .x68k_input;
import .x68k_fdc;
import .x68k_dmac;
import .x68k_rtc;
import .x68k_state;
import .x68k_disk;
import .mcp_args;
import .launch_args;
import .x68k_adpcm;
import .x68k_opm;
import .x68k_output;

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
    g_mmu.init();
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
    for _ in steps { m68k::step(g_cpu, g_mmu); }
}

fn test_flag_helpers() {
    var cpu = M68kCPU {};
    cpu.sr = 0;
    cpu.flags_add(1, 0x01, 0x7F, 0x80);
    check_eq("add8 0x7F+1 sets N V", cpu.sr & 0x1F, SR_N | SR_V);
    cpu.flags_add(2, 0x0001, 0xFFFF, 0x10000);
    check_eq("add16 0xFFFF+1 sets X Z C", cpu.sr & 0x1F, SR_X | SR_Z | SR_C);
    cpu.flags_add(4, 0x80000000, 0x80000000, 0);
    check_eq("add32 overflow sets X Z V C", cpu.sr & 0x1F, SR_X | SR_Z | SR_V | SR_C);

    cpu.sr = SR_X;
    cpu.flags_sub(1, 0x01, 0x00, 0xFF, false);
    check_eq("cmp8 0-1 keeps X, sets N C", cpu.sr & 0x1F, SR_X | SR_N | SR_C);
    cpu.sr = SR_X;
    cpu.flags_sub(4, 5, 5, 0, true);
    check_eq("sub32 equal clears X, sets Z", cpu.sr & 0x1F, SR_Z);
    cpu.flags_sub(2, 0x0001, 0x8000, 0x7FFF, true);
    check_eq("sub16 0x8000-1 sets V", cpu.sr & 0x1F, SR_V);

    cpu.sr = SR_Z;
    cpu.flags_addx(4, 0, 0, 0);
    check_eq("addx zero result keeps Z", cpu.sr & 0x1F, SR_Z);
    cpu.flags_addx(4, 0, 1, 1);
    check_eq("addx non-zero result clears Z", cpu.sr & 0x1F, 0);
    cpu.sr = 0;
    cpu.flags_subx(1, 1, 0, 0xFF);
    check_eq("subx8 borrow sets X N C", cpu.sr & 0x1F, SR_X | SR_N | SR_C);

    cpu.sr = SR_C | SR_X;
    cpu.set_nz(2, 0x8000);
    check_eq("set_nz clears C, keeps X", cpu.sr & 0x1F, SR_X | SR_N);
    cpu.sr = SR_C;
    cpu.set_nz_only(1, 0x100);
    check_eq("set_nz_only looks at the low byte, keeps C", cpu.sr & 0x1F, SR_Z | SR_C);
}

fn test_conditions() {
    var cpu = M68kCPU {};
    cpu.sr = 0;
    check("HI with C=0 Z=0", cpu.check_condition(2));
    check("GE with N=V=0", cpu.check_condition(12));
    check("GT with N=V=0 Z=0", cpu.check_condition(14));
    cpu.sr = SR_Z;
    check("EQ with Z", cpu.check_condition(7));
    check("LS with Z", cpu.check_condition(3));
    check("LE with Z", cpu.check_condition(15));
    check("not GT with Z", !cpu.check_condition(14));
    cpu.sr = SR_N;
    check("LT with N!=V", cpu.check_condition(13));
    check("MI with N", cpu.check_condition(11));
    cpu.sr = SR_N | SR_V;
    check("GE with N=V=1", cpu.check_condition(12));
    cpu.sr = SR_C;
    check("CS with C", cpu.check_condition(5));
    check("not HI with C", !cpu.check_condition(2));
    check("T", cpu.check_condition(0));
    check("F", !cpu.check_condition(1));
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
    m68k::step(g_cpu, g_mmu);
    check_eq("JSR target", g_cpu.pc, 0x3000);
    check_eq("JSR pushes 4 bytes", g_cpu.a[REG_A7], 0x7FFC);
    check_eq("JSR pushes the return address", x68k_ram_read32(0x7FFC), CODE + 6);
    m68k::step(g_cpu, g_mmu);
    m68k::step(g_cpu, g_mmu);
    check_eq("RTS returns", g_cpu.pc, CODE + 6);
    check_eq("RTS restores SP", g_cpu.a[REG_A7], 0x8000);
    check_eq("subroutine ran", g_cpu.d[3], 7);
}

fn test_exceptions() {
    // TRAP #0 はベクタ 32。次の命令のアドレスと SR を積む。
    fresh();
    x68k_ram_write32(0x80, 0x6000);
    poke(CODE, [0x4E40]);
    m68k::step(g_cpu, g_mmu);
    check_eq("TRAP #0 vector", g_cpu.pc, 0x6000);
    check_eq("TRAP frame is 6 bytes", g_cpu.a[REG_A7], 0x7FFA);
    check_eq("TRAP stacks the next PC", x68k_ram_read32(0x7FFC), CODE + 2);
    check_eq("TRAP stacks SR", x68k_ram_read16(0x7FFA), 0x2700);

    // ゼロ除算はベクタ 5。 MOVEQ #1,D0 / MOVEQ #0,D1 / DIVU D1,D0
    fresh();
    x68k_ram_write32(0x14, 0x4000);
    poke(CODE, [0x7001, 0x7200, 0x80C1]);
    for _ in 3 { m68k::step(g_cpu, g_mmu); }
    check_eq("divide by zero vector", g_cpu.pc, 0x4000);

    // 奇数アドレスのワードアクセスはアドレスエラー (ベクタ 3、14 バイトのフレーム)。
    // MOVEA.L #1,A0 / MOVE.W (A0),D0
    fresh();
    x68k_ram_write32(0x0C, 0x5000);
    poke(CODE, [0x207C, 0x0000, 0x0001, 0x3010]);
    m68k::step(g_cpu, g_mmu);
    m68k::step(g_cpu, g_mmu);
    check_eq("address error vector", g_cpu.pc, 0x5000);
    check_eq("address error frame is 14 bytes", g_cpu.a[REG_A7], 0x8000 - 14);
    check_eq("address error stacks the fault address", x68k_ram_read32(0x8000 - 12), 1);
    check_eq("address error stacks the opcode", x68k_ram_read16(0x8000 - 8), 0x3010);
    check_eq("address error stacks the instruction address", x68k_ram_read32(0x8000 - 4), CODE + 6);

    // ILLEGAL はベクタ 4。その命令自身のアドレスを積む。
    fresh();
    x68k_ram_write32(0x10, 0x6200);
    poke(CODE, [0x4AFC]);
    m68k::step(g_cpu, g_mmu);
    check_eq("illegal instruction vector", g_cpu.pc, 0x6200);
    check_eq("illegal instruction stacks its own address", x68k_ram_read32(0x7FFC), CODE);

    // 特権命令をユーザモードで実行するとベクタ 8。どの命令でもその命令自身のアドレスを積む。
    // RESET / STOP #$2000 / MOVE A0,USP / RTE / MOVE #$2700,SR
    let privileged: u16[5] = [0x4E70, 0x4E72, 0x4E60, 0x4E73, 0x46FC];
    for i in privileged.len {
        fresh();
        g_cpu.usp = 0x7000;
        g_cpu.set_sr(0x0000);
        x68k_ram_write32(0x20, 0x6400);
        // ユーザモードは $2000 未満 (スーパーバイザ領域) を読めないので、その上に置く。
        poke(0x4800, [privileged[i], 0x2700]);
        g_cpu.pc = 0x4800;
        m68k::step(g_cpu, g_mmu);
        check_eq("privilege violation vector", g_cpu.pc, 0x6400);
        check_eq("privilege violation stacks the instruction address", x68k_ram_read32(0x7FFC), 0x4800);
        check_eq("privilege violation stacks the user SR", x68k_ram_read16(0x7FFA), 0x0000);
        check("privilege violation enters supervisor mode", g_cpu.is_supervisor());
    }

    // トレース: T が立っていると 1 命令ごとにベクタ 9。次の命令のアドレスと T 付きの SR を積む。
    // MOVEQ #1,D0 / MOVEQ #2,D1
    fresh();
    g_cpu.sr = 0xA700;
    x68k_ram_write32(0x24, 0x6600);
    poke(CODE, [0x7001, 0x7202]);
    m68k::step(g_cpu, g_mmu);
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
    m68k::step(g_cpu, g_mmu);
    check_eq("TRAP under trace goes to the TRAP handler", g_cpu.pc, 0x6000);
    check_eq("TRAP under trace builds one frame", g_cpu.a[REG_A7], 0x7FFA);

    // ユーザモードから割り込みを受けると SSP に切り替わる。
    fresh();
    g_cpu.usp = 0x7000;
    g_cpu.set_sr(0x0000);
    check_eq("user mode uses USP", g_cpu.a[REG_A7], 0x7000);
    x68k_ram_write32(0x100, 0x6800);
    m68k::interrupt(g_cpu, g_mmu, 6, 0x40);
    check_eq("interrupt vector", g_cpu.pc, 0x6800);
    check_eq("interrupt uses SSP", g_cpu.a[REG_A7], 0x8000 - 6);
    check_eq("interrupt sets S and the level", g_cpu.sr & 0x2700, 0x2600);
    check_eq("USP is kept", g_cpu.usp, 0x7000);
}

fn test_input() {
    var missing: u8[>..] = [];
    for ch: i32 in 0x20..0x7F {
        let code, shift, ok = input::type_scancode(ch as u8);
        if !ok || code < 1 || code > 0x7F { missing.push(ch as u8); }
    }
    check("every printable ASCII character has a key", missing.len == 0);
    if missing.len > 0 { print("  no key for: ", missing); }

    let colon, colon_shift, colon_ok = input::type_scancode(':');
    check("':' is key 0x28", colon_ok && colon == 0x28 && !colon_shift);
    let star, star_shift, star_ok = input::type_scancode('*');
    check("'*' is SHIFT + 0x28", star_ok && star == 0x28 && star_shift);
    let big, big_shift, big_ok = input::type_scancode('A');
    check("'A' is SHIFT + 'a'", big_ok && big == 0x1E && big_shift);
    check("control characters have no key", !input::type_has_key(0x01));
    check("key name return", input::key_code("return") == 0x1D);
    check("key name a", input::key_code("a") == 0x1E);
    check("unknown key name", input::key_code("nosuchkey") == KEY_UNKNOWN);
    check("function keys", input::key_code("f1") == 0x63 && input::key_code("f2") == 0x64 && input::key_code("f10") == 0x6C);
    check("F11 does not exist, F12 is blocked", input::key_code("f11") == KEY_UNKNOWN && input::key_code("f12") == KEY_BLOCKED);
    check("XF keys", input::key_code("xf1") == 0x55 && input::key_code("xf5") == 0x59 && input::key_code("xf6") == KEY_UNKNOWN);
    check("modifier keys", input::key_code("ctrl") == 0x71 && input::key_code("opt1") == 0x72 && input::key_code("opt2") == 0x73);
    check("editing keys", input::key_code("del") == 0x37 && input::key_code("ins") == 0x5E && input::key_code("undo") == 0x3A);
    check("a bare 'f' is the letter", input::key_code("f") == 0x21);
    check("joypad up", input::joy_mask("up") == 0x01);
    check("joypad trg2", input::joy_mask("b") == 0x40);
}

// 結果相で残っているバイト数。結果相でなければ -1。
fn result_left(fdc: X68kFDC&) -> i32 {
    match fdc.phase {
        Result r => r.left,
        _ => -1,
    }
}

fn test_fdc_tables() {
    check("ReadData takes 8 parameter bytes", fdc::cmd_prm_len(FDC_READ_DATA) == 8);
    check("ReadData returns 7 result bytes", fdc::cmd_rsp_len(FDC_READ_DATA) == 7);
    check("Seek takes 2 parameter bytes", fdc::cmd_prm_len(FDC_SEEK) == 2);
    check("Seek has no result phase", fdc::cmd_rsp_len(FDC_SEEK) == 0);
    check("SenseIntStatus takes none", fdc::cmd_prm_len(FDC_SENSE_INT) == 0);
    check("SenseIntStatus returns 2", fdc::cmd_rsp_len(FDC_SENSE_INT) == 2);
    check("WriteID takes 5", fdc::cmd_prm_len(FDC_WRITE_ID) == 5);
    check("invalid command", fdc::cmd_prm_len(0) == 0 && fdc::cmd_rsp_len(0) == 0);

    // ドライブを選んでいない Seek は「ドライブなし」で終わり、SenseIntStatus で読める。
    var fdc = X68kFDC {};
    fdc.write(7, 0x00);
    check("idle: ready, not busy", fdc.read(1) == 0x80 && fdc.phase == fdc::FdcPhase.Idle);
    fdc.write(3, 0x0F);
    check("command phase: busy, waiting for the CPU", fdc.read(1) == 0x90);
    fdc.write(3, 0x00);
    check("still in the command phase", fdc.read(1) == 0x90);
    fdc.write(3, 0x05);
    check("Seek has no result phase", fdc.phase == fdc::FdcPhase.Idle);
    check("Seek raises the interrupt", fdc.int_pending);
    fdc.write(3, 0x08);
    check("result phase: data for the CPU", result_left(fdc) == 2 && fdc.read(1) == 0xD0);
    check("peeking the result does not consume it", fdc.peek(3) == 0x48 && fdc.peek(3) == 0x48);
    check("SenseIntStatus: ST0 abnormal, not ready", fdc.read(3) == 0x48);
    check("reading moves on to the cylinder byte", fdc.peek(3) == 0x00 && result_left(fdc) == 1);
    fdc.read(3);
    check("the last result byte returns to idle", fdc.phase == fdc::FdcPhase.Idle);
    // 結果を読み残していても、次のコマンドを受け付ける
    fdc.write(3, 0x08);
    fdc.write(3, 0x0F);
    check("a new command may interrupt the result phase", fdc.read(1) == 0x90 && result_left(fdc) == -1);
}

// デバッガ用の読み出しは、読むと状態が変わるレジスタを進めない。
fn test_peek() {
    fresh();
    g_mmu.mfp.last_key = 0x41;
    g_mmu.mfp.key_int_flag = true;
    check("peek of MFP UDR returns the key", g_mmu.peek8(0xE8802F) == 0x41);
    check("peek of MFP UDR keeps the receive flag", g_mmu.mfp.key_int_flag);
    check("read of MFP UDR returns the key", g_mmu.read8(0xE8802F) == 0x41);
    check("read of MFP UDR clears the receive flag", !g_mmu.mfp.key_int_flag);

    x68k_ram_write(0x2000, 0x5A);
    check("peek of RAM is an ordinary read", g_mmu.peek8(0x2000) == 0x5A);
}

fn test_dmac() {
    var dmac = X68kDMAC {};
    dmac.write(0xE8400D, 0x12);
    dmac.write(0xE8400E, 0x34);
    dmac.write(0xE8400F, 0x56);
    check_eq("MAR is 24 bits wide", dmac.ch[0].mar, 0x123456);
    check("MAR reads back", dmac.read(0xE8400D) == 0x12 && dmac.read(0xE8400F) == 0x56);
    dmac.write(0xE8404A, 0x04);
    dmac.write(0xE8404B, 0x00);
    check_eq("channel 1 MTC", dmac.ch[1].mtc, 0x0400);
    check("channel 0 MTC untouched", dmac.ch[0].mtc == 0);

    dmac.ch[2].csr = 0xF8;
    dmac.write(0xE84080, 0xF0);
    check_eq("writing 1s to CSR clears them, ACT stays", dmac.ch[2].csr, 0x08);

    dmac.write(0xE84007, 0x80);
    check_eq("CCR STR sets ACT", dmac.ch[0].csr & 0x08, 0x08);
    dmac.write(0xE84007, 0x10);
    check_eq("software abort sets ERR and clears ACT", dmac.ch[0].csr & 0x18, 0x10);
    check_eq("software abort error code", dmac.ch[0].cer, 0x11);

    check("no interrupt pending", dmac.peek_irq() == -1);
    dmac.ch[1].niv = 0x6C;
    dmac.ch[1].eiv = 0x6D;
    dmac.ch[1].csr = 0x80;
    dmac.int_ch = 2;
    dmac.int_pending = true;
    check("normal completion uses NIV", dmac.peek_irq() == 0x6C);
    dmac.ch[1].csr = 0x10;
    check("an error uses EIV", dmac.peek_irq() == 0x6D);
    dmac.ack_irq();
    check("acknowledge clears the request", !dmac.int_pending && dmac.peek_irq() == -1);
}

fn test_rtc() {
    check("1970-01-01 is day 0", rtc::days_from_civil(1970, 1, 1) == 0);
    check("2026-01-01", rtc::days_from_civil(2026, 1, 1) * 86400 == RTC_EPOCH_2026);
    check("month 13 rolls into the next year", rtc::days_from_civil(2025, 13, 1) == rtc::days_from_civil(2026, 1, 1));
    var ok = true;
    for day in -800..40000 {
        let y, m, d = rtc::civil_from_days(day);
        if rtc::days_from_civil(y, m, d) != day || m < 1 || m > 12 || d < 1 || d > 31 { ok = false; }
    }
    check("civil date round trip", ok);

    // 既定の時計は 2026-01-01 00:00:00 (木曜)。年は 1980 起点の 2 桁。
    var rtc = X68kRTC {};
    check("year digits", rtc.digit(12) == 4 && rtc.digit(11) == 6);
    check("month digits", rtc.digit(10) == 0 && rtc.digit(9) == 1);
    check("day digits", rtc.digit(8) == 0 && rtc.digit(7) == 1);
    check("weekday is Thursday", rtc.digit(6) == 4);
    check("leap counter", rtc.read(0x1B) == 0x08);
    rtc.now = 3661 * RTC_UNITS_PER_SEC;
    check("clock runs with emulated time", rtc.digit(4) == 1 && rtc.digit(2) == 1 && rtc.digit(0) == 1);
    rtc.write(0x0D, 0x03);
    check("writing the weekday changes only the weekday", rtc.digit(6) == 3 && rtc.digit(7) == 1);
    rtc.write(0x13, 0x02);
    check("writing the month re-dates the clock", rtc.digit(9) == 2 && rtc.digit(4) == 1);
}

// CODE に words を置いて 1 命令を逆アセンブルし、文字列と長さを確かめる。
fn check_dis(words: u16[:], want: const u8[:], want_len: i32) {
    fresh();
    poke(CODE, words);
    var text: u8[>..] = [];
    let length = m68k_disasm(g_mmu, CODE, text);
    g_checks++;
    if text != want || length != want_len {
        g_failures++;
        print("FAIL: disasm: got \"", text, "\" (", length, " bytes), want \"", want, "\" (", want_len, " bytes)");
    }
}

fn test_disasm() {
    check_dis([0x4E71], "NOP", 2);
    check_dis([0x4E75], "RTS", 2);
    check_dis([0x4E73], "RTE", 2);
    check_dis([0x4E72, 0x2000], "STOP #$2000", 4);
    check_dis([0x4E40], "TRAP #0", 2);
    check_dis([0x4E4F], "TRAP #15", 2);
    check_dis([0x4AFC], "ILLEGAL", 2);
    check_dis([0x70FF], "MOVEQ #-$1,D0", 2);
    check_dis([0x7C7F], "MOVEQ #$7f,D6", 2);
    check_dis([0x203C, 0x1234, 0x5678], "MOVE.L #$12345678,D0", 6);
    check_dis([0x303C, 0x8001], "MOVE.W #$8001,D0", 4);
    check_dis([0x103C, 0x00FF], "MOVE.B #$ff,D0", 4);
    check_dis([0x207C, 0x0000, 0x2000], "MOVEA.L #$00002000,A0", 6);
    check_dis([0x2080], "MOVE.L D0,(A0)", 2);
    check_dis([0x2210], "MOVE.L (A0),D1", 2);
    check_dis([0x12D8], "MOVE.B (A0)+,(A1)+", 2);
    check_dis([0x3F00], "MOVE.W D0,-(A7)", 2);
    check_dis([0x3028, 0x0010], "MOVE.W $10(A0),D0", 4);
    check_dis([0x3028, 0xFFFE], "MOVE.W -$2(A0),D0", 4);
    check_dis([0x3030, 0x0800], "MOVE.W $0(A0,D0.L),D0", 4);
    check_dis([0x3030, 0x90FC], "MOVE.W -$4(A0,A1.W),D0", 4);
    check_dis([0x3038, 0x0400], "MOVE.W ($000400).W,D0", 4);
    check_dis([0x33C0, 0x00E8, 0x0028], "MOVE.W D0,($00e80028).L", 6);
    check_dis([0x303A, 0x0010], "MOVE.W $001012(PC),D0", 4);
    check_dis([0x43E8, 0x0010], "LEA $10(A0),A1", 4);
    check_dis([0x4EB9, 0x0000, 0x3000], "JSR ($00003000).L", 6);
    check_dis([0x4ED0], "JMP (A0)", 2);
    check_dis([0x4879, 0x0001, 0x0000], "PEA ($00010000).L", 6);
    check_dis([0x4E56, 0xFFF8], "LINK A6,#-$8", 4);
    check_dis([0x4E5E], "UNLK A6", 2);
    check_dis([0x4E60], "MOVE A0,USP", 2);
    check_dis([0x46FC, 0x2700], "MOVE #$2700,SR", 4);
    check_dis([0x40C0], "MOVE SR,D0", 2);
    check_dis([0x4840], "SWAP D0", 2);
    check_dis([0x4880], "EXT.W D0", 2);
    check_dis([0x48C1], "EXT.L D1", 2);
    check_dis([0x4480], "NEG.L D0", 2);
    check_dis([0x4600], "NOT.B D0", 2);
    check_dis([0x4240], "CLR.W D0", 2);
    check_dis([0x4A80], "TST.L D0", 2);
    check_dis([0x48E7, 0xFFFE], "MOVEM.L D0-D7/A0-A6,-(A7)", 4);
    check_dis([0x4CDF, 0x7FFF], "MOVEM.L (A7)+,D0-D7/A0-A6", 4);
    check_dis([0x48E7, 0xC080], "MOVEM.L D0-D1/A0,-(A7)", 4);
    check_dis([0xD081], "ADD.L D1,D0", 2);
    check_dis([0xD001], "ADD.B D1,D0", 2);
    check_dis([0x9041], "SUB.W D1,D0", 2);
    check_dis([0xD150], "ADD.W D0,(A0)", 2);
    check_dis([0xD181], "ADDX.L D1,D0", 2);
    check_dis([0x9308], "SUBX.B -(A0),-(A1)", 2);
    check_dis([0xD1C0], "ADDA.L D0,A0", 2);
    check_dis([0x90FC, 0x0010], "SUBA.W #$0010,A0", 4);
    check_dis([0xB081], "CMP.L D1,D0", 2);
    check_dis([0xB1C1], "CMPA.L D1,A0", 2);
    check_dis([0xB308], "CMPM.B (A0)+,(A1)+", 2);
    check_dis([0xB380], "EOR.L D1,D0", 2);
    check_dis([0xC0C1], "MULU D1,D0", 2);
    check_dis([0xC1C1], "MULS D1,D0", 2);
    check_dis([0x80C1], "DIVU D1,D0", 2);
    check_dis([0x81FC, 0x0007], "DIVS #$0007,D0", 4);
    check_dis([0xC101], "ABCD D1,D0", 2);
    check_dis([0xC141], "EXG D0,D1", 2);
    check_dis([0xC189], "EXG D0,A1", 2);
    check_dis([0xC081], "AND.L D1,D0", 2);
    check_dis([0x8081], "OR.L D1,D0", 2);
    check_dis([0x0640, 0x0010], "ADDI.W #$0010,D0", 4);
    check_dis([0x0C80, 0x0000, 0x0005], "CMPI.L #$00000005,D0", 6);
    check_dis([0x0200, 0x000F], "ANDI.B #$0f,D0", 4);
    check_dis([0x007C, 0x0700], "ORI #$0700,SR", 4);
    check_dis([0x023C, 0x00FE], "ANDI #$fe,CCR", 4);
    check_dis([0x0800, 0x0007], "BTST #$7,D0", 4);
    check_dis([0x08D0, 0x0003], "BSET #$3,(A0)", 4);
    check_dis([0x0300], "BTST D1,D0", 2);
    check_dis([0x0188, 0x0004], "MOVEP.W D0,$4(A0)", 4);
    check_dis([0x5281], "ADDQ.L #1,D1", 2);
    check_dis([0x5148], "SUBQ.W #8,A0", 2);
    check_dis([0x51C8, 0xFFFC], "DBRA D0,$000ffe", 4);
    check_dis([0x56C8, 0x0006], "DBNE D0,$001008", 4);
    check_dis([0x57C0], "SEQ D0", 2);
    check_dis([0x6702], "BEQ.S $001004", 2);
    check_dis([0x66FE], "BNE.S $001000", 2);
    check_dis([0x6000, 0x0100], "BRA.W $001102", 4);
    check_dis([0x6100, 0xFF00], "BSR.W $000f02", 4);
    check_dis([0xE388], "LSL.L #1,D0", 2);
    check_dis([0xE240], "ASR.W #1,D0", 2);
    check_dis([0xE318], "ROL.B #1,D0", 2);
    check_dis([0xE0A8], "LSR.L D0,D0", 2);
    check_dis([0xE1D0], "ASL.W (A0)", 2);
    check_dis([0xE4D8], "ROXR.W (A0)+", 2);
    // 68000 に無い形、ライン A / ライン F はデータとして出す
    check_dis([0xFF09], "DC.W $ff09", 2);
    check_dis([0xA000], "DC.W $a000", 2);
    check_dis([0x4E7A, 0x0002], "DC.W $4e7a", 2);
}

// ステートファイルの読み込みは、スロットへ入れる前に形式を確かめて弾く。
fn test_state_file() {
    var empty: u8[>..] = [];
    check("empty data is not a state file", state::import_image(STATE_SLOT, 0, empty[..]) == state::StateFileError.NotAStateFile);
    var text: u8[>..] = [];
    text.append("this is not a state file");
    check("text is not a state file", state::import_image(STATE_SLOT, 0, text[..]) == state::StateFileError.NotAStateFile);

    // 正しいヘッダだけがあって続きが無いもの
    var header: StateFileHeader[>..] = [];
    header.push(StateFileHeader { magic: STATE_FILE_MAGIC, version: STATE_VERSION });
    var image: u8[>..] = [];
    to_bytes(header, image);
    check("a header alone is damaged", state::import_image(STATE_SLOT, 0, image[..]) == state::StateFileError.Corrupt);

    var old: StateFileHeader[>..] = [];
    old.push(StateFileHeader { magic: STATE_FILE_MAGIC, version: STATE_VERSION - 1 });
    var old_image: u8[>..] = [];
    to_bytes(old, old_image);
    check("another version is refused", state::import_image(STATE_SLOT, 0, old_image[..]) == state::StateFileError.WrongVersion);
    check("a slot outside the bank is refused", state::import_image(STATE_SLOT, 99, image[..]) == state::StateFileError.Rejected);

    var h: u64 = state::checksum(STATE_HASH_SEED, "a");
    check("FNV-1a of \"a\"", h == 0xAF63DC4C8601EC8C);
}

// ディスクモジュール。イメージはその場で作り、ファイルは使わない。
fn mount_fd0(kind: disk::FdKind, image: u8[:]) {
    var none: u8[>..] = [];
    var s = DiskState {};
    s.fd[0] = disk::FdDrive { kind: kind, len: image.len as i32, .. };
    disk::restore(s, image, none[..], none[..]);
}

fn test_disk_paths() {
    check("d88 by extension", disk::kind_of("a.D88") == disk::FdKind.D88);
    check("88d by extension", disk::kind_of("dir.x/a.88d") == disk::FdKind.D88);
    check("dim by extension", disk::kind_of("a.dim") == disk::FdKind.Dim);
    check("2hd is a flat image", disk::kind_of("a.2HD") == disk::FdKind.Xdf);
    check("no extension is a flat image", disk::kind_of("image") == disk::FdKind.Xdf);
    check("hdf is a hard disk", disk::path_is_hdd("X.HDF") && disk::path_is_hdd("x.hds"));
    check("other names are floppies", !disk::path_is_hdd("x.xdf") && !disk::path_is_hdd("x.hdfx") && !disk::path_is_hdd("hdf"));
}

fn test_disk_xdf() {
    var image: u8[>..] = [];
    image.resize(FDD_XDF_BYTES, 0);
    image[(3 * 8 + 1) * 1024] = 0xA5; // トラック 3 (シリンダ 1、ヘッド 1) のセクタ 2
    mount_fd0(disk::FdKind.Xdf, image[..]);
    var buf: u8[8192] = [0; 8192];
    check("xdf: read a sector", disk::fd_read(0, 3, 1, 1, 2, 3, buf[..]) && buf[0] == 0xA5);
    let ok, c, h, r, n = disk::fd_current_id(0);
    check("xdf: READ ID gives the next sector", ok && c == 1 && h == 1 && r == 3 && n == 3);
    check("xdf: the ID must match the track", !disk::fd_read(0, 3, 2, 1, 2, 3, buf[..]));
    check("xdf: there is no sector 9", !disk::fd_read(0, 3, 1, 1, 9, 3, buf[..]));
    check("xdf: there is no track 154", !disk::fd_seek(0, 154));
    buf[0] = 0x5A;
    check("xdf: write a sector", disk::fd_write(0, 3, 1, 1, 2, 3, buf[..]));
    buf[0] = 0;
    check("xdf: the write is read back", disk::fd_read(0, 3, 1, 1, 2, 3, buf[..]) && buf[0] == 0x5A);
    check("an empty drive does not seek", !disk::fd_seek(1, 0) && !disk::fd_loaded(1));
}

fn test_disk_dim() {
    // 2HS: 1024 バイト * 9 セクタ。トラック 0〜2 だけがあるイメージ。
    var image: u8[>..] = [];
    image.resize(256 + 9 * 1024 * 3, 0);
    image[0] = 1;
    for trk in 3 { image[1 + trk] = 1; }
    image[256 + 9 * 1024 + 1024] = 0xC3; // トラック 1 の 2 番目のセクタ。2HS の ID では R = 11
    mount_fd0(disk::FdKind.Dim, image[..]);
    var buf: u8[8192] = [0; 8192];
    check("dim: read a 2HS sector", disk::fd_read(0, 1, 0, 1, 11, 3, buf[..]) && buf[0] == 0xC3);
    let ok, c, h, r, n = disk::fd_current_id(0);
    check("dim: READ ID gives the next 2HS sector", ok && c == 0 && h == 1 && r == 12 && n == 3);
    check("dim: a 512-byte ID does not match", !disk::fd_read(0, 1, 0, 1, 11, 2, buf[..]));
    check("dim: a track the header leaves out", !disk::fd_seek(0, 3));
    check("dim: a sector past the image", disk::fd_seek(0, 2) && disk::fd_read(0, 2, 1, 0, 9, 3, buf[..]) && !disk::fd_seek(0, 200));
}

fn test_disk_d88() {
    // トラック 0 に 256 バイトのセクタが 2 つあるイメージ。
    let top = 0x2B0;
    var image: u8[>..] = [];
    image.resize(top + 2 * (16 + 256), 0);
    image[28] = (image.len & 0xFF) as u8;
    image[29] = (image.len >> 8) as u8;
    image[32] = 0xB0;
    image[33] = 0x02;
    for s in 2 {
        let at = top + s * (16 + 256);
        image[at + 2] = (s + 1) as u8; // R
        image[at + 3] = 1;             // N
        image[at + 4] = 2;             // このトラックのセクタ数
        image[at + 15] = 1;            // データ長 256
    }
    image[top + (16 + 256) + 16] = 0x77;
    mount_fd0(disk::FdKind.D88, image[..]);
    var buf: u8[8192] = [0; 8192];
    check("d88: read the last sector", disk::fd_read(0, 0, 0, 0, 2, 1, buf[..]) && buf[0] == 0x77);
    let ok, _, _, r, n = disk::fd_current_id(0);
    check("d88: READ ID wraps to the first sector", ok && r == 1 && n == 1);
    check("d88: read the first sector", disk::fd_read(0, 0, 0, 0, 1, 1, buf[..]) && buf[0] == 0);
    let ok2, _, _, r2, _ = disk::fd_current_id(0);
    check("d88: READ ID moves to the second sector", ok2 && r2 == 2);
    check("d88: no such sector", !disk::fd_read(0, 0, 0, 0, 3, 1, buf[..]));
    check("d88: a track with no data", !disk::fd_seek(0, 1));
    buf[0] = 0x33;
    check("d88: write a sector", disk::fd_write(0, 0, 0, 0, 2, 1, buf[..]));
    buf[0] = 0;
    check("d88: the write is read back", disk::fd_read(0, 0, 0, 0, 2, 1, buf[..]) && buf[0] == 0x33);
}

fn test_disk_hdd_and_media() {
    var none: u8[>..] = [];
    var hdd: u8[>..] = [];
    hdd.resize(1024, 0);
    hdd[2 * 256] = 0x42;
    var s = DiskState {};
    disk::restore(s, none[..], none[..], hdd[..]);
    var sector: u8[256] = [0xFF; 256];
    check("hdd: read a sector", disk::hdd_read(2, sector) == 1 && sector[0] == 0x42 && sector[1] == 0);
    sector[5] = 0x99;
    check("hdd: write a sector", disk::hdd_write(3, sector) == 1 && disk::hdd_read(3, sector) == 1 && sector[5] == 0x99);
    check("hdd: a sector past the image", disk::hdd_read(4, sector) == 0 && sector[5] == 0);
    disk::hdd_eject();
    check("hdd: no image", disk::hdd_read(0, sector) == -1 && !disk::hdd_unit_ok());
    check("hdd: ejecting asks SASI to reset, once", disk::take_sasi_reset() && !disk::take_sasi_reset());

    // 挿入の通知は 3 フレーム後、排出は入っていたときすぐ
    var image: u8[>..] = [];
    image.resize(FDD_XDF_BYTES, 0);
    mount_fd0(disk::FdKind.Xdf, image[..]);
    g_disk.fd[0].delay = 2;
    disk::media_tick(true);
    check("media: not yet", !g_disk.media_pending);
    disk::media_tick(true);
    check("media: the insertion is reported", g_disk.media_pending);
    disk::machine_reset();
    check("media: a reset withdraws the request and keeps the disk", !g_disk.media_pending && disk::fd_loaded(0));
    disk::fd_eject(0);
    check("media: masked, nothing is reported", !g_disk.media_pending && !disk::fd_loaded(0));
    mount_fd0(disk::FdKind.Xdf, image[..]);
    disk::media_tick(true);
    disk::fd_eject(0);
    check("media: an ejection is reported at once", g_disk.media_pending);

    // 保存してあった状態の検査
    var good = DiskState {};
    good.fd[0] = disk::FdDrive { kind: disk::FdKind.Xdf, len: 1000, trk: 5, .. };
    check("state: a short XDF padded to full size", disk::state_ok(good, [FDD_XDF_BYTES, 0, 0]));
    check("state: an XDF of another size", !disk::state_ok(good, [1000, 0, 0]));
    check("state: bytes for an empty drive", !disk::state_ok(good, [FDD_XDF_BYTES, 16, 0]));
    check("state: a hard disk over 40 MB", !disk::state_ok(good, [FDD_XDF_BYTES, 0, HDD_MAX_BYTES + 1]));
    good.fd[0].delay = 9;
    check("state: an impossible delay", !disk::state_ok(good, [FDD_XDF_BYTES, 0, 0]));
    disk::power_on();
    check("power on empties every drive", !disk::fd_loaded(0) && !disk::hdd_loaded() && !g_disk.media_pending);
}

// 8255 ポート C と OPM の控え。どちらも MMU が持ち、チェックポイントに入る。
fn test_io_latches() {
    g_mmu.init();
    check_eq("pia: port C after reset", g_mmu.read8(0xE9A005), 0x0B);
    g_mmu.write8(0xE9A005, 0x35);
    check_eq("pia: port C reads back", g_mmu.read8(0xE9A005), 0x35);
    g_mmu.write8(0xE9A007, 0x03); // bit 1 を 1 に
    check_eq("pia: bit set", g_mmu.read8(0xE9A005), 0x37);
    g_mmu.write8(0xE9A007, 0x08); // bit 4 を 0 に
    check_eq("pia: bit reset", g_mmu.read8(0xE9A005), 0x27);
    g_mmu.write8(0xE9A007, 0x81); // bit 7 が立っていればモード設定で、ポート C は変わらない
    check_eq("pia: a mode word leaves port C", g_mmu.read8(0xE9A005), 0x27);

    g_mmu.write8(0xE90001, 0x18);
    g_mmu.write8(0xE90003, 0xC4);
    check_eq("opm: register value is kept", g_mmu.opm.regs[0x18], 0xC4);
    g_mmu.write8(0xE90001, 0x08);
    g_mmu.write8(0xE90003, 0x7B); // チャンネル 3、スロット 4 つともキーオン
    check_eq("opm: key-on slots of the channel", g_mmu.opm.key_on[3], 0x0F);
    g_mmu.write8(0xE90003, 0x03); // 同じチャンネルをキーオフ
    check_eq("opm: key off", g_mmu.opm.key_on[3], 0);
    check_eq("opm: other channels untouched", g_mmu.opm.key_on[2], 0);

    g_mmu.init();
    check("a reset clears the latches", g_mmu.pia_c == 0x0B && g_mmu.opm.regs[0x18] == 0 && g_mmu.opm.addr == 0);
}

// MCP の引数の取り出し (mcp_args)。
fn check_addr(name: const u8[:], obj: const u8[:], want: u32, want_present: bool, want_valid: bool) {
    let v, present, valid = json_addr_parse(obj, "a");
    check(name, present == want_present && valid == want_valid && (!valid || !present || v == want));
}

fn test_mcp_args() {
    let req = "{\"jsonrpc\":\"2.0\", \"id\" :  17 ,\"method\":\"tools/call\",\"params\":{\"name\":\"arcl_run\",\"arguments\":{ \"frames\": 3, \"name\":\"inner\" }}}";
    let id, has_id = json_member(req, "id");
    check("member: a number, without the spaces around it", has_id && id == "17");
    let params, has_params = json_member(req, "params");
    check("member: an object", has_params && params.len > 0 && params[0] == '{');
    var name: u8[>..] = [];
    check("str: the tool name is the one in params, not the one in its arguments",
        extract_json_str(params, "name", name) && name == "arcl_run");
    let args, _ = json_member(params, "arguments");
    check("int: a member of the arguments", extract_json_int(args, "frames", -1) == 3);
    check("has: present and absent keys", json_has(args, "frames") && !json_has(args, "method") && !json_has(req, "frames"));

    var text: u8[>..] = [];
    check("str: escapes are decoded", extract_json_str("{\"p\":\"a\\n\\\"b\\u3042\"}", "p", text) && text == "a\n\"bあ");
    text.clear();
    check("str: a number is not a string", !extract_json_str("{\"p\":5}", "p", text));
    check("str: the first of two equal keys", extract_json_str("{\"p\":\"x\",\"p\":\"y\"}", "p", text) && text == "x");

    check("int: negative", extract_json_int("{\"n\":-12}", "n", 0) == -12);
    check("int: a string falls back", extract_json_int("{\"n\":\"5\"}", "n", 7) == 7);
    check("int: a fraction falls back", extract_json_int("{\"n\":1.5}", "n", 7) == 7);
    check("int: an exponent that is whole", extract_json_int("{\"n\":1e3}", "n", 7) == 1000);
    check("int: too large for 32 bits falls back", extract_json_int("{\"n\":99999999999}", "n", 7) == 7);
    check("int: absent falls back", extract_json_int("{}", "n", 7) == 7);

    check_addr("addr: a number", "{\"a\":4096}", 4096, true, true);
    check_addr("addr: a negative number wraps to 32 bits", "{\"a\":-1}", 0xFFFFFFFF, true, true);
    check_addr("addr: 0x prefix", "{\"a\":\"0x00FF0010\"}", 0xFF0010, true, true);
    check_addr("addr: $ prefix", "{\"a\":\"$e8a000\"}", 0xE8A000, true, true);
    check_addr("addr: h suffix", "{\"a\":\"1000h\"}", 0x1000, true, true);
    check_addr("addr: bare hex digits", "{\"a\":\"ff\"}", 0xFF, true, true);
    check_addr("addr: a decimal string", "{\"a\":\" 255 \"}", 255, true, true);
    check_addr("addr: more than 32 bits", "{\"a\":\"0x100000000\"}", 0, true, false);
    check_addr("addr: not a number", "{\"a\":\"zz\"}", 0, true, false);
    check_addr("addr: a boolean", "{\"a\":true}", 0, true, false);
    check_addr("addr: a fraction", "{\"a\":1.5}", 0, true, false);
    check_addr("addr: absent is not an error", "{\"b\":1}", 0, false, true);

    // 壊れた入力は、キーが無いものとして扱う
    check("broken: text that is not JSON", !json_has("not json", "a") && !json_has("", "a"));
    check("broken: an object cut short", !json_has("{\"a\":1,\"b\":", "a"));

    var steps: const u8[:][>..] = [];
    check("elements: objects and other values, as written",
        json_elements("[ {\"op\":\"run\"}, 5 ,\"x\" ]", steps) && steps.len == 3
        && steps[0] == "{\"op\":\"run\"}" && steps[1] == "5" && steps[2] == "\"x\"");
    var none: const u8[:][>..] = [];
    check("elements: not an array", !json_elements("{\"a\":1}", none) && !json_elements("", none));
    check("elements: an empty array", json_elements("[]", none) && none.len == 0);
}

// 起動引数の解釈 (launch_args)。
fn test_launch_args() {
    var none: const u8[:][>..] = [];
    var o = LaunchOptions {};
    check("args: nothing gives the defaults", launch::parse(none, o) == "" && o.clock_mhz == 10 && o.screen_w == 768
        && o.scale == 1 && !o.mcp_mode && !o.no_window && !o.content_set && o.max_frames == -1 && o.layers == -1);

    o = LaunchOptions {};
    check("args: a typical MCP launch", launch::parse(["--mcp", "--no-window", "--mcp-layers", "all", "--system-dir", "keropi", "GAME.XDF"], o) == ""
        && o.mcp_mode && o.no_window && o.layers == MCP_LAYER_ALL && o.sys_set && o.sys_dir == "keropi"
        && o.content_set && o.content_path == "GAME.XDF");

    o = LaunchOptions {};
    check("args: numbers", launch::parse(["--clock", "25", "--scale", "2", "--frames", "600", "--dump-after-frames", "30", "--mode", "512x512"], o) == ""
        && o.clock_mhz == 25 && o.clock_set && o.scale == 2 && o.scale_set && o.max_frames == 600 && o.frames_set
        && o.dump_after == 30 && o.screen_w == 512 && o.mode_set);

    o = LaunchOptions {};
    check("args: --no-disk counts as naming the disk", launch::parse(["a.xdf", "--no-disk"], o) == "" && o.content_set && o.content_path.len == 0);
    o = LaunchOptions {};
    check("args: the last disk wins", launch::parse(["a.xdf", "b.xdf"], o) == "" && o.content_path == "b.xdf");
    o = LaunchOptions {};
    check("args: after --, a leading dash is a file name", launch::parse(["--", "-odd.xdf"], o) == "" && o.content_path == "-odd.xdf");
    o = LaunchOptions {};
    check("args: -512 is a short form of --mode", launch::parse(["-512"], o) == "" && o.screen_w == 512 && o.mode_set);
    o = LaunchOptions {};
    check("args: --ram other than 12 is noted, not refused", launch::parse(["--ram", "4"], o) == "" && o.ram_ignored);
    o = LaunchOptions {};
    check("args: --ram 12 is quiet", launch::parse(["--ram", "12"], o) == "" && !o.ram_ignored);
    o = LaunchOptions {};
    check("args: --help skips the other checks", launch::parse(["--no-window", "--help"], o) == "" && o.help);

    o = LaunchOptions {};
    check("args: an unknown option", launch::parse(["--bogus"], o) == "unknown option or missing option value (use --help)\n");
    o = LaunchOptions {};
    check("args: an option with its value missing", launch::parse(["--clock"], o) == "unknown option or missing option value (use --help)\n");
    o = LaunchOptions {};
    check("args: a clock out of range", launch::parse(["--clock", "999"], o) == "invalid --clock value\n");
    o = LaunchOptions {};
    check("args: a scale out of range", launch::parse(["--scale", "3"], o) == "--scale must be 1 or 2\n");
    o = LaunchOptions {};
    check("args: frames must be positive", launch::parse(["--frames", "0"], o) == "--frames must be a positive integer\n");
    o = LaunchOptions {};
    check("args: a bad mode", launch::parse(["--mode", "640"], o) == "--mode must be 512 or 768\n");
    o = LaunchOptions {};
    check("args: bad layers", launch::parse(["--mcp-layers", "l9"], o) == "--mcp-layers: expected l0,l1,l2,l3,l4 or all\n");
    o = LaunchOptions {};
    check("args: --no-window alone has nothing to do", launch::parse(["--no-window"], o) == "--no-window requires --frames N or --dump-frame PATH\n");
    o = LaunchOptions {};
    check("args: --no-window with a dump is fine", launch::parse(["--no-window", "--dump-frame", "x.png"], o) == "" && o.dump_path == "x.png");

    var long: u8[>..] = [];
    long.resize(HOST_PATH_BYTES + 1, 'a');
    var list: const u8[:][>..] = [];
    list.push(long[..]);
    o = LaunchOptions {};
    check("args: a path that does not fit is refused", launch::parse(list, o) == "the disk image path is too long\n");
}

// ADPCM (MSM6258) のデコーダ。
var g_adpcm = X68kADPCM {};

fn test_adpcm() {
    // 4 ビットのデータ 1 個の変化量: 符号と、ステップ幅の 1 + 1/2 + 1/4 + 1/8 倍
    check("adpcm: the smallest step", adpcm::delta(0, 0) == 2 && adpcm::delta(0, 8) == -2);
    check("adpcm: every bit at the first step", adpcm::delta(0, 7) == 30 && adpcm::delta(0, 15) == -30);
    check("adpcm: every bit at the last step", adpcm::delta(48, 7) == 2910);
    check("adpcm: small data lowers the step, not below 0", adpcm::next_step(0, 3) == 0 && adpcm::next_step(5, 1) == 4);
    check("adpcm: large data raises the step, not above 48", adpcm::next_step(10, 7) == 18 && adpcm::next_step(45, 15) == 48);

    g_adpcm = X68kADPCM {};
    check("adpcm: idle status", g_adpcm.read(0xE92001) == 0x40);
    g_adpcm.write(0xE92003, 0x77);
    check("adpcm: data while stopped is ignored", g_adpcm.empty() && g_adpcm.level == 0);
    g_adpcm.write(0xE92001, 2);
    check("adpcm: playing status", g_adpcm.read(0xE92001) == 0xC0 && g_adpcm.playing);
    g_adpcm.write(0xE92003, 0x77);
    // 下位 4 ビットが先: 7 で +30、ステップ 0 → 8 (幅 34)。次の 7 で +34 * 15 / 8 = +63、ステップ 16
    check("adpcm: two nibbles move the level up", g_adpcm.level == 30 + 63 && g_adpcm.step == 16);
    check("adpcm: samples reach the ring", !g_adpcm.empty());

    // 出力側: たまっているぶんを読み終えたら、最後の値から 0 へ 1 ずつ戻る
    var guard_count = 0;
    while !g_adpcm.empty() && guard_count < 100000 { g_adpcm.next_sample(); guard_count += 1; }
    let held = g_adpcm.held_r;
    g_adpcm.next_sample();
    check("adpcm: with no data the output decays toward 0", g_adpcm.held_r == held - 1 || held == 0);

    // パン: bit 0 で右、bit 1 で左を切る。bit 2-3 が変わるとサンプリングの速さが変わる
    g_adpcm = X68kADPCM {};
    g_adpcm.set_pan(0x0B);
    check("adpcm: the reset pan keeps the default rate", g_adpcm.clock_rate == 187500);
    g_adpcm.set_pan(0x01);
    check("adpcm: pan bits 2-3 choose the divider", g_adpcm.clock_rate == 93750);
    g_adpcm.set_clock(4);
    check("adpcm: the OPM CT1 bit halves the clock", g_adpcm.clock_rate == 46875);
    g_adpcm.write(0xE92001, 2);
    g_adpcm.write(0xE92003, 0x07);
    let wr = g_adpcm.wr;
    check("adpcm: right muted, left kept", wr > 0 && g_adpcm.right[wr - 1] == 0 && g_adpcm.left[wr - 1] != 0);

    // DMA の要求: たまっている量が尽きる頃合いの回数だけ返す
    g_adpcm = X68kADPCM {};
    check("adpcm: a short time asks for nothing", g_adpcm.pre_update(10) == 0);
    check("adpcm: an empty buffer asks once per unit of time", g_adpcm.pre_update(2000) > 0);
}

// YM2151 (x68k_opm)。fmgen と出力が一致することは別の突き合わせで確かめてあるので、
// ここでは表と、レジスタから見える振る舞いを見る。
var g_fm = X68kOPM {};

fn fm_write(reg: u8, val: u8) {
    g_fm.write_io(0, reg);
    g_fm.write_io(1, val);
}

fn test_opm() {
    g_fm.power_on();
    g_fm.machine_reset();
    // 表: 対数→線形の先頭は 2^13、正弦波の先頭は 1/4 周期の最小値。値は fmgen の表と同じ
    check("opm: log table starts at 2^13", opm::g_cl[0] == 8192 && opm::g_cl[1] == -8192 && opm::g_cl[512] == 4096);
    // sin(pi / 1024) の対数: 2138。下位ビットが符号 (後半は負)
    check("opm: sine table", opm::g_sine[0] == 4276 && opm::g_sine[512] == 4277);
    // 16384 * 10^(-16 / 40)。fmgen の音量は 0.5 dB 単位で、-16 が px68k の既定の -8 dB
    check("opm: the default volume is -8 dB", g_fm.fmvolume == 6522);
    check("opm: idle status", g_fm.read_status() == 0 && !g_fm.irq);

    // 何も鳴っていなければ、渡したサンプルはそのまま
    var buf: i16[512] = [100; 512];
    g_fm.mix(buf[..]);
    check("opm: silence leaves the samples alone", buf[0] == 100 && buf[511] == 100);

    // チャンネル 0 に、OP4 だけを出すアルゴリズム 7 の音を作ってキーオンする
    fm_write(0x20, 0xC7);       // 左右とも、FB 0、アルゴリズム 7
    fm_write(0x28, 0x4A);       // KC: オクターブ 4、A
    fm_write(0x78, 0x00);       // OP4 (C2) の TL = 0 (最大)
    fm_write(0x98, 0x1F);       // AR 最大
    fm_write(0xF8, 0x0F);       // D1L 0、RR 最大
    fm_write(0x08, 0x40);       // チャンネル 0 の C2 をキーオン
    buf = [0; 512];
    g_fm.mix(buf[..]);
    var peak: i32 = 0;
    for v in buf { peak = max(peak, abs(v as i32)); }
    check("opm: a keyed-on voice makes sound", peak > 1000);
    check("opm: both sides get it", buf[100] == buf[101]);
    fm_write(0x20, 0x47);       // 右だけ (bit 6)
    buf = [0; 512];
    g_fm.mix(buf[..]);
    check("opm: pan to one side", buf[100] != 0 && buf[101] == 0);

    // タイマー A: 周期 1024 - 1023 = 1 単位。動かして、割り込みを許すと要求が立つ
    fm_write(0x10, 0xFF);
    fm_write(0x11, 0x03);
    fm_write(0x14, 0x05);       // タイマー A を動かし、満了でステータスを立てる
    g_fm.count2(1000);
    check("opm: timer A sets its status bit and raises the interrupt", (g_fm.read_status() & 1) != 0 && g_fm.irq);
    fm_write(0x14, 0x15);       // bit 4 でステータスを落とす
    check("opm: the status bit is cleared by register 0x14", (g_fm.read_status() & 1) == 0);

    g_fm.machine_reset();
    buf = [0; 512];
    g_fm.mix(buf[..]);
    check("opm: a reset silences every voice", buf[100] == 0 && g_fm.read_status() == 0);
}

// ファイルの書き出し (x68k_output)。値は各形式の仕様と、元の C の実装が書いたファイルで確かめた。
fn le32(b: u8[>..]&, at: i64) -> u32 {
    let lo: u32 = b[at];
    let b1: u32 = b[at + 1];
    let b2: u32 = b[at + 2];
    let b3: u32 = b[at + 3];
    return lo | (b1 << 8) | (b2 << 16) | (b3 << 24);
}

fn test_output() {
    // CRC-32 の標準の検査値と、PNG の IEND の CRC
    check("output: CRC-32 of 123456789", ~output::crc_update(0xFFFFFFFF, "123456789") == 0xCBF43926);
    check("output: CRC-32 of IEND", ~output::crc_update(0xFFFFFFFF, "IEND") == 0xAE426082);

    let px: u32[6] = [0xFF102030, 0xFF405060, 0xFF708090, 0xFFA0B0C0, 0xFFD0E0F0, 0xFF000000];
    var bmp: u8[>..] = [];
    output::bmp_bytes(px[..], 3, 2, bmp);
    check("output: BMP size and header", bmp.len == 54 + 24 && bmp[0] == 'B' && bmp[1] == 'M' && le32(bmp, 2) == 78 && le32(bmp, 10) == 54);
    check("output: BMP width and height", le32(bmp, 18) == 3 && le32(bmp, 22) == 2);
    // 下の行が先。画素は B, G, R, A の順
    check("output: BMP rows bottom up", bmp[54] == 0xC0 && bmp[55] == 0xB0 && bmp[56] == 0xA0 && bmp[54 + 12] == 0x30);

    var png: u8[>..] = [];
    output::png_bytes(px[..], 3, 2, png);
    check("output: PNG signature", png.len > 33 && png[0] == 137 && png[1] == 'P' && png[2] == 'N' && png[3] == 'G');
    check("output: PNG IHDR", png[12] == 'I' && png[15] == 'R' && png[19] == 3 && png[23] == 2 && png[24] == 8 && png[25] == 2);
    check("output: PNG ends with IEND", png[png.len - 8] == 'I' && png[png.len - 5] == 'D' && png[png.len - 1] == 0x82);

    let samples: i16[4] = [1, -1, 32767, -32768];
    var wav: u8[>..] = [];
    output::wav_bytes(samples[..], wav);
    check("output: WAV header", wav.len == 44 + 8 && wav[0] == 'R' && wav[8] == 'W' && le32(wav, 4) == 36 + 8 && le32(wav, 24) == 44100 && le32(wav, 40) == 8);
    check("output: WAV samples little endian", wav[44] == 1 && wav[45] == 0 && wav[46] == 0xFF && wav[47] == 0xFF && wav[50] == 0x00 && wav[51] == 0x80);

    output::capture_start();
    output::capture_push(samples[..]);
    output::capture_push(samples[..2]);
    let st = output::capture_status();
    check("output: capture counts stereo frames", st.active && st.frames == 3 && !st.truncated);
    let ok, frames, trunc, peak, silent = output::capture_stop("");
    check("output: stop without a path reports the take", ok && frames == 3 && !trunc && peak == 32768 && !silent);
    // 始め直すとサンプル数は 0 に戻る。1 サンプルも無ければ、元の C と同じくファイルを作らずに失敗する
    output::capture_start();
    let ok2, frames2, _, _, _ = output::capture_stop("never_written.wav");
    check("output: a path with no samples fails, as before", !ok2 && frames2 == 0);
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
    test_disasm();
    test_state_file();
    test_disk_paths();
    test_disk_xdf();
    test_disk_dim();
    test_disk_d88();
    test_disk_hdd_and_media();
    test_io_latches();
    test_mcp_args();
    test_launch_args();
    test_adpcm();
    test_opm();
    test_output();
    print(g_checks - g_failures, " / ", g_checks, " checks passed");
    if g_failures > 0 { exit(1); }
}
