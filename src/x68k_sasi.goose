// SASI (0xE96000)。相とコマンドのバイトはここに置く。
// セクタの中身は x68k_disk にある (hdd_read / hdd_write)。

import .x68k_bridge;
import .x68k_disk;
namespace sasi;

// タグはこの中だけのもので、並びは実機のバスのステータスの符号とは違う。
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
    status_edge: bool = false,
}
type ::X68kSASI = sasi::X68kSASI;

fn reset(sasi: X68kSASI&) {
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
    sasi.status_edge = false;
}

fn clear_buf(sasi: X68kSASI&) {
    for i in 256 {
        sasi.buf[i] = 0;
    }
}

fn pull_host_reset(sasi: X68kSASI&) {
    if disk::take_sasi_reset() {
        sasi.reset();
    }
}

fn image_present() -> bool {
    return disk::hdd_unit_ok();
}

fn unit_present(sasi: X68kSASI&) -> bool {
    return sasi.device == 0 && sasi.unit == 0 && image_present();
}

fn seek(sasi: X68kSASI&) -> i32 {
    if !sasi.unit_present() {
        sasi.clear_buf();
        return -1;
    }
    return disk::hdd_read(sasi.sector, sasi.buf);
}

fn flush(sasi: X68kSASI&) -> i32 {
    if !sasi.unit_present() {
        return -1;
    }
    return disk::hdd_write(sasi.sector, sasi.buf);
}

fn dec_blocks(sasi: X68kSASI&) {
    if sasi.blocks == 0 {
        sasi.blocks = 0xFFFFFFFF;
    } else {
        sasi.blocks -= 1;
    }
}

fn after_block(sasi: X68kSASI&) {
    sasi.dec_blocks();
    if sasi.blocks != 0 {
        sasi.sector += 1;
        sasi.buf_ptr = 0;
        let result = sasi.seek();
        if result == 0 {
            sasi.error = 0x0f;
            sasi.phase = SasiPhase.Status;
        }
    } else {
        sasi.phase = SasiPhase.Status;
    }
}

fn check_cmd(sasi: X68kSASI&) {
    sasi.unit = ((sasi.cmd[1] >> 5) & 1);
    let op = sasi.cmd[0];
    if op == 0x00 || op == 0x0b {
        if sasi.unit_present() {
            sasi.stat = 0;
        } else {
            sasi.stat = 0x02;
            sasi.error = 0x7f;
        }
        sasi.phase = SasiPhase.Status;
    } else if op == 0x01 {
        if sasi.unit_present() {
            sasi.sector = 0;
            sasi.stat = 0;
        } else {
            sasi.stat = 0x02;
            sasi.error = 0x7f;
        }
        sasi.phase = SasiPhase.Status;
    } else if op == 0x03 {
        sasi.sense[0] = sasi.error;
        let hi = ((sasi.sector >> 16) & 0x1f) as u8;
        sasi.sense[1] = ((sasi.unit << 5) | hi);
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
        let b1: u32 = sasi.cmd[1];
        let b2: u32 = sasi.cmd[2];
        let b3: u32 = sasi.cmd[3];
        sasi.sector = ((b1 & 0x1f) << 16) | (b2 << 8) | b3;
        sasi.blocks = sasi.cmd[4];
        sasi.phase = SasiPhase.Data;
        sasi.direction = SasiDirection.DiskToHost;
        sasi.buf_ptr = 0;
        sasi.stat = 0;
        let result = sasi.seek();
        if result == 0 || result == -1 {
            sasi.error = 0x0f;
        }
    } else if op == 0x0a {
        let b1: u32 = sasi.cmd[1];
        let b2: u32 = sasi.cmd[2];
        let b3: u32 = sasi.cmd[3];
        sasi.sector = ((b1 & 0x1f) << 16) | (b2 << 8) | b3;
        sasi.blocks = sasi.cmd[4];
        sasi.phase = SasiPhase.Data;
        sasi.direction = SasiDirection.HostToDisk;
        sasi.buf_ptr = 0;
        sasi.stat = 0;
        sasi.clear_buf();
        let result = sasi.seek();
        if result == 0 || result == -1 {
            sasi.error = 0x0f;
        }
    } else if op == 0xc2 {
        sasi.phase = SasiPhase.Specify;
        sasi.sense_ptr = 0;
        if sasi.unit_present() {
            sasi.stat = 0;
        } else {
            sasi.stat = 0x02;
            sasi.error = 0x7f;
        }
    } else {
        sasi.phase = SasiPhase.Status;
    }
}

