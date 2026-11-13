// khan/md: Machinedrum-style machines (<dk/machine/machine.h>), one body for both devices.
// Machines: EFM-BD, EFM-XT and EFM-SD, two sine operators with feedback FM on one shared loop (_md_efm_run).
//
// Based on Digidrum's EFM-BD (soejrd/digidrum, machines/EFM/BD/efm_bd.c, MIT, used with the author's permission),
// rewritten for the SHARC+: float32, phases as 32-bit integers (2^32 a turn, so they wrap for free), the
// Machinedrum's 15-bit sine index kept (it shapes the feedback's timbre), a branch-free sine fold, a degree-7 odd
// polynomial (max error 2.2e-6), knob curves as tables (tables.inc, gen_tables.py) and 48 kHz.
//
// Knobs (words 0..7, the Machinedrum's order): EFM-BD PTCH DEC RAMP RDEC MOD MFRQ MDEC MFB; EFM-XT the same with CLIC for MFB.
// EFM-XT (fitted to the Machinedrum's, research/fit_efm_xt.py): PTCH reads BD's table at 24 + PTCH / 2 (43 to 171 Hz); the
// modulator fed back at half of BD's full; the deviation (3/8) MOD / 16 of BD's pitch at PTCH, not XT's (_md_xt_dev); a
// one-pole high-pass at 125 Hz after the loop; a start level 0.839 of BD's; CLIC starts the carrier up to 0.19 cycle in.
// Per sample, y1 a phase step in 2^32-units a sample:
//   y1 = ptch8 * op1 + ptch;     op1 = op1 * rdec                    pitch ramp
//   s1 = sin(ph1 + m + m);       ph1 += inc(step1 * y1)               modulator, fed back one sample late
//   m  = trunc(fbamt * s1);      x = op2 * s1 * y1;  op2 = op2 * mdec
//   s2 = sin(ph2);               ph2 += inc(modamt * x + y1)          carrier
//   out = fbg * s2;              fbg = fbg * dec
// sin(p): u = FLOAT(p & mask) * 2^-32 in [-0.5, 0.5); w = 1/4 - ||u| - 1/4|; s = w (a1 + w2 (a3 + w2 (a5 + w2 a7)));
// sin = s with u's sign. inc(x) = TRUNC(CLIP x BY 2147483520): under half a turn a sample.
// tests/md_ref.py is this, operation for operation; tests/test_md.py holds the routine to it bit for bit.
//
// State per voice (MD_STATE bytes; the first 6 words are set at note-on, the coefficients each block):
//   0 ph1  1 ph2  2 m  3 op1  4 op2  5 fbg  |  6 ptch  7 ptch8  8 rdec  9 mdec  10 dec  11 step1  12 fbamt  13 modamt
//   14 hpc (the high-pass's coefficient, 0: none)  15 low (its state)
//   16 seed  17 nl  18 hiss (the noise: xorshift32 state, its one-pole high-pass, its level)  |  19 namt (0: no noise)  20 ndec
// Noise, per sample after the loop and before the high-pass: seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
//   w = FLOAT(seed) * 2^-31; d = w - nl; d = d * NC; nl = nl + d; o = w - nl; t = o * hiss; t = t * namt; out = out + t;
//   hiss = hiss * ndec.
// High-pass, per sample after the loop: d = s - low; d = d * hpc; low = low + d; out = s - low.
// A voice whose level fbg is under 2^-22 has died away: it writes zeros and returns DK_DONE (it costs nothing more).
//
// Registers: I3 state, I2 voice input, I1 parameter words, I0 output, I4 the constants, I5 a table; in the loop
// R8 ph1  R9 ph2  R10 m  F11 op1  F12 op2  F13 fbg  F14 0.25  F15 clip; F0..F7 scratch (F7 y1, F5 x, F6 the sine).

#include "dk_machine.inc"
#include "tables.inc"

#define MD_STATE 96
#define MD_CLEAR 96
// EFM-XT's start level: 0.839 * 0.315478504
#define MX_LEVEL 0x3e8784fc

