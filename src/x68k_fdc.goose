// Sharp X68000 フロッピーディスクコントローラ (uPD72065 / FDC) in Goose
// ※実機 ROM / ディスクコード自走用

import .x68k_bridge;

// uPD72065 のコマンド番号 (コマンドバイトの下位 5 bit)
let FDC_READ_DIAGNOSTIC = 2;
let FDC_SPECIFY = 3;
let FDC_SENSE_DEVICE = 4;
let FDC_WRITE_DATA = 5;
let FDC_READ_DATA = 6;
let FDC_RECALIBRATE = 7;
let FDC_SENSE_INT = 8;
let FDC_WRITE_DELETED = 9;
let FDC_READ_ID = 10;
let FDC_READ_DELETED = 12;
let FDC_WRITE_ID = 13;
let FDC_SEEK = 15;
let FDC_SCAN_EQUAL = 17;
let FDC_SCAN_LOW_OR_EQUAL = 25;
let FDC_SCAN_HIGH_OR_EQUAL = 29;

// コマンドバイトに続くパラメータのバイト数 (px68k CMD_TABLE)。添字はコマンド番号。
fn fdc_cmd_prm_len(cmd: i32) -> i32 {
    let table: u8[32] = [
        0, 0, 8, 2, 1, 8, 8, 1, 0, 8, 1, 0, 8, 5, 0, 2,
        0, 8, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 8, 0, 0,
    ];
    return table[cmd & 31];
}

// 結果相のバイト数 (px68k DAT_TABLE)。添字はコマンド番号。
fn fdc_cmd_rsp_len(cmd: i32) -> i32 {
    let table: u8[32] = [
        0, 0, 7, 0, 1, 7, 7, 0, 2, 7, 7, 0, 7, 7, 0, 0,
        0, 7, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 7, 0, 0,
    ];
    return table[cmd & 31];
}

// コマンドの進み具合。相ごとに要るデータだけを持つので、「パラメータ待ちなのに結果が残っている」
// のような組み合わせは表せない。
enum FdcPhase {
    Idle,                                // コマンド待ち
    Command { left: i32 },               // パラメータをあと left バイト受け取る
    Exec { len: i32, writing: bool },    // 実行相。data_buf の len バイトを受け渡す。writing なら CPU / DMA → FDC
    Result { left: i32 },                // 結果をあと left バイト読ませる
}

struct X68kFDC {
    cmd: i32 = 0,
    cyl: i32 = 0,
    drv: i32 = 0,
    ctrl: u8 = 0,
    phase: FdcPhase = FdcPhase.Idle,
    read_pos: i32 = 0,  // 読み出し位置。実行相では data_buf、結果相では rsp_buf の中
    write_pos: i32 = 0, // 書き込み位置。コマンド相では prm_buf、実行相では data_buf の中
    st0: u8 = 0,
    st1: u8 = 0,
    st2: u8 = 0,
    rsp_buf: u8[16] = [0; 16],
    prm_buf: u8[16] = [0; 16],
    data_buf: u8[8192] = [0; 8192],
    int_pending: bool = false,
}

// 実行相で受け渡すバイト数。実行相でなければ 0。
fn fdc_exec_len(fdc: X68kFDC&) -> i32 {
    match fdc.phase {
        Exec e => e.len,
        _ => 0,
    }
}

// 実行相で、CPU / DMA からデータを受け取っているところか。
fn fdc_is_writing(fdc: X68kFDC&) -> bool {
    match fdc.phase {
        Exec e => e.writing,
        _ => false,
    }
}

// 実行が済んだあとの相。結果のあるコマンドは結果相、無ければコマンド待ち。
fn fdc_done_phase(fdc: X68kFDC&) -> FdcPhase {
    let n = fdc_cmd_rsp_len(fdc.cmd);
    return if n > 0 { FdcPhase.Result { left: n } } else { FdcPhase.Idle };
}

fn fdc_init(fdc: X68kFDC&) {
    fdc = X68kFDC {};
}

