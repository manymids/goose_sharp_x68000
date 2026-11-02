// Motorola 68000 命令デコード & 実行エンジン in Goose (Approach 1 完全実装)

import std;
import os;
import .x68k_bridge;
import .m68k_types;
import .m68k_cpu;
import .m68k_mmu;

var g_ret_trace_count: i32 = 0;

// PC から次の 16bit ワードをフェッチ
fn fetch16(cpu: M68kCPU&, mmu: M68kMMU&) -> u16 {
    let val = mmu_read16(mmu, cpu.pc);
    cpu.pc += 2;
    return val;
}

// PC から次の 32bit ロングワードをフェッチ
fn fetch32(cpu: M68kCPU&, mmu: M68kMMU&) -> u32 {
    let hi = fetch16(cpu, mmu) as! u32;
    let lo = fetch16(cpu, mmu) as! u32;
    return (hi << 16) | lo;
}

// スタック push / pop
fn push16(cpu: M68kCPU&, mmu: M68kMMU&, val: u16) {
    cpu.a[REG_A7] -= 2;
    mmu_write16(mmu, cpu.a[REG_A7], val);
}

fn push32(cpu: M68kCPU&, mmu: M68kMMU&, val: u32) {
    cpu.a[REG_A7] -= 4;
    mmu_write32(mmu, cpu.a[REG_A7], val);
}

fn pop16(cpu: M68kCPU&, mmu: M68kMMU&) -> u16 {
    let val = mmu_read16(mmu, cpu.a[REG_A7]);
    cpu.a[REG_A7] += 2;
    return val;
}

fn pop32(cpu: M68kCPU&, mmu: M68kMMU&) -> u32 {
    let val = mmu_read32(mmu, cpu.a[REG_A7]);
    cpu.a[REG_A7] += 4;
    return val;
}

// EA (Effective Address) アドレス計算 (サイズ: 1=byte, 2=word, 4=long)
fn ea_calc_addr(cpu: M68kCPU&, mmu: M68kMMU&, mode: i32, reg: i32, size: i32) -> u32 {
    if mode == 2 { // (An)
        return cpu.a[reg];
    }
    if mode == 3 { // (An)+
        let addr = cpu.a[reg];
        let delta = if reg == 7 && size == 1 { 2 } else { size };
        cpu.a[reg] += delta as! u32;
        return addr;
    }
    if mode == 4 { // -(An)
        let delta = if reg == 7 && size == 1 { 2 } else { size };
        cpu.a[reg] -= delta as! u32;
        return cpu.a[reg];
    }
    if mode == 5 { // (d16, An)
        let d16 = fetch16(cpu, mmu) as! i16;
        return ((cpu.a[reg] as! i32) + (d16 as! i32)) as! u32;
    }
    if mode == 6 { // (d8, An, Xn)
        let ext = fetch16(cpu, mmu);
        let d8 = (ext & 0xFF) as! i8;
        let xreg = ((ext >> 12) & 0x07) as! i32;
        let is_a = (ext & 0x8000) != 0;
        let is_long = (ext & 0x0800) != 0;
        var xval: i32 = 0;
        if is_a {
            xval = if is_long { cpu.a[xreg] as! i32 } else { (cpu.a[xreg] as! i16) as! i32 };
        } else {
            xval = if is_long { cpu.d[xreg] as! i32 } else { (cpu.d[xreg] as! i16) as! i32 };
        }
        return ((cpu.a[reg] as! i32) + (d8 as! i32) + xval) as! u32;
    }
    if mode == 7 {
        if reg == 0 { // (xxx).W
            // 符号拡張した 32bit を返す。バスは mmu 側で 24bit に切る。
            // ここで切ると PEA/LEA が 0xFFFFFFFF ではなく 0x00FFFFFF になる。
            let w = fetch16(cpu, mmu) as! i16;
            return (w as! i32) as! u32;
        }
        if reg == 1 { // (xxx).L
            return fetch32(cpu, mmu);
        }
        if reg == 2 { // (d16, PC)
            let pc_base = cpu.pc;
            let d16 = fetch16(cpu, mmu) as! i16;
            return ((pc_base as! i32) + (d16 as! i32)) as! u32;
        }
        if reg == 3 { // (d8, PC, Xn)
            let pc_base = cpu.pc;
            let ext = fetch16(cpu, mmu);
            let d8 = (ext & 0xFF) as! i8;
            let xreg = ((ext >> 12) & 0x07) as! i32;
            let is_a = (ext & 0x8000) != 0;
            let is_long = (ext & 0x0800) != 0;
            var xval: i32 = 0;
            if is_a {
                xval = if is_long { cpu.a[xreg] as! i32 } else { (cpu.a[xreg] as! i16) as! i32 };
            } else {
                xval = if is_long { cpu.d[xreg] as! i32 } else { (cpu.d[xreg] as! i16) as! i32 };
            }
            return ((pc_base as! i32) + (d8 as! i32) + xval) as! u32;
        }
    }
    return 0;
}

struct EAResult {
    addr: u32,
    val: u32,
}

// Read-Modify-Write (RMW) 用の EA 読み出し (アドレス計算を 1 度だけ行う)
fn ea_read_for_rmw(cpu: M68kCPU&, mmu: M68kMMU&, mode: i32, reg: i32, size: i32) -> EAResult {
    if mode == 0 { // Dn
        let v = if size == 1 { cpu.d[reg] & 0xFF }
                else if size == 2 { cpu.d[reg] & 0xFFFF }
                else { cpu.d[reg] };
        return EAResult { addr: 0, val: v };
    }
    if mode == 1 { // An
        let v = if size == 2 { ((cpu.a[reg] as! i16) as! i32) as! u32 }
                else { cpu.a[reg] };
        return EAResult { addr: 0, val: v };
    }
    let addr = ea_calc_addr(cpu, mmu, mode, reg, size);
    let v = if size == 1 { mmu_read8(mmu, addr) as! u32 }
            else if size == 2 { mmu_read16(mmu, addr) as! u32 }
            else { mmu_read32(mmu, addr) };
    return EAResult { addr: addr, val: v };
}

// Read-Modify-Write (RMW) 用の EA 書き込み (保持したアドレスに直接書き戻す)
fn ea_write_for_rmw(cpu: M68kCPU&, mmu: M68kMMU&, mode: i32, reg: i32, size: i32, addr: u32, val: u32) {
    if mode == 0 { // Dn
        if size == 1 {
            cpu.d[reg] = (cpu.d[reg] & 0xFFFFFF00) | (val & 0xFF);
        } else if size == 2 {
            cpu.d[reg] = (cpu.d[reg] & 0xFFFF0000) | (val & 0xFFFF);
        } else {
            cpu.d[reg] = val;
        }
        return;
    }
    if mode == 1 { // An
        if mmu.fault != 0 { return; }
        if size == 2 {
            cpu.a[reg] = ((val as! i16) as! i32) as! u32;
        } else {
            cpu.a[reg] = val;
        }
        return;
    }
    if size == 1 { mmu_write8(mmu, addr, (val & 0xFF) as! u8); }
    else if size == 2 { mmu_write16(mmu, addr, (val & 0xFFFF) as! u16); }
    else { mmu_write32(mmu, addr, val); }
}

// EA 読み出し
fn ea_read(cpu: M68kCPU&, mmu: M68kMMU&, mode: i32, reg: i32, size: i32) -> u32 {
    if mode == 0 { // Dn
        if size == 1 { return cpu.d[reg] & 0xFF; }
        if size == 2 { return cpu.d[reg] & 0xFFFF; }
        return cpu.d[reg];
    }
    if mode == 1 { // An
        if size == 2 { return ((cpu.a[reg] as! i16) as! i32) as! u32; }
        return cpu.a[reg];
    }
    if mode == 7 && reg == 4 { // Immediate #<data>
        if size == 1 { return (fetch16(cpu, mmu) & 0xFF) as! u32; }
        if size == 2 { return fetch16(cpu, mmu) as! u32; }
        return fetch32(cpu, mmu);
    }
    let addr = ea_calc_addr(cpu, mmu, mode, reg, size);
    if size == 1 { return mmu_read8(mmu, addr) as! u32; }
    if size == 2 { return mmu_read16(mmu, addr) as! u32; }
    return mmu_read32(mmu, addr);
}

// EA 書き込み
fn ea_write(cpu: M68kCPU&, mmu: M68kMMU&, mode: i32, reg: i32, size: i32, val: u32) {
    if mode == 0 { // Dn
        if size == 1 {
            cpu.d[reg] = (cpu.d[reg] & 0xFFFFFF00) | (val & 0xFF);
        } else if size == 2 {
            cpu.d[reg] = (cpu.d[reg] & 0xFFFF0000) | (val & 0xFFFF);
        } else {
            cpu.d[reg] = val;
        }
        return;
    }
    if mode == 1 { // An
        if mmu.fault != 0 { return; }
        if size == 2 {
            cpu.a[reg] = ((val as! i16) as! i32) as! u32;
        } else {
            cpu.a[reg] = val;
        }
        return;
    }
    let addr = ea_calc_addr(cpu, mmu, mode, reg, size);
    if size == 1 { mmu_write8(mmu, addr, (val & 0xFF) as! u8); }
    else if size == 2 { mmu_write16(mmu, addr, (val & 0xFFFF) as! u16); }
    else { mmu_write32(mmu, addr, val); }
}

// バイト/ワードの EA 加算。Dn/An は 0。ロングのメモリは +6（C68K の ADD 表）。
fn ea_bw_extra(mode: i32, reg: i32) -> i32 {
    if mode == 0 || mode == 1 { return 0; }
    if mode == 2 || mode == 3 { return 4; }
    if mode == 4 { return 6; }
    if mode == 5 { return 8; }
    if mode == 6 { return 10; }
    if reg == 0 || reg == 2 { return 8; }
    if reg == 1 { return 12; }
    if reg == 3 { return 10; }
    return 4;
}

// Effective address time; a long operand in memory (or a long immediate) adds 4.
fn ea_extra_cycles(mode: i32, reg: i32, size: i32) -> i32 {
    let bw = ea_bw_extra(mode, reg);
    if size == 4 && mode != 0 && mode != 1 { return bw + 4; }
    return bw;
}

fn ea_is_reg_or_imm(mode: i32, reg: i32) -> bool {
    return mode == 0 || mode == 1 || (mode == 7 && reg == 4);
}

// <ea>,Dn の ADD/SUB/AND/OR。バイト/ワードは 4、ロングは 6、プラス EA。
// ロングでソースがレジスタか即値のときは 8 (XEiJ)。
fn alu_read_cycles(size: i32, mode: i32, reg: i32) -> i32 {
    var base: i32 = if size == 4 { 6 } else { 4 };
    if size == 4 && ea_is_reg_or_imm(mode, reg) { base = 8; }
    return base + ea_extra_cycles(mode, reg, size);
}

// CLR / メモリ RMW。C68K の CLR 表。
fn clr_cycles(size: i32, mode: i32, reg: i32) -> i32 {
    if mode == 0 { return if size == 4 { 6 } else { 4 }; }
    let bw = 8 + ea_bw_extra(mode, reg);
    if size == 4 { return bw + 8; }
    return bw;
}

// EOR は Dn ロングだけ CLR と違う（8）。メモリは CLR と同じ。
fn eor_cycles(size: i32, mode: i32, reg: i32) -> i32 {
    if mode == 0 { return if size == 4 { 8 } else { 4 }; }
    return clr_cycles(size, mode, reg);
}

fn alu_bin_cycles(size: i32, mode: i32, reg: i32, to_ea: bool) -> i32 {
    if to_ea { return clr_cycles(size, mode, reg); }
    return alu_read_cycles(size, mode, reg);
}

