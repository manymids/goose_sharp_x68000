// Launch preferences are host settings, separate from machine checkpoints.
import std;
import os;
import .x68k_bridge;
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

fn gui_mount_saved_media() {
    for key: i32 in 1..4 {
        var path = gui_settings_path(key);
        if path.len == 0 { continue; }
        path.push(0);
        var ok: i32 = 0;
        if key == GUI_HDD { ok = c_hdd_load_file(0, path[0], path.len as i32); }
        else { ok = c_fdd_load_file(key - 1, path[0], path.len as i32); }
        if ok == 0 {
            write_stderr(str("warning: saved disk could not be loaded: ", path[0..path.len-1], "\n"));
        }
    }
}
