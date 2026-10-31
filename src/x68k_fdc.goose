// Sharp X68000 フロッピーディスクコントローラ (uPD72065 / FDC) in Goose
// ※実機 ROM / ディスクコード自走用

import std;
import .x68k_bridge;
import .m68k_types;

// コマンド毎のパラメータ長 (CMD_TABLE[32])
fn fdc_cmd_prm_len(cmd: i32) -> i32 {
    if cmd == 2 { return 8; }  // ReadDiagnostic
    if cmd == 3 { return 2; }  // Specify
    if cmd == 4 { return 1; }  // SenseDeviceStatus
    if cmd == 5 { return 8; }  // WriteData
    if cmd == 6 { return 8; }  // ReadData
    if cmd == 7 { return 1; }  // Recalibrate
    if cmd == 8 { return 0; }  // SenseIntStatus
    if cmd == 9 { return 8; }  // WriteDeletedData
    if cmd == 10 { return 1; } // ReadID
    if cmd == 12 { return 8; } // ReadDeletedData
    if cmd == 13 { return 5; } // WriteID
    if cmd == 15 { return 2; } // Seek
    if cmd == 17 { return 8; } // ScanEqual
    if cmd == 25 { return 8; } // ScanLowOrEqual
    if cmd == 29 { return 8; } // ScanHighOrEqual
    return 0;
}

// コマンド毎のレスポンス長 (DAT_TABLE[32])
fn fdc_cmd_rsp_len(cmd: i32) -> i32 {
    if cmd == 2 { return 7; }  // ReadDiagnostic
    if cmd == 3 { return 0; }  // Specify
    if cmd == 4 { return 1; }  // SenseDeviceStatus
    if cmd == 5 { return 7; }  // WriteData
    if cmd == 6 { return 7; }  // ReadData
    if cmd == 7 { return 0; }  // Recalibrate
    if cmd == 8 { return 2; }  // SenseIntStatus
    if cmd == 9 { return 7; }  // WriteDeletedData
    if cmd == 10 { return 7; } // ReadID
    if cmd == 12 { return 7; } // ReadDeletedData
    if cmd == 13 { return 7; } // WriteID
    if cmd == 15 { return 0; } // Seek
    if cmd == 17 { return 7; } // ScanEqual
    if cmd == 25 { return 7; } // ScanLowOrEqual
    if cmd == 29 { return 7; } // ScanHighOrEqual
    return 0;
}

struct X68kFDC {
    cmd: i32 = 0,
    cyl: i32 = 0,
    drv: i32 = 0,
    ready: i32 = 0,
    ctrl: u8 = 0,
    wexec: i32 = 0,
    rdptr: i32 = 0,
    wrptr: i32 = 0,
    rdnum: i32 = 0,
    wrnum: i32 = 0,
    bufnum: i32 = 0,
    st0: u8 = 0,
    st1: u8 = 0,
    st2: u8 = 0,
    rsp_buf: u8[16] = [0; 16],
    prm_buf: u8[16] = [0; 16],
    data_buf: u8[8192] = [0; 8192],
    int_pending: bool = false
}

