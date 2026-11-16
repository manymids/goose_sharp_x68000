// Motorola 68000 の命令のデコードと実行

import .m68k_types;
import .m68k_cpu;
import .m68k_mmu;
namespace m68k;

// PC から次の 16bit ワードをフェッチ
fn fetch16(cpu: M68kCPU&, mmu: M68kMMU&) -> u16 {
    let val = mmu.read16(cpu.pc);
    cpu.pc += 2;
    return val;
}

// PC から次の 32bit ロングワードをフェッチ
fn fetch32(cpu: M68kCPU&, mmu: M68kMMU&) -> u32 {
    let hi: u32 = fetch16(cpu, mmu);
    let lo: u32 = fetch16(cpu, mmu);
    return (hi << 16) | lo;
}

// スタック push / pop
fn push16(cpu: M68kCPU&, mmu: M68kMMU&, val: u16) {
    cpu.a[REG_A7] -= 2;
    mmu.write16(cpu.a[REG_A7], val);
}

fn push32(cpu: M68kCPU&, mmu: M68kMMU&, val: u32) {
    cpu.a[REG_A7] -= 4;
    mmu.write32(cpu.a[REG_A7], val);
}

fn pop16(cpu: M68kCPU&, mmu: M68kMMU&) -> u16 {
    let val = mmu.read16(cpu.a[REG_A7]);
    cpu.a[REG_A7] += 2;
    return val;
}

fn pop32(cpu: M68kCPU&, mmu: M68kMMU&) -> u32 {
    let val = mmu.read32(cpu.a[REG_A7]);
    cpu.a[REG_A7] += 4;
    return val;
}

// Dn の下位 size バイトだけを書き換える。
fn dreg_write(cpu: M68kCPU&, reg: i32, size: i32, val: u32) {
    let mask = cpu::size_mask(size);
    cpu.d[reg] = (cpu.d[reg] & ~mask) | (val & mask);
}

// アドレスに符号付きの変位を足す。32 bit で折り返す (符号付き加算だとデバッグビルドで桁あふれ検査に掛かる)。
fn addr_add(base: u32, disp: i32) -> u32 {
    return base + (disp as! u32);
}

// サイズ付きのメモリ読み書き (1 = byte, 2 = word, 4 = long)
fn mem_read(mmu: M68kMMU&, addr: u32, size: i32) -> u32 {
    if size == 1 { return mmu.read8(addr); }
    if size == 2 { return mmu.read16(addr); }
    return mmu.read32(addr);
}

fn mem_write(mmu: M68kMMU&, addr: u32, size: i32, val: u32) {
    if size == 1 { mmu.write8(addr, val as! u8); }
    else if size == 2 { mmu.write16(addr, val as! u16); }
    else { mmu.write32(addr, val); }
}

// -(An)。A7 のバイトはスタックを偶数に保つため 2 減らす。
fn predec(cpu: M68kCPU&, reg: i32, size: i32) -> u32 {
    let delta: u32 = if reg == 7 && size == 1 { 2 } else { size as! u32 };
    cpu.a[reg] -= delta;
    return cpu.a[reg];
}

fn flags_addsub(cpu: M68kCPU&, is_add: bool, size: i32, src: u32, dst: u32, res: u32) {
    if is_add { cpu.flags_add(size, src, dst, res); } else { cpu.flags_sub(size, src, dst, res, true); }
}

fn flags_addsubx(cpu: M68kCPU&, is_add: bool, size: i32, src: u32, dst: u32, res: u32) {
    if is_add { cpu.flags_addx(size, src, dst, res); } else { cpu.flags_subx(size, src, dst, res); }
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
        return addr_add(cpu.a[reg], d16);
    }
    if mode == 6 { // (d8, An, Xn)
        let ext = fetch16(cpu, mmu);
        let d8 = (ext & 0xFF) as! i8;
        let xreg: i32 = (ext >> 12) & 0x07;
        let is_a = (ext & 0x8000) != 0;
        let is_long = (ext & 0x0800) != 0;
        var xval: i32 = 0;
        if is_a {
            xval = if is_long { cpu.a[xreg] as! i32 } else { (cpu.a[xreg] as! i16) };
        } else {
            xval = if is_long { cpu.d[xreg] as! i32 } else { (cpu.d[xreg] as! i16) };
        }
        return addr_add(addr_add(cpu.a[reg], d8), xval);
    }
    if mode == 7 {
        if reg == 0 { // (xxx).W
            // 符号拡張した 32bit を返す。バスは mmu 側で 24bit に切る。
            // ここで切ると PEA/LEA が 0xFFFFFFFF ではなく ADDR_MASK になる。
            let w = fetch16(cpu, mmu) as! i16;
            return (w) as! u32;
        }
        if reg == 1 { // (xxx).L
            return fetch32(cpu, mmu);
        }
        if reg == 2 { // (d16, PC)
            let pc_base = cpu.pc;
            let d16 = fetch16(cpu, mmu) as! i16;
            return addr_add(pc_base, d16);
        }
        if reg == 3 { // (d8, PC, Xn)
            let pc_base = cpu.pc;
            let ext = fetch16(cpu, mmu);
            let d8 = (ext & 0xFF) as! i8;
            let xreg: i32 = (ext >> 12) & 0x07;
            let is_a = (ext & 0x8000) != 0;
            let is_long = (ext & 0x0800) != 0;
            var xval: i32 = 0;
            if is_a {
                xval = if is_long { cpu.a[xreg] as! i32 } else { (cpu.a[xreg] as! i16) };
            } else {
                xval = if is_long { cpu.d[xreg] as! i32 } else { (cpu.d[xreg] as! i16) };
            }
            return addr_add(addr_add(pc_base, d8), xval);
        }
    }
    return 0;
}

struct EAResult {
    addr: u32,
    val: u32,
}
type ::EAResult = m68k::EAResult;

// Read-Modify-Write (RMW) 用の EA 読み出し (アドレス計算を 1 度だけ行う)
fn ea_read_for_rmw(cpu: M68kCPU&, mmu: M68kMMU&, mode: i32, reg: i32, size: i32) -> EAResult {
    if mode == 0 { // Dn
        let v = if size == 1 { cpu.d[reg] & 0xFF }
                else if size == 2 { cpu.d[reg] & 0xFFFF }
                else { cpu.d[reg] };
        return EAResult { addr: 0, val: v };
    }
    if mode == 1 { // An
        let v = if size == 2 { ((cpu.a[reg] as! i16)) as! u32 }
                else { cpu.a[reg] };
        return EAResult { addr: 0, val: v };
    }
    let addr = ea_calc_addr(cpu, mmu, mode, reg, size);
    let v = mem_read(mmu, addr, size);
    return EAResult { addr: addr, val: v };
}

// Read-Modify-Write (RMW) 用の EA 書き込み (保持したアドレスに直接書き戻す)
fn ea_write_for_rmw(cpu: M68kCPU&, mmu: M68kMMU&, mode: i32, reg: i32, size: i32, addr: u32, val: u32) {
    if mode == 0 { // Dn
        dreg_write(cpu, reg, size, val);
        return;
    }
    if mode == 1 { // An
        if mmu.failed() { return; }
        if size == 2 {
            cpu.a[reg] = ((val as! i16)) as! u32;
        } else {
            cpu.a[reg] = val;
        }
        return;
    }
    mem_write(mmu, addr, size, val);
}

// EA 読み出し
fn ea_read(cpu: M68kCPU&, mmu: M68kMMU&, mode: i32, reg: i32, size: i32) -> u32 {
    if mode == 0 { // Dn
        if size == 1 { return cpu.d[reg] & 0xFF; }
        if size == 2 { return cpu.d[reg] & 0xFFFF; }
        return cpu.d[reg];
    }
    if mode == 1 { // An
        if size == 2 { return ((cpu.a[reg] as! i16)) as! u32; }
        return cpu.a[reg];
    }
    if mode == 7 && reg == 4 { // 即値 #<data>
        if size == 1 { return (fetch16(cpu, mmu) & 0xFF); }
        if size == 2 { return fetch16(cpu, mmu); }
        return fetch32(cpu, mmu);
    }
    let addr = ea_calc_addr(cpu, mmu, mode, reg, size);
    if size == 1 { return mmu.read8(addr); }
    if size == 2 { return mmu.read16(addr); }
    return mmu.read32(addr);
}

