// 機械のチェックポイント。JSON、フロントエンドの名前、ホストのハンドルは入れない。
//
// 1 件は 2 つの部分からなる。
//   X68kCheckpoint   大きさの決まった状態 (CPU、MMU とその中の各デバイス、ディスクドライブ)
//   blob             大きさが実行時に決まるバイト列。RAM、SRAM、FD0、FD1、HDD のイメージをこの順に並べたもの
// blob は 1 つのスライスプールから切り出す。巻き戻しのように保存と破棄を繰り返しても、
// 空いた区間が次の保存に使い回される。
import std;
import os;
import .x68k_bridge;
import .x68k_emu;
import .m68k_cpu;
import .m68k_mmu;
import .x68k_ram;
import .x68k_rom;
import .x68k_disk;
import .x68k_input;
namespace state;

// チェックポイントの置き場所の種類: 保存スロット、名前付きのスナップショット、巻き戻し。
enum Bank { Slot, Snapshot, Rewind }
type ::StateBank = state::Bank;
let ::STATE_SLOT = state::Bank.Slot;
let ::STATE_SNAPSHOT = state::Bank.Snapshot;
let ::STATE_REWIND = state::Bank.Rewind;
// v8: OPM を Goose 側へ移した。機械の状態はすべて Goose の値になり、C のバイト列は入らない。
// v7: ADPCM と DMA チャンネル 3 を Goose 側へ移した。音源の状態に残るのは OPM だけ。
// v6: 音源の状態に、書いたときの番地を入れた (別のプロセスで読んでもポインタを直せる)。
// v5: 8255 ポート C と OPM の控えを MMU へ移した。C 側に残る状態は音源だけ。
// v4: ディスクの状態とイメージの置き場所を Goose 側へ移した。v3: FDC の相が enum。
// 版の違う記録は読めない。
// v9: バスの失敗の種類 (MMU の fault) を enum にした。
// v10: MMU に SCC (マウス) を足した。
let ::STATE_VERSION = 10;

// blob の内訳。この順に並ぶ。
struct BlobLayout {
    ram_bytes: i64 = 0,
    image_bytes: i64[DISK_IMAGES] = [0; DISK_IMAGES],
}

let SECTION_RAM = 0;
let SECTION_SRAM = 1;
let SECTION_IMAGES = 2; // ここから DISK_IMAGES 個
let SECTIONS = 5;

fn section_bytes(layout: BlobLayout&, which: i64) -> i64 {
    if which == SECTION_RAM { return layout.ram_bytes; }
    if which == SECTION_SRAM { return SRAM_BYTES; }
    return layout.image_bytes[which - SECTION_IMAGES];
}

fn total_bytes(layout: BlobLayout&) -> i64 {
    var total: i64 = 0;
    for which in SECTIONS { total += section_bytes(layout, which); }
    return total;
}

fn section(layout: BlobLayout&, blob: u8[:], which: i64) -> u8[:] {
    var at: i64 = 0;
    for before in which { at += section_bytes(layout, before); }
    return blob[at..at + section_bytes(layout, which)];
}

struct X68kCheckpoint {
    saved: bool = false,
    version: i32 = 0,
    cpu: M68kCPU = M68kCPU {},
    mmu: M68kMMU = M68kMMU {},
    total_frames: i64 = 0,
    total_cycles: i64 = 0,
    clk_used: i32 = 0,
    sram_we: i32 = 0,
    clock_mhz: i32 = 10,
    disk: DiskState = DiskState {},
    layout: BlobLayout = BlobLayout {},
}
type ::X68kCheckpoint = state::X68kCheckpoint;

// g_checkpoints の並び: セーブスロット、名前付きスナップショット、巻き戻しリングの順。
let ::SAVE_SLOTS = 10;
let ::SNAPSHOT_SLOTS = 32;
let ::REWIND_SLOTS = 8;
let ::CHECKPOINT_SLOTS = 50; // 上の 3 つの合計

var ::g_checkpoints: X68kCheckpoint[CHECKPOINT_SLOTS] = [X68kCheckpoint {}; CHECKPOINT_SLOTS];

reusable[] var g_blob_pool: u8[>..] = [];

