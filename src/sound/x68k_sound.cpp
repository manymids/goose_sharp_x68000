#include "x68k_sound.h"
#include "common.h"
#include "opm.h"
#include "adpcm.h"

// グローバル設定・スタブ定義
SoundConfig Config = { 0, 16, 16 };

static volatile int g_opm_irq_flag = 0;

class MyOPM : public FM::OPM {
public:
    MyOPM();
    virtual ~MyOPM() {}
    void WriteIO(uint32_t adr, uint8_t data);
    void Count2(uint32_t clock);

private:
    virtual void Intr(bool f);

public:
    int CurReg;
    uint32_t CurCount;
};

MyOPM::MyOPM() {
    CurReg = 0;
    CurCount = 0;
}

void MyOPM::WriteIO(uint32_t adr, uint8_t data) {
    if (adr & 1) {
        if (CurReg == 0x1b) {
            ADPCM_SetClock((data >> 5) & 4);
        }
        SetReg(CurReg, (int)data);
    } else {
        CurReg = (int)data;
    }
}

void MyOPM::Intr(bool f) {
    if (f) {
        g_opm_irq_flag = 1;
    }
}

void MyOPM::Count2(uint32_t clock) {
    CurCount += clock;
    Count(CurCount / 10);
    CurCount %= 10;
}

static MyOPM *g_opm = NULL;

