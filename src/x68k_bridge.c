#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include <commdlg.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include "x68k_bridge.h"
#include "sound/x68k_sound.h"

/* Palette, TVRAM and GVRAM live in the Goose emulator struct, which is a
 * local. 1MB is not enough once those arrays are there. */
#ifdef _MSC_VER
#pragma comment(linker, "/STACK:8388608")
#endif

// Stdio IO helpers for Goose MCP Server
int c_io_read_line(void *out_buf, int max_len) {
    char *buf = (char *)out_buf;
    if (!fgets(buf, max_len, stdin)) {
        return -1;
    }
    int len = (int)strlen(buf);
    while (len > 0 && (buf[len - 1] == '\r' || buf[len - 1] == '\n')) {
        buf[--len] = '\0';
    }
    return len;
}

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

static int g_last_path_len;

int c_last_path_len(void) { return g_last_path_len; }

static void bind_path(const uint8_t *p, int len, char *dst, int cap) {
    int n;
    if (!dst || cap < 1) return;
    if (len < 0) len = 0;
    if (!p) len = 0;
    g_last_path_len = len;
    n = len;
    if (n >= cap) n = cap - 1;
    if (n > 0) memcpy(dst, p, (size_t)n);
    dst[n] = 0;
}

// Raw File IO
int c_file_read(const uint8_t *path, int path_len, void *out_buf, int max_len) {
    char pbuf[MAX_PATH];
    bind_path(path, path_len, pbuf, MAX_PATH);
    if (pbuf[0] == 0 || !out_buf || max_len <= 0) return 0;
    FILE *fp = fopen(pbuf, "rb");
    if (!fp) return 0;
    size_t n = fread(out_buf, 1, (size_t)max_len, fp);
    fclose(fp);
    return (int)n;
}

