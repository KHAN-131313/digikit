/* The machine declaration of khan/md. patchkit pack reads these records; the device never sees them.
   The DSP symbols are in src/dsp/md.s, which reads the words in the Machinedrum's order: PTCH DEC RAMP RDEC MOD MFRQ
   MDEC MFB. The defaults are the Machinedrum's EFM-BD defaults. */
#include <dk/machine/machine.h>

DK_MACHINE(md, .name = "MD EFM-BD", .short_name = "MDKHAN", .render = "_md_render",
           .note_on = "_md_note_on", .desc = "_md_desc");
DK_PARAM(md, 0, md_ptch, "Pitch", "PTCH", 0, 127, 36);
DK_PARAM(md, 1, md_dec, "Decay", "DEC", 0, 127, 76);
DK_PARAM(md, 2, md_ramp, "Ramp", "RAMP", 0, 127, 64);
DK_PARAM(md, 3, md_rdec, "Ramp Decay", "RDEC", 0, 127, 55);
DK_PARAM(md, 4, md_mod, "Mod Amount", "MOD", 0, 127, 64);
DK_PARAM(md, 5, md_mfrq, "Mod Freq", "MFRQ", 0, 127, 64);
DK_PARAM(md, 6, md_mdec, "Mod Decay", "MDEC", 0, 127, 32);
DK_PARAM(md, 7, md_mfb, "Mod Feedback", "MFB", 0, 127, 127);
DK_PAGE(md, "MDKHAN", "EFM-BD", DK_KNOB(0), DK_KNOB(1), DK_KNOB(2), DK_KNOB(3), DK_KNOB(4),
        DK_KNOB(5), DK_KNOB(6), DK_KNOB(7));

/* EFM-XT: an FM tom, EFM-BD's voice over two octaves through a high-pass; CLIC starts the carrier further in. */
DK_MACHINE(xt, .name = "MD EFM-XT", .short_name = "MDXT", .render = "_mx_render",
           .note_on = "_mx_note_on", .desc = "_mx_desc");
DK_PARAM(xt, 0, xt_ptch, "Pitch", "PTCH", 0, 127, 64);
DK_PARAM(xt, 1, xt_dec, "Decay", "DEC", 0, 127, 64);
DK_PARAM(xt, 2, xt_ramp, "Ramp", "RAMP", 0, 127, 38);
DK_PARAM(xt, 3, xt_rdec, "Ramp Decay", "RDEC", 0, 127, 87);
DK_PARAM(xt, 4, xt_mod, "Mod Amount", "MOD", 0, 127, 48);
DK_PARAM(xt, 5, xt_mfrq, "Mod Freq", "MFRQ", 0, 127, 84);
DK_PARAM(xt, 6, xt_mdec, "Mod Decay", "MDEC", 0, 127, 55);
DK_PARAM(xt, 7, xt_clic, "Click", "CLIC", 0, 127, 127);
DK_PAGE(xt, "MDXT", "EFM-XT", DK_KNOB(0), DK_KNOB(1), DK_KNOB(2), DK_KNOB(3), DK_KNOB(4),
        DK_KNOB(5), DK_KNOB(6), DK_KNOB(7));