fn bus_status(sasi: X68kSASI&) -> u8 {
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

fn is_ready(sasi: X68kSASI&) -> bool {
    sasi.pull_host_reset();
    match sasi.phase {
        Data, Sense => true,
        BusFree, Selected, Command, Status, Message, Specify => false,
    }
}

fn consume_status_edge(sasi: X68kSASI&) -> bool {
    let e = sasi.status_edge;
    sasi.status_edge = false;
    return e;
}

fn note_status(sasi: X68kSASI&) {
    if sasi.phase == SasiPhase.Status { sasi.status_edge = true; }
}

// デバッガ用。フェーズもバッファ位置も進めずに、次に読めるはずの値を返す。
fn peek(sasi: X68kSASI&, adr: u32) -> u8 {
    if adr == 0xE96003 { return sasi.bus_status(); }
    if adr != 0xE96001 { return 0; }
    match sasi.phase {
        Data => if sasi.direction == SasiDirection.DiskToHost { sasi.buf[sasi.buf_ptr] } else { 0 },
        Status => if sasi.error != 0 { 0x02 } else { sasi.stat },
        Sense => sasi.sense[sasi.sense_ptr],
        BusFree, Selected, Command, Message, Specify => 0,
    }
}

fn read(sasi: X68kSASI&, adr: u32) -> u8 {
    sasi.pull_host_reset();
    var ret: u8 = 0;
    if adr == 0xE96003 {
        ret = sasi.bus_status();
    } else if adr == 0xE96001 {
        match sasi.phase {
            Data => {
                if sasi.direction == SasiDirection.DiskToHost {
                    ret = sasi.buf[sasi.buf_ptr];
                    sasi.buf_ptr += 1;
                    if sasi.buf_ptr == 256 { sasi.after_block(); }
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
        sasi.note_status();
    }
    return ret;
}

fn write(sasi: X68kSASI&, adr: u32, data: u8) {
    sasi.pull_host_reset();
    if adr == 0xE96007 && sasi.phase == SasiPhase.BusFree {
        sasi.device = 0x7f;
        if data != 0 {
            var bit: u8 = 1;
            var i: i32 = 0;
            while bit != 0 {
                if (data & bit) != 0 { sasi.device = i as! u16; break; }
                i += 1;
                bit = (bit << 1);
            }
        }
        if sasi.device == 0 && image_present() {
            sasi.phase = SasiPhase.Selected;
            sasi.cmd_ptr = 0;
        } else { sasi.phase = SasiPhase.BusFree; }
    } else if adr == 0xE96003 && sasi.phase == SasiPhase.Selected {
        sasi.phase = SasiPhase.Command;
    } else if adr == 0xE96005 {
        sasi.reset();
    } else if adr == 0xE96001 {
        match sasi.phase {
            Command => {
                sasi.cmd[sasi.cmd_ptr] = data;
                sasi.cmd_ptr += 1;
                if sasi.cmd_ptr == 6 { sasi.check_cmd(); }
            },
            Data => {
                if sasi.direction == SasiDirection.HostToDisk {
                    sasi.buf[sasi.buf_ptr] = data;
                    sasi.buf_ptr += 1;
                    if sasi.buf_ptr == 256 { sasi.flush(); sasi.after_block(); }
                }
            },
            Specify => {
                sasi.sense_ptr += 1;
                if sasi.sense_ptr == 10 { sasi.phase = SasiPhase.Status; }
            },
            BusFree, Selected, Status, Message, Sense => {},
        }
        sasi.note_status();
    }
}