int c_file_write(const uint8_t *path, int path_len, const void *buf, int len) {
    char pbuf[MAX_PATH];
    bind_path(path, path_len, pbuf, MAX_PATH);
    if (pbuf[0] == 0 || !buf || len <= 0) return 0;
    FILE *fp = fopen(pbuf, "wb");
    if (!fp) return 0;
    size_t n = fwrite(buf, 1, (size_t)len, fp);
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
static void state_banks_clear(void);
static int g_init_fail_after = -1;

void c_mem_test_fail_init(int after) { g_init_fail_after = after; }
static void *host_calloc(size_t n, size_t size) {
    if (g_init_fail_after == 0) { g_init_fail_after = -1; return NULL; }
    if (g_init_fail_after > 0) g_init_fail_after--;
    return calloc(n, size);
}
static char g_sys_dir[MAX_PATH];
#define TVRAM_SIZE (512 * 1024)        // 512KB
#define GVRAM_SIZE (512 * 1024)        // 512KB
#define CGROM_SIZE (768 * 1024)        // 768KB
#define IPL_SIZE   (128 * 1024)        // 128KB
#define SRAM_SIZE  (16 * 1024)         // 16KB
#define FDD_SIZE   (1261568)           // 1.2MB 2HD (154 tracks * 8 sectors * 1024 bytes)
#define HDD_SIZE   (40 * 1024 * 1024)  // 40MB max SASI HDD
#define PAL_SIZE     (1024)            // 1024 bytes (0xE82000 - 0xE823FF)
#define VCREG_SIZE   (0x400)           // 1024 bytes (0xE82400 - 0xE827FF)
#define SPRITE_SIZE  (0x800)           // 2048 bytes (0xEB0000 - 0xEB07FF)
#define BGREG_SIZE   (0x20)            // 32 bytes   (0xEB0800 - 0xEB081F)
#define BGRAM_SIZE   (0x8000)          // 32768 bytes (0xEB8000 - 0xEBFFFF)
#define FB_MAX_W   768
#define FB_MAX_H   512
#define FB_MAX_PIXELS (FB_MAX_W * FB_MAX_H)

static uint8_t *g_ram = NULL;
static int g_ram_bound = 0;
static uint8_t *g_tvram = NULL;
static int g_tvram_bound = 0;
static uint8_t *g_gvram = NULL;
static int g_gvram_bound = 0;
static uint8_t *g_cgrom = NULL;
static int g_cgrom_bound = 0;
static uint8_t *g_iplrom = NULL;
static int g_ipl_bound = 0;
static uint8_t *g_sram = NULL;
static int g_sram_bound = 0;
static uint8_t *g_fdd0 = NULL;
static uint8_t *g_fdd1 = NULL;
static uint8_t *g_hdd0 = NULL;
static uint32_t *g_fb = NULL;
static int g_fb_bound = 0;

static uint8_t *g_pal = NULL;
static uint8_t *g_vcreg = NULL;
static int g_vcreg_bound = 0;
static int s_current_frame = 0;
static uint8_t *g_sprite = NULL;
static uint8_t *g_bgreg = NULL;
static uint8_t *g_bgram = NULL;
static uint8_t *g_bg_chr8 = NULL;
static uint8_t *g_bg_chr16 = NULL;
static int g_video_bound = 0;
static int g_src_w = 768; // Default to 768x512 standard X68000 mode
static int g_frame_ready = 0;
static int g_src_h = 512;
static int32_t *g_screen_w_slot = NULL;
static int32_t *g_screen_h_slot = NULL;

static void screen_publish(void) {
    if (g_screen_w_slot) *g_screen_w_slot = g_src_w;
    if (g_screen_h_slot) *g_screen_h_slot = g_src_h;
}
/* 0: full composite. 1: clear+GVRAM only (sprites follow per scanline). 2: text only. */
static int g_ppu_phase = 0;

static bool g_fdd0_loaded = false;
static bool g_fdd1_loaded = false;
static bool g_hdd0_loaded = false;
static int g_hdd0_len = 0;
static int g_sasi_reset_req = 0;
static char g_fdd0_path[MAX_PATH] = {0};
static char g_fdd1_path[MAX_PATH] = {0};
static char g_hdd0_path[MAX_PATH] = {0};
/* px68k fdd.c SetDelay。挿入は 3 フレーム後、排出は入っていたときすぐ。 */
static int g_fdd_delay[2];
static int g_fdd_media_enable;
static int g_fdd_media_pending;
static int32_t *g_fdd_media_slot = NULL;
/* 1=XDF 2=D88 3=DIM. px68k GetDiskType. XDF stays the flat 1024x8 layout. */
#define FDD_KIND_XDF 1
#define FDD_KIND_D88 2
#define FDD_KIND_DIM 3
#define FDD_DIM_HEADER 256
#define FDD_D88_HEADER 0x2B0
#define FDD_MAX_IMAGE (4 * 1024 * 1024)
static int g_fdd_kind[2];
static int g_fdd_cap[2];
static int g_fdd_len[2];
static int g_fdd_trk[2];
static int g_fdd_cur[2];
static uint32_t g_fdd_d88_top[2];
static uint32_t g_fdd_d88_cur[2];

static void fdd_media_store(int pending) {
    g_fdd_media_pending = pending;
    if (g_fdd_media_slot) *g_fdd_media_slot = pending;
}

static void fdd_media_raise(void) {
    if (g_fdd_media_enable) fdd_media_store(1);
}

void c_fdd_media_bind(int32_t *slot) {
    g_fdd_media_slot = slot;
    if (slot) *slot = g_fdd_media_pending ? 1 : 0;
}

void c_fdd_media_reset(void) {
    g_fdd_delay[0] = 0;
    g_fdd_delay[1] = 0;
    g_fdd_media_enable = 0;
    fdd_media_store(0);
}

void c_fdd_set_media_enable(int32_t enable) {
    g_fdd_media_enable = enable ? 1 : 0;
}

void c_fdd_media_tick(int32_t enable) {
    c_fdd_set_media_enable(enable);
    for (int i = 0; i < 2; i++) {
        if (g_fdd_delay[i] > 0) {
            g_fdd_delay[i]--;
            if (g_fdd_delay[i] == 0) fdd_media_raise();
        }
    }
}

int c_fdd_peek_media_irq(void) {
    return g_fdd_media_pending ? 1 : 0;
}

void c_fdd_ack_media_irq(void) {
    fdd_media_store(0);
}

// Helper to find and load ROM file with multiple candidate directories
static int load_rom_file(const char *filename, const char *sys_dir, void *buf, int size) {
    char path[MAX_PATH];
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

int c_default_system_dir(char *out, int cap) {
    DWORD n;
    if (!out || cap < 1) return 0;
    out[0] = 0;
    n = GetFullPathNameA(".\\keropi", cap, out, NULL);
    if (!n || n >= (DWORD)cap) { out[0] = 0; return 0; }
    return 1;
}

int c_default_disk_path(char *out, int cap) {
    // No game-specific media discovery. An unconfigured drive stays empty.
    if (out && cap > 0) out[0] = 0;
    return 0;
}

static int fdd_kind_of(const char *path) {
    const char *dot = strrchr(path, '.');
    if (!dot || !dot[1] || !dot[2] || !dot[3]) return FDD_KIND_XDF;
    char a = dot[1]; if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
    char b = dot[2]; if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
    char c = dot[3]; if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    if ((a == 'd' && b == '8' && c == '8') || (a == '8' && b == '8' && c == 'd')) return FDD_KIND_D88;
    if (a == 'd' && b == 'i' && c == 'm') return FDD_KIND_DIM;
    return FDD_KIND_XDF;
}

static uint8_t *fdd_slot_img(int drive) {
    if (drive == 0) return g_fdd0;
    if (drive == 1) return g_fdd1;
    return NULL;
}

static int fdd_store(int drive, const char *path, int kind) {
    FILE *fp = fopen(path, "rb");
    if (!fp) return 0;
    if (fseek(fp, 0, SEEK_END) != 0) { fclose(fp); return 0; }
    long sz = ftell(fp);
    if (sz <= 0 || fseek(fp, 0, SEEK_SET) != 0) { fclose(fp); return 0; }
    int need = (kind == FDD_KIND_XDF) ? FDD_SIZE : (int)sz;
    if (kind != FDD_KIND_XDF && (sz > FDD_MAX_IMAGE || sz < 16)) { fclose(fp); return 0; }
    uint8_t **img = (drive == 0) ? &g_fdd0 : &g_fdd1;
    if (!*img || g_fdd_cap[drive] < need) {
        uint8_t *buf = (uint8_t *)calloc(1, (size_t)need);
        if (!buf) { fclose(fp); return 0; }
        free(*img);
        *img = buf;
        g_fdd_cap[drive] = need;
    } else {
        memset(*img, 0, (size_t)g_fdd_cap[drive]);
    }
    int want = (kind == FDD_KIND_XDF) ? (int)((sz < FDD_SIZE) ? sz : FDD_SIZE) : (int)sz;
    size_t n = fread(*img, 1, (size_t)want, fp);
    fclose(fp);
    if (n == 0) return 0;
    g_fdd_len[drive] = (int)n;
    g_fdd_kind[drive] = kind;
    g_fdd_trk[drive] = -1;
    g_fdd_cur[drive] = 0;
    g_fdd_d88_top[drive] = 0;
    g_fdd_d88_cur[drive] = 0;
    return 1;
}

static int dim_track_ok(const uint8_t *img, int len, int trk) {
    if (!img || len < FDD_DIM_HEADER || trk < 0 || trk >= 170) return 0;
    int type = img[0];
    int limit = (type == 0) ? 153 : 159;
    if (type != 0 && type != 1 && type != 2 && type != 3 && type != 9) return 0;
    if (trk > limit && !img[255]) return 0;
    return img[1 + trk] ? 1 : 0;
}

static int dim_pos(const uint8_t *img, int c, int h, int r, int n) {
    int type = img[0];
    int rr = r;
    int hh = h;
    int unit = 0;
    int sct = 1024;
    if (type == 0) {
        if (c < 0 || c > 84 || hh < 0 || hh > 1 || rr < 1 || rr > 8 || n != 3) return 0;
        unit = 1024 * 8;
    } else if (type == 1) {
        if (rr > 9) rr -= 9;
        if (c < 0 || c > 84 || hh < 0 || hh > 1 || rr < 1 || rr > 9 || n != 3) return 0;
        unit = 1024 * 9;
    } else if (type == 3) {
        hh &= 1;
        if (c < 0 || c > 84 || hh < 0 || hh > 1 || rr < 1 || rr > 9 || n != 3) return 0;
        unit = 1024 * 9;
    } else if (type == 2) {
        if (c < 0 || c > 84 || hh < 0 || hh > 1 || rr < 1 || rr > 15 || n != 2) return 0;
        unit = 512 * 15;
        sct = 512;
    } else if (type == 9) {
        if (c < 0 || c > 84 || hh < 0 || hh > 1 || rr < 1 || rr > 18 || n != 2) return 0;
        unit = 512 * 18;
        sct = 512;
    } else {
        return 0;
    }
    return unit * (c * 2 + hh) + (rr - 1) * sct + FDD_DIM_HEADER;
}

static int dim_inc(int type, int r) {
    if (type == 0) return (r + 1) & 7;
    if (type == 1 && r > 8) r -= 9;
    if (type == 1 || type == 3) return (r + 1) % 9;
    if (type == 2) return (r + 1) % 15;
    if (type == 9) return (r + 1) % 18;
    return r;
}

static int d88_track_ptr(const uint8_t *img, int len, int trk, uint32_t *out) {
    uint32_t ptr, fd_size;
    if (!img || trk < 0 || trk > 163 || len < FDD_D88_HEADER) return 0;
    memcpy(&fd_size, img + 28, 4);
    memcpy(&ptr, img + 32 + trk * 4, 4);
    if (ptr < FDD_D88_HEADER || ptr >= fd_size || ptr >= (uint32_t)len) return 0;
    *out = ptr;
    return 1;
}

static int d88_match(uint8_t *img, int len, uint32_t top, int c, int h, int r, int n,
                     uint32_t *payload, int *paylen, uint32_t *next) {
    uint32_t p = top;
    int count = 65535;
    for (int s = 0; s < count; s++) {
        uint32_t size, np;
        int sectors;
        if (p + 16 > (uint32_t)len) return 0;
        sectors = img[p + 4] | (img[p + 5] << 8);
        size = (uint32_t)(img[p + 14] | (img[p + 15] << 8));
        if (s == 0) count = sectors > 0 ? sectors : 0;
        if (count <= 0 || p + 16 + size > (uint32_t)len) return 0;
        np = p + 16 + size;
        if (img[p] == (uint8_t)c && img[p + 1] == (uint8_t)h && img[p + 2] == (uint8_t)r && img[p + 3] == (uint8_t)n) {
            *payload = p + 16;
            *paylen = (int)size;
            *next = (s + 1 >= count) ? top : np;
            return 1;
        }
        p = np;
    }
    return 0;
}

static int fdd_seek_kind(int drive, int trk) {
    uint8_t *img = fdd_slot_img(drive);
    int len = g_fdd_len[drive];
    int kind = g_fdd_kind[drive];
    if (!img) return 0;
    if (kind == FDD_KIND_XDF) {
        if (trk < 0 || trk > 153) return 0;
        if (g_fdd_trk[drive] != trk) g_fdd_cur[drive] = 0;
        g_fdd_trk[drive] = trk;
        return 1;
    }
    if (kind == FDD_KIND_DIM) {
        if (trk < 0 || trk > 169 || !dim_track_ok(img, len, trk)) return 0;
        if (g_fdd_trk[drive] != trk) g_fdd_cur[drive] = 0;
        g_fdd_trk[drive] = trk;
        return 1;
    }
    if (kind == FDD_KIND_D88) {
        uint32_t ptr = 0;
        if (!d88_track_ptr(img, len, trk, &ptr)) return 0;
        if (g_fdd_d88_top[drive] != ptr) {
            g_fdd_d88_cur[drive] = ptr;
            g_fdd_d88_top[drive] = ptr;
        }
        g_fdd_trk[drive] = trk;
        return 1;
    }
    return 0;
}

int c_fdd_load_file(int32_t drive, const uint8_t *path_bytes, int path_len) {
    char path[MAX_PATH];
    bind_path(path_bytes, path_len, path, MAX_PATH);
    if (path[0] == 0) return 0;
    if (drive != 0 && drive != 1) return 0;
    int kind = fdd_kind_of(path);
    if (!fdd_store(drive, path, kind)) return 0;
    int was = (drive == 0 ? g_fdd0_loaded : g_fdd1_loaded) ? 1 : 0;
    if (drive == 0) {
        strncpy(g_fdd0_path, path, MAX_PATH - 1);
        g_fdd0_loaded = true;
    } else {
        strncpy(g_fdd1_path, path, MAX_PATH - 1);
        g_fdd1_loaded = true;
    }
    if (was) fdd_media_raise();
    g_fdd_delay[drive] = 3;
    return 1;
}

void c_fdd_eject(int32_t drive) {
    if (drive != 0 && drive != 1) return;
    int was = (drive == 0 ? g_fdd0_loaded : g_fdd1_loaded) ? 1 : 0;
    uint8_t *img = fdd_slot_img(drive);
    if (img && g_fdd_cap[drive] > 0) memset(img, 0, (size_t)g_fdd_cap[drive]);
    if (drive == 0) {
        g_fdd0_loaded = false;
        g_fdd0_path[0] = '\0';
    } else {
        g_fdd1_loaded = false;
        g_fdd1_path[0] = '\0';
    }
    g_fdd_kind[drive] = 0;
    g_fdd_len[drive] = 0;
    g_fdd_trk[drive] = -1;
    g_fdd_cur[drive] = 0;
    g_fdd_d88_top[drive] = 0;
    g_fdd_d88_cur[drive] = 0;
    if (was) fdd_media_raise();
}

bool c_fdd_is_loaded(int32_t drive) {
    if (drive == 0) return g_fdd0_loaded;
    if (drive == 1) return g_fdd1_loaded;
    return false;
}

int c_hdd_load_file(int32_t drive, const uint8_t *path_bytes, int path_len) {
    char path[MAX_PATH];
    bind_path(path_bytes, path_len, path, MAX_PATH);
    if (path[0] == 0 || drive != 0) return 0;
    if (!g_hdd0) g_hdd0 = (uint8_t *)calloc(1, HDD_SIZE);
    if (!g_hdd0) return 0;
    memset(g_hdd0, 0, HDD_SIZE);
    int n = c_file_read((const uint8_t *)path, (int)strlen(path), g_hdd0, HDD_SIZE);
    if (n > 0) {
        strncpy(g_hdd0_path, path, MAX_PATH - 1);
        g_hdd0_path[MAX_PATH - 1] = '\0';
        g_hdd0_loaded = true;
        g_hdd0_len = n;
        g_sasi_reset_req = 1;
        return 1;
    }
    g_hdd0_loaded = false;
    g_hdd0_len = 0;
    return 0;
}

void c_hdd_eject(int32_t drive) {
    if (drive == 0) {
        if (g_hdd0) memset(g_hdd0, 0, HDD_SIZE);
        g_hdd0_loaded = false;
        g_hdd0_len = 0;
        g_hdd0_path[0] = '\0';
        g_sasi_reset_req = 1;
    }
}

bool c_hdd_is_loaded(int32_t drive) {
    if (drive == 0) return g_hdd0_loaded;
    return false;
}

int c_hdd_read_sector(uint32_t sector, uint8_t *dst) {
    uint64_t off;
    if (!dst) return -1;
    memset(dst, 0, 256);
    if (!g_hdd0_loaded || !g_hdd0 || g_hdd0_len < 256) return -1;
    off = ((uint64_t)sector) << 8;
    if (off + 256 > (uint64_t)g_hdd0_len) return 0;
    memcpy(dst, g_hdd0 + off, 256);
    return 1;
}

int c_hdd_write_sector(uint32_t sector, const uint8_t *src) {
    uint64_t off;
    if (!src) return -1;
    if (!g_hdd0_loaded || !g_hdd0 || g_hdd0_len < 256) return -1;
    off = ((uint64_t)sector) << 8;
    if (off + 256 > (uint64_t)g_hdd0_len) return 0;
    memcpy(g_hdd0 + off, src, 256);
    return 1;
}

/* SASI phase lives in x68k_sasi.goose. This flag asks that code to reset
 * after the image is loaded or ejected. */
int c_hdd_unit_ok(void) {
    return (g_hdd0_loaded && g_hdd0 && g_hdd0_len >= 256) ? 1 : 0;
}

int c_hdd_take_sasi_reset(void) {
    int v = g_sasi_reset_req;
    g_sasi_reset_req = 0;
    return v;
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

static int path_is_hdd(const char *path) {
    const char *dot = strrchr(path, '.');
    if (!dot || !dot[1] || !dot[2] || !dot[3] || dot[4]) return 0;
    char a = dot[1]; if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
    char b = dot[2]; if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
    char c = dot[3]; if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    return a == 'h' && b == 'd' && (c == 'f' || c == 's');
}

int x68k_mem_init(const uint8_t *sys_bytes, int sys_len, const uint8_t *floppy_bytes, int floppy_len) {
    char sys_dir[MAX_PATH];
    char floppy_path[MAX_PATH];
    if (g_mem_ready) return 0; // Explicit destroy before a new host session.
    bind_path(sys_bytes, sys_len, sys_dir, MAX_PATH);
    bind_path(floppy_bytes, floppy_len, floppy_path, MAX_PATH);
    c_fdd_media_reset();
    g_sys_dir[0] = '\0';
    if (sys_dir[0]) {
        strncpy(g_sys_dir, sys_dir, MAX_PATH - 1);
        g_sys_dir[MAX_PATH - 1] = '\0';
    }
    if (!g_ram) g_ram = (uint8_t *)host_calloc(1, (size_t)g_ram_bytes);
    if (!g_tvram_bound && !g_tvram) g_tvram = (uint8_t *)host_calloc(1, TVRAM_SIZE);
    if (!g_gvram_bound && !g_gvram) g_gvram = (uint8_t *)host_calloc(1, GVRAM_SIZE);
    if (!g_cgrom) g_cgrom = (uint8_t *)host_calloc(1, CGROM_SIZE);
    if (!g_iplrom) g_iplrom = (uint8_t *)host_calloc(1, IPL_SIZE);
    if (!g_sram) g_sram = (uint8_t *)host_calloc(1, SRAM_SIZE);
    if (!g_fdd0) g_fdd0 = (uint8_t *)host_calloc(1, FDD_SIZE);
    if (!g_fb) g_fb = (uint32_t *)host_calloc(1, FB_MAX_PIXELS * sizeof(uint32_t));

    if (!g_vcreg) g_vcreg = (uint8_t *)host_calloc(1, VCREG_SIZE);
    if (!g_video_bound) {
        if (!g_pal) g_pal = (uint8_t *)host_calloc(1, PAL_SIZE);
        if (!g_sprite) g_sprite = (uint8_t *)host_calloc(1, SPRITE_SIZE);
        if (!g_bgreg) g_bgreg = (uint8_t *)host_calloc(1, BGREG_SIZE);
        if (!g_bgram) g_bgram = (uint8_t *)host_calloc(1, BGRAM_SIZE);
        if (!g_bg_chr8) g_bg_chr8 = (uint8_t *)host_calloc(1, 8 * 8 * 256);
        if (!g_bg_chr16) g_bg_chr16 = (uint8_t *)host_calloc(1, 16 * 16 * 256);
    }
    if (!g_ram || !g_tvram || !g_gvram || !g_cgrom || !g_iplrom || !g_sram ||
        !g_fdd0 || !g_fb || !g_vcreg || !g_pal || !g_sprite || !g_bgreg ||
        !g_bgram || !g_bg_chr8 || !g_bg_chr16) {
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

    // .hdf / .hds are SASI images. Everything else stays a floppy.
    if (floppy_path[0]) {
        if (path_is_hdd(floppy_path))
            c_hdd_load_file(0, (const uint8_t *)floppy_path, (int)strlen(floppy_path));
        else
            c_fdd_load_file(0, (const uint8_t *)floppy_path, (int)strlen(floppy_path));
    }

    g_mem_ready = 1;
    return 1;
}



static void save_sram_file(void) {
    char path[MAX_PATH];
    FILE *f;
    if (!g_mem_ready || !g_sram || !g_sys_dir[0]) return;
    snprintf(path, sizeof(path), "%s\\sram.dat", g_sys_dir);
    f = fopen(path, "wb");
    if (!f) return;
    fwrite(g_sram, 1, SRAM_SIZE, f);
    fclose(f);
}

void x68k_mem_destroy(void) {
    save_sram_file();
    // Stop publications before dropping any borrowed array or scalar view.
    c_dma_vec_bind(NULL);
    c_fdd_media_bind(NULL);
    g_ram_limit_slot = NULL;
    g_screen_w_slot = g_screen_h_slot = NULL;
    g_machine_epoch = 0;
    g_mem_ready = 0;
    state_banks_clear();
    c_sound_cleanup();
    if (!g_ram_bound && g_ram) free(g_ram);
    g_ram = NULL;
    g_ram_bound = 0;
    if (!g_tvram_bound && g_tvram) free(g_tvram);
    g_tvram = NULL;
    g_tvram_bound = 0;
    if (!g_gvram_bound && g_gvram) free(g_gvram);
    g_gvram = NULL;
    g_gvram_bound = 0;
    if (!g_cgrom_bound && g_cgrom) free(g_cgrom);
    g_cgrom = NULL;
    g_cgrom_bound = 0;
    if (!g_ipl_bound && g_iplrom) free(g_iplrom);
    g_iplrom = NULL;
    g_ipl_bound = 0;
    if (!g_sram_bound && g_sram) free(g_sram);
    g_sram = NULL;
    g_sram_bound = 0;
    if (g_fdd0) { free(g_fdd0); g_fdd0 = NULL; }
    if (g_fdd1) { free(g_fdd1); g_fdd1 = NULL; }
    if (g_hdd0) { free(g_hdd0); g_hdd0 = NULL; }
    if (!g_fb_bound && g_fb) free(g_fb);
    g_fb = NULL;
    g_fb_bound = 0;

    if (!g_vcreg_bound && g_vcreg) free(g_vcreg);
    g_vcreg = NULL;
    g_vcreg_bound = 0;
    if (!g_video_bound) {
        if (g_pal) free(g_pal);
        if (g_sprite) free(g_sprite);
        if (g_bgreg) free(g_bgreg);
        if (g_bgram) free(g_bgram);
        if (g_bg_chr8) free(g_bg_chr8);
        if (g_bg_chr16) free(g_bg_chr16);
    }
    g_pal = NULL;
    g_sprite = NULL;
    g_bgreg = NULL;
    g_bgram = NULL;
    g_bg_chr8 = NULL;
    g_bg_chr16 = NULL;
    g_video_bound = 0;

    g_fdd0_loaded = false;
    g_fdd1_loaded = false;
    g_hdd0_loaded = false;
    g_hdd0_len = 0;
    memset(g_fdd_cap, 0, sizeof(g_fdd_cap));
    memset(g_fdd_len, 0, sizeof(g_fdd_len));
    memset(g_fdd_kind, 0, sizeof(g_fdd_kind));
    memset(g_fdd_trk, 0, sizeof(g_fdd_trk));
    memset(g_fdd_cur, 0, sizeof(g_fdd_cur));
    memset(g_fdd_d88_top, 0, sizeof(g_fdd_d88_top));
    memset(g_fdd_d88_cur, 0, sizeof(g_fdd_d88_cur));
    c_fdd_media_reset();
    g_sasi_reset_req = 0;
    g_frame_ready = 0;
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

void c_tvram_bind(uint8_t *tvram) {
    if (!tvram) return;
    if (!g_tvram_bound) {
        free(g_tvram);
        g_tvram_bound = 1;
    }
    g_tvram = tvram;
}

uint8_t c_mem_read_tvram(int32_t off) {
    if (g_tvram && off >= 0 && off < TVRAM_SIZE) return g_tvram[off];
    return 0;
}

void c_mem_write_tvram(int32_t off, uint8_t val) {
    if (g_tvram && off >= 0 && off < TVRAM_SIZE) g_tvram[off] = val;
}

void c_mem_clear_tvram(void) {
    if (g_tvram) {
        memset(g_tvram, 0, TVRAM_SIZE);
    }
}

int c_frame_ready(void) {
    return g_frame_ready;
}

void c_set_frame_ready(int32_t ready) {
    g_frame_ready = ready ? 1 : 0;
}

void c_fb_bind(uint32_t *fb) {
    if (!fb) return;
    if (!g_fb_bound) {
        free(g_fb);
        g_fb_bound = 1;
    }
    g_fb = fb;
}

void c_mem_reset_display(void) {
    if (g_tvram) memset(g_tvram, 0, TVRAM_SIZE);
    if (g_pal) memset(g_pal, 0, PAL_SIZE);
    if (g_sprite) memset(g_sprite, 0, SPRITE_SIZE);
    if (g_bgreg) memset(g_bgreg, 0, BGREG_SIZE);
    if (g_bgram) memset(g_bgram, 0, BGRAM_SIZE);
    if (g_bg_chr8) memset(g_bg_chr8, 0, 8 * 8 * 256);
    if (g_bg_chr16) memset(g_bg_chr16, 0, 16 * 16 * 256);
    c_clear_framebuffer(0xFF000000);
    g_frame_ready = 0;
}

void c_gvram_bind(uint8_t *gvram) {
    if (!gvram) return;
    if (!g_gvram_bound) {
        free(g_gvram);
        g_gvram_bound = 1;
    }
    g_gvram = gvram;
}

uint8_t c_mem_read_gvram(int32_t off) {
    if (!g_gvram) return 0;
    int32_t a = off & 0x1FFFFF;
    if (a < GVRAM_SIZE) return g_gvram[a];
    return 0;
}

void c_mem_write_gvram(int32_t off, uint8_t val) {
    if (!g_gvram) return;
    int32_t a = off & 0x1FFFFF;
    if (a < GVRAM_SIZE) g_gvram[a] = val;
}

void c_mem_clear_gvram(void) {
    if (g_gvram) memset(g_gvram, 0, GVRAM_SIZE);
}

/* px68k gvram.c. Pages share the 512KB array. R20 selects the packing. */
static int gvram_type(uint8_t r20) {
    if (r20 & 8) return 4;
    if (r20 & 4) return 0;
    return (r20 & 3) + 1;
}

static uint32_t gvram_addr1024(uint32_t adr) {
    return ((adr & 0xff800u) >> 1) + (adr & 0x3ffu);
}

uint8_t c_mem_gvram_cpu_read(int32_t off, uint8_t r20) {
    if (!g_gvram || off < 0) return 0;
    uint32_t adr = (uint32_t)off & 0x1fffffu;
    int type = gvram_type(r20);
    if (type == 0) {
        uint32_t i;
        if ((adr & 1) == 0) return 0;
        i = gvram_addr1024(adr);
        if ((adr & 0x100000) == 0) i ^= 1;
        if (i >= GVRAM_SIZE) return 0;
        if (adr & 0x400) return (uint8_t)(g_gvram[i] >> 4);
        return (uint8_t)(g_gvram[i] & 0x0f);
    }
    if (type == 1) {
        uint32_t i;
        if ((adr & 1) == 0) return 0;
        if (adr < 0x80000) return (uint8_t)(g_gvram[adr ^ 1] & 0x0f);
        i = adr & 0x7ffff;
        if (adr < 0x100000) return (uint8_t)(g_gvram[i ^ 1] >> 4);
        if (adr < 0x180000) return (uint8_t)(g_gvram[i] & 0x0f);
        return (uint8_t)(g_gvram[i] >> 4);
    }
    if (type == 2 || type == 3) {
        if (adr < 0x80000) {
            if (adr & 1) return g_gvram[adr ^ 1];
            return 0;
        }
        if (adr < 0x100000) {
            adr &= 0x7ffff;
            if (adr & 1) return g_gvram[adr];
            return 0;
        }
        return 0;
    }
    if (adr < 0x80000) return g_gvram[adr ^ 1];
    return 0;
}

void c_mem_gvram_cpu_write(int32_t off, uint8_t val, uint8_t r20) {
    uint32_t adr, i;
    uint8_t cur;
    int type;
    if (!g_gvram || off < 0) return;
    adr = (uint32_t)off & 0x1fffffu;
    type = gvram_type(r20);
    if (type == 0) {
        if ((adr & 1) == 0) return;
        i = gvram_addr1024(adr);
        if ((adr & 0x100000) == 0) i ^= 1;
        if (i >= GVRAM_SIZE) return;
        cur = g_gvram[i];
        if (adr & 0x400) g_gvram[i] = (uint8_t)((cur & 0x0f) | ((val & 0x0f) << 4));
        else g_gvram[i] = (uint8_t)((cur & 0xf0) | (val & 0x0f));
        return;
    }
    if (type == 1) {
        if ((adr & 1) == 0) return;
        if (adr < 0x80000) {
            i = adr ^ 1;
            g_gvram[i] = (uint8_t)((g_gvram[i] & 0xf0) | (val & 0x0f));
            return;
        }
        i = adr & 0x7ffff;
        if (adr < 0x100000) {
            i ^= 1;
            g_gvram[i] = (uint8_t)((g_gvram[i] & 0x0f) | (val << 4));
            return;
        }
        if (adr < 0x180000) {
            g_gvram[i] = (uint8_t)((g_gvram[i] & 0xf0) | (val & 0x0f));
            return;
        }
        g_gvram[i] = (uint8_t)((g_gvram[i] & 0x0f) | (val << 4));
        return;
    }
    if (type == 2 || type == 3) {
        if ((adr & 1) == 0) return;
        if (adr < 0x80000) {
            g_gvram[adr ^ 1] = val;
            return;
        }
        if (adr < 0x100000) {
            g_gvram[adr & 0x7ffff] = val;
        }
        return;
    }
    if (adr < 0x80000) g_gvram[adr ^ 1] = val;
}

void c_video_bind(uint8_t *pal, uint8_t *sprite, uint8_t *bgreg, uint8_t *bgram, uint8_t *chr8, uint8_t *chr16) {
    if (!pal || !sprite || !bgreg || !bgram || !chr8 || !chr16) return;
    if (!g_video_bound) {
        free(g_pal);
        free(g_sprite);
        free(g_bgreg);
        free(g_bgram);
        free(g_bg_chr8);
        free(g_bg_chr16);
        g_video_bound = 1;
    }
    g_pal = pal;
    g_sprite = sprite;
    g_bgreg = bgreg;
    g_bgram = bgram;
    g_bg_chr8 = chr8;
    g_bg_chr16 = chr16;
}

uint8_t c_mem_read_pal(int32_t off) {
    if (g_pal && off >= 0 && off < PAL_SIZE) return g_pal[off];
    return 0xFF;
}

void c_mem_write_pal(int32_t off, uint8_t val) {
    if (g_pal && off >= 0 && off < PAL_SIZE) g_pal[off] = val;
}

void c_vcreg_bind(uint8_t *vcreg) {
    if (!vcreg) return;
    if (!g_vcreg_bound) {
        if (g_vcreg && g_vcreg != vcreg)
            memcpy(vcreg, g_vcreg, VCREG_SIZE);
        free(g_vcreg);
        g_vcreg_bound = 1;
    }
    g_vcreg = vcreg;
}

uint8_t c_mem_read_sprite(int32_t off) {
    if (g_sprite && off >= 0 && off < SPRITE_SIZE) return g_sprite[off];
    return 0xFF;
}

void c_set_current_frame(int frame) {
    s_current_frame = frame;
}
int c_get_current_frame() {
    return s_current_frame;
}
void c_log_duff(uint32_t a5, uint32_t a6, uint32_t d7, uint32_t ret_pc) {
}
void c_log_ram_write(uint32_t addr, uint8_t val, uint32_t pc) {
    (void)addr;
    (void)val;
    (void)pc;
}

void c_mem_write_sprite(int32_t off, uint8_t val) {
    if (g_sprite && off >= 0 && off < SPRITE_SIZE) g_sprite[off] = val;
}

uint8_t c_mem_read_bg_reg(int32_t off) {
    if (g_bgreg && off >= 0 && off < BGREG_SIZE) return g_bgreg[off];
    return 0xFF;
}

void c_mem_write_bg_reg(int32_t off, uint8_t val) {
    if (g_bgreg && off >= 0 && off < BGREG_SIZE) g_bgreg[off] = val;
}

uint8_t c_mem_read_bgram(int32_t off) {
    if (g_bgram && off >= 0 && off < BGRAM_SIZE) return g_bgram[off];
    return 0xFF;
}

void c_mem_write_bgram(int32_t off, uint8_t val) {
    if (!g_bgram || off < 0 || off >= BGRAM_SIZE) return;
    g_bgram[off] = val;
    if (g_bg_chr8 && off < 0x2000) {
        g_bg_chr8[off * 2]     = val >> 4;
        g_bg_chr8[off * 2 + 1] = val & 15;
    }
    if (g_bg_chr16) {
        uint32_t bg16chr = ((off & 3) * 2) + ((off & 0x3C) * 4) + ((off & 0x40) >> 3) + ((off & 0x7F80) * 2);
        if (bg16chr + 1 < (16 * 16 * 256)) {
            g_bg_chr16[bg16chr]     = val >> 4;
            g_bg_chr16[bg16chr + 1] = val & 15;
        }
    }
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

static uint8_t *fdd_image(int32_t drive, bool *loaded) {
    if (drive == 0) { *loaded = g_fdd0_loaded; return g_fdd0; }
    if (drive == 1) { *loaded = g_fdd1_loaded; return g_fdd1; }
    *loaded = false;
    return NULL;
}

int c_fdd_seek(int32_t drive, int32_t trk) {
    bool loaded = false;
    if (!fdd_image(drive, &loaded) || !loaded) return 0;
    return fdd_seek_kind(drive, trk);
}

int c_fdd_read_fdc(int32_t drive, int32_t trk, int32_t c, int32_t h, int32_t r, int32_t n, uint8_t *dst) {
    bool loaded = false;
    uint8_t *img = fdd_image(drive, &loaded);
    if (!img || !dst || !loaded || drive < 0 || drive > 1) return 0;
    if (!fdd_seek_kind(drive, trk)) return 0;
    int kind = g_fdd_kind[drive];
    int len = g_fdd_len[drive];
    if (kind == FDD_KIND_XDF) {
        if (((c << 1) + (h & 1)) != trk) return 0;
        if (r < 1 || r > 8 || n != 3 || (h != 0 && h != 1)) return 0;
        int offset = (trk * 8 + (r - 1)) * 1024;
        if (offset + 1024 > FDD_SIZE) return 0;
        memcpy(dst, img + offset, 1024);
        g_fdd_cur[drive] = r & 7;
        return 1;
    }
    if (kind == FDD_KIND_DIM) {
        if (((c << 1) + (h & 1)) != g_fdd_trk[drive]) return 0;
        if (!dim_track_ok(img, len, (c << 1) + (h & 1))) return 0;
        int pos = dim_pos(img, c, h, r, n);
        int nbytes = (n == 2) ? 512 : 1024;
        if (pos <= 0 || pos + nbytes > len) return 0;
        memcpy(dst, img + pos, (size_t)nbytes);
        g_fdd_cur[drive] = dim_inc(img[0], r - 1);
        return 1;
    }
    if (kind == FDD_KIND_D88) {
        uint32_t payload = 0, next = 0;
        int paylen = 0;
        int nbytes = (n > 0) ? (128 << n) : 1024;
        if (!d88_match(img, len, g_fdd_d88_top[drive], c, h, r, n, &payload, &paylen, &next)) return 0;
        if (nbytes > paylen) nbytes = paylen;
        if (nbytes > 8192) nbytes = 8192;
        memcpy(dst, img + payload, (size_t)nbytes);
        g_fdd_d88_cur[drive] = next;
        return 1;
    }
    return 0;
}

int c_fdd_write_fdc(int32_t drive, int32_t trk, int32_t c, int32_t h, int32_t r, int32_t n, const uint8_t *src) {
    bool loaded = false;
    uint8_t *img = fdd_image(drive, &loaded);
    if (!img || !src || !loaded || drive < 0 || drive > 1) return 0;
    if (!fdd_seek_kind(drive, trk)) return 0;
    int kind = g_fdd_kind[drive];
    int len = g_fdd_len[drive];
    if (kind == FDD_KIND_XDF) {
        if (((c << 1) + (h & 1)) != trk) return 0;
        if (r < 1 || r > 8 || n != 3 || (h != 0 && h != 1)) return 0;
        int offset = (trk * 8 + (r - 1)) * 1024;
        if (offset + 1024 > FDD_SIZE) return 0;
        memcpy(img + offset, src, 1024);
        g_fdd_cur[drive] = r & 7;
        return 1;
    }
    if (kind == FDD_KIND_DIM) {
        if (((c << 1) + (h & 1)) != g_fdd_trk[drive]) return 0;
        int pos = dim_pos(img, c, h, r, n);
        int nbytes = (n == 2) ? 512 : 1024;
        if (pos <= 0 || pos + nbytes > len) return 0;
        memcpy(img + pos, src, (size_t)nbytes);
        g_fdd_cur[drive] = dim_inc(img[0], r - 1);
        return 1;
    }
    if (kind == FDD_KIND_D88) {
        uint32_t payload = 0, next = 0;
        int paylen = 0;
        int nbytes = (n > 0) ? (128 << n) : 1024;
        if (!d88_match(img, len, g_fdd_d88_top[drive], c, h, r, n, &payload, &paylen, &next)) return 0;
        if (nbytes > paylen) nbytes = paylen;
        memcpy(img + payload, src, (size_t)nbytes);
        g_fdd_d88_cur[drive] = next;
        return 1;
    }
    return 0;
}

int c_fdd_current_id(int32_t drive, uint8_t *c, uint8_t *h, uint8_t *r, uint8_t *n) {
    bool loaded = false;
    uint8_t *img = fdd_image(drive, &loaded);
    if (!img || !loaded || !c || !h || !r || !n || drive < 0 || drive > 1) return 0;
    int trk = g_fdd_trk[drive];
    if (g_fdd_kind[drive] == FDD_KIND_XDF) {
        if (trk < 0 || trk > 153) return 0;
        *c = (uint8_t)(trk >> 1);
        *h = (uint8_t)(trk & 1);
        *r = (uint8_t)(g_fdd_cur[drive] + 1);
        *n = 3;
        return 1;
    }
    if (g_fdd_kind[drive] == FDD_KIND_DIM) {
        if (!dim_track_ok(img, g_fdd_len[drive], trk)) return 0;
        int type = img[0];
        int cc = trk >> 1;
        int hh = trk & 1;
        int rr = g_fdd_cur[drive] + 1;
        int nn = 3;
        if (type == 1) {
            if (cc || hh || rr != 1) rr += 9;
        } else if (type == 3) {
            if (cc || hh || rr != 1) hh += 0x80;
        } else if (type == 2 || type == 9) {
            nn = 2;
        }
        *c = (uint8_t)cc;
        *h = (uint8_t)hh;
        *r = (uint8_t)rr;
        *n = (uint8_t)nn;
        return 1;
    }
    if (g_fdd_kind[drive] == FDD_KIND_D88) {
        uint32_t p = g_fdd_d88_cur[drive];
        if (p + 4 > (uint32_t)g_fdd_len[drive]) return 0;
        *c = img[p];
        *h = img[p + 1];
        *r = img[p + 2];
        *n = img[p + 3];
        return 1;
    }
    return 0;
}

int c_fdd_read_sector(int32_t drive, int32_t trk, int32_t sec, uint8_t *dst_1024) {
    bool loaded = false;
    uint8_t *img = fdd_image(drive, &loaded);
    if (!img || !dst_1024 || !loaded) return 0;
    if (drive >= 0 && drive <= 1 && (g_fdd_kind[drive] == FDD_KIND_D88 || g_fdd_kind[drive] == FDD_KIND_DIM)) {
        return c_fdd_read_fdc(drive, trk, trk >> 1, trk & 1, sec, 3, dst_1024);
    }
    if (trk < 0 || trk >= 154 || sec < 1 || sec > 8) return 0;
    int offset = (trk * 8 + (sec - 1)) * 1024;
    if (offset + 1024 > FDD_SIZE) return 0;
    memcpy(dst_1024, &img[offset], 1024);
    return 1;
}

int c_fdd_write_sector(int32_t drive, int32_t trk, int32_t sec, const uint8_t *src_1024) {
    bool loaded = false;
    uint8_t *img = fdd_image(drive, &loaded);
    if (!img || !src_1024 || !loaded) return 0;
    if (drive >= 0 && drive <= 1 && (g_fdd_kind[drive] == FDD_KIND_D88 || g_fdd_kind[drive] == FDD_KIND_DIM)) {
        return c_fdd_write_fdc(drive, trk, trk >> 1, trk & 1, sec, 3, src_1024);
    }
    if (trk < 0 || trk >= 154 || sec < 1 || sec > 8) return 0;
    int offset = (trk * 8 + (sec - 1)) * 1024;
    if (offset + 1024 > FDD_SIZE) return 0;
    memcpy(&img[offset], src_1024, 1024);
    return 1;
}



int c_fdd_load_to_ram(int32_t disk_offset, int32_t ram_addr, int32_t bytes) {
    if (!g_fdd0 || !g_ram || !g_fdd0_loaded || bytes <= 0) return 0;
    if (g_fdd_kind[0] != FDD_KIND_XDF) return 0;
    if (disk_offset < 0 || disk_offset + bytes > FDD_SIZE) return 0;
    if (ram_addr < 0 || ram_addr + bytes > g_ram_bytes) return 0;
    memcpy(&g_ram[ram_addr], &g_fdd0[disk_offset], (size_t)bytes);
    return 1;
}



static HWND g_hwnd = NULL;
static HDC g_hdc = NULL;
static int g_scale = 1;
static bool g_is_open = false;
static uint32_t g_keys = 0;
static BITMAPINFO g_bmi;
static int g_pending_cmd = 0;

static void win32_set_scale(int scale);

void c_screen_bind(int32_t *w, int32_t *h) {
    g_screen_w_slot = w;
    g_screen_h_slot = h;
    screen_publish();
}

uint64_t c_machine_epoch(void) { return g_machine_epoch; }

static uint64_t machine_bind_views(const X68kHostViews *v) {
    if (!g_mem_ready || !v) return 0;
#define VIEW_OK(field, count) (v->field.data && v->field.len == (int64_t)(count))
    if (!VIEW_OK(ram, 12582912) || !VIEW_OK(ipl, IPL_SIZE) || !VIEW_OK(cgrom, CGROM_SIZE) ||
        !VIEW_OK(sram, SRAM_SIZE) || !VIEW_OK(tvram, TVRAM_SIZE) || !VIEW_OK(gvram, GVRAM_SIZE) ||
        !VIEW_OK(pal, PAL_SIZE) || !VIEW_OK(vc, VCREG_SIZE) || !VIEW_OK(sprite, SPRITE_SIZE) ||
        !VIEW_OK(bgreg, BGREG_SIZE) || !VIEW_OK(bgram, BGRAM_SIZE) ||
        !VIEW_OK(chr8, 8 * 8 * 256) || !VIEW_OK(chr16, 16 * 16 * 256) ||
        !VIEW_OK(fb, FB_MAX_PIXELS) || !v->ram_limit || !v->screen_w || !v->screen_h ||
        !v->dma_vec || !v->media_irq) return 0;
#undef VIEW_OK
    // All validation precedes registration. No allocation or callbacks here.
    c_dma_vec_bind(NULL); c_fdd_media_bind(NULL);
    if (!g_ram_bound) {
        memset(v->ram.data, 0, (size_t)v->ram.len);
        if (g_ram && g_ram != v->ram.data) memcpy(v->ram.data, g_ram, (size_t)g_ram_bytes);
    }
    c_ram_bind(v->ram.data); c_ram_limit_bind(v->ram_limit);
    c_ipl_bind(v->ipl.data); c_cgrom_bind(v->cgrom.data); c_sram_bind(v->sram.data);
    c_video_bind(v->pal.data, v->sprite.data, v->bgreg.data, v->bgram.data, v->chr8.data, v->chr16.data);
    c_vcreg_bind(v->vc.data); c_tvram_bind(v->tvram.data); c_gvram_bind(v->gvram.data);
    c_fb_bind(v->fb.data); c_screen_bind(v->screen_w, v->screen_h);
    c_dma_vec_bind(v->dma_vec); c_fdd_media_bind(v->media_irq);
    if (++g_machine_epoch_next == 0) ++g_machine_epoch_next;
    g_machine_epoch = g_machine_epoch_next;
    return g_machine_epoch;
}

uint64_t c_machine_bind(X68kByteView ram, X68kByteView ipl, X68kByteView cgrom, X68kByteView sram,
    X68kByteView tvram, X68kByteView gvram, X68kByteView pal, X68kByteView vc, X68kByteView sprite,
    X68kByteView bgreg, X68kByteView bgram, X68kByteView chr8, X68kByteView chr16, X68kPixelView fb,
    int32_t *ram_limit, int32_t *screen_w, int32_t *screen_h, int32_t *dma_vec, int32_t *media_irq) {
    X68kHostViews views = {ram, ipl, cgrom, sram, tvram, gvram, pal, vc, sprite,
        bgreg, bgram, chr8, chr16, fb, ram_limit, screen_w, screen_h, dma_vec, media_irq};
    return machine_bind_views(&views);
}

int c_machine_unbind(uint64_t epoch) {
    if (!epoch || epoch != g_machine_epoch) return 0;
    c_dma_vec_bind(NULL); c_fdd_media_bind(NULL);
    g_ram_limit_slot = NULL;
    g_screen_w_slot = g_screen_h_slot = NULL;
    // These are borrowed from the active emulator, never freed by C.
    g_tvram = g_gvram = g_pal = g_vcreg = g_sprite = g_bgreg = g_bgram = NULL;
    g_bg_chr8 = g_bg_chr16 = NULL;
    g_fb = NULL;
    g_tvram_bound = g_gvram_bound = g_video_bound = g_vcreg_bound = g_fb_bound = 0;
    g_frame_ready = 0;
    g_machine_epoch = 0;
    // RAM/ROM/SRAM are process-lifetime Goose globals; destroy releases views.
    return 1;
}

void c_set_screen_mode(int32_t w, int32_t h) {
    if (w <= 0 || h <= 0) return;
    if (g_src_w == w && g_src_h == h && g_hwnd) return;
    g_src_w = w;
    g_src_h = h;
    screen_publish();
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

void c_clear_framebuffer(uint32_t argb) {
    if (!g_fb) return;
    int total = g_src_w * g_src_h;
    for (int i = 0; i < total; i++) {
        g_fb[i] = argb;
    }
}

void c_set_pixel(int32_t x, int32_t y, uint32_t argb) {
    if (!g_fb || x < 0 || x >= g_src_w || y < 0 || y >= g_src_h) return;
    g_fb[y * g_src_w + x] = argb;
}

uint32_t c_fb_at(int32_t x, int32_t y) {
    if (!g_fb || x < 0 || x >= g_src_w || y < 0 || y >= g_src_h) return 0;
    return g_fb[y * g_src_w + x];
}

static void tvram_store(uint32_t adr, uint8_t data) {
    if (adr < TVRAM_SIZE) g_tvram[adr] = data;
}

/* R23: bit 1 in the mask keeps the old bit. Even CPU address uses 0x2E. */
static void tvram_store_mask(uint32_t adr, uint8_t data, uint8_t r2e, uint8_t r2f) {
    if (adr >= TVRAM_SIZE) return;
    uint8_t m = (adr & 1) ? r2f : r2e;
    uint8_t cur = g_tvram[adr];
    g_tvram[adr] = (uint8_t)((cur & m) | (data & (uint8_t)~m));
}

void c_mem_write_tvram_access(int32_t off, uint8_t val, uint8_t r2a, uint8_t r2b, uint8_t r2e, uint8_t r2f) {
    if (!g_tvram || off < 0) return;
    uint32_t adr = (uint32_t)off & 0x7FFFF;
    if (r2a & 1) {
        adr &= 0x1FFFF;
        if (r2a & 2) {
            if (r2b & 0x10) tvram_store_mask(adr, val, r2e, r2f);
            if (r2b & 0x20) tvram_store_mask(adr + 0x20000, val, r2e, r2f);
            if (r2b & 0x40) tvram_store_mask(adr + 0x40000, val, r2e, r2f);
            if (r2b & 0x80) tvram_store_mask(adr + 0x60000, val, r2e, r2f);
        } else {
            if (r2b & 0x10) tvram_store(adr, val);
            if (r2b & 0x20) tvram_store(adr + 0x20000, val);
            if (r2b & 0x40) tvram_store(adr + 0x40000, val);
            if (r2b & 0x80) tvram_store(adr + 0x60000, val);
        }
    } else if (r2a & 2) {
        tvram_store_mask(adr, val, r2e, r2f);
    } else {
        tvram_store(adr, val);
    }
}

// CRTC Raster Copy
void c_mem_tvram_raster_copy(uint32_t src_line, uint32_t dst_line, uint8_t plane_mask) {
    if (!g_tvram) return;
    uint32_t src = (src_line << 9) & 0x1FFFF;
    uint32_t dst = (dst_line << 9) & 0x1FFFF;
    static const uint32_t plane_offs[4] = { 0, 0x20000, 0x40000, 0x60000 };
    for (int bit = 0; bit < 4; bit++) {
        if (plane_mask & (1 << bit)) {
            memmove(&g_tvram[dst + plane_offs[bit]], &g_tvram[src + plane_offs[bit]], 512);
        }
    }
}

// Keyboard input FIFO
#define KEY_BUF_SIZE 256
static char g_key_fifo[KEY_BUF_SIZE];
static int g_key_head = 0;
static int g_key_tail = 0;

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
        case VK_OEM_5:      return 0x0E; // yen / \
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

int c_vk_to_x68k(int vk, int extended) {
    return (int)vk_to_x68k_code((WPARAM)vk, extended ? 0x01000000 : 0);
}

/* Held host keys that also drive joy1. 超連射68K reads this port for start and shot.
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

static void push_char(char ch) {
    int next = (g_key_head + 1) % KEY_BUF_SIZE;
    if (next != g_key_tail) {
        g_key_fifo[g_key_head] = ch;
        g_key_head = next;
    }
}

int win32_ui_get_char(void) {
    if (g_key_head == g_key_tail) return -1;
    char ch = g_key_fifo[g_key_tail];
    g_key_tail = (g_key_tail + 1) % KEY_BUF_SIZE;
    return (int)(unsigned char)ch;
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
static bool open_file_dialog(HWND owner, const char *filter, char *out_path, int max_len) {
    OPENFILENAMEA ofn;
    memset(&ofn, 0, sizeof(ofn));
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = owner;
    ofn.lpstrFilter = filter;
    ofn.lpstrFile = out_path;
    ofn.nMaxFile = max_len;
    ofn.Flags = OFN_PATHMUSTEXIST | OFN_FILEMUSTEXIST | OFN_NOCHANGEDIR;
    out_path[0] = '\0';
    return GetOpenFileNameA(&ofn) != 0;
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

void c_gui_settings_store(void) {
    c_gui_settings_set_int(GUI_CLOCK, g_cpu_mhz);
    c_gui_settings_set_int(GUI_SCALE, g_scale);
    if (g_sys_dir[0]) c_gui_settings_set_path(GUI_BIOS, (const uint8_t *)g_sys_dir, (int)strlen(g_sys_dir));
    c_gui_settings_set_path(GUI_FD0, (const uint8_t *)g_fdd0_path, g_fdd0_loaded ? (int)strlen(g_fdd0_path) : 0);
    c_gui_settings_set_path(GUI_FD1, (const uint8_t *)g_fdd1_path, g_fdd1_loaded ? (int)strlen(g_fdd1_path) : 0);
    c_gui_settings_set_path(GUI_HDD, (const uint8_t *)g_hdd0_path, g_hdd0_loaded ? (int)strlen(g_hdd0_path) : 0);
    if (!c_gui_settings_save()) fprintf(stderr, "warning: could not save arcl_windows_x68k_goose.ini\n");
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
                c_gui_settings_store();
                return 0;
            }
            switch (id) {
                case 103: g_pending_cmd = 3; break; // Reset
                case 104: g_is_open = false; DestroyWindow(hwnd); break;
                case 201: win32_set_scale(1); break;
                case 202: win32_set_scale(2); break;
                case 211: c_gui_settings_set_int(GUI_WIDTH, 768); c_set_screen_mode(768, 512); break;
                case 212: c_gui_settings_set_int(GUI_WIDTH, 512); c_set_screen_mode(512, 512); break;
                // FD0
                case 401: {
                    char file_buf[MAX_PATH] = {0};
                    if (open_file_dialog(hwnd, "X68000 Disk Images (*.2hd;*.xdf;*.dim;*.d88;*.img;*.bin)\0*.2hd;*.xdf;*.dim;*.d88;*.img;*.bin\0All Files (*.*)\0*.*\0", file_buf, MAX_PATH)) {
                        if (c_fdd_load_file(0, (const uint8_t *)file_buf, (int)strlen(file_buf))) {
                            g_pending_cmd = 3; // Trigger Reboot with new disk
                        }
                    }
                    break;
                }
                case 402: {
                    c_fdd_eject(0);
                    break;
                }
                // FD1
                case 411: {
                    char file_buf[MAX_PATH] = {0};
                    if (open_file_dialog(hwnd, "X68000 Disk Images (*.2hd;*.xdf;*.dim;*.d88;*.img;*.bin)\0*.2hd;*.xdf;*.dim;*.d88;*.img;*.bin\0All Files (*.*)\0*.*\0", file_buf, MAX_PATH)) {
                        c_fdd_load_file(1, (const uint8_t *)file_buf, (int)strlen(file_buf));
                    }
                    break;
                }
                case 412: {
                    c_fdd_eject(1);
                    break;
                }
                // HDD
                case 421: {
                    char file_buf[MAX_PATH] = {0};
                    if (open_file_dialog(hwnd, "X68000 HDD Images (*.hdf;*.hds;*.img)\0*.hdf;*.hds;*.img\0All Files (*.*)\0*.*\0", file_buf, MAX_PATH)) {
                        if (c_hdd_load_file(0, (const uint8_t *)file_buf, (int)strlen(file_buf))) {
                            /* IPL boots a floppy ahead of SASI. Drop floppies and reset. */
                            c_fdd_eject(0);
                            c_fdd_eject(1);
                            g_pending_cmd = 3;
                        }
                    }
                    break;
                }
                case 422: {
                    c_hdd_eject(0);
                    break;
                }
                case 301:
                    MessageBoxA(hwnd,
                        "Goose Sharp X68000 Emulator\nWritten in Goose language!\nSupports Motorola 68000 CPU, MMU, PPU, FD0/FD1/HDD disk insertion, and ARCL MCP.",
                        "About Goose X68000", MB_OK | MB_ICONINFORMATION);
                    break;
                default: break;
            }
            c_gui_settings_store();
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
        case WM_CHAR: {
            char ch = (char)wParam;
            if (ch >= 0x20 || ch == '\r' || ch == '\b' || ch == '\t') {
                push_char(ch);
            }
            return 0;
        }
        case WM_KILLFOCUS:
            c_host_joy_reset();
            return 0;
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

void c_audio_shutdown(void) {
    win32_audio_destroy();
}

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
        /* 再生中のバッファが足りているときは溜めて、短いバッファの継ぎ目を減らす */
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

bool win32_ui_init(const uint8_t *title_bytes, int title_len, int w, int h, int scale) {
    char title_buf[256];
    const char *title;
    bind_path(title_bytes, title_len, title_buf, (int)sizeof(title_buf));
    title = title_buf[0] ? title_buf : NULL;
    if (g_hwnd) return true;
    g_src_w = (w > 0 ? w : 512);
    g_src_h = (h > 0 ? h : 512);
    screen_publish();
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
    // SOCD Cleaner: 左右同時押し、上下同時押しをニュートラル化して超連射68k等の誤ポーズを防止
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

int win32_ui_get_command(void) {
    int cmd = g_pending_cmd;
    g_pending_cmd = 0;
    return cmd;
}

// BMP screenshot saver
int c_save_fb_bmp(const uint8_t *path_bytes, int path_len) {
    char path[MAX_PATH];
    bind_path(path_bytes, path_len, path, MAX_PATH);
    if (path[0] == 0 || !g_fb) return 0;
    FILE *f = fopen(path, "wb");
    if (!f) return 0;

    int w = g_src_w;
    int h = g_src_h;
    int row_bytes = w * 4;
    int image_size = row_bytes * h;
    int file_size = 54 + image_size;

    uint8_t bmp_file_hdr[14] = {
        'B', 'M',
        file_size & 0xFF, (file_size >> 8) & 0xFF, (file_size >> 16) & 0xFF, (file_size >> 24) & 0xFF,
        0, 0, 0, 0,
        54, 0, 0, 0
    };

    uint8_t dib_hdr[40] = {
        40, 0, 0, 0,
        w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF, (w >> 24) & 0xFF,
        h & 0xFF, (h >> 8) & 0xFF, (h >> 16) & 0xFF, (h >> 24) & 0xFF,
        1, 0,
        32, 0,
        0, 0, 0, 0,
        image_size & 0xFF, (image_size >> 8) & 0xFF, (image_size >> 16) & 0xFF, (image_size >> 24) & 0xFF,
        0x13, 0x0B, 0, 0,
        0x13, 0x0B, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0
    };

    fwrite(bmp_file_hdr, 1, 14, f);
    fwrite(dib_hdr, 1, 40, f);

    for (int y = h - 1; y >= 0; y--) {
        const uint32_t *row = &g_fb[y * w];
        fwrite(row, 4, w, f);
    }

    fclose(f);
    return 1;
}

static uint32_t png_crc_update(uint32_t c, const uint8_t *p, int n) {
    int i, b;
    for (i = 0; i < n; i++) {
        c ^= p[i];
        for (b = 0; b < 8; b++) {
            c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1u)));
        }
    }
    return c;
}

static int png_chunk(FILE *f, const char *type, const uint8_t *data, int n) {
    uint8_t lenb[4];
    uint8_t crcb[4];
    uint32_t crc = 0xFFFFFFFFu;
    uint32_t out;
    lenb[0] = (uint8_t)((n >> 24) & 0xFF);
    lenb[1] = (uint8_t)((n >> 16) & 0xFF);
    lenb[2] = (uint8_t)((n >> 8) & 0xFF);
    lenb[3] = (uint8_t)(n & 0xFF);
    if (fwrite(lenb, 1, 4, f) != 4) return 0;
    if (fwrite(type, 1, 4, f) != 4) return 0;
    if (n > 0 && fwrite(data, 1, (size_t)n, f) != (size_t)n) return 0;
    crc = png_crc_update(crc, (const uint8_t *)type, 4);
    if (n > 0) crc = png_crc_update(crc, data, n);
    out = ~crc;
    crcb[0] = (uint8_t)(out >> 24);
    crcb[1] = (uint8_t)(out >> 16);
    crcb[2] = (uint8_t)(out >> 8);
    crcb[3] = (uint8_t)out;
    return fwrite(crcb, 1, 4, f) == 4;
}

int c_save_fb_png(const uint8_t *path_bytes, int path_len) {
    char path[MAX_PATH];
    static const uint8_t sig[8] = { 137, 80, 78, 71, 13, 10, 26, 10 };
    int w, h, raw_n, zcap, zlen, y, x, pos, left;
    uint8_t ihdr[13];
    uint8_t *raw = NULL;
    uint8_t *z = NULL;
    uint32_t s1 = 1, s2 = 0, adler;
    FILE *f;
    bind_path(path_bytes, path_len, path, MAX_PATH);
    if (path[0] == 0 || !g_fb) return 0;
    w = g_src_w;
    h = g_src_h;
    if (w <= 0 || h <= 0 || w > FB_MAX_W || h > FB_MAX_H) return 0;
    raw_n = h * (1 + w * 3);
    raw = (uint8_t *)malloc((size_t)raw_n);
    if (!raw) return 0;
    pos = 0;
    for (y = 0; y < h; y++) {
        raw[pos++] = 0;
        for (x = 0; x < w; x++) {
            uint32_t px = g_fb[y * w + x];
            raw[pos++] = (uint8_t)((px >> 16) & 0xFF);
            raw[pos++] = (uint8_t)((px >> 8) & 0xFF);
            raw[pos++] = (uint8_t)(px & 0xFF);
        }
    }
    zcap = 2 + ((raw_n + 65534) / 65535) * 5 + raw_n + 4;
    z = (uint8_t *)malloc((size_t)zcap);
    if (!z) { free(raw); return 0; }
    z[0] = 0x78;
    z[1] = 0x01;
    zlen = 2;
    left = raw_n;
    pos = 0;
    while (left > 0) {
        int chunk = left > 65535 ? 65535 : left;
        int i;
        z[zlen++] = (left == chunk) ? 1 : 0;
        z[zlen++] = (uint8_t)(chunk & 0xFF);
        z[zlen++] = (uint8_t)((chunk >> 8) & 0xFF);
        z[zlen++] = (uint8_t)((~chunk) & 0xFF);
        z[zlen++] = (uint8_t)(((~chunk) >> 8) & 0xFF);
        memcpy(z + zlen, raw + pos, (size_t)chunk);
        for (i = 0; i < chunk; i++) {
            s1 = (s1 + raw[pos + i]) % 65521;
            s2 = (s2 + s1) % 65521;
        }
        zlen += chunk;
        pos += chunk;
        left -= chunk;
    }
    free(raw);
    adler = (s2 << 16) | s1;
    z[zlen++] = (uint8_t)(adler >> 24);
    z[zlen++] = (uint8_t)(adler >> 16);
    z[zlen++] = (uint8_t)(adler >> 8);
    z[zlen++] = (uint8_t)adler;
    ihdr[0] = (uint8_t)(w >> 24); ihdr[1] = (uint8_t)(w >> 16);
    ihdr[2] = (uint8_t)(w >> 8); ihdr[3] = (uint8_t)w;
    ihdr[4] = (uint8_t)(h >> 24); ihdr[5] = (uint8_t)(h >> 16);
    ihdr[6] = (uint8_t)(h >> 8); ihdr[7] = (uint8_t)h;
    ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
    f = fopen(path, "wb");
    if (!f) { free(z); return 0; }
    if (fwrite(sig, 1, 8, f) != 8 || !png_chunk(f, "IHDR", ihdr, 13) || !png_chunk(f, "IDAT", z, zlen) || !png_chunk(f, "IEND", NULL, 0)) {
        fclose(f);
        free(z);
        return 0;
    }
    fclose(f);
    free(z);
    return 1;
}

void c_print_hex(uint32_t val) {
    printf("%08X", val);
    fflush(stdout);
}

void c_print_hex16(uint16_t val) {
    printf("%04X", val);
    fflush(stdout);
}

void c_eprint_hex(uint32_t val) {
    fprintf(stderr, "%08X", val);
}

void c_eprint_hex16(uint16_t val) {
    fprintf(stderr, "%04X", val);
}

// -----------------------------------------------------------------------------
// Full Hardware State Save / Load for ARCL Rollback & State Machine
// -----------------------------------------------------------------------------
#define MAX_ARCL_SLOTS 10
#define ARCL_SLOT_VERSION 5

typedef struct {
    int cpu_mhz;
    uint8_t pia_c;
    uint8_t joy_strobe[2];
    int opm_addr;
    uint8_t opm_shadow[256];
    uint8_t opm_key_on[8];
} ArclIoLatches;

static void io_latches_save(ArclIoLatches *state);
static void io_latches_load(const ArclIoLatches *state);

typedef struct {
    uint32_t version;
    uint64_t generation;
    uint8_t *ram;
    uint8_t *sram;
    uint8_t *sound;
    uint8_t *fdd[2];
    uint8_t *hdd;
    int hdd_len;
    int hdd_loaded;
    int sasi_reset_req;
    int sound_bytes;
    int fdd_cap[2];
    int fdd_len[2];
    int fdd_kind[2];
    int fdd_loaded[2];
    int fdd_trk[2];
    int fdd_cur[2];
    uint32_t fdd_d88_top[2];
    uint32_t fdd_d88_cur[2];
    int fdd_delay[2];
    int fdd_media_enable;
    int fdd_media_pending;
    int ppu_phase;
    ArclIoLatches io;
    bool valid;
    size_t ram_bytes;
} ArclHwSlot;

static ArclHwSlot g_arcl_slots[MAX_ARCL_SLOTS] = {0};
static uint64_t g_state_generation = 0;

// Local fault injection follows the existing test_break_version hook. It is
// used only by native regression tests, never exposed as an MCP tool.
static int g_state_fail_after = -1;
static int g_state_alloc_count = 0;

void c_mem_test_fail_alloc(int after) {
    g_state_fail_after = after;
    g_state_alloc_count = 0;
}

int c_mem_test_alloc_count(void) { return g_state_alloc_count; }

static void *state_alloc(size_t bytes) {
    g_state_alloc_count++;
    if (g_state_fail_after == 0) {
        g_state_fail_after = -1;
        return NULL;
    }
    if (g_state_fail_after > 0) g_state_fail_after--;
    return malloc(bytes);
}

static void slot_dispose(ArclHwSlot *slot) {
    free(slot->ram); free(slot->sram); free(slot->sound);
    free(slot->fdd[0]); free(slot->fdd[1]); free(slot->hdd);
    memset(slot, 0, sizeof(*slot));
}

static int arcl_slot_alloc(ArclHwSlot *slot) {
#define ALLOC_STATE(field, size) \
    do { slot->field = (uint8_t *)state_alloc(size); if (!slot->field) return 0; } while (0)
    ALLOC_STATE(ram, (size_t)g_ram_bytes);
    slot->ram_bytes = (size_t)g_ram_bytes;
    ALLOC_STATE(sram, SRAM_SIZE);
#undef ALLOC_STATE
    return 1;
}

static int hw_capture_slot(ArclHwSlot *slot) {
    // Video arrays belong to the Goose MMU checkpoint, never duplicated here.
    if (!g_ram || !g_sram) return 0;
    if (!arcl_slot_alloc(slot)) return 0;

    if (g_ram && slot->ram) memcpy(slot->ram, g_ram, g_ram_bytes);
    if (g_sram && slot->sram) memcpy(slot->sram, g_sram, SRAM_SIZE);

    {
        int sn = x68k_sound_state_size();
        int drive;
        if (sn <= 0) { slot->valid = false; slot->version = 0; return 0; }
        if (!slot->sound || slot->sound_bytes != sn) {
            free(slot->sound);
            slot->sound = (uint8_t *)state_alloc((size_t)sn);
            slot->sound_bytes = slot->sound ? sn : 0;
        }
        if (!slot->sound || !x68k_sound_state_save(slot->sound, sn)) {
            slot->valid = false;
            slot->version = 0;
            return 0;
        }
        for (drive = 0; drive < 2; drive++) {
            int len = g_fdd_len[drive];
            int copy_n = g_fdd_cap[drive];
            int loaded = (drive == 0 ? g_fdd0_loaded : g_fdd1_loaded) ? 1 : 0;
            uint8_t *img = (drive == 0) ? g_fdd0 : g_fdd1;
            slot->fdd_len[drive] = len;
            slot->fdd_kind[drive] = g_fdd_kind[drive];
            slot->fdd_loaded[drive] = loaded;
            slot->fdd_trk[drive] = g_fdd_trk[drive];
            slot->fdd_cur[drive] = g_fdd_cur[drive];
            slot->fdd_d88_top[drive] = g_fdd_d88_top[drive];
            slot->fdd_d88_cur[drive] = g_fdd_d88_cur[drive];
            slot->fdd_delay[drive] = g_fdd_delay[drive];
            if (!loaded || !img || copy_n <= 0) copy_n = 0;
            if (copy_n > 0) {
                if (!slot->fdd[drive] || slot->fdd_cap[drive] < copy_n) {
                    uint8_t *nbuf = (uint8_t *)state_alloc((size_t)copy_n);
                    if (!nbuf) { slot->valid = false; slot->version = 0; return 0; }
                    free(slot->fdd[drive]);
                    slot->fdd[drive] = nbuf;
                    slot->fdd_cap[drive] = copy_n;
                }
                memcpy(slot->fdd[drive], img, (size_t)copy_n);
            }
            slot->fdd_cap[drive] = copy_n;
        }
    }

    {
        int n = g_hdd0_loaded ? g_hdd0_len : 0;
        if (n < 0 || n > HDD_SIZE || (n && !g_hdd0)) return 0;
        if (n != slot->hdd_len || (n && !slot->hdd)) {
            uint8_t *next = n ? (uint8_t *)state_alloc((size_t)n) : NULL;
            if (n && !next) return 0;
            free(slot->hdd);
            slot->hdd = next;
        }
        if (n) memcpy(slot->hdd, g_hdd0, (size_t)n);
        slot->hdd_len = n;
        slot->hdd_loaded = g_hdd0_loaded ? 1 : 0;
        slot->sasi_reset_req = g_sasi_reset_req;
    }
    slot->fdd_media_enable = g_fdd_media_enable;
    slot->fdd_media_pending = g_fdd_media_pending;
    slot->ppu_phase = g_ppu_phase;
    io_latches_save(&slot->io);
    slot->version = ARCL_SLOT_VERSION;
    slot->valid = true;
    return 1;
}

static int slot_check(const ArclHwSlot *slot);

static int hw_save_slot(ArclHwSlot *slot) {
    ArclHwSlot next = {0};
    ArclHwSlot old;
    if (!slot) return 0;
    if (!hw_capture_slot(&next) || !slot_check(&next)) {
        slot_dispose(&next);
        return 0;
    }
    old = *slot;
    if (++g_state_generation == 0) ++g_state_generation;
    next.generation = g_state_generation;
    *slot = next;
    slot_dispose(&old);
    return 1;
}

int c_mem_save_state(int slot_idx) {
    if (slot_idx < 0 || slot_idx >= MAX_ARCL_SLOTS) return 0;
    return hw_save_slot(&g_arcl_slots[slot_idx]);
}



int c_mem_test_break_version(int slot_idx) {
    if (slot_idx < 0 || slot_idx >= MAX_ARCL_SLOTS) return 0;
    if (!g_arcl_slots[slot_idx].valid) return 0;
    g_arcl_slots[slot_idx].version = 0;
    return 1;
}

int c_mem_test_corrupt_slot(int slot_idx, int kind) {
    ArclHwSlot *slot;
    if (slot_idx < 0 || slot_idx >= MAX_ARCL_SLOTS) return 0;
    slot = &g_arcl_slots[slot_idx];
    if (!slot->valid) return 0;
    switch (kind) {
    case 1: slot->version = 0; break;
    case 2: slot->ram_bytes++; break;
    case 3: slot->hdd_len = HDD_SIZE + 1; break;
    case 4: slot->fdd_cap[0] = FDD_MAX_IMAGE + 1; break;
    case 5: if (!slot->sound) return 0; slot->sound[0] ^= 1; break;
    case 6: slot->fdd_kind[0] = 99; break;
    case 7: slot->io.cpu_mhz = 33; break;
    case 8: slot->io.opm_addr = 256; break;
    default: return 0;
    }
    return 1;
}

int c_ppu_get_phase(void) {
    return g_ppu_phase;
}

void c_ppu_set_phase(int phase) {
    g_ppu_phase = phase;
}

static void slot_commit_fdd(const ArclHwSlot *slot, int drive, uint8_t *prepared) {
    uint8_t **img = (drive == 0) ? &g_fdd0 : &g_fdd1;
    free(*img);
    *img = prepared;
    g_fdd_cap[drive] = slot->fdd_cap[drive];
    g_fdd_len[drive] = slot->fdd_len[drive];
    g_fdd_kind[drive] = slot->fdd_kind[drive];
    g_fdd_trk[drive] = slot->fdd_trk[drive];
    g_fdd_cur[drive] = slot->fdd_cur[drive];
    g_fdd_d88_top[drive] = slot->fdd_d88_top[drive];
    g_fdd_d88_cur[drive] = slot->fdd_d88_cur[drive];
    g_fdd_delay[drive] = slot->fdd_delay[drive];
    if (drive == 0) g_fdd0_loaded = slot->fdd_loaded[0] != 0;
    else g_fdd1_loaded = slot->fdd_loaded[1] != 0;
}

static void opm_shadow_reset(void);

static int slot_check(const ArclHwSlot *slot) {
    int drive;
    if (!slot) return 0;
    if (!slot->valid || slot->version != ARCL_SLOT_VERSION) return 0;
    if (slot->ram_bytes != (size_t)g_ram_bytes) return 0;
    if (!slot->ram || !slot->sram || !g_ram || !g_sram) return 0;
    if (!x68k_sound_state_check(slot->sound, slot->sound_bytes)) return 0;
    if (slot->hdd_len < 0 || slot->hdd_len > HDD_SIZE || (slot->hdd_len && !slot->hdd)) return 0;
    if (slot->hdd_loaded != 0 && slot->hdd_loaded != 1) return 0;
    if (slot->hdd_loaded != (slot->hdd_len > 0)) return 0;
    if (cpu_clock_index(slot->io.cpu_mhz) < 0 || slot->io.opm_addr < 0 || slot->io.opm_addr > 255) return 0;
    if ((slot->fdd_media_pending & ~1) || (slot->fdd_media_enable & ~1) || (slot->sasi_reset_req & ~1)) return 0;
    for (drive = 0; drive < 2; drive++) {
        int cap = slot->fdd_cap[drive], len = slot->fdd_len[drive];
        int kind = slot->fdd_kind[drive], loaded = slot->fdd_loaded[drive];
        if (loaded != 0 && loaded != 1) return 0;
        if (cap < 0 || cap > FDD_MAX_IMAGE || len < 0 || len > cap) return 0;
        if (loaded) {
            if (!slot->fdd[drive] || len == 0 || kind < FDD_KIND_XDF || kind > FDD_KIND_DIM) return 0;
            if (kind == FDD_KIND_XDF && cap != FDD_SIZE) return 0;
            if (kind == FDD_KIND_D88 && len < FDD_D88_HEADER) return 0;
            if (kind == FDD_KIND_DIM && len < FDD_DIM_HEADER) return 0;
        } else if (cap || len) return 0;
        if (slot->fdd_trk[drive] < -1 || slot->fdd_trk[drive] > 169) return 0;
        if (slot->fdd_cur[drive] < 0 || slot->fdd_cur[drive] > 255) return 0;
        if (slot->fdd_d88_top[drive] > (uint32_t)len || slot->fdd_d88_cur[drive] > (uint32_t)len) return 0;
        if (slot->fdd_delay[drive] < 0 || slot->fdd_delay[drive] > 3) return 0;
    }
    return 1;
}

static int hw_load_slot(ArclHwSlot *slot) {
    uint8_t *fd[2] = {NULL, NULL};
    uint8_t *hdd = NULL;
    int drive;
    if (!slot_check(slot)) return 0;
    // Prepare every fallible allocation before touching any machine state.
    for (drive = 0; drive < 2; drive++) {
        if (slot->fdd_cap[drive]) {
            fd[drive] = (uint8_t *)state_alloc((size_t)slot->fdd_cap[drive]);
            if (!fd[drive]) goto fail;
            memcpy(fd[drive], slot->fdd[drive], (size_t)slot->fdd_cap[drive]);
        }
    }
    if (slot->hdd_loaded) {
        hdd = (uint8_t *)state_alloc(HDD_SIZE);
        if (!hdd) goto fail;
        memset(hdd, 0, HDD_SIZE);
        memcpy(hdd, slot->hdd, (size_t)slot->hdd_len);
    }
    // The checked sound loader can fail only before applying its state.
    if (!x68k_sound_state_load(slot->sound, slot->sound_bytes)) goto fail;

    if (g_ram && slot->ram) memcpy(g_ram, slot->ram, g_ram_bytes);
    if (g_sram && slot->sram) memcpy(g_sram, slot->sram, SRAM_SIZE);
    slot_commit_fdd(slot, 0, fd[0]);
    slot_commit_fdd(slot, 1, fd[1]);
    free(g_hdd0);
    g_hdd0 = hdd;
    g_hdd0_loaded = slot->hdd_loaded != 0;
    g_hdd0_len = slot->hdd_len;
    g_sasi_reset_req = slot->sasi_reset_req;
    g_fdd_media_enable = slot->fdd_media_enable;
    fdd_media_store(slot->fdd_media_pending);
    // Restored images live in memory; no host path is opened or written.
    g_fdd0_path[0] = g_fdd1_path[0] = g_hdd0_path[0] = 0;
    g_ppu_phase = slot->ppu_phase;
    io_latches_load(&slot->io);
    return 1;
fail:
    free(fd[0]); free(fd[1]); free(hdd);
    return 0;
}

int c_mem_load_state(int slot_idx) {
    if (slot_idx < 0 || slot_idx >= MAX_ARCL_SLOTS) return 0;
    return hw_load_slot(&g_arcl_slots[slot_idx]);
}

static ArclHwSlot g_snaps[32];
static ArclHwSlot g_rew[8];

static void state_banks_clear(void) {
    int i;
    for (i = 0; i < MAX_ARCL_SLOTS; i++) slot_dispose(&g_arcl_slots[i]);
    for (i = 0; i < 32; i++) slot_dispose(&g_snaps[i]);
    for (i = 0; i < 8; i++) slot_dispose(&g_rew[i]);
}

static ArclHwSlot *extra_slot(int bank, int idx) {
    if (bank == 0) {
        if (idx < 0 || idx >= 32) return NULL;
        return &g_snaps[idx];
    }
    if (bank != 1 || idx < 0 || idx >= 8) return NULL;
    return &g_rew[idx];
}

static int slot_bytes(const ArclHwSlot *slot) {
    int n;
    if (!slot || !slot->valid) return 0;
    n = (int)slot->ram_bytes + SRAM_SIZE;
    n += slot->sound_bytes + slot->fdd_cap[0] + slot->fdd_cap[1] + slot->hdd_len;
    return n;
}

int c_extra_save(int bank, int idx) {
    ArclHwSlot *slot = extra_slot(bank, idx);
    return hw_save_slot(slot);
}

int c_extra_load(int bank, int idx) {
    return hw_load_slot(extra_slot(bank, idx));
}

void c_extra_drop(int bank, int idx) {
    ArclHwSlot *slot = extra_slot(bank, idx);
    if (!slot) return;
    slot_dispose(slot);
}

int c_extra_bytes(int bank, int idx) {
    return slot_bytes(extra_slot(bank, idx));
}

int c_extra_total(int bank) {
    int i, n = 0, lim = bank == 0 ? 32 : 8;
    for (i = 0; i < lim; i++) n += c_extra_bytes(bank, i);
    return n;
}

// One native bank convention shared with x68k_state.goose.
static ArclHwSlot *state_slot(int bank, int idx) {
    if (bank == 0) {
        if (idx < 0 || idx >= MAX_ARCL_SLOTS) return NULL;
        return &g_arcl_slots[idx];
    }
    if (bank == 1) return extra_slot(0, idx);
    if (bank == 2) return extra_slot(1, idx);
    return NULL;
}

int c_state_capture(int bank, int idx) { return hw_save_slot(state_slot(bank, idx)); }
int c_state_validate(int bank, int idx) { return slot_check(state_slot(bank, idx)); }
int c_state_restore(int bank, int idx) { return hw_load_slot(state_slot(bank, idx)); }
uint64_t c_state_generation(int bank, int idx) {
    ArclHwSlot *slot = state_slot(bank, idx);
    return slot && slot->valid && slot->version == ARCL_SLOT_VERSION ? slot->generation : 0;
}
void c_state_drop(int bank, int idx) {
    ArclHwSlot *slot = state_slot(bank, idx);
    if (slot) slot_dispose(slot);
}
int c_state_bytes(int bank, int idx) {
    ArclHwSlot *slot = state_slot(bank, idx);
    return slot && slot->valid ? slot_bytes(slot) + (int)sizeof(*slot) : 0;
}

#define AUDIO_CAP_RATE 44100
#define AUDIO_CAP_SECONDS 60
#define AUDIO_SILENCE_PEAK 256
static int16_t *g_cap_buf = NULL;
static int g_cap_frames = 0;
static int g_cap_active = 0;
static int g_cap_trunc = 0;

static void cap_push(const int16_t *stereo, int frames) {
    int room, n;
    if (!g_cap_active || !g_cap_buf || !stereo || frames <= 0) return;
    room = AUDIO_CAP_RATE * AUDIO_CAP_SECONDS - g_cap_frames;
    if (room <= 0) { g_cap_trunc = 1; return; }
    n = frames < room ? frames : room;
    memcpy(g_cap_buf + (size_t)g_cap_frames * 2, stereo, (size_t)n * 2 * sizeof(int16_t));
    g_cap_frames += n;
    if (n < frames) g_cap_trunc = 1;
}

void c_audio_capture_start(void) {
    if (!g_cap_buf) g_cap_buf = (int16_t *)malloc((size_t)AUDIO_CAP_RATE * AUDIO_CAP_SECONDS * 2 * sizeof(int16_t));
    g_cap_frames = 0;
    g_cap_trunc = 0;
    g_cap_active = g_cap_buf != NULL;
}

void c_audio_capture_status(int *active, int *frames, int *truncated) {
    if (active) *active = g_cap_active;
    if (frames) *frames = g_cap_frames;
    if (truncated) *truncated = g_cap_trunc;
}

static int write_wav(const char *path, const int16_t *data, int frames) {
    uint8_t hdr[44];
    uint32_t data_bytes, riff;
    FILE *fp;
    if (!path || !data || frames <= 0) return 0;
    data_bytes = (uint32_t)frames * 4;
    riff = 36 + data_bytes;
    memset(hdr, 0, sizeof(hdr));
    memcpy(hdr, "RIFF", 4);
    hdr[4] = (uint8_t)riff; hdr[5] = (uint8_t)(riff >> 8); hdr[6] = (uint8_t)(riff >> 16); hdr[7] = (uint8_t)(riff >> 24);
    memcpy(hdr + 8, "WAVEfmt ", 8);
    hdr[16] = 16;
    hdr[20] = 1;
    hdr[22] = 2;
    hdr[24] = (uint8_t)AUDIO_CAP_RATE; hdr[25] = (uint8_t)(AUDIO_CAP_RATE >> 8);
    {
        uint32_t rate = (uint32_t)AUDIO_CAP_RATE * 4;
        hdr[28] = (uint8_t)rate; hdr[29] = (uint8_t)(rate >> 8); hdr[30] = (uint8_t)(rate >> 16); hdr[31] = (uint8_t)(rate >> 24);
    }
    hdr[32] = 4; hdr[34] = 16;
    memcpy(hdr + 36, "data", 4);
    hdr[40] = (uint8_t)data_bytes; hdr[41] = (uint8_t)(data_bytes >> 8);
    hdr[42] = (uint8_t)(data_bytes >> 16); hdr[43] = (uint8_t)(data_bytes >> 24);
    fp = fopen(path, "wb");
    if (!fp) return 0;
    if (fwrite(hdr, 1, 44, fp) != 44 || fwrite(data, 1, data_bytes, fp) != data_bytes) {
        fclose(fp);
        return 0;
    }
    fclose(fp);
    return 1;
}

int c_audio_capture_stop(const uint8_t *path_bytes, int path_len, int *frames, int *truncated, int *peak, int *silent) {
    char path[MAX_PATH];
    int i, pk = 0, n;
    bind_path(path_bytes, path_len, path, MAX_PATH);
    g_cap_active = 0;
    n = g_cap_frames;
    for (i = 0; i < n * 2; i++) {
        int v = g_cap_buf ? g_cap_buf[i] : 0;
        if (v < 0) v = -v;
        if (v > pk) pk = v;
    }
    if (path[0]) {
        if (!write_wav(path, g_cap_buf, n)) return 0;
    }
    if (frames) *frames = n;
    if (truncated) *truncated = g_cap_trunc;
    if (peak) *peak = pk;
    if (silent) *silent = pk < AUDIO_SILENCE_PEAK;
    return 1;
}

void c_sound_render(int16_t *buf, int32_t samples) {
    x68k_sound_render(buf, samples);
    cap_push(buf, samples);
}

// Audio / Sound API
void c_sound_init(void) {
    x68k_sound_init();
}

void c_sound_reset(void) {
    x68k_sound_reset();
}

void c_sound_cleanup(void) {
    x68k_sound_cleanup();
}

static uint8_t g_opm_shadow[256];
static int g_opm_addr = 0;
static uint8_t g_opm_key_on[8];

static void opm_shadow_reset(void) {
    memset(g_opm_shadow, 0, sizeof(g_opm_shadow));
    memset(g_opm_key_on, 0, sizeof(g_opm_key_on));
    g_opm_addr = 0;
}
static uint32_t s_opm_w_count = 0;
static uint32_t s_adpcm_w_count = 0;
static int32_t s_peak_sample = 0;
static uint32_t s_total_rendered_samples = 0;

void c_sound_opm_write(uint32_t addr, uint8_t val) {
    s_opm_w_count++;
    if ((addr & 1) == 0) g_opm_addr = val & 255;
    else {
        g_opm_shadow[g_opm_addr] = val;
        if (g_opm_addr == 0x08) g_opm_key_on[val & 7] = (uint8_t)((val >> 3) & 15);
    }
    x68k_sound_opm_write(addr, val);
}

int c_opm_shadow_byte(int index) {
    if (index < 0 || index > 255) return 0;
    return g_opm_shadow[index];
}

int c_opm_key_on(int ch) {
    if (ch < 0 || ch > 7) return 0;
    return g_opm_key_on[ch];
}

uint8_t c_sound_opm_read(uint32_t addr) {
    return x68k_sound_opm_read(addr);
}

void c_sound_adpcm_write(uint32_t addr, uint8_t val) {
    s_adpcm_w_count++;
    x68k_sound_adpcm_write(addr, val);
}

uint8_t c_sound_adpcm_read(uint32_t addr) {
    return x68k_sound_adpcm_read(addr);
}

void c_sound_adpcm_set_pan(uint8_t pan) {
    x68k_sound_adpcm_set_pan(pan);
}

static uint8_t g_pia_c = 0x0b;
static uint8_t g_joy_strobe[2];

void c_machine_reset_devices(void) {
    c_sound_reset();
    opm_shadow_reset();
    g_pia_c = 0x0b;
    memset(g_joy_strobe, 0, sizeof(g_joy_strobe));
    g_ppu_phase = 0;
    // Preserve media contents, cursor and physical insertion countdown.
    // px68k FDD_Reset also leaves that state in the drive.
    g_fdd_media_enable = 0;
    fdd_media_store(0);
    g_sasi_reset_req = 0;
    c_host_input_discard();
    c_audio_discard();
}

void c_host_input_discard(void) {
    c_host_joy_reset();
    g_key_head = g_key_tail = g_scan_head = g_scan_tail = 0;
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

static void io_latches_save(ArclIoLatches *state) {
    state->cpu_mhz = g_cpu_mhz;
    state->pia_c = g_pia_c;
    memcpy(state->joy_strobe, g_joy_strobe, sizeof(g_joy_strobe));
    state->opm_addr = g_opm_addr;
    memcpy(state->opm_shadow, g_opm_shadow, sizeof(g_opm_shadow));
    memcpy(state->opm_key_on, g_opm_key_on, sizeof(g_opm_key_on));
}

static void io_latches_load(const ArclIoLatches *state) {
    c_set_cpu_mhz(state->cpu_mhz);
    // Sound has already restored ADPCM pan/clock. Do not replay port writes.
    g_pia_c = state->pia_c;
    memcpy(g_joy_strobe, state->joy_strobe, sizeof(g_joy_strobe));
    g_opm_addr = state->opm_addr;
    memcpy(g_opm_shadow, state->opm_shadow, sizeof(g_opm_shadow));
    memcpy(g_opm_key_on, state->opm_key_on, sizeof(g_opm_key_on));
}

static void pia_set_portc(uint8_t next) {
    uint8_t prev = g_pia_c;
    g_pia_c = next;
    if ((prev & 0x0f) != (next & 0x0f)) c_sound_adpcm_set_pan(next & 0x0f);
    if ((prev & 0x10) != (next & 0x10)) g_joy_strobe[0] = (next & 0x10) ? 0xff : 0x00;
    if ((prev & 0x20) != (next & 0x20)) g_joy_strobe[1] = (next & 0x20) ? 0xff : 0x00;
}

void c_pia_write(int32_t adr, uint8_t data) {
    if (adr == 0x00E9A005) {
        pia_set_portc(data);
    } else if (adr == 0x00E9A007 && (data & 0x80) == 0) {
        uint8_t bit = (uint8_t)((data >> 1) & 7);
        uint8_t mask = (uint8_t)(1u << bit);
        uint8_t next = g_pia_c;
        if (data & 1) next = (uint8_t)(next | mask);
        else next = (uint8_t)(next & (uint8_t)~mask);
        pia_set_portc(next);
    }
}

uint8_t c_pia_read_c(void) {
    return g_pia_c;
}

uint8_t c_pia_joy_strobe(int32_t port) {
    if (port < 0 || port > 1) return 0;
    return g_joy_strobe[port];
}

void c_sound_scanline_timer(uint32_t cycles) {
    x68k_sound_scanline_timer(cycles);
}

void c_sound_frame_update(int samples) {
    if (samples <= 0) return;
    static int16_t s_render_buf[2048 * 2]; // max 2048 stereo samples
    int render_samples = samples > 2048 ? 2048 : samples;
    x68k_sound_render(s_render_buf, render_samples);
    cap_push(s_render_buf, render_samples);
    for (int i = 0; i < render_samples * 2; i++) {
        int val = s_render_buf[i];
        if (val < 0) val = -val;
        if (val > s_peak_sample) s_peak_sample = val;
    }
    s_total_rendered_samples += (uint32_t)render_samples;
    win32_audio_push(s_render_buf, render_samples * 2);
}

int c_sound_poll_irq(void) {
    return x68k_sound_poll_irq();
}

int c_host_list_dir(const uint8_t *path_bytes, int path_len, char *out, int cap) {
    char path[MAX_PATH];
    char pattern[MAX_PATH];
    WIN32_FIND_DATAA fd;
    HANDLE h;
    int used = 0;
    int first = 1;
    bind_path(path_bytes, path_len, path, MAX_PATH);
    if (!out || cap < 2) return 0;
    if (path[0] == 0) return 0;
    if (strstr(path, "..")) return -1;
    if ((int)strlen(path) + 3 >= MAX_PATH) return 0;
    snprintf(pattern, sizeof(pattern), "%s\\*", path);
    h = FindFirstFileA(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE) return 0;
    out[0] = 0;
    do {
        const char *name = fd.cFileName;
        int is_dir, i, nlen;
        char piece[600];
        int pn = 0;
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
    } while (FindNextFileA(h, &fd));
    FindClose(h);
    if (first) {
        memcpy(out, "[]", 3);
    } else if (used + 1 < cap) {
        out[used++] = ']';
        out[used] = 0;
    }
    return 1;
}

void c_sound_get_stats(uint32_t *opm_w, uint32_t *adpcm_w, int32_t *peak, uint32_t *total_rendered) {
    if (opm_w) *opm_w = s_opm_w_count;
    if (adpcm_w) *adpcm_w = s_adpcm_w_count;
    if (peak) *peak = s_peak_sample;
    if (total_rendered) *total_rendered = s_total_rendered_samples;
}





