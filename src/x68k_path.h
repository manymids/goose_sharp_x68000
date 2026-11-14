#ifndef X68K_PATH_H
#define X68K_PATH_H
/* Every path that crosses between Goose and C is UTF-8. Win32 is called through its wide
 * (W) functions, so a path means the same thing whatever the ANSI code page is. */
#include <windows.h>
#include <stdio.h>

/* Bytes for a path of MAX_PATH UTF-16 units as UTF-8, with the terminator. */
#define PATH_CAP (MAX_PATH * 3 + 1)

/* Both return 0 when the text is malformed or does not fit. */
static inline int path_to_wide(const char *utf8, wchar_t *wide, int cap) {
    return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, wide, cap) > 0;
}

static inline int path_from_wide(const wchar_t *wide, char *utf8, int cap) {
    return WideCharToMultiByte(CP_UTF8, 0, wide, -1, utf8, cap, NULL, NULL) > 0;
}

static inline FILE *path_fopen(const char *utf8, const wchar_t *mode) {
    wchar_t wide[MAX_PATH];
    if (!utf8 || !utf8[0] || !path_to_wide(utf8, wide, MAX_PATH)) return NULL;
    return _wfopen(wide, mode);
}

#endif
