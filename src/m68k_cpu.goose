// Motorola 68000 CPU 構造体 & フラグヘルパー in Goose

import .m68k_types;

struct M68kCPU {
    d: u32[8] = [0; 8],     // D0 - D7
    a: u32[8] = [0; 8],     // A0 - A7 (A7 is current SP)
    pc: u32 = 0,            // Program Counter
    sr: u16 = 0x2700,       // Status Register (Supervisor Mode, Interrupt level 7)
    usp: u32 = 0,           // User Stack Pointer
    ssp: u32 = 0,           // Supervisor Stack Pointer
    halted: bool = false,
}

fn cpu_flag_c(cpu: M68kCPU&) -> bool { (cpu.sr & SR_C) != 0 }
fn cpu_flag_v(cpu: M68kCPU&) -> bool { (cpu.sr & SR_V) != 0 }
fn cpu_flag_z(cpu: M68kCPU&) -> bool { (cpu.sr & SR_Z) != 0 }
fn cpu_flag_n(cpu: M68kCPU&) -> bool { (cpu.sr & SR_N) != 0 }
fn cpu_flag_x(cpu: M68kCPU&) -> bool { (cpu.sr & SR_X) != 0 }
fn cpu_is_supervisor(cpu: M68kCPU&) -> bool { (cpu.sr & SR_S) != 0 }

// SR の割り込みマスク (0..7)
fn cpu_int_mask(cpu: M68kCPU&) -> i32 {
    return (cpu.sr >> 8) & 7;
}

fn cpu_set_sr(cpu: M68kCPU&, val: u16) {
    let new_sr = val & 0xA71F; // M68000 有効ビットマスク
    let was_super = cpu_is_supervisor(cpu);
    let is_super = (new_sr & SR_S) != 0;
    if was_super && !is_super {
        cpu.ssp = cpu.a[REG_A7];
        cpu.a[REG_A7] = cpu.usp;
    } else if !was_super && is_super {
        cpu.usp = cpu.a[REG_A7];
        cpu.a[REG_A7] = cpu.ssp;
    }
    cpu.sr = new_sr;
}

fn cpu_set_ccr(cpu: M68kCPU&, val: u8) {
    cpu.sr = (cpu.sr & 0xFFE0) | ((val as! u16) & 0x001F);
}

// オペランドサイズは 1 = byte, 2 = word, 4 = long。値は u32 で受け、下位 size バイトだけを見る。
fn size_msb(size: i32) -> u32 {
    return if size == 1 { 0x80 } else if size == 2 { 0x8000 } else { 0x80000000 };
}

fn size_mask(size: i32) -> u32 {
    return if size == 1 { 0xFF } else if size == 2 { 0xFFFF } else { 0xFFFFFFFF };
}

fn cpu_put_flag(cpu: M68kCPU&, flag: u16, on: bool) {
    if on { cpu.sr |= flag; } else { cpu.sr &= ~flag; }
}

// N と Z を結果から決め、V と C を落とす (MOVE, 論理演算, TST など)。
fn cpu_set_nz(cpu: M68kCPU&, size: i32, val: u32) {
    cpu_put_flag(cpu, SR_N, (val & size_msb(size)) != 0);
    cpu_put_flag(cpu, SR_Z, (val & size_mask(size)) == 0);
    cpu.sr &= ~(SR_V | SR_C);
}

// N と Z を結果から決め、V だけを落とす。C は呼び出し側が決める (シフトなど)。
fn cpu_set_nz_only(cpu: M68kCPU&, size: i32, val: u32) {
    cpu_put_flag(cpu, SR_N, (val & size_msb(size)) != 0);
    cpu_put_flag(cpu, SR_Z, (val & size_mask(size)) == 0);
    cpu.sr &= ~SR_V;
}

// 加算 res = dst + src のオーバーフローとキャリー
fn add_overflow(sm: bool, dm: bool, rm: bool) -> bool { return (sm && dm && !rm) || (!sm && !dm && rm); }
fn add_carry(sm: bool, dm: bool, rm: bool) -> bool { return (sm && dm) || (!rm && (sm || dm)); }

