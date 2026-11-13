// MC68000 逆アセンブラ。デバッガ (arcl_disasm) 用。
//
// 表記はモトローラ形式。数値は 16 進で `$` を付ける。相対分岐と PC 相対は飛び先の絶対番地を出す。
// 68000 に無い命令と、ライン A / ライン F (X68000 では IOCS / DOS コール) は `DC.W` で出す。
// メモリは mmu::peek8 で読むので、I/O レジスタを逆アセンブルしても機器の状態は変わらない。

import std;
import .m68k_mmu;

// 読み進める位置。命令語の次から始まり、拡張語を読むたびに進む。
struct DisCursor {
    pc: u32,
}

fn dis_word(mmu: M68kMMU&, at: u32) -> u16 {
    let hi: u16 = mmu.peek8(at);
    let lo: u16 = mmu.peek8(at + 1);
    return (hi << 8) | lo;
}

fn dis_next16(mmu: M68kMMU&, cur: DisCursor&) -> u16 {
    let w = dis_word(mmu, cur.pc);
    cur.pc += 2;
    return w;
}

fn dis_next32(mmu: M68kMMU&, cur: DisCursor&) -> u32 {
    let hi: u32 = dis_next16(mmu, cur);
    let lo: u32 = dis_next16(mmu, cur);
    return (hi << 16) | lo;
}

fn dis_hex(out: u8[>..]&, v: u32, digits: i32) {
    out.push('$');
    format_uint(out, v, 16, digits, '0');
}

// 符号付きの変位。負なら `-$10`。
fn dis_disp(out: u8[>..]&, d: i32) {
    if d < 0 {
        out.push('-');
        dis_hex(out, (0 - d) as u32, 1);
    } else {
        dis_hex(out, d as u32, 1);
    }
}

fn dis_size(out: u8[>..]&, size: i32) {
    out.append(if size == 1 { ".B" } else if size == 2 { ".W" } else { ".L" });
}

// サイズフィールド (0, 1, 2) をバイト数に。3 は 0 を返す (その形の命令ではない)。
fn dis_size_of(code: u16) -> i32 {
    return if code == 0 { 1 } else if code == 1 { 2 } else if code == 2 { 4 } else { 0 };
}

fn dis_dreg(out: u8[>..]&, r: u16) { format(out, "D", r); }
fn dis_areg(out: u8[>..]&, r: u16) { format(out, "A", r); }

// 拡張語のインデックスレジスタ部分 `D3.W` / `A1.L`
fn dis_index(out: u8[>..]&, ext: u16) {
    if (ext & 0x8000) != 0 { dis_areg(out, (ext >> 12) & 7); } else { dis_dreg(out, (ext >> 12) & 7); }
    out.append(if (ext & 0x0800) != 0 { ".L" } else { ".W" });
}

// 実効アドレス。size は即値の大きさを決める。表せない組み合わせなら false。
fn dis_ea(mmu: M68kMMU&, cur: DisCursor&, out: u8[>..]&, mode: u16, reg: u16, size: i32) -> bool {
    match mode {
        0 => { dis_dreg(out, reg); },
        1 => { dis_areg(out, reg); },
        2 => { format(out, "(A", reg, ")"); },
        3 => { format(out, "(A", reg, ")+"); },
        4 => { format(out, "-(A", reg, ")"); },
        5 => {
            let d: i16 = dis_next16(mmu, cur) as! i16;
            dis_disp(out, d);
            format(out, "(A", reg, ")");
        },
        6 => {
            let ext = dis_next16(mmu, cur);
            let d: i8 = (ext & 0xFF) as! i8;
            dis_disp(out, d);
            format(out, "(A", reg, ",");
            dis_index(out, ext);
            out.push(')');
        },
        _ => {
            match reg {
                0 => {
                    let w: i16 = dis_next16(mmu, cur) as! i16;
                    out.push('(');
                    dis_hex(out, (w as! u32) & ADDR_MASK, 6);
                    out.append(").W");
                },
                1 => {
                    out.push('(');
                    dis_hex(out, dis_next32(mmu, cur), 8);
                    out.append(").L");
                },
                2 => {
                    let base = cur.pc;
                    let d: i16 = dis_next16(mmu, cur) as! i16;
                    dis_hex(out, base + (d as! u32), 6);
                    out.append("(PC)");
                },
                3 => {
                    let base = cur.pc;
                    let ext = dis_next16(mmu, cur);
                    let d: i8 = (ext & 0xFF) as! i8;
                    dis_hex(out, base + (d as! u32), 6);
                    out.append("(PC,");
                    dis_index(out, ext);
                    out.push(')');
                },
                4 => {
                    out.push('#');
                    if size == 4 {
                        dis_hex(out, dis_next32(mmu, cur), 8);
                    } else if size == 2 {
                        dis_hex(out, dis_next16(mmu, cur), 4);
                    } else {
                        dis_hex(out, dis_next16(mmu, cur) & 0xFF, 2);
                    }
                },
                _ => { return false; },
            }
        },
    }
    return true;
}

