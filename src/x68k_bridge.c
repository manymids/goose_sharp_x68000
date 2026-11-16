#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include <commdlg.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "x68k_bridge.h"
#include "x68k_path.h"

/* Palette, TVRAM and GVRAM live in the Goose emulator struct, which is a
 * local. 1MB is not enough once those arrays are there. */
#ifdef _MSC_VER
#pragma comment(linker, "/STACK:8388608")
#endif

static char g_io_acc[65536];
static int g_io_acc_len = 0;
static int g_io_eof = 0;

static void io_acc_append(const char *src, int n) {
    if (n <= 0) return;
    if (g_io_acc_len + n > (int)sizeof(g_io_acc)) {
        int drop = g_io_acc_len + n - (int)sizeof(g_io_acc);
        if (drop >= g_io_acc_len) {
            if (n > (int)sizeof(g_io_acc)) {
                src += n - (int)sizeof(g_io_acc);
                n = (int)sizeof(g_io_acc);
            }
            g_io_acc_len = 0;
        } else {
            memmove(g_io_acc, g_io_acc + drop, (size_t)(g_io_acc_len - drop));
            g_io_acc_len -= drop;
        }
    }
    memcpy(g_io_acc + g_io_acc_len, src, (size_t)n);
    g_io_acc_len += n;
}

/* Returns the line length, or -1 when no newline is buffered yet. */
static int io_take_line(char *out, int max_len) {
    int i;
    for (i = 0; i < g_io_acc_len; i++) {
        int n;
        int rest;
        if (g_io_acc[i] != '\n') continue;
        n = i;
        if (n > 0 && g_io_acc[n - 1] == '\r') n--;
        if (n >= max_len) n = max_len - 1;
        memcpy(out, g_io_acc, (size_t)n);
        out[n] = '\0';
        rest = g_io_acc_len - (i + 1);
        if (rest > 0) memmove(g_io_acc, g_io_acc + i + 1, (size_t)rest);
        g_io_acc_len = rest;
        return n;
    }
    return -1;
}

int c_io_poll_line(void *out_buf, int max_len, int wait_ms) {
    char *out = (char *)out_buf;
    HANDLE h;
    char tmp[4096];
    DWORD n = 0;
    DWORD avail = 0;
    int ready;
    if (!out || max_len < 2) return -1;
    ready = io_take_line(out, max_len);
    if (ready >= 0) return ready;
    if (g_io_eof) return -1;

    h = GetStdHandle(STD_INPUT_HANDLE);
    if (h == NULL || h == INVALID_HANDLE_VALUE) return -1;

    if (!PeekNamedPipe(h, NULL, 0, NULL, &avail, NULL)) {
        DWORD err = GetLastError();
        if (err == ERROR_BROKEN_PIPE || err == ERROR_INVALID_HANDLE) {
            g_io_eof = 1;
            return -1;
        }
        if (WaitForSingleObject(h, wait_ms > 0 ? (DWORD)wait_ms : 0) != WAIT_OBJECT_0)
            return 0;
        if (!ReadFile(h, tmp, sizeof(tmp), &n, NULL) || n == 0) {
            g_io_eof = 1;
            return -1;
        }
        io_acc_append(tmp, (int)n);
    } else {
        if (avail == 0 && wait_ms > 0) {
            Sleep((DWORD)wait_ms);
            avail = 0;
            if (!PeekNamedPipe(h, NULL, 0, NULL, &avail, NULL)) {
                g_io_eof = 1;
                return -1;
            }
        }
        if (avail == 0) return 0;
        if (avail > sizeof(tmp)) avail = sizeof(tmp);
        if (!ReadFile(h, tmp, avail, &n, NULL)) {
            g_io_eof = 1;
            return -1;
        }
        if (n == 0) {
            g_io_eof = 1;
            return -1;
        }
        io_acc_append(tmp, (int)n);
    }
    ready = io_take_line(out, max_len);
    return ready >= 0 ? ready : 0;
}