// EA 書き込み
fn ea_write(cpu: M68kCPU&, mmu: M68kMMU&, mode: i32, reg: i32, size: i32, val: u32) {
    if mode == 0 { // Dn
        dreg_write(cpu, reg, size, val);
        return;
    }
    if mode == 1 { // An
        if mmu.failed() { return; }
        if size == 2 {
            cpu.a[reg] = ((val as! i16)) as! u32;
        } else {
            cpu.a[reg] = val;
        }
        return;
    }
    let addr = ea_calc_addr(cpu, mmu, mode, reg, size);
    mem_write(mmu, addr, size, val);
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

// 実効アドレスの時間。メモリ上のロングのオペランド (ロングの即値も) は 4 足す。
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
    let base: i32 = if size != 4 { 4 } else if ea_is_reg_or_imm(mode, reg) { 8 } else { 6 };
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

// ADDA/SUBA: .W は 8、.L は 6 (レジスタか即値からなら 8)、これに EA を足す。
fn adda_cycles(is_long: bool, mode: i32, reg: i32) -> i32 {
    let size: i32 = if is_long { 4 } else { 2 };
    let base: i32 = if is_long && !ea_is_reg_or_imm(mode, reg) { 6 } else { 8 };
    return base + ea_extra_cycles(mode, reg, size);
}

// CMP <ea>,Dn: 4 (.L は 6) に EA を足す。レジスタ / 即値の上乗せはない。
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

// MOVEM (XEiJ): メモリへは -(An) が 8、それ以外は 4 (.L は 0) + EA。レジスタへは (An)+ が 12 (.L は 8)、
// それ以外は 8 (.L は 4) + EA。レジスタ 1 つごとに 4 (.L は 8) を足す。
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

// LEA/PEA のアドレス計算の時間: (An) 4、d16 8、インデックス 12、abs.W 8、abs.L 12、PC 8 / 12。
fn lea_cycles(mode: i32, reg: i32) -> i32 {
    if mode == 2 { return 4; }
    if mode == 6 || (mode == 7 && reg == 3) { return 12; }
    if mode == 7 && reg == 1 { return 12; }
    return 8;
}

// JMP のアドレス計算の時間: (An) 8、d16 10、インデックス 14、abs.W 10、abs.L 12、PC 10 / 14。JSR は 8 足す。
fn jmp_cycles(mode: i32, reg: i32) -> i32 {
    if mode == 2 { return 8; }
    if mode == 6 || (mode == 7 && reg == 3) { return 14; }
    if mode == 7 && reg == 1 { return 12; }
    return 10;
}

// MULU: 38 + ソースの 1 のビット 1 つにつき 2。MULS: 38 + 次の値の下位 16 ビットにある 1 のビット 1 つにつき 2:
// source ^ (source << 1)。つまり末尾に 0 を足したときの 01 / 10 の組の数 (XEiJ irpMulsWord)。
fn mul_cycles(mode: i32, reg: i32, src: u32, signed: bool) -> i32 {
    var t = src & 0xFFFF;
    if signed { t = (t ^ (t << 1)) & 0xFFFF; }
    var n: i32 = 0;
    while t != 0 {
        n += (t & 1) as i32;
        t = t >> 1;
    }
    return 38 + 2 * n + ea_extra_cycles(mode, reg, 2);
}

// BTST/BCHG/BCLR/BSET (XEiJ)。レジスタ: 動的 BTST 6、BCHG/BSET 6/8、BCLR 8/10 (ビット番号が 16 未満 /
// それ以上)。静的は 4 足す。メモリ: 動的 BTST 4、ほかは 8。静的は 4 足し、EA も足す。
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

// DIVU/DIVS のサイクルは 68000 のシフトと引き算の繰り返しから求める (XEiJ irpDivuCyclesModified /
// irpDivsCycles)。これに実効アドレスの時間を足す。ゼロ除算は前の数え方のまま。
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
    let ax = if x < 0 { (0) - (x as! u32) } else { x as! u32 };
    let ay = if y < 0 { (0) - (y as! u32) } else { y as! u32 };
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

// CMPI (XEiJ): Dn は 8 (.L は 14)、メモリは 8 (.L は 12) に EA を足す。
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
    // 不当命令と特権違反は、その命令自身のアドレスを積む。
    trigger_exception(cpu, mmu, 4, mmu.inst_pc);
    return 34;
}

// ABCD/SBCD/NBCD。Z は結果が 0 以外のときだけクリアする。keep_z のときは Z を変えない。V は変えない。
// 68000 の BCD のフラグ (XEiJ と同じ求め方): X/C は桁上がり、Z は結果が 0 でなければ落とす、
// N は結果の最上位ビット、V は 10 進補正を足したときのオーバーフロー。
fn bcd_flags(cpu: M68kCPU&, t: i32, z: i32, carry: bool) {
    if carry { cpu.sr |= SR_C | SR_X; } else { cpu.sr &= ~(SR_C | SR_X); }
    if z != 0 { cpu.sr &= ~(SR_Z as! u16); }
    if (z & 0x80) != 0 { cpu.sr |= SR_N; } else { cpu.sr &= ~(SR_N as! u16); }
    let a = z - t;
    if (((t ^ z) & (a ^ z)) & 0x80) != 0 { cpu.sr |= SR_V; } else { cpu.sr &= ~(SR_V as! u16); }
}

fn bcd_add(cpu: M68kCPU&, dst: u32, src: u32) -> u32 {
    let c: i32 = if cpu.flag_x() { 1 } else { 0 };
    let x = (dst & 0xFF) as i32;
    let y = (src & 0xFF) as i32;
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
    let b: i32 = if cpu.flag_x() { 1 } else { 0 };
    let x = (dst & 0xFF) as i32;
    let y = (src & 0xFF) as i32;
    let t = x - y - b;
    var z = t;
    if (x & 0x0F) - (y & 0x0F) - b < 0 { z -= 0x10 - 0x0A; }
    let borrow = z < 0;
    if borrow && t < 0 { z -= 0x100 - 0xA0; }
    z &= 0xFF;
    bcd_flags(cpu, t, z, borrow);
    return z as! u32;
}

// MOVEP。mm: 0=W メモリ→Dn, 1=L メモリ→Dn, 2=W Dn→メモリ, 3=L Dn→メモリ
fn exec_movep(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    let dreg: i32 = (op >> 9) & 0x07;
    let areg: i32 = op & 0x07;
    let disp: i32 = fetch16(cpu, mmu) as! i16;
    let adr = addr_add(cpu.a[areg], disp);
    let kind: i32 = (op >> 6) & 0x03;
    if kind == 0 {
        let hi: u32 = mmu.read8(adr);
        let lo: u32 = mmu.read8(adr + 2);
        cpu.d[dreg] = (cpu.d[dreg] & 0xFFFF0000) | (hi << 8) | lo;
        return 16;
    }
    if kind == 1 {
        let b0: u32 = mmu.read8(adr);
        let b1: u32 = mmu.read8(adr + 2);
        let b2: u32 = mmu.read8(adr + 4);
        let b3: u32 = mmu.read8(adr + 6);
        cpu.d[dreg] = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
        return 24;
    }
    let res = cpu.d[dreg];
    if kind == 2 {
        mmu.write8(adr, ((res >> 8) & 0xFF) as u8);
        mmu.write8(adr + 2, (res & 0xFF) as u8);
        return 16;
    }
    mmu.write8(adr, ((res >> 24) & 0xFF) as u8);
    mmu.write8(adr + 2, ((res >> 16) & 0xFF) as u8);
    mmu.write8(adr + 4, ((res >> 8) & 0xFF) as u8);
    mmu.write8(adr + 6, (res & 0xFF) as u8);
    return 24;
}

// BTST / BCHG / BCLR / BSET。bit はビット番号 (レジスタなら下位 5 ビット、メモリなら下位 3 ビットを使う)。
// is_static は、ビット番号が即値で与えられた形かどうか (サイクル数が違う)。
fn exec_bit_op(cpu: M68kCPU&, mmu: M68kMMU&, op: u16, bit: u32, is_static: bool) -> i32 {
    let mode: i32 = (op >> 3) & 0x07;
    let reg: i32 = op & 0x07;
    let op_type: i32 = (op >> 6) & 0x03; // 0=BTST, 1=BCHG, 2=BCLR, 3=BSET

    if mode == 0 { // データレジスタ: 32 ビット
        let b = bit & 31;
        let mask = (1 as! u32) << b;
        if (cpu.d[reg] & mask) == 0 { cpu.sr |= SR_Z; } else { cpu.sr &= ~(SR_Z as! u16); }
        if op_type == 1 { cpu.d[reg] ^= mask; }
        else if op_type == 2 { cpu.d[reg] &= ~mask; }
        else if op_type == 3 { cpu.d[reg] |= mask; }
        return bit_cycles(op_type, is_static, mode, reg, b);
    }

    // メモリ: 8 ビット
    let mask = ((1 as! u32) << (bit & 7)) as! u8;
    if op_type == 0 {
        // BTST は読むだけなので、即値や PC 相対も指定できる
        let cur = ea_read(cpu, mmu, mode, reg, 1) as! u8;
        if (cur & mask) == 0 { cpu.sr |= SR_Z; } else { cpu.sr &= ~(SR_Z as! u16); }
        return bit_cycles(op_type, is_static, mode, reg, 0);
    }
    let addr = ea_calc_addr(cpu, mmu, mode, reg, 1);
    let cur = mmu.read8(addr);
    if (cur & mask) == 0 { cpu.sr |= SR_Z; } else { cpu.sr &= ~(SR_Z as! u16); }
    if op_type == 1 { mmu.write8(addr, cur ^ mask); }
    else if op_type == 2 { mmu.write8(addr, cur & ~mask); }
    else { mmu.write8(addr, cur | mask); }
    return bit_cycles(op_type, is_static, mode, reg, 0);
}

