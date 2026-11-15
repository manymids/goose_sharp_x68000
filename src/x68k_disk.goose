// フロッピー (XDF / D88 / DIM) とハードディスク (SASI) のイメージ。
//
// イメージはメモリに読み込んで使い、ホストのファイルへは書き戻さない。ドライブごとの状態
// (種類、ヘッド位置、挿抜の通知) は DiskState にまとめてあり、チェックポイントにそのまま入る。
// イメージ本体は大きさが実行時に決まるので、伸長配列のグローバルに置く。

import std;
import os;
import .x68k_bridge;
import .x68k_config;
namespace disk;

let ::FDD_XDF_BYTES = 1261568;  // 2HD: 154 トラック * 8 セクタ * 1024 バイト
let ::FDD_MAX_IMAGE = 4194304;  // D88 / DIM の上限
let ::HDD_MAX_BYTES = 41943040; // SASI は 40 MB まで
let ::HDD_SECTOR_BYTES = 256;
let DIM_HEADER = 256;
let D88_HEADER = 0x2B0;
let XDF_LAST_TRACK = 153;
let DIM_LAST_TRACK = 169;
let D88_LAST_TRACK = 163;
let MEDIA_DELAY_FRAMES = 3;     // px68k fdd.c SetDelay: 挿入は 3 フレーム後に通知する

// イメージの種類は拡張子で決める (px68k GetDiskType)。XDF は 1024 バイト * 8 セクタの平らな並び。
enum FdKind { Empty, Xdf, D88, Dim }

struct FdDrive {
    kind: FdKind = FdKind.Empty,
    len: i32 = 0,     // ファイルから読んだバイト数
    trk: i32 = -1,    // ヘッドのあるトラック (シリンダ * 2 + ヘッド)。-1 はシーク前
    cur: i32 = 0,     // XDF / DIM: 次に READ ID で返すセクタの番号 (0 始まり)
    d88_top: u32 = 0, // D88: 今のトラックの先頭セクタヘッダの位置
    d88_cur: u32 = 0, // D88: 次に READ ID で返すセクタヘッダの位置
    delay: i32 = 0,   // 挿入を通知するまでの残りフレーム数
}

struct DiskState {
    fd: FdDrive[2] = [FdDrive {}; 2],
    media_enable: bool = false,  // IOC が挿抜割り込みを許可している
    media_pending: bool = false, // 挿抜割り込みを要求中
    sasi_reset: bool = false,    // HDD を差し替えたので SASI を初期化してほしい
}
type ::DiskState = disk::DiskState;

var ::g_disk: DiskState = DiskState {};
var g_fd0: u8[>..] = [];
var g_fd1: u8[>..] = [];
var g_hdd: u8[>..] = [];

// ---------------------------------------------------------------
// 挿抜の通知
// ---------------------------------------------------------------

fn media_raise() {
    if g_disk.media_enable { g_disk.media_pending = true; }
}

// 1 フレームに 1 回。挿入から MEDIA_DELAY_FRAMES 後に割り込みを要求する。
fn media_tick(enable: bool) {
    g_disk.media_enable = enable;
    for d in 2 {
        let drive .= g_disk.fd[d];
        if drive.delay > 0 {
            drive.delay -= 1;
            if drive.delay == 0 { media_raise(); }
        }
    }
}

// 本体のリセット。メディアとヘッド位置、挿入待ちの残りは実機と同じくドライブに残す。
fn machine_reset() {
    g_disk.media_enable = false;
    g_disk.media_pending = false;
    g_disk.sasi_reset = false;
}

// 電源を入れ直した状態。すべてのドライブが空になり、覚えていたパスも消える。
fn power_on() {
    g_fd0.clear();
    g_fd1.clear();
    g_hdd.clear();
    g_disk = DiskState {};
    forget_paths();
}

// ---------------------------------------------------------------
// 読み込みと取り出し
// ---------------------------------------------------------------

fn lower(ch: u8) -> u8 {
    return if ch >= 'A' && ch <= 'Z' { ch + 32 } else { ch };
}

// 最後の '.' の後ろ 3 文字を小文字にして返す。3 文字に満たなければ false。
fn extension(path: const u8[:]) -> u8[3], bool {
    var dot: i64 = -1;
    for i in path.len {
        if path[i] == '.' { dot = i; }
    }
    if dot < 0 || dot + 3 >= path.len { return [0; 3], false; }
    return [lower(path[dot + 1]), lower(path[dot + 2]), lower(path[dot + 3])], dot + 4 == path.len;
}

