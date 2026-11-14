// Launch preferences are host settings, separate from machine checkpoints.
import os;
import .x68k_bridge;
import .x68k_disk;
let GUI_CLOCK = 0;
let GUI_SCALE = 1;
let GUI_WIDTH = 2;
let GUI_BIOS = 0;
let GUI_FD0 = 1;
let GUI_FD1 = 2;
let GUI_HDD = 3;

fn gui_settings_path(key: i32) -> u8[>..] {
    var buffer: u8[520] = [0; 520];
    let n = c_gui_settings_path(key, buffer[0], 520);
    var path: u8[>..] = [];
    if n > 0 { path.append(buffer[0..n]); }
    return path;
}

fn mount_saved(key: i32, path: u8[>..]&) {
    if path.len == 0 { return; }
    let ok = if key == GUI_HDD { disk::hdd_load(path[..]) } else { disk::fd_load(key - GUI_FD0, path[..]) };
    if !ok { write_stderr(str("warning: saved disk could not be loaded: ", path, "\n")); }
}

// 前回の終了時に入っていたディスクを、空のドライブへ入れ直す。
// 読めなかったものは設定からも消え、次回は試さない。
fn gui_mount_saved_media() {
    var fd0 = gui_settings_path(GUI_FD0);
    var fd1 = gui_settings_path(GUI_FD1);
    var hdd = gui_settings_path(GUI_HDD);
    disk::power_on();
    mount_saved(GUI_FD0, fd0);
    mount_saved(GUI_FD1, fd1);
    mount_saved(GUI_HDD, hdd);
}
