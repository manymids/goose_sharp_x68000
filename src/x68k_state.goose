// Machine checkpoints. No JSON, frontend names, host handles or borrowed
// references are stored here. Native banks own sound/media/RAM snapshots.
import std;
import os;
import .x68k_bridge;
import .x68k_emu;
import .m68k_cpu;
import .m68k_mmu;
import .x68k_rom;
import .x68k_input;

let STATE_SLOT = 0;
let STATE_SNAPSHOT = 1;
let STATE_REWIND = 2;
// v3: the FDC phase is an enum. v2: SASI phase/direction are typed tags. Older records are incompatible.
let STATE_VERSION = 3;

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
    clock_mhz: i32 = 10,
}

// g_checkpoints の並び: セーブスロット、名前付きスナップショット、巻き戻しリングの順。
let SAVE_SLOTS = 10;
let SNAPSHOT_SLOTS = 32;
let REWIND_SLOTS = 8;
let CHECKPOINT_SLOTS = 50; // 上の 3 つの合計

var g_checkpoints: X68kCheckpoint[CHECKPOINT_SLOTS] = [X68kCheckpoint {}; CHECKPOINT_SLOTS];

fn state_capacity(bank: i32) -> i32 {
    if bank == STATE_SLOT { return SAVE_SLOTS; }
    if bank == STATE_SNAPSHOT { return SNAPSHOT_SLOTS; }
    if bank == STATE_REWIND { return REWIND_SLOTS; }
    return 0;
}

fn state_index(bank: i32, idx: i32) -> i32 {
    if idx < 0 || idx >= state_capacity(bank) { return -1; }
    if bank == STATE_SLOT { return idx; }
    if bank == STATE_SNAPSHOT { return SAVE_SLOTS + idx; }
    return SAVE_SLOTS + SNAPSHOT_SLOTS + idx;
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
    return (c_state_bytes(bank, idx))
        + bytes_of(g_checkpoints).len / g_checkpoints.len;
}

fn state_total(bank: i32) -> i64 {
    var total: i64 = 0;
    for idx: i32 in state_capacity(bank) { total += state_bytes(bank, idx); }
    return total;
}

// ---------------------------------------------------------------
// ファイルへの保存と読み込み
//
// ファイルは 3 つの直列化イメージを並べたもの:
//   1. StateFileHeader 1 件   種別、版、後続 2 つの大きさとチェックサム
//   2. X68kCheckpoint 1 件    Goose 側の機械の状態 (CPU、MMU とその中の各デバイス)
//   3. バイト列               C 側のスロット (RAM、SRAM、音源、FD / HDD イメージ、I/O ラッチ)
// どれも to_bytes で書き、from_bytes で読む。from_bytes は長さや enum のタグを確かめてから
// 値にするので、壊れたファイルから不正な状態は入らない。内容の改変は検出しないため、
// チェックサムを自前で持つ。
//
// 構造体のバイト配置がそのままファイル形式になる。X68kCheckpoint やその中の構造体に
// フィールドを足したら STATE_VERSION を上げること。
// ---------------------------------------------------------------

let STATE_FILE_MAGIC = 0x53383658; // "X68S"

struct StateFileHeader {
    magic: u32 = 0,
    version: i32 = 0,
    record_bytes: i64 = 0,
    native_bytes: i64 = 0,
    checksum: u64 = 0,
}

// 読み込みに失敗した理由
enum StateFileError { None, Unreadable, NotAStateFile, WrongVersion, Corrupt, Rejected }

fn state_file_error_text(e: StateFileError) -> const u8[:] {
    match e {
        None => "",
        Unreadable => "the file could not be read",
        NotAStateFile => "the file is not a state file",
        WrongVersion => "the state file was written by an incompatible version",
        Corrupt => "the state file is damaged",
        Rejected => "the state does not fit this machine configuration",
    }
}

// FNV-1a。h を引き継いで複数の領域を続けて計算できる。
fn state_hash(h: u64, data: const u8[:]) -> u64 {
    var acc = h;
    for b in data { acc = (acc ^ b) * 1099511628211; }
    return acc;
}

