// SASI (0xE96000). Phase and command bytes live here.
// Sector bytes stay in c_hdd_read_sector / c_hdd_write_sector.

import std;
import .x68k_bridge;

// Tags are internal; their order is not the hardware bus status encoding.
enum SasiPhase { BusFree, Selected, Command, Data, Status, Message, Sense, Specify }
enum SasiDirection { HostToDisk, DiskToHost }

struct X68kSASI {
    buf: u8[256] = [0; 256],
    phase: SasiPhase = SasiPhase.BusFree,
    sector: u32 = 0,
    blocks: u32 = 0,
    cmd: u8[6] = [0; 6],
    cmd_ptr: i32 = 0,
    device: u16 = 0,
    unit: u8 = 0,
    buf_ptr: i32 = 0,
    direction: SasiDirection = SasiDirection.HostToDisk,
    stat: u8 = 0,
    error: u8 = 0,
    sense: u8[4] = [0; 4],
    sense_ptr: i32 = 0,
    status_edge: i32 = 0
}

fn sasi_reset(sasi: X68kSASI&) {
    sasi.phase = SasiPhase.BusFree;
    sasi.sector = 0;
    sasi.blocks = 0;
    sasi.cmd_ptr = 0;
    sasi.device = 0;
    sasi.unit = 0;
    sasi.buf_ptr = 0;
    sasi.direction = SasiDirection.HostToDisk;
    sasi.stat = 0;
    sasi.error = 0;
    sasi.sense_ptr = 0;
    sasi.status_edge = 0;
}

fn sasi_clear_buf(sasi: X68kSASI&) {
    for i in 256 {
        sasi.buf[i] = 0;
    }
}

fn sasi_pull_host_reset(sasi: X68kSASI&) {
    if c_hdd_take_sasi_reset() != 0 {
        sasi_reset(sasi);
    }
}

fn sasi_image_present() -> bool {
    return c_hdd_unit_ok() != 0;
}

fn sasi_unit_present(sasi: X68kSASI&) -> bool {
    return sasi.device == 0 && sasi.unit == 0 && sasi_image_present();
}

fn sasi_seek(sasi: X68kSASI&) -> i32 {
    if !sasi_unit_present(sasi) {
        sasi_clear_buf(sasi);
        return -1;
    }
    return c_hdd_read_sector(sasi.sector, sasi.buf[0]);
}

fn sasi_flush(sasi: X68kSASI&) -> i32 {
    if !sasi_unit_present(sasi) {
        return -1;
    }
    return c_hdd_write_sector(sasi.sector, sasi.buf[0]);
}

fn sasi_dec_blocks(sasi: X68kSASI&) {
    if sasi.blocks == 0 {
        sasi.blocks = 0xFFFFFFFF;
    } else {
        sasi.blocks -= 1;
    }
}

fn sasi_after_block(sasi: X68kSASI&) {
    sasi_dec_blocks(sasi);
    if sasi.blocks != 0 {
        sasi.sector += 1;
        sasi.buf_ptr = 0;
        let result = sasi_seek(sasi);
        if result == 0 {
            sasi.error = 0x0f;
            sasi.phase = SasiPhase.Status;
        }
    } else {
        sasi.phase = SasiPhase.Status;
    }
}

fn sasi_check_cmd(sasi: X68kSASI&) {
    sasi.unit = ((sasi.cmd[1] >> 5) & 1) as! u8;
    let op = sasi.cmd[0];
    if op == 0x00 || op == 0x0b {
        if sasi_unit_present(sasi) {
            sasi.stat = 0;
        } else {
            sasi.stat = 0x02;
            sasi.error = 0x7f;
        }
        sasi.phase = SasiPhase.Status;
    } else if op == 0x01 {
        if sasi_unit_present(sasi) {
            sasi.sector = 0;
            sasi.stat = 0;
        } else {
            sasi.stat = 0x02;
            sasi.error = 0x7f;
        }
        sasi.phase = SasiPhase.Status;
    } else if op == 0x03 {
        sasi.sense[0] = sasi.error;
        let hi = ((sasi.sector >> 16) & 0x1f) as! u8;
        sasi.sense[1] = ((sasi.unit << 5) | hi) as! u8;
        sasi.sense[2] = (sasi.sector >> 8) as! u8;
        sasi.sense[3] = sasi.sector as! u8;
        sasi.error = 0;
        sasi.phase = SasiPhase.Sense;
        sasi.stat = 0;
        sasi.sense_ptr = 0;
    } else if op == 0x04 {
        sasi.phase = SasiPhase.Status;
        sasi.stat = 0;
    } else if op == 0x08 {
        let b1 = sasi.cmd[1] as u32;
        let b2 = sasi.cmd[2] as u32;
        let b3 = sasi.cmd[3] as u32;
        sasi.sector = ((b1 & 0x1f) << 16) | (b2 << 8) | b3;
        sasi.blocks = sasi.cmd[4] as u32;
        sasi.phase = SasiPhase.Data;
        sasi.direction = SasiDirection.DiskToHost;
        sasi.buf_ptr = 0;
        sasi.stat = 0;
        let result = sasi_seek(sasi);
        if result == 0 || result == -1 {
            sasi.error = 0x0f;
        }
    } else if op == 0x0a {
        let b1 = sasi.cmd[1] as u32;
        let b2 = sasi.cmd[2] as u32;
        let b3 = sasi.cmd[3] as u32;
        sasi.sector = ((b1 & 0x1f) << 16) | (b2 << 8) | b3;
        sasi.blocks = sasi.cmd[4] as u32;
        sasi.phase = SasiPhase.Data;
        sasi.direction = SasiDirection.HostToDisk;
        sasi.buf_ptr = 0;
        sasi.stat = 0;
        sasi_clear_buf(sasi);
        let result = sasi_seek(sasi);
        if result == 0 || result == -1 {
            sasi.error = 0x0f;
        }
    } else if op == 0xc2 {
        sasi.phase = SasiPhase.Specify;
        sasi.sense_ptr = 0;
        if sasi_unit_present(sasi) {
            sasi.stat = 0;
        } else {
            sasi.stat = 0x02;
            sasi.error = 0x7f;
        }
    } else {
        sasi.phase = SasiPhase.Status;
    }
}

