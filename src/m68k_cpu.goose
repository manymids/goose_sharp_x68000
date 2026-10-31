// Motorola 68000 CPU 構造体 & フラグヘルパー in Goose

import std;
import .m68k_types;

struct M68kCPU {
    d: u32[8] = [0; 8],     // D0 - D7
    a: u32[8] = [0; 8],     // A0 - A7 (A7 is current SP)
    pc: u32 = 0,            // Program Counter
    sr: u16 = 0x2700,       // Status Register (Supervisor Mode, Interrupt level 7)
    usp: u32 = 0,           // User Stack Pointer
    ssp: u32 = 0,           // Supervisor Stack Pointer
    halted: bool = false
}

fn cpu_flag_c(cpu: M68kCPU&) -> bool { (cpu.sr & (SR_C as! u16)) != 0 }
fn cpu_flag_v(cpu: M68kCPU&) -> bool { (cpu.sr & (SR_V as! u16)) != 0 }
fn cpu_flag_z(cpu: M68kCPU&) -> bool { (cpu.sr & (SR_Z as! u16)) != 0 }
fn cpu_flag_n(cpu: M68kCPU&) -> bool { (cpu.sr & (SR_N as! u16)) != 0 }
fn cpu_flag_x(cpu: M68kCPU&) -> bool { (cpu.sr & (SR_X as! u16)) != 0 }
fn cpu_is_supervisor(cpu: M68kCPU&) -> bool { (cpu.sr & (SR_S as! u16)) != 0 }

