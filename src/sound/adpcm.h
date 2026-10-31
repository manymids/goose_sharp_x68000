#ifndef _WINX68K_ADPCM_H
#define _WINX68K_ADPCM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void FASTCALL ADPCM_PreUpdate(uint32_t clock);
void ADPCM_Update(int16_t *buffer, size_t length, uint8_t *pbsp, uint8_t *pbep);

void FASTCALL ADPCM_Write(uint32_t adr, uint8_t data);
uint8_t FASTCALL ADPCM_Read(uint32_t adr);

void ADPCM_SetVolume(uint8_t vol);
void ADPCM_SetPan(int n);
void ADPCM_SetClock(int n);

void ADPCM_Init(void);
int ADPCM_StateAction(StateMem *sm, int load, int data_only);
int ADPCM_StateBytes(void);
void ADPCM_StateSave(void *dst);
void ADPCM_StateLoad(const void *src);

#ifdef __cplusplus
}
#endif

#endif /* _WINX68K_ADPCM_H */