fn kind_of(path: const u8[:]) -> FdKind {
    let ext, _ = extension(path);
    if ext == "d88" || ext == "88d" { return FdKind.D88; }
    if ext == "dim" { return FdKind.Dim; }
    return FdKind.Xdf;
}

// .hdf / .hds は SASI のイメージ。それ以外はフロッピーとして扱う。
fn path_is_hdd(path: const u8[:]) -> bool {
    let ext, exact = extension(path);
    return exact && (ext == "hdf" || ext == "hds");
}

// ファイルを out に読む。使う長さ (limit を超える分は切り捨てる) を返す。読めなければ 0。
fn read_image(path: const u8[:], limit: i64, out: u8[>..]&) -> i64 {
    if path.len == 0 || !read_file(path, out) { return 0; }
    return min(out.len, limit);
}

fn replace(image: u8[>..]&, bytes: const u8[:]) {
    image.clear();
    image.append(bytes);
}

// GUI が次回の起動で同じディスクを入れ直せるよう、設定にパスを覚えさせる。
fn remember_path(key: i32, path: const u8[:]) {
    config::set_path(key, path);
}

fn forget_paths() {
    for key: i32 in GUI_FD0..GUI_HDD + 1 { remember_path(key, ""); }
}

fn fd_loaded(drive: i32) -> bool {
    return (drive == 0 || drive == 1) && g_disk.fd[drive].kind != FdKind.Empty;
}

fn fd_image(drive: i32) -> u8[:] {
    return if drive == 0 { g_fd0[..] } else { g_fd1[..] };
}

fn fd_load(drive: i32, path: const u8[:]) -> bool {
    if drive != 0 && drive != 1 { return false; }
    let kind = kind_of(path);
    let xdf = kind == FdKind.Xdf;
    var file: u8[>..] = [];
    let n = read_image(path, if xdf { FDD_XDF_BYTES } else { FDD_MAX_IMAGE + 1 }, file);
    if n <= 0 { return false; }
    if !xdf && (n > FDD_MAX_IMAGE || n < 16) { return false; }
    // XDF は短いファイルでも 2HD の大きさまで 0 で埋めて持つ。
    if xdf && file.len < FDD_XDF_BYTES { file.resize(FDD_XDF_BYTES, 0); }
    let size = if xdf { FDD_XDF_BYTES } else { n };
    if drive == 0 { replace(g_fd0, file[..size]); } else { replace(g_fd1, file[..size]); }

    let was_loaded = fd_loaded(drive);
    g_disk.fd[drive] = FdDrive { kind: kind, len: n as i32, delay: MEDIA_DELAY_FRAMES, .. };
    remember_path(GUI_FD0 + drive, path);
    if was_loaded { media_raise(); } // 入れ替えは、抜いた分をすぐ通知する
    return true;
}

fn fd_eject(drive: i32) {
    if drive != 0 && drive != 1 { return; }
    let was_loaded = fd_loaded(drive);
    if drive == 0 { g_fd0.clear(); } else { g_fd1.clear(); }
    g_disk.fd[drive] = FdDrive { delay: g_disk.fd[drive].delay, .. };
    remember_path(GUI_FD0 + drive, "");
    if was_loaded { media_raise(); }
}

fn hdd_loaded() -> bool {
    return g_hdd.len > 0;
}

// 読めなかったときは、入っていたイメージも外れる。
fn hdd_load(path: const u8[:]) -> bool {
    var file: u8[>..] = [];
    let n = read_image(path, HDD_MAX_BYTES, file);
    if n <= 0 {
        g_hdd.clear();
        return false;
    }
    replace(g_hdd, file[..n]);
    g_disk.sasi_reset = true;
    remember_path(GUI_HDD, path);
    return true;
}

fn hdd_eject() {
    g_hdd.clear();
    g_disk.sasi_reset = true;
    remember_path(GUI_HDD, "");
}

// ---------------------------------------------------------------
// ハードディスク: 256 バイトのセクタ
// ---------------------------------------------------------------

fn hdd_unit_ok() -> bool {
    return g_hdd.len >= HDD_SECTOR_BYTES;
}

// SASI 側が初期化の依頼を受け取る。受け取ると依頼は消える。
fn take_sasi_reset() -> bool {
    let asked = g_disk.sasi_reset;
    g_disk.sasi_reset = false;
    return asked;
}

// セクタの位置。1 = イメージの中、0 = イメージの外、-1 = イメージが無い。
fn hdd_sector_at(sector: u32) -> i32, i64 {
    if !hdd_unit_ok() { return -1, 0; }
    let at: i64 = (sector as i64) << 8;
    if at + HDD_SECTOR_BYTES > g_hdd.len { return 0, 0; }
    return 1, at;
}