// the constants table _md_k, word offsets
#define K_A1 0
#define K_A3 1
#define K_A5 2
#define K_A7 3
#define K_MASK 4
#define K_M32 5

.SECTION/PM seg_pmco;
.GLOBAL _md_render;
.GLOBAL _md_note_on;
.GLOBAL _mx_render;
.GLOBAL _mx_note_on;
.GLOBAL _ms_render;
.GLOBAL _ms_note_on;
.EXTERN _md_efm_ptch;
.EXTERN _md_efm_dec;
.EXTERN _md_efm_rdec;
.EXTERN _md_efm_mdec;
.EXTERN _md_semis;
.EXTERN _md_k;
.EXTERN _md_xt_dev;
.EXTERN _md_sd_ptch;
.EXTERN _md_sd_ndec;
.EXTERN _md_sd_hpf;

// MD_KNOB(OUT, TABLE, WORD): OUT = T[k] + (T[k + 1] - T[k]) * f for the 8.8 word k.f of parameter WORD.
// The adapter clamps the word to 0 .. 0x7f00, so k <= 127 and k + 1 <= 128 are inside the 129 entries.
// Addresses are bytes: the entry's address is TABLE + 4 k, made in the ALU (a register modifier does not index words here).
// MD_KNOBR is the same for the word in R0. Clobbers R0 R1 R2 F3 F4 I5.
#define MD_KNOB(OUT, TABLE, WORD) \
    R0 = DM(WORD, I1); \
    MD_KNOBR(OUT, TABLE)
#define MD_KNOBR(OUT, TABLE) \
    R2 = -6; \
    R1 = LSHIFT R0 BY R2; \
    R2 = 0x3fc; \
    R1 = R1 AND R2; \
    R2 = TABLE; \
    R1 = R1 + R2; \
    I5 = R1; \
    R2 = 255; \
    R2 = R0 AND R2; \
    F2 = FLOAT R2; \
    R0 = 0x3b800000; \
    F2 = F2 * F0; \
    F3 = DM(0, I5); \
    F4 = DM(1, I5); \
    F4 = F4 - F3; \
    F4 = F4 * F2; \
    OUT = F3 + F4

// MD_ENTER: the call's pointers; a voice that has died away (or whose level is not a number) rests.
#define MD_ENTER \
    I3 = R4; \
    I2 = R8; \
    I1 = R12; \
    R0 = DM(DK_IN_W_OUT, I2); \
    I0 = R0; \
    F13 = DM(5, I3); \
    R0 = 0x34800000; \
    COMP(F13, F0); \
    IF LT JUMP _md_rest

// MD_PITCH: from F5, the PTCH table's turns a sample at note 60: ptch and ptch8 for the voice's note (tests/md_ref.py pitch).
#define MD_PITCH \
    R0 = DM(DK_IN_W_PITCH, I2); \
    R2 = -8; \
    R1 = LSHIFT R0 BY R2; \
    R2 = 12; \
    R1 = R1 - R2; \
    R2 = 0; \
    R1 = MAX(R1, R2); \
    R2 = 96; \
    R1 = MIN(R1, R2); \
    R1 = LSHIFT R1 BY 2; \
    R2 = _md_semis; \
    R1 = R1 + R2; \
    I5 = R1; \
    F3 = DM(0, I5); \
    F5 = F5 * F3; \
    R0 = 0x4f800000; \
    F5 = F5 * F0; \
    DM(6, I3) = F5; \
    R0 = 0x41000000; \
    F6 = F0 * F5; \
    DM(7, I3) = F6

// MD_DECAYS: dec, rdec, mdec and step1 = 8 max(MFRQ, 1) / 128.
#define MD_DECAYS \
    MD_KNOB(F5, _md_efm_dec, 1); \
    DM(10, I3) = F5; \
    MD_KNOB(F5, _md_efm_rdec, 3); \
    DM(8, I3) = F5; \
    MD_KNOB(F5, _md_efm_mdec, 6); \
    DM(9, I3) = F5; \
    R0 = DM(5, I1); \
    F5 = FLOAT R0; \
    R0 = 0x3b800000; \
    F5 = F5 * F0; \
    R0 = 0x3f800000; \
    F5 = MAX(F5, F0); \
    R0 = 0x3c000000; \
    F5 = F5 * F0; \
    R0 = 0x41000000; \
    F5 = F0 * F5; \
    DM(11, I3) = F5