fn dis_cond(out: u8[>..]&, cond: u16) {
    let names: u8[2][16] = ["T ", "F ", "HI", "LS", "CC", "CS", "NE", "EQ", "VC", "VS", "PL", "MI", "GE", "LT", "GT", "LE"];
    let n = names[cond & 15];
    out.push(n[0]);
    if n[1] != ' ' { out.push(n[1]); }
}

// MOVEM のレジスタ一覧 `D0-D3/A0/A6`。-(An) への退避ではマスクのビット順が逆になる。
fn dis_reglist(out: u8[>..]&, mask: u16, reversed: bool) {
    var first = true;
    var i = 0;
    while i < 16 {
        let bit: u16 = if reversed { 0x8000 >> i } else { 1 << i };
        if (mask & bit) == 0 {
            i++;
            continue;
        }
        // 同じ種類 (D か A) の中で連続している範囲をまとめる
        var j = i;
        while j + 1 < 16 && (j + 1) / 8 == i / 8 {
            let next: u16 = if reversed { 0x8000 >> (j + 1) } else { 1 << (j + 1) };
            if (mask & next) == 0 { break; }
            j++;
        }
        if !first { out.push('/'); }
        first = false;
        let kind: u8 = if i < 8 { 'D' } else { 'A' };
        format(out, [kind], i % 8);
        if j > i { format(out, "-", [kind], j % 8); }
        i = j + 1;
    }
    if first { out.append("#0"); }
}

// 命令語だけでは表せなかったとき。読み位置を命令語の直後に戻して `DC.W` にする。
fn dis_data(out: u8[>..]&, cur: DisCursor&, addr: u32, op: u16) {
    out.clear();
    out.append("DC.W ");
    dis_hex(out, op, 4);
    cur.pc = addr + 2;
}

fn dis_group0(mmu: M68kMMU&, cur: DisCursor&, out: u8[>..]&, op: u16) -> bool {
    let mode = (op >> 3) & 7;
    let reg = op & 7;
    // MOVEP
    if (op & 0x0138) == 0x0108 {
        let long = (op & 0x0040) != 0;
        out.append(if long { "MOVEP.L " } else { "MOVEP.W " });
        let d: i16 = dis_next16(mmu, cur) as! i16;
        if (op & 0x0080) != 0 {
            dis_dreg(out, (op >> 9) & 7);
            out.push(',');
            dis_disp(out, d);
            format(out, "(A", reg, ")");
        } else {
            dis_disp(out, d);
            format(out, "(A", reg, "),");
            dis_dreg(out, (op >> 9) & 7);
        }
        return true;
    }
    let bit_names: u8[4][4] = ["BTST", "BCHG", "BCLR", "BSET"];
    // ビット操作。ビット番号が Dn のもの
    if (op & 0x0100) != 0 {
        if mode == 1 { return false; }
        format(out, bit_names[(op >> 6) & 3], " ");
        dis_dreg(out, (op >> 9) & 7);
        out.push(',');
        return dis_ea(mmu, cur, out, mode, reg, 1);
    }
    // ビット番号が即値のもの
    if (op & 0x0F00) == 0x0800 {
        if mode == 1 { return false; }
        format(out, bit_names[(op >> 6) & 3], " #");
        dis_hex(out, dis_next16(mmu, cur) & 0xFF, 1);
        out.push(',');
        return dis_ea(mmu, cur, out, mode, reg, 1);
    }
    let kind = (op >> 9) & 7;
    let names: u8[4][8] = ["ORI ", "ANDI", "SUBI", "ADDI", "    ", "EORI", "CMPI", "    "];
    if kind == 4 || kind == 7 { return false; }
    // CCR / SR への即値演算
    if (op & 0x00BF) == 0x003C && (kind == 0 || kind == 1 || kind == 5) {
        format(out, names[kind]);
        if out[out.len - 1] == ' ' { out.pop(); }
        out.append(" #");
        if (op & 0x0040) != 0 {
            dis_hex(out, dis_next16(mmu, cur), 4);
            out.append(",SR");
        } else {
            dis_hex(out, dis_next16(mmu, cur) & 0xFF, 2);
            out.append(",CCR");
        }
        return true;
    }
    let size = dis_size_of((op >> 6) & 3);
    if size == 0 || mode == 1 { return false; }
    format(out, names[kind]);
    if out[out.len - 1] == ' ' { out.pop(); }
    dis_size(out, size);
    out.append(" ");
    if !dis_ea(mmu, cur, out, 7, 4, size) { return false; }
    out.push(',');
    return dis_ea(mmu, cur, out, mode, reg, size);
}