// ADDA/SUBA: .W 8, .L 6 (8 from a register or immediate), plus EA.
fn adda_cycles(is_long: bool, mode: i32, reg: i32) -> i32 {
    let size: i32 = if is_long { 4 } else { 2 };
    var base: i32 = if is_long { 6 } else { 8 };
    if is_long && ea_is_reg_or_imm(mode, reg) { base = 8; }
    return base + ea_extra_cycles(mode, reg, size);
}

// CMP <ea>,Dn: 4 (.L 6) plus EA, with no register/immediate surcharge.
fn cmp_cycles(size: i32, mode: i32, reg: i32) -> i32 {
    let base: i32 = if size == 4 { 6 } else { 4 };
    return base + ea_extra_cycles(mode, reg, size);
}

// MOVE の src 成分と dst 成分。-(An) の書き込みだけ EA 加算と違う。
fn move_cycles(size: i32, src_mode: i32, src_reg: i32, dst_mode: i32, dst_reg: i32) -> i32 {
    var src = 4 + ea_bw_extra(src_mode, src_reg);
    var dst: i32 = 0;
    if dst_mode >= 2 {
        if dst_mode == 4 { dst = 4; } else { dst = ea_bw_extra(dst_mode, dst_reg); }
    }
    if size == 4 {
        if src_mode >= 2 { src += 4; }
        if dst_mode >= 2 { dst += 4; }
    }
    return src + dst;
}

// MOVEM (XEiJ): to memory -(An) 8, else 4 (.L 0) + EA; to registers (An)+ 12 (.L 8),
// else 8 (.L 4) + EA; plus 4 (.L 8) per register.
fn movem_cycles(is_long: bool, nregs: i32, mode: i32, to_mem: bool, reg: i32) -> i32 {
    let size: i32 = if is_long { 4 } else { 2 };
    let per: i32 = if is_long { 8 } else { 4 };
    var base: i32 = 0;
    if to_mem {
        if mode == 4 { base = 8; }
        else { base = (if is_long { 0 } else { 4 }) + ea_extra_cycles(mode, reg, size); }
    } else {
        if mode == 3 { base = if is_long { 8 } else { 12 }; }
        else { base = (if is_long { 4 } else { 8 }) + ea_extra_cycles(mode, reg, size); }
    }
    return base + per * nregs;
}

// LEA/PEA address time: (An) 4, d16 8, index 12, abs.W 8, abs.L 12, PC 8 / 12.
fn lea_cycles(mode: i32, reg: i32) -> i32 {
    if mode == 2 { return 4; }
    if mode == 6 || (mode == 7 && reg == 3) { return 12; }
    if mode == 7 && reg == 1 { return 12; }
    return 8;
}

// JMP address time: (An) 8, d16 10, index 14, abs.W 10, abs.L 12, PC 10 / 14. JSR adds 8.
fn jmp_cycles(mode: i32, reg: i32) -> i32 {
    if mode == 2 { return 8; }
    if mode == 6 || (mode == 7 && reg == 3) { return 14; }
    if mode == 7 && reg == 1 { return 12; }
    return 10;
}

// MULU: 38 + 2 per one bit of the source. MULS: 38 + 2 per one bit in the low 16 bits of
// source ^ (source << 1), i.e. 01/10 pairs with a 0 appended (XEiJ irpMulsWord).
fn mul_cycles(mode: i32, reg: i32, src: u32, signed: bool) -> i32 {
    var t = src & 0xFFFF;
    if signed { t = (t ^ (t << 1)) & 0xFFFF; }
    var n: i32 = 0;
    while t != 0 {
        n += (t & 1) as! i32;
        t = t >> 1;
    }
    return 38 + 2 * n + ea_extra_cycles(mode, reg, 2);
}

// BTST/BCHG/BCLR/BSET (XEiJ). Register: dynamic BTST 6, BCHG/BSET 6/8, BCLR 8/10 (bit < 16 /
// above); static adds 4. Memory: dynamic BTST 4, others 8; static adds 4; plus EA.
fn bit_cycles(op_type: i32, is_static: bool, mode: i32, reg: i32, bit: u32) -> i32 {
    let st: i32 = if is_static { 4 } else { 0 };
    if mode == 0 {
        let hi: i32 = if bit >= 16 { 2 } else { 0 };
        if op_type == 0 { return 6 + st; }
        if op_type == 2 { return 8 + hi + st; }
        return 6 + hi + st;
    }
    let base: i32 = if op_type == 0 { 4 } else { 8 };
    return base + st + ea_bw_extra(mode, reg);
}

fn shift_reg_cycles(size: i32, count: i32) -> i32 {
    let base: i32 = if size == 4 { 8 } else { 6 };
    return base + count * 2;
}

fn shift_mem_cycles(mode: i32, reg: i32) -> i32 {
    return 8 + ea_bw_extra(mode, reg);
}

// DIVU/DIVS cycles from the 68000's shift-subtract loop (XEiJ irpDivuCyclesModified /
// irpDivsCycles), plus the effective address time. Zero divide keeps the old count.
fn divu_cycles(mode: i32, reg: i32, x: u32, y: u32) -> i32 {
    let extra = ea_extra_cycles(mode, reg, 2);
    let d = y & 0xFFFF;
    if d == 0 { return 38 + extra; }
    var r = x >> 16;
    if d <= r { return 10 + extra; }
    var c: i32 = 76;
    var i: i32 = 15;
    while i > 0 {
        r = (r << 1) | ((x >> (i as! u32)) & 1);
        if r >= 0x10000 {
            r -= d;
        } else if d <= r {
            r -= d;
            c += 2;
        } else {
            c += 4;
        }
        i -= 1;
    }
    return c + extra;
}

fn divs_cycles(mode: i32, reg: i32, x: i32, y: i32) -> i32 {
    let extra = ea_extra_cycles(mode, reg, 2);
    if y == 0 { return 38 + extra; }
    let ax = if x < 0 { (0 as! u32) - (x as! u32) } else { x as! u32 };
    let ay = if y < 0 { (0 as! u32) - (y as! u32) } else { y as! u32 };
    let q = ax / ay;
    if (q & 0xFFFF0000) != 0 {
        let ovf: i32 = if x < 0 { 18 } else { 16 };
        return ovf + extra;
    }
    var t = ~q;
    t = (t & 0x5554) + ((t >> 1) & 0x5555);
    t = (t & 0x3333) + ((t >> 2) & 0x3333);
    t = (t & 0x0F0F) + ((t >> 4) & 0x0F0F);
    t = (t & 0x00FF) + ((t >> 8) & 0x00FF);
    let base: i32 = if x < 0 { if y < 0 { 124 } else { 126 } } else { if y < 0 { 122 } else { 120 } };
    return base + ((t as! i32) << 1) + extra;
}

fn bcc_cycles(word_disp: bool, taken: bool) -> i32 {
    if word_disp { return if taken { 10 } else { 12 }; }
    return if taken { 10 } else { 8 };
}

// ORI/ANDI/SUBI/ADDI/EORI。Dn は 8/16。メモリは CLR に即値分を足す。
fn imm_alu_cycles(size: i32, mode: i32, reg: i32) -> i32 {
    if mode == 0 { return if size == 4 { 16 } else { 8 }; }
    let add: i32 = if size == 4 { 8 } else { 4 };
    return clr_cycles(size, mode, reg) + add;
}

// CMPI (XEiJ): Dn 8 (.L 14); memory 8 (.L 12) plus EA.
fn cmpi_cycles(size: i32, mode: i32, reg: i32) -> i32 {
    if mode == 0 { return if size == 4 { 14 } else { 8 }; }
    return (if size == 4 { 12 } else { 8 }) + ea_extra_cycles(mode, reg, size);
}

fn addq_cycles(size: i32, mode: i32, reg: i32) -> i32 {
    if mode == 1 { return 8; }
    if mode == 0 { return if size == 4 { 8 } else { 4 }; }
    return clr_cycles(size, mode, reg);
}

// -------------------------------------------------------------
// Op 0: ビット操作 & 即値演算 (ORI, ANDI, SUBI, ADDI, EORI, CMPI, BTST, BSET, BCLR, BCHG)
// -------------------------------------------------------------
// データ変更可能な EA（Dn / メモリ。An 直接、PC 相対、即値は不可）
fn ea_is_alterable(mode: i32, reg: i32) -> bool {
    if mode == 0 || mode == 2 || mode == 3 || mode == 4 || mode == 5 || mode == 6 { return true; }
    if mode == 7 && (reg == 0 || reg == 1) { return true; }
    return false;
}

// CHK のソース。An 直接と未定義の mode7 は不可。即値と PC 相対は可。
fn ea_is_data(mode: i32, reg: i32) -> bool {
    if mode == 1 { return false; }
    if mode == 7 && reg > 4 { return false; }
    return true;
}

fn raise_illegal(cpu: M68kCPU&, mmu: M68kMMU&) -> i32 {
    m68k_trigger_exception(cpu, mmu, 4, cpu.pc - 2);
    return 34;
}

// ABCD/SBCD/NBCD。Z は結果が 0 以外のときだけクリアする。keep_z のときは Z を変えない。V は変えない。
// 68000 BCD flags as XEiJ computes them: X/C carry, Z cleared on a non-zero result,
// N the result's top bit, V overflow from adding the decimal correction.
fn bcd_flags(cpu: M68kCPU&, t: i32, z: i32, carry: bool) {
    if carry { cpu.sr |= ((SR_C | SR_X) as! u16); } else { cpu.sr &= ~((SR_C | SR_X) as! u16); }
    if z != 0 { cpu.sr &= ~(SR_Z as! u16); }
    if (z & 0x80) != 0 { cpu.sr |= (SR_N as! u16); } else { cpu.sr &= ~(SR_N as! u16); }
    let a = z - t;
    if (((t ^ z) & (a ^ z)) & 0x80) != 0 { cpu.sr |= (SR_V as! u16); } else { cpu.sr &= ~(SR_V as! u16); }
}

fn bcd_add(cpu: M68kCPU&, dst: u32, src: u32) -> u32 {
    let c: i32 = if cpu_flag_x(cpu) { 1 } else { 0 };
    let x = (dst & 0xFF) as! i32;
    let y = (src & 0xFF) as! i32;
    let t = x + y + c;
    var z = t;
    if (x & 0x0F) + (y & 0x0F) + c >= 0x0A { z += 0x10 - 0x0A; }
    let carry = z >= 0xA0;
    if carry { z += 0x100 - 0xA0; }
    z &= 0xFF;
    bcd_flags(cpu, t, z, carry);
    return z as! u32;
}

fn bcd_sub(cpu: M68kCPU&, dst: u32, src: u32) -> u32 {
    let b: i32 = if cpu_flag_x(cpu) { 1 } else { 0 };
    let x = (dst & 0xFF) as! i32;
    let y = (src & 0xFF) as! i32;
    let t = x - y - b;
    var z = t;
    if (x & 0x0F) - (y & 0x0F) - b < 0 { z -= 0x10 - 0x0A; }
    let borrow = z < 0;
    if borrow && t < 0 { z -= 0x100 - 0xA0; }
    z &= 0xFF;
    bcd_flags(cpu, t, z, borrow);
    return z as! u32;
}

fn predec_byte(cpu: M68kCPU&, reg: i32) -> u32 {
    let delta: u32 = if reg == 7 { 2 } else { 1 };
    cpu.a[reg] -= delta;
    return cpu.a[reg];
}