// ---- EFM-BD ----
_md_render:
    MD_ENTER;
    MD_KNOB(F5, _md_efm_ptch, 0);         // PTCH
    MD_PITCH;
    MD_DECAYS;
    R0 = DM(7, I1);                       // MFB
    F5 = FLOAT R0;
    R0 = 0x3b800000;
    F5 = F5 * F0;
    R0 = 0x3c000000;
    F5 = F5 * F0;
    R0 = 0x4f000000;                      // 2^31: m + m is mfb s1 turns
    F5 = F5 * F0;
    DM(12, I3) = F5;                      // fbamt
    R0 = DM(4, I1);                       // MOD
    F5 = FLOAT R0;
    R0 = 0x3b800000;
    F5 = F5 * F0;
    R0 = 0x3c000000;
    F5 = F5 * F0;
    R0 = 0x41000000;
    F5 = F0 * F5;
    DM(13, I3) = F5;                      // modamt = 8 MOD / 128
    R0 = 0;
    DM(14, I3) = R0;                      // no high-pass
    DM(19, I3) = R0;                      // no noise
    JUMP _md_efm_run;

// ---- EFM-XT ----
_mx_render:
    MD_ENTER;
    R0 = DM(0, I1);                       // PTCH, read on BD's table at 24 + PTCH / 2
    R2 = -1;
    R0 = LSHIFT R0 BY R2;
    R2 = 0x1800;
    R0 = R0 + R2;
    MD_KNOBR(F5, _md_efm_ptch);
    MD_PITCH;
    MD_DECAYS;
    R0 = 0x4e800000;                      // 2^30: half of BD's full feedback
    DM(12, I3) = R0;
    MD_KNOB(F5, _md_xt_dev, 0);           // (3/8) / 16 of BD's pitch over XT's, at PTCH
    R0 = DM(4, I1);                       // MOD
    F6 = FLOAT R0;
    R0 = 0x3b800000;
    F6 = F6 * F0;
    F5 = F6 * F5;
    DM(13, I3) = F5;                      // modamt
    R0 = 0x3c84f35c;                      // 1 - exp(-2 pi 125 / 48000)
    DM(14, I3) = R0;
    R0 = 0;
    DM(19, I3) = R0;                      // no noise
    JUMP _md_efm_run;

// ---- EFM-SD ----
// No pitch ramp (op1 is 0); PTCH on _md_sd_ptch (BD's curve at 72 + 5 PTCH / 8); the modulator fed back at full; the deviation
// (9/16) MOD / 16; NOIS's noise (0.1755 NOIS / 127 at the start) decaying on _md_sd_ndec; the high-pass on _md_sd_hpf (off at 0).
// The voice rests when both the tone's level and the noise's (hiss * namt) are under 2^-22.
_ms_render:
    I3 = R4;
    I2 = R8;
    I1 = R12;
    R0 = DM(DK_IN_W_OUT, I2);
    I0 = R0;
    R0 = DM(2, I1);                       // NOIS
    F0 = FLOAT R0;
    R1 = 0x36b52087;                      // 0.1755 / 127 / 256
    F0 = F0 * F1;
    DM(19, I3) = F0;                      // namt
    F1 = DM(18, I3);
    F0 = F0 * F1;                         // the noise's level
    F13 = DM(5, I3);
    F0 = MAX(F0, F13);
    R1 = 0x34800000;
    COMP(F0, F1);
    IF LT JUMP _md_rest;
    MD_KNOB(F5, _md_sd_ptch, 0);
    MD_PITCH;
    MD_DECAYS;
    MD_KNOB(F5, _md_sd_ndec, 3);
    DM(20, I3) = F5;                      // ndec
    R0 = 0x4f000000;                      // 2^31: full feedback
    DM(12, I3) = R0;
    R0 = DM(4, I1);                       // MOD
    F5 = FLOAT R0;
    R0 = 0x3b800000;
    F5 = F5 * F0;
    R0 = 0x3d100000;                      // 9/256: (9/16) / 16
    F5 = F5 * F0;
    DM(13, I3) = F5;                      // modamt
    MD_KNOB(F5, _md_sd_hpf, 7);
    DM(14, I3) = F5;                      // hpc
    JUMP _md_efm_run;