// 即値演算: ORI / ANDI / SUBI / ADDI / EORI / CMPI と、CCR / SR への ORI / ANDI / EORI
fn exec_immediate(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    let mode: i32 = (op >> 3) & 0x07;
    let reg: i32 = op & 0x07;
    let imm_op: i32 = (op >> 9) & 0x07;
    let sz_code: i32 = (op >> 6) & 0x03;
    // imm_op 4 は BTST、7 は未定義。未定義は即値ワードを読まず Illegal にする。
    if sz_code <= 2 && imm_op != 4 && imm_op != 7 {
        let size: i32 = if sz_code == 0 { 1 } else if sz_code == 1 { 2 } else { 4 };
        // ORI/ANDI/EORI to SR はユーザーモードで Vector 8。即値は読まない（C68K と同じ）。
        if size == 2 && mode == 7 && reg == 4 && (imm_op == 0 || imm_op == 1 || imm_op == 5) {
            if !cpu.is_supervisor() { return privilege_violation(cpu, mmu); }
        }
        let imm_val = if size == 1 { (fetch16(cpu, mmu) & 0xFF) as u32 }
                      else if size == 2 { fetch16(cpu, mmu) as! u32 }
                      else { fetch32(cpu, mmu) };

        // ORI / ANDI / EORI to CCR / SR
        if mode == 7 && reg == 4 {
            if imm_op == 0 { // ORI
                if size == 1 { cpu.set_ccr(((cpu.sr & 0x1F) | (imm_val as! u16)) as! u8); }
                else if size == 2 && cpu.is_supervisor() { cpu.set_sr(cpu.sr | (imm_val as! u16)); }
            } else if imm_op == 1 { // ANDI
                if size == 1 { cpu.set_ccr(((cpu.sr & 0x1F) & (imm_val as! u16)) as! u8); }
                else if size == 2 && cpu.is_supervisor() { cpu.set_sr(cpu.sr & (imm_val as! u16)); }
            } else if imm_op == 5 { // EORI
                if size == 1 { cpu.set_ccr(((cpu.sr & 0x1F) ^ (imm_val as! u16)) as! u8); }
                else if size == 2 && cpu.is_supervisor() { cpu.set_sr(cpu.sr ^ (imm_val as! u16)); }
            }
            return 20;
        }

        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, size);
        let dst = ea_res.val;

        if imm_op == 0 { // ORI
            let res = dst | imm_val;
            ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
            cpu.set_nz(size, res);
            return imm_alu_cycles(size, mode, reg);
        }
        if imm_op == 1 { // ANDI
            let res = dst & imm_val;
            ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
            cpu.set_nz(size, res);
            return imm_alu_cycles(size, mode, reg);
        }
        if imm_op == 2 { // SUBI
            let res = dst - imm_val;
            ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
            cpu.flags_sub(size, imm_val, dst, res, true);
            return imm_alu_cycles(size, mode, reg);
        }
        if imm_op == 3 { // ADDI
            let res = dst + imm_val;
            ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
            cpu.flags_add(size, imm_val, dst, res);
            return imm_alu_cycles(size, mode, reg);
        }
        if imm_op == 5 { // EORI
            let res = dst ^ imm_val;
            ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
            cpu.set_nz(size, res);
            return imm_alu_cycles(size, mode, reg);
        }
        if imm_op == 6 { // CMPI
            let res = dst - imm_val;
            cpu.flags_sub(size, imm_val, dst, res, false);
            return cmpi_cycles(size, mode, reg);
        }
    }
    return raise_illegal(cpu, mmu);
}

// 上位 4 ビットが 0 の命令: ビット操作、MOVEP、即値演算
fn exec_op0(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    let mode: i32 = (op >> 3) & 0x07;
    // ビット番号が即値の形 (0000 1000 ss eee eee #imm)
    if (op & 0xFF00) == 0x0800 {
        let bit: u32 = fetch16(cpu, mmu) & 0xFF;
        return exec_bit_op(cpu, mmu, op, bit, true);
    }
    if (op & 0x0100) != 0 {
        // アドレスレジスタ直接の形は MOVEP (0000 rrr1 mm001 aaa)。それ以外はビット番号が Dn の形
        if mode == 1 { return exec_movep(cpu, mmu, op); }
        return exec_bit_op(cpu, mmu, op, cpu.d[(op >> 9) & 0x07], false);
    }
    return exec_immediate(cpu, mmu, op);
}

fn trigger_exception(cpu: M68kCPU&, mmu: M68kMMU&, vector: i32, return_pc: u32) {
    if mmu.failed() { return; }
    cpu.took_exception = true;
    mmu.user_mode = false;
    if !cpu.is_supervisor() {
        cpu.usp = cpu.a[REG_A7];
        cpu.a[REG_A7] = cpu.ssp;
    }
    push32(cpu, mmu, return_pc);
    push16(cpu, mmu, cpu.sr);
    cpu.sr |= SR_S;
    cpu.sr &= ~(SR_T as! u16);
    let vec_addr = ((vector & 0xFF) * 4) as! u32;
    cpu.pc = mmu.read32(vec_addr);
}

// -------------------------------------------------------------
// Op 4: 雑多命令 (LEA, PEA, MOVEM, CLR, NEG, NOT, TST, JMP, JSR, TRAP, LINK, UNLK, EXT, SWAP)
// -------------------------------------------------------------

// NOP, RESET, STOP, RTS, RTE, RTR, TRAPV, JMP, JSR。戻り値は消費サイクルと、この関数が命令を処理したかどうか。
// 特権違反 (Vector 8)。積む PC はこの命令の先頭。
fn privilege_violation(cpu: M68kCPU&, mmu: M68kMMU&) -> i32 {
    trigger_exception(cpu, mmu, 8, mmu.inst_pc);
    return 34;
}

