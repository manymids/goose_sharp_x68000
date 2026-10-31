#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include "x68k_config.h"

static int enabled;
static int values[3];
static char paths[4][MAX_PATH];
static char config_path[MAX_PATH];
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

int c_gui_settings_set_path(int key, const uint8_t *path, int len) {
    char relative[MAX_PATH], absolute[MAX_PATH];
    int n = 0;
    DWORD count;
    if (key < 0 || key >= 4 || !path || len < 0) return 0;
    while (n < len && path[n]) {
        if (n >= MAX_PATH-1 || path[n] == '\r' || path[n] == '\n') return 0;
        relative[n] = (char)path[n]; n++;
    }
    relative[n] = 0;
    if (!n) {
        if (key == GUI_BIOS) return 0;
        paths[key][0] = 0;
        return 1;
    }
    count = GetFullPathNameA(relative, MAX_PATH, absolute, NULL);
    if (!count || count >= MAX_PATH) return 0;
    memcpy(paths[key], absolute, count+1);
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

static int read_int(const char *key, int fallback) {
    char text[64], *end;
    long n;
    DWORD size = GetPrivateProfileStringA("gui", key, "", text, sizeof(text), config_path);
    if (!size || size >= sizeof(text)-1) return fallback;
    errno = 0;
    n = strtol(text, &end, 10);
    while (*end == ' ' || *end == '\t') end++;
    if (errno || *end || n < 0 || n > 100000) return fallback;
    return (int)n;
}

void c_gui_settings_open(int allow_file) {
    int i;
    DWORD n;
    enabled = 0;
    memset(paths, 0, sizeof(paths));
    values[GUI_CLOCK] = 10; values[GUI_SCALE] = 1; values[GUI_WIDTH] = 768;
    c_gui_settings_set_path(GUI_BIOS, (const uint8_t *)".\\keropi", 8);
    config_path[0] = 0;
    if (!allow_file) return; /* ARCL must not even consult the GUI file. */
    n = GetFullPathNameA("arcl_windows_x68k_goose.ini", MAX_PATH, config_path, NULL);
    if (!n || n >= MAX_PATH) { config_path[0] = 0; return; }
    enabled = 1;
    if (read_int("version", 1) != 1) return;
    for (i = 0; i < 3; i++) c_gui_settings_set_int(i, read_int(int_keys[i], values[i]));
    for (i = 0; i < 4; i++) {
        char path[MAX_PATH];
        n = GetPrivateProfileStringA("gui", path_keys[i], "", path, MAX_PATH, config_path);
        if (n < MAX_PATH-1) c_gui_settings_set_path(i, (const uint8_t *)path, (int)n);
    }
}

int c_gui_settings_save(void) {
    char temp[MAX_PATH+40];
    FILE *file;
    int i, ok;
    if (!enabled) return 1;
    snprintf(temp, sizeof(temp), "%s.tmp-%lu", config_path, (unsigned long)GetCurrentProcessId());
    file = fopen(temp, "wb");
    if (!file) return 0;
    ok = fprintf(file, "[gui]\r\nversion=1\r\n") >= 0;
    for (i = 0; i < 3; i++) if (fprintf(file, "%s=%d\r\n", int_keys[i], values[i]) < 0) ok = 0;
    for (i = 0; i < 4; i++) if (fprintf(file, "%s=%s\r\n", path_keys[i], paths[i]) < 0) ok = 0;
    if (fflush(file) != 0) ok = 0;
    if (fclose(file) != 0) ok = 0;
    if (ok) ok = MoveFileExA(temp, config_path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
    if (!ok) DeleteFileA(temp); /* Only this process's staging file. */
    return ok;
}