// ---- the shared loop ----
_md_efm_run:
    // ---- the voice's state into registers; envelopes under 1e-30 are 0 (no denormals) ----
    R8 = DM(0, I3);
    R9 = DM(1, I3);
    R10 = DM(2, I3);
    F11 = DM(3, I3);
    F12 = DM(4, I3);
    R1 = 0x0da24260;                      // 1e-30
    F0 = ABS F11;
    COMP(F0, F1);
    IF LT F11 = F1 - F1;
    F0 = ABS F12;
    COMP(F0, F1);
    IF LT F12 = F1 - F1;
    R14 = 0x3e800000;                     // 0.25
    R15 = 0x4effffff;                     // 2147483520.0, the increment's clip
    I4 = _md_k;

    LCNTR = DK_BLOCK, DO _md_efm_end UNTIL LCE;
        // y1 = ptch8 * op1 + ptch; op1 = op1 * rdec
        F0 = DM(7, I3);
        F7 = F0 * F11;
        F0 = DM(6, I3);
        F7 = F7 + F0;
        F0 = DM(8, I3);
        F11 = F11 * F0;
        // s1 = sin(ph1 + m + m)
        R5 = R8 + R10;
        R5 = R5 + R10;
        R1 = DM(K_MASK, I4);
        R0 = R5 AND R1;
        R1 = DM(K_M32, I4);
        F0 = FLOAT R0 BY R1;              // u
        F1 = ABS F0;
        F1 = F1 - F14;
        F1 = ABS F1;
        F1 = F14 - F1;                    // w
        F2 = F1 * F1;                     // w2
        F3 = DM(K_A7, I4);
        F3 = F3 * F2;
        F4 = DM(K_A5, I4);
        F3 = F3 + F4;
        F3 = F3 * F2;
        F4 = DM(K_A3, I4);
        F3 = F3 + F4;
        F3 = F3 * F2;
        F4 = DM(K_A1, I4);
        F3 = F3 + F4;
        F3 = F3 * F1;
        F6 = F3 COPYSIGN F0;              // s1
        // ph1 += inc(step1 * y1); m = trunc(fbamt * s1)
        F0 = DM(11, I3);
        F0 = F0 * F7;
        F0 = CLIP F0 BY F15;
        R0 = TRUNC F0;
        R8 = R8 + R0;
        F0 = DM(12, I3);
        F0 = F0 * F6;
        R10 = TRUNC F0;
        // x = op2 * s1 * y1; op2 = op2 * mdec
        F5 = F12 * F6;
        F5 = F5 * F7;
        F0 = DM(9, I3);
        F12 = F12 * F0;
        // s2 = sin(ph2)
        R1 = DM(K_MASK, I4);
        R0 = R9 AND R1;
        R1 = DM(K_M32, I4);
        F0 = FLOAT R0 BY R1;
        F1 = ABS F0;
        F1 = F1 - F14;
        F1 = ABS F1;
        F1 = F14 - F1;
        F2 = F1 * F1;
        F3 = DM(K_A7, I4);
        F3 = F3 * F2;
        F4 = DM(K_A5, I4);
        F3 = F3 + F4;
        F3 = F3 * F2;
        F4 = DM(K_A3, I4);
        F3 = F3 + F4;
        F3 = F3 * F2;
        F4 = DM(K_A1, I4);
        F3 = F3 + F4;
        F3 = F3 * F1;
        F6 = F3 COPYSIGN F0;              // s2
        // ph2 += inc(modamt * x + y1)
        F0 = DM(13, I3);
        F0 = F0 * F5;
        F0 = F0 + F7;
        F0 = CLIP F0 BY F15;
        R0 = TRUNC F0;
        R9 = R9 + R0;
        // out = fbg * s2; fbg = fbg * dec
        F0 = F13 * F6;
        DM(I0, M6) = F0;
        F0 = DM(10, I3);
