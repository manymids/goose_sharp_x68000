#ifndef _X68K_SOUND_H
#define _X68K_SOUND_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 初期化・リセット・クリーンアップ
void x68k_sound_init(void);
void x68k_sound_reset(void);
void x68k_sound_cleanup(void);

// OPM レジスタ読み書き
void x68k_sound_opm_write(uint32_t addr, uint8_t val);
uint8_t x68k_sound_opm_read(uint32_t addr);

// 走査線ごとのタイマーステップ
void x68k_sound_scanline_timer(uint32_t cycles);

// ADPCM の出力が入っているバッファへ OPM を足し込む (out_buf: 16-bit ステレオインターリーブ, samples: サンプル数)
void x68k_sound_mix(int16_t *out_buf, int samples);

// OPM 割り込みフラグ確認 (1なら割り込み要求あり、呼ぶとクリア)
int x68k_sound_poll_irq(void);
int x68k_sound_state_size(void);
int x68k_sound_state_save(void *dst, int cap);
int x68k_sound_state_check(const void *src, int n);
int x68k_sound_state_load(const void *src, int n);

#ifdef __cplusplus
}
#endif

#endif // _X68K_SOUND_H