void c_io_write_line(const void *data, int len) {
    fwrite(data, 1, len, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}


int64_t c_host_local_seconds(void) {
    time_t now = time(NULL);
    struct tm local;
    if (localtime_s(&local, &now) != 0) return (int64_t)now;
    /* _mkgmtime reads the local fields as UTC: seconds of the local calendar. */
    return (int64_t)_mkgmtime(&local);
}

static void bind_path(const uint8_t *p, int len, char *dst, int cap) {
    int n;
    if (!dst || cap < 1) return;
    if (len < 0) len = 0;
    if (!p) len = 0;
    n = len;
    if (n >= cap) n = cap - 1;
    if (n > 0) memcpy(dst, p, (size_t)n);
    dst[n] = 0;
}

// Reads up to max_len bytes from the start of a file.
static int c_file_read(const uint8_t *path, int path_len, void *out_buf, int max_len) {
    char pbuf[PATH_CAP];
    bind_path(path, path_len, pbuf, PATH_CAP);
    if (pbuf[0] == 0 || !out_buf || max_len <= 0) return 0;
    FILE *fp = path_fopen(pbuf, L"rb");
    if (!fp) return 0;
    size_t n = fread(out_buf, 1, (size_t)max_len, fp);
    fclose(fp);
    return (int)n;
}

// Memory Buffer management
#define RAM_MAX    (12 * 1024 * 1024)  // px68k accepts 1..12 MB
static int32_t g_ram_bytes = 2 * 1024 * 1024;
static int32_t *g_ram_limit_slot = NULL;
static int g_mem_ready = 0;
static uint64_t g_machine_epoch = 0;
static uint64_t g_machine_epoch_next = 0;
static int g_init_fail_after = -1;

static void *host_calloc(size_t n, size_t size) {
    if (g_init_fail_after == 0) { g_init_fail_after = -1; return NULL; }
    if (g_init_fail_after > 0) g_init_fail_after--;
    return calloc(n, size);
}
static char g_sys_dir[PATH_CAP];
#define CGROM_SIZE (768 * 1024)        // 768KB
#define IPL_SIZE   (128 * 1024)        // 128KB
#define SRAM_SIZE  (16 * 1024)         // 16KB
#define FB_MAX_W   768
#define FB_MAX_H   512
#define FB_MAX_PIXELS (FB_MAX_W * FB_MAX_H)

static uint8_t *g_ram = NULL;
static int g_ram_bound = 0;
static uint8_t *g_cgrom = NULL;
static int g_cgrom_bound = 0;
static uint8_t *g_iplrom = NULL;
static int g_ipl_bound = 0;
static uint8_t *g_sram = NULL;
static int g_sram_bound = 0;
static uint32_t *g_fb = NULL;
static int g_fb_bound = 0;
static int g_src_w = 768; // Default to 768x512 standard X68000 mode
static int g_src_h = 512;


// Helper to find and load ROM file with multiple candidate directories
static int load_rom_file(const char *filename, const char *sys_dir, void *buf, int size) {
    char path[PATH_CAP];
    // 1. Try directly in sys_dir
    if (sys_dir && strlen(sys_dir) > 0) {
        snprintf(path, sizeof(path), "%s/%s", sys_dir, filename);
        if (c_file_read((const uint8_t *)path, (int)strlen(path), buf, size) == size) return 1;

        // 2. Try sys_dir/keropi
        snprintf(path, sizeof(path), "%s/keropi/%s", sys_dir, filename);
        if (c_file_read((const uint8_t *)path, (int)strlen(path), buf, size) == size) return 1;
    }


    return 0;
}

static void stamp_sram_ram_size(void) {
    if (!g_sram) return;
    uint32_t ram = (uint32_t)g_ram_bytes;
    g_sram[8]  = (uint8_t)(ram >> 24);
    g_sram[9]  = (uint8_t)(ram >> 16);
    g_sram[10] = (uint8_t)(ram >> 8);
    g_sram[11] = (uint8_t)ram;
}

int c_mem_set_ram_mb(int32_t mb) {
    if (mb < 1 || mb > 12) return 0;
    int32_t bytes = mb * 1024 * 1024;
    if (g_ram_bound) {
        if (bytes > g_ram_bytes && g_ram) {
            memset(g_ram + g_ram_bytes, 0, (size_t)(bytes - g_ram_bytes));
        }
    } else if (g_ram && g_ram_bytes != bytes) {
        uint8_t *n = (uint8_t *)realloc(g_ram, (size_t)bytes);
        if (!n) return 0;
        if (bytes > g_ram_bytes) memset(n + g_ram_bytes, 0, (size_t)(bytes - g_ram_bytes));
        g_ram = n;
    }
    g_ram_bytes = bytes;
    if (g_ram_limit_slot) *g_ram_limit_slot = g_ram_bytes;
    stamp_sram_ram_size();
    return 1;
}

int x68k_mem_init(X68kByteView sys_bytes) {
    char sys_dir[PATH_CAP];
    if (g_mem_ready) return 0; // Explicit destroy before a new host session.
    bind_path(sys_bytes.data, (int)sys_bytes.len, sys_dir, PATH_CAP);
    g_sys_dir[0] = '\0';
    if (sys_dir[0]) {
        strncpy(g_sys_dir, sys_dir, PATH_CAP - 1);
        g_sys_dir[PATH_CAP - 1] = '\0';
    }
    if (!g_ram) g_ram = (uint8_t *)host_calloc(1, (size_t)g_ram_bytes);
    if (!g_cgrom) g_cgrom = (uint8_t *)host_calloc(1, CGROM_SIZE);
    if (!g_iplrom) g_iplrom = (uint8_t *)host_calloc(1, IPL_SIZE);
    if (!g_sram) g_sram = (uint8_t *)host_calloc(1, SRAM_SIZE);
    if (!g_fb) g_fb = (uint32_t *)host_calloc(1, FB_MAX_PIXELS * sizeof(uint32_t));

    if (!g_ram || !g_cgrom || !g_iplrom || !g_sram || !g_fb) {
        x68k_mem_destroy();
        return 0;
    }

    // Load ROMs with fallback search
    int ipl_ok = load_rom_file("iplrom.dat", sys_dir, g_iplrom, IPL_SIZE);
    int cg_ok = load_rom_file("cgrom.dat", sys_dir, g_cgrom, CGROM_SIZE);
    if (sys_dir[0] && (!ipl_ok || !cg_ok)) {
        x68k_mem_destroy();
        return 0;
    }
    load_rom_file("sram.dat", sys_dir, g_sram, SRAM_SIZE);
    stamp_sram_ram_size();

    g_mem_ready = 1;
    return 1;
}



// Only the GUI writes sram.dat back. ARCL and headless runs leave it alone so that they replay identically.
static int g_sram_persist = 1;
void c_sram_set_persist(int enabled) { g_sram_persist = enabled != 0; }

static void save_sram_file(void) {
    if (!g_sram_persist) return;
    char path[PATH_CAP];
    FILE *f;
    if (!g_mem_ready || !g_sram || !g_sys_dir[0]) return;
    snprintf(path, sizeof(path), "%s\\sram.dat", g_sys_dir);
    f = path_fopen(path, L"wb");
    if (!f) return;
    fwrite(g_sram, 1, SRAM_SIZE, f);
    fclose(f);
}

void x68k_mem_destroy(void) {
    save_sram_file();
    // Stop publications before dropping any borrowed array or scalar view.
    g_ram_limit_slot = NULL;
    g_machine_epoch = 0;
    g_mem_ready = 0;
    if (!g_ram_bound && g_ram) free(g_ram);
    g_ram = NULL;
    g_ram_bound = 0;
    if (!g_cgrom_bound && g_cgrom) free(g_cgrom);
    g_cgrom = NULL;
    g_cgrom_bound = 0;
    if (!g_ipl_bound && g_iplrom) free(g_iplrom);
    g_iplrom = NULL;
    g_ipl_bound = 0;
    if (!g_sram_bound && g_sram) free(g_sram);
    g_sram = NULL;
    g_sram_bound = 0;
    if (!g_fb_bound && g_fb) free(g_fb);
    g_fb = NULL;
    g_fb_bound = 0;


    g_sys_dir[0] = 0;
}

int32_t c_ram_size(void) {
    return g_ram_bytes;
}

void c_ram_limit_bind(int32_t *slot) {
    g_ram_limit_slot = slot;
    if (slot) *slot = g_ram_bytes;
}

void c_ram_bind(uint8_t *ram) {
    if (!ram) return;
    if (!g_ram_bound) {
        free(g_ram);
        g_ram_bound = 1;
    }
    g_ram = ram;
}

void c_ipl_bind(uint8_t *ipl) {
    if (!ipl) return;
    if (!g_ipl_bound) {
        if (g_iplrom && g_iplrom != ipl)
            memcpy(ipl, g_iplrom, IPL_SIZE);
        free(g_iplrom);
        g_ipl_bound = 1;
    }
    g_iplrom = ipl;
}

void c_cgrom_bind(uint8_t *cgrom) {
    if (!cgrom) return;
    if (!g_cgrom_bound) {
        if (g_cgrom && g_cgrom != cgrom)
            memcpy(cgrom, g_cgrom, CGROM_SIZE);
        free(g_cgrom);
        g_cgrom_bound = 1;
    }
    g_cgrom = cgrom;
}

void c_sram_bind(uint8_t *sram) {
    if (!sram) return;
    if (!g_sram_bound) {
        if (g_sram && g_sram != sram)
            memcpy(sram, g_sram, SRAM_SIZE);
        free(g_sram);
        g_sram_bound = 1;
    }
    g_sram = sram;
}

uint8_t *c_ram_base(void) {
    return g_ram;
}

void c_fb_bind(uint32_t *fb) {
    if (!fb) return;
    if (!g_fb_bound) {
        free(g_fb);
        g_fb_bound = 1;
    }
    g_fb = fb;
}

void c_line_zero(uint16_t *grp, uint8_t *mix, uint16_t *sp, uint16_t *sp2, uint16_t *bg, uint8_t *tr) {
    if (!grp || !mix || !sp || !sp2 || !bg || !tr) return;
    memset(grp, 0, 1024 * sizeof(uint16_t));
    memset(mix, 0, 1024);
    memset(sp, 0, 1024 * sizeof(uint16_t));
    memset(sp2, 0, 1024 * sizeof(uint16_t));
    memset(bg, 0, 1040 * sizeof(uint16_t));
    memset(tr, 0, 1040);
}

static HWND g_hwnd = NULL;
static HDC g_hdc = NULL;
static int g_scale = 1;
static bool g_is_open = false;
static uint32_t g_keys = 0;
static BITMAPINFO g_bmi;
static int g_pending_cmd = 0;

/* The settings live in x68k_config.goose. The menu only notes that one changed, and which initial
 * screen width it chose; the frontend loop collects that once per frame and saves the file. */
static int g_settings_changed = 0;
static int g_menu_width = 0;

int c_gui_take_settings_changes(int32_t *width) {
    int changed = g_settings_changed;
    if (width) *width = g_menu_width;
    g_settings_changed = 0;
    g_menu_width = 0;
    return changed;
}

int c_get_scale(void) { return g_scale; }

int c_full_path(X68kByteView path_bytes, uint8_t *out, int cap) {
    char path[PATH_CAP];
    wchar_t wide[MAX_PATH], full[MAX_PATH];
    DWORD n;
    if (!out || cap < 1) return 0;
    bind_path(path_bytes.data, (int)path_bytes.len, path, PATH_CAP);
    if (!path[0] || !path_to_wide(path, wide, MAX_PATH)) return 0;
    n = GetFullPathNameW(wide, MAX_PATH, full, NULL);
    if (!n || n >= MAX_PATH || !path_from_wide(full, (char *)out, cap)) return 0;
    return (int)strlen((const char *)out);
}

int c_ansi_to_utf8(X68kByteView text, uint8_t *out, int cap) {
    char in[PATH_CAP];
    wchar_t wide[MAX_PATH];
    if (!out || cap < 1) return 0;
    bind_path(text.data, (int)text.len, in, PATH_CAP);
    if (!MultiByteToWideChar(CP_ACP, 0, in, -1, wide, MAX_PATH) || !path_from_wide(wide, (char *)out, cap)) return 0;
    return (int)strlen((const char *)out);
}

/* A disk the user picked from the menu. The images belong to the Goose side, so the menu
 * only records the request and the frontend loop collects it once per frame. */
enum { MEDIA_NONE = 0, MEDIA_FD0_INSERT, MEDIA_FD0_EJECT, MEDIA_FD1_INSERT, MEDIA_FD1_EJECT,
       MEDIA_HDD_INSERT, MEDIA_HDD_EJECT };
static int g_media_request = MEDIA_NONE;
static char g_media_path[PATH_CAP];

static void media_request(int kind, const char *path) {
    g_media_request = kind;
    strncpy(g_media_path, path ? path : "", PATH_CAP - 1);
    g_media_path[PATH_CAP - 1] = '\0';
}

int c_gui_take_media_request(uint8_t *path, int cap, int32_t *path_len) {
    int kind = g_media_request;
    int n = (int)strlen(g_media_path);
    g_media_request = MEDIA_NONE;
    if (!path || !path_len || n >= cap) return MEDIA_NONE;
    memcpy(path, g_media_path, (size_t)n + 1);
    *path_len = n;
    return kind;
}

static void win32_set_scale(int scale);

uint64_t c_machine_epoch(void) { return g_machine_epoch; }

static uint64_t machine_bind_views(const X68kHostViews *v) {
    if (!g_mem_ready || !v) return 0;
#define VIEW_OK(field, count) (v->field.data && v->field.len == (int64_t)(count))
    if (!VIEW_OK(ram, 12582912) || !VIEW_OK(ipl, IPL_SIZE) || !VIEW_OK(cgrom, CGROM_SIZE) ||
        !VIEW_OK(sram, SRAM_SIZE) || !VIEW_OK(fb, FB_MAX_PIXELS) || !v->ram_limit) return 0;
#undef VIEW_OK
    // All validation precedes registration. No allocation or callbacks here.
    if (!g_ram_bound) {
        memset(v->ram.data, 0, (size_t)v->ram.len);
        if (g_ram && g_ram != v->ram.data) memcpy(v->ram.data, g_ram, (size_t)g_ram_bytes);
    }
    c_ram_bind(v->ram.data); c_ram_limit_bind(v->ram_limit);
    c_ipl_bind(v->ipl.data); c_cgrom_bind(v->cgrom.data); c_sram_bind(v->sram.data);
    c_fb_bind(v->fb.data);
    if (++g_machine_epoch_next == 0) ++g_machine_epoch_next;
    g_machine_epoch = g_machine_epoch_next;
    return g_machine_epoch;
}

uint64_t c_machine_bind(X68kByteView ram, X68kByteView ipl, X68kByteView cgrom, X68kByteView sram,
    X68kPixelView fb, int32_t *ram_limit) {
    X68kHostViews views = {ram, ipl, cgrom, sram, fb, ram_limit};
    return machine_bind_views(&views);
}

void c_set_screen_mode(int32_t w, int32_t h) {
    if (w <= 0 || h <= 0) return;
    if (g_src_w == w && g_src_h == h && g_hwnd) return;
    g_src_w = w;
    g_src_h = h;
    if (g_hwnd) {
        memset(&g_bmi, 0, sizeof(g_bmi));
        g_bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        g_bmi.bmiHeader.biWidth = g_src_w;
        g_bmi.bmiHeader.biHeight = -g_src_h; // top-down
        g_bmi.bmiHeader.biPlanes = 1;
        g_bmi.bmiHeader.biBitCount = 32;
        g_bmi.bmiHeader.biCompression = BI_RGB;
        win32_set_scale(g_scale);
    }
}

int32_t c_get_screen_width(void) {
    return g_src_w;
}

int32_t c_get_screen_height(void) {
    return g_src_h;
}

// Keyboard input FIFO
#define KEY_BUF_SIZE 256

static uint8_t g_scancode_fifo[KEY_BUF_SIZE];
static int g_scan_head = 0;
static int g_scan_tail = 0;

static void push_scancode(uint8_t sc) {
    int next = (g_scan_head + 1) % KEY_BUF_SIZE;
    if (next != g_scan_tail) {
        g_scancode_fifo[g_scan_head] = sc;
        g_scan_head = next;
    }
}

int win32_ui_get_key_scancode(void) {
    if (g_scan_head == g_scan_tail) return -1;
    uint8_t sc = g_scancode_fifo[g_scan_tail];
    g_scan_tail = (g_scan_tail + 1) % KEY_BUF_SIZE;
    return (int)sc;
}

static uint8_t vk_to_x68k_code(WPARAM vk, LPARAM lp) {
    if (vk == VK_RETURN && (lp & 0x01000000)) return 0x4E;
    if (vk >= '0' && vk <= '9') {
        if (vk == '0') return 0x0B;
        return 0x02 + (uint8_t)(vk - '1');
    }
    if (vk >= 'A' && vk <= 'Z') {
        switch (vk) {
            case 'Q': return 0x11; case 'W': return 0x12; case 'E': return 0x13; case 'R': return 0x14;
            case 'T': return 0x15; case 'Y': return 0x16; case 'U': return 0x17; case 'I': return 0x18;
            case 'O': return 0x19; case 'P': return 0x1A;
            case 'A': return 0x1E; case 'S': return 0x1F; case 'D': return 0x20; case 'F': return 0x21;
            case 'G': return 0x22; case 'H': return 0x23; case 'J': return 0x24; case 'K': return 0x25;
            case 'L': return 0x26;
            case 'Z': return 0x2A; case 'X': return 0x2B; case 'C': return 0x2C; case 'V': return 0x2D;
            case 'B': return 0x2E; case 'N': return 0x2F; case 'M': return 0x30;
            default: return 0;
        }
    }
    switch (vk) {
        case VK_ESCAPE:     return 0x01;
        case VK_OEM_MINUS:  return 0x0C;
        case VK_OEM_7:      return 0x0D; // ^
        case VK_OEM_5:      return 0x0E; // yen / backslash key (no backslash at the end: it would join the next line)
        case VK_BACK:       return 0x0F; // Backspace
        case VK_TAB:        return 0x10;
        case VK_OEM_3:      return 0x1B; // @
        case VK_OEM_4:      return 0x1C; // [
        case VK_RETURN:     return 0x1D;
        case VK_OEM_PLUS:   return 0x27; // ;
        case VK_OEM_1:      return 0x28; // :
        case VK_OEM_6:      return 0x29; // ]
        case VK_OEM_COMMA:  return 0x31; // ,
        case VK_OEM_PERIOD: return 0x32; // .
        case VK_OEM_2:      return 0x33; // /
        case VK_SPACE:      return 0x35;
        case VK_HOME:       return 0x36;
        case VK_DELETE:     return 0x37;
        case VK_LEFT:       return 0x3B;
        case VK_UP:         return 0x3C;
        case VK_RIGHT:      return 0x3D;
        case VK_DOWN:       return 0x3E;
        case VK_DIVIDE:     return 0x40;
        case VK_MULTIPLY:   return 0x41;
        case VK_SUBTRACT:   return 0x42;
        case VK_NUMPAD7:    return 0x43;
        case VK_NUMPAD8:    return 0x44;
        case VK_NUMPAD9:    return 0x45;
        case VK_ADD:        return 0x46;
        case VK_NUMPAD4:    return 0x47;
        case VK_NUMPAD5:    return 0x48;
        case VK_NUMPAD6:    return 0x49;
        case VK_NUMPAD1:    return 0x4B;
        case VK_NUMPAD2:    return 0x4C;
        case VK_NUMPAD3:    return 0x4D;
        case VK_NUMPAD0:    return 0x4F;
        case VK_DECIMAL:    return 0x51;
        case VK_F13:        return 0x55; // XF1
        case VK_F14:        return 0x56; // XF2
        case VK_F15:        return 0x57; // XF3
        case VK_F16:        return 0x58; // XF4
        case VK_F17:        return 0x59; // XF5
        case VK_KANA:       return 0x5A;
        case VK_SHIFT:      return 0x70;
        case VK_CONTROL:    return 0x71;
        case VK_F1:         return 0x63;
        case VK_F2:         return 0x64;
        case VK_F3:         return 0x65;
        case VK_F4:         return 0x66;
        case VK_F5:         return 0x67;
        case VK_F6:         return 0x68;
        case VK_F7:         return 0x69;
        case VK_F8:         return 0x6A;
        case VK_F9:         return 0x6B;
        case VK_F10:        return 0x6C;
        default: return 0;
    }
}

/* Held host keys that also drive joy1. Cho Ren Sha 68K reads this port for start and shot.
   Bits are active-low and match arcl_joypad: up 0x01, down 0x02, left 0x04, right 0x08,
   A 0x20 (Z / Space / Enter), B 0x40 (X). Opposite directions cancel. */
static uint8_t g_hold_up, g_hold_down, g_hold_left, g_hold_right;
static uint8_t g_hold_z, g_hold_space, g_hold_enter, g_hold_x;

void c_host_joy_reset(void) {
    g_hold_up = g_hold_down = g_hold_left = g_hold_right = 0;
    g_hold_z = g_hold_space = g_hold_enter = g_hold_x = 0;
}

void c_host_key_joy(int vk, int down) {
    uint8_t *slot = NULL;
    uint8_t v = down ? 1 : 0;
    switch (vk) {
    case VK_UP: slot = &g_hold_up; break;
    case VK_DOWN: slot = &g_hold_down; break;
    case VK_LEFT: slot = &g_hold_left; break;
    case VK_RIGHT: slot = &g_hold_right; break;
    case 'Z': slot = &g_hold_z; break;
    case VK_SPACE: slot = &g_hold_space; break;
    case VK_RETURN: slot = &g_hold_enter; break;
    case 'X': slot = &g_hold_x; break;
    default: return;
    }
    *slot = v;
}

// ---------------------------------------------------------------
// Mouse (X68000 mouse on the SCC). While captured, the cursor is hidden and kept at the
// centre of the window, and each move away from the centre is a relative motion for the machine.
// A middle click or the menu toggles capture; losing focus releases it.
// ---------------------------------------------------------------
static bool g_mouse_captured = false;
static int32_t g_mouse_dx = 0, g_mouse_dy = 0;
static int g_mouse_buttons = 0;   // bit 0 left, bit 1 right
static HMENU g_mouse_menu = NULL;
// Speed: host pixels per X68000 count is g_mouse_div (4, 2 or 1). The remainder carries over,
// so slow movements are not lost. Menu items 811-813.
static int g_mouse_div = 2;
static int32_t g_mouse_rest_x = 0, g_mouse_rest_y = 0;

static void mouse_check_speed_menu(void) {
    if (g_mouse_menu) {
        int id = g_mouse_div == 4 ? 811 : g_mouse_div == 2 ? 812 : 813;
        CheckMenuRadioItem(g_mouse_menu, 811, 813, id, MF_BYCOMMAND);
    }
}

static POINT mouse_centre(HWND hwnd) {
    RECT r; GetClientRect(hwnd, &r);
    POINT p = { (r.right - r.left) / 2, (r.bottom - r.top) / 2 };
    return p;
}

static void mouse_recentre(HWND hwnd) {
    POINT p = mouse_centre(hwnd);
    ClientToScreen(hwnd, &p);
    SetCursorPos(p.x, p.y);
}

static void mouse_set_capture(HWND hwnd, bool on) {
    if (on == g_mouse_captured) return;
    g_mouse_captured = on;
    g_mouse_dx = g_mouse_dy = 0;
    g_mouse_buttons = 0;
    if (on) {
        RECT r; GetClientRect(hwnd, &r);
        POINT tl = { r.left, r.top }, br = { r.right, r.bottom };
        ClientToScreen(hwnd, &tl); ClientToScreen(hwnd, &br);
        RECT clip = { tl.x, tl.y, br.x, br.y };
        ClipCursor(&clip);
        SetCapture(hwnd);
        while (ShowCursor(FALSE) >= 0) {}
        mouse_recentre(hwnd);
    } else {
        ClipCursor(NULL);
        ReleaseCapture();
        while (ShowCursor(TRUE) < 0) {}
    }
    if (g_mouse_menu) CheckMenuItem(g_mouse_menu, 801, MF_BYCOMMAND | (on ? MF_CHECKED : MF_UNCHECKED));
}

// Motion since the last call and the buttons held. Returns false when the mouse is not captured.
bool c_host_mouse(int32_t *dx, int32_t *dy, int32_t *buttons) {
    int32_t x = g_mouse_rest_x + g_mouse_dx, y = g_mouse_rest_y + g_mouse_dy;
    g_mouse_dx = g_mouse_dy = 0;
    *dx = x / g_mouse_div; *dy = y / g_mouse_div;      // toward zero; the rest waits for the next call
    g_mouse_rest_x = x - *dx * g_mouse_div;
    g_mouse_rest_y = y - *dy * g_mouse_div;
    *buttons = g_mouse_buttons;
    return g_mouse_captured;
}

int c_host_joy_byte(void) {
    int j = 0xFF;
    if (g_hold_up && !g_hold_down) j &= ~0x01;
    if (g_hold_down && !g_hold_up) j &= ~0x02;
    if (g_hold_left && !g_hold_right) j &= ~0x04;
    if (g_hold_right && !g_hold_left) j &= ~0x08;
    if (g_hold_z || g_hold_space || g_hold_enter) j &= ~0x20;
    if (g_hold_x) j &= ~0x40;
    return j;
}

static void win32_set_scale(int scale) {
    if (scale < 1 || scale > 4 || !g_hwnd) return;
    g_scale = scale;
    int disp_w = g_src_w;
    int disp_h = g_src_h;
    if (disp_w == 256 && disp_h == 256) {
        disp_w = 512;
        disp_h = 512;
    }
    RECT r = {0, 0, disp_w * g_scale, disp_h * g_scale};
    DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    AdjustWindowRect(&r, style, TRUE);
    SetWindowPos(g_hwnd, NULL, 0, 0, r.right - r.left, r.bottom - r.top, SWP_NOMOVE | SWP_NOZORDER);
}

// Open File Dialog helper
static bool open_file_dialog(HWND owner, const wchar_t *filter, char *out_path, int max_len) {
    OPENFILENAMEW ofn;
    wchar_t picked[MAX_PATH];
    memset(&ofn, 0, sizeof(ofn));
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = owner;
    ofn.lpstrFilter = filter;
    ofn.lpstrFile = picked;
    ofn.nMaxFile = MAX_PATH;
    ofn.Flags = OFN_PATHMUSTEXIST | OFN_FILEMUSTEXIST | OFN_NOCHANGEDIR;
    picked[0] = 0;
    out_path[0] = '\0';
    return GetOpenFileNameW(&ofn) != 0 && path_from_wide(picked, out_path, max_len);
}

static const int k_cpu_clocks[] = { X68K_CPU_CLOCK_LIST };
static int g_cpu_mhz = 10;
static HMENU g_clock_menu = NULL;

static int cpu_clock_index(int mhz) {
    int i;
    for (i = 0; i < (int)(sizeof(k_cpu_clocks) / sizeof(k_cpu_clocks[0])); i++) {
        if (k_cpu_clocks[i] == mhz) return i;
    }
    return -1;
}

static void cpu_clock_check_menu(void) {
    int idx;
    if (!g_clock_menu) return;
    idx = cpu_clock_index(g_cpu_mhz);
    if (idx < 0) idx = 0;
    CheckMenuRadioItem(g_clock_menu, 501, 509, 501 + idx, MF_BYCOMMAND);
}

int c_set_cpu_mhz(int mhz) {
    if (cpu_clock_index(mhz) < 0) return 0;
    g_cpu_mhz = mhz;
    cpu_clock_check_menu();
    return 1;
}

int c_get_cpu_mhz(void) {
    return g_cpu_mhz;
}

int c_cpu_mhz_ok(int mhz) {
    return cpu_clock_index(mhz) >= 0;
}

/* Run-ahead: how many frames ahead the window shows (0 = off). The menu sets it; the frontend
 * loop reads it every frame and x68k_config.goose saves it. */
static int g_run_ahead = 0;
static HMENU g_ahead_menu = NULL;

static void run_ahead_check_menu(void) {
    if (g_ahead_menu) CheckMenuRadioItem(g_ahead_menu, 601, 605, 601 + g_run_ahead, MF_BYCOMMAND);
}

int c_set_run_ahead(int frames) {
    if (frames < 0 || frames > 4) return 0;
    g_run_ahead = frames;
    run_ahead_check_menu();
    return 1;
}

int c_get_run_ahead(void) {
    return g_run_ahead;
}

void c_startup_error(void) {
    MessageBoxA(NULL, "Could not load the X68000 BIOS.\nPlace iplrom.dat (128 KiB) and cgrom.dat (768 KiB) in .\\keropi\nrelative to the working directory, or pass --system-dir PATH.\nSee README.md for setup.",
                "Goose X68000 - BIOS setup", MB_OK | MB_ICONERROR);
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
        case WM_COMMAND: {
            int id = LOWORD(wParam);
            if (id >= 501 && id <= 509) {
                c_set_cpu_mhz(k_cpu_clocks[id - 501]);
                g_settings_changed = 1;
                return 0;
            }
            if (id >= 601 && id <= 605) {
                c_set_run_ahead(id - 601);
                g_settings_changed = 1;
                return 0;
            }
            // State menu: 701-703 save slot 1-3, 711-713 load slot 1-3 (commands 11-13 and 21-23)
            if (id == 801) { mouse_set_capture(hwnd, !g_mouse_captured); return 0; }
            if (id >= 811 && id <= 813) {
                g_mouse_div = id == 811 ? 4 : id == 812 ? 2 : 1;
                g_mouse_rest_x = g_mouse_rest_y = 0;
                mouse_check_speed_menu();
                return 0;
            }
            if (id >= 701 && id <= 703) { g_pending_cmd = 11 + (int)(id - 701); return 0; }
            if (id >= 711 && id <= 713) { g_pending_cmd = 21 + (int)(id - 711); return 0; }
            switch (id) {
                case 103: g_pending_cmd = 3; break; // Reset
                case 104: g_is_open = false; DestroyWindow(hwnd); break;
                case 201: win32_set_scale(1); break;
                case 202: win32_set_scale(2); break;
                case 211: g_menu_width = 768; c_set_screen_mode(768, 512); break;
                case 212: g_menu_width = 512; c_set_screen_mode(512, 512); break;
                // FD0 (a new disk here also reboots; the frontend decides that)
                case 401: {
                    char file_buf[PATH_CAP] = {0};
                    if (open_file_dialog(hwnd, L"X68000 Disk Images (*.2hd;*.xdf;*.dim;*.d88;*.img;*.bin)\0*.2hd;*.xdf;*.dim;*.d88;*.img;*.bin\0All Files (*.*)\0*.*\0", file_buf, PATH_CAP)) media_request(MEDIA_FD0_INSERT, file_buf);
                    break;
                }
                case 402: media_request(MEDIA_FD0_EJECT, NULL); break;
                // FD1
                case 411: {
                    char file_buf[PATH_CAP] = {0};
                    if (open_file_dialog(hwnd, L"X68000 Disk Images (*.2hd;*.xdf;*.dim;*.d88;*.img;*.bin)\0*.2hd;*.xdf;*.dim;*.d88;*.img;*.bin\0All Files (*.*)\0*.*\0", file_buf, PATH_CAP)) media_request(MEDIA_FD1_INSERT, file_buf);
                    break;
                }
                case 412: media_request(MEDIA_FD1_EJECT, NULL); break;
                // HDD
                case 421: {
                    char file_buf[PATH_CAP] = {0};
                    if (open_file_dialog(hwnd, L"X68000 HDD Images (*.hdf;*.hds;*.img)\0*.hdf;*.hds;*.img\0All Files (*.*)\0*.*\0", file_buf, PATH_CAP)) media_request(MEDIA_HDD_INSERT, file_buf);
                    break;
                }
                case 422: media_request(MEDIA_HDD_EJECT, NULL); break;
                case 301:
                    MessageBoxA(hwnd,
                        "Goose Sharp X68000 Emulator\nWritten in Goose language!\nSupports Motorola 68000 CPU, MMU, PPU, FD0/FD1/HDD disk insertion, and ARCL MCP.",
                        "About Goose X68000", MB_OK | MB_ICONINFORMATION);
                    break;
                default: break;
            }
            g_settings_changed = 1;
            return 0;
        }
        case WM_CLOSE:
            g_is_open = false;
            DestroyWindow(hwnd);
            return 0;
        case WM_DESTROY:
            g_is_open = false;
            PostQuitMessage(0);
            return 0;
        case WM_CHAR:
            return 0; // keys reach the machine as scan codes (WM_KEYDOWN / WM_KEYUP)
        case WM_KILLFOCUS:
            c_host_joy_reset();
            mouse_set_capture(hwnd, false);
            return 0;
        case WM_MBUTTONDOWN:
            mouse_set_capture(hwnd, !g_mouse_captured);
            return 0;
        case WM_MOUSEMOVE:
            if (g_mouse_captured) {
                POINT c = mouse_centre(hwnd);
                int x = (short)LOWORD(lParam), y = (short)HIWORD(lParam);
                if (x != c.x || y != c.y) {
                    g_mouse_dx += x - c.x;
                    g_mouse_dy += y - c.y;
                    mouse_recentre(hwnd);
                }
            }
            return 0;
        case WM_LBUTTONDOWN: if (g_mouse_captured) g_mouse_buttons |= 1; return 0;
        case WM_LBUTTONUP:   g_mouse_buttons &= ~1; return 0;
        case WM_RBUTTONDOWN: if (g_mouse_captured) g_mouse_buttons |= 2; return 0;
        case WM_RBUTTONUP:   g_mouse_buttons &= ~2; return 0;
        case WM_KEYDOWN:
        case WM_KEYUP: {
            bool down = (msg == WM_KEYDOWN);
            bool repeat = (lParam & 0x40000000) != 0;
            uint8_t sc = vk_to_x68k_code(wParam, lParam);
            if (sc != 0) {
                push_scancode(down ? sc : (sc | 0x80));
            }
            if (!(down && repeat)) {
                c_host_key_joy((int)wParam, down ? 1 : 0);
            }
            uint32_t mask = 0;
            switch (wParam) {
                case VK_F5: if (down) g_pending_cmd = 3; break;
                case VK_ESCAPE: if (down) mask = (1 << 8); break;
                default: break;
            }
            if (mask) {
                if (down) g_keys |= mask;
                else g_keys &= ~mask;
            }
            return 0;
        }
        default:
            return DefWindowProc(hwnd, msg, wParam, lParam);
    }
}

