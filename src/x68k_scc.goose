// Z85C30 SCC ($E98000-$E98007)。X68000 ではポート B がマウス、ポート A が RS-232C。
// px68k scc.c と同じく、マウスだけを作る。RS-232C は読むと 0、書いても何もしない。
//
// マウスは、ポート B の RTS (WR5 の bit 1) を 0 から 1 にすると、ボタン、X、Y の 3 バイトを送ってくる。
// ソフトはそれを受信割り込み (レベル 5) か、RR0 の受信ありのビットを見て読む。
// 動いた量は、ホストのマウスから move で足しておき、送るときに -128〜127 に切り詰める (px68k mouse.c)。

namespace scc;

let ::SCC_IRQ_LEVEL = 5;

struct X68kSCC {
    reg_num_a: u8 = 0,
    reg_set_a: bool = false,
    regs_b: u8[16] = [0; 16],   // ポート B の書き込みレジスタ (WR9 は両ポート共通なのでここに置く)
    reg_num_b: u8 = 0,
    reg_set_b: bool = false,
    vector: u8 = 0,
    dat: u8[3] = [0; 3],        // 送る 3 バイト。後ろから読む (Y、X、ボタンの順に dat[0..2])
    dat_num: i32 = 0,           // 残りのバイト数
    irq: bool = false,          // レベル 5 の要求
    line_div: i32 = 0,          // int_check を呼ぶ間隔を数える
    // ホストのマウス。まだ送っていない動きとボタン
    move_x: i32 = 0,
    move_y: i32 = 0,
    buttons: u8 = 0,            // bit 0 左、bit 1 右
}

type ::X68kSCC = scc::X68kSCC;

// WR1 の受信割り込みの方式 (bit 4-3) と WR9 の MIE (bit 3)
let WR1_RX_INT_MASK: u8 = 0x18;
let WR1_RX_INT_ALL: u8 = 0x10;    // 受信したバイトごと
let WR1_RX_INT_FIRST: u8 = 0x08;  // 最初のバイトだけ
let WR9_MIE: u8 = 0x08;
let WR9_VIS: u8 = 0x01;           // ベクタに状態を入れる
let WR9_NV: u8 = 0x02;            // ベクタを出さない
let WR9_STATUS_HIGH: u8 = 0x10;
let WR5_RTS: u8 = 0x02;
let WR3_RX_ENABLE: u8 = 0x01;

// ホストのマウスが dx, dy 動いた (X68000 の座標の向き: 右と下が正)。
fn move(scc: X68kSCC&, dx: i32, dy: i32) {
    scc.move_x += dx;
    scc.move_y += dy;
}

fn set_buttons(scc: X68kSCC&, left: bool, right: bool) {
    let l: u8 = if left { 1 } else { 0 };
    let r: u8 = if right { 2 } else { 0 };
    scc.buttons = l | r;
}

// 動いた量を 1 バイトに切り詰める。はみ出したら状態のバイトに印を立てる (over は正、under は負の側)。
fn clamp_move(v: i32, st: u8&, over: u8, under: u8) -> u8 {
    if v > 127 { st |= over; return 127; }
    if v < -128 { st |= under; return 0x80; }
    return (v & 0xFF) as u8;
}

// マウスが 3 バイトを送る (px68k Mouse_SetData)。
fn send_mouse(scc: X68kSCC&) {
    var st = scc.buttons;
    let x = clamp_move(scc.move_x, st, 0x10, 0x20);
    let y = clamp_move(scc.move_y, st, 0x40, 0x80);
    scc.move_x = 0;
    scc.move_y = 0;
    scc.dat_num = 3;
    scc.dat[2] = st;
    scc.dat[1] = x;
    scc.dat[0] = y;
}