fn fdc_init(fdc: X68kFDC&) {
    fdc.cmd = 0;
    fdc.cyl = 0;
    fdc.drv = 0;
    fdc.ready = 0;
    fdc.ctrl = 0;
    fdc.wexec = 0;
    fdc.rdptr = 0;
    fdc.wrptr = 0;
    fdc.rdnum = 0;
    fdc.wrnum = 0;
    fdc.bufnum = 0;
    fdc.st0 = 0;
    fdc.st1 = 0;
    fdc.st2 = 0;
    fdc.int_pending = false;

    for i in 16 {
        fdc.rsp_buf[i] = 0;
        fdc.prm_buf[i] = 0;
    }
    for i in 8192 {
        fdc.data_buf[i] = 0;
    }
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

    fdc.bufnum = 0;
    fdc.rdptr = 0;
    fdc.wexec = 0;
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

    if cmd == 3 { // Specify
        // 何もしない
    } else if cmd == 4 { // SenseDeviceStatus
        let us = (fdc.prm_buf[1] & 7) as u8;
        fdc.st0 = us;
        var st3: u8 = us;
        if fdc.cyl == 0 { st3 |= 0x10; } // Track 0
        if c_fdd_is_loaded(fdc.drv) { st3 |= 0x20; } // Ready
        fdc.rsp_buf[0] = st3;
    } else if cmd == 7 { // Recalibrate
        fdc.st0 = (fdc.prm_buf[1] & 7) as u8;
        fdc.cyl = 0;
        if !c_fdd_is_loaded(fdc.drv) {
            fdc.st0 |= 0x48; // no FD
        } else if fdc.drv >= 0 && fdc.drv < 2 {
            fdc.st0 |= 0x20; // with FD and drive
        } else {
            fdc.st0 |= 0x50; // no drive
        }
        fdc.int_pending = true;
    } else if cmd == 8 { // SenseIntStatus
        fdc.rsp_buf[0] = fdc.st0;
        fdc.rsp_buf[1] = fdc.cyl as u8;
        fdc.st0 = 0x80;
    } else if cmd == 15 { // Seek
        fdc.st0 = (fdc.prm_buf[1] & 7) as u8;
        if c_fdd_is_loaded(fdc.drv) {
            fdc.cyl = fdc.prm_buf[2] as i32;
            fdc.st0 |= 0x20;
        } else {
            fdc.st0 |= 0x48;
        }
        fdc.int_pending = true;
    } else if cmd == 10 { // ReadID
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
    } else if cmd == 5 || cmd == 9 { // WriteData / WriteDeletedData
        fdc.st0 = (fdc.prm_buf[1] & 7) as u8;
        fdc.wexec = 0;
        if c_fdd_is_loaded(fdc.drv) {
            let hd = (fdc.prm_buf[1] >> 2) & 1;
            let trk = fdc.cyl * 2 + hd;
            let n = fdc.prm_buf[5] as i32;
            if c_fdd_seek(fdc.drv, trk) == 0 {
                fdc.st0 |= 0x40;
                fdc.st1 |= 0x04;
                fdc_ephase_end(fdc);
            } else {
                let sec_size = if n > 0 { (128 << n) as i32 } else { 1024 };
                fdc.bufnum = sec_size;
                fdc.wrptr = 0;
                fdc.wexec = 1;
            }
        } else {
            fdc.st0 |= 0x48;
            fdc_ephase_end(fdc);
        }
    } else if cmd == 6 || cmd == 12 { // ReadData / ReadDeletedData
        fdc.st0 = (fdc.prm_buf[1] & 7) as u8;
        fdc.wexec = 0;
        if c_fdd_is_loaded(fdc.drv) {
            let hd = (fdc.prm_buf[1] >> 2) & 1;
            let trk = fdc.cyl * 2 + hd;
            let c = fdc.prm_buf[2] as i32;
            let h = fdc.prm_buf[3] as i32;
            let r = fdc.prm_buf[4] as i32;
            let n = fdc.prm_buf[5] as i32;

            let sec_size = if n > 0 { (128 << n) as i32 } else { 1024 };

            let ok = c_fdd_read_fdc(fdc.drv, trk, c, h, r, n, fdc.data_buf[0]);
            // print("[FDC ReadData trk=", trk, " sec=", r, " ok=", ok, " buf[0]=", fdc.data_buf[0] as u32, "]");
            if ok != 0 {
                fdc.bufnum = sec_size;
                fdc.rdptr = 0;
                fdc.st0 |= 0x00; // Success
            } else {
                fdc.st0 |= 0x40; // Abnormal termination
                fdc.st1 |= 0x04; // No data
                fdc_ephase_end(fdc);
            }
        } else {
            fdc.st0 |= 0x48;
            fdc_ephase_end(fdc);
        }
    } else {
        // 未サポートコマンド
        fdc.st0 |= 0x80; // Invalid command
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
            fdc.prm_buf[1] = (us | 4) as u8;
            fdc.prm_buf[3] = 1;
            fdc.prm_buf[4] = 1;
        } else {
            fdc_ephase_end(fdc);
            return;
        }
    } else {
        fdc.prm_buf[4] = (r + 1) as u8;
    }
    fdc_exec_cmd(fdc);
}