fn cpu_set_sr(cpu: M68kCPU&, val: u16) {
    let new_sr = val & 0xA71F; // M68000 有効ビットマスク
    let was_super = cpu_is_supervisor(cpu);
    let is_super = (new_sr & (SR_S as! u16)) != 0;
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

fn cpu_set_nz8(cpu: M68kCPU&, val: u8) {
    if (val & 0x80) != 0 { cpu.sr |= (SR_N as! u16); } else { cpu.sr &= ~(SR_N as! u16); }
    if val == 0 { cpu.sr |= (SR_Z as! u16); } else { cpu.sr &= ~(SR_Z as! u16); }
    cpu.sr &= ~((SR_V | SR_C) as! u16);
}

fn cpu_set_nz8_only(cpu: M68kCPU&, val: u8) {
    if (val & 0x80) != 0 { cpu.sr |= (SR_N as! u16); } else { cpu.sr &= ~(SR_N as! u16); }
    if val == 0 { cpu.sr |= (SR_Z as! u16); } else { cpu.sr &= ~(SR_Z as! u16); }
    cpu.sr &= ~(SR_V as! u16);
}

fn cpu_set_nz16(cpu: M68kCPU&, val: u16) {
    if (val & 0x8000) != 0 { cpu.sr |= (SR_N as! u16); } else { cpu.sr &= ~(SR_N as! u16); }
    if val == 0 { cpu.sr |= (SR_Z as! u16); } else { cpu.sr &= ~(SR_Z as! u16); }
    cpu.sr &= ~((SR_V | SR_C) as! u16);
}

fn cpu_set_nz16_only(cpu: M68kCPU&, val: u16) {
    if (val & 0x8000) != 0 { cpu.sr |= (SR_N as! u16); } else { cpu.sr &= ~(SR_N as! u16); }
    if val == 0 { cpu.sr |= (SR_Z as! u16); } else { cpu.sr &= ~(SR_Z as! u16); }
    cpu.sr &= ~(SR_V as! u16);
}

fn cpu_set_nz32(cpu: M68kCPU&, val: u32) {
    if (val & 0x80000000) != 0 { cpu.sr |= (SR_N as! u16); } else { cpu.sr &= ~(SR_N as! u16); }
    if val == 0 { cpu.sr |= (SR_Z as! u16); } else { cpu.sr &= ~(SR_Z as! u16); }
    cpu.sr &= ~((SR_V | SR_C) as! u16);
}

fn cpu_set_nz32_only(cpu: M68kCPU&, val: u32) {
    if (val & 0x80000000) != 0 { cpu.sr |= (SR_N as! u16); } else { cpu.sr &= ~(SR_N as! u16); }
    if val == 0 { cpu.sr |= (SR_Z as! u16); } else { cpu.sr &= ~(SR_Z as! u16); }
    cpu.sr &= ~(SR_V as! u16);
}

// 加算フラグ計算 (ADD / ADDI / ADDQ / ADDX)
fn cpu_flags_add8(cpu: M68kCPU&, src: u8, dst: u8, res: u8) {
    let sm = (src & 0x80) != 0;
    let dm = (dst & 0x80) != 0;
    let rm = (res & 0x80) != 0;
    let v = (sm && dm && !rm) || (!sm && !dm && rm);
    let c = (sm && dm) || (!rm && (sm || dm));
    let z = (res == 0);

    cpu.sr &= ~((SR_X | SR_N | SR_Z | SR_V | SR_C) as! u16);
    if rm { cpu.sr |= (SR_N as! u16); }
    if z { cpu.sr |= (SR_Z as! u16); }
    if v { cpu.sr |= (SR_V as! u16); }
    if c { cpu.sr |= ((SR_C | SR_X) as! u16); }
}

fn cpu_flags_add16(cpu: M68kCPU&, src: u16, dst: u16, res: u16) {
    let sm = (src & 0x8000) != 0;
    let dm = (dst & 0x8000) != 0;
    let rm = (res & 0x8000) != 0;
    let v = (sm && dm && !rm) || (!sm && !dm && rm);
    let c = (sm && dm) || (!rm && (sm || dm));
    let z = (res == 0);

    cpu.sr &= ~((SR_X | SR_N | SR_Z | SR_V | SR_C) as! u16);
    if rm { cpu.sr |= (SR_N as! u16); }
    if z { cpu.sr |= (SR_Z as! u16); }
    if v { cpu.sr |= (SR_V as! u16); }
    if c { cpu.sr |= ((SR_C | SR_X) as! u16); }
}

fn cpu_flags_add32(cpu: M68kCPU&, src: u32, dst: u32, res: u32) {
    let sm = (src & 0x80000000) != 0;
    let dm = (dst & 0x80000000) != 0;
    let rm = (res & 0x80000000) != 0;
    let v = (sm && dm && !rm) || (!sm && !dm && rm);
    let c = (sm && dm) || (!rm && (sm || dm));
    let z = (res == 0);

    cpu.sr &= ~((SR_X | SR_N | SR_Z | SR_V | SR_C) as! u16);
    if rm { cpu.sr |= (SR_N as! u16); }
    if z { cpu.sr |= (SR_Z as! u16); }
    if v { cpu.sr |= (SR_V as! u16); }
    if c { cpu.sr |= ((SR_C | SR_X) as! u16); }
}

// 減算フラグ計算 (SUB / SUBI / SUBQ / SUBX / CMP / CMPI / CMPA)
// res = dst - src
fn cpu_flags_sub8(cpu: M68kCPU&, src: u8, dst: u8, res: u8, update_x: bool) {
    let sm = (src & 0x80) != 0;
    let dm = (dst & 0x80) != 0;
    let rm = (res & 0x80) != 0;
    let v = (!sm && dm && !rm) || (sm && !dm && rm);
    let c = (sm && !dm) || (rm && (!dm || sm));
    let z = (res == 0);

    if update_x {
        cpu.sr &= ~((SR_X | SR_N | SR_Z | SR_V | SR_C) as! u16);
        if c { cpu.sr |= (SR_X as! u16); }
    } else {
        cpu.sr &= ~((SR_N | SR_Z | SR_V | SR_C) as! u16);
    }
    if rm { cpu.sr |= (SR_N as! u16); }
    if z { cpu.sr |= (SR_Z as! u16); }
    if v { cpu.sr |= (SR_V as! u16); }
    if c { cpu.sr |= (SR_C as! u16); }
}

fn cpu_flags_sub16(cpu: M68kCPU&, src: u16, dst: u16, res: u16, update_x: bool) {
    let sm = (src & 0x8000) != 0;
    let dm = (dst & 0x8000) != 0;
    let rm = (res & 0x8000) != 0;
    let v = (!sm && dm && !rm) || (sm && !dm && rm);
    let c = (sm && !dm) || (rm && (!dm || sm));
    let z = (res == 0);

    if update_x {
        cpu.sr &= ~((SR_X | SR_N | SR_Z | SR_V | SR_C) as! u16);
        if c { cpu.sr |= (SR_X as! u16); }
    } else {
        cpu.sr &= ~((SR_N | SR_Z | SR_V | SR_C) as! u16);
    }
    if rm { cpu.sr |= (SR_N as! u16); }
    if z { cpu.sr |= (SR_Z as! u16); }
    if v { cpu.sr |= (SR_V as! u16); }
    if c { cpu.sr |= (SR_C as! u16); }
}

fn cpu_flags_sub32(cpu: M68kCPU&, src: u32, dst: u32, res: u32, update_x: bool) {
    let sm = (src & 0x80000000) != 0;
    let dm = (dst & 0x80000000) != 0;
    let rm = (res & 0x80000000) != 0;
    let v = (!sm && dm && !rm) || (sm && !dm && rm);
    let c = (sm && !dm) || (rm && (!dm || sm));
    let z = (res == 0);

    if update_x {
        cpu.sr &= ~((SR_X | SR_N | SR_Z | SR_V | SR_C) as! u16);
        if c { cpu.sr |= (SR_X as! u16); }
    } else {
        cpu.sr &= ~((SR_N | SR_Z | SR_V | SR_C) as! u16);
    }
    if rm { cpu.sr |= (SR_N as! u16); }
    if z { cpu.sr |= (SR_Z as! u16); }
    if v { cpu.sr |= (SR_V as! u16); }
    if c { cpu.sr |= (SR_C as! u16); }
}

fn cpu_flags_addx8(cpu: M68kCPU&, src: u8, dst: u8, res: u8) {
    let sm = (src & 0x80) != 0;
    let dm = (dst & 0x80) != 0;
    let rm = (res & 0x80) != 0;
    let v = (sm && dm && !rm) || (!sm && !dm && rm);
    let c = (sm && dm) || (!rm && (sm || dm));

    cpu.sr &= ~((SR_X | SR_N | SR_V | SR_C) as! u16);
    if rm { cpu.sr |= (SR_N as! u16); }
    if res != 0 { cpu.sr &= ~(SR_Z as! u16); }
    if v { cpu.sr |= (SR_V as! u16); }
    if c { cpu.sr |= ((SR_C | SR_X) as! u16); }
}

fn cpu_flags_addx16(cpu: M68kCPU&, src: u16, dst: u16, res: u16) {
    let sm = (src & 0x8000) != 0;
    let dm = (dst & 0x8000) != 0;
    let rm = (res & 0x8000) != 0;
    let v = (sm && dm && !rm) || (!sm && !dm && rm);
    let c = (sm && dm) || (!rm && (sm || dm));

    cpu.sr &= ~((SR_X | SR_N | SR_V | SR_C) as! u16);
    if rm { cpu.sr |= (SR_N as! u16); }
    if res != 0 { cpu.sr &= ~(SR_Z as! u16); }
    if v { cpu.sr |= (SR_V as! u16); }
    if c { cpu.sr |= ((SR_C | SR_X) as! u16); }
}

fn cpu_flags_addx32(cpu: M68kCPU&, src: u32, dst: u32, res: u32) {
    let sm = (src & 0x80000000) != 0;
    let dm = (dst & 0x80000000) != 0;
    let rm = (res & 0x80000000) != 0;
    let v = (sm && dm && !rm) || (!sm && !dm && rm);
    let c = (sm && dm) || (!rm && (sm || dm));

    cpu.sr &= ~((SR_X | SR_N | SR_V | SR_C) as! u16);
    if rm { cpu.sr |= (SR_N as! u16); }
    if res != 0 { cpu.sr &= ~(SR_Z as! u16); }
    if v { cpu.sr |= (SR_V as! u16); }
    if c { cpu.sr |= ((SR_C | SR_X) as! u16); }
}

fn cpu_flags_subx8(cpu: M68kCPU&, src: u8, dst: u8, res: u8) {
    let sm = (src & 0x80) != 0;
    let dm = (dst & 0x80) != 0;
    let rm = (res & 0x80) != 0;
    let v = (!sm && dm && !rm) || (sm && !dm && rm);
    let c = (sm && !dm) || (rm && (!dm || sm));

    cpu.sr &= ~((SR_X | SR_N | SR_V | SR_C) as! u16);
    if rm { cpu.sr |= (SR_N as! u16); }
    if res != 0 { cpu.sr &= ~(SR_Z as! u16); }
    if v { cpu.sr |= (SR_V as! u16); }
    if c { cpu.sr |= ((SR_C | SR_X) as! u16); }
}

fn cpu_flags_subx16(cpu: M68kCPU&, src: u16, dst: u16, res: u16) {
    let sm = (src & 0x8000) != 0;
    let dm = (dst & 0x8000) != 0;
    let rm = (res & 0x8000) != 0;
    let v = (!sm && dm && !rm) || (sm && !dm && rm);
    let c = (sm && !dm) || (rm && (!dm || sm));

    cpu.sr &= ~((SR_X | SR_N | SR_V | SR_C) as! u16);
    if rm { cpu.sr |= (SR_N as! u16); }
    if res != 0 { cpu.sr &= ~(SR_Z as! u16); }
    if v { cpu.sr |= (SR_V as! u16); }
    if c { cpu.sr |= ((SR_C | SR_X) as! u16); }
}

fn cpu_flags_subx32(cpu: M68kCPU&, src: u32, dst: u32, res: u32) {
    let sm = (src & 0x80000000) != 0;
    let dm = (dst & 0x80000000) != 0;
    let rm = (res & 0x80000000) != 0;
    let v = (!sm && dm && !rm) || (sm && !dm && rm);
    let c = (sm && !dm) || (rm && (!dm || sm));

    cpu.sr &= ~((SR_X | SR_N | SR_V | SR_C) as! u16);
    if rm { cpu.sr |= (SR_N as! u16); }
    if res != 0 { cpu.sr &= ~(SR_Z as! u16); }
    if v { cpu.sr |= (SR_V as! u16); }
    if c { cpu.sr |= ((SR_C | SR_X) as! u16); }
}

// 条件コード判定 (Bcc, DBcc 等)
fn cpu_check_condition(cpu: M68kCPU&, cond: i32) -> bool {
    let c = cpu_flag_c(cpu);
    let v = cpu_flag_v(cpu);
    let z = cpu_flag_z(cpu);
    let n = cpu_flag_n(cpu);

    if cond == 0 { return true; }              // T (True)
    if cond == 1 { return false; }             // F (False)
    if cond == 2 { return !c && !z; }          // HI
    if cond == 3 { return c || z; }            // LS
    if cond == 4 { return !c; }                // CC
    if cond == 5 { return c; }                 // CS
    if cond == 6 { return !z; }                // NE
    if cond == 7 { return z; }                 // EQ
    if cond == 8 { return !v; }                // VC
    if cond == 9 { return v; }                 // VS
    if cond == 10 { return !n; }               // PL
    if cond == 11 { return n; }                // MI
    if cond == 12 { return (n && v) || (!n && !v); } // GE
    if cond == 13 { return (n && !v) || (!n && v); } // LT
    if cond == 14 { return (n && v && !z) || (!n && !v && !z); } // GT
    if cond == 15 { return z || (n && !v) || (!n && v); }        // LE
    return false;
}