// 各チェックポイントの blob がプールのどこにあるか。空のスロットは長さ 0。
// スライスそのものではなく位置で持つ。スライスをグローバルの配列に入れて読み戻すと、
// コンパイラからは「u8 を持つどの配列を指しているか分からない」ものになり、ディスクイメージを
// 入れ替える関数へ渡せなくなる。位置から切り出し直せば、プールを指すことがはっきりする。
struct BlobSpan { at: i64 = 0, len: i64 = 0 }
var g_spans: BlobSpan[CHECKPOINT_SLOTS] = [BlobSpan {}; CHECKPOINT_SLOTS];

fn blob_of(at: i32) -> u8[:] {
    let span .= g_spans[at];
    return g_blob_pool[span.at..span.at + span.len];
}

fn capacity(bank: Bank) -> i32 {
    match bank {
        Slot => { return SAVE_SLOTS; },
        Snapshot => { return SNAPSHOT_SLOTS; },
        Rewind => { return REWIND_SLOTS; },
    }
}

// g_checkpoints の中の位置。スロット、スナップショット、巻き戻しの順に並ぶ。範囲外は -1。
fn index(bank: Bank, idx: i32) -> i32 {
    if idx < 0 || idx >= capacity(bank) { return -1; }
    match bank {
        Slot => { return idx; },
        Snapshot => { return SAVE_SLOTS + idx; },
        Rewind => { return SAVE_SLOTS + SNAPSHOT_SLOTS + idx; },
    }
}

fn saved(bank: Bank, idx: i32) -> bool {
    let at = index(bank, idx);
    if at < 0 { return false; }
    return g_checkpoints[at].saved && g_checkpoints[at].version == STATE_VERSION;
}

// 記録と blob の組が、今の機械へ戻せる形かどうか。ファイルから来たものもここを通す。
fn record_ok(r: X68kCheckpoint&, blob: u8[:]) -> bool {
    let layout .= r.layout;
    if layout.ram_bytes != x68k_ram_limit() { return false; }
    if c_cpu_mhz_ok(r.clock_mhz) == 0 { return false; }
    guard disk::state_ok(r.disk, layout.image_bytes) else { return false; }
    return blob.len == total_bytes(layout);
}

fn validate(bank: Bank, idx: i32) -> bool {
    guard saved(bank, idx) else { return false; }
    let at = index(bank, idx);
    return record_ok(g_checkpoints[at], blob_of(at));
}

fn release_blob(at: i32) {
    if g_spans[at].len > 0 { g_blob_pool.free_slice(blob_of(at)); }
    g_spans[at] = BlobSpan {};
}

// プールから bytes バイトを切り出してスロットの blob にする。前の blob は先に release_blob で返すこと。
fn claim_blob(at: i32, bytes: i64) -> u8[:] {
    let blob = g_blob_pool.alloc_slice(bytes);
    g_spans[at] = BlobSpan { at: g_blob_pool.index_of(blob[0]), len: bytes };
    return blob;
}

fn capture(emu: X68kEmulator&, bank: Bank, idx: i32) -> bool {
    guard emu.active() else { return false; }
    let at = index(bank, idx);
    if at < 0 { return false; }

    var layout = BlobLayout { ram_bytes: x68k_ram_limit() };
    for which in DISK_IMAGES { layout.image_bytes[which] = disk::image_bytes(which); }

    // 先に新しい blob を作る。失敗したら前の内容がそのまま残る。
    let previous = g_spans[at];
    let blob = claim_blob(at, total_bytes(layout));
    copy_into(section(layout, blob, SECTION_RAM), g_x68k_ram[..layout.ram_bytes]);
    copy_into(section(layout, blob, SECTION_SRAM), g_sram[..]);
    for which in DISK_IMAGES {
        copy_into(section(layout, blob, SECTION_IMAGES + which), disk::image(which));
    }
    if previous.len > 0 { g_blob_pool.free_slice(g_blob_pool[previous.at..previous.at + previous.len]); }

    let slot .= g_checkpoints[at];
    slot.cpu = emu.cpu;
    slot.mmu = emu.mmu;
    slot.total_frames = emu.total_frames;
    slot.total_cycles = emu.total_cycles;
    slot.clk_used = emu.clk_used;
    slot.sram_we = x68k_sram_write_enable();
    slot.clock_mhz = emu.clock_mhz;
    slot.disk = g_disk;
    slot.layout = layout;
    slot.version = STATE_VERSION;
    slot.saved = true;
    return true;
}