// Audio state (waveOut)
#define AUDIO_NUM_BUFFERS 8
#define AUDIO_BUF_SAMPLES 4096 // 2048 stereo frames
#define AUDIO_HOLD_MAX (44100 * 2)
static HWAVEOUT g_hwave = NULL;
static WAVEHDR g_wave_hdrs[AUDIO_NUM_BUFFERS];
static int16_t g_audio_buffers[AUDIO_NUM_BUFFERS][AUDIO_BUF_SAMPLES];
static int16_t g_audio_hold[AUDIO_HOLD_MAX];
static int g_audio_hold_n = 0;
static int g_audio_busy[AUDIO_NUM_BUFFERS];
static int g_cur_buf = 0;
static bool g_audio_open = false;

static bool win32_audio_init(void) {
    if (g_audio_open && g_hwave) return true;
    WAVEFORMATEX wfx;
    memset(&wfx, 0, sizeof(wfx));
    wfx.wFormatTag = WAVE_FORMAT_PCM;
    wfx.nChannels = 2;
    wfx.nSamplesPerSec = 44100;
    wfx.wBitsPerSample = 16;
    wfx.nBlockAlign = (wfx.nChannels * wfx.wBitsPerSample) / 8;
    wfx.nAvgBytesPerSec = wfx.nSamplesPerSec * wfx.nBlockAlign;
    wfx.cbSize = 0;

    MMRESULT res = waveOutOpen(&g_hwave, WAVE_MAPPER, &wfx, 0, 0, CALLBACK_NULL);
    if (res != MMSYSERR_NOERROR) {
        g_audio_open = false;
        return false;
    }

    memset(g_wave_hdrs, 0, sizeof(g_wave_hdrs));
    for (int i = 0; i < AUDIO_NUM_BUFFERS; i++) {
        memset(g_audio_buffers[i], 0, sizeof(g_audio_buffers[i]));
        g_wave_hdrs[i].lpData = (LPSTR)g_audio_buffers[i];
        g_wave_hdrs[i].dwBufferLength = sizeof(g_audio_buffers[i]);
        g_wave_hdrs[i].dwFlags = 0;
        waveOutPrepareHeader(g_hwave, &g_wave_hdrs[i], sizeof(WAVEHDR));
        g_audio_busy[i] = 0;
    }

    g_cur_buf = 0;
    g_audio_hold_n = 0;
    g_audio_open = true;
    return true;
}