fn hdd_read(sector: u32, dst: u8[HDD_SECTOR_BYTES]&) -> i32 {
    dst = [0; HDD_SECTOR_BYTES];
    let found, at = hdd_sector_at(sector);
    if found == 1 { copy_into(dst[..], g_hdd[at..at + HDD_SECTOR_BYTES]); }
    return found;
}

fn hdd_write(sector: u32, src: u8[HDD_SECTOR_BYTES]&) -> i32 {
    let found, at = hdd_sector_at(sector);
    if found == 1 { note_write(2, at, HDD_SECTOR_BYTES); }
    if found == 1 { copy_into(g_hdd[at..at + HDD_SECTOR_BYTES], src[..]); }
    return found;
}

// ---------------------------------------------------------------
// DIM: 256 バイトのヘッダ (種類、トラックごとの有無) の後ろにトラックが並ぶ
// ---------------------------------------------------------------

fn dim_track_ok(img: const u8[:], trk: i32) -> bool {
    if img.len < DIM_HEADER || trk < 0 || trk > DIM_LAST_TRACK { return false; }
    let kind = img[0];
    if kind != 0 && kind != 1 && kind != 2 && kind != 3 && kind != 9 { return false; }
    let limit = if kind == 0 { 153 } else { 159 };
    if trk > limit && img[255] == 0 { return false; } // その先はオーバートラックの印があるときだけ
    return img[1 + trk] != 0;
}

// 種類ごとの 1 トラックのセクタ数とセクタ長コード (N)。知らない種類は 0。
fn dim_geometry(kind: u8) -> i32, i32 {
    if kind == 0 { return 8, 3; }               // 2HD  1024 * 8
    if kind == 1 || kind == 3 { return 9, 3; }  // 2HS / 2HDE  1024 * 9
    if kind == 2 { return 15, 2; }              // 2HC  512 * 15
    if kind == 9 { return 18, 2; }              // 2HQ  512 * 18
    return 0, 0;
}

// セクタの位置。0 はその ID のセクタが無いことを表す。
fn dim_pos(kind: u8, c: i32, h: i32, r: i32, n: i32) -> i64 {
    let sectors, size_code = dim_geometry(kind);
    var hh = h;
    var rr = r;
    if kind == 1 && rr > 9 { rr -= 9; } // 2HS は先頭以外のセクタ番号に 9 を足して記録する
    if kind == 3 { hh &= 1; }           // 2HDE はヘッド番号に 0x80 を立てて記録する
    if sectors == 0 || n != size_code { return 0; }
    if c < 0 || c > 84 || hh < 0 || hh > 1 || rr < 1 || rr > sectors { return 0; }
    let sector_bytes: i64 = if size_code == 2 { 512 } else { 1024 };
    return sector_bytes * sectors * (c * 2 + hh) + (rr - 1) * sector_bytes + DIM_HEADER;
}

// 0 始まりのセクタ番号 r の次。トラックの終わりで先頭へ戻る。
fn dim_next(kind: u8, r: i32) -> i32 {
    let sectors, _ = dim_geometry(kind);
    if sectors == 0 { return r; }
    if kind == 0 { return (r + 1) & 7; }
    let at = if kind == 1 && r > 8 { r - 9 } else { r };
    return (at + 1) % sectors;
}

// ---------------------------------------------------------------
// D88: ヘッダにトラックごとの位置の表があり、各セクタは 16 バイトのヘッダとデータからなる
// ---------------------------------------------------------------

fn le16(img: const u8[:], at: i64) -> i64 {
    let lo: i64 = img[at];
    let hi: i64 = img[at + 1];
    return lo | (hi << 8);
}

fn le32(img: const u8[:], at: i64) -> i64 {
    return le16(img, at) | (le16(img, at + 2) << 16);
}

// トラックの先頭セクタヘッダの位置。
fn d88_track_ptr(img: const u8[:], trk: i32) -> i64, bool {
    if trk < 0 || trk > D88_LAST_TRACK || img.len < D88_HEADER { return 0, false; }
    let disk_size = le32(img, 28);
    let ptr = le32(img, 32 + trk * 4);
    if ptr < D88_HEADER || ptr >= disk_size || ptr >= img.len { return 0, false; }
    return ptr, true;
}

