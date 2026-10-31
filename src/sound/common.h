#ifndef _SOUND_COMMON_H
#define _SOUND_COMMON_H

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <math.h>

#ifdef _MSC_VER
#define FASTCALL __fastcall
#define INLINE __inline
#else
#define FASTCALL
#define INLINE inline
#endif

typedef struct {
    uint8_t *data;
    uint32_t loc;
    uint32_t len;
    uint32_t malloced;
    uint32_t initial_malloc;
    bool fastsavestates;
} StateMem;

#define PX68KSTATE_RLSB            0x80000000
#define PX68KSTATE_RLSB32          0x40000000
#define PX68KSTATE_RLSB16          0x20000000
#define PX68KSTATE_RLSB64          0x10000000
#define PX68KSTATE_BOOL            0x08000000

typedef struct {
    void *v;
    uint32_t size;
    uint32_t flags;
    const char *name;
} SFORMAT;

#define SFVARN_BOOL(x, n) { &(x), 1, PX68KSTATE_RLSB | PX68KSTATE_BOOL, n }
#define SFVARN(x, n) { &(x), (uint32_t)sizeof(x), PX68KSTATE_RLSB, n }
#define SFVAR(x) SFVARN((x), #x)
#define SFARRAYN(x, l, n) { (x), (uint32_t)(l), 0, n }
#define SFARRAY(x, l) SFARRAYN((x), (l), #x)
#define SFARRAY16N(x, l, n) { (x), (uint32_t)((l) * sizeof(uint16_t)), PX68KSTATE_RLSB16, n }
#define SFARRAY16(x, l) SFARRAY16N((x), (l), #x)
#define SFARRAY32N(x, l, n) { (x), (uint32_t)((l) * sizeof(uint32_t)), PX68KSTATE_RLSB32, n }
#define SFARRAY32(x, l) SFARRAY32N((x), (l), #x)
#define SFARRAY64N(x, l, n) { (x), (uint32_t)((l) * sizeof(uint64_t)), PX68KSTATE_RLSB64, n }
#define SFARRAY64(x, l) SFARRAY64N((x), (l), #x)
#define SFEND { 0, 0, 0, 0 }

#ifdef __cplusplus
extern "C" {
#endif

static inline int PX68KSS_StateAction(void *st, int load, int data_only, SFORMAT *sf, const char *name, bool optional) {
    (void)st; (void)load; (void)data_only; (void)sf; (void)name; (void)optional;
    return 1;
}

typedef struct {
    int Sound_LPF;
    int PCM_VOL;
    int OPM_VOL;
} SoundConfig;

extern SoundConfig Config;

typedef struct {
    uint8_t CSR;
    uint8_t CER;
    uint8_t DCR;
    uint8_t OCR;
    uint8_t SCR;
    uint8_t CCR;
    uint16_t MTC;
    uint16_t BTC;
    uint32_t MAR;
    uint32_t DAR;
    uint32_t BAR;
    uint8_t NIV;
    uint8_t EIV;
} DMAChannelStub;

extern DMAChannelStub DMA[4];
void FASTCALL DMA_Exec(int ch);

#ifdef __cplusplus
}
#endif

#endif // _SOUND_COMMON_H