int c_audio_init(void) {
    return win32_audio_init() ? 1 : 0;
}

static void win32_audio_destroy(void);

static int audio_is_free(int idx) {
    if (!g_audio_busy[idx])
        return 1;
    if (g_wave_hdrs[idx].dwFlags & WHDR_DONE) {
        g_audio_busy[idx] = 0;
        return 1;
    }
    return 0;
}

static int audio_queued(void) {
    int n = 0;
    for (int i = 0; i < AUDIO_NUM_BUFFERS; i++) {
        if (g_audio_busy[i] && (g_wave_hdrs[i].dwFlags & WHDR_DONE) == 0)
            n++;
    }
    return n;
}

static int audio_find_free(void) {
    for (int i = 0; i < AUDIO_NUM_BUFFERS; i++) {
        int idx = (g_cur_buf + i) % AUDIO_NUM_BUFFERS;
        if (audio_is_free(idx))
            return idx;
    }
    return -1;
}

static void audio_flush(void) {
    while (g_audio_hold_n >= 2) {
        int frames = g_audio_hold_n / 2;
        /* While enough is queued, keep collecting so that short buffers make fewer seams */
        if (audio_queued() >= 3 && frames < 1024)
            return;
        int idx = audio_find_free();
        if (idx < 0)
            return;
        if (frames > 2048)
            frames = 2048;
        int n16 = frames * 2;
        WAVEHDR *hdr = &g_wave_hdrs[idx];
        if (hdr->dwFlags & WHDR_PREPARED)
            waveOutUnprepareHeader(g_hwave, hdr, sizeof(WAVEHDR));
        memcpy(g_audio_buffers[idx], g_audio_hold, (size_t)n16 * sizeof(int16_t));
        if (g_audio_hold_n > n16) {
            memmove(g_audio_hold, g_audio_hold + n16,
                    (size_t)(g_audio_hold_n - n16) * sizeof(int16_t));
        }
        g_audio_hold_n -= n16;
        hdr->dwBufferLength = (DWORD)(n16 * sizeof(int16_t));
        hdr->dwFlags = 0;
        waveOutPrepareHeader(g_hwave, hdr, sizeof(WAVEHDR));
        if (waveOutWrite(g_hwave, hdr, sizeof(WAVEHDR)) != MMSYSERR_NOERROR)
            return;
        g_audio_busy[idx] = 1;
        g_cur_buf = (idx + 1) % AUDIO_NUM_BUFFERS;
    }
}

