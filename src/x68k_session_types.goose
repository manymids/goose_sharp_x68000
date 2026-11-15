// ホストが制御に使う情報。エミュレートした機械のチェックポイントには入らない。
// エミュレータが持つ。借りた参照も、受け取り方の状態も持たない。
let SNAPSHOT_NAME_MAX = 63; // スナップショット名の最大バイト数

struct X68kSession {
    keys: bool[128] = [false; 128],
    snapshot_names: u8[..63][32] = [""; 32], // [SNAPSHOT_SLOTS] 件、各 SNAPSHOT_NAME_MAX バイトまで
    rewind_on: bool = false,
    rewind_interval: i32 = 60,
    rewind_count: i32 = 0,
    rewind_next: i32 = 0,
    speed_live: bool = false,
    speed_have: bool = false,
    speed_start_ms: u64 = 0,
    speed_start_frame: i64 = 0,
    speed_fps: i32 = 0,
    speed_pct: i32 = 0,
}