// MOVEP。mm: 0=W メモリ→Dn, 1=L メモリ→Dn, 2=W Dn→メモリ, 3=L Dn→メモリ
fn exec_movep(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    let dreg = ((op >> 9) & 0x07) as! i32;
    let areg = (op & 0x07) as! i32;
    let disp = (fetch16(cpu, mmu) as! i16) as! i32;
    let adr = ((cpu.a[areg] as! i32) + disp) as! u32;
    let kind = ((op >> 6) & 0x03) as! i32;
    if kind == 0 {
        let hi = mmu_read8(mmu, adr) as! u32;
        let lo = mmu_read8(mmu, adr + 2) as! u32;
        cpu.d[dreg] = (cpu.d[dreg] & 0xFFFF0000) | (hi << 8) | lo;
        return 16;
    }
    if kind == 1 {
        let b0 = mmu_read8(mmu, adr) as! u32;
        let b1 = mmu_read8(mmu, adr + 2) as! u32;
        let b2 = mmu_read8(mmu, adr + 4) as! u32;
        let b3 = mmu_read8(mmu, adr + 6) as! u32;
        cpu.d[dreg] = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
        return 24;
    }
    let res = cpu.d[dreg];
    if kind == 2 {
        mmu_write8(mmu, adr, ((res >> 8) & 0xFF) as! u8);
        mmu_write8(mmu, adr + 2, (res & 0xFF) as! u8);
        return 16;
    }
    mmu_write8(mmu, adr, ((res >> 24) & 0xFF) as! u8);
    mmu_write8(mmu, adr + 2, ((res >> 16) & 0xFF) as! u8);
    mmu_write8(mmu, adr + 4, ((res >> 8) & 0xFF) as! u8);
    mmu_write8(mmu, adr + 6, (res & 0xFF) as! u8);
    return 24;
}

fn exec_op0(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    let mode = ((op >> 3) & 0x07) as! i32;
    let reg = (op & 0x07) as! i32;

    // BTST / BCHG / BCLR / BSET (Static: 0000 1000 ss eee eee #imm)
    if (op & 0xFF00) == 0x0800 {
        let op_type = ((op >> 6) & 0x03) as! i32; // 0=BTST, 1=BCHG, 2=BCLR, 3=BSET
        let bit_num = (fetch16(cpu, mmu) & 0xFF) as! u32;

        if mode == 0 { // Register (32-bit)
            let b = bit_num & 31;
            let mask = (1 as! u32) << b;
            let z = (cpu.d[reg] & mask) == 0;
            if z { cpu.sr |= (SR_Z as! u16); } else { cpu.sr &= ~(SR_Z as! u16); }

            if op_type == 1 { cpu.d[reg] ^= mask; }
            else if op_type == 2 { cpu.d[reg] &= ~mask; }
            else if op_type == 3 { cpu.d[reg] |= mask; }
            return bit_cycles(op_type, true, mode, reg, b);
        } else { // Memory (8-bit)
            let b = bit_num & 7;
            let mask = ((1 as! u32) << b) as! u8;
            if op_type == 0 {
                let cur = ea_read(cpu, mmu, mode, reg, 1) as! u8;
                let z = (cur & mask) == 0;
                if z { cpu.sr |= (SR_Z as! u16); } else { cpu.sr &= ~(SR_Z as! u16); }
                return bit_cycles(op_type, true, mode, reg, 0);
            }
            let addr = ea_calc_addr(cpu, mmu, mode, reg, 1);
            let cur = mmu_read8(mmu, addr);
            let z = (cur & mask) == 0;
            if z { cpu.sr |= (SR_Z as! u16); } else { cpu.sr &= ~(SR_Z as! u16); }

            if op_type == 1 { mmu_write8(mmu, addr, cur ^ mask); }
            else if op_type == 2 { mmu_write8(mmu, addr, cur & ~mask); }
            else if op_type == 3 { mmu_write8(mmu, addr, cur | mask); }
            return bit_cycles(op_type, true, mode, reg, 0);
        }
    }

    // BTST / BCHG / BCLR / BSET (Dynamic: 0000 rrr 1ss eee eee Dn)
    if (op & 0x0100) != 0 && mode != 1 {
        let dreg = ((op >> 9) & 0x07) as! i32;
        let op_type = ((op >> 6) & 0x03) as! i32;

        if mode == 0 { // Register (32-bit)
            let b = cpu.d[dreg] & 31;
            let mask = (1 as! u32) << b;
            let z = (cpu.d[reg] & mask) == 0;
            if z { cpu.sr |= (SR_Z as! u16); } else { cpu.sr &= ~(SR_Z as! u16); }

            if op_type == 1 { cpu.d[reg] ^= mask; }
            else if op_type == 2 { cpu.d[reg] &= ~mask; }
            else if op_type == 3 { cpu.d[reg] |= mask; }
            return bit_cycles(op_type, false, mode, reg, b);
        } else { // Memory (8-bit)
            let b = (cpu.d[dreg] & 7) as! u32;
            let mask = ((1 as! u32) << b) as! u8;
            if op_type == 0 {
                let cur = ea_read(cpu, mmu, mode, reg, 1) as! u8;
                let z = (cur & mask) == 0;
                if z { cpu.sr |= (SR_Z as! u16); } else { cpu.sr &= ~(SR_Z as! u16); }
                return bit_cycles(op_type, false, mode, reg, 0);
            }
            let addr = ea_calc_addr(cpu, mmu, mode, reg, 1);
            let cur = mmu_read8(mmu, addr);
            let z = (cur & mask) == 0;
            if z { cpu.sr |= (SR_Z as! u16); } else { cpu.sr &= ~(SR_Z as! u16); }

            if op_type == 1 { mmu_write8(mmu, addr, cur ^ mask); }
            else if op_type == 2 { mmu_write8(mmu, addr, cur & ~mask); }
            else if op_type == 3 { mmu_write8(mmu, addr, cur | mask); }
            return bit_cycles(op_type, false, mode, reg, 0);
        }
    }

    // MOVEP (0000 rrr1 mm001 aaa)。mode==1 は動的ビット命令から外れている。
    if (op & 0x0100) != 0 && mode == 1 {
        return exec_movep(cpu, mmu, op);
    }

    // 即値演算: ORI (0x00), ANDI (0x02), SUBI (0x04), ADDI (0x06), EORI (0x0A), CMPI (0x0C)
    let imm_op = ((op >> 9) & 0x07) as! i32;
    let sz_code = ((op >> 6) & 0x03) as! i32;
    // imm_op 4 は BTST、7 は未定義。未定義は即値ワードを読まず Illegal にする。
    if sz_code <= 2 && imm_op != 4 && imm_op != 7 {
        let size: i32 = if sz_code == 0 { 1 } else if sz_code == 1 { 2 } else { 4 };
        // ORI/ANDI/EORI to SR はユーザーモードで Vector 8。即値は読まない（C68K と同じ）。
        if size == 2 && mode == 7 && reg == 4 && (imm_op == 0 || imm_op == 1 || imm_op == 5) {
            if !cpu_is_supervisor(cpu) {
                m68k_trigger_exception(cpu, mmu, 8, cpu.pc);
                return 34;
            }
        }
        let imm_val = if size == 1 { (fetch16(cpu, mmu) & 0xFF) as! u32 }
                      else if size == 2 { fetch16(cpu, mmu) as! u32 }
                      else { fetch32(cpu, mmu) };

        // ORI / ANDI / EORI to CCR / SR
        if mode == 7 && reg == 4 {
            if imm_op == 0 { // ORI
                if size == 1 { cpu_set_ccr(cpu, ((cpu.sr & 0x1F) | (imm_val as! u16)) as! u8); }
                else if size == 2 && cpu_is_supervisor(cpu) { cpu_set_sr(cpu, cpu.sr | (imm_val as! u16)); }
            } else if imm_op == 1 { // ANDI
                if size == 1 { cpu_set_ccr(cpu, ((cpu.sr & 0x1F) & (imm_val as! u16)) as! u8); }
                else if size == 2 && cpu_is_supervisor(cpu) { cpu_set_sr(cpu, cpu.sr & (imm_val as! u16)); }
            } else if imm_op == 5 { // EORI
                if size == 1 { cpu_set_ccr(cpu, ((cpu.sr & 0x1F) ^ (imm_val as! u16)) as! u8); }
                else if size == 2 && cpu_is_supervisor(cpu) { cpu_set_sr(cpu, cpu.sr ^ (imm_val as! u16)); }
            }
            return 20;
        }

        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, size);
        let dst = ea_res.val;

        if imm_op == 0 { // ORI
            let res = dst | imm_val;
            ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
            if size == 1 { cpu_set_nz8(cpu, res as! u8); }
            else if size == 2 { cpu_set_nz16(cpu, res as! u16); }
            else { cpu_set_nz32(cpu, res); }
            return imm_alu_cycles(size, mode, reg);
        }
        if imm_op == 1 { // ANDI
            let res = dst & imm_val;
            ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
            if size == 1 { cpu_set_nz8(cpu, res as! u8); }
            else if size == 2 { cpu_set_nz16(cpu, res as! u16); }
            else { cpu_set_nz32(cpu, res); }
            return imm_alu_cycles(size, mode, reg);
        }
        if imm_op == 2 { // SUBI
            let res = dst - imm_val;
            ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
            if size == 1 { cpu_flags_sub8(cpu, imm_val as! u8, dst as! u8, res as! u8, true); }
            else if size == 2 { cpu_flags_sub16(cpu, imm_val as! u16, dst as! u16, res as! u16, true); }
            else { cpu_flags_sub32(cpu, imm_val, dst, res, true); }
            return imm_alu_cycles(size, mode, reg);
        }
        if imm_op == 3 { // ADDI
            let res = dst + imm_val;
            ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
            if size == 1 { cpu_flags_add8(cpu, imm_val as! u8, dst as! u8, res as! u8); }
            else if size == 2 { cpu_flags_add16(cpu, imm_val as! u16, dst as! u16, res as! u16); }
            else { cpu_flags_add32(cpu, imm_val, dst, res); }
            return imm_alu_cycles(size, mode, reg);
        }
        if imm_op == 5 { // EORI
            let res = dst ^ imm_val;
            ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
            if size == 1 { cpu_set_nz8(cpu, res as! u8); }
            else if size == 2 { cpu_set_nz16(cpu, res as! u16); }
            else { cpu_set_nz32(cpu, res); }
            return imm_alu_cycles(size, mode, reg);
        }
        if imm_op == 6 { // CMPI
            let res = dst - imm_val;
            if size == 1 { cpu_flags_sub8(cpu, imm_val as! u8, dst as! u8, res as! u8, false); }
            else if size == 2 { cpu_flags_sub16(cpu, imm_val as! u16, dst as! u16, res as! u16, false); }
            else { cpu_flags_sub32(cpu, imm_val, dst, res, false); }
            return cmpi_cycles(size, mode, reg);
        }
    }
    return raise_illegal(cpu, mmu);
}

fn m68k_trigger_exception(cpu: M68kCPU&, mmu: M68kMMU&, vector: i32, return_pc: u32) {
    if mmu.fault != 0 { return; }
    mmu.user_mode = false;
    if !cpu_is_supervisor(cpu) {
        cpu.usp = cpu.a[REG_A7];
        cpu.a[REG_A7] = cpu.ssp;
    }
    push32(cpu, mmu, return_pc);
    push16(cpu, mmu, cpu.sr);
    cpu.sr |= (SR_S as! u16);
    cpu.sr &= ~(SR_T as! u16);
    let vec_addr = ((vector & 0xFF) * 4) as! u32;
    cpu.pc = mmu_read32(mmu, vec_addr);
}