// top から始まるトラックの中で ID が合うセクタを探す。
// データの位置、データの長さ、次のセクタヘッダの位置 (最後のセクタなら top) を返す。
fn d88_match(img: const u8[:], top: i64, c: i32, h: i32, r: i32, n: i32) -> i64, i64, i64, bool {
    var p = top;
    var count: i64 = 1;
    var s: i64 = 0;
    while s < count {
        if p + 16 > img.len { break; }
        if s == 0 { count = le16(img, p + 4); } // トラックのセクタ数は各ヘッダに入っている
        let size = le16(img, p + 14);
        if count <= 0 || p + 16 + size > img.len { break; }
        let next = p + 16 + size;
        if img[p] == (c & 0xFF) && img[p + 1] == (h & 0xFF) && img[p + 2] == (r & 0xFF) && img[p + 3] == (n & 0xFF) {
            return p + 16, size, if s + 1 >= count { top } else { next }, true;
        }
        p = next;
        s += 1;
    }
    return 0, 0, 0, false;
}

// ---------------------------------------------------------------
// FDC から見たドライブ
// ---------------------------------------------------------------

// ヘッドを trk へ動かす。イメージにそのトラックが無ければ false。
fn fd_seek(drive: i32, trk: i32) -> bool {
    if !fd_loaded(drive) { return false; }
    let img = fd_image(drive);
    let d .= g_disk.fd[drive];
    match d.kind {
        Empty => { return false; },
        Xdf => {
            if trk < 0 || trk > XDF_LAST_TRACK { return false; }
            if d.trk != trk { d.cur = 0; }
        },
        Dim => {
            if !dim_track_ok(img, trk) { return false; }
            if d.trk != trk { d.cur = 0; }
        },
        D88 => {
            let ptr, ok = d88_track_ptr(img, trk);
            if !ok { return false; }
            if d.d88_top != ptr {
                d.d88_top = ptr as u32;
                d.d88_cur = ptr as u32;
            }
        },
    }
    d.trk = trk;
    return true;
}

// ID が (c, h, r, n) のセクタを探し、イメージの中の位置とバイト数を返す。
// 見つかれば READ ID の位置を次のセクタへ進める。バイト数 0 は見つからなかったことを表す。
fn fd_locate(drive: i32, trk: i32, c: i32, h: i32, r: i32, n: i32) -> i64, i64 {
    if !fd_seek(drive, trk) { return 0, 0; }
    let img = fd_image(drive);
    let d .= g_disk.fd[drive];
    match d.kind {
        Empty => { return 0, 0; },
        Xdf => {
            if ((c << 1) + (h & 1)) != trk { return 0, 0; }
            if r < 1 || r > 8 || n != 3 || (h != 0 && h != 1) { return 0, 0; }
            d.cur = r & 7;
            return ((trk as i64) * 8 + (r - 1)) * 1024, 1024;
        },
        Dim => {
            if ((c << 1) + (h & 1)) != trk { return 0, 0; }
            let at = dim_pos(img[0], c, h, r, n);
            let bytes: i64 = if n == 2 { 512 } else { 1024 };
            if at <= 0 || at + bytes > img.len { return 0, 0; }
            d.cur = dim_next(img[0], r - 1);
            return at, bytes;
        },
        D88 => {
            let at, size, next, ok = d88_match(img, d.d88_top, c, h, r, n);
            if !ok { return 0, 0; }
            d.d88_cur = next as u32;
            let wanted: i64 = if n > 0 && n < 16 { 128 << n } else { 1024 };
            return at, min(wanted, size);
        },
    }
}

// 1 セクタを dst の先頭へ読む。dst より長いセクタは dst の長さまで。
fn fd_read(drive: i32, trk: i32, c: i32, h: i32, r: i32, n: i32, dst: u8[:]) -> bool {
    let at, bytes = fd_locate(drive, trk, c, h, r, n);
    if bytes == 0 { return false; }
    let count = min(bytes, dst.len);
    copy_into(dst[..count], fd_image(drive)[at..at + count]);
    return true;
}

// src の先頭から 1 セクタを書く。イメージはメモリの中だけで変わる。
fn fd_write(drive: i32, trk: i32, c: i32, h: i32, r: i32, n: i32, src: const u8[:]) -> bool {
    let at, bytes = fd_locate(drive, trk, c, h, r, n);
    if bytes == 0 { return false; }
    let count = min(bytes, src.len);
    note_write(drive, at, count);
    copy_into(fd_image(drive)[at..at + count], src[..count]);
    return true;
}