fn dis_move(mmu: M68kMMU&, cur: DisCursor&, out: u8[>..]&, op: u16) -> bool {
    let hi4 = op >> 12;
    let size: i32 = if hi4 == 1 { 1 } else if hi4 == 3 { 2 } else { 4 };
    let dst_mode = (op >> 6) & 7;
    let dst_reg = (op >> 9) & 7;
    if dst_mode == 1 {
        if size == 1 { return false; }
        out.append("MOVEA");
    } else {
        out.append("MOVE");
    }
    dis_size(out, size);
    out.push(' ');
    if !dis_ea(mmu, cur, out, (op >> 3) & 7, op & 7, size) { return false; }
    out.push(',');
    if dst_mode == 7 && dst_reg > 1 { return false; }
    return dis_ea(mmu, cur, out, dst_mode, dst_reg, size);
}

fn dis_group4(mmu: M68kMMU&, cur: DisCursor&, out: u8[>..]&, op: u16) -> bool {
    let mode = (op >> 3) & 7;
    let reg = op & 7;
    match op {
        0x4E70 => { out.append("RESET"); return true; },
        0x4E71 => { out.append("NOP"); return true; },
        0x4E72 => {
            out.append("STOP #");
            dis_hex(out, dis_next16(mmu, cur), 4);
            return true;
        },
        0x4E73 => { out.append("RTE"); return true; },
        0x4E75 => { out.append("RTS"); return true; },
        0x4E76 => { out.append("TRAPV"); return true; },
        0x4E77 => { out.append("RTR"); return true; },
        0x4AFC => { out.append("ILLEGAL"); return true; },
        _ => {},
    }
    if (op & 0xFFF0) == 0x4E40 {
        format(out, "TRAP #", op & 15);
        return true;
    }
    if (op & 0xFFF8) == 0x4E50 {
        format(out, "LINK A", reg, ",#");
        let d: i16 = dis_next16(mmu, cur) as! i16;
        dis_disp(out, d);
        return true;
    }
    if (op & 0xFFF8) == 0x4E58 {
        format(out, "UNLK A", reg);
        return true;
    }
    if (op & 0xFFF8) == 0x4E60 {
        format(out, "MOVE A", reg, ",USP");
        return true;
    }
    if (op & 0xFFF8) == 0x4E68 {
        format(out, "MOVE USP,A", reg);
        return true;
    }
    if (op & 0xFFC0) == 0x4E80 || (op & 0xFFC0) == 0x4EC0 {
        if mode < 2 || mode == 3 || mode == 4 || (mode == 7 && reg == 4) { return false; }
        out.append(if (op & 0x0040) != 0 { "JMP " } else { "JSR " });
        return dis_ea(mmu, cur, out, mode, reg, 4);
    }
    if (op & 0xF1C0) == 0x41C0 {
        if mode < 2 || mode == 3 || mode == 4 || (mode == 7 && reg == 4) { return false; }
        out.append("LEA ");
        if !dis_ea(mmu, cur, out, mode, reg, 4) { return false; }
        out.push(',');
        dis_areg(out, (op >> 9) & 7);
        return true;
    }
    if (op & 0xF1C0) == 0x4180 {
        if mode == 1 { return false; }
        out.append("CHK ");
        if !dis_ea(mmu, cur, out, mode, reg, 2) { return false; }
        out.push(',');
        dis_dreg(out, (op >> 9) & 7);
        return true;
    }
    if (op & 0xFFF8) == 0x4840 {
        format(out, "SWAP D", reg);
        return true;
    }
    if (op & 0xFFC0) == 0x4840 {
        if mode < 2 || mode == 3 || mode == 4 || (mode == 7 && reg == 4) { return false; }
        out.append("PEA ");
        return dis_ea(mmu, cur, out, mode, reg, 4);
    }
    if (op & 0xFFB8) == 0x4880 {
        format(out, if (op & 0x0040) != 0 { "EXT.L D" } else { "EXT.W D" }, reg);
        return true;
    }
    if (op & 0xFB80) == 0x4880 {
        let size: i32 = if (op & 0x0040) != 0 { 4 } else { 2 };
        let to_regs = (op & 0x0400) != 0;
        if mode < 2 || (to_regs && mode == 4) || (!to_regs && mode == 3) { return false; }
        out.append("MOVEM");
        dis_size(out, size);
        out.push(' ');
        let mask = dis_next16(mmu, cur);
        if to_regs {
            if !dis_ea(mmu, cur, out, mode, reg, size) { return false; }
            out.push(',');
            dis_reglist(out, mask, false);
            return true;
        }
        dis_reglist(out, mask, mode == 4);
        out.push(',');
        return dis_ea(mmu, cur, out, mode, reg, size);
    }
    if (op & 0xFFC0) == 0x40C0 {
        if mode == 1 { return false; }
        out.append("MOVE SR,");
        return dis_ea(mmu, cur, out, mode, reg, 2);
    }
    if (op & 0xFFC0) == 0x44C0 || (op & 0xFFC0) == 0x46C0 {
        if mode == 1 { return false; }
        out.append("MOVE ");
        if !dis_ea(mmu, cur, out, mode, reg, 2) { return false; }
        out.append(if (op & 0x0200) != 0 { ",SR" } else { ",CCR" });
        return true;
    }
    if (op & 0xFFC0) == 0x4800 {
        if mode == 1 { return false; }
        out.append("NBCD ");
        return dis_ea(mmu, cur, out, mode, reg, 1);
    }
    if (op & 0xFFC0) == 0x4AC0 {
        if mode == 1 { return false; }
        out.append("TAS ");
        return dis_ea(mmu, cur, out, mode, reg, 1);
    }
    let size = dis_size_of((op >> 6) & 3);
    if size == 0 || mode == 1 { return false; }
    match op & 0xFF00 {
        0x4000 => { out.append("NEGX"); },
        0x4200 => { out.append("CLR"); },
        0x4400 => { out.append("NEG"); },
        0x4600 => { out.append("NOT"); },
        0x4A00 => { out.append("TST"); },
        _ => { return false; },
    }
    dis_size(out, size);
    out.push(' ');
    return dis_ea(mmu, cur, out, mode, reg, size);
}