_md_efm_end: F13 = F13 * F0;

    DM(0, I3) = R8;
    DM(1, I3) = R9;
    DM(2, I3) = R10;
    DM(3, I3) = F11;
    DM(4, I3) = F12;
    DM(5, I3) = F13;

    // the noise, when the machine has some
    R3 = DM(19, I3);
    R3 = PASS R3;
    IF EQ JUMP _md_no_noise;
    R0 = DM(16, I3);                      // seed
    R2 = -17;
    F4 = DM(17, I3);                      // nl
    F5 = DM(18, I3);                      // hiss
    F6 = R3;                              // namt
    F7 = DM(20, I3);                      // ndec
    R3 = 0x3ea64801;                      // NC = 1 - exp(-2 pi 3000 / 48000)
    R11 = -31;
    R12 = DM(DK_IN_W_OUT, I2);
    I1 = R12;
    LCNTR = DK_BLOCK, DO _md_noise_end UNTIL LCE;
        R1 = LSHIFT R0 BY 13;
        R0 = R0 XOR R1;
        R1 = LSHIFT R0 BY R2;
        R0 = R0 XOR R1;
        R1 = LSHIFT R0 BY 5;
        R0 = R0 XOR R1;
        F8 = FLOAT R0 BY R11;             // w
        F9 = F8 - F4;
        F9 = F9 * F3;
        F4 = F4 + F9;
        F8 = F8 - F4;                     // o
        F8 = F8 * F5;
        F8 = F8 * F6;
        F10 = DM(0, I1);
        F10 = F10 + F8;
        F5 = F5 * F7;
_md_noise_end: DM(I1, M6) = F10;
    DM(16, I3) = R0;
    DM(17, I3) = F4;
    DM(18, I3) = F5;
_md_no_noise:
    // the high-pass, when the machine has one
    R3 = DM(14, I3);
    R3 = PASS R3;
    IF EQ JUMP _md_ok;
    F2 = DM(15, I3);                      // low
    R0 = DM(DK_IN_W_OUT, I2);
    I1 = R0;
    LCNTR = DK_BLOCK, DO _md_hp_end UNTIL LCE;
        F0 = DM(0, I1);
        F1 = F0 - F2;
        F1 = F1 * F3;
        F2 = F2 + F1;
        F0 = F0 - F2;
_md_hp_end: DM(I1, M6) = F0;
    DM(15, I3) = F2;
_md_ok:
    R0 = DK_OK;
    JUMP (M13, I13);

_md_rest:
    R0 = 0;
    LCNTR = DK_BLOCK, DO _md_rest_end UNTIL LCE;
_md_rest_end: DM(I0, M6) = R0;
    R0 = DK_DONE;
    JUMP (M13, I13);

// note_on (not at offset 0 of the image: an offset of 0 reads as "no note_on")
//   op1 = (RAMP / 256 - 16) / 128; op2 = 1; fbg = 0.630957 * 0.5; ph1 = ph2 = 4000/32768 of a turn; m = 0
_md_note_on:
    I3 = R4;
    I1 = R12;
    R0 = DM(2, I1);                       // RAMP
    F1 = FLOAT R0;
    R0 = 0x3b800000;                      // 1/256
    F1 = F1 * F0;
    R0 = 0x41800000;                      // 16.0
    F1 = F1 - F0;
    R0 = 0x3c000000;                      // 1/128
    F1 = F1 * F0;
    DM(3, I3) = F1;                       // op1
    R0 = 0x3f800000;
    DM(4, I3) = R0;                       // op2 = 1
    R0 = 0x3ea18666;
    DM(5, I3) = R0;                       // fbg = 0.315478504
    R0 = 524288000;
    DM(0, I3) = R0;                       // ph1
    DM(1, I3) = R0;                       // ph2
    R0 = 0;
    DM(2, I3) = R0;                       // m
    JUMP (M13, I13);