// READ ID が返す、ヘッドの下に次に来るセクタの ID (C, H, R, N)。
fn fd_current_id(drive: i32) -> bool, u8, u8, u8, u8 {
    if !fd_loaded(drive) { return false, 0, 0, 0, 0; }
    let img = fd_image(drive);
    let d .= g_disk.fd[drive];
    let cyl = (d.trk >> 1) as! u8;
    let head = d.trk & 1;
    let sector = d.cur + 1;
    match d.kind {
        Empty => { return false, 0, 0, 0, 0; },
        Xdf => {
            if d.trk < 0 || d.trk > XDF_LAST_TRACK { return false, 0, 0, 0, 0; }
            return true, cyl, head as u8, sector as! u8, 3;
        },
        Dim => {
            if !dim_track_ok(img, d.trk) { return false, 0, 0, 0, 0; }
            let kind = img[0];
            let first = d.trk == 0 && d.cur == 0; // 2HS / 2HDE でも最初のセクタだけは 2HD と同じ ID
            if kind == 1 && !first { return true, cyl, head as u8, (sector + 9) as! u8, 3; }
            if kind == 3 && !first { return true, cyl, (head + 0x80) as u8, sector as! u8, 3; }
            if kind == 2 || kind == 9 { return true, cyl, head as u8, sector as! u8, 2; }
            return true, cyl, head as u8, sector as! u8, 3;
        },
        D88 => {
            let p: i64 = d.d88_cur;
            if p + 4 > img.len { return false, 0, 0, 0, 0; }
            return true, img[p], img[p + 1], img[p + 2], img[p + 3];
        },
    }
}

// ---------------------------------------------------------------
// チェックポイント
// ---------------------------------------------------------------

let ::DISK_IMAGES = 3; // FD0, FD1, HDD の順

// 書き込みの取り消し帳。先読み (x68k_ahead) の間だけ付け、書く前の中身を残しておく。
// 先読みを終えたら新しい順に書き戻し、イメージを先読みの前と同じにする。
struct UndoEntry { which: i64 = 0, at: i64 = 0, len: i64 = 0 }
var g_undo_on = false;
var g_undo: UndoEntry[>..] = [];
var g_undo_bytes: u8[>..] = [];

fn undo_begin() {
    g_undo.clear();
    g_undo_bytes.clear();
    g_undo_on = true;
}

fn note_write(which: i64, at: i64, len: i64) {
    if !g_undo_on { return; }
    g_undo.push(UndoEntry { which: which, at: at, len: len });
    g_undo_bytes.append(image(which)[at..at + len]);
}

// 付けた書き込みを新しい順に戻して、帳を閉じる。
fn undo_rollback() {
    var end = g_undo_bytes.len;
    var i = g_undo.len;
    while i > 0 {
        i -= 1;
        let e = g_undo[i];
        copy_into(image(e.which)[e.at..e.at + e.len], g_undo_bytes[end - e.len..end]);
        end -= e.len;
    }
    g_undo.clear();
    g_undo_bytes.clear();
    g_undo_on = false;
}

fn image(which: i64) -> u8[:] {
    if which == 0 { return g_fd0[..]; }
    if which == 1 { return g_fd1[..]; }
    return g_hdd[..];
}

fn image_bytes(which: i64) -> i64 {
    return image(which).len;
}

// 保存してあった状態とイメージの長さが、この実装の取りうる形かどうか。
fn state_ok(s: DiskState&, bytes: i64[DISK_IMAGES]) -> bool {
    for i in 2 {
        let d .= s.fd[i];
        let len: i64 = d.len;
        match d.kind {
            Empty => { if len != 0 || bytes[i] != 0 { return false; } },
            Xdf => { if len <= 0 || len > FDD_XDF_BYTES || bytes[i] != FDD_XDF_BYTES { return false; } },
            D88 => { if len < D88_HEADER || len > FDD_MAX_IMAGE || bytes[i] != len { return false; } },
            Dim => { if len < DIM_HEADER || len > FDD_MAX_IMAGE || bytes[i] != len { return false; } },
        }
        if d.trk < -1 || d.trk > DIM_LAST_TRACK || d.cur < 0 || d.cur > 255 { return false; }
        if d.d88_top > len || d.d88_cur > len { return false; }
        if d.delay < 0 || d.delay > MEDIA_DELAY_FRAMES { return false; }
    }
    return bytes[2] >= 0 && bytes[2] <= HDD_MAX_BYTES;
}

// 保存してあった状態とイメージに入れ替える。state_ok を通したものだけを渡すこと。
fn restore(s: DiskState&, fd0: const u8[:], fd1: const u8[:], hdd: const u8[:]) {
    replace(g_fd0, fd0);
    replace(g_fd1, fd1);
    replace(g_hdd, hdd);
    g_disk = s;
    // イメージはメモリから戻したので、ホストのファイルとはもう対応しない。
    forget_paths();
}