// FDC レジスタ読み込み (0x00E94001 .. 0x00E94007)
fn fdc_read(fdc: X68kFDC&, reg: i32) -> u8 {
    if reg == 1 { // 0x00E94001: Main Status Register (MSR)
        var msr: u8 = 0x80; // RQM: Always Request for Master (Ready)
        if fdc.rdnum > 0 && fdc.wexec == 0 {
            msr |= 0x40; // DIO: 1 = FDC -> CPU (Data from FDC)
        }
        if fdc.wrnum > 0 || fdc.rdnum > 0 {
            msr |= 0x10; // CB: FDC Busy
        }
        if fdc.rdnum == 1 && fdc.cmd == 8 {
            msr &= 0xAF;
        }
        return msr;
    } else if reg == 3 { // 0x00E94003: Data Register (FIFO)
        if fdc.bufnum > 0 {
            let ret = fdc.data_buf[fdc.rdptr];
            fdc.rdptr++;
            if fdc.rdptr >= fdc.bufnum {
                fdc.rdptr = 0;
                fdc_next_track(fdc);
            }
            return ret;
        } else if fdc.rdnum > 0 {
            let ret = fdc.rsp_buf[fdc.rdptr];
            fdc.rdptr++;
            fdc.rdnum--;
            return ret;
        }
        return 0;
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

fn fdc_write_buffer(fdc: X68kFDC&) {
    if fdc.cmd == 5 || fdc.cmd == 9 {
        let hd = (fdc.prm_buf[1] >> 2) & 1;
        let trk = fdc.cyl * 2 + hd;
        let c = fdc.prm_buf[2] as i32;
        let h = fdc.prm_buf[3] as i32;
        let r = fdc.prm_buf[4] as i32;
        let n = fdc.prm_buf[5] as i32;
        let ok = c_fdd_write_fdc(fdc.drv, trk, c, h, r, n, fdc.data_buf[0]);
        if ok == 0 {
            fdc.st0 |= 0x40;
            fdc.st1 |= 0x04;
            fdc_ephase_end(fdc);
        } else {
            fdc_next_track(fdc);
        }
    } else {
        fdc_ephase_end(fdc);
    }
}

// FDC レジスタ書き込み (0x00E94001 .. 0x00E94007)
fn fdc_write(fdc: X68kFDC&, reg: i32, val: u8) {
    if reg == 3 || reg == 5 || reg == 7 {
        // print("[FDC WRITE reg ", reg, " val 0x", val as u32, "]");
    }
    if reg == 3 { // 0x00E94003: Data Register (FIFO)
        if fdc.bufnum > 0 {
            fdc.data_buf[fdc.wrptr] = val;
            fdc.wrptr++;
            if fdc.wrptr >= fdc.bufnum {
                fdc_write_buffer(fdc);
                fdc.wrptr = 0;
            }
        } else {
            if fdc.wrnum > 0 {
                // Writing parameters
                fdc.prm_buf[fdc.wrptr] = val;
                fdc.wrptr++;
                fdc.wrnum--;
            } else {
                // Command byte
                fdc.cmd = (val & 0x1F) as i32;
                fdc.rdptr = 0;
                fdc.wrptr = 0;
                fdc.rdnum = 0;
                fdc.wrnum = fdc_cmd_prm_len(fdc.cmd);
                fdc.prm_buf[fdc.wrptr] = val;
                fdc.wrptr++;
            }
            if fdc.wrnum == 0 {
                fdc.wrptr = 0;
                fdc.rdnum = fdc_cmd_rsp_len(fdc.cmd);
                fdc.st1 = 0;
                fdc.st2 = 0;
                fdc_exec_cmd(fdc);
            }
        }
    } else if reg == 5 { // 0x00E94005: Control
        fdc.ctrl = val;
    } else if reg == 7 { // 0x00E94007: Drive Select
        if (val & 0x80) != 0 {
            fdc.drv = (val & 3) as i32;
        } else {
            fdc.drv = -1;
        }
    }
}

// DMAC 連動用データ準備フラグ
fn fdc_is_data_ready(fdc: X68kFDC&) -> bool {
    return fdc.bufnum > 0;
}