fn dis_group5(mmu: M68kMMU&, cur: DisCursor&, out: u8[>..]&, op: u16) -> bool {
    let mode = (op >> 3) & 7;
    let reg = op & 7;
    if (op & 0xF0F8) == 0x50C8 {
        out.append("DB");
        // DBT は無く、条件 1 (F) の DBF は DBRA とも書く
        if ((op >> 8) & 15) == 1 { out.append("RA"); } else { dis_cond(out, (op >> 8) & 15); }
        format(out, " D", reg, ",");
        let base = cur.pc;
        let d: i16 = dis_next16(mmu, cur) as! i16;
        dis_hex(out, base + (d as! u32), 6);
        return true;
    }
    if (op & 0xF0C0) == 0x50C0 {
        if mode == 1 { return false; }
        out.push('S');
        dis_cond(out, (op >> 8) & 15);
        out.push(' ');
        return dis_ea(mmu, cur, out, mode, reg, 1);
    }
    let size = dis_size_of((op >> 6) & 3);
    if size == 0 || (mode == 1 && size == 1) { return false; }
    out.append(if (op & 0x0100) != 0 { "SUBQ" } else { "ADDQ" });
    dis_size(out, size);
    let q = (op >> 9) & 7;
    format(out, " #", if q == 0 { 8 } else { q }, ",");
    return dis_ea(mmu, cur, out, mode, reg, size);
}

