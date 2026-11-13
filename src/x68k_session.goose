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
    if (emu.total_frames % (s.rewind_interval)) != 0 { return; }
    if !state_capture(emu, STATE_REWIND, s.rewind_next) { return; }
    s.rewind_next = (s.rewind_next + 1) % REWIND_SLOTS;
    if s.rewind_count < REWIND_SLOTS { s.rewind_count += 1; }
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

// 再開してからの実測 fps と、CRTC が決める公称値に対する百分率。
fn session_measure(emu: X68kEmulator&, now: u64) -> i32, i32 {
    let s .= emu.session;
    let elapsed = (now - s.speed_start_ms) as i64;
    let frames = emu.total_frames - s.speed_start_frame;
    let fps = if elapsed > 50 { ((frames * 1000) / elapsed) as i32 } else { 0 };
    return fps, (fps * 100) / x68k_nominal_fps(emu.mmu);
}

fn session_pause(emu: X68kEmulator&, now: u64) {
    let s .= emu.session;
    if !emu.is_paused && s.speed_live {
        let fps, pct = session_measure(emu, now);
        s.speed_fps = fps;
        s.speed_pct = pct;
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

// fps、公称比の百分率、実行中かどうか。停止中は最後に測った値を返す。
fn session_speed(emu: X68kEmulator&, now: u64) -> i32, i32, bool {
    let s .= emu.session;
    if s.speed_live && !emu.is_paused {
        let fps, pct = session_measure(emu, now);
        return fps, pct, true;
    }
    if s.speed_have { return s.speed_fps, s.speed_pct, false; }
    return 0, 0, false;
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
    if name.len == 0 || name.len > SNAPSHOT_NAME_MAX { return -1; }
    for idx: i32 in SNAPSHOT_SLOTS {
        if state_saved(STATE_SNAPSHOT, idx) && emu.session.snapshot_names[idx] == name { return idx; }
    }
    return -1;
}

fn snapshot_name(emu: X68kEmulator&, idx: i32, out: u8[>..]&) {
    if !state_saved(STATE_SNAPSHOT, idx) { return; }
    out.append(emu.session.snapshot_names[idx]);
}

fn snapshot_create(emu: X68kEmulator&, name: const u8[:]) -> i32 {
    if name.len == 0 || name.len > SNAPSHOT_NAME_MAX { return SNAPSHOT_INVALID; }
    var idx = snapshot_find(emu, name);
    if idx < 0 {
        for i: i32 in SNAPSHOT_SLOTS {
            if !state_saved(STATE_SNAPSHOT, i) {
                idx = i;
                break;
            }
        }
    }
    if idx < 0 { return SNAPSHOT_FULL; }
    if !state_capture(emu, STATE_SNAPSHOT, idx) { return SNAPSHOT_CAPTURE_FAILED; }
    // Commit metadata only after capture succeeds, including failed overwrites.
    emu.session.snapshot_names[idx] = name;
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
    emu.session.snapshot_names[idx] = "";
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
    for idx: i32 in REWIND_SLOTS { state_drop(STATE_REWIND, idx); }
}

fn rewind_restore(emu: X68kEmulator&, steps: i32) -> bool {
    let s .= emu.session;
    if steps < 1 || steps > s.rewind_count { return false; }
    var idx = s.rewind_next - steps;
    while idx < 0 { idx += REWIND_SLOTS; }
    if !state_restore(emu, STATE_REWIND, idx) { return false; }
    s.rewind_count -= steps;
    s.rewind_next = idx;
    return true;
}

// Character scheduling is shared by type/exec/macro adapters.
fn session_type_char(emu: X68kEmulator&, ch: u8, hold: i32) -> i32 {
    let code, shift, ok = type_scancode(ch);
    if hold < 1 || hold > 3600 || !ok { return 0; }
    var frames: i32 = 0;
    if shift { type_set_key(emu, 0x70, true); session_run_frame(emu); frames += 1; }
    type_set_key(emu, code, true);
    for _ in hold { session_run_frame(emu); }
    frames += hold;
    type_set_key(emu, code, false);
    if shift { type_set_key(emu, 0x70, false); }
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
