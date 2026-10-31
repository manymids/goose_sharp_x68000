// Machine checkpoints. No JSON, frontend names, host handles or borrowed
// references are stored here. Native banks own sound/media/RAM snapshots.
import std;
import .x68k_bridge;
import .x68k_emu;
import .m68k_cpu;
import .m68k_mmu;
import .x68k_rom;
import .x68k_input;

let STATE_SLOT = 0;
let STATE_SNAPSHOT = 1;
let STATE_REWIND = 2;
// v2: SASI phase/direction are typed tags; v1 numeric records are incompatible.
let STATE_VERSION = 2;

struct X68kCheckpoint {
    saved: bool = false,
    version: i32 = 0,
    native_generation: u64 = 0,
    cpu: M68kCPU = M68kCPU {},
    mmu: M68kMMU = M68kMMU {},
    total_frames: i64 = 0,
    total_cycles: i64 = 0,
    clk_used: i32 = 0,
    sram_we: i32 = 0,
    clock_mhz: i32 = 10
}

var g_checkpoints: X68kCheckpoint[50] = [X68kCheckpoint {}; 50];

fn state_capacity(bank: i32) -> i32 {
    if bank == STATE_SLOT { return 10; }
    if bank == STATE_SNAPSHOT { return 32; }
    if bank == STATE_REWIND { return 8; }
    return 0;
}

fn state_index(bank: i32, idx: i32) -> i32 {
    if idx < 0 || idx >= state_capacity(bank) { return -1; }
    if bank == STATE_SLOT { return idx; }
    if bank == STATE_SNAPSHOT { return 10 + idx; }
    return 42 + idx;
}

fn state_saved(bank: i32, idx: i32) -> bool {
    let at = state_index(bank, idx);
    if at < 0 { return false; }
    let slot .= g_checkpoints[at];
    return slot.saved && slot.version == STATE_VERSION
        && slot.native_generation != 0
        && slot.native_generation == c_state_generation(bank, idx);
}

fn state_validate(bank: i32, idx: i32) -> bool {
    return state_saved(bank, idx) && c_state_validate(bank, idx) != 0;
}

fn state_capture(emu: X68kEmulator&, bank: i32, idx: i32) -> bool {
    if !x68k_emu_active(emu) { return false; }
    let at = state_index(bank, idx);
    if at < 0 { return false; }
    // The native transaction preserves the old generation on any failure.
    if c_state_capture(bank, idx) == 0 { return false; }
    let slot .= g_checkpoints[at];
    slot.cpu = emu.cpu;
    slot.mmu = emu.mmu;
    slot.total_frames = emu.total_frames;
    slot.total_cycles = emu.total_cycles;
    slot.clk_used = emu.clk_used;
    slot.sram_we = x68k_sram_write_enable();
    slot.clock_mhz = c_get_cpu_mhz();
    slot.native_generation = c_state_generation(bank, idx);
    slot.version = STATE_VERSION;
    slot.saved = true;
    return true;
}

fn state_restore(emu: X68kEmulator&, bank: i32, idx: i32) -> bool {
    if !x68k_emu_active(emu) { return false; }
    if !state_validate(bank, idx) { return false; }
    if c_state_restore(bank, idx) == 0 { return false; }
    let slot .= g_checkpoints[state_index(bank, idx)];
    emu.cpu = slot.cpu;
    emu.mmu = slot.mmu;
    emu.total_frames = slot.total_frames;
    emu.total_cycles = slot.total_cycles;
    emu.clk_used = slot.clk_used;
    x68k_sram_set_write_enable(slot.sram_we);
    emu.clock_mhz = slot.clock_mhz;
    emu.is_paused = true;
    // Discard host events only after commit; keep restored MFP/joy machine data.
    input_discard(emu);
    c_audio_discard();
    emu.session.speed_live = false;
    emu.session.speed_have = false;
    // The framebuffer is derived, not saved. Do not publish stale pixels.
    emu.ppu.frame_ready = false;
    c_set_frame_ready(0);
    return true;
}

fn state_drop(bank: i32, idx: i32) {
    let at = state_index(bank, idx);
    if at < 0 { return; }
    c_state_drop(bank, idx);
    g_checkpoints[at].saved = false;
    g_checkpoints[at].native_generation = 0;
}

fn state_frame(bank: i32, idx: i32) -> i64 {
    if !state_saved(bank, idx) { return 0; }
    return g_checkpoints[state_index(bank, idx)].total_frames;
}

// Occupied checkpoint bytes: native-owned storage plus this Goose record.
// Empty records are preallocated globals and are excluded from this metric.
fn state_bytes(bank: i32, idx: i32) -> i64 {
    if !state_saved(bank, idx) { return 0; }
    return (c_state_bytes(bank, idx) as i64)
        + bytes_of(g_checkpoints).len / g_checkpoints.len;
}

fn state_total(bank: i32) -> i64 {
    var total: i64 = 0;
    for idx: i32 in state_capacity(bank) { total += state_bytes(bank, idx); }
    return total;
}