// -------------------------------------------------------------
// Op 4: 雑多命令 (LEA, PEA, MOVEM, CLR, NEG, NOT, TST, JMP, JSR, TRAP, LINK, UNLK, EXT, SWAP)
// -------------------------------------------------------------
fn exec_op4(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    let mode = ((op >> 3) & 0x07) as! i32;
    let reg = (op & 0x07) as! i32;

    // NOP (0x4E71)
    if op == 0x4E71 { return 4; }
    // RESET (0x4E70)。px68k の Reset_CallBack は C68k_Reset_Dummy で、周辺は変えない。
    if op == 0x4E70 {
        if !cpu_is_supervisor(cpu) {
            m68k_trigger_exception(cpu, mmu, 8, cpu.pc);
            return 34;
        }
        return 132;
    }
    // STOP #imm (0x4E72)
    if op == 0x4E72 {
        if !cpu_is_supervisor(cpu) {
            m68k_trigger_exception(cpu, mmu, 8, cpu.pc - 2);
            return 34;
        }
        let imm = fetch16(cpu, mmu);
        cpu_set_sr(cpu, imm);
        cpu.halted = true;
        return 4;
    }
    // RTS (0x4E75)
    if op == 0x4E75 { cpu.pc = pop32(cpu, mmu); return 16; }
    // RTE (0x4E73)
    if op == 0x4E73 {
        if !cpu_is_supervisor(cpu) {
            m68k_trigger_exception(cpu, mmu, 8, cpu.pc);
            return 34;
        }
        let new_sr = pop16(cpu, mmu);
        let new_pc = pop32(cpu, mmu);
        cpu_set_sr(cpu, new_sr);
        cpu.pc = new_pc;
        return 20;
    }
    // RTR (0x4E77)
    if op == 0x4E77 {
        let ccr = pop16(cpu, mmu);
        cpu_set_ccr(cpu, ccr as! u8);
        cpu.pc = pop32(cpu, mmu);
        return 20;
    }
    // TRAPV (0x4E76)。V が立っていれば Vector 7。積む PC は次の命令。
    if op == 0x4E76 {
        if cpu_flag_v(cpu) {
            m68k_trigger_exception(cpu, mmu, 7, cpu.pc);
            return 34;
        }
        return 4;
    }

    // JMP (0100 1110 11 eee eee)
    if (op & 0xFFC0) == 0x4EC0 {
        cpu.pc = ea_calc_addr(cpu, mmu, mode, reg, 4);
        return jmp_cycles(mode, reg);
    }
    // JSR (0100 1110 10 eee eee)
    if (op & 0xFFC0) == 0x4E80 {
        let target = ea_calc_addr(cpu, mmu, mode, reg, 4);
        push32(cpu, mmu, cpu.pc);
        cpu.pc = target;
        return 8 + jmp_cycles(mode, reg);
    }

    // LEA (0100 rrr1 11 eee eee)
    if (op & 0xF1C0) == 0x41C0 {
        let areg = ((op >> 9) & 0x07) as! i32;
        cpu.a[areg] = ea_calc_addr(cpu, mmu, mode, reg, 4);
        return lea_cycles(mode, reg);
    }
    // SWAP (0100 1000 0100 0rrr: mode == 0)
    if (op & 0xFFF8) == 0x4840 {
        let dreg = (op & 0x07) as! i32;
        let v = cpu.d[dreg];
        cpu.d[dreg] = (v >> 16) | (v << 16);
        cpu_set_nz32(cpu, cpu.d[dreg]);
        return 4;
    }

    // PEA (0100 1000 01 eee eee: mode >= 2)
    if (op & 0xFFC0) == 0x4840 && mode >= 2 {
        let addr = ea_calc_addr(cpu, mmu, mode, reg, 4);
        push32(cpu, mmu, addr);
        return 8 + lea_cycles(mode, reg);
    }

    // LINK (0100 1110 0101 0rrr)
    if (op & 0xFFF8) == 0x4E50 {
        let areg = (op & 0x07) as! i32;
        let disp = (fetch16(cpu, mmu) as! i16) as! i32;
        push32(cpu, mmu, cpu.a[areg]);
        cpu.a[areg] = cpu.a[REG_A7];
        cpu.a[REG_A7] = ((cpu.a[REG_A7] as! i32) + disp) as! u32;
        return 16;
    }
    // UNLK (0100 1110 0101 1rrr)
    if (op & 0xFFF8) == 0x4E58 {
        let areg = (op & 0x07) as! i32;
        cpu.a[REG_A7] = cpu.a[areg];
        let saved = pop32(cpu, mmu);
        if mmu.fault == 0 { cpu.a[areg] = saved; }
        return 12;
    }

    // MOVE USP (0100 1110 0110 drrr)
    if (op & 0xFFF0) == 0x4E60 {
        if !cpu_is_supervisor(cpu) {
            m68k_trigger_exception(cpu, mmu, 8, cpu.pc);
            return 34;
        }
        let areg = (op & 0x07) as! i32;
        let to_usp = (op & 0x08) == 0;
        if to_usp { cpu.usp = cpu.a[areg]; } else { cpu.a[areg] = cpu.usp; }
        return 4;
    }

    // TRAP (0100 1110 0100 vvvv)
    if (op & 0xFFF0) == 0x4E40 {
        let trap_num = (op & 0x0F) as! i32;
        m68k_trigger_exception(cpu, mmu, 32 + trap_num, cpu.pc);
        return 34;
    }

    // MOVEM Regs -> <ea> (0100 1000 1s eee eee)
    if ((op & 0xFB80) == 0x4880) && mode >= 2 {
        let is_to_mem = (op & 0x0400) == 0;
        let is_long = (op & 0x0040) != 0;
        let mask = fetch16(cpu, mmu);
        var nregs: i32 = 0;
        for i in 16 {
            if (mask & ((1 as! u16) << i)) != 0 { nregs += 1; }
        }

        if is_to_mem {
            if mode == 4 { // -(An): predecrement (bit 0=A7..bit 7=A0, bit 8=D7..bit 15=D0)
                var addr = cpu.a[reg];
                for i in 16 {
                    if (mask & ((1 as! u16) << i)) != 0 {
                        let val = if i < 8 { cpu.a[7 - i] } else { cpu.d[15 - i] };
                        if is_long {
                            addr -= 4;
                            mmu_write32(mmu, addr, val);
                        } else {
                            addr -= 2;
                            mmu_write16(mmu, addr, (val & 0xFFFF) as! u16);
                        }
                    }
                }
                cpu.a[reg] = addr;
            } else {
                var addr = ea_calc_addr(cpu, mmu, mode, reg, if is_long { 4 } else { 2 });
                for i in 16 {
                    if (mask & ((1 as! u16) << i)) != 0 {
                        let val = if i < 8 { cpu.d[i] } else { cpu.a[i - 8] };
                        if is_long {
                            mmu_write32(mmu, addr, val);
                            addr += 4;
                        } else {
                            mmu_write16(mmu, addr, (val & 0xFFFF) as! u16);
                            addr += 2;
                        }
                    }
                }
            }
            return movem_cycles(is_long, nregs, mode, true, reg);
        } else {
            // MOVEM <ea> -> Regs (0100 1100 1s eee eee)
            var addr = if mode == 3 { cpu.a[reg] } else { ea_calc_addr(cpu, mmu, mode, reg, if is_long { 4 } else { 2 }) };
            for i in 16 {
                if (mask & ((1 as! u16) << i)) != 0 {
                    if is_long {
                        let val = mmu_read32(mmu, addr);
                        addr += 4;
                        if i < 8 { cpu.d[i] = val; } else if mmu.fault == 0 { cpu.a[i - 8] = val; }
                    } else {
                        let val = (mmu_read16(mmu, addr) as! i16) as! i32 as! u32;
                        addr += 2;
                        if i < 8 { cpu.d[i] = val; } else if mmu.fault == 0 { cpu.a[i - 8] = val; }
                    }
                }
            }
            if mode == 3 && mmu.fault == 0 { // (An)+ postincrement
                cpu.a[reg] = addr;
            }
            return movem_cycles(is_long, nregs, mode, false, reg);
        }
    }

    // EXT.W (0100 1000 1000 0rrr) & EXT.L (0100 1000 1100 0rrr)
    if (op & 0xFFB8) == 0x4880 {
        let is_long = (op & 0x0040) != 0;
        let dreg = (op & 0x07) as! i32;
        if is_long {
            let val = (cpu.d[dreg] as! i16) as! i32 as! u32;
            cpu.d[dreg] = val;
            cpu_set_nz32(cpu, val);
        } else {
            let val = (cpu.d[dreg] as! i8) as! i16 as! u16;
            cpu.d[dreg] = (cpu.d[dreg] & 0xFFFF0000) | (val as! u32);
            cpu_set_nz16(cpu, val);
        }
        return 4;
    }

    // MOVE to SR (0100 0110 11 eee eee)
    if (op & 0xFFC0) == 0x46C0 {
        if !cpu_is_supervisor(cpu) {
            m68k_trigger_exception(cpu, mmu, 8, cpu.pc);
            return 34;
        }
        let val = ea_read(cpu, mmu, mode, reg, 2) as! u16;
        cpu_set_sr(cpu, val);
        return 12 + ea_bw_extra(mode, reg);
    }
    // MOVE to CCR (0100 0100 11 eee eee)
    if (op & 0xFFC0) == 0x44C0 {
        let ccr = ea_read(cpu, mmu, mode, reg, 2) as! u16;
        cpu_set_ccr(cpu, ccr as! u8);
        return 12 + ea_bw_extra(mode, reg);
    }
    // MOVE from SR (0100 0000 11 eee eee)
    if (op & 0xFFC0) == 0x40C0 {
        ea_write(cpu, mmu, mode, reg, 2, cpu.sr as! u32);
        if mode == 0 { return 6; }
        return 8 + ea_bw_extra(mode, reg);
    }

    // NEGX (0100 0000 ss eee eee: ss <= 2)
    if (op & 0xFF00) == 0x4000 && ((op >> 6) & 3) <= 2 {
        let sz_code = ((op >> 6) & 0x03) as! i32;
        let size: i32 = if sz_code == 0 { 1 } else if sz_code == 1 { 2 } else { 4 };
        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, size);
        let cur = ea_res.val;
        let x_val = if cpu_flag_x(cpu) { 1 as! u32 } else { 0 as! u32 };
        let res = (0 as! u32) - cur - x_val;
        ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
        if size == 1 { cpu_flags_subx8(cpu, cur as! u8, 0, res as! u8); }
        else if size == 2 { cpu_flags_subx16(cpu, cur as! u16, 0, res as! u16); }
        else { cpu_flags_subx32(cpu, cur, 0, res); }
        return clr_cycles(size, mode, reg);
    }

    // CLR (0100 0010 ss eee eee: ss <= 2)
    if (op & 0xFF00) == 0x4200 && ((op >> 6) & 3) <= 2 {
        let sz_code = ((op >> 6) & 0x03) as! i32;
        let size: i32 = if sz_code == 0 { 1 } else if sz_code == 1 { 2 } else { 4 };
        ea_write(cpu, mmu, mode, reg, size, 0);
        cpu.sr |= (SR_Z as! u16);
        cpu.sr &= ~((SR_N | SR_V | SR_C) as! u16);
        return clr_cycles(size, mode, reg);
    }

    // NEG (0100 0100 ss eee eee: ss <= 2)
    if (op & 0xFF00) == 0x4400 && ((op >> 6) & 3) <= 2 {
        let sz_code = ((op >> 6) & 0x03) as! i32;
        let size: i32 = if sz_code == 0 { 1 } else if sz_code == 1 { 2 } else { 4 };
        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, size);
        let cur = ea_res.val;
        let res = (0 as! u32) - cur;
        ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
        if size == 1 { cpu_flags_sub8(cpu, cur as! u8, 0, res as! u8, true); }
        else if size == 2 { cpu_flags_sub16(cpu, cur as! u16, 0, res as! u16, true); }
        else { cpu_flags_sub32(cpu, cur, 0, res, true); }
        return clr_cycles(size, mode, reg);
    }

    // NOT (0100 0110 ss eee eee: ss <= 2)
    if (op & 0xFF00) == 0x4600 && ((op >> 6) & 3) <= 2 {
        let sz_code = ((op >> 6) & 0x03) as! i32;
        let size: i32 = if sz_code == 0 { 1 } else if sz_code == 1 { 2 } else { 4 };
        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, size);
        let cur = ea_res.val;
        let res = ~cur;
        ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
        if size == 1 { cpu_set_nz8(cpu, res as! u8); }
        else if size == 2 { cpu_set_nz16(cpu, res as! u16); }
        else { cpu_set_nz32(cpu, res); }
        return clr_cycles(size, mode, reg);
    }

    // TST (0100 1010 ss eee eee: ss <= 2)
    if (op & 0xFF00) == 0x4A00 && ((op >> 6) & 3) <= 2 {
        let sz_code = ((op >> 6) & 0x03) as! i32;
        let size: i32 = if sz_code == 0 { 1 } else if sz_code == 1 { 2 } else { 4 };
        let val = ea_read(cpu, mmu, mode, reg, size);
        if size == 1 { cpu_set_nz8(cpu, val as! u8); }
        else if size == 2 { cpu_set_nz16(cpu, val as! u16); }
        else { cpu_set_nz32(cpu, val); }
        return 4 + ea_extra_cycles(mode, reg, size);
    }

    // NBCD (0100 1000 00 eee eee): 0 - <ea> - X with SBCD's flags.
    if (op & 0xFFC0) == 0x4800 {
        if !ea_is_alterable(mode, reg) { return raise_illegal(cpu, mmu); }
        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, 1);
        let res = bcd_sub(cpu, 0, ea_res.val);
        ea_write_for_rmw(cpu, mmu, mode, reg, 1, ea_res.addr, res);
        if mode == 0 { return 6; }
        return 8 + ea_bw_extra(mode, reg);
    }

    // CHK.W (0100 rrr1 10 eee eee): signed bounds. N/Z from Dn, V/C from bound - Dn (XEiJ).
    if (op & 0xF1C0) == 0x4180 {
        if !ea_is_data(mode, reg) { return raise_illegal(cpu, mmu); }
        let dn = ((op >> 9) & 0x07) as! i32;
        let x = (ea_read(cpu, mmu, mode, reg, 2) as! i16) as! i32;
        let y = (cpu.d[dn] as! i16) as! i32;
        let z = ((x - y) as! i16) as! i32;
        var ccr = cpu.sr & (SR_X as! u16);
        if y < 0 { ccr |= (SR_N as! u16); }
        if y == 0 { ccr |= (SR_Z as! u16); }
        if ((x ^ y) & (x ^ z)) < 0 { ccr |= (SR_V as! u16); }
        if ((x & (y ^ z)) ^ (y | z)) < 0 { ccr |= (SR_C as! u16); }
        cpu.sr = (cpu.sr & 0xFF00) | ccr;
        if y < 0 || x < y {
            m68k_trigger_exception(cpu, mmu, 6, cpu.pc);
            return 38 + ea_bw_extra(mode, reg);
        }
        return 10 + ea_bw_extra(mode, reg);
    }

    // TAS (0100 1010 11 eee eee)。4AFC など無効 EA は Illegal。
    if (op & 0xFFC0) == 0x4AC0 {
        if !ea_is_alterable(mode, reg) { return raise_illegal(cpu, mmu); }
        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, 1);
        let cur = ea_res.val & 0xFF;
        if (cur & 0x80) != 0 { cpu.sr |= (SR_N as! u16); } else { cpu.sr &= ~(SR_N as! u16); }
        if cur == 0 { cpu.sr |= (SR_Z as! u16); } else { cpu.sr &= ~(SR_Z as! u16); }
        cpu.sr &= ~((SR_V | SR_C) as! u16);
        ea_write_for_rmw(cpu, mmu, mode, reg, 1, ea_res.addr, cur | 0x80);
        if mode == 0 { return 4; }
        return 10 + ea_bw_extra(mode, reg);
    }

    return raise_illegal(cpu, mmu);
}