// 減算 res = dst - src のオーバーフローとボロー
fn sub_overflow(sm: bool, dm: bool, rm: bool) -> bool { return (!sm && dm && !rm) || (sm && !dm && rm); }
fn sub_borrow(sm: bool, dm: bool, rm: bool) -> bool { return (sm && !dm) || (rm && (!dm || sm)); }

// ADD / ADDI / ADDQ: X N Z V C をすべて更新する。
fn cpu_flags_add(cpu: M68kCPU&, size: i32, src: u32, dst: u32, res: u32) {
    let msb = size_msb(size);
    let sm = (src & msb) != 0;
    let dm = (dst & msb) != 0;
    let rm = (res & msb) != 0;
    let c = add_carry(sm, dm, rm);
    cpu_put_flag(cpu, SR_N, rm);
    cpu_put_flag(cpu, SR_Z, (res & size_mask(size)) == 0);
    cpu_put_flag(cpu, SR_V, add_overflow(sm, dm, rm));
    cpu_put_flag(cpu, SR_C | SR_X, c);
}

// SUB / SUBI / SUBQ (update_x = true) と CMP / CMPI / CMPA / CMPM (false)。res = dst - src。
fn cpu_flags_sub(cpu: M68kCPU&, size: i32, src: u32, dst: u32, res: u32, update_x: bool) {
    let msb = size_msb(size);
    let sm = (src & msb) != 0;
    let dm = (dst & msb) != 0;
    let rm = (res & msb) != 0;
    let c = sub_borrow(sm, dm, rm);
    cpu_put_flag(cpu, SR_N, rm);
    cpu_put_flag(cpu, SR_Z, (res & size_mask(size)) == 0);
    cpu_put_flag(cpu, SR_V, sub_overflow(sm, dm, rm));
    cpu_put_flag(cpu, SR_C, c);
    if update_x { cpu_put_flag(cpu, SR_X, c); }
}

// ADDX: Z は結果が 0 以外のときだけ落とす (多倍長演算のため 0 では変えない)。
fn cpu_flags_addx(cpu: M68kCPU&, size: i32, src: u32, dst: u32, res: u32) {
    let msb = size_msb(size);
    let sm = (src & msb) != 0;
    let dm = (dst & msb) != 0;
    let rm = (res & msb) != 0;
    cpu_put_flag(cpu, SR_N, rm);
    if (res & size_mask(size)) != 0 { cpu.sr &= ~SR_Z; }
    cpu_put_flag(cpu, SR_V, add_overflow(sm, dm, rm));
    cpu_put_flag(cpu, SR_C | SR_X, add_carry(sm, dm, rm));
}

// SUBX: Z の扱いは ADDX と同じ。
fn cpu_flags_subx(cpu: M68kCPU&, size: i32, src: u32, dst: u32, res: u32) {
    let msb = size_msb(size);
    let sm = (src & msb) != 0;
    let dm = (dst & msb) != 0;
    let rm = (res & msb) != 0;
    cpu_put_flag(cpu, SR_N, rm);
    if (res & size_mask(size)) != 0 { cpu.sr &= ~SR_Z; }
    cpu_put_flag(cpu, SR_V, sub_overflow(sm, dm, rm));
    cpu_put_flag(cpu, SR_C | SR_X, sub_borrow(sm, dm, rm));
}

// 条件コード判定 (Bcc, DBcc 等)
fn cpu_check_condition(cpu: M68kCPU&, cond: i32) -> bool {
    let c = cpu_flag_c(cpu);
    let v = cpu_flag_v(cpu);
    let z = cpu_flag_z(cpu);
    let n = cpu_flag_n(cpu);
    match cond & 15 {
        0 => true,           // T
        1 => false,          // F
        2 => !c && !z,       // HI
        3 => c || z,         // LS
        4 => !c,             // CC
        5 => c,              // CS
        6 => !z,             // NE
        7 => z,              // EQ
        8 => !v,             // VC
        9 => v,              // VS
        10 => !n,            // PL
        11 => n,             // MI
        12 => n == v,        // GE
        13 => n != v,        // LT
        14 => !z && n == v,  // GT
        _ => z || n != v,    // LE
    }
}