fn op4_flow(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32, bool {
    let mode: i32 = (op >> 3) & 0x07;
    let reg: i32 = op & 0x07;

    // 0x4E70〜0x4E77 はオペランドのない制御命令
    match op {
        0x4E71 => { return 4, true; },                                    // NOP
        0x4E70 => {                                                       // RESET
            // px68k の Reset_CallBack は C68k_Reset_Dummy で、周辺は変えない。
            if !cpu.is_supervisor() { return privilege_violation(cpu, mmu), true; }
            return 132, true;
        },
        0x4E72 => {                                                       // STOP #imm
            if !cpu.is_supervisor() { return privilege_violation(cpu, mmu), true; }
            let imm = fetch16(cpu, mmu);
            cpu.set_sr(imm);
            cpu.halted = true;
            return 4, true;
        },
        0x4E73 => {                                                       // RTE
            if !cpu.is_supervisor() { return privilege_violation(cpu, mmu), true; }
            let new_sr = pop16(cpu, mmu);
            let new_pc = pop32(cpu, mmu);
            cpu.set_sr(new_sr);
            cpu.pc = new_pc;
            return 20, true;
        },
        0x4E75 => { cpu.pc = pop32(cpu, mmu); return 16, true; },         // RTS
        0x4E76 => {                                                       // TRAPV
            // V が立っていれば Vector 7。積む PC は次の命令。
            if cpu.flag_v() {
                trigger_exception(cpu, mmu, 7, cpu.pc);
                return 34, true;
            }
            return 4, true;
        },
        0x4E77 => {                                                       // RTR
            let ccr = pop16(cpu, mmu);
            cpu.set_ccr(ccr as! u8);
            cpu.pc = pop32(cpu, mmu);
            return 20, true;
        },
        _ => {},
    }

    // JMP (0100 1110 11 eee eee)
    if (op & 0xFFC0) == 0x4EC0 {
        cpu.pc = ea_calc_addr(cpu, mmu, mode, reg, 4);
        return jmp_cycles(mode, reg), true;
    }
    // JSR (0100 1110 10 eee eee)
    if (op & 0xFFC0) == 0x4E80 {
        let target = ea_calc_addr(cpu, mmu, mode, reg, 4);
        push32(cpu, mmu, cpu.pc);
        cpu.pc = target;
        return 8 + jmp_cycles(mode, reg), true;
    }
    return 0, false;
}

// LEA, SWAP, PEA, LINK, UNLK, MOVE USP, TRAP。戻り値は消費サイクルと、この関数が命令を処理したかどうか。
fn op4_stack(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32, bool {
    let mode: i32 = (op >> 3) & 0x07;
    let reg: i32 = op & 0x07;

    // LEA (0100 rrr1 11 eee eee)
    if (op & 0xF1C0) == 0x41C0 {
        let areg: i32 = (op >> 9) & 0x07;
        cpu.a[areg] = ea_calc_addr(cpu, mmu, mode, reg, 4);
        return lea_cycles(mode, reg), true;
    }
    // SWAP (0100 1000 0100 0rrr: mode == 0)
    if (op & 0xFFF8) == 0x4840 {
        let dreg: i32 = op & 0x07;
        let v = cpu.d[dreg];
        cpu.d[dreg] = (v >> 16) | (v << 16);
        cpu.set_nz(4, cpu.d[dreg]);
        return 4, true;
    }

    // PEA (0100 1000 01 eee eee: mode >= 2)
    if (op & 0xFFC0) == 0x4840 && mode >= 2 {
        let addr = ea_calc_addr(cpu, mmu, mode, reg, 4);
        push32(cpu, mmu, addr);
        return 8 + lea_cycles(mode, reg), true;
    }

    // LINK (0100 1110 0101 0rrr)
    if (op & 0xFFF8) == 0x4E50 {
        let areg: i32 = op & 0x07;
        let disp: i32 = fetch16(cpu, mmu) as! i16;
        push32(cpu, mmu, cpu.a[areg]);
        cpu.a[areg] = cpu.a[REG_A7];
        cpu.a[REG_A7] = addr_add(cpu.a[REG_A7], disp);
        return 16, true;
    }
    // UNLK (0100 1110 0101 1rrr)
    if (op & 0xFFF8) == 0x4E58 {
        let areg: i32 = op & 0x07;
        cpu.a[REG_A7] = cpu.a[areg];
        let saved = pop32(cpu, mmu);
        if !mmu.failed() { cpu.a[areg] = saved; }
        return 12, true;
    }

    // MOVE USP (0100 1110 0110 drrr)
    if (op & 0xFFF0) == 0x4E60 {
        if !cpu.is_supervisor() { return privilege_violation(cpu, mmu), true; }
        let areg: i32 = op & 0x07;
        let to_usp = (op & 0x08) == 0;
        if to_usp { cpu.usp = cpu.a[areg]; } else { cpu.a[areg] = cpu.usp; }
        return 4, true;
    }

    // TRAP (0100 1110 0100 vvvv)
    if (op & 0xFFF0) == 0x4E40 {
        let trap_num: i32 = op & 0x0F;
        trigger_exception(cpu, mmu, 32 + trap_num, cpu.pc);
        return 34, true;
    }
    return 0, false;
}

// MOVEM, EXT。戻り値は消費サイクルと、この関数が命令を処理したかどうか。
fn op4_movem_ext(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32, bool {
    let mode: i32 = (op >> 3) & 0x07;
    let reg: i32 = op & 0x07;

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
            if mode == 4 { // -(An): プリデクリメント (bit 0 = A7 … bit 7 = A0、bit 8 = D7 … bit 15 = D0)
                var addr = cpu.a[reg];
                for i in 16 {
                    if (mask & ((1 as! u16) << i)) != 0 {
                        let val = if i < 8 { cpu.a[7 - i] } else { cpu.d[15 - i] };
                        if is_long {
                            addr -= 4;
                            mmu.write32(addr, val);
                        } else {
                            addr -= 2;
                            mmu.write16(addr, (val & 0xFFFF) as u16);
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
                            mmu.write32(addr, val);
                            addr += 4;
                        } else {
                            mmu.write16(addr, (val & 0xFFFF) as u16);
                            addr += 2;
                        }
                    }
                }
            }
            return movem_cycles(is_long, nregs, mode, true, reg), true;
        } else {
            // MOVEM <ea> -> Regs (0100 1100 1s eee eee)
            var addr = if mode == 3 { cpu.a[reg] } else { ea_calc_addr(cpu, mmu, mode, reg, if is_long { 4 } else { 2 }) };
            for i in 16 {
                if (mask & ((1 as! u16) << i)) != 0 {
                    if is_long {
                        let val = mmu.read32(addr);
                        addr += 4;
                        if i < 8 { cpu.d[i] = val; } else if !mmu.failed() { cpu.a[i - 8] = val; }
                    } else {
                        let val = (mmu.read16(addr) as! i16) as! u32;
                        addr += 2;
                        if i < 8 { cpu.d[i] = val; } else if !mmu.failed() { cpu.a[i - 8] = val; }
                    }
                }
            }
            if mode == 3 && !mmu.failed() { // (An)+: ポストインクリメント
                cpu.a[reg] = addr;
            }
            return movem_cycles(is_long, nregs, mode, false, reg), true;
        }
    }

    // EXT.W (0100 1000 1000 0rrr) & EXT.L (0100 1000 1100 0rrr)
    if (op & 0xFFB8) == 0x4880 {
        let is_long = (op & 0x0040) != 0;
        let dreg: i32 = op & 0x07;
        if is_long {
            let val = (cpu.d[dreg] as! i16) as! u32;
            cpu.d[dreg] = val;
            cpu.set_nz(4, val);
        } else {
            let val = (cpu.d[dreg] as! i8) as! u16;
            cpu.d[dreg] = (cpu.d[dreg] & 0xFFFF0000) | (val);
            cpu.set_nz(2, val);
        }
        return 4, true;
    }
    return 0, false;
}

// MOVE to SR, MOVE to CCR, MOVE from SR。戻り値は消費サイクルと、この関数が命令を処理したかどうか。
fn op4_status(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32, bool {
    let mode: i32 = (op >> 3) & 0x07;
    let reg: i32 = op & 0x07;

    // MOVE to SR (0100 0110 11 eee eee)
    if (op & 0xFFC0) == 0x46C0 {
        if !cpu.is_supervisor() { return privilege_violation(cpu, mmu), true; }
        let val = ea_read(cpu, mmu, mode, reg, 2) as! u16;
        cpu.set_sr(val);
        return 12 + ea_bw_extra(mode, reg), true;
    }
    // MOVE to CCR (0100 0100 11 eee eee)
    if (op & 0xFFC0) == 0x44C0 {
        let ccr = ea_read(cpu, mmu, mode, reg, 2) as! u16;
        cpu.set_ccr(ccr as! u8);
        return 12 + ea_bw_extra(mode, reg), true;
    }
    // MOVE from SR (0100 0000 11 eee eee)
    if (op & 0xFFC0) == 0x40C0 {
        ea_write(cpu, mmu, mode, reg, 2, cpu.sr);
        if mode == 0 { return 6, true; }
        return 8 + ea_bw_extra(mode, reg), true;
    }
    return 0, false;
}

// NEGX, CLR, NEG, NOT, TST, NBCD, CHK, TAS。戻り値は消費サイクルと、この関数が命令を処理したかどうか。
fn op4_unary(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32, bool {
    let mode: i32 = (op >> 3) & 0x07;
    let reg: i32 = op & 0x07;

    // NEGX (0100 0000 ss eee eee: ss <= 2)
    if (op & 0xFF00) == 0x4000 && ((op >> 6) & 3) <= 2 {
        let sz_code: i32 = (op >> 6) & 0x03;
        let size: i32 = if sz_code == 0 { 1 } else if sz_code == 1 { 2 } else { 4 };
        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, size);
        let cur = ea_res.val;
        let x_val = if cpu.flag_x() { 1 as! u32 } else { 0 as! u32 };
        let res = (0) - cur - x_val;
        ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
        cpu.flags_subx(size, cur, 0, res);
        return clr_cycles(size, mode, reg), true;
    }

    // CLR (0100 0010 ss eee eee: ss <= 2)
    if (op & 0xFF00) == 0x4200 && ((op >> 6) & 3) <= 2 {
        let sz_code: i32 = (op >> 6) & 0x03;
        let size: i32 = if sz_code == 0 { 1 } else if sz_code == 1 { 2 } else { 4 };
        ea_write(cpu, mmu, mode, reg, size, 0);
        cpu.sr |= SR_Z;
        cpu.sr &= ~(SR_N | SR_V | SR_C);
        return clr_cycles(size, mode, reg), true;
    }

    // NEG (0100 0100 ss eee eee: ss <= 2)
    if (op & 0xFF00) == 0x4400 && ((op >> 6) & 3) <= 2 {
        let sz_code: i32 = (op >> 6) & 0x03;
        let size: i32 = if sz_code == 0 { 1 } else if sz_code == 1 { 2 } else { 4 };
        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, size);
        let cur = ea_res.val;
        let res = (0) - cur;
        ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
        cpu.flags_sub(size, cur, 0, res, true);
        return clr_cycles(size, mode, reg), true;
    }

    // NOT (0100 0110 ss eee eee: ss <= 2)
    if (op & 0xFF00) == 0x4600 && ((op >> 6) & 3) <= 2 {
        let sz_code: i32 = (op >> 6) & 0x03;
        let size: i32 = if sz_code == 0 { 1 } else if sz_code == 1 { 2 } else { 4 };
        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, size);
        let cur = ea_res.val;
        let res = ~cur;
        ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
        cpu.set_nz(size, res);
        return clr_cycles(size, mode, reg), true;
    }

    // TST (0100 1010 ss eee eee: ss <= 2)
    if (op & 0xFF00) == 0x4A00 && ((op >> 6) & 3) <= 2 {
        let sz_code: i32 = (op >> 6) & 0x03;
        let size: i32 = if sz_code == 0 { 1 } else if sz_code == 1 { 2 } else { 4 };
        let val = ea_read(cpu, mmu, mode, reg, size);
        cpu.set_nz(size, val);
        return 4 + ea_extra_cycles(mode, reg, size), true;
    }

    // NBCD (0100 1000 00 eee eee): 0 - <ea> - X。フラグは SBCD と同じ。
    if (op & 0xFFC0) == 0x4800 {
        if !ea_is_alterable(mode, reg) { return raise_illegal(cpu, mmu), true; }
        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, 1);
        let res = bcd_sub(cpu, 0, ea_res.val);
        ea_write_for_rmw(cpu, mmu, mode, reg, 1, ea_res.addr, res);
        if mode == 0 { return 6, true; }
        return 8 + ea_bw_extra(mode, reg), true;
    }

    // CHK.W (0100 rrr1 10 eee eee): 符号付きの範囲検査。N/Z は Dn から、V/C は 上限 - Dn から (XEiJ)。
    if (op & 0xF1C0) == 0x4180 {
        if !ea_is_data(mode, reg) { return raise_illegal(cpu, mmu), true; }
        let dn: i32 = (op >> 9) & 0x07;
        let x: i32 = ea_read(cpu, mmu, mode, reg, 2) as! i16;
        let y: i32 = cpu.d[dn] as! i16;
        let z: i32 = (x - y) as! i16;
        var ccr = cpu.sr & SR_X;
        if y < 0 { ccr |= SR_N; }
        if y == 0 { ccr |= SR_Z; }
        if ((x ^ y) & (x ^ z)) < 0 { ccr |= SR_V; }
        if ((x & (y ^ z)) ^ (y | z)) < 0 { ccr |= SR_C; }
        cpu.sr = (cpu.sr & 0xFF00) | ccr;
        if y < 0 || x < y {
            trigger_exception(cpu, mmu, 6, cpu.pc);
            return 38 + ea_bw_extra(mode, reg), true;
        }
        return 10 + ea_bw_extra(mode, reg), true;
    }

    // TAS (0100 1010 11 eee eee)。4AFC など無効 EA は Illegal。
    if (op & 0xFFC0) == 0x4AC0 {
        if !ea_is_alterable(mode, reg) { return raise_illegal(cpu, mmu), true; }
        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, 1);
        let cur = ea_res.val & 0xFF;
        if (cur & 0x80) != 0 { cpu.sr |= SR_N; } else { cpu.sr &= ~(SR_N as! u16); }
        if cur == 0 { cpu.sr |= SR_Z; } else { cpu.sr &= ~(SR_Z as! u16); }
        cpu.sr &= ~(SR_V | SR_C);
        ea_write_for_rmw(cpu, mmu, mode, reg, 1, ea_res.addr, cur | 0x80);
        if mode == 0 { return 4, true; }
        return 10 + ea_bw_extra(mode, reg), true;
    }
    return 0, false;
}