// -------------------------------------------------------------
// Op 8 & Op C: OR, AND, MULU, MULS, DIVU, DIVS, EXG
// -------------------------------------------------------------
fn exec_op8_or_div(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    let dreg = ((op >> 9) & 0x07) as! i32;
    let opmode = ((op >> 6) & 0x07) as! i32;
    let mode = ((op >> 3) & 0x07) as! i32;
    let reg = (op & 0x07) as! i32;

    // SBCD (1000 rrr1 0000 mrrr)。この形を OR.B に落とさない。
    if (op & 0x01F0) == 0x0100 {
        let mem = (op & 0x0008) != 0;
        if mem {
            let src_addr = predec_byte(cpu, reg);
            let dst_addr = predec_byte(cpu, dreg);
            let src = mmu_read8(mmu, src_addr) as! u32;
            let dst = mmu_read8(mmu, dst_addr) as! u32;
            let res = bcd_sub(cpu, dst, src);
            mmu_write8(mmu, dst_addr, res as! u8);
            return 18;
        }
        let res = bcd_sub(cpu, cpu.d[dreg], cpu.d[reg]);
        cpu.d[dreg] = (cpu.d[dreg] & 0xFFFFFF00) | res;
        return 6;
    }

    if opmode == 3 { // DIVU.W
        let src = ea_read(cpu, mmu, mode, reg, 2);
        let x = cpu.d[dreg];
        let cycles = divu_cycles(mode, reg, x, src);
        // Zero divide and overflow leave Dq; N/Z/V as the 68000 sets them (XEiJ).
        if src == 0 {
            var ccr = (cpu.sr & (SR_X as! u16)) | (SR_V as! u16);
            if (x & 0x80000000) != 0 { ccr |= (SR_N as! u16); }
            if (x >> 16) == 0 { ccr |= (SR_Z as! u16); }
            cpu.sr = (cpu.sr & 0xFF00) | ccr;
            m68k_trigger_exception(cpu, mmu, 5, cpu.pc);
            return cycles;
        }
        let q = x / src;
        let r = x % src;
        if q > 0xFFFF {
            var ccr = (cpu.sr & (SR_X as! u16)) | (SR_V as! u16);
            if (x & 0x80000000) != 0 { ccr |= (SR_N as! u16); }
            cpu.sr = (cpu.sr & 0xFF00) | ccr;
        } else {
            cpu.d[dreg] = (r << 16) | (q & 0xFFFF);
            cpu_set_nz16(cpu, q as! u16);
        }
        return cycles;
    }
    if opmode == 7 { // DIVS.W
        let src = (ea_read(cpu, mmu, mode, reg, 2) as! i16) as! i32;
        let dst = cpu.d[dreg] as! i32;
        let cycles = divs_cycles(mode, reg, dst, src);
        // Zero divide and overflow leave Dq; N/Z/V as the 68000 sets them (XEiJ).
        if src == 0 {
            let x = cpu.d[dreg];
            var v = (cpu.sr & (SR_V as! u16)) != 0;
            if x == 0x00008000 { v = !v; }
            else if (dst >= 0 && x != 0x7FFFFFFF) || x == 0x80000000 { v = true; }
            var ccr = (cpu.sr & (SR_X as! u16)) | (SR_Z as! u16);
            if v { ccr |= (SR_V as! u16); }
            cpu.sr = (cpu.sr & 0xFF00) | ccr;
            m68k_trigger_exception(cpu, mmu, 5, cpu.pc);
            return cycles;
        }
        // 64-bit so that $80000000 / -1 is an overflow, not a trap.
        let q64 = (dst as! i64) / (src as! i64);
        if q64 > 32767 || q64 < -32768 {
            let z = (q64 as! i32) as! u32;
            var ccr = (cpu.sr & (SR_X as! u16)) | (SR_V as! u16);
            if cpu.d[dreg] == 0x80000000 || (z & 0xFFFF0080) == 0x00000080 || (z & 0xFFFF0080) == 0xFFFF0080 {
                ccr |= (SR_N as! u16);
            }
            if z == 0x00008000 || (((z & 0xFFFF00FF) == 0 || (z & 0xFFFF00FF) == 0xFFFF0000) && (z & 0xFF00) != 0) {
                ccr |= (SR_Z as! u16);
            }
            cpu.sr = (cpu.sr & 0xFF00) | ccr;
        } else {
            let q = q64 as! i32;
            let r = dst - q * src;
            cpu.d[dreg] = (((r as! u32) & 0xFFFF) << 16) | ((q as! u32) & 0xFFFF);
            cpu_set_nz16(cpu, (q as! i16) as! u16);
        }
        return cycles;
    }

    // OR
    let size: i32 = if (opmode & 3) == 0 { 1 } else if (opmode & 3) == 1 { 2 } else { 4 };
    let is_ea_dst = (opmode & 4) != 0;
    if is_ea_dst {
        let src = cpu.d[dreg];
        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, size);
        let dst = ea_res.val;
        let res = dst | src;
        ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
        if size == 1 { cpu_set_nz8(cpu, res as! u8); }
        else if size == 2 { cpu_set_nz16(cpu, res as! u16); }
        else { cpu_set_nz32(cpu, res); }
    } else {
        let src = ea_read(cpu, mmu, mode, reg, size);
        let dst = cpu.d[dreg];
        let res = dst | src;
        if size == 1 { cpu.d[dreg] = (cpu.d[dreg] & 0xFFFFFF00) | (res & 0xFF); cpu_set_nz8(cpu, res as! u8); }
        else if size == 2 { cpu.d[dreg] = (cpu.d[dreg] & 0xFFFF0000) | (res & 0xFFFF); cpu_set_nz16(cpu, res as! u16); }
        else { cpu.d[dreg] = res; cpu_set_nz32(cpu, res); }
    }
    return alu_bin_cycles(size, mode, reg, is_ea_dst);
}

