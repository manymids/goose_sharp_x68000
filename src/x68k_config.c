#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include "x68k_config.h"
#include "x68k_path.h"

/* The INI file is UTF-8: "key=value" lines under one [gui] heading. It is read and written
 * here rather than with GetPrivateProfileString, which would treat the bytes as ANSI. */
#define INI_MAX_BYTES 16384

static int enabled;
static int values[3];
static char paths[4][PATH_CAP];
static wchar_t config_path[MAX_PATH];
static char ini_text[INI_MAX_BYTES];
static const char *path_keys[] = { "bios_dir", "fd0", "fd1", "hdd" };
static const char *int_keys[] = { "clock_mhz", "scale", "screen_width" };

int c_gui_settings_int(int key) { return key >= 0 && key < 3 ? values[key] : 0; }

int c_gui_settings_set_int(int key, int value) {
    if (key == GUI_CLOCK) {
        const int clocks[] = { X68K_CPU_CLOCK_LIST };
        int i, found = 0;
        for (i = 0; i < sizeof(clocks)/sizeof(clocks[0]); i++) if (clocks[i] == value) found = 1;
        if (!found) return 0;
    } else if (key == GUI_SCALE) {
        if (value != 1 && value != 2) return 0;
    } else if (key == GUI_WIDTH) {
        if (value != 512 && value != 768) return 0;
    } else return 0;
    values[key] = value;
    return 1;
}

/* Stores the absolute form of a UTF-8 path. An empty path clears the entry. */
int c_gui_settings_set_path(int key, const uint8_t *path, int len) {
    char relative[PATH_CAP], absolute[PATH_CAP];
    wchar_t wide[MAX_PATH], full[MAX_PATH];
    int n = 0;
    DWORD count;
    if (key < 0 || key >= 4 || !path || len < 0) return 0;
    while (n < len && path[n]) {
        if (n >= PATH_CAP-1 || path[n] == '\r' || path[n] == '\n') return 0;
        relative[n] = (char)path[n]; n++;
    }
    relative[n] = 0;
    if (!n) {
        if (key == GUI_BIOS) return 0;
        paths[key][0] = 0;
        return 1;
    }
    if (!path_to_wide(relative, wide, MAX_PATH)) return 0;
    count = GetFullPathNameW(wide, MAX_PATH, full, NULL);
    if (!count || count >= MAX_PATH) return 0;
    if (!path_from_wide(full, absolute, PATH_CAP)) return 0;
    memcpy(paths[key], absolute, strlen(absolute)+1);
    return 1;
}

int c_gui_settings_path(int key, uint8_t *out, int cap) {
    int n;
    if (key < 0 || key >= 4 || !out || cap < 1) return 0;
    out[0] = 0;
    n = (int)strlen(paths[key]);
    if (n >= cap) return 0;
    memcpy(out, paths[key], n+1);
    return n;
}

/* The value of "key=" in the loaded INI text, without the line end. Returns its length,
 * or -1 if the key is absent or the value does not fit. */
static int ini_value(const char *key, char *out, int cap) {
    size_t klen = strlen(key);
    const char *line = ini_text;
    while (*line) {
        const char *end = line + strcspn(line, "\r\n");
        if ((size_t)(end - line) > klen && !memcmp(line, key, klen) && line[klen] == '=') {
            int n = (int)(end - line - klen - 1);
            if (n >= cap) return -1;
            memcpy(out, line + klen + 1, (size_t)n);
            out[n] = 0;
            return n;
        }
        line = end + strspn(end, "\r\n");
    }
    return -1;
}

static int read_int(const char *key, int fallback) {
    char text[64], *end;
    long n;
    if (ini_value(key, text, sizeof(text)) <= 0) return fallback;
    errno = 0;
    n = strtol(text, &end, 10);
    while (*end == ' ' || *end == '\t') end++;
    if (errno || *end || n < 0 || n > 100000) return fallback;
    return (int)n;
}

/* Files written before the INI became UTF-8 hold paths in the ANSI code page. Such a path
 * is not valid UTF-8 as soon as it has a non-ASCII character, and is converted here. */
static void path_from_legacy(char *path, int cap) {
    wchar_t wide[MAX_PATH];
    if (path_to_wide(path, wide, MAX_PATH)) return;
    if (!MultiByteToWideChar(CP_ACP, 0, path, -1, wide, MAX_PATH) || !path_from_wide(wide, path, cap)) path[0] = 0;
}

void c_gui_settings_open(int allow_file) {
    int i;
    DWORD n;
    FILE *file;
    size_t got;
    enabled = 0;
    memset(paths, 0, sizeof(paths));
    values[GUI_CLOCK] = 10; values[GUI_SCALE] = 1; values[GUI_WIDTH] = 768;
    c_gui_settings_set_path(GUI_BIOS, (const uint8_t *)".\\keropi", 8);
    config_path[0] = 0;
    ini_text[0] = 0;
    if (!allow_file) return; /* ARCL must not even consult the GUI file. */
    n = GetFullPathNameW(L"arcl_windows_x68k_goose.ini", MAX_PATH, config_path, NULL);
    if (!n || n >= MAX_PATH) { config_path[0] = 0; return; }
    enabled = 1;
    file = _wfopen(config_path, L"rb");
    if (!file) return; /* First run: the defaults stand. */
    got = fread(ini_text, 1, sizeof(ini_text)-1, file);
    fclose(file);
    ini_text[got] = 0;
    if (read_int("version", 1) != 1) return;
    for (i = 0; i < 3; i++) c_gui_settings_set_int(i, read_int(int_keys[i], values[i]));
    for (i = 0; i < 4; i++) {
        char path[PATH_CAP];
        if (ini_value(path_keys[i], path, PATH_CAP) < 0) continue;
        path_from_legacy(path, PATH_CAP);
        c_gui_settings_set_path(i, (const uint8_t *)path, (int)strlen(path));
    }
}

int c_gui_settings_save(void) {
    wchar_t temp[MAX_PATH+40];
    FILE *file;
    int i, ok;
    if (!enabled) return 1;
    swprintf(temp, MAX_PATH+40, L"%ls.tmp-%lu", config_path, (unsigned long)GetCurrentProcessId());
    file = _wfopen(temp, L"wb");
    if (!file) return 0;
    ok = fprintf(file, "[gui]\r\nversion=1\r\n") >= 0;
    for (i = 0; i < 3; i++) if (fprintf(file, "%s=%d\r\n", int_keys[i], values[i]) < 0) ok = 0;
    for (i = 0; i < 4; i++) if (fprintf(file, "%s=%s\r\n", path_keys[i], paths[i]) < 0) ok = 0;
    if (fflush(file) != 0) ok = 0;
    if (fclose(file) != 0) ok = 0;
    if (ok) ok = MoveFileExW(temp, config_path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
    if (!ok) DeleteFileW(temp); /* Only this process's staging file. */
    return ok;
}