static void win32_audio_push(const int16_t *samples, int count) {
    if (!g_audio_open || !g_hwave || !samples || count <= 0) return;

    if (count > AUDIO_HOLD_MAX) {
        samples += count - AUDIO_HOLD_MAX;
        count = AUDIO_HOLD_MAX;
    }
    if (g_audio_hold_n + count > AUDIO_HOLD_MAX) {
        int drop = g_audio_hold_n + count - AUDIO_HOLD_MAX;
        if (drop > g_audio_hold_n)
            drop = g_audio_hold_n;
        if (drop > 0 && g_audio_hold_n > drop) {
            memmove(g_audio_hold, g_audio_hold + drop,
                    (size_t)(g_audio_hold_n - drop) * sizeof(int16_t));
        }
        g_audio_hold_n -= drop;
    }
    memcpy(g_audio_hold + g_audio_hold_n, samples, (size_t)count * sizeof(int16_t));
    g_audio_hold_n += count;
    audio_flush();
}

static void win32_audio_destroy(void) {
    if (g_audio_open && g_hwave) {
        waveOutReset(g_hwave);
        for (int i = 0; i < AUDIO_NUM_BUFFERS; i++) {
            waveOutUnprepareHeader(g_hwave, &g_wave_hdrs[i], sizeof(WAVEHDR));
        }
        waveOutClose(g_hwave);
        g_hwave = NULL;
    }
    g_audio_open = false;
}