fn write(scc: X68kSCC&, a: u32, data: u8) {
    if (a & 7) == 1 {
        // ポート B の制御
        if scc.reg_set_b {
            if scc.reg_num_b == 5 {
                let rts_rises = (scc.regs_b[5] & WR5_RTS) == 0 && (data & WR5_RTS) != 0;
                if rts_rises && (scc.regs_b[3] & WR3_RX_ENABLE) != 0 && scc.dat_num == 0 {
                    scc.send_mouse();
                }
            } else if scc.reg_num_b == 2 {
                scc.vector = data;
            }
            scc.reg_set_b = false;
            scc.regs_b[scc.reg_num_b] = data;
            scc.reg_num_b = 0;
        } else if (data & 0xF0) == 0 {
            scc.reg_set_b = true;
            scc.reg_num_b = data & 15;
        } else {
            scc.reg_set_b = false;
            scc.reg_num_b = 0;
        }
    } else if (a & 7) == 5 {
        // ポート A の制御。マウスに関わる WR2 (ベクタ) と WR9 (割り込みの制御) だけを受ける
        if scc.reg_set_a {
            scc.reg_set_a = false;
            if scc.reg_num_a == 2 {
                scc.regs_b[2] = data;
                scc.vector = data;
            } else if scc.reg_num_a == 9 {
                scc.regs_b[9] = data;
            }
        } else {
            let n = data & 15;
            scc.reg_set_a = n != 0;
            scc.reg_num_a = n;
        }
    }
}

fn read(scc: X68kSCC&, a: u32) -> u8 {
    var ret: u8 = 0;
    if (a & 7) == 1 {
        // ポート B の RR0: bit 0 = 受信したバイトがある
        if scc.reg_num_b == 0 { ret = if scc.dat_num != 0 { 1 } else { 0 }; }
        scc.reg_num_b = 0;
        scc.reg_set_b = false;
    } else if (a & 7) == 3 {
        // ポート B のデータ
        if scc.dat_num != 0 {
            scc.dat_num -= 1;
            ret = scc.dat[scc.dat_num];
        }
    } else if (a & 7) == 5 {
        // ポート A: RR0 は送信バッファが空 (bit 2)、RR3 は受信割り込みの保留 (ポート B の受信は bit 2)
        if scc.reg_num_a == 0 { ret = 4; }
        else if scc.reg_num_a == 3 { ret = if scc.dat_num != 0 { 4 } else { 0 }; }
        scc.reg_num_a = 0;
        scc.reg_set_a = false;
    }
    return ret;
}

// 走査線ごとに呼ぶ。1/8 フレームごとに int_check する (px68k の MouseIntCnt)。
fn scanline(scc: X68kSCC&, vline_total: i32) {
    scc.line_div += 1;
    if scc.line_div > vline_total / 8 {
        scc.line_div = 0;
        scc.int_check();
    }
}

// 受信したバイトが残っていれば割り込みを要求する (px68k SCC_IntCheck)。
fn int_check(scc: X68kSCC&) {
    let mode = scc.regs_b[1] & WR1_RX_INT_MASK;
    let mie = (scc.regs_b[9] & WR9_MIE) != 0;
    if mie && ((scc.dat_num != 0 && mode == WR1_RX_INT_ALL) || (scc.dat_num == 3 && mode == WR1_RX_INT_FIRST)) {
        scc.irq = true;
    }
}

// 割り込みを受け付けたときのベクタ (px68k SCC_Int)。ベクタを出さない設定なら -1。
fn ack(scc: X68kSCC&) -> i32 {
    scc.irq = false;
    let wr9 = scc.regs_b[9];
    if (wr9 & WR9_NV) != 0 { return -1; }
    let v = scc.vector as i32;
    if (wr9 & WR9_VIS) == 0 { return v; }
    // 状態入りのベクタ: ポート B の受信 (状態 2)
    return if (wr9 & WR9_STATUS_HIGH) != 0 { (v & 0x8F) + 0x20 } else { (v & 0xF1) + 4 };
}