fn dis_branch(mmu: M68kMMU&, cur: DisCursor&, out: u8[>..]&, op: u16) -> bool {
    let cond = (op >> 8) & 15;
    if cond == 0 {
        out.append("BRA");
    } else if cond == 1 {
        out.append("BSR");
    } else {
        out.push('B');
        dis_cond(out, cond);
    }
    let base = cur.pc;
    var d: i32 = (op & 0xFF) as! i8;
    if d == 0 {
        d = dis_next16(mmu, cur) as! i16;
        out.append(".W ");
    } else {
        out.append(".S ");
    }
    dis_hex(out, base + (d as! u32), 6);
    return true;
}

// OR / AND / ADD / SUB の共通形: `<ea>,Dn` または `Dn,<ea>`
fn dis_alu(mmu: M68kMMU&, cur: DisCursor&, out: u8[>..]&, op: u16, name: const u8[:]) -> bool {
    let mode = (op >> 3) & 7;
    let reg = op & 7;
    let size = dis_size_of((op >> 6) & 3);
    if size == 0 { return false; }
    out.append(name);
    dis_size(out, size);
    out.push(' ');
    if (op & 0x0100) != 0 {
        if mode < 2 { return false; }
        dis_dreg(out, (op >> 9) & 7);
        out.push(',');
        return dis_ea(mmu, cur, out, mode, reg, size);
    }
    if mode == 1 && size == 1 { return false; }
    if !dis_ea(mmu, cur, out, mode, reg, size) { return false; }
    out.push(',');
    dis_dreg(out, (op >> 9) & 7);
    return true;
}

// ABCD / SBCD / ADDX / SUBX の共通形: `Dy,Dx` または `-(Ay),-(Ax)`
fn dis_extended(out: u8[>..]&, op: u16) {
    let rx = (op >> 9) & 7;
    let ry = op & 7;
    if (op & 0x0008) != 0 {
        format(out, " -(A", ry, "),-(A", rx, ")");
    } else {
        format(out, " D", ry, ",D", rx);
    }
}

// ADDA / SUBA / CMPA
fn dis_addr_op(mmu: M68kMMU&, cur: DisCursor&, out: u8[>..]&, op: u16, name: const u8[:]) -> bool {
    let size: i32 = if (op & 0x0100) != 0 { 4 } else { 2 };
    out.append(name);
    dis_size(out, size);
    out.push(' ');
    if !dis_ea(mmu, cur, out, (op >> 3) & 7, op & 7, size) { return false; }
    out.push(',');
    dis_areg(out, (op >> 9) & 7);
    return true;
}

fn dis_mul_div(mmu: M68kMMU&, cur: DisCursor&, out: u8[>..]&, op: u16, name: const u8[:]) -> bool {
    if ((op >> 3) & 7) == 1 { return false; }
    out.append(name);
    out.append(if (op & 0x0100) != 0 { "S " } else { "U " });
    if !dis_ea(mmu, cur, out, (op >> 3) & 7, op & 7, 2) { return false; }
    out.push(',');
    dis_dreg(out, (op >> 9) & 7);
    return true;
}

fn dis_group8_c(mmu: M68kMMU&, cur: DisCursor&, out: u8[>..]&, op: u16) -> bool {
    let is_and = (op >> 12) == 0x0C;
    if (op & 0x00C0) == 0x00C0 {
        return dis_mul_div(mmu, cur, out, op, if is_and { "MUL" } else { "DIV" });
    }
    if (op & 0x01F0) == 0x0100 {
        out.append(if is_and { "ABCD" } else { "SBCD" });
        dis_extended(out, op);
        return true;
    }
    if is_and {
        let rx = (op >> 9) & 7;
        let ry = op & 7;
        if (op & 0x01F8) == 0x0140 {
            format(out, "EXG D", rx, ",D", ry);
            return true;
        }
        if (op & 0x01F8) == 0x0148 {
            format(out, "EXG A", rx, ",A", ry);
            return true;
        }
        if (op & 0x01F8) == 0x0188 {
            format(out, "EXG D", rx, ",A", ry);
            return true;
        }
    }
    return dis_alu(mmu, cur, out, op, if is_and { "AND" } else { "OR" });
}

fn dis_group9_d(mmu: M68kMMU&, cur: DisCursor&, out: u8[>..]&, op: u16) -> bool {
    let is_add = (op >> 12) == 0x0D;
    if (op & 0x00C0) == 0x00C0 {
        return dis_addr_op(mmu, cur, out, op, if is_add { "ADDA" } else { "SUBA" });
    }
    if (op & 0x0130) == 0x0100 {
        out.append(if is_add { "ADDX" } else { "SUBX" });
        dis_size(out, dis_size_of((op >> 6) & 3));
        dis_extended(out, op);
        return true;
    }
    return dis_alu(mmu, cur, out, op, if is_add { "ADD" } else { "SUB" });
}

