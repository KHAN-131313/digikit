/* The machines of khan/md, declared by builder calls in init. On the machine list they sit in the folder Machinedrum (titled MD), one folder
   per family below it (EFM; TRX and the others when they come). The DSP (src/dsp/md.s)
   reads the words in the Machinedrum's order; the defaults are the Machinedrum's. Knob orders: the fit scripts' (research).
   EFM-BD: PTCH DEC RAMP RDEC MOD MFRQ MDEC MFB (DSP prefix md).
   EFM-XT: an FM tom, EFM-BD's voice over two octaves through a high-pass; CLIC starts the carrier further in (mx).
   EFM-SD: PTCH DEC NOIS NDEC MOD MFRQ MDEC HPF (ms).   EFM-CP: PTCH DEC CLPS CDEC MOD MFRQ MDEC HPF (mc).
   EFM-RS: PTCH DEC MOD HPF SNAR SPTC SDEC SMOD (mr).   EFM-CB: PTCH DEC SNAP FB MOD MFRQ MDEC (mb; seven knobs, as on the MD).
   EFM-HH: PTCH DEC TREM TFRQ MOD MFRQ MDEC FB (mh).   EFM-CY: PTCH DEC FB HPF MOD MFRQ MDEC (my; seven knobs). */
#include <dk/core/module.h>
#include "module_ids.h"

typedef struct md_knob {
    const char *name, *short_name;
    uint32_t def;
} md_knob;

static void add(dk_module_ctx *ctx, uint32_t id, const char *family, const char *name,
                const char *short_name, const md_knob *k, unsigned n)
{
    dk_machine *m = dk_module_ctx_add_machine(ctx, id, name, short_name);
    dk_machine_folder(m, family);
    dk_page *p = dk_machine_add_page(m, name, short_name);
    for (unsigned i = 0; i < n; i++)
        dk_page_add_param(p, k[i].name, k[i].short_name, k[i].def);
}

static const md_knob efm_bd[8] = {
    {"Pitch", "PTCH", 36},      {"Decay", "DEC", 76},         {"Ramp", "RAMP", 64},
    {"Ramp Decay", "RDEC", 55}, {"Mod Amount", "MOD", 64},    {"Mod Freq", "MFRQ", 64},
    {"Mod Decay", "MDEC", 32},  {"Mod Feedback", "MFB", 127},
};
static const md_knob efm_xt[8] = {
    {"Pitch", "PTCH", 64},      {"Decay", "DEC", 64},      {"Ramp", "RAMP", 38},
    {"Ramp Decay", "RDEC", 87}, {"Mod Amount", "MOD", 48}, {"Mod Freq", "MFRQ", 84},
    {"Mod Decay", "MDEC", 55},  {"Click", "CLIC", 127},
};
static const md_knob efm_sd[8] = {
    {"Pitch", "PTCH", 64},       {"Decay", "DEC", 55},      {"Noise", "NOIS", 64},
    {"Noise Decay", "NDEC", 64}, {"Mod Amount", "MOD", 64}, {"Mod Freq", "MFRQ", 32},
    {"Mod Decay", "MDEC", 44},   {"High-pass", "HPF", 16},
};
static const md_knob efm_cp[8] = {
    {"Pitch", "PTCH", 83},      {"Decay", "DEC", 41},      {"Claps", "CLPS", 64},
    {"Clap Decay", "CDEC", 36}, {"Mod Amount", "MOD", 32}, {"Mod Freq", "MFRQ", 64},
    {"Mod Decay", "MDEC", 127}, {"High-pass", "HPF", 32},
};
static const md_knob efm_rs[8] = {
    {"Pitch", "PTCH", 64},       {"Decay", "DEC", 32},      {"Mod Amount", "MOD", 64},
    {"High-pass", "HPF", 32},    {"Snare", "SNAR", 64},     {"Snare Pitch", "SPTC", 64},
    {"Snare Decay", "SDEC", 44}, {"Snare Mod", "SMOD", 64},
};
static const md_knob efm_cb[7] = {
    {"Pitch", "PTCH", 64},     {"Decay", "DEC", 64},      {"Snap", "SNAP", 64},
    {"Feedback", "FB", 96},    {"Mod Amount", "MOD", 64}, {"Mod Freq", "MFRQ", 64},
    {"Mod Decay", "MDEC", 64},
};
static const md_knob efm_hh[8] = {
    {"Pitch", "PTCH", 96},       {"Decay", "DEC", 32},      {"Tremolo", "TREM", 0},
    {"Tremolo Freq", "TFRQ", 0}, {"Mod Amount", "MOD", 64}, {"Mod Freq", "MFRQ", 64},
    {"Mod Decay", "MDEC", 64},   {"Feedback", "FB", 127},
};
static const md_knob efm_cy[7] = {
    {"Pitch", "PTCH", 64},     {"Decay", "DEC", 72},      {"Feedback", "FB", 96},
    {"High-pass", "HPF", 127}, {"Mod Amount", "MOD", 64}, {"Mod Freq", "MFRQ", 32},
    {"Mod Decay", "MDEC", 64},
};

static int32_t init(dk_module_ctx *ctx)
{
    dk_module_ctx_folder(
        ctx, "Machinedrum (MD)"); /* the machine list: Machinedrum > EFM > the machines */
    add(ctx, DK_MACHINE_ID_MD, "EFM", "EFM-BD", "MDKHAN", efm_bd, 8);
    add(ctx, DK_MACHINE_ID_XT, "EFM", "EFM-XT", "MDXT", efm_xt, 8);
    add(ctx, DK_MACHINE_ID_SD, "EFM", "EFM-SD", "MDSD", efm_sd, 8);
    add(ctx, DK_MACHINE_ID_CP, "EFM", "EFM-CP", "MDCP", efm_cp, 8);
    add(ctx, DK_MACHINE_ID_RS, "EFM", "EFM-RS", "MDRS", efm_rs, 8);
    add(ctx, DK_MACHINE_ID_CB, "EFM", "EFM-CB", "MDCB", efm_cb, 7);
    add(ctx, DK_MACHINE_ID_HH, "EFM", "EFM-HH", "MDHH", efm_hh, 8);
    add(ctx, DK_MACHINE_ID_CY, "EFM", "EFM-CY", "MDCY", efm_cy, 7);
    return DK_OK;
}

const dk_module_def dk_module = {.init = init};