let STATE_HASH_SEED = 14695981039346656037;

// スロットの内容をファイル形式のバイト列にして out に追記する。
fn state_export(bank: i32, idx: i32, out: u8[>..]&) -> bool {
    if !state_validate(bank, idx) { return false; }
    var record: X68kCheckpoint[>..] = [];
    record.push(g_checkpoints[state_index(bank, idx)]);

    let native_bytes = c_state_export_size(bank, idx);
    if native_bytes <= 0 { return false; }
    var native: u8[>..] = [];
    native.resize(native_bytes, 0);
    if c_state_export(bank, idx, native[..]) != native_bytes { return false; }

    var header: StateFileHeader[>..] = [];
    header.push(StateFileHeader {
        magic: STATE_FILE_MAGIC,
        version: STATE_VERSION,
        record_bytes: bytes_of(record).len,
        native_bytes: native_bytes,
        checksum: state_hash(state_hash(STATE_HASH_SEED, bytes_of(record)), native[..]),
    });
    to_bytes(header, out);
    to_bytes(record, out);
    to_bytes(native, out);
    return true;
}

// data の at から始まる直列化イメージ 1 つの範囲。長さの接頭辞が壊れていれば false。
fn state_next_image(data: u8[:], at: i64) -> i64, bool {
    if at >= data.len { return at, false; }
    let payload, prefix = parse_uleb(data[at..]);
    if prefix == 0 || payload < 0 || payload > data.len - at - prefix { return at, false; }
    return at + prefix + payload, true;
}

// ファイル形式のバイト列を検証してスロットへ入れる。成功するまでスロットは変えない。
fn state_import(bank: i32, idx: i32, data: u8[:]) -> StateFileError {
    let at = state_index(bank, idx);
    if at < 0 { return StateFileError.Rejected; }

    let end1, ok1 = state_next_image(data, 0);
    if !ok1 { return StateFileError.NotAStateFile; }
    var header, header_ok = from_bytes<StateFileHeader[>..]>(data[..end1]);
    if !header_ok || header.len != 1 || header[0].magic != STATE_FILE_MAGIC { return StateFileError.NotAStateFile; }
    if header[0].version != STATE_VERSION { return StateFileError.WrongVersion; }

    let end2, ok2 = state_next_image(data, end1);
    let end3, ok3 = state_next_image(data, end2);
    if !ok2 || !ok3 || end3 != data.len { return StateFileError.Corrupt; }
    var record, record_ok = from_bytes<X68kCheckpoint[>..]>(data[end1..end2]);
    if !record_ok || record.len != 1 { return StateFileError.Corrupt; }
    if bytes_of(record).len != header[0].record_bytes { return StateFileError.WrongVersion; }
    var native, native_ok = from_bytes<u8[>..]>(data[end2..end3]);
    if !native_ok || native.len != header[0].native_bytes { return StateFileError.Corrupt; }
    if state_hash(state_hash(STATE_HASH_SEED, bytes_of(record)), native[..]) != header[0].checksum {
        return StateFileError.Corrupt;
    }

    if c_state_import(bank, idx, native[..]) == 0 { return StateFileError.Rejected; }
    g_checkpoints[at] = record[0];
    g_checkpoints[at].native_generation = c_state_generation(bank, idx);
    g_checkpoints[at].version = STATE_VERSION;
    g_checkpoints[at].saved = true;
    return StateFileError.None;
}

fn state_write_file(bank: i32, idx: i32, path: const u8[:]) -> bool {
    var image: u8[>..] = [];
    if !state_export(bank, idx, image) { return false; }
    return write_file_atomic(path, image);
}

fn state_read_file(bank: i32, idx: i32, path: const u8[:]) -> StateFileError {
    var image: u8[>..] = [];
    if !read_file(path, image) { return StateFileError.Unreadable; }
    return state_import(bank, idx, image[..]);
}
