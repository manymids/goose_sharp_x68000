// 先読み: 機械の写しを別スレッドで先へ進め、結果だけを持ち帰る。本体の機械には触らない。
//
// 写しはエミュレータの構造体をそのまま thread_spawn の引数に渡して作る。ワーカーは別のプログラム
// として動き、使うグローバル (RAM、ROM、ディスクイメージ) は起動時の写しを持つので、本体の状態と
// 混ざることはない。emu::run_frame はホスト (画面、音声出力) に触らないように作ってある。
// 写しを何本も作れば、入力の違う試行を並行して走らせられる。

import std;
import .x68k_emu;
import .x68k_input;
import .x68k_ppu;
import .m68k_cpu;
import .x68k_ram;
import .x68k_rom;
import .x68k_disk;
namespace ahead;

let ::AHEAD_MAX_VARIANTS = 8;
let ::AHEAD_MAX_FRAMES = 3600;
let AHEAD_MAX_KEYS = 8;
let FB_PIXELS = 393216;

// 写し 1 本ぶんの指示。押しっぱなしにするキーとジョイパッドのボタン。
struct Job {
    frames: i64 = 0,
    keys: i32[AHEAD_MAX_KEYS] = [-1; AHEAD_MAX_KEYS],
    key_count: i32 = 0,
    buttons: u8 = 0,         // ポート 1 のボタンのビット (input::joy_mask の値の和)
}
type ::AheadJob = ahead::Job;

// 写しを進めた結果。画面はまるごと持ち帰る (1.5 MB)。
struct Result {
    variant: i64 = 0,
    frame: i64 = 0,          // 進めたあとのフレーム番号
    hit_break: bool = false, // ブレークポイントで止まった
    pc: u32 = 0,
    sr: u16 = 0,
    d: u32[8] = [0; 8],
    a: u32[8] = [0; 8],
    screen_w: i32 = 0,
    screen_h: i32 = 0,
    audio_peak: i32 = 0,     // 進めた間に出た音の最大の振幅
    fb: u32[FB_PIXELS] = [0; FB_PIXELS],
}
type ::AheadResult = ahead::Result;

thread_fn worker(start: X68kEmulator, job: Job, variant: i64) {
    var emu = start;
    for i in job.key_count { input::key(emu, job.keys[i], true); }
    if job.buttons != 0 { input::joy(emu, 0, job.buttons, true); }
    var peak: i32 = 0;
    emu.hit_break = false;
    for _ in job.frames {
        emu.run_frame();
        for k in emu.audio_samples * 2 { peak = max(peak, abs(emu.audio[k] as i32)); }
        emu.audio_samples = 0;
        if emu.hit_break { break; }
    }
    var r = Result { variant: variant, frame: emu.total_frames, hit_break: emu.hit_break, pc: emu.cpu.pc, sr: emu.cpu.sr,
        d: emu.cpu.d, screen_w: emu.ppu.screen_w, screen_h: emu.ppu.screen_h, audio_peak: peak, .. };
    r.a = emu.cpu.a;   // A7 は今のモードのスタックポインタ (使っていない側は usp / ssp にある)
    r.fb = emu.ppu.fb;
    qput(r);
}

// jobs の写しをそれぞれ別スレッドで進め、結果を jobs と同じ順で out に入れる。
fn run(emu: X68kEmulator&, jobs: const Job[:], out: Result[>..]&) {
    var ids: i64[>..] = [];
    for i in jobs.len { ids.push(thread_spawn(worker, emu, jobs[i], i)); }
    // 届いた順に受け取り、あとで並べ直す
    var got: Result[>..] = [];
    for _ in jobs.len { got.push(qget<Result>()); }
    for id in ids { thread_wait(id); }
    for i in jobs.len {
        for r in got {
            if r.variant == i { out.push(r); }
        }
    }
}

// ---------------------------------------------------------------
// 見せるための先読み (ウィンドウの入力遅れを減らす)
// ---------------------------------------------------------------
//
// 本当のフレームを進めて音を出したあとで、同じスレッドで機械を frames フレーム先まで進め、
// その画面を出してから元へ戻す。今押しているキーがそのまま続くと見なした未来を見せるので、
// ゲームが入力を画面に出すまでの遅れがその分だけ縮んで見える。先読みの間の音は捨てる。
// 戻すのは run_frame が変えうるものすべて: エミュレータの構造体、RAM、SRAM、ディスクの状態と
// イメージ (イメージは書き込みの取り消し帳で戻す)。

struct Saved {
    emu: X68kEmulator = X68kEmulator {},
    sram: u8[SRAM_BYTES] = [0; SRAM_BYTES],
    sram_we: i32 = 0,
    disk: DiskState = DiskState {},
}
var g_saved = Saved {};
var g_saved_ram: u8[>..] = [];

fn save(emu: X68kEmulator&) {
    g_saved.emu = emu;
    g_saved.sram = g_sram;
    g_saved.sram_we = x68k_sram_write_enable();
    g_saved.disk = g_disk;
    g_saved_ram.clear();
    g_saved_ram.append(g_x68k_ram[..x68k_ram_limit()]);
    disk::undo_begin();
}

fn restore(emu: X68kEmulator&) {
    disk::undo_rollback();
    copy_into(g_x68k_ram[..g_saved_ram.len], g_saved_ram[..]);
    g_disk = g_saved.disk;
    x68k_sram_set_write_enable(g_saved.sram_we);
    g_sram = g_saved.sram;
    emu = g_saved.emu;
}

// emu を frames フレーム先まで進める。画面を出したら必ず end で元に戻すこと。
// ブレークポイントに当たればそこで止める。end のあとの emu は begin の前とまったく同じ。
fn begin(emu: X68kEmulator&, frames: i32) -> bool {
    if frames < 1 || !emu.active() { return false; }
    save(emu);
    emu.hit_break = false;
    for _ in frames {
        emu.run_frame();
        emu.audio_samples = 0;
        if emu.hit_break { break; }
    }
    return true;
}

fn end(emu: X68kEmulator&) {
    restore(emu);
}