fn restore(emu: X68kEmulator&, bank: Bank, idx: i32) -> bool {
    guard emu.active() else { return false; }
    guard validate(bank, idx) else { return false; }
    let at = index(bank, idx);
    let slot .= g_checkpoints[at];
    let blob = blob_of(at);
    let layout .= slot.layout;
    copy_into(g_x68k_ram[..layout.ram_bytes], section(layout, blob, SECTION_RAM));
    copy_into(g_sram[..], section(layout, blob, SECTION_SRAM));
    disk::restore(slot.disk, section(layout, blob, SECTION_IMAGES), section(layout, blob, SECTION_IMAGES + 1),
        section(layout, blob, SECTION_IMAGES + 2));
    emu.cpu = slot.cpu;
    emu.mmu = slot.mmu;
    emu.total_frames = slot.total_frames;
    emu.total_cycles = slot.total_cycles;
    emu.clk_used = slot.clk_used;
    x68k_sram_set_write_enable(slot.sram_we);
    c_set_cpu_mhz(slot.clock_mhz); // ウィンドウのメニューの印もここで合う
    emu.clock_mhz = slot.clock_mhz;
    emu.is_paused = true;
    // ホストのイベントは、確定してから捨てる。復元した MFP やジョイスティックの機械の状態は残す。
    input::discard(emu);
    c_audio_discard();
    emu.session.speed_live = false;
    emu.session.speed_have = false;
    // フレームバッファは保存せず作り直すもの。古い画素は出さない。
    emu.ppu.frame_ready = false;
    return true;
}

fn drop(bank: Bank, idx: i32) {
    let at = index(bank, idx);
    if at < 0 { return; }
    release_blob(at);
    g_checkpoints[at].saved = false;
}

fn frame(bank: Bank, idx: i32) -> i64 {
    guard saved(bank, idx) else { return 0; }
    return g_checkpoints[index(bank, idx)].total_frames;
}

// 使っているバイト数: blob とこの記録。空の記録は最初から確保してあるので数えない。
fn bytes(bank: Bank, idx: i32) -> i64 {
    guard saved(bank, idx) else { return 0; }
    return g_spans[index(bank, idx)].len + bytes_of(g_checkpoints).len / g_checkpoints.len;
}

fn total(bank: Bank) -> i64 {
    var total: i64 = 0;
    for idx: i32 in capacity(bank) { total += bytes(bank, idx); }
    return total;
}

// ---------------------------------------------------------------
// ファイルへの保存と読み込み
//
// ファイルは次の 3 つを並べたもの:
//   1. StateFileHeader 1 件   種別、版、後続 2 つの大きさとチェックサム
//   2. X68kCheckpoint 1 件    大きさの決まった状態
//   3. blob                   RAM、SRAM、FD / HDD イメージ。ファイルの終わりまで
// 1 と 2 は to_bytes で書き、from_bytes で読む。from_bytes は長さや enum のタグを確かめてから
// 値にするので、壊れたファイルから不正な状態は入らない。内容の改変は検出しないため、
// チェックサムを自前で持つ。値の範囲は record_ok で確かめる。
//
// 構造体のバイト配置がそのままファイル形式になる。X68kCheckpoint やその中の構造体に
// フィールドを足したら STATE_VERSION を上げること。
// ---------------------------------------------------------------

let ::STATE_FILE_MAGIC = 0x53383658; // "X68S"

struct StateFileHeader {
    magic: u32 = 0,
    version: i32 = 0,
    record_bytes: i64 = 0,
    blob_bytes: i64 = 0,
    checksum: u64 = 0,
}
type ::StateFileHeader = state::StateFileHeader;

// 読み込みに失敗した理由
enum StateFileError { None, Unreadable, NotAStateFile, WrongVersion, Corrupt, Rejected }

// 最後に WrongVersion で断ったファイルの版。版が同じで中身の大きさが違う (同じ版の別のビルド) ときは STATE_VERSION のまま。
var g_refused_version: i32 = 0;

