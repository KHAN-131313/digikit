/* The machines of khan/md, declared by builder calls in init. The DSP (src/dsp/md.s) reads the words in the Machinedrum's
   order; the defaults are the Machinedrum's.
   EFM-BD: PTCH DEC RAMP RDEC MOD MFRQ MDEC MFB (DSP prefix md).
   EFM-XT: an FM tom, EFM-BD's voice over two octaves through a high-pass; CLIC starts the carrier further in (DSP prefix mx). */
#include <dk/core/module.h>
#include "module_ids.h"

typedef struct md_knob {
    const char *name, *short_name;
    uint32_t def;
} md_knob;

static void add(dk_module_ctx *ctx, uint32_t id, const char *name, const char *short_name, const char *title,
                const md_knob *k)
{
    dk_machine *m = dk_module_ctx_add_machine(ctx, id, name, short_name);
    dk_page *p = dk_machine_add_page(m, title, short_name);
    for (unsigned i = 0; i < 8; i++)
        dk_page_add_param(p, k[i].name, k[i].short_name, k[i].def);
}

static const md_knob efm_bd[8] = {
    {"Pitch", "PTCH", 36},     {"Decay", "DEC", 76},      {"Ramp", "RAMP", 64},     {"Ramp Decay", "RDEC", 55},
    {"Mod Amount", "MOD", 64}, {"Mod Freq", "MFRQ", 64}, {"Mod Decay", "MDEC", 32}, {"Mod Feedback", "MFB", 127},
};
static const md_knob efm_xt[8] = {
    {"Pitch", "PTCH", 64},     {"Decay", "DEC", 64},      {"Ramp", "RAMP", 38},     {"Ramp Decay", "RDEC", 87},
    {"Mod Amount", "MOD", 48}, {"Mod Freq", "MFRQ", 84}, {"Mod Decay", "MDEC", 55}, {"Click", "CLIC", 127},
};

static int32_t init(dk_module_ctx *ctx)
{
    dk_module_ctx_folder(ctx, "MD"); /* the machine list shows them in one MD folder row */
    add(ctx, DK_MACHINE_ID_MD, "EFM-BD", "MDKHAN", "EFM-BD", efm_bd);
    add(ctx, DK_MACHINE_ID_XT, "EFM-XT", "MDXT", "EFM-XT", efm_xt);
    return DK_OK;
}

const dk_module_def dk_module = {.init = init};