fn dis_group_b(mmu: M68kMMU&, cur: DisCursor&, out: u8[>..]&, op: u16) -> bool {
    if (op & 0x00C0) == 0x00C0 { return dis_addr_op(mmu, cur, out, op, "CMPA"); }
    let size = dis_size_of((op >> 6) & 3);
    if (op & 0x0100) == 0 {
        out.append("CMP");
        dis_size(out, size);
        out.push(' ');
        if ((op >> 3) & 7) == 1 && size == 1 { return false; }
        if !dis_ea(mmu, cur, out, (op >> 3) & 7, op & 7, size) { return false; }
        out.push(',');
        dis_dreg(out, (op >> 9) & 7);
        return true;
    }
    if (op & 0x0038) == 0x0008 {
        out.append("CMPM");
        dis_size(out, size);
        format(out, " (A", op & 7, ")+,(A", (op >> 9) & 7, ")+");
        return true;
    }
    out.append("EOR");
    dis_size(out, size);
    out.push(' ');
    dis_dreg(out, (op >> 9) & 7);
    out.push(',');
    return dis_ea(mmu, cur, out, (op >> 3) & 7, op & 7, size);
}

fn dis_shift(mmu: M68kMMU&, cur: DisCursor&, out: u8[>..]&, op: u16) -> bool {
    let names: u8[3][4] = ["AS ", "LS ", "ROX", "RO "];
    let left = (op & 0x0100) != 0;
    if (op & 0x00C0) == 0x00C0 {
        // メモリ上の 1 ビットシフト
        if (op & 0x0800) != 0 || ((op >> 3) & 7) < 2 { return false; }
        format(out, names[(op >> 9) & 3]);
        if out[out.len - 1] == ' ' { out.pop(); }
        out.push(if left { 'L' } else { 'R' });
        out.append(".W ");
        return dis_ea(mmu, cur, out, (op >> 3) & 7, op & 7, 2);
    }
    format(out, names[(op >> 3) & 3]);
    if out[out.len - 1] == ' ' { out.pop(); }
    out.push(if left { 'L' } else { 'R' });
    dis_size(out, dis_size_of((op >> 6) & 3));
    let count = (op >> 9) & 7;
    if (op & 0x0020) != 0 {
        format(out, " D", count, ",D", op & 7);
    } else {
        format(out, " #", if count == 0 { 8 } else { count }, ",D", op & 7);
    }
    return true;
}

// addr の命令を out に書き、命令の長さ (バイト数) を返す。
fn m68k_disasm(mmu: M68kMMU&, addr: u32, out: u8[>..]&) -> i32 {
    let op = dis_word(mmu, addr);
    var cur = DisCursor { pc: addr + 2 };
    let start = out.len;
    var ok = false;
    match op >> 12 {
        0 => { ok = dis_group0(mmu, cur, out, op); },
        1, 2, 3 => { ok = dis_move(mmu, cur, out, op); },
        4 => { ok = dis_group4(mmu, cur, out, op); },
        5 => { ok = dis_group5(mmu, cur, out, op); },
        6 => { ok = dis_branch(mmu, cur, out, op); },
        7 => {
            if (op & 0x0100) == 0 {
                out.append("MOVEQ #");
                let d: i8 = (op & 0xFF) as! i8;
                dis_disp(out, d);
                format(out, ",D", (op >> 9) & 7);
                ok = true;
            }
        },
        8, 0x0C => { ok = dis_group8_c(mmu, cur, out, op); },
        9, 0x0D => { ok = dis_group9_d(mmu, cur, out, op); },
        0x0B => { ok = dis_group_b(mmu, cur, out, op); },
        0x0E => { ok = dis_shift(mmu, cur, out, op); },
        _ => {}, // ライン A / ライン F
    }
    if !ok {
        // 途中まで書いた分を捨てて DC.W にする
        while out.len > start { out.pop(); }
        out.append("DC.W ");
        dis_hex(out, op, 4);
        cur.pc = addr + 2;
    }
    return (cur.pc - addr) as i32;
}