fn exec_opC_and_mul_exg(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    let dreg = ((op >> 9) & 0x07) as! i32;
    let opmode = ((op >> 6) & 0x07) as! i32;
    let mode = ((op >> 3) & 0x07) as! i32;
    let reg = (op & 0x07) as! i32;

    // ABCD (1100 rrr1 0000 mrrr)。EXG のマスクに掛かるが、そちらへ落とさない。
    if (op & 0x01F0) == 0x0100 {
        let mem = (op & 0x0008) != 0;
        if mem {
            let src_addr = predec_byte(cpu, reg);
            let dst_addr = predec_byte(cpu, dreg);
            let src = mmu_read8(mmu, src_addr) as! u32;
            let dst = mmu_read8(mmu, dst_addr) as! u32;
            let res = bcd_add(cpu, dst, src);
            mmu_write8(mmu, dst_addr, res as! u8);
            return 18;
        }
        let res = bcd_add(cpu, cpu.d[dreg], cpu.d[reg]);
        cpu.d[dreg] = (cpu.d[dreg] & 0xFFFFFF00) | res;
        return 6;
    }

    // EXG (1100 rrr 1 oooo rrr)
    if (op & 0xF130) == 0xC100 {
        let op_mode = ((op >> 3) & 0x1F) as! i32;
        let rx = dreg;
        let ry = reg;
        if op_mode == 0x08 { // EXG Dx, Dy
            let tmp = cpu.d[rx]; cpu.d[rx] = cpu.d[ry]; cpu.d[ry] = tmp; return 6;
        }
        if op_mode == 0x09 { // EXG Ax, Ay
            let tmp = cpu.a[rx]; cpu.a[rx] = cpu.a[ry]; cpu.a[ry] = tmp; return 6;
        }
        if op_mode == 0x11 { // EXG Dx, Ay
            let tmp = cpu.d[rx]; cpu.d[rx] = cpu.a[ry]; cpu.a[ry] = tmp; return 6;
        }
    }

    if opmode == 3 { // MULU.W
        let src = ea_read(cpu, mmu, mode, reg, 2);
        let res = (cpu.d[dreg] & 0xFFFF) * (src & 0xFFFF);
        cpu.d[dreg] = res;
        cpu_set_nz32(cpu, res);
        return mul_cycles(mode, reg, src, false);
    }
    if opmode == 7 { // MULS.W
        let src = (ea_read(cpu, mmu, mode, reg, 2) as! i16) as! i32;
        let dst = (cpu.d[dreg] as! i16) as! i32;
        let res = (dst * src) as! u32;
        cpu.d[dreg] = res;
        cpu_set_nz32(cpu, res);
        return mul_cycles(mode, reg, src as! u32, true);
    }

    // AND
    let size: i32 = if (opmode & 3) == 0 { 1 } else if (opmode & 3) == 1 { 2 } else { 4 };
    let is_ea_dst = (opmode & 4) != 0;
    if is_ea_dst {
        let src = cpu.d[dreg];
        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, size);
        let dst = ea_res.val;
        let res = dst & src;
        ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
        if size == 1 { cpu_set_nz8(cpu, res as! u8); }
        else if size == 2 { cpu_set_nz16(cpu, res as! u16); }
        else { cpu_set_nz32(cpu, res); }
    } else {
        let src = ea_read(cpu, mmu, mode, reg, size);
        let dst = cpu.d[dreg];
        let res = dst & src;
        if size == 1 { cpu.d[dreg] = (cpu.d[dreg] & 0xFFFFFF00) | (res & 0xFF); cpu_set_nz8(cpu, res as! u8); }
        else if size == 2 { cpu.d[dreg] = (cpu.d[dreg] & 0xFFFF0000) | (res & 0xFFFF); cpu_set_nz16(cpu, res as! u16); }
        else { cpu.d[dreg] = res; cpu_set_nz32(cpu, res); }
    }
    return alu_bin_cycles(size, mode, reg, is_ea_dst);
}

// -------------------------------------------------------------
// Op 9 & Op D: SUB, SUBA, SUBX, ADD, ADDA, ADDX
// -------------------------------------------------------------
fn exec_op9_sub(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    let reg_field = ((op >> 9) & 0x07) as! i32;
    let opmode = ((op >> 6) & 0x07) as! i32;
    let mode = ((op >> 3) & 0x07) as! i32;
    let reg = (op & 0x07) as! i32;

    // SUBA
    if opmode == 3 || opmode == 7 {
        let is_long = (opmode == 7);
        let src = ea_read(cpu, mmu, mode, reg, if is_long { 4 } else { 2 });
        let ext_src = if is_long { src } else { ((src as! i16) as! i32) as! u32 };
        if mmu.fault == 0 { cpu.a[reg_field] -= ext_src; }
        return adda_cycles(is_long, mode, reg);
    }

    // SUBX (1001 Rx 1 ss 00 R/M Ry)
    if (op & 0x0130) == 0x0100 && ((op >> 6) & 3) <= 2 {
        let size_code = ((op >> 6) & 3) as! i32;
        let size: i32 = if size_code == 0 { 1 } else if size_code == 1 { 2 } else { 4 };
        let is_mem = (op & 0x0008) != 0;
        let rx = reg_field;
        let ry = reg;
        let x_val = if cpu_flag_x(cpu) { 1 as! u32 } else { 0 as! u32 };

        if is_mem {
            let delta = if rx == 7 && size == 1 { 2 } else { size };
            let s_delta = if ry == 7 && size == 1 { 2 } else { size };
            cpu.a[ry] -= s_delta as! u32;
            cpu.a[rx] -= delta as! u32;
            let src = if size == 1 { mmu_read8(mmu, cpu.a[ry]) as! u32 }
                      else if size == 2 { mmu_read16(mmu, cpu.a[ry]) as! u32 }
                      else { mmu_read32(mmu, cpu.a[ry]) };
            let dst = if size == 1 { mmu_read8(mmu, cpu.a[rx]) as! u32 }
                      else if size == 2 { mmu_read16(mmu, cpu.a[rx]) as! u32 }
                      else { mmu_read32(mmu, cpu.a[rx]) };
            let res = dst - src - x_val;
            if size == 1 {
                mmu_write8(mmu, cpu.a[rx], res as! u8);
                cpu_flags_subx8(cpu, src as! u8, dst as! u8, res as! u8);
            } else if size == 2 {
                mmu_write16(mmu, cpu.a[rx], res as! u16);
                cpu_flags_subx16(cpu, src as! u16, dst as! u16, res as! u16);
            } else {
                mmu_write32(mmu, cpu.a[rx], res);
                cpu_flags_subx32(cpu, src, dst, res);
            }
            return if size == 4 { 30 } else { 18 };
        } else {
            let src = cpu.d[ry];
            let dst = cpu.d[rx];
            let res = dst - src - x_val;
            if size == 1 {
                cpu.d[rx] = (cpu.d[rx] & 0xFFFFFF00) | (res & 0xFF);
                cpu_flags_subx8(cpu, src as! u8, dst as! u8, res as! u8);
            } else if size == 2 {
                cpu.d[rx] = (cpu.d[rx] & 0xFFFF0000) | (res & 0xFFFF);
                cpu_flags_subx16(cpu, src as! u16, dst as! u16, res as! u16);
            } else {
                cpu.d[rx] = res;
                cpu_flags_subx32(cpu, src, dst, res);
            }
            return if size == 4 { 8 } else { 4 };
        }
    }

    let size: i32 = if (opmode & 3) == 0 { 1 } else if (opmode & 3) == 1 { 2 } else { 4 };
    let is_ea_dst = (opmode & 4) != 0;

    if is_ea_dst {
        let src = cpu.d[reg_field];
        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, size);
        let dst = ea_res.val;
        let res = dst - src;
        ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
        if size == 1 { cpu_flags_sub8(cpu, src as! u8, dst as! u8, res as! u8, true); }
        else if size == 2 { cpu_flags_sub16(cpu, src as! u16, dst as! u16, res as! u16, true); }
        else { cpu_flags_sub32(cpu, src, dst, res, true); }
    } else {
        let src = ea_read(cpu, mmu, mode, reg, size);
        let dst = cpu.d[reg_field];
        let res = dst - src;
        if size == 1 {
            cpu.d[reg_field] = (cpu.d[reg_field] & 0xFFFFFF00) | (res & 0xFF);
            cpu_flags_sub8(cpu, src as! u8, dst as! u8, res as! u8, true);
        } else if size == 2 {
            cpu.d[reg_field] = (cpu.d[reg_field] & 0xFFFF0000) | (res & 0xFFFF);
            cpu_flags_sub16(cpu, src as! u16, dst as! u16, res as! u16, true);
        } else {
            cpu.d[reg_field] = res;
            cpu_flags_sub32(cpu, src, dst, res, true);
        }
    }
    return alu_bin_cycles(size, mode, reg, is_ea_dst);
}

fn exec_opD_add(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    let reg_field = ((op >> 9) & 0x07) as! i32;
    let opmode = ((op >> 6) & 0x07) as! i32;
    let mode = ((op >> 3) & 0x07) as! i32;
    let reg = (op & 0x07) as! i32;

    // ADDA
    if opmode == 3 || opmode == 7 {
        let is_long = (opmode == 7);
        let src = ea_read(cpu, mmu, mode, reg, if is_long { 4 } else { 2 });
        let ext_src = if is_long { src } else { ((src as! i16) as! i32) as! u32 };
        if mmu.fault == 0 { cpu.a[reg_field] += ext_src; }
        return adda_cycles(is_long, mode, reg);
    }

    // ADDX (1101 Rx 1 ss 00 R/M Ry)
    if (op & 0x0130) == 0x0100 && ((op >> 6) & 3) <= 2 {
        let size_code = ((op >> 6) & 3) as! i32;
        let size: i32 = if size_code == 0 { 1 } else if size_code == 1 { 2 } else { 4 };
        let is_mem = (op & 0x0008) != 0;
        let rx = reg_field;
        let ry = reg;
        let x_val = if cpu_flag_x(cpu) { 1 as! u32 } else { 0 as! u32 };

        if is_mem {
            let delta = if rx == 7 && size == 1 { 2 } else { size };
            let s_delta = if ry == 7 && size == 1 { 2 } else { size };
            cpu.a[ry] -= s_delta as! u32;
            cpu.a[rx] -= delta as! u32;
            let src = if size == 1 { mmu_read8(mmu, cpu.a[ry]) as! u32 }
                      else if size == 2 { mmu_read16(mmu, cpu.a[ry]) as! u32 }
                      else { mmu_read32(mmu, cpu.a[ry]) };
            let dst = if size == 1 { mmu_read8(mmu, cpu.a[rx]) as! u32 }
                      else if size == 2 { mmu_read16(mmu, cpu.a[rx]) as! u32 }
                      else { mmu_read32(mmu, cpu.a[rx]) };
            let res = dst + src + x_val;
            if size == 1 {
                mmu_write8(mmu, cpu.a[rx], res as! u8);
                cpu_flags_addx8(cpu, src as! u8, dst as! u8, res as! u8);
            } else if size == 2 {
                mmu_write16(mmu, cpu.a[rx], res as! u16);
                cpu_flags_addx16(cpu, src as! u16, dst as! u16, res as! u16);
            } else {
                mmu_write32(mmu, cpu.a[rx], res);
                cpu_flags_addx32(cpu, src, dst, res);
            }
            return if size == 4 { 30 } else { 18 };
        } else {
            let src = cpu.d[ry];
            let dst = cpu.d[rx];
            let res = dst + src + x_val;
            if size == 1 {
                cpu.d[rx] = (cpu.d[rx] & 0xFFFFFF00) | (res & 0xFF);
                cpu_flags_addx8(cpu, src as! u8, dst as! u8, res as! u8);
            } else if size == 2 {
                cpu.d[rx] = (cpu.d[rx] & 0xFFFF0000) | (res & 0xFFFF);
                cpu_flags_addx16(cpu, src as! u16, dst as! u16, res as! u16);
            } else {
                cpu.d[rx] = res;
                cpu_flags_addx32(cpu, src, dst, res);
            }
            return if size == 4 { 8 } else { 4 };
        }
    }

    let size: i32 = if (opmode & 3) == 0 { 1 } else if (opmode & 3) == 1 { 2 } else { 4 };
    let is_ea_dst = (opmode & 4) != 0;

    if is_ea_dst {
        let src = cpu.d[reg_field];
        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, size);
        let dst = ea_res.val;
        let res = dst + src;
        ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
        if size == 1 { cpu_flags_add8(cpu, src as! u8, dst as! u8, res as! u8); }
        else if size == 2 { cpu_flags_add16(cpu, src as! u16, dst as! u16, res as! u16); }
        else { cpu_flags_add32(cpu, src, dst, res); }
    } else {
        let src = ea_read(cpu, mmu, mode, reg, size);
        let dst = cpu.d[reg_field];
        let res = dst + src;
        if size == 1 {
            cpu.d[reg_field] = (cpu.d[reg_field] & 0xFFFFFF00) | (res & 0xFF);
            cpu_flags_add8(cpu, src as! u8, dst as! u8, res as! u8);
        } else if size == 2 {
            cpu.d[reg_field] = (cpu.d[reg_field] & 0xFFFF0000) | (res & 0xFFFF);
            cpu_flags_add16(cpu, src as! u16, dst as! u16, res as! u16);
        } else {
            cpu.d[reg_field] = res;
            cpu_flags_add32(cpu, src, dst, res);
        }
    }
    return alu_bin_cycles(size, mode, reg, is_ea_dst);
}