static void win32_timer_init(void);
static void win32_timer_shutdown(void);

bool win32_ui_init(X68kByteView title_bytes, int w, int h, int scale) {
    char title_buf[256];
    const char *title;
    bind_path(title_bytes.data, (int)title_bytes.len, title_buf, (int)sizeof(title_buf));
    title = title_buf[0] ? title_buf : NULL;
    if (g_hwnd) return true;
    g_src_w = (w > 0 ? w : 512);
    g_src_h = (h > 0 ? h : 512);
    g_scale = (scale >= 1 && scale <= 4 ? scale : 1);

    HINSTANCE hInstance = GetModuleHandle(NULL);
    const char *className = "GooseX68kClass";

    WNDCLASSA wc;
    memset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInstance;
    wc.lpszClassName = className;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    RegisterClassA(&wc);

    HMENU hMenuBar = CreateMenu();

    // File Menu
    HMENU hFileMenu = CreatePopupMenu();
    AppendMenuA(hFileMenu, MF_STRING, 103, "&Reset\tF5");
    AppendMenuA(hFileMenu, MF_SEPARATOR, 0, NULL);
    AppendMenuA(hFileMenu, MF_STRING, 104, "E&xit\tAlt+F4");
    AppendMenuA(hMenuBar, MF_POPUP, (UINT_PTR)hFileMenu, "&File");

    // FD0 Menu
    HMENU hFd0Menu = CreatePopupMenu();
    AppendMenuA(hFd0Menu, MF_STRING, 401, "&Open FD0 Image (XDF, DIM, D88)...");
    AppendMenuA(hFd0Menu, MF_STRING, 402, "&Eject FD0");
    AppendMenuA(hMenuBar, MF_POPUP, (UINT_PTR)hFd0Menu, "FD&0");

    // FD1 Menu
    HMENU hFd1Menu = CreatePopupMenu();
    AppendMenuA(hFd1Menu, MF_STRING, 411, "&Open FD1 Image (XDF, DIM, D88)...");
    AppendMenuA(hFd1Menu, MF_STRING, 412, "&Eject FD1");
    AppendMenuA(hMenuBar, MF_POPUP, (UINT_PTR)hFd1Menu, "FD&1");

    // HDD Menu
    HMENU hHddMenu = CreatePopupMenu();
    AppendMenuA(hHddMenu, MF_STRING, 421, "&Open HDD Image (HDF, HDS)...");
    AppendMenuA(hHddMenu, MF_STRING, 422, "&Eject HDD");
    AppendMenuA(hMenuBar, MF_POPUP, (UINT_PTR)hHddMenu, "&HDD");

    // View Menu
    HMENU hViewMenu = CreatePopupMenu();
    AppendMenuA(hViewMenu, MF_STRING, 201, "&1x Scale");
    AppendMenuA(hViewMenu, MF_STRING, 202, "&2x Scale");
    AppendMenuA(hViewMenu, MF_SEPARATOR, 0, NULL);
    AppendMenuA(hViewMenu, MF_STRING, 211, "Initial Screen: &768x512");
    AppendMenuA(hViewMenu, MF_STRING, 212, "Initial Screen: &512x512");
    AppendMenuA(hMenuBar, MF_POPUP, (UINT_PTR)hViewMenu, "&View");

    g_clock_menu = CreatePopupMenu();
    AppendMenuA(g_clock_menu, MF_STRING, 501, "10 MHz");
    AppendMenuA(g_clock_menu, MF_STRING, 502, "16 MHz");
    AppendMenuA(g_clock_menu, MF_STRING, 503, "25 MHz");
    AppendMenuA(g_clock_menu, MF_STRING, 504, "50 MHz");
    AppendMenuA(g_clock_menu, MF_STRING, 505, "75 MHz");
    AppendMenuA(g_clock_menu, MF_STRING, 506, "100 MHz");
    AppendMenuA(g_clock_menu, MF_STRING, 507, "150 MHz");
    AppendMenuA(g_clock_menu, MF_STRING, 508, "200 MHz");
    AppendMenuA(g_clock_menu, MF_STRING, 509, "250 MHz");
    AppendMenuA(hMenuBar, MF_POPUP, (UINT_PTR)g_clock_menu, "&Clock");
    cpu_clock_check_menu();

    // Run-ahead: show the screen N frames ahead to cut input lag
    g_ahead_menu = CreatePopupMenu();
    AppendMenuA(g_ahead_menu, MF_STRING, 601, "&Off");
    AppendMenuA(g_ahead_menu, MF_STRING, 602, "&1 Frame");
    AppendMenuA(g_ahead_menu, MF_STRING, 603, "&2 Frames");
    AppendMenuA(g_ahead_menu, MF_STRING, 604, "&3 Frames");
    AppendMenuA(g_ahead_menu, MF_STRING, 605, "&4 Frames");
    AppendMenuA(hMenuBar, MF_POPUP, (UINT_PTR)g_ahead_menu, "Run-&Ahead");
    run_ahead_check_menu();

    // State Menu (the slots are files state1.x68s .. state3.x68s in the working directory)
    HMENU hStateMenu = CreatePopupMenu();
    AppendMenuA(hStateMenu, MF_STRING, 701, "&Save Slot 1");
    AppendMenuA(hStateMenu, MF_STRING, 702, "Save Slot &2");
    AppendMenuA(hStateMenu, MF_STRING, 703, "Save Slot &3");
    AppendMenuA(hStateMenu, MF_SEPARATOR, 0, NULL);
    AppendMenuA(hStateMenu, MF_STRING, 711, "&Load Slot 1");
    AppendMenuA(hStateMenu, MF_STRING, 712, "Load Slot 2");
    AppendMenuA(hStateMenu, MF_STRING, 713, "Load Slot 3");
    AppendMenuA(hMenuBar, MF_POPUP, (UINT_PTR)hStateMenu, "&State");

    // Mouse Menu
    g_mouse_menu = CreatePopupMenu();
    AppendMenuA(g_mouse_menu, MF_STRING, 801, "&Capture Mouse\tMiddle Click");
    AppendMenuA(g_mouse_menu, MF_SEPARATOR, 0, NULL);
    AppendMenuA(g_mouse_menu, MF_STRING, 811, "Speed: &Slow (1/4)");
    AppendMenuA(g_mouse_menu, MF_STRING, 812, "Speed: &Normal (1/2)");
    AppendMenuA(g_mouse_menu, MF_STRING, 813, "Speed: &Fast (1/1)");
    mouse_check_speed_menu();
    AppendMenuA(hMenuBar, MF_POPUP, (UINT_PTR)g_mouse_menu, "&Mouse");

    // Help Menu
    HMENU hHelpMenu = CreatePopupMenu();
    AppendMenuA(hHelpMenu, MF_STRING, 301, "&About Goose X68000...");
    AppendMenuA(hMenuBar, MF_POPUP, (UINT_PTR)hHelpMenu, "&Help");

    int disp_w = g_src_w;
    int disp_h = g_src_h;
    if (disp_w == 256 && disp_h == 256) {
        disp_w = 512;
        disp_h = 512;
    }
    RECT r = {0, 0, disp_w * g_scale, disp_h * g_scale};
    DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    AdjustWindowRect(&r, style, TRUE);

    g_hwnd = CreateWindowA(
        className,
        title ? title : "Sharp X68000 Emulator (Goose Native)",
        style,
        CW_USEDEFAULT, CW_USEDEFAULT,
        r.right - r.left, r.bottom - r.top,
        NULL, hMenuBar, hInstance, NULL
    );

    if (!g_hwnd) return false;

    g_hdc = GetDC(g_hwnd);

    memset(&g_bmi, 0, sizeof(g_bmi));
    g_bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    g_bmi.bmiHeader.biWidth = g_src_w;
    g_bmi.bmiHeader.biHeight = -g_src_h; // top-down
    g_bmi.bmiHeader.biPlanes = 1;
    g_bmi.bmiHeader.biBitCount = 32;
    g_bmi.bmiHeader.biCompression = BI_RGB;

    ShowWindow(g_hwnd, SW_SHOW);
    UpdateWindow(g_hwnd);
    win32_timer_init();
    win32_audio_init();
    g_is_open = true;
    return true;
}