fn exec_op4(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    // NOP, RESET, STOP, RTS, RTE, RTR, TRAPV, JMP, JSR
    let flow_cycles, flow_done = op4_flow(cpu, mmu, op);
    if flow_done { return flow_cycles; }
    // LEA, SWAP, PEA, LINK, UNLK, MOVE USP, TRAP
    let stack_cycles, stack_done = op4_stack(cpu, mmu, op);
    if stack_done { return stack_cycles; }
    // MOVEM, EXT
    let movem_cycles, movem_done = op4_movem_ext(cpu, mmu, op);
    if movem_done { return movem_cycles; }
    // MOVE to SR, MOVE to CCR, MOVE from SR
    let status_cycles, status_done = op4_status(cpu, mmu, op);
    if status_done { return status_cycles; }
    // NEGX, CLR, NEG, NOT, TST, NBCD, CHK, TAS
    let unary_cycles, unary_done = op4_unary(cpu, mmu, op);
    if unary_done { return unary_cycles; }
    return raise_illegal(cpu, mmu);
}

// -------------------------------------------------------------
// Op 8 & Op C: OR, AND, MULU, MULS, DIVU, DIVS, EXG
// -------------------------------------------------------------
fn exec_op8_or_div(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    let dreg: i32 = (op >> 9) & 0x07;
    let opmode: i32 = (op >> 6) & 0x07;
    let mode: i32 = (op >> 3) & 0x07;
    let reg: i32 = op & 0x07;

    // SBCD (1000 rrr1 0000 mrrr)。この形を OR.B に落とさない。
    if (op & 0x01F0) == 0x0100 {
        let mem = (op & 0x0008) != 0;
        if mem {
            let src_addr = predec(cpu, reg, 1);
            let dst_addr = predec(cpu, dreg, 1);
            let src: u32 = mmu.read8(src_addr);
            let dst: u32 = mmu.read8(dst_addr);
            let res = bcd_sub(cpu, dst, src);
            mmu.write8(dst_addr, res as! u8);
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
        // ゼロ除算とオーバーフローでは Dq を変えない。N/Z/V は 68000 と同じに立てる (XEiJ)。
        if src == 0 {
            var ccr = (cpu.sr & SR_X) | SR_V;
            if (x & 0x80000000) != 0 { ccr |= SR_N; }
            if (x >> 16) == 0 { ccr |= SR_Z; }
            cpu.sr = (cpu.sr & 0xFF00) | ccr;
            trigger_exception(cpu, mmu, 5, cpu.pc);
            return cycles;
        }
        let q = x / src;
        let r = x % src;
        if q > 0xFFFF {
            var ccr = (cpu.sr & SR_X) | SR_V;
            if (x & 0x80000000) != 0 { ccr |= SR_N; }
            cpu.sr = (cpu.sr & 0xFF00) | ccr;
        } else {
            cpu.d[dreg] = (r << 16) | (q & 0xFFFF);
            cpu.set_nz(2, q as! u16);
        }
        return cycles;
    }
    if opmode == 7 { // DIVS.W
        let src: i32 = ea_read(cpu, mmu, mode, reg, 2) as! i16;
        let dst = cpu.d[dreg] as! i32;
        let cycles = divs_cycles(mode, reg, dst, src);
        // ゼロ除算とオーバーフローでは Dq を変えない。N/Z/V は 68000 と同じに立てる (XEiJ)。
        if src == 0 {
            let x = cpu.d[dreg];
            var v = (cpu.sr & SR_V) != 0;
            if x == 0x00008000 { v = !v; }
            else if (dst >= 0 && x != 0x7FFFFFFF) || x == 0x80000000 { v = true; }
            var ccr = (cpu.sr & SR_X) | SR_Z;
            if v { ccr |= SR_V; }
            cpu.sr = (cpu.sr & 0xFF00) | ccr;
            trigger_exception(cpu, mmu, 5, cpu.pc);
            return cycles;
        }
        // 64 ビットで計算し、$80000000 / -1 をトラップではなくオーバーフローにする。
        let q64 = (dst as! i64) / (src);
        if q64 > 32767 || q64 < -32768 {
            let z = (q64 as! i32) as! u32;
            var ccr = (cpu.sr & SR_X) | SR_V;
            if cpu.d[dreg] == 0x80000000 || (z & 0xFFFF0080) == 0x00000080 || (z & 0xFFFF0080) == 0xFFFF0080 {
                ccr |= SR_N;
            }
            if z == 0x00008000 || (((z & 0xFFFF00FF) == 0 || (z & 0xFFFF00FF) == 0xFFFF0000) && (z & 0xFF00) != 0) {
                ccr |= SR_Z;
            }
            cpu.sr = (cpu.sr & 0xFF00) | ccr;
        } else {
            let q = q64 as! i32;
            let r = dst - q * src;
            cpu.d[dreg] = (((r as! u32) & 0xFFFF) << 16) | ((q as! u32) & 0xFFFF);
            cpu.set_nz(2, (q as! i16) as! u16);
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
        cpu.set_nz(size, res);
    } else {
        let src = ea_read(cpu, mmu, mode, reg, size);
        let dst = cpu.d[dreg];
        let res = dst | src;
        if size == 1 { cpu.d[dreg] = (cpu.d[dreg] & 0xFFFFFF00) | (res & 0xFF); cpu.set_nz(1, res as! u8); }
        else if size == 2 { cpu.d[dreg] = (cpu.d[dreg] & 0xFFFF0000) | (res & 0xFFFF); cpu.set_nz(2, res as! u16); }
        else { cpu.d[dreg] = res; cpu.set_nz(4, res); }
    }
    return alu_bin_cycles(size, mode, reg, is_ea_dst);
}

fn exec_opC_and_mul_exg(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    let dreg: i32 = (op >> 9) & 0x07;
    let opmode: i32 = (op >> 6) & 0x07;
    let mode: i32 = (op >> 3) & 0x07;
    let reg: i32 = op & 0x07;

    // ABCD (1100 rrr1 0000 mrrr)。EXG のマスクに掛かるが、そちらへ落とさない。
    if (op & 0x01F0) == 0x0100 {
        let mem = (op & 0x0008) != 0;
        if mem {
            let src_addr = predec(cpu, reg, 1);
            let dst_addr = predec(cpu, dreg, 1);
            let src: u32 = mmu.read8(src_addr);
            let dst: u32 = mmu.read8(dst_addr);
            let res = bcd_add(cpu, dst, src);
            mmu.write8(dst_addr, res as! u8);
            return 18;
        }
        let res = bcd_add(cpu, cpu.d[dreg], cpu.d[reg]);
        cpu.d[dreg] = (cpu.d[dreg] & 0xFFFFFF00) | res;
        return 6;
    }

    // EXG (1100 rrr 1 oooo rrr)
    if (op & 0xF130) == 0xC100 {
        let op_mode: i32 = (op >> 3) & 0x1F;
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
        cpu.set_nz(4, res);
        return mul_cycles(mode, reg, src, false);
    }
    if opmode == 7 { // MULS.W
        let src: i32 = ea_read(cpu, mmu, mode, reg, 2) as! i16;
        let dst: i32 = cpu.d[dreg] as! i16;
        let res = (dst * src) as! u32;
        cpu.d[dreg] = res;
        cpu.set_nz(4, res);
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
        cpu.set_nz(size, res);
    } else {
        let src = ea_read(cpu, mmu, mode, reg, size);
        let dst = cpu.d[dreg];
        let res = dst & src;
        if size == 1 { cpu.d[dreg] = (cpu.d[dreg] & 0xFFFFFF00) | (res & 0xFF); cpu.set_nz(1, res as! u8); }
        else if size == 2 { cpu.d[dreg] = (cpu.d[dreg] & 0xFFFF0000) | (res & 0xFFFF); cpu.set_nz(2, res as! u16); }
        else { cpu.d[dreg] = res; cpu.set_nz(4, res); }
    }
    return alu_bin_cycles(size, mode, reg, is_ea_dst);
}

// -------------------------------------------------------------
// Op 9 & Op D: SUB, SUBA, SUBX, ADD, ADDA, ADDX
// -------------------------------------------------------------
fn exec_add_sub(cpu: M68kCPU&, mmu: M68kMMU&, op: u16, is_add: bool) -> i32 {
    let reg_field: i32 = (op >> 9) & 0x07;
    let opmode: i32 = (op >> 6) & 0x07;
    let mode: i32 = (op >> 3) & 0x07;
    let reg: i32 = op & 0x07;

    // ADDA / SUBA: ワードのソースは符号拡張し、An 全体に作用する。フラグは変えない。
    if opmode == 3 || opmode == 7 {
        let is_long = (opmode == 7);
        let src = ea_read(cpu, mmu, mode, reg, if is_long { 4 } else { 2 });
        let ext_src = if is_long { src } else { (src as! i16) as! u32 };
        if !mmu.failed() {
            cpu.a[reg_field] = if is_add { cpu.a[reg_field] + ext_src } else { cpu.a[reg_field] - ext_src };
        }
        return adda_cycles(is_long, mode, reg);
    }

    // ADDX / SUBX (1x01 Rx 1 ss 00 R/M Ry)
    if (op & 0x0130) == 0x0100 && ((op >> 6) & 3) <= 2 {
        let size_code: i32 = (op >> 6) & 3;
        let size: i32 = if size_code == 0 { 1 } else if size_code == 1 { 2 } else { 4 };
        let is_mem = (op & 0x0008) != 0;
        let rx = reg_field;
        let ry = reg;
        let x_val: u32 = if cpu.flag_x() { 1 } else { 0 };

        if is_mem { // -(Ay),-(Ax)
            let src_addr = predec(cpu, ry, size);
            let dst_addr = predec(cpu, rx, size);
            let src = mem_read(mmu, src_addr, size);
            let dst = mem_read(mmu, dst_addr, size);
            let res = if is_add { dst + src + x_val } else { dst - src - x_val };
            mem_write(mmu, dst_addr, size, res);
            flags_addsubx(cpu, is_add, size, src, dst, res);
            return if size == 4 { 30 } else { 18 };
        }
        let src = cpu.d[ry];
        let dst = cpu.d[rx];
        let res = if is_add { dst + src + x_val } else { dst - src - x_val };
        dreg_write(cpu, rx, size, res);
        flags_addsubx(cpu, is_add, size, src, dst, res);
        return if size == 4 { 8 } else { 4 };
    }

    let size: i32 = if (opmode & 3) == 0 { 1 } else if (opmode & 3) == 1 { 2 } else { 4 };
    let is_ea_dst = (opmode & 4) != 0;

    if is_ea_dst { // Dn,<ea>
        let src = cpu.d[reg_field];
        let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, size);
        let dst = ea_res.val;
        let res = if is_add { dst + src } else { dst - src };
        ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
        flags_addsub(cpu, is_add, size, src, dst, res);
    } else { // <ea>,Dn
        let src = ea_read(cpu, mmu, mode, reg, size);
        let dst = cpu.d[reg_field];
        let res = if is_add { dst + src } else { dst - src };
        dreg_write(cpu, reg_field, size, res);
        flags_addsub(cpu, is_add, size, src, dst, res);
    }
    return alu_bin_cycles(size, mode, reg, is_ea_dst);
}

// -------------------------------------------------------------
// Op B: CMP, CMPA, EOR, CMPM
// -------------------------------------------------------------
fn exec_opB_cmp_eor(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    let reg_field: i32 = (op >> 9) & 0x07;
    let opmode: i32 = (op >> 6) & 0x07;
    let mode: i32 = (op >> 3) & 0x07;
    let reg: i32 = op & 0x07;

    // CMPA
    if opmode == 3 || opmode == 7 {
        let is_long = (opmode == 7);
        let src = ea_read(cpu, mmu, mode, reg, if is_long { 4 } else { 2 });
        let ext_src = if is_long { src } else { ((src as! i16)) as! u32 };
        let dst = cpu.a[reg_field];
        let res = dst - ext_src;
        cpu.flags_sub(4, ext_src, dst, res, false);
        return 6 + ea_extra_cycles(mode, reg, if is_long { 4 } else { 2 });
    }

    // CMPM (Ay)+, (Ax)+: 1011 rrr 1 ss 001 rrr
    if (op & 0x0138) == 0x0108 {
        let size_code: i32 = (op >> 6) & 0x03;
        let size: i32 = if size_code == 0 { 1 } else if size_code == 1 { 2 } else { 4 };
        let ay: i32 = op & 0x07;
        let ax: i32 = (op >> 9) & 0x07;

        let src_addr = cpu.a[ay];
        let src = mem_read(mmu, src_addr, size);
        if size == 1 && ay == 7 { cpu.a[ay] += 2; }
        else { cpu.a[ay] += size as! u32; }

        let dst_addr = cpu.a[ax];
        let dst = mem_read(mmu, dst_addr, size);
        if size == 1 && ax == 7 { cpu.a[ax] += 2; }
        else { cpu.a[ax] += size as! u32; }

        let res = dst - src;
        cpu.flags_sub(size, src, dst, res, false);
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
        cpu.set_nz(size, res);
        return eor_cycles(size, mode, reg);
    } else {
        // CMP <ea>, Dn
        let src = ea_read(cpu, mmu, mode, reg, size);
        let dst = cpu.d[reg_field];
        let res = dst - src;
        cpu.flags_sub(size, src, dst, res, false);
        return cmp_cycles(size, mode, reg);
    }
}

// -------------------------------------------------------------
// Op E: シフト & ローテート (ASL, ASR, LSL, LSR, ROL, ROR, ROXL, ROXR)
// -------------------------------------------------------------
// シフトとローテートの種類 (命令語の 2 ビット)
let SHIFT_AS = 0;  // 算術シフト
let SHIFT_LS = 1;  // 論理シフト
let SHIFT_ROX = 2; // X を通すローテート
let SHIFT_RO = 3;  // ローテート

// 最上位ビットが msb の値 v を 1 ビットだけ動かす。結果と、押し出されたビットを返す。
// 空いた側に入るのは、ROX なら x_in、RO なら押し出されたビット、右の算術シフトなら元の最上位ビット。
fn shift_one(v: u32, msb: u32, kind: i32, left: bool, x_in: bool) -> u32, bool {
    let wraps = (kind == SHIFT_ROX && x_in);
    if left {
        let out = (v & msb) != 0;
        let low: u32 = if wraps || (kind == SHIFT_RO && out) { 1 } else { 0 };
        return ((v << 1) & (msb | (msb - 1))) | low, out;
    }
    let out = (v & 1) != 0;
    let top: u32 = if kind == SHIFT_AS { v & msb } else if wraps || (kind == SHIFT_RO && out) { msb } else { 0 };
    return (v >> 1) | top, out;
}

// シフト結果のフラグ。C は最後に押し出されたビット。X は RO 以外で C と同じになる。
// V は ASL で途中に最上位ビットが変わったときだけ立つ (C68K の符号ビットマスクと同じ)。
fn shift_flags(cpu: M68kCPU&, size: i32, result: u32, kind: i32, carry: bool, sign_changed: bool) {
    let cx: u16 = if kind == SHIFT_RO { SR_C } else { SR_C | SR_X };
    if carry { cpu.sr |= cx; } else { cpu.sr &= ~cx; }
    cpu.set_nz_only(size, result);
    if sign_changed { cpu.sr |= SR_V; } else { cpu.sr &= ~(SR_V as! u16); }
}

// メモリのシフト: ワード、1 ビットだけ。
fn shift_memory(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    let mode: i32 = (op >> 3) & 0x07;
    let reg: i32 = op & 0x07;
    let left = (op & 0x0100) != 0;
    let kind: i32 = (op >> 9) & 0x03;
    let addr = ea_calc_addr(cpu, mmu, mode, reg, 2);
    let before: u32 = mmu.read16(addr);
    let after, carry = shift_one(before, 0x8000, kind, left, cpu.flag_x());
    mmu.write16(addr, after as! u16);
    let sign_changed = left && kind == SHIFT_AS && ((after & 0x8000) != 0) != carry;
    shift_flags(cpu, 2, after, kind, carry, sign_changed);
    return shift_mem_cycles(mode, reg);
}

// レジスタのシフト: バイト / ワード / ロング、回数は即値 (1-8) かレジスタ (下位 6 ビット)。
fn shift_register(cpu: M68kCPU&, op: u16) -> i32 {
    let count_field: i32 = (op >> 9) & 0x07;
    let left = (op & 0x0100) != 0;
    let sz_code: i32 = (op >> 6) & 0x03;
    let kind: i32 = (op >> 3) & 0x03;
    let dreg: i32 = op & 0x07;
    let size: i32 = if sz_code == 0 { 1 } else if sz_code == 1 { 2 } else { 4 };
    let count = if (op & 0x0020) != 0 { (cpu.d[count_field] & 63) as i32 }
                else if count_field == 0 { 8 } else { count_field };

    if count == 0 {
        // 値は変わらない。C は ROX のとき X を写し、それ以外は落ちる。
        if kind == SHIFT_ROX && cpu.flag_x() { cpu.sr |= SR_C; } else { cpu.sr &= ~(SR_C as! u16); }
        cpu.sr &= ~(SR_V as! u16);
        cpu.set_nz_only(size, cpu.d[dreg]);
        return shift_reg_cycles(size, 0);
    }

    let msb: u32 = if size == 1 { 0x80 } else if size == 2 { 0x8000 } else { 0x80000000 };
    let mask = msb | (msb - 1);
    var part = cpu.d[dreg] & mask;
    var x = cpu.flag_x();
    var carry = false;
    var sign_changed = false;
    for _ in count {
        let next, out = shift_one(part, msb, kind, left, x);
        if left && kind == SHIFT_AS && ((next & msb) != 0) != out { sign_changed = true; }
        part = next;
        carry = out;
        if kind == SHIFT_ROX { x = out; }
    }
    // オペランドより上のビットはそのまま残る
    cpu.d[dreg] = (cpu.d[dreg] & ~mask) | part;
    shift_flags(cpu, size, cpu.d[dreg], kind, carry, sign_changed);
    return shift_reg_cycles(size, count);
}

fn exec_opE_shift_rotate(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    if ((op >> 6) & 0x03) == 3 { return shift_memory(cpu, mmu, op); }
    return shift_register(cpu, op);
}

// MOVE / MOVEA。上位 4 ビットが大きさ (1 = バイト、3 = ワード、2 = ロング)。
fn exec_move(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    let hi4 = (op >> 12) & 0x0F;
    let size: i32 = if hi4 == 1 { 1 } else if hi4 == 3 { 2 } else { 4 };
    let src_mode: i32 = (op >> 3) & 0x07;
    let src_reg: i32 = op & 0x07;
    let dst_reg: i32 = (op >> 9) & 0x07;
    let dst_mode: i32 = (op >> 6) & 0x07;

    let val = ea_read(cpu, mmu, src_mode, src_reg, size);
    ea_write(cpu, mmu, dst_mode, dst_reg, size, val);

    if dst_mode != 1 { // MOVEA はフラグを変えない
        cpu.set_nz(size, val);
    }
    return move_cycles(size, src_mode, src_reg, dst_mode, dst_reg);
}

// ADDQ / SUBQ / Scc / DBcc
fn exec_op5(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    // DBcc (0101 cccc 1100 1rrr)
    if (op & 0xF0F8) == 0x50C8 {
        let cond: i32 = (op >> 8) & 0x0F;
        let dreg: i32 = op & 0x07;
        let disp: i32 = fetch16(cpu, mmu) as! i16;
        if !cpu.check_condition(cond) {
            let count = (cpu.d[dreg] & 0xFFFF) as i32 - 1;
            cpu.d[dreg] = (cpu.d[dreg] & 0xFFFF0000) | ((count & 0xFFFF) as u32);
            if count != -1 {
                cpu.pc = addr_add(cpu.pc, disp - 2);
                return 10;
            }
            return 14;
        }
        return 12;
    }

    // Scc (0101 cccc 11 eee eee)
    if (op & 0xF0C0) == 0x50C0 {
        let cond: i32 = (op >> 8) & 0x0F;
        let mode: i32 = (op >> 3) & 0x07;
        let reg: i32 = op & 0x07;
        let set = cpu.check_condition(cond);
        ea_write(cpu, mmu, mode, reg, 1, if set { 0xFF } else { 0 });
        if mode == 0 { return if set { 6 } else { 4 }; }
        return 8 + ea_bw_extra(mode, reg);
    }

    // ADDQ / SUBQ
    let q3: u32 = (op >> 9) & 0x07;
    let q: u32 = if q3 == 0 { 8 } else { q3 };   // 0 は 8 を表す
    let is_sub = (op & 0x0100) != 0;
    let sz_code: i32 = (op >> 6) & 0x03;
    let mode: i32 = (op >> 3) & 0x07;
    let reg: i32 = op & 0x07;
    let size: i32 = if sz_code == 0 { 1 } else if sz_code == 1 { 2 } else { 4 };

    if mode == 1 { // An: アドレスレジスタへの ADDQ.W / ADDQ.L はフラグを変えない
        let cur = cpu.a[reg];
        cpu.a[reg] = if is_sub { cur - q } else { cur + q };
        return addq_cycles(size, mode, reg);
    }

    let ea_res = ea_read_for_rmw(cpu, mmu, mode, reg, size);
    let cur = ea_res.val;
    let res = if is_sub { cur - q } else { cur + q };
    ea_write_for_rmw(cpu, mmu, mode, reg, size, ea_res.addr, res);
    if is_sub {
        cpu.flags_sub(size, q, cur, res, true);
    } else {
        cpu.flags_add(size, q, cur, res);
    }
    return addq_cycles(size, mode, reg);
}

// BRA / BSR / Bcc。変位が 0 なら、続く 1 ワードが 16 ビットの変位。
fn exec_branch(cpu: M68kCPU&, mmu: M68kMMU&, op: u16) -> i32 {
    let cond: i32 = (op >> 8) & 0x0F;
    let base_pc = cpu.pc;
    var disp: i32 = (op & 0xFF) as! i8;
    if disp == 0 {
        disp = (fetch16(cpu, mmu) as! i16);
    }

    let target = addr_add(base_pc, disp);

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
    if cpu.check_condition(cond) {
        cpu.pc = target;
        return bcc_cycles(word_disp, true);
    }
    return bcc_cycles(word_disp, false);
}

// MOVEQ: 8 ビットの即値を符号拡張して Dn へ
fn exec_moveq(cpu: M68kCPU&, op: u16) -> i32 {
    let dreg: i32 = (op >> 9) & 0x07;
    let data8 = (op & 0xFF) as! i8;
    cpu.d[dreg] = (data8) as! u32;
    cpu.set_nz(4, cpu.d[dreg]);
    return 4;
}

// -------------------------------------------------------------
// 1命令を実行して消費サイクル数を返す
// -------------------------------------------------------------
fn step_core(cpu: M68kCPU&, mmu: M68kMMU&) -> i32 {
    // 68000 はアドレス線が 24 本でも PC の 32 ビットをすべて持つ。IPL の例外処理はこれに頼っている:
    // $02FF0540 のようなベクタは最上位バイトにベクタ番号を持ち、BSR がそれを積んで
    // 処理ルーチンが読む。
    if cpu.halted {
        return 4;
    }

    let inst_pc = cpu.pc;
    mmu.inst_pc = inst_pc;
    let op = fetch16(cpu, mmu);
    mmu.cur_ir = op;
    let hi4 = (op >> 12) & 0x0F;

    match hi4 {
        // Op 0: ビット操作 & 即値演算
        0 => {
            return exec_op0(cpu, mmu, op);
        },
        // Op 1, 2, 3: MOVE / MOVEA
        1, 2, 3 => {
            return exec_move(cpu, mmu, op);
        },
        // Op 4: 雑多命令 (LEA, PEA, MOVEM, CLR, NEG, NOT, TST, JMP, JSR, TRAP, LINK, UNLK, MOVE to/from SR/CCR/USP)
        4 => {
            return exec_op4(cpu, mmu, op);
        },
        // Op 5: ADDQ、SUBQ、Scc、DBcc
        5 => {
            return exec_op5(cpu, mmu, op);
        },
        // Op 6: BRA (disp8/16)、BSR、Bcc
        6 => {
            return exec_branch(cpu, mmu, op);
        },
        // Op 7: MOVEQ (0111 ddd0 data8)
        7 => {
            return exec_moveq(cpu, op);
        },
        // Op 8: OR, DIVU, DIVS
        8 => {
            return exec_op8_or_div(cpu, mmu, op);
        },
        // Op 9: SUB, SUBA, SUBX
        9 => {
            return exec_add_sub(cpu, mmu, op, false);
        },
        // Op B: CMP, CMPA, EOR, CMPM
        0x0B => {
            return exec_opB_cmp_eor(cpu, mmu, op);
        },
        // Op C: AND, MULU, MULS, EXG
        0x0C => {
            return exec_opC_and_mul_exg(cpu, mmu, op);
        },
        // Op D: ADD, ADDA, ADDX
        0x0D => {
            return exec_add_sub(cpu, mmu, op, true);
        },
        // Op E: シフト & ローテート
        0x0E => {
            return exec_opE_shift_rotate(cpu, mmu, op);
        },
        // Op A: Line 1010 エミュレータ例外 (Vector 10)
        0x0A => {
            trigger_exception(cpu, mmu, 10, inst_pc);
            return 34;
        },
        // Op F: Line 1111 エミュレータ例外 (Vector 11、Human68k の DOS コール)
        _ => {
            trigger_exception(cpu, mmu, 11, inst_pc);
            return 34;
        },
    }
}

// 命令が失敗したあとのグループ 0 例外 (2 = バスエラー、3 = アドレスエラー)。
// XEiJ と同じく、データレジスタと SR は元に戻し、失敗の前にしたアドレスレジスタの更新は
// 残す。スタックフレームには命令コードと命令の番地を積む。
fn group0(cpu: M68kCPU&, mmu: M68kMMU&, d: u32[8], sr: u16) {
    let vector = mmu::fault_vector(mmu.fault);
    let addr = mmu.fault_addr;
    let write = mmu.fault_write;
    mmu.fault = mmu::Fault.None;
    mmu.user_mode = false;
    cpu.d = d;
    cpu.set_sr(sr);
    if !cpu.is_supervisor() {
        cpu.usp = cpu.a[REG_A7];
        cpu.a[REG_A7] = cpu.ssp;
    }
    push32(cpu, mmu, mmu.inst_pc);
    push16(cpu, mmu, sr);
    push16(cpu, mmu, mmu.cur_ir);
    push32(cpu, mmu, addr);
    push16(cpu, mmu, if write { 0 } else { 0x10 });
    if mmu.failed() { // スタックに積む途中で失敗した: 68000 は停止する
        mmu.fault = mmu::Fault.None;
        cpu.halted = true;
        return;
    }
    cpu.sr |= SR_S;
    cpu.sr &= ~(SR_T as! u16);
    cpu.pc = mmu.read32(((vector * 4) as! u32));
}

fn step(cpu: M68kCPU&, mmu: M68kMMU&) -> i32 {
    let d = cpu.d;
    let sr = cpu.sr;
    // トレースは命令を始める時点の T ビットで決まる。
    let traced = (sr & SR_T) != 0;
    cpu.took_exception = false;
    mmu.user_mode = !cpu.is_supervisor();
    mmu.cpu_access = true;
    var cycles = step_core(cpu, mmu);
    // 奇数番地へのジャンプは、ジャンプした命令で失敗する。
    if !mmu.failed() && (cpu.pc & 1) != 0 && !cpu.halted {
        mmu.raise_fault(mmu::Fault.Address, cpu.pc & ADDR_MASK, false);
    }
    if mmu.failed() {
        group0(cpu, mmu, d, sr);
        cycles += 50;
    } else if traced && !cpu.took_exception && !cpu.halted {
        // トレース例外 (ベクタ 9)。次の命令のアドレスを積む。命令が別の例外へ入ったときは重ねない。
        trigger_exception(cpu, mmu, 9, cpu.pc);
        cycles += 34;
    }
    mmu.cpu_access = false;
    cycles += mmu.wait40 / 40;
    mmu.wait40 = mmu.wait40 % 40;
    return cycles;
}

// M68000 割り込み処理 (Level: 1..7, Vector: 0..255)
fn interrupt(cpu: M68kCPU&, mmu: M68kMMU&, level: i32, vector: i32) {
    if !cpu.is_supervisor() {
        // ユーザモードからスーパーバイザモードへの移行
        cpu.usp = cpu.a[REG_A7];
        cpu.a[REG_A7] = cpu.ssp;
    }

    // 現在の PC と SR をスーパーバイザスタックにプッシュ
    push32(cpu, mmu, cpu.pc);
    push16(cpu, mmu, cpu.sr);

    // スーパーバイザフラグをセット、トレースをオフ
    cpu.sr |= SR_S;
    cpu.sr &= ~(SR_T as! u16);

    // 割込マスクを更新 (レベルを設定)
    cpu.sr = (cpu.sr & ~0x0700) | (((level & 7) as u16) << 8);

    // ベクタアドレスから新しい PC を取得
    let vec_addr = ((vector & 0xFF) * 4) as! u32;
    cpu.pc = mmu.read32(vec_addr);
    cpu.halted = false;
}