// Legacy phase numbers are for diagnostics/tests only. Never cast enum tags.
fn sasi_phase_code(phase: SasiPhase) -> u8 {
    match phase {
        BusFree => 0, Selected => 1, Command => 2, Data => 3,
        Status => 4, Message => 5, Sense => 9, Specify => 10,
    }
}

fn sasi_bus_status(sasi: X68kSASI&) -> u8 {
    match sasi.phase {
        BusFree => 0,
        Selected => 2,
        Command => 0x0B,
        Data => if sasi.direction == SasiDirection.DiskToHost { 7 } else { 3 },
        Status => 0x0F,
        Message => 0x1F,
        Sense => 7,
        Specify => 3,
    }
}

fn sasi_is_ready(sasi: X68kSASI&) -> i32 {
    sasi_pull_host_reset(sasi);
    match sasi.phase {
        Data, Sense => 1,
        BusFree, Selected, Command, Status, Message, Specify => 0,
    }
}

fn sasi_consume_status_edge(sasi: X68kSASI&) -> i32 {
    let e = sasi.status_edge;
    sasi.status_edge = 0;
    return e;
}

fn sasi_note_status(sasi: X68kSASI&) {
    if sasi.phase == SasiPhase.Status { sasi.status_edge = 1; }
}

fn sasi_read(sasi: X68kSASI&, adr: u32) -> u8 {
    sasi_pull_host_reset(sasi);
    var ret: u8 = 0;
    if adr == 0xE96003 {
        ret = sasi_bus_status(sasi);
    } else if adr == 0xE96001 {
        match sasi.phase {
            Data => {
                if sasi.direction == SasiDirection.DiskToHost {
                    ret = sasi.buf[sasi.buf_ptr];
                    sasi.buf_ptr += 1;
                    if sasi.buf_ptr == 256 { sasi_after_block(sasi); }
                }
            },
            Status => {
                ret = if sasi.error != 0 { 0x02 } else { sasi.stat };
                sasi.phase = SasiPhase.Message;
            },
            Message => { sasi.phase = SasiPhase.BusFree; },
            Sense => {
                ret = sasi.sense[sasi.sense_ptr];
                sasi.sense_ptr += 1;
                if sasi.sense_ptr == 4 { sasi.error = 0; sasi.phase = SasiPhase.Status; }
            },
            BusFree, Selected, Command, Specify => {},
        }
        sasi_note_status(sasi);
    }
    return ret;
}

fn sasi_write(sasi: X68kSASI&, adr: u32, data: u8) {
    sasi_pull_host_reset(sasi);
    if adr == 0xE96007 && sasi.phase == SasiPhase.BusFree {
        sasi.device = 0x7f;
        if data != 0 {
            var bit: u8 = 1;
            var i: i32 = 0;
            while bit != 0 {
                if (data & bit) != 0 { sasi.device = i as! u16; break; }
                i += 1;
                bit = (bit << 1) as! u8;
            }
        }
        if sasi.device == 0 && sasi_image_present() {
            sasi.phase = SasiPhase.Selected;
            sasi.cmd_ptr = 0;
        } else { sasi.phase = SasiPhase.BusFree; }
    } else if adr == 0xE96003 && sasi.phase == SasiPhase.Selected {
        sasi.phase = SasiPhase.Command;
    } else if adr == 0xE96005 {
        sasi_reset(sasi);
    } else if adr == 0xE96001 {
        match sasi.phase {
            Command => {
                sasi.cmd[sasi.cmd_ptr] = data;
                sasi.cmd_ptr += 1;
                if sasi.cmd_ptr == 6 { sasi_check_cmd(sasi); }
            },
            Data => {
                if sasi.direction == SasiDirection.HostToDisk {
                    sasi.buf[sasi.buf_ptr] = data;
                    sasi.buf_ptr += 1;
                    if sasi.buf_ptr == 256 { sasi_flush(sasi); sasi_after_block(sasi); }
                }
            },
            Specify => {
                sasi.sense_ptr += 1;
                if sasi.sense_ptr == 10 { sasi.phase = SasiPhase.Status; }
            },
            BusFree, Selected, Status, Message, Sense => {},
        }
        sasi_note_status(sasi);
    }
}