uint32_t win32_ui_poll(void) {
    MSG msg;
    while (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    // SOCD cleaner: left+right or up+down together count as neither, so games such as Cho Ren Sha 68K do not pause by mistake
    uint32_t cleaned = g_keys;
    if ((cleaned & 0x03) == 0x03) cleaned &= ~0x03; // Left + Right cancel
    if ((cleaned & 0x0C) == 0x0C) cleaned &= ~0x0C; // Up + Down cancel
    return cleaned;
}

void win32_ui_render_fb(void) {
    if (!g_hwnd || !g_hdc || !g_fb) return;
    RECT cr;
    GetClientRect(g_hwnd, &cr);
    int client_w = cr.right - cr.left;
    int client_h = cr.bottom - cr.top;
    StretchDIBits(
        g_hdc,
        0, 0, client_w, client_h,
        0, 0, g_src_w, g_src_h,
        g_fb,
        &g_bmi,
        DIB_RGB_COLORS,
        SRCCOPY
    );
}

bool win32_ui_is_open(void) {
    return g_is_open;
}

static LARGE_INTEGER s_qpc_freq = {0};
static bool s_timer_initialized = false;

static void win32_timer_init(void) {
    if (!s_timer_initialized) {
        timeBeginPeriod(1);
        QueryPerformanceFrequency(&s_qpc_freq);
        s_timer_initialized = true;
    }
}

static void win32_timer_shutdown(void) {
    if (s_timer_initialized) {
        timeEndPeriod(1);
        s_timer_initialized = false;
    }
}

/* Close whatever is open: the audio device, the timer resolution, the window. Safe to call
 * when none of them was opened (headless and windowless ARCL runs end here too). */
void win32_ui_destroy(void) {
    win32_audio_destroy();
    win32_timer_shutdown();
    if (g_hdc && g_hwnd) {
        ReleaseDC(g_hwnd, g_hdc);
        g_hdc = NULL;
    }
    if (g_hwnd) {
        DestroyWindow(g_hwnd);
        g_hwnd = NULL;
    }
    g_clock_menu = NULL;
    g_ahead_menu = NULL;
    g_mouse_menu = NULL;
    g_mouse_captured = false;
    g_is_open = false;
}

void win32_ui_sleep(int ms) {
    Sleep(ms > 0 ? ms : 0);
}

uint64_t win32_ui_get_ticks_ms(void) {
    return (uint64_t)GetTickCount64();
}

uint64_t win32_ui_get_time_us(void) {
    if (!s_timer_initialized) {
        win32_timer_init();
    }
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    return (uint64_t)((now.QuadPart * 1000000ULL) / s_qpc_freq.QuadPart);
}

void win32_ui_wait_until_us(uint64_t target_us) {
    if (!s_timer_initialized) {
        win32_timer_init();
    }
    uint64_t now = win32_ui_get_time_us();
    if (now >= target_us) return;

    int64_t diff_us = (int64_t)(target_us - now);
    // Safety clamp: never sleep longer than 30ms (prevents any accidental freeze/pause)
    if (diff_us > 30000) return;

    // If more than 2.0ms remain, Sleep most of it to yield CPU cleanly
    if (diff_us > 2000) {
        DWORD sleep_ms = (DWORD)((diff_us - 1500) / 1000);
        if (sleep_ms > 0) {
            Sleep(sleep_ms);
        }
    }
    // High-precision spin-wait for the last fraction of a millisecond
    while (win32_ui_get_time_us() < target_us) {
        YieldProcessor();
    }
}

// A warning box for a failed menu action (the text is UTF-8 from Goose; it is ASCII here).
void c_ui_warning(X68kByteView text) {
    char buf[512];
    int n = (int)(text.len < (int64_t)sizeof(buf) - 1 ? text.len : (int64_t)sizeof(buf) - 1);
    memcpy(buf, text.data, (size_t)n);
    buf[n] = 0;
    MessageBoxA(g_hwnd, buf, "Goose X68000", MB_OK | MB_ICONWARNING);
}

int win32_ui_get_command(void) {
    int cmd = g_pending_cmd;
    g_pending_cmd = 0;
    return cmd;
}

void c_machine_reset_devices(void) {
    c_host_input_discard();
    c_audio_discard();
}

void c_host_input_discard(void) {
    c_host_joy_reset();
    g_scan_head = g_scan_tail = 0;
    g_keys = 0;
    g_pending_cmd = 0;
}

void c_audio_discard(void) {
    // Drop audio queued for the old machine state without recreating waveOut.
    if (g_hwave) waveOutReset(g_hwave);
    memset(g_audio_busy, 0, sizeof(g_audio_busy));
    g_audio_hold_n = 0;
    g_cur_buf = 0;
}

// One frame of finished interleaved stereo samples (the ADPCM and the OPM, mixed in Goose) for the
// audio device. Recording and writing WAV files are done in Goose (x68k_output.goose).
void c_audio_output(X68kSampleView frame) {
    int samples = (int)(frame.len / 2);
    if (!frame.data || samples <= 0) return;
    win32_audio_push(frame.data, samples * 2);
}

int c_host_list_dir(X68kByteView path_bytes, char *out, int cap) {
    char path[PATH_CAP];
    char pattern[PATH_CAP];
    wchar_t wide[MAX_PATH];
    WIN32_FIND_DATAW fd;
    HANDLE h;
    int used = 0;
    int first = 1;
    bind_path(path_bytes.data, (int)path_bytes.len, path, PATH_CAP);
    if (!out || cap < 2) return 0;
    if (path[0] == 0) return 0;
    if (strstr(path, "..")) return -1;
    if ((int)strlen(path) + 3 >= PATH_CAP) return 0;
    snprintf(pattern, sizeof(pattern), "%s\\*", path);
    if (!path_to_wide(pattern, wide, MAX_PATH)) return 0;
    h = FindFirstFileW(wide, &fd);
    if (h == INVALID_HANDLE_VALUE) return 0;
    out[0] = 0;
    do {
        char name[PATH_CAP];
        int is_dir, i, nlen;
        char piece[PATH_CAP * 2 + 64];
        int pn = 0;
        if (!path_from_wide(fd.cFileName, name, PATH_CAP)) continue;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
        is_dir = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        piece[pn++] = first ? '[' : ',';
        first = 0;
        pn += snprintf(piece + pn, sizeof(piece) - (size_t)pn, "{\"name\":\"");
        nlen = (int)strlen(name);
        for (i = 0; i < nlen && pn < (int)sizeof(piece) - 8; i++) {
            char c = name[i];
            if (c == '\\' || c == '"') piece[pn++] = '\\';
            piece[pn++] = c;
        }
        pn += snprintf(piece + pn, sizeof(piece) - (size_t)pn, "\",\"is_dir\":%s,\"size\":%llu}",
            is_dir ? "true" : "false",
            (unsigned long long)(((uint64_t)fd.nFileSizeHigh << 32) | fd.nFileSizeLow));
        if (used + pn + 2 >= cap) break;
        memcpy(out + used, piece, (size_t)pn);
        used += pn;
        out[used] = 0;
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    if (first) {
        memcpy(out, "[]", 3);
    } else if (used + 1 < cap) {
        out[used++] = ']';
        out[used] = 0;
    }
    return 1;
}

