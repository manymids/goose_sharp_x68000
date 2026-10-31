// Application services shared by frontends. JSON parsing and response formatting
// belong to the adapter. Machine checkpoints remain in x68k_state.
import .x68k_emu;
import .x68k_state;
import .x68k_input;

let SNAPSHOT_INVALID = -1;
let SNAPSHOT_FULL = -2;
let SNAPSHOT_CAPTURE_FAILED = -3;

fn session_run_frame(emu: X68kEmulator&) {
    x68k_emu_run_frame(emu);
    let s .= emu.session;
    if !s.rewind_on || s.rewind_interval < 1 || emu.total_frames <= 0 { return; }
    if (emu.total_frames % (s.rewind_interval as i64)) != 0 { return; }
    if !state_capture(emu, STATE_REWIND, s.rewind_next) { return; }
    s.rewind_next = (s.rewind_next + 1) % 8;
    if s.rewind_count < 8 { s.rewind_count += 1; }
}

fn session_run(emu: X68kEmulator&, frames: i32) -> i32 {
    if frames < 1 || frames > 36000 { return 0; }
    emu.is_paused = true;
    emu.hit_break = false;
    var used: i32 = 0;
    for _ in frames {
        session_run_frame(emu);
        used += 1;
        if emu.hit_break { break; }
    }
    return used;
}

fn session_pause(emu: X68kEmulator&, now: u64) {
    let s .= emu.session;
    if !emu.is_paused && s.speed_live {
        let elapsed = (now - s.speed_start_ms) as i64;
        let frames = emu.total_frames - s.speed_start_frame;
        s.speed_fps = if elapsed > 50 { ((frames * 1000) / elapsed) as i32 } else { 0 };
        let nom = if (emu.mmu.crtc_regs[0x29] & 0x10) != 0 { 55 } else { 61 };
        s.speed_pct = ((s.speed_fps * 100) / nom) as i32;
        s.speed_have = true;
        s.speed_live = false;
    }
    emu.is_paused = true;
}

fn session_resume(emu: X68kEmulator&, now: u64) {
    if emu.is_paused {
        emu.session.speed_live = true;
        emu.session.speed_start_ms = now;
        emu.session.speed_start_frame = emu.total_frames;
    }
    emu.is_paused = false;
}

fn session_speed(emu: X68kEmulator&, now: u64, fps: i32&, pct: i32&, running: bool&) {
    fps = 0; pct = 0; running = false;
    let s .= emu.session;
    if s.speed_live && !emu.is_paused {
        let elapsed = (now - s.speed_start_ms) as i64;
        let frames = emu.total_frames - s.speed_start_frame;
        if elapsed > 50 { fps = ((frames * 1000) / elapsed) as i32; }
        let nom = if (emu.mmu.crtc_regs[0x29] & 0x10) != 0 { 55 } else { 61 };
        pct = ((fps * 100) / nom) as i32;
        running = true;
    } else if s.speed_have { fps = s.speed_fps; pct = s.speed_pct; }
}

fn session_reset(emu: X68kEmulator&) { x68k_emu_reset(emu); }

fn session_save(emu: X68kEmulator&, slot: i32) -> bool {
    if !state_capture(emu, STATE_SLOT, slot) { return false; }
    emu.is_paused = true;
    return true;
}

fn session_load(emu: X68kEmulator&, slot: i32) -> bool {
    return state_restore(emu, STATE_SLOT, slot);
}

fn snapshot_find(emu: X68kEmulator&, name: const u8[:]) -> i32 {
    if name.len == 0 || name.len > 63 { return -1; }
    for idx: i32 in 32 {
        if !state_saved(STATE_SNAPSHOT, idx) { continue; }
        var equal = true;
        for i in name.len {
            let ch = emu.session.snapshot_names[idx * 64 + i];
            if ch == 0 || ch != name[i] { equal = false; break; }
        }
        if equal && emu.session.snapshot_names[idx * 64 + name.len] == 0 { return idx; }
    }
    return -1;
}

