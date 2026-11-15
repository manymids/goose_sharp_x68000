#include "x68k_sound.h"
#include "common.h"
#include "opm.h"

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

/* px68k's default level (OPM_VOL 12 = -8 dB). At the maximum the OPM alone exceeds 16 bits,
   so the mix with the ADPCM (x68k_adpcm.goose) clips. */
#define OPM_VOLUME (-(16 - 12) * 4)

void x68k_sound_init(void) {
    if (!g_opm) {
        g_opm = new MyOPM();
        g_opm->Init(4000000, 44100);
        g_opm->SetVolume(OPM_VOLUME);
    }
    g_opm_irq_flag = 0;
}

void x68k_sound_reset(void) {
    if (g_opm) {
        g_opm->Reset();
        g_opm->CurReg = 0;
        g_opm->CurCount = 0;
        g_opm->SetVolume(OPM_VOLUME);
    }
    g_opm_irq_flag = 0;
}

void x68k_sound_cleanup(void) {
    if (g_opm) {
        delete g_opm;
        g_opm = NULL;
    }
    g_opm_irq_flag = 0;
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

void x68k_sound_scanline_timer(uint32_t cycles) {
    if (g_opm) {
        g_opm->Count2(cycles);
    }
}

// Adds the OPM output to samples that already hold the ADPCM output (interleaved stereo).
void x68k_sound_mix(int16_t *out_buf, int samples) {
    if (!out_buf || samples <= 0 || !g_opm) return;
    uint8_t *pbsp = (uint8_t*)out_buf;
    uint8_t *pbep = (uint8_t*)(out_buf + samples * 2);
    g_opm->Mix(out_buf, samples, pbsp, pbep);
}

int x68k_sound_poll_irq(void) {
    int f = g_opm_irq_flag;
    g_opm_irq_flag = 0;
    return f;
}

#define SOUND_STATE_MAGIC 0x5336384Du

// The state image: this header, then the OPM object.
//
// The OPM (fmgen) is saved as the bytes of the C++ object, which holds pointers: to its own
// members (operator outputs, the chip), and to code and tables of this program (the vtable,
// envelope tables). An image is often loaded by another process (a state file), where the
// object and the program sit at other addresses, so the header records both addresses as they
// were when the image was written, and loading moves every pointer by the difference.
struct SoundStateHeader {
    uint32_t magic;
    uint32_t total;          // bytes of the whole image
    int32_t irq;
    uint32_t opm_bytes;
    uint64_t opm_at;         // address of the OPM object when the image was written
    uint64_t module_at;      // address this program was loaded at
    uint64_t module_bytes;   // size of this program in memory; another build has another size
};

extern "C" void c_host_module_range(uint64_t *base, uint64_t *bytes);

static int sound_opm_bytes(void) {
    return g_opm ? (int)sizeof(MyOPM) : 0;
}

int x68k_sound_state_size(void) {
    return (int)(sizeof(SoundStateHeader) + (size_t)sound_opm_bytes());
}

// Copies the saved OPM object over the live one. A word that pointed into the saved object or
// into the program as it was loaded then is moved to where that is now; any other word is data.
static void opm_restore(const uint8_t *saved, const SoundStateHeader &h, uint64_t module_now) {
    uint8_t *live = (uint8_t *)g_opm;
    const uint64_t opm_now = (uint64_t)(uintptr_t)g_opm;
    size_t at = 0;
    for (; at + sizeof(uint64_t) <= h.opm_bytes; at += sizeof(uint64_t)) {
        uint64_t word;
        memcpy(&word, saved + at, sizeof(word));
        if (word >= h.opm_at && word < h.opm_at + h.opm_bytes) word = word - h.opm_at + opm_now;
        else if (word >= h.module_at && word < h.module_at + h.module_bytes) word = word - h.module_at + module_now;
        memcpy(live + at, &word, sizeof(word));
    }
    if (at < h.opm_bytes) memcpy(live + at, saved + at, h.opm_bytes - at);
}

static int sound_apply(const uint8_t *src, int n, int apply) {
    SoundStateHeader h;
    uint64_t module_now = 0, module_bytes = 0;
    if (!src || n != x68k_sound_state_size()) return 0;
    memcpy(&h, src, sizeof(h));
    c_host_module_range(&module_now, &module_bytes);
    if (h.magic != SOUND_STATE_MAGIC || (int)h.total != n) return 0;
    if ((int)h.opm_bytes != sound_opm_bytes()) return 0;
    if (h.module_bytes != module_bytes) return 0;   // written by another build
    if (!apply) return 1;
    g_opm_irq_flag = h.irq;
    if (h.opm_bytes && g_opm) opm_restore(src + sizeof(h), h, module_now);
    return 1;
}

int x68k_sound_state_save(void *dst, int cap) {
    uint8_t *p = (uint8_t *)dst;
    int n = x68k_sound_state_size();
    SoundStateHeader h;
    if (!dst || cap < n) return 0;
    memset(&h, 0, sizeof(h));
    h.magic = SOUND_STATE_MAGIC;
    h.total = (uint32_t)n;
    h.irq = g_opm_irq_flag;
    h.opm_bytes = (uint32_t)sound_opm_bytes();
    h.opm_at = (uint64_t)(uintptr_t)g_opm;
    c_host_module_range(&h.module_at, &h.module_bytes);
    memcpy(p, &h, sizeof(h));
    if (h.opm_bytes) memcpy(p + sizeof(h), g_opm, h.opm_bytes);
    return 1;
}

int x68k_sound_state_check(const void *src, int n) {
    return sound_apply((const uint8_t *)src, n, 0);
}

int x68k_sound_state_load(const void *src, int n) {
    return sound_apply((const uint8_t *)src, n, 1);
}

} // extern "C"