// EFM-XT's note_on: as BD's, the level 0.839 of BD's, the carrier CLIC * 0.19 / 128 of a cycle in, the high-pass at rest.
_mx_note_on:
    I3 = R4;
    I1 = R12;
    R0 = DM(2, I1);                       // RAMP
    F1 = FLOAT R0;
    R0 = 0x3b800000;
    F1 = F1 * F0;
    R0 = 0x41800000;
    F1 = F1 - F0;
    R0 = 0x3c000000;
    F1 = F1 * F0;
    DM(3, I3) = F1;                       // op1
    R0 = 0x3f800000;
    DM(4, I3) = R0;                       // op2 = 1
    R0 = MX_LEVEL;
    DM(5, I3) = R0;                       // fbg
    R0 = 524288000;
    DM(0, I3) = R0;                       // ph1
    R0 = DM(7, I1);                       // CLIC
    F1 = FLOAT R0;
    R0 = 0x46c28f5c;                      // 0.19 * 2^32 / 32768
    F1 = F1 * F0;
    R1 = TRUNC F1;
    DM(1, I3) = R1;                       // ph2
    R0 = 0;
    DM(2, I3) = R0;                       // m
    DM(15, I3) = R0;                      // low
    JUMP (M13, I13);

// EFM-SD's note_on: the pair 0.0153 cycle in, no ramp, BD's level, the noise at full and its filters at rest.
_ms_note_on:
    I3 = R4;
    R0 = 0;
    DM(3, I3) = R0;                       // op1: no ramp
    DM(2, I3) = R0;                       // m
    DM(15, I3) = R0;                      // low
    DM(17, I3) = R0;                      // nl
    R0 = 0x3f800000;
    DM(4, I3) = R0;                       // op2 = 1
    DM(18, I3) = R0;                      // hiss = 1
    R0 = 0x3ea18666;
    DM(5, I3) = R0;                       // fbg
    R0 = 65754096;
    DM(0, I3) = R0;                       // ph1
    DM(1, I3) = R0;                       // ph2
    R0 = 0x2545f491;
    DM(16, I3) = R0;                      // seed
    JUMP (M13, I13);

.SECTION/DM seg_dmda;
// dk_machine_desc: magic, contract, n_params, voices, state_bytes, state_clear_bytes, max_cycles_block, max_cycles_note_on,
// max_call_depth, stack_bytes.
.GLOBAL _md_desc;
.VAR _md_desc = DK_MAGIC;
.VAR _md_desc1 = DK_MACHINE_V1;
.VAR _md_desc2 = 8;
.VAR _md_desc3 = DK_MAX_VOICES;
.VAR _md_desc4 = MD_STATE;
.VAR _md_desc5 = MD_CLEAR;
.VAR _md_desc6 = 4000;
.VAR _md_desc7 = 4400;
.VAR _md_desc8 = 0;
.VAR _md_desc9 = 0;
.GLOBAL _mx_desc;
.VAR _mx_desc = DK_MAGIC;
.VAR _mx_desc1 = DK_MACHINE_V1;
.VAR _mx_desc2 = 8;
.VAR _mx_desc3 = DK_MAX_VOICES;
.VAR _mx_desc4 = MD_STATE;
.VAR _mx_desc5 = MD_CLEAR;
.VAR _mx_desc6 = 4400;
.VAR _mx_desc7 = 4400;
.VAR _mx_desc8 = 0;
.VAR _mx_desc9 = 0;
.GLOBAL _ms_desc;
.VAR _ms_desc = DK_MAGIC;
.VAR _ms_desc1 = DK_MACHINE_V1;
.VAR _ms_desc2 = 8;
.VAR _ms_desc3 = DK_MAX_VOICES;
.VAR _ms_desc4 = MD_STATE;
.VAR _ms_desc5 = MD_CLEAR;
.VAR _ms_desc6 = 5000;
.VAR _ms_desc7 = 4400;
.VAR _ms_desc8 = 0;
.VAR _ms_desc9 = 0;