// -------------------------------------------------------------
// Op B: CMP, CMPA, EOR, CMPM
// -------------------------------------------------------------
fn exec_opB_cmp_eor(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    let reg_field = ((op >> 9) & 0x07) as! i32;
    let opmode = ((op >> 6) & 0x07) as! i32;
    let mode = ((op >> 3) & 0x07) as! i32;
    let reg = (op & 0x07) as! i32;

    // CMPA
    if opmode == 3 || opmode == 7 {
        let is_long = (opmode == 7);
        let src = ea_read(cpu, mmu, mode, reg, if is_long { 4 } else { 2 });
        let ext_src = if is_long { src } else { ((src as! i16) as! i32) as! u32 };
        let dst = cpu.a[reg_field];
        let res = dst - ext_src;
        cpu_flags_sub32(cpu, ext_src, dst, res, false);
        return 6 + ea_extra_cycles(mode, reg, if is_long { 4 } else { 2 });
    }

    // CMPM (Ay)+, (Ax)+: 1011 rrr 1 ss 001 rrr
    if (op & 0x0138) == 0x0108 {
        let size_code = ((op >> 6) & 0x03) as! i32;
        let size: i32 = if size_code == 0 { 1 } else if size_code == 1 { 2 } else { 4 };
        let ay = (op & 0x07) as! i32;
        let ax = ((op >> 9) & 0x07) as! i32;

        let src_addr = cpu.a[ay];
        let src = if size == 1 { mmu_read8(mmu, src_addr) as! u32 }
                  else if size == 2 { mmu_read16(mmu, src_addr) as! u32 }
                  else { mmu_read32(mmu, src_addr) };
        if size == 1 && ay == 7 { cpu.a[ay] += 2; }
        else { cpu.a[ay] += size as! u32; }

        let dst_addr = cpu.a[ax];
        let dst = if size == 1 { mmu_read8(mmu, dst_addr) as! u32 }
                  else if size == 2 { mmu_read16(mmu, dst_addr) as! u32 }
                  else { mmu_read32(mmu, dst_addr) };
        if size == 1 && ax == 7 { cpu.a[ax] += 2; }
        else { cpu.a[ax] += size as! u32; }

        let res = dst - src;
        if size == 1 { cpu_flags_sub8(cpu, src as! u8, dst as! u8, res as! u8, false); }
        else if size == 2 { cpu_flags_sub16(cpu, src as! u16, dst as! u16, res as! u16, false); }
        else { cpu_flags_sub32(cpu, src, dst, res, false); }
        return if size == 4 { 20 } else { 12 };
    }

    let size: i32 = if (opmode & 3) == 0 { 1 } else if (opmode & 3) == 1 { 2 } else { 4 };
    let is_eor = (opmode & 4) != 0;

    if is_eor {
        // EOR Dn, <ea>
        let src = cpu.d[reg_field];
        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, size);
        let dst = ea_res.val;
        let res = dst ^ src;
        ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
        if size == 1 { cpu_set_nz8(cpu, res as! u8); }
        else if size == 2 { cpu_set_nz16(cpu, res as! u16); }
        else { cpu_set_nz32(cpu, res); }
        return eor_cycles(size, mode, reg);
    } else {
        // CMP <ea>, Dn
        let src = ea_read(cpu, mmu, mode, reg, size);
        let dst = cpu.d[reg_field];
        let res = dst - src;
        if size == 1 { cpu_flags_sub8(cpu, src as! u8, dst as! u8, res as! u8, false); }
        else if size == 2 { cpu_flags_sub16(cpu, src as! u16, dst as! u16, res as! u16, false); }
        else { cpu_flags_sub32(cpu, src, dst, res, false); }
        return cmp_cycles(size, mode, reg);
    }
}

// -------------------------------------------------------------
// Op E: シフト & ローテート (ASL, ASR, LSL, LSR, ROL, ROR, ROXL, ROXR)
// -------------------------------------------------------------
fn exec_opE_shift_rotate(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    let mode = ((op >> 3) & 0x07) as! i32;
    let reg = (op & 0x07) as! i32;
    let is_memory = ((op >> 6) & 0x03) == 3;

    if is_memory { // Memory shift (16-bit, 1 bit shift)
        let is_left = (op & 0x0100) != 0;
        let shift_type = ((op >> 9) & 0x03) as! i32; // 0=AS, 1=LS, 2=ROX, 3=RO
        let addr = ea_calc_addr(cpu, mmu, mode, reg, 2);
        var val = mmu_read16(mmu, addr) as! u32;

        var carry = false;
        let old_x = cpu_flag_x(cpu);
        // ASL だけ、シフト中に MSB が変わったら V。C68K の符号ビットマスクと同じ。
        var asl_v = false;
        if is_left && shift_type == 0 {
            asl_v = ((val & 0x8000) != 0) != ((val & 0x4000) != 0);
        }

        if is_left {
            carry = (val & 0x8000) != 0;
            let in_bit: u32 = if shift_type == 2 {
                if old_x { 1 } else { 0 }
            } else if shift_type == 3 {
                if carry { 1 } else { 0 }
            } else {
                0
            };
            val = ((val << 1) & 0xFFFF) | in_bit;
        } else {
            carry = (val & 0x0001) != 0;
            if shift_type == 0 { // ASR
                val = ((val as! i16) >> 1) as! u16 as! u32;
            } else {
                let msb: u32 = if shift_type == 2 {
                    if old_x { 0x8000 } else { 0 }
                } else if shift_type == 3 {
                    if carry { 0x8000 } else { 0 }
                } else {
                    0
                };
                val = ((val >> 1) & 0xFFFF) | msb;
            }
        }

        mmu_write16(mmu, addr, val as! u16);
        if carry {
            cpu.sr |= (SR_C as! u16);
            if shift_type != 3 { cpu.sr |= (SR_X as! u16); }
        } else {
            cpu.sr &= ~(SR_C as! u16);
            if shift_type != 3 { cpu.sr &= ~(SR_X as! u16); }
        }
        cpu_set_nz16_only(cpu, val as! u16);
        if asl_v { cpu.sr |= (SR_V as! u16); } else { cpu.sr &= ~(SR_V as! u16); }
        return shift_mem_cycles(mode, reg);
    }

    // Register shift
    let count_field = ((op >> 9) & 0x07) as! i32;
    let is_left = (op & 0x0100) != 0;
    let sz_code = ((op >> 6) & 0x03) as! i32;
    let is_reg_count = (op & 0x0020) != 0;
    let shift_type = ((op >> 3) & 0x03) as! i32; // 0=AS, 1=LS, 2=ROX, 3=RO
    let dreg = reg;

    let size: i32 = if sz_code == 0 { 1 } else if sz_code == 1 { 2 } else { 4 };
    var count = if is_reg_count { (cpu.d[count_field] & 63) as! i32 }
                else { if count_field == 0 { 8 } else { count_field } };

    if count == 0 {
        if shift_type == 2 { // ROXL / ROXR: C takes X
            if cpu_flag_x(cpu) { cpu.sr |= (SR_C as! u16); }
            else { cpu.sr &= ~(SR_C as! u16); }
        } else {
            cpu.sr &= ~(SR_C as! u16);
        }
        cpu.sr &= ~(SR_V as! u16);
        if size == 1 { cpu_set_nz8_only(cpu, cpu.d[dreg] as! u8); }
        else if size == 2 { cpu_set_nz16_only(cpu, cpu.d[dreg] as! u16); }
        else { cpu_set_nz32_only(cpu, cpu.d[dreg]); }
        return shift_reg_cycles(size, 0);
    }

    var v = cpu.d[dreg];
    var last_c = false;
    var current_x = cpu_flag_x(cpu);
    var asl_v = false;

    for _ in count {
        if is_left {
            if size == 1 {
                last_c = (v & 0x80) != 0;
                let in_bit: u32 = if shift_type == 2 {
                    if current_x { 1 } else { 0 }
                } else if shift_type == 3 {
                    if last_c { 1 } else { 0 }
                } else {
                    0
                };
                v = (v & 0xFFFFFF00) | (((v << 1) & 0xFF) | in_bit);
                if shift_type == 0 && ((v & 0x80) != 0) != last_c { asl_v = true; }
            } else if size == 2 {
                last_c = (v & 0x8000) != 0;
                let in_bit: u32 = if shift_type == 2 {
                    if current_x { 1 } else { 0 }
                } else if shift_type == 3 {
                    if last_c { 1 } else { 0 }
                } else {
                    0
                };
                v = (v & 0xFFFF0000) | (((v << 1) & 0xFFFF) | in_bit);
                if shift_type == 0 && ((v & 0x8000) != 0) != last_c { asl_v = true; }
            } else {
                last_c = (v & 0x80000000) != 0;
                let in_bit: u32 = if shift_type == 2 {
                    if current_x { 1 } else { 0 }
                } else if shift_type == 3 {
                    if last_c { 1 } else { 0 }
                } else {
                    0
                };
                v = (v << 1) | in_bit;
                if shift_type == 0 && ((v & 0x80000000) != 0) != last_c { asl_v = true; }
            }
            if shift_type == 2 {
                current_x = last_c;
            }
        } else {
            last_c = (v & 1) != 0;
            if size == 1 {
                let msb: u32 = if shift_type == 0 {
                    v & 0x80
                } else if shift_type == 2 {
                    if current_x { 0x80 } else { 0 }
                } else if shift_type == 3 {
                    if last_c { 0x80 } else { 0 }
                } else {
                    0
                };
                v = (v & 0xFFFFFF00) | (((v & 0xFF) >> 1) | msb);
            } else if size == 2 {
                let msb: u32 = if shift_type == 0 {
                    v & 0x8000
                } else if shift_type == 2 {
                    if current_x { 0x8000 } else { 0 }
                } else if shift_type == 3 {
                    if last_c { 0x8000 } else { 0 }
                } else {
                    0
                };
                v = (v & 0xFFFF0000) | (((v & 0xFFFF) >> 1) | msb);
            } else {
                let msb: u32 = if shift_type == 0 {
                    v & 0x80000000
                } else if shift_type == 2 {
                    if current_x { 0x80000000 } else { 0 }
                } else if shift_type == 3 {
                    if last_c { 0x80000000 } else { 0 }
                } else {
                    0
                };
                v = (v >> 1) | msb;
            }
            if shift_type == 2 {
                current_x = last_c;
            }
        }
    }

    cpu.d[dreg] = v;
    if last_c {
        cpu.sr |= (SR_C as! u16);
        if shift_type != 3 { cpu.sr |= (SR_X as! u16); }
    } else {
        cpu.sr &= ~(SR_C as! u16);
        if shift_type != 3 { cpu.sr &= ~(SR_X as! u16); }
    }
    if size == 1 { cpu_set_nz8_only(cpu, v as! u8); }
    else if size == 2 { cpu_set_nz16_only(cpu, v as! u16); }
    else { cpu_set_nz32_only(cpu, v); }
    if asl_v { cpu.sr |= (SR_V as! u16); } else { cpu.sr &= ~(SR_V as! u16); }
    return shift_reg_cycles(size, count);
}