fn fdc_ephase_end(fdc: X68kFDC&) {
    // レスポンスバッファにステータスとヘッド位置をセット
    fdc.rsp_buf[0] = fdc.st0;
    fdc.rsp_buf[1] = fdc.st1;
    fdc.rsp_buf[2] = fdc.st2;
    // C, H, R, N
    fdc.rsp_buf[3] = fdc.cyl as u8;
    fdc.rsp_buf[4] = fdc.prm_buf[3]; // H
    fdc.rsp_buf[5] = fdc.prm_buf[4]; // R
    fdc.rsp_buf[6] = fdc.prm_buf[5]; // N

    fdc.phase = fdc_done_phase(fdc);
    fdc.read_pos = 0;
    fdc.int_pending = true;

    var idc: u8 = 0;
    var idh: u8 = 0;
    var idr: u8 = 0;
    var idn: u8 = 0;
    if c_fdd_current_id(fdc.drv, idc, idh, idr, idn) != 0 {
        fdc.rsp_buf[3] = idc;
        fdc.rsp_buf[4] = idh;
        fdc.rsp_buf[5] = idr;
        fdc.rsp_buf[6] = idn;
    }
}

fn fdc_exec_cmd(fdc: X68kFDC&) {
    let cmd = fdc.cmd;

    match cmd {
        FDC_SPECIFY => {
            // 何もしない
        },
        FDC_SENSE_DEVICE => {
            let us = (fdc.prm_buf[1] & 7);
            fdc.st0 = us;
            var st3: u8 = us;
            if fdc.cyl == 0 { st3 |= 0x10; } // Track 0
            if c_fdd_is_loaded(fdc.drv) { st3 |= 0x20; } // Ready
            fdc.rsp_buf[0] = st3;
        },
        FDC_RECALIBRATE => {
            fdc.st0 = (fdc.prm_buf[1] & 7);
            fdc.cyl = 0;
            if !c_fdd_is_loaded(fdc.drv) {
                fdc.st0 |= 0x48; // no FD
            } else if fdc.drv >= 0 && fdc.drv < 2 {
                fdc.st0 |= 0x20; // with FD and drive
            } else {
                fdc.st0 |= 0x50; // no drive
            }
            fdc.int_pending = true;
        },
        FDC_SENSE_INT => {
            fdc.rsp_buf[0] = fdc.st0;
            fdc.rsp_buf[1] = fdc.cyl as u8;
            fdc.st0 = 0x80;
        },
        FDC_SEEK => {
            fdc.st0 = (fdc.prm_buf[1] & 7);
            if c_fdd_is_loaded(fdc.drv) {
                fdc.cyl = fdc.prm_buf[2];
                fdc.st0 |= 0x20;
            } else {
                fdc.st0 |= 0x48;
            }
            fdc.int_pending = true;
        },
        FDC_READ_ID => {
            fdc.st0 = fdc.prm_buf[1] & 7;
            let hd = (fdc.prm_buf[1] >> 2) & 1;
            if c_fdd_is_loaded(fdc.drv) {
                fdc.rsp_buf[0] = fdc.st0;
                fdc.rsp_buf[1] = fdc.st1;
                fdc.rsp_buf[2] = fdc.st2;
                fdc.rsp_buf[3] = fdc.cyl as u8;
                fdc.rsp_buf[4] = hd;
                fdc.rsp_buf[5] = 1; // 1-based sector
                fdc.rsp_buf[6] = 3; // 1024 bytes (2HD)
            } else {
                fdc.st0 |= 0x48;
                fdc.rsp_buf[0] = fdc.st0;
                fdc.rsp_buf[1] = fdc.st1;
                fdc.rsp_buf[2] = fdc.st2;
                fdc.rsp_buf[3] = 0;
                fdc.rsp_buf[4] = 0;
                fdc.rsp_buf[5] = 0;
                fdc.rsp_buf[6] = 0;
            }
            fdc.int_pending = true;
        },
        FDC_WRITE_DATA, FDC_WRITE_DELETED => {
            fdc.st0 = (fdc.prm_buf[1] & 7);
            if c_fdd_is_loaded(fdc.drv) {
                let hd = (fdc.prm_buf[1] >> 2) & 1;
                let trk = fdc.cyl * 2 + hd;
                let n: i32 = fdc.prm_buf[5];
                if c_fdd_seek(fdc.drv, trk) == 0 {
                    fdc.st0 |= 0x40;
                    fdc.st1 |= 0x04;
                    fdc_ephase_end(fdc);
                } else {
                    let sec_size = if n > 0 { (128 << n) as i32 } else { 1024 };
                    fdc.phase = FdcPhase.Exec { len: sec_size, writing: true };
                    fdc.write_pos = 0;
                }
            } else {
                fdc.st0 |= 0x48;
                fdc_ephase_end(fdc);
            }
        },
        FDC_READ_DATA, FDC_READ_DELETED => {
            fdc.st0 = (fdc.prm_buf[1] & 7);
            if c_fdd_is_loaded(fdc.drv) {
                let hd = (fdc.prm_buf[1] >> 2) & 1;
                let trk = fdc.cyl * 2 + hd;
                let c: i32 = fdc.prm_buf[2];
                let h: i32 = fdc.prm_buf[3];
                let r: i32 = fdc.prm_buf[4];
                let n: i32 = fdc.prm_buf[5];

                let sec_size = if n > 0 { (128 << n) as i32 } else { 1024 };

                let ok = c_fdd_read_fdc(fdc.drv, trk, c, h, r, n, fdc.data_buf[0]);
                if ok != 0 {
                    fdc.phase = FdcPhase.Exec { len: sec_size, writing: false };
                    fdc.read_pos = 0;
                } else {
                    fdc.st0 |= 0x40; // Abnormal termination
                    fdc.st1 |= 0x04; // No data
                    fdc_ephase_end(fdc);
                }
            } else {
                fdc.st0 |= 0x48;
                fdc_ephase_end(fdc);
            }
        },
        _ => {
            // 未サポートコマンド
            fdc.st0 |= 0x80; // Invalid command
        },
    }
}