fn snapshot_name(emu: X68kEmulator&, idx: i32, out: u8[>..]&) {
    if !state_saved(STATE_SNAPSHOT, idx) { return; }
    for i: i32 in 63 {
        let ch = emu.session.snapshot_names[idx * 64 + i];
        if ch == 0 { break; }
        out.push(ch);
    }
}

fn snapshot_create(emu: X68kEmulator&, name: const u8[:]) -> i32 {
    if name.len == 0 || name.len > 63 { return SNAPSHOT_INVALID; }
    var idx = snapshot_find(emu, name);
    if idx < 0 {
        for i: i32 in 32 { if !state_saved(STATE_SNAPSHOT, i) { idx = i; break; } }
    }
    if idx < 0 { return SNAPSHOT_FULL; }
    if !state_capture(emu, STATE_SNAPSHOT, idx) { return SNAPSHOT_CAPTURE_FAILED; }
    // Commit metadata only after capture succeeds, including failed overwrites.
    for i: i32 in 64 { emu.session.snapshot_names[idx * 64 + i] = 0; }
    for i in name.len { emu.session.snapshot_names[idx * 64 + i] = name[i]; }
    emu.is_paused = true;
    return idx;
}

fn snapshot_restore(emu: X68kEmulator&, name: const u8[:]) -> bool {
    return state_restore(emu, STATE_SNAPSHOT, snapshot_find(emu, name));
}

fn snapshot_delete(emu: X68kEmulator&, name: const u8[:]) -> bool {
    let idx = snapshot_find(emu, name);
    if idx < 0 { return false; }
    state_drop(STATE_SNAPSHOT, idx);
    for i: i32 in 64 { emu.session.snapshot_names[idx * 64 + i] = 0; }
    return true;
}

fn rewind_enable(emu: X68kEmulator&, interval: i32) -> bool {
    if interval < 10 || interval > 36000 { return false; }
    emu.session.rewind_on = true;
    emu.session.rewind_interval = interval;
    emu.session.rewind_count = 0;
    emu.session.rewind_next = 0;
    return true;
}

fn rewind_disable(emu: X68kEmulator&) {
    emu.session.rewind_on = false;
    emu.session.rewind_count = 0;
    emu.session.rewind_next = 0;
    for idx: i32 in 8 { state_drop(STATE_REWIND, idx); }
}

fn rewind_restore(emu: X68kEmulator&, steps: i32) -> bool {
    let s .= emu.session;
    if steps < 1 || steps > s.rewind_count { return false; }
    var idx = s.rewind_next - steps;
    while idx < 0 { idx += 8; }
    if !state_restore(emu, STATE_REWIND, idx) { return false; }
    s.rewind_count -= steps;
    s.rewind_next = idx;
    return true;
}

// Character scheduling is shared by type/exec/macro adapters.
fn session_type_char(emu: X68kEmulator&, ch: u8, hold: i32) -> i32 {
    var code: i32 = 0;
    var shift: i32 = 0;
    if hold < 1 || hold > 3600 || !type_scancode(ch, code, shift) { return 0; }
    var frames: i32 = 0;
    if shift != 0 { type_set_key(emu, 0x70, true); session_run_frame(emu); frames += 1; }
    type_set_key(emu, code, true);
    for _ in hold { session_run_frame(emu); }
    frames += hold;
    type_set_key(emu, code, false);
    if shift != 0 { type_set_key(emu, 0x70, false); }
    session_run_frame(emu);
    return frames + 1;
}

fn session_key_tap(emu: X68kEmulator&, code: i32, frames: i32) -> bool {
    if code < 0 || code >= 128 || frames < 1 || frames > 3600 { return false; }
    input_key(emu, code, true);
    for _ in frames { session_run_frame(emu); }
    input_key(emu, code, false);
    return true;
}

fn session_joy_tap(emu: X68kEmulator&, port: i32, mask: u8, frames: i32) -> bool {
    if frames < 1 || frames > 3600 { return false; }
    if !input_joy(emu, port, mask, true) { return false; }
    for _ in frames { session_run_frame(emu); }
    input_joy(emu, port, mask, false);
    return true;
}
