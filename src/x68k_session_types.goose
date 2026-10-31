// Host control metadata. Not part of an emulated-machine checkpoint.
// Owned by the emulator; no borrowed references and no transport state.
struct X68kSession {
    keys: u8[128] = [0; 128],
    snapshot_names: u8[2048] = [0; 2048],
    rewind_on: bool = false,
    rewind_interval: i32 = 60,
    rewind_count: i32 = 0,
    rewind_next: i32 = 0,
    speed_live: bool = false,
    speed_have: bool = false,
    speed_start_ms: u64 = 0,
    speed_start_frame: i64 = 0,
    speed_fps: i32 = 0,
    speed_pct: i32 = 0
}