// px68k FDC_NextTrack。セクタ途中では割り込まず、EOT（と MT の反対面）まで読み切ってから 1 回だけ終了する。
fn fdc_next_track(fdc: X68kFDC&) {
    let r = fdc.prm_buf[4];
    let eot = fdc.prm_buf[6];
    if r == eot {
        let us = fdc.prm_buf[1];
        let mt = (us & 0x80) != 0;
        let hd = (us & 0x04) != 0;
        let h = fdc.prm_buf[3];
        if mt && !hd && h == 0 {
            fdc.prm_buf[1] = (us | 4);
            fdc.prm_buf[3] = 1;
            fdc.prm_buf[4] = 1;
        } else {
            fdc_ephase_end(fdc);
            return;
        }
    } else {
        fdc.prm_buf[4] = (r + 1);
    }
    fdc_exec_cmd(fdc);
}

// FDC レジスタ読み込み (0x00E94001 .. 0x00E94007)
fn fdc_read(fdc: X68kFDC&, reg: i32) -> u8 {
    if reg == 1 { // 0x00E94001: Main Status Register (MSR)
        // bit7 RQM (常に受け付け可)、bit6 DIO (1 = FDC → CPU)、bit4 CB (コマンド処理中)
        match fdc.phase {
            Idle => { return 0x80; },
            Command c => { return 0x90; },
            Exec e => {
                // 結果のあるコマンドだけが実行相に入る。読み出し中は DIO も立つ。
                if fdc_cmd_rsp_len(fdc.cmd) == 0 { return 0x80; }
                return if e.writing { 0x90 } else { 0xD0 };
            },
            Result r => {
                // SenseIntStatus の最後の 1 バイトでは DIO と CB を落とす (px68k)。
                if r.left == 1 && fdc.cmd == FDC_SENSE_INT { return 0x80; }
                return 0xD0;
            },
        }
    } else if reg == 3 { // 0x00E94003: Data Register (FIFO)
        match fdc.phase {
            Exec e => {
                let ret = fdc.data_buf[fdc.read_pos];
                fdc.read_pos++;
                if fdc.read_pos >= e.len {
                    fdc.read_pos = 0;
                    fdc_next_track(fdc);
                }
                return ret;
            },
            Result r => {
                let ret = fdc.rsp_buf[fdc.read_pos];
                fdc.read_pos++;
                fdc.phase = if r.left > 1 { FdcPhase.Result { left: r.left - 1 } } else { FdcPhase.Idle };
                return ret;
            },
            Idle => { return 0; },
            Command c => { return 0; },
        }
    } else if reg == 5 { // 0x00E94005: Control / Status
        var ret: u8 = 0;
        if (fdc.ctrl & 1) != 0 && c_fdd_is_loaded(0) {
            ret |= 0x80; // Drive 0 ready
        }
        if (fdc.ctrl & 2) != 0 && c_fdd_is_loaded(1) {
            ret |= 0x80; // Drive 1 ready
        }
        return ret;
    }
    return 0;
}