extern "C" {

extern uint8_t *c_ram_base(void);
extern int32_t c_ram_size(void);

DMAChannelStub DMA[4];
static int g_dma_vec = -1;
static int32_t *g_dma_vec_slot = NULL;

static void dma_vec_store(int v) {
    g_dma_vec = v;
    if (g_dma_vec_slot) *g_dma_vec_slot = (int32_t)v;
}

void c_dma_vec_bind(int32_t *slot) {
    g_dma_vec_slot = slot;
    if (slot) *slot = (int32_t)g_dma_vec;
}

static uint8_t dma_mem_read(uint32_t addr) {
    uint8_t *ram = c_ram_base();
    addr &= 0x00FFFFFFu;
    if (ram && addr < (uint32_t)c_ram_size())
        return ram[addr];
    return 0;
}

static void dma_port_write(uint32_t addr, uint8_t val) {
    uint8_t *ram = c_ram_base();
    addr &= 0x00FFFFFFu;
    if ((addr & 0xFFFFFCu) == 0x00E92000u) {
        ADPCM_Write(addr, val);
        return;
    }
    if (ram && addr < (uint32_t)c_ram_size())
        ram[addr] = val;
}

static uint32_t dma_mem_read32(uint32_t addr) {
    return ((uint32_t)dma_mem_read(addr) << 24) |
           ((uint32_t)dma_mem_read(addr + 1) << 16) |
           ((uint32_t)dma_mem_read(addr + 2) << 8) |
           (uint32_t)dma_mem_read(addr + 3);
}

static uint16_t dma_mem_read16(uint32_t addr) {
    return (uint16_t)(((uint16_t)dma_mem_read(addr) << 8) | dma_mem_read(addr + 1));
}

static void dma_raise(int ch) {
    if (DMA[ch].CCR & 0x08) {
        int vec = (DMA[ch].CSR & 0x10) ? (int)DMA[ch].EIV : (int)DMA[ch].NIV;
        if (vec > 0)
            dma_vec_store(vec);
    }
}

/* px68k DMA_Exec, enough for ADPCM channel 3 (memory -> 0xE92003). */
void FASTCALL DMA_Exec(int ch) {
    if (ch < 0 || ch > 3)
        return;
    DMAChannelStub *d = &DMA[ch];
    int guard = 0;

    while ((d->CSR & 0x08) && !(d->CCR & 0x20) && !(d->CSR & 0x80) && d->MTC && guard < 65536) {
        guard++;
        int mem_to_dev = (d->OCR & 0x80) == 0;
        uint32_t *src = mem_to_dev ? &d->MAR : &d->DAR;
        uint32_t *dst = mem_to_dev ? &d->DAR : &d->MAR;
        int kind = ((d->OCR >> 4) & 3) + ((d->DCR >> 1) & 4);
        int ops = 1;
        int mem_step = 1;
        int dev_step = 2;
        int width = 1;
        switch (kind) {
        case 0:
        case 3:
            break;
        case 1:
            ops = 2;
            break;
        case 2:
            ops = 4;
            break;
        case 4:
            dev_step = 1;
            break;
        case 5:
            mem_step = 2;
            dev_step = 2;
            width = 2;
            break;
        case 6:
            mem_step = 4;
            dev_step = 4;
            width = 4;
            break;
        default:
            dev_step = 1;
            break;
        }

        for (int n = 0; n < ops; n++) {
            uint32_t s = *src & 0x00FFFFFFu;
            uint32_t t = *dst & 0x00FFFFFFu;
            if (width == 1) {
                dma_port_write(t, dma_mem_read(s));
            } else if (width == 2) {
                dma_port_write(t, dma_mem_read(s));
                dma_port_write(t + 1, dma_mem_read(s + 1));
            } else {
                for (int i = 0; i < 4; i++)
                    dma_port_write(t + (uint32_t)i, dma_mem_read(s + (uint32_t)i));
            }
            if (d->SCR & 4) d->MAR = (d->MAR + (uint32_t)mem_step) & 0x00FFFFFFu;
            else if (d->SCR & 8) d->MAR = (d->MAR - (uint32_t)mem_step) & 0x00FFFFFFu;
            if (d->SCR & 1) d->DAR = (d->DAR + (uint32_t)dev_step) & 0x00FFFFFFu;
            else if (d->SCR & 2) d->DAR = (d->DAR - (uint32_t)dev_step) & 0x00FFFFFFu;
        }

        d->MTC--;
        if (!d->MTC) {
            if (d->OCR & 8) {
                if (d->OCR & 4) {
                    if (d->BAR) {
                        d->MAR = dma_mem_read32(d->BAR) & 0x00FFFFFFu;
                        d->MTC = dma_mem_read16(d->BAR + 4);
                        d->BAR = dma_mem_read32(d->BAR + 6) & 0x00FFFFFFu;
                        if (!d->MTC)
                            break;
                    }
                } else if (d->BTC) {
                    d->BTC--;
                    if (d->BTC) {
                        d->MAR = dma_mem_read32(d->BAR) & 0x00FFFFFFu;
                        d->MTC = dma_mem_read16(d->BAR + 4);
                        d->BAR = (d->BAR + 6) & 0x00FFFFFFu;
                        if (!d->MTC)
                            break;
                    }
                }
            } else if (d->CCR & 0x40) {
                d->CSR |= 0x40;
                dma_raise(ch);
                if (d->BAR) {
                    d->MAR = d->BAR & 0x00FFFFFFu;
                    d->MTC = d->BTC;
                    d->CSR |= 0x08;
                    d->BAR = 0;
                    d->BTC = 0;
                    d->CCR &= 0xBF;
                }
            }
            if (!d->MTC) {
                d->CSR |= 0x80;
                d->CSR &= 0xF7;
                dma_raise(ch);
            }
        }
        if ((d->OCR & 3) != 1)
            break;
    }
}

void c_dmac_push_ch3(uint8_t csr, uint8_t cer, uint8_t dcr, uint8_t ocr, uint8_t scr, uint8_t ccr,
                     uint16_t mtc, uint32_t mar, uint32_t dar, uint16_t btc, uint32_t bar,
                     uint8_t niv, uint8_t eiv) {
    DMAChannelStub *d = &DMA[3];
    d->CSR = csr;
    d->CER = cer;
    d->DCR = dcr;
    d->OCR = ocr;
    d->SCR = scr;
    d->CCR = ccr;
    d->MTC = mtc;
    d->MAR = mar & 0x00FFFFFFu;
    d->DAR = dar & 0x00FFFFFFu;
    d->BTC = btc;
    d->BAR = bar & 0x00FFFFFFu;
    d->NIV = niv;
    d->EIV = eiv;
}

void c_dmac_pull_ch3(uint8_t *csr, uint8_t *cer, uint8_t *ccr, uint16_t *mtc,
                     uint32_t *mar, uint32_t *dar, uint16_t *btc, uint32_t *bar) {
    DMAChannelStub *d = &DMA[3];
    if (csr) *csr = d->CSR;
    if (cer) *cer = d->CER;
    if (ccr) *ccr = d->CCR;
    if (mtc) *mtc = d->MTC;
    if (mar) *mar = d->MAR;
    if (dar) *dar = d->DAR;
    if (btc) *btc = d->BTC;
    if (bar) *bar = d->BAR;
}

int c_dmac_peek_irq(void) {
    return g_dma_vec;
}

void c_dmac_ack_irq(void) {
    dma_vec_store(-1);
}

void x68k_sound_init(void) {
    if (!g_opm) {
        g_opm = new MyOPM();
        g_opm->Init(4000000, 44100);
        g_opm->SetVolume(0); // 0dB (max)
    }
    ADPCM_Init();
    ADPCM_SetVolume(16); // max
    g_opm_irq_flag = 0;
}

void x68k_sound_reset(void) {
    if (g_opm) {
        g_opm->Reset();
        g_opm->CurReg = 0;
        g_opm->CurCount = 0;
        g_opm->SetVolume(0);
    }
    ADPCM_Init();
    ADPCM_SetVolume(16);
    g_opm_irq_flag = 0;
    memset(DMA, 0, sizeof(DMA));
    dma_vec_store(-1);
}

void x68k_sound_cleanup(void) {
    if (g_opm) {
        delete g_opm;
        g_opm = NULL;
    }
    g_opm_irq_flag = 0;
    memset(DMA, 0, sizeof(DMA));
    dma_vec_store(-1);
}

void x68k_sound_opm_write(uint32_t addr, uint8_t val) {
    if (g_opm) {
        g_opm->WriteIO(addr, val);
    }
}

uint8_t x68k_sound_opm_read(uint32_t addr) {
    (void)addr;
    if (g_opm) {
        return (uint8_t)g_opm->ReadStatus();
    }
    return 0;
}

void x68k_sound_adpcm_write(uint32_t addr, uint8_t val) {
    ADPCM_Write(addr, val);
}

uint8_t x68k_sound_adpcm_read(uint32_t addr) {
    return ADPCM_Read(addr);
}

void x68k_sound_adpcm_set_pan(uint8_t pan) {
    ADPCM_SetPan(pan);
}

void x68k_sound_scanline_timer(uint32_t cycles) {
    ADPCM_PreUpdate(cycles);
    if (g_opm) {
        g_opm->Count2(cycles);
    }
}

void x68k_sound_render(int16_t *out_buf, int samples) {
    if (!out_buf || samples <= 0) return;
    uint8_t *pbsp = (uint8_t*)out_buf;
    uint8_t *pbep = (uint8_t*)(out_buf + samples * 2);

    ADPCM_Update(out_buf, samples, pbsp, pbep);
    if (g_opm) {
        g_opm->Mix(out_buf, samples, pbsp, pbep);
    }
}

int x68k_sound_poll_irq(void) {
    int f = g_opm_irq_flag;
    g_opm_irq_flag = 0;
    return f;
}

#define SOUND_STATE_MAGIC 0x5336384Bu

static int sound_opm_bytes(void) {
    return g_opm ? (int)sizeof(MyOPM) : 0;
}

int x68k_sound_state_size(void) {
    return (int)(sizeof(uint32_t) * 4 + sizeof(int32_t) * 2 + sizeof(DMA)
        + (size_t)sound_opm_bytes() + (size_t)ADPCM_StateBytes());
}

static int sound_apply(const uint8_t *src, int n, int apply) {
    const uint8_t *p = src;
    uint32_t magic = 0, total = 0, opm_n = 0, adpcm_n = 0;
    int32_t irq = 0, vec = 0;
    int need;
    if (!src || n < x68k_sound_state_size()) return 0;
    memcpy(&magic, p, 4); p += 4;
    memcpy(&total, p, 4); p += 4;
    memcpy(&irq, p, 4); p += 4;
    memcpy(&vec, p, 4); p += 4;
    if (magic != SOUND_STATE_MAGIC || (int)total != n) return 0;
    p += sizeof(DMA);
    memcpy(&opm_n, p, 4); p += 4;
    if ((int)opm_n != sound_opm_bytes()) return 0;
    p += opm_n;
    memcpy(&adpcm_n, p, 4); p += 4;
    if (adpcm_n != (uint32_t)ADPCM_StateBytes()) return 0;
    need = (int)(sizeof(uint32_t) * 4 + sizeof(int32_t) * 2 + sizeof(DMA) + opm_n + adpcm_n);
    if (need != n) return 0;
    if (!apply) return 1;
    g_opm_irq_flag = irq;
    dma_vec_store(vec);
    p = src + 16;
    memcpy(DMA, p, sizeof(DMA));
    p += sizeof(DMA) + 4;
    if (opm_n && g_opm) memcpy(g_opm, p, opm_n);
    p += opm_n + 4;
    ADPCM_StateLoad(p);
    return 1;
}

int x68k_sound_state_save(void *dst, int cap) {
    uint8_t *p = (uint8_t *)dst;
    int n = x68k_sound_state_size();
    uint32_t magic = SOUND_STATE_MAGIC;
    uint32_t total = (uint32_t)n;
    uint32_t opm_n = (uint32_t)sound_opm_bytes();
    uint32_t adpcm_n = (uint32_t)ADPCM_StateBytes();
    int32_t irq = g_opm_irq_flag;
    if (!dst || cap < n) return 0;
    memcpy(p, &magic, 4); p += 4;
    memcpy(p, &total, 4); p += 4;
    memcpy(p, &irq, 4); p += 4;
    memcpy(p, &g_dma_vec, 4); p += 4;
    memcpy(p, DMA, sizeof(DMA)); p += sizeof(DMA);
    memcpy(p, &opm_n, 4); p += 4;
    if (opm_n) { memcpy(p, g_opm, opm_n); p += opm_n; }
    memcpy(p, &adpcm_n, 4); p += 4;
    ADPCM_StateSave(p);
    return 1;
}

int x68k_sound_state_check(const void *src, int n) {
    return sound_apply((const uint8_t *)src, n, 0);
}

int x68k_sound_state_load(const void *src, int n) {
    return sound_apply((const uint8_t *)src, n, 1);
}

} // extern "C"