// WrongVersion を、ファイルの版とこのビルドの版を入れた文にする。
fn version_error_text(out: u8[>..]&) {
    if g_refused_version == STATE_VERSION {
        format(out, "the state file was written by another build of version ", STATE_VERSION, " (the machine state has a different size)");
    } else {
        format(out, "the state file is version ", g_refused_version, "; this build reads version ", STATE_VERSION);
    }
}

fn file_error_text(e: StateFileError) -> const u8[:] {
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
fn checksum(h: u64, data: const u8[:]) -> u64 {
    var acc = h;
    for b in data { acc = (acc ^ b) * 1099511628211; }
    return acc;
}

let ::STATE_HASH_SEED = 14695981039346656037;

// スロットの内容をファイル形式のバイト列にして out に追記する。
fn export_image(bank: Bank, idx: i32, out: u8[>..]&) -> bool {
    guard validate(bank, idx) else { return false; }
    let at = index(bank, idx);
    let blob = blob_of(at);
    var record: X68kCheckpoint[>..] = [];
    record.push(g_checkpoints[at]);

    var header: StateFileHeader[>..] = [];
    header.push(StateFileHeader {
        magic: STATE_FILE_MAGIC,
        version: STATE_VERSION,
        record_bytes: bytes_of(record).len,
        blob_bytes: blob.len,
        checksum: checksum(checksum(STATE_HASH_SEED, bytes_of(record)), blob),
    });
    to_bytes(header, out);
    to_bytes(record, out);
    out.append(blob);
    return true;
}

// data の at から始まる直列化イメージ 1 つの範囲。長さの接頭辞が壊れていれば false。
fn next_image(data: u8[:], at: i64) -> i64, bool {
    if at >= data.len { return at, false; }
    let payload, prefix = parse_uleb(data[at..]);
    if prefix == 0 || payload < 0 || payload > data.len - at - prefix { return at, false; }
    return at + prefix + payload, true;
}

// ファイル形式のバイト列を検証してスロットへ入れる。成功するまでスロットは変えない。
fn import_image(bank: Bank, idx: i32, data: u8[:]) -> StateFileError {
    let at = index(bank, idx);
    if at < 0 { return StateFileError.Rejected; }

    let end1, ok1 = next_image(data, 0);
    guard ok1 else { return StateFileError.NotAStateFile; }
    var header, header_ok = from_bytes<StateFileHeader[>..]>(data[..end1]);
    if !header_ok || header.len != 1 || header[0].magic != STATE_FILE_MAGIC { return StateFileError.NotAStateFile; }
    g_refused_version = header[0].version;
    if header[0].version != STATE_VERSION { return StateFileError.WrongVersion; }

    let end2, ok2 = next_image(data, end1);
    guard ok2 else { return StateFileError.Corrupt; }
    var record, parsed = from_bytes<X68kCheckpoint[>..]>(data[end1..end2]);
    if !parsed || record.len != 1 { return StateFileError.Corrupt; }
    if bytes_of(record).len != header[0].record_bytes { return StateFileError.WrongVersion; }
    let blob = data[end2..];
    if blob.len != header[0].blob_bytes { return StateFileError.Corrupt; }
    if checksum(checksum(STATE_HASH_SEED, bytes_of(record)), blob) != header[0].checksum {
        return StateFileError.Corrupt;
    }
    guard record_ok(record[0], blob) else { return StateFileError.Rejected; }

    release_blob(at);
    copy_into(claim_blob(at, blob.len), blob);
    g_checkpoints[at] = record[0];
    g_checkpoints[at].version = STATE_VERSION;
    g_checkpoints[at].saved = true;
    return StateFileError.None;
}

fn save_file(bank: Bank, idx: i32, path: const u8[:]) -> bool {
    var image: u8[>..] = [];
    guard export_image(bank, idx, image) else { return false; }
    return write_file_atomic(path, image);
}

fn load_file(bank: Bank, idx: i32, path: const u8[:]) -> StateFileError {
    var image: u8[>..] = [];
    guard read_file(path, image) else { return StateFileError.Unreadable; }
    return import_image(bank, idx, image[..]);
}