// デバッガ用。データレジスタの次のバイトを、読み位置を進めずに返す。
fn fdc_peek(fdc: X68kFDC&, reg: i32) -> u8 {
    if reg != 3 { return fdc_read(fdc, reg); }
    match fdc.phase {
        Exec e => fdc.data_buf[fdc.read_pos],
        Result r => fdc.rsp_buf[fdc.read_pos],
        Idle => 0,
        Command c => 0,
    }
}

// data_buf に 1 セクタ分そろったら書き込む。last は DMAC の転送カウンタが尽きたとき (TC)。
// TC なら EOT を待たずに結果相へ進む。CPU が 1 バイトずつ書く経路は last = false。
fn fdc_write_buffer(fdc: X68kFDC&, last: bool) {
    if fdc.cmd == FDC_WRITE_DATA || fdc.cmd == FDC_WRITE_DELETED {
        let hd = (fdc.prm_buf[1] >> 2) & 1;
        let trk = fdc.cyl * 2 + hd;
        let c: i32 = fdc.prm_buf[2];
        let h: i32 = fdc.prm_buf[3];
        let r: i32 = fdc.prm_buf[4];
        let n: i32 = fdc.prm_buf[5];
        let ok = c_fdd_write_fdc(fdc.drv, trk, c, h, r, n, fdc.data_buf[0]);
        if ok == 0 {
            fdc.st0 |= 0x40;
            fdc.st1 |= 0x04;
            fdc_ephase_end(fdc);
        } else if last {
            fdc_ephase_end(fdc);
        } else {
            fdc_next_track(fdc);
        }
    } else {
        fdc_ephase_end(fdc);
    }
}

// FDC レジスタ書き込み (0x00E94001 .. 0x00E94007)
// パラメータがそろったコマンドを実行する。実行相に入らなければ、結果相かコマンド待ちになる。
fn fdc_run_command(fdc: X68kFDC&) {
    fdc.write_pos = 0;
    fdc.st1 = 0;
    fdc.st2 = 0;
    fdc.phase = fdc_done_phase(fdc);
    fdc_exec_cmd(fdc);
}

fn fdc_write(fdc: X68kFDC&, reg: i32, val: u8) {
    if reg == 3 { // 0x00E94003: Data Register (FIFO)
        match fdc.phase {
            Exec e => {
                fdc.data_buf[fdc.write_pos] = val;
                fdc.write_pos++;
                if fdc.write_pos >= e.len {
                    fdc_write_buffer(fdc, false);
                    fdc.write_pos = 0;
                }
            },
            Command c => {
                fdc.prm_buf[fdc.write_pos] = val;
                fdc.write_pos++;
                if c.left > 1 {
                    fdc.phase = FdcPhase.Command { left: c.left - 1 };
                } else {
                    fdc_run_command(fdc);
                }
            },
            // コマンド待ち。結果を読み残していても、次のコマンドを受け付ける。
            Idle, Result => {
                fdc.cmd = (val & 0x1F);
                fdc.read_pos = 0;
                fdc.prm_buf[0] = val;
                fdc.write_pos = 1;
                let n = fdc_cmd_prm_len(fdc.cmd);
                if n > 0 {
                    fdc.phase = FdcPhase.Command { left: n };
                } else {
                    fdc_run_command(fdc);
                }
            },
        }
    } else if reg == 5 { // 0x00E94005: Control
        fdc.ctrl = val;
    } else if reg == 7 { // 0x00E94007: Drive Select
        if (val & 0x80) != 0 {
            fdc.drv = (val & 3);
        } else {
            fdc.drv = -1;
        }
    }
}