// -------------------------------------------------------------
// 1命令を実行して消費サイクル数を返す
// -------------------------------------------------------------
fn m68k_step_core(cpu: M68kCPU&, mmu: M68kMMU&) -> i32 {
    // The 68000 keeps all 32 PC bits even though it drives 24 address lines. The IPL
    // exception handlers rely on it: vectors such as $02FF0540 carry the vector number
    // in the top byte, which BSR then pushes for the handler to read.
    if cpu.halted {
        return 4;
    }

    let inst_pc = cpu.pc;
    mmu.debug_pc = inst_pc;
    let op = fetch16(cpu, mmu);
    mmu.cur_ir = op;
    let hi4 = (op >> 12) & 0x0F;

    if mmu.trace_steps > 0 {
        mmu.trace_steps--;
        write_stderr("[TRACE PC=0x");
        c_eprint_hex(inst_pc);
        write_stderr(" OP=0x");
        c_eprint_hex16(op);
        write_stderr(" D0=0x");
        c_eprint_hex(cpu.d[0]);
        write_stderr(" D1=0x");
        c_eprint_hex(cpu.d[1]);
        write_stderr(" A0=0x");
        c_eprint_hex(cpu.a[0]);
        write_stderr(" A1=0x");
        c_eprint_hex(cpu.a[1]);
        write_stderr(" SP=0x");
        c_eprint_hex(cpu.a[REG_A7]);
        write_stderr("]\n");
    }

    // Op 0: ビット操作 & 即値演算
    if hi4 == 0 {
        return exec_op0(cpu, mmu, op);
    }

    // Op 1, 2, 3: MOVE / MOVEA
    if hi4 == 1 || hi4 == 2 || hi4 == 3 {
        let size: i32 = if hi4 == 1 { 1 } else if hi4 == 3 { 2 } else { 4 };
        let src_mode = ((op >> 3) & 0x07) as! i32;
        let src_reg = (op & 0x07) as! i32;
        let dst_reg = ((op >> 9) & 0x07) as! i32;
        let dst_mode = ((op >> 6) & 0x07) as! i32;

        let val = ea_read(cpu, mmu, src_mode, src_reg, size);
        ea_write(cpu, mmu, dst_mode, dst_reg, size, val);

        if dst_mode != 1 { // MOVEA does not affect flags
            if size == 1 { cpu_set_nz8(cpu, val as! u8); }
            else if size == 2 { cpu_set_nz16(cpu, val as! u16); }
            else { cpu_set_nz32(cpu, val); }
        }
        return move_cycles(size, src_mode, src_reg, dst_mode, dst_reg);
    }

    // Op 4: 雑多命令 (LEA, PEA, MOVEM, CLR, NEG, NOT, TST, JMP, JSR, TRAP, LINK, UNLK, MOVE to/from SR/CCR/USP)
    if hi4 == 4 {
        return exec_op4(cpu, mmu, op);
    }

    // Op 5: ADDQ, SUBQ, Scc, DBcc
    if hi4 == 5 {
        // DBcc (0101 cccc 1100 1rrr)
        if (op & 0xF0F8) == 0x50C8 {
            let cond = ((op >> 8) & 0x0F) as! i32;
            let dreg = (op & 0x07) as! i32;
            let disp = (fetch16(cpu, mmu) as! i16) as! i32;
            if !cpu_check_condition(cpu, cond) {
                let count = (cpu.d[dreg] & 0xFFFF) as! i32 - 1;
                cpu.d[dreg] = (cpu.d[dreg] & 0xFFFF0000) | ((count & 0xFFFF) as! u32);
                if count != -1 {
                    cpu.pc = ((cpu.pc as! i32) + disp - 2) as! u32;
                    return 10;
                }
                return 14;
            }
            return 12;
        }

        // Scc (0101 cccc 11 eee eee)
        if (op & 0xF0C0) == 0x50C0 {
            let cond = ((op >> 8) & 0x0F) as! i32;
            let mode = ((op >> 3) & 0x07) as! i32;
            let reg = (op & 0x07) as! i32;
            let set = cpu_check_condition(cpu, cond);
            ea_write(cpu, mmu, mode, reg, 1, if set { 0xFF } else { 0 });
            if mode == 0 { return if set { 6 } else { 4 }; }
            return 8 + ea_bw_extra(mode, reg);
        }

        // ADDQ / SUBQ
        var q = ((op >> 9) & 0x07) as! u32;
        if q == 0 { q = 8; }
        let is_sub = (op & 0x0100) != 0;
        let sz_code = ((op >> 6) & 0x03) as! i32;
        let mode = ((op >> 3) & 0x07) as! i32;
        let reg = (op & 0x07) as! i32;
        let size: i32 = if sz_code == 0 { 1 } else if sz_code == 1 { 2 } else { 4 };

        if mode == 1 { // An: ADDQ.W or ADDQ.L to address register does not affect flags
            let cur = cpu.a[reg];
            cpu.a[reg] = if is_sub { cur - q } else { cur + q };
            return addq_cycles(size, mode, reg);
        }

        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, size);
        let cur = ea_res.val;
        let res = if is_sub { cur - q } else { cur + q };
        ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
        if is_sub {
            if size == 1 { cpu_flags_sub8(cpu, q as! u8, cur as! u8, res as! u8, true); }
            else if size == 2 { cpu_flags_sub16(cpu, q as! u16, cur as! u16, res as! u16, true); }
            else { cpu_flags_sub32(cpu, q, cur, res, true); }
        } else {
            if size == 1 { cpu_flags_add8(cpu, q as! u8, cur as! u8, res as! u8); }
            else if size == 2 { cpu_flags_add16(cpu, q as! u16, cur as! u16, res as! u16); }
            else { cpu_flags_add32(cpu, q, cur, res); }
        }
        return addq_cycles(size, mode, reg);
    }

    // Op 6: BRA (disp8/16), BSR, Bcc
    if hi4 == 6 {
        let cond = ((op >> 8) & 0x0F) as! i32;
        let base_pc = cpu.pc;
        var disp = (op & 0xFF) as! i8 as! i32;
        if disp == 0 {
            disp = (fetch16(cpu, mmu) as! i16) as! i32;
        }

        let target = ((base_pc as! i32) + disp) as! u32;

        let word_disp = (op & 0xFF) == 0;
        if cond == 0 { // BRA
            cpu.pc = target;
            return 10;
        }
        if cond == 1 { // BSR
            push32(cpu, mmu, cpu.pc);
            cpu.pc = target;
            return 18;
        }
        // Bcc
        if cpu_check_condition(cpu, cond) {
            cpu.pc = target;
            return bcc_cycles(word_disp, true);
        }
        return bcc_cycles(word_disp, false);
    }

    // Op 7: MOVEQ (0111 ddd0 data8)
    if hi4 == 7 {
        let dreg = ((op >> 9) & 0x07) as! i32;
        let data8 = (op & 0xFF) as! i8;
        cpu.d[dreg] = (data8 as! i32) as! u32;
        cpu_set_nz32(cpu, cpu.d[dreg]);
        return 4;
    }

    // Op 8: OR, DIVU, DIVS
    if hi4 == 8 {
        return exec_op8_or_div(cpu, mmu, op);
    }

    // Op 9: SUB, SUBA, SUBX
    if hi4 == 9 {
        return exec_op9_sub(cpu, mmu, op);
    }

    // Op B: CMP, CMPA, EOR, CMPM
    if hi4 == 0x0B {
        return exec_opB_cmp_eor(cpu, mmu, op);
    }

    // Op C: AND, MULU, MULS, EXG
    if hi4 == 0x0C {
        return exec_opC_and_mul_exg(cpu, mmu, op);
    }

    // Op D: ADD, ADDA, ADDX
    if hi4 == 0x0D {
        return exec_opD_add(cpu, mmu, op);
    }

    // Op E: シフト & ローテート
    if hi4 == 0x0E {
        return exec_opE_shift_rotate(cpu, mmu, op);
    }

    // Op A: Line 1010 Emulator Exception (Vector 10)
    if hi4 == 0x0A {
        m68k_trigger_exception(cpu, mmu, 10, inst_pc);
        return 34;
    }

    // Op F: Line 1111 Emulator Exception (Vector 11, Human68k DOS call)
    if hi4 == 0x0F {
        m68k_trigger_exception(cpu, mmu, 11, inst_pc);
        return 34;
    }

    // 未知・未実装オプコード: Illegal Instruction Exception (Vector 4)
    write_stderr(str("!!! UNIMPLEMENTED OPCODE: 0x", op as! u32, " at PC=0x", inst_pc, " !!!\n"));
    m68k_trigger_exception(cpu, mmu, 4, inst_pc);
    return 8;
}

// Group 0 exception (2 = bus error, 3 = address error) after a faulted instruction.
// Matches XEiJ: data registers and SR are rolled back, address register updates made
// before the fault stay, and the frame holds the opcode and the instruction address.
fn m68k_group0(cpu: M68kCPU&, mmu: M68kMMU&, d: u32[8], sr: u16) {
    let vector = mmu.fault;
    let addr = mmu.fault_addr;
    let write = mmu.fault_write;
    mmu.fault = 0;
    mmu.user_mode = false;
    cpu.d = d;
    cpu_set_sr(cpu, sr);
    if !cpu_is_supervisor(cpu) {
        cpu.usp = cpu.a[REG_A7];
        cpu.a[REG_A7] = cpu.ssp;
    }
    push32(cpu, mmu, mmu.debug_pc);
    push16(cpu, mmu, sr);
    push16(cpu, mmu, mmu.cur_ir);
    push32(cpu, mmu, addr);
    push16(cpu, mmu, if write { 0 } else { 0x10 });
    if mmu.fault != 0 { // fault while stacking: the 68000 halts
        mmu.fault = 0;
        cpu.halted = true;
        return;
    }
    cpu.sr |= (SR_S as! u16);
    cpu.sr &= ~(SR_T as! u16);
    cpu.pc = mmu_read32(mmu, ((vector * 4) as! u32));
}

fn m68k_step(cpu: M68kCPU&, mmu: M68kMMU&) -> i32 {
    let d = cpu.d;
    let sr = cpu.sr;
    mmu.user_mode = !cpu_is_supervisor(cpu);
    mmu.cpu_access = true;
    var cycles = m68k_step_core(cpu, mmu);
    // A jump to an odd address faults in the jumping instruction.
    if mmu.fault == 0 && (cpu.pc & 1) != 0 && !cpu.halted {
        mmu_fault(mmu, 3, cpu.pc & 0x00FFFFFF, false);
    }
    if mmu.fault != 0 {
        m68k_group0(cpu, mmu, d, sr);
        cycles += 50;
    }
    mmu.cpu_access = false;
    cycles += mmu.wait40 / 40;
    mmu.wait40 = mmu.wait40 % 40;
    return cycles;
}

// M68000 割り込み処理 (Level: 1..7, Vector: 0..255)
fn m68k_interrupt(cpu: M68kCPU&, mmu: M68kMMU&, level: i32, vector: i32) {
    if !cpu_is_supervisor(cpu) {
        // ユーザモードからスーパーバイザモードへの移行
        cpu.usp = cpu.a[REG_A7];
        cpu.a[REG_A7] = cpu.ssp;
    }

    // 現在の PC と SR をスーパーバイザスタックにプッシュ
    push32(cpu, mmu, cpu.pc);
    push16(cpu, mmu, cpu.sr);

    // スーパーバイザフラグをセット、トレースをオフ
    cpu.sr |= (SR_S as! u16);
    cpu.sr &= ~(SR_T as! u16);

    // 割込マスクを更新 (レベルを設定)
    cpu.sr = (cpu.sr & ~0x0700) | (((level & 7) as! u16) << 8);

    // ベクタアドレスから新しい PC を取得
    let vec_addr = ((vector & 0xFF) * 4) as! u32;
    cpu.pc = mmu_read32(mmu, vec_addr);
    cpu.halted = false;
}
