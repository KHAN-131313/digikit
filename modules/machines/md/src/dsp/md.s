// khan/md: Machinedrum-style machines (<dk/machine/machine.h>), one body for both devices.
// Machines: EFM-BD, EFM-XT, EFM-SD, EFM-CP, EFM-RS, EFM-CB, EFM-HH and EFM-CY, two sine operators with feedback FM on one shared loop (_md_efm_run).
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
//   21 env  22 left  23 until  |  26 claps (0: none)   (EFM-CP's clap train: its gain, the boundaries left -- the claps after
//   the first, then the tail's start -- and the samples from the block's start to the next one)
// Claps, per sample after the noise: cnt = cnt - 1; if cnt == 0: env = 1, rate = next; out = out * env; env = env * rate.
//   A boundary at sample b of the block starts cnt at b + 1 (0: none in this block; the spacing is never under 32 samples).
// High-pass, per sample after the loop: d = s - low; d = d * hpc; low = low + d; out = s - low.
// A voice whose level fbg is under 2^-22 has died away: it writes zeros and returns DK_DONE (it costs nothing more).
//
// Registers: I3 state, I2 voice input, I1 parameter words, I0 output, I4 the constants, I5 a table; in the loop
// R8 ph1  R9 ph2  R10 m  F11 op1  F12 op2  F13 fbg  F14 0.25  F15 clip; F0..F7 scratch (F7 y1, F5 x, F6 the sine).

#include "dk_machine.inc"
#include "tables.inc"

// state bytes: BD and XT use words 0..15, SD 0..20, CP 0..26; RS adds the snare's pair (28..41) and a scratch block (44..75)
#define MD_STATE 112
#define MD_CLEAR 112
#define MR_STATE 304
#define MR_CLEAR 176
#define MR_PAIR 112
#define MR_SCRATCH 176
// EFM-CB: pair A words 0..17 (m2 16, cfb 17), the snap's level 27, pair B at word 28 (its m2 44, cfb 45), scratch 48..79
#define MB_STATE 320
#define MB_CLEAR 184
#define MB_SCRATCH 192
// EFM-CY: ph 0..3, mph 4..7, inc 8..11, minc 12..15 (integers), depth 16, prev 17, env 18, low1 19, low2 20, before 21
#define MY_STATE 96
#define MY_CLEAR 96
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
.GLOBAL _mc_render;
.GLOBAL _mc_note_on;
.GLOBAL _mr_render;
.GLOBAL _mr_note_on;
.GLOBAL _mb_render;
.GLOBAL _mb_note_on;
.GLOBAL _mh_render;
.GLOBAL _mh_note_on;
.GLOBAL _my_render;
.GLOBAL _my_note_on;
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
.EXTERN _md_cp_ptch;
.EXTERN _md_cp_space;
.EXTERN _md_cp_crate;
.EXTERN _md_rs_ptch;
.EXTERN _md_cb_ptch;
.EXTERN _md_hh_ptch;
.EXTERN _md_hh_trem;
.EXTERN _md_cy_mdec;
.EXTERN _md_cy_hpf;

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
    DM(26, I3) = R0;                      // no claps
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
    DM(26, I3) = R0;                      // no claps
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
    R0 = 0;
    DM(26, I3) = R0;                      // no claps
    JUMP _md_efm_run;

// ---- EFM-CP ----
// EFM-SD's tone (no ramp, full feedback, (9/16) MOD / 16, SD's HPF) on _md_cp_ptch (BD's curve at 72 + 11 PTCH / 8), at a
// constant level (fbg BD's start level, dec 1), times the clap train: CLPS >> 3 claps (none: the tail alone) TRUNC
// _md_cp_space samples apart (CDEC), each from 1 falling 22 dB a spacing (_md_cp_crate), then the tail from 1 at DEC's rate.
// The voice rests when the train is over (left 0) and its gain is under 2^-22.
_mc_render:
    I3 = R4;
    I2 = R8;
    I1 = R12;
    R0 = DM(DK_IN_W_OUT, I2);
    I0 = R0;
    R0 = DM(22, I3);                      // left
    R0 = PASS R0;
    IF NE JUMP _mc_live;
    F0 = DM(21, I3);                      // env
    R1 = 0x34800000;
    COMP(F0, F1);
    IF LT JUMP _md_rest;
_mc_live:
    MD_KNOB(F5, _md_cp_ptch, 0);
    MD_PITCH;
    MD_DECAYS;
    R0 = 0x3f800000;
    DM(10, I3) = R0;                      // the tone at a constant level: the train is the envelope
    R0 = 0x4f000000;
    DM(12, I3) = R0;                      // full feedback
    R0 = DM(4, I1);                       // MOD
    F5 = FLOAT R0;
    R0 = 0x3b800000;
    F5 = F5 * F0;
    R0 = 0x3d100000;
    F5 = F5 * F0;
    DM(13, I3) = F5;                      // modamt
    MD_KNOB(F5, _md_sd_hpf, 7);
    DM(14, I3) = F5;                      // hpc
    R0 = 0;
    DM(19, I3) = R0;                      // no noise
    R0 = 1;
    DM(26, I3) = R0;                      // claps
    JUMP _md_efm_run;

// ---- EFM-RS ----
// Two fed-back pairs, ratio 4, no modulation envelope, BD's level: the rim (PTCH on _md_rs_ptch, BD's curve at 104 + PTCH;
// DEC; MOD (1/8) / 16) and the snare (SPTC on _md_sd_ptch; SDEC; SMOD (9/16) / 16) in a scratch block, mixed in at SNAR / 127;
// then SD's HPF. Knobs: PTCH DEC MOD HPF SNAR SPTC SDEC SMOD. Rests when both pairs' levels are under 2^-22.
#define MR_PAIR_COEFS(PTAB, PW, DW, MW, MK) \
    MD_KNOB(F5, PTAB, PW); \
    MD_PITCH; \
    MD_KNOB(F5, _md_efm_dec, DW); \
    DM(10, I3) = F5; \
    R0 = 0; \
    DM(8, I3) = R0; \
    R0 = 0x3f800000; \
    DM(9, I3) = R0; \
    R0 = 0x40800000; \
    DM(11, I3) = R0; \
    R0 = 0x4f000000; \
    DM(12, I3) = R0; \
    R0 = DM(MW, I1); \
    F5 = FLOAT R0; \
    R0 = MK; \
    F5 = F5 * F0; \
    DM(13, I3) = F5

_mr_render:
    I3 = R4;
    M1 = R4;                              // the state's base, kept over the loop's calls (they clobber R0..R15)
    I2 = R8;
    I1 = R12;
    R0 = DM(DK_IN_W_OUT, I2);
    I0 = R0;
    F13 = DM(5, I3);
    R0 = MR_PAIR;
    R0 = R4 + R0;
    I5 = R0;
    F1 = DM(5, I5);
    F13 = MAX(F13, F1);
    R0 = 0x34800000;
    COMP(F13, F0);
    IF LT JUMP _md_rest;
    MR_PAIR_COEFS(_md_rs_ptch, 0, 1, 2, 0x38000000);      // the rim: (1/8) / 16 / 256 = 2^-15
    MD_KNOB(F5, _md_sd_hpf, 3);
    DM(14, I3) = F5;                      // hpc
    R0 = 0;
    DM(19, I3) = R0;                      // no noise
    DM(26, I3) = R0;                      // no claps
    R4 = M1;                              // (MD_KNOB uses F4)
    R0 = MR_PAIR;
    R0 = R4 + R0;
    I3 = R0;
    MR_PAIR_COEFS(_md_sd_ptch, 5, 6, 7, 0x39100000);      // the snare: (9/16) / 16 / 256
    // the snare's pair into the scratch block, then the rim's into the output
    R4 = M1;
    R0 = MR_SCRATCH;
    R0 = R4 + R0;
    I0 = R0;
    CALL _md_efm_loop;
    R4 = M1;
    I3 = R4;
    R0 = DM(DK_IN_W_OUT, I2);
    I0 = R0;
    CALL _md_efm_loop;
    R4 = M1;
    I3 = R4;
    // out = out + scratch * SNAR / 127
    R0 = DM(4, I1);
    F2 = FLOAT R0;
    R0 = 0x38010204;                      // 1 / (127 * 256)
    F2 = F2 * F0;
    R0 = MR_SCRATCH;
    R0 = R4 + R0;
    I5 = R0;
    R0 = DM(DK_IN_W_OUT, I2);
    I1 = R0;
    LCNTR = DK_BLOCK, DO _mr_mix_end UNTIL LCE;
        F1 = DM(I5, M6);
        F1 = F1 * F2;
        F0 = DM(0, I1);
        F0 = F0 + F1;
_mr_mix_end: DM(I1, M6) = F0;
    JUMP _md_efm_post;

// ---- EFM-CB ----
// Two tones of level 0.177, the low on _md_cb_ptch (BD's curve at 88 + 5 PTCH / 8), the high 1.4808 times it; each its own
// modulator at MFRQ / 16 with MDEC's envelope and half BD's deviation (MOD 2^-13 a word unit), no modulator feedback; each
// carrier fed back on itself at (3/8) FB / 128 (_md_efm_loop_cfb). DEC the level's decay; SNAP takes 0.8 SNAP / 127 of the
// level away, -60 dB in 80 ms: out = (lo + hi) * (snap * share + 1 - share). Knobs: PTCH DEC SNAP FB MOD MFRQ MDEC -.
#define MB_PAIR_COEFS \
    MD_PITCH; \
    MD_DECAYS; \
    R0 = 0; \
    DM(12, I3) = R0; \
    R0 = DM(4, I1); \
    F5 = FLOAT R0; \
    R0 = 0x39000000; \
    F5 = F5 * F0; \
    DM(13, I3) = F5; \
    R0 = DM(3, I1); \
    F5 = FLOAT R0; \
    R0 = 0x46c00000; \
    F5 = F5 * F0; \
    DM(17, I3) = F5

_mb_render:
    I3 = R4;
    M1 = R4;
    I2 = R8;
    I1 = R12;
    R0 = DM(DK_IN_W_OUT, I2);
    I0 = R0;
    F13 = DM(5, I3);
    R0 = MR_PAIR;
    R0 = R4 + R0;
    I5 = R0;
    F1 = DM(5, I5);
    F13 = MAX(F13, F1);
    R0 = 0x34800000;
    COMP(F13, F0);
    IF LT JUMP _md_rest;
    MD_KNOB(F5, _md_cb_ptch, 0);
    MB_PAIR_COEFS;
    R0 = 0;
    DM(14, I3) = R0;                      // no high-pass
    DM(19, I3) = R0;                      // no noise
    DM(26, I3) = R0;                      // no claps
    R4 = M1;
    R0 = MR_PAIR;
    R0 = R4 + R0;
    I3 = R0;
    MD_KNOB(F5, _md_cb_ptch, 0);
    R0 = 0x3fbd8adb;                      // 1.4808
    F5 = F5 * F0;
    MB_PAIR_COEFS;
    R4 = M1;
    R0 = MB_SCRATCH;
    R0 = R4 + R0;
    I0 = R0;
    CALL _md_efm_loop_cfb;
    R4 = M1;
    I3 = R4;
    R0 = DM(DK_IN_W_OUT, I2);
    I0 = R0;
    CALL _md_efm_loop_cfb;
    R4 = M1;
    I3 = R4;
    R0 = DM(2, I1);                       // SNAP
    F9 = FLOAT R0;
    R0 = 0x37ce69a0;                      // 0.8 / 127 / 256
    F9 = F9 * F0;                         // share
    R0 = 0x3f800000;
    F10 = F0 - F9;                        // 1 - share
    R11 = 0x3f7f8a37;                     // the snap's fall a sample
    F8 = DM(27, I3);
    R0 = MB_SCRATCH;
    R0 = R4 + R0;
    I5 = R0;
    R0 = DM(DK_IN_W_OUT, I2);
    I1 = R0;
    LCNTR = DK_BLOCK, DO _mb_mix_end UNTIL LCE;
        F1 = DM(I5, M6);
        F0 = DM(0, I1);
        F0 = F0 + F1;
        F2 = F8 * F9;
        F2 = F2 + F10;
        F0 = F0 * F2;
        F8 = F8 * F11;
_mb_mix_end: DM(I1, M6) = F0;
    DM(27, I3) = F8;
    JUMP _md_efm_post;

// ---- EFM-HH ----
// One carrier-fed-back pair (_md_efm_loop_cfb) on _md_hh_ptch (BD's curve at 104 + 5 PTCH / 8) at BD's level: deviation BD's
// (MOD 2^-12 a word unit), FB the carrier's feedback at BD's MFB scale (FB 65536 a word unit), no modulator feedback; DEC
// BD's. Then a pass: y = (x - xprev) * 1.402 * g, g the tremolo's gain from the block's start to its end in 32 equal steps:
// g = 1 - TREM / 127 * (1 - cos(phi)) / 2 at the block's end, phi advancing TRUNC(32 _md_hh_trem) a block (TFRQ).
// State: the pair 0..17; xprev 20, phi 21, g 22. Knobs: PTCH DEC TREM TFRQ MOD MFRQ MDEC FB. (A short hat does not choke
// the open ones yet: that needs state across voices.)
_mh_render:
    MD_ENTER;
    M1 = R4;
    MD_KNOB(F5, _md_hh_ptch, 0);
    MD_PITCH;
    MD_DECAYS;
    R0 = 0;
    DM(12, I3) = R0;                      // no modulator feedback
    DM(14, I3) = R0;                      // no high-pass
    DM(19, I3) = R0;                      // no noise
    DM(26, I3) = R0;                      // no claps
    R0 = DM(4, I1);
    F5 = FLOAT R0;
    R0 = 0x39800000;                      // 2^-12: MOD / 16, a word unit
    F5 = F5 * F0;
    DM(13, I3) = F5;
    R0 = DM(7, I1);
    F5 = FLOAT R0;
    R0 = 0x47800000;                      // 65536: FB / 128 * 2^31, a word unit
    F5 = F5 * F0;
    DM(17, I3) = F5;
    CALL _md_efm_loop_cfb;
    R4 = M1;
    I3 = R4;
    I4 = _md_k;
    R14 = 0x3e800000;                     // 0.25, for the sine
    // the tremolo's gain at the block's end
    MD_KNOB(F5, _md_hh_trem, 3);
    R0 = 0x42000000;                      // 32.0
    F5 = F5 * F0;
    R2 = TRUNC F5;                        // a block's turn
    R0 = DM(21, I3);
    R0 = R0 + R2;
    DM(21, I3) = R0;                      // phi
    R1 = 0x40000000;
    R5 = R0 + R1;                         // phi + a quarter turn: the sine is the cosine
    R1 = DM(K_MASK, I4);
    R0 = R5 AND R1;
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
    F6 = F3 COPYSIGN F0;                  // cos(phi)
    R0 = DM(2, I1);                       // TREM
    F7 = FLOAT R0;
    R0 = 0x38010204;                      // 1 / (127 * 256)
    F7 = F7 * F0;                         // depth
    R0 = 0x3f800000;
    F8 = F0 - F6;                         // 1 - cos
    R1 = 0x3f000000;
    F8 = F8 * F1;                         // (1 - cos) / 2
    F8 = F8 * F7;
    F9 = F0 - F8;                         // g1
    F12 = DM(22, I3);                     // g0
    DM(22, I3) = F9;
    F13 = F9 - F12;
    R0 = 0x3d000000;                      // 1/32
    F13 = F13 * F0;                       // the gain's step
    F10 = DM(20, I3);                     // xprev
    R11 = 0x3fb374bc;                     // 1.402
    R0 = DM(DK_IN_W_OUT, I2);
    I1 = R0;
    LCNTR = DK_BLOCK, DO _mh_end UNTIL LCE;
        F0 = DM(0, I1);
        F1 = F0 - F10;
        F10 = PASS F0;
        F1 = F1 * F11;
        F1 = F1 * F12;
        F12 = F12 + F13;
_mh_end: DM(I1, M6) = F1;
    DM(20, I3) = F10;
    JUMP _md_efm_post;

// MD_SIN: F6 = sin(R0), R0 a 2^32-turn phase (the FM loop's sine: 15-bit index, degree-7 polynomial). I4 _md_k, F14 0.25.
// Clobbers R0..R4, F6.
#define MD_SIN \
    R1 = DM(K_MASK, I4); \
    R0 = R0 AND R1, R2 = DM(K_M32, I4); \
    F0 = FLOAT R0 BY R2; \
    F1 = ABS F0, F3 = DM(K_A7, I4); \
    F1 = F1 - F14; \
    F1 = ABS F1; \
    F1 = F14 - F1, F4 = DM(K_A5, I4); \
    F2 = F1 * F1; \
    F3 = F3 * F2; \
    F3 = F3 + F4, F4 = DM(K_A3, I4); \
    F3 = F3 * F2; \
    F3 = F3 + F4, F4 = DM(K_A1, I4); \
    F3 = F3 * F2; \
    F3 = F3 + F4; \
    F3 = F3 * F1; \
    F6 = F3 COPYSIGN F0

// MY_PARTIAL(K): partial K of EFM-CY's sample. F9 the index, R11 the fed-back phase, F8 the sum so far.
#define MY_PARTIAL(K) \
    R0 = DM(4 + K, I3); \
    R1 = DM(12 + K, I3); \
    R5 = R0 + R1; \
    DM(4 + K, I3) = R5; \
    MD_SIN; \
    F6 = F6 * F9; \
    R7 = TRUNC F6; \
    R7 = LSHIFT R7 BY 2; \
    R0 = DM(0 + K, I3); \
    R1 = DM(8 + K, I3); \
    R5 = R0 + R1; \
    DM(0 + K, I3) = R5; \
    R0 = R0 + R11; \
    R0 = R0 + R7; \
    MD_SIN; \
    F8 = F8 + F6

// MY_INC(K, RATIO): inc K = TRUNC CLIP(base * RATIO), minc K = TRUNC CLIP(base * RATIO * r); F5 base, F10 r, F15 the clip.
#define MY_INC(K, RATIO) \
    R0 = RATIO; \
    F1 = F5 * F0; \
    F2 = CLIP F1 BY F15; \
    R2 = TRUNC F2; \
    DM(8 + K, I3) = R2; \
    F1 = F1 * F10; \
    F2 = CLIP F1 BY F15; \
    R2 = TRUNC F2; \
    DM(12 + K, I3) = R2

// ---- EFM-CY ----
// Four partials at 1, 1.41, 1.80 and 2.70 of _md_hh_ptch (BD's curve at 104 + 5 PTCH / 8), each phase-moved by its own
// modulator at MFRQ / 16 + 0.5 of it, by an index (0.7 + 9.05 MOD / 127) radians that falls by _md_cy_mdec a block (MDEC); the
// partials' sum fed back into every phase one sample late, 1.2 FB / 128 of BD's MFB scale over four. Per sample:
//   fed = TRUNC(fbk * prev) << 2; for k: m = sin(mph_k); mph_k += minc_k; mv = TRUNC(m * idx) << 2 (fbk and idx at a
//   quarter, so a move past half a turn wraps: TRUNC of an overflow is 0xFFFFFFFF); s = sin(ph_k + fed + mv);
//   ph_k += inc_k; sum = sum + s.  prev = sum.
// Then a pass: x = sum * env; env = env * dec; two one-pole high-passes (_md_cy_hpf) in cascade; a soft top (0.15).
// Knobs: PTCH DEC FB HPF MOD MFRQ MDEC -.
_my_render:
    I3 = R4;
    I2 = R8;
    I1 = R12;
    R0 = DM(DK_IN_W_OUT, I2);
    I0 = R0;
    F13 = DM(18, I3);                     // env
    R0 = 0x34800000;
    COMP(F13, F0);
    IF LT JUMP _md_rest;
    // the block's increments
    MD_KNOB(F5, _md_hh_ptch, 0);
    R0 = DM(DK_IN_W_PITCH, I2);
    R2 = -8;
    R1 = LSHIFT R0 BY R2;
    R2 = 12;
    R1 = R1 - R2;
    R2 = 0;
    R1 = MAX(R1, R2);
    R2 = 96;
    R1 = MIN(R1, R2);
    R1 = LSHIFT R1 BY 2;
    R2 = _md_semis;
    R1 = R1 + R2;
    I5 = R1;
    F3 = DM(0, I5);
    F5 = F5 * F3;
    R0 = 0x4f800000;
    F5 = F5 * F0;                         // base, 2^32-turn units a sample
    R0 = DM(5, I1);                       // MFRQ
    F10 = FLOAT R0;
    R0 = 0x39800000;                      // 1 / 4096: MFRQ / 16 a word unit
    F10 = F10 * F0;
    R0 = 0x3f000000;
    F10 = F10 + F0;                       // r = MFRQ / 16 + 0.5
    R15 = 0x4effffff;                     // 2147483520.0
    MY_INC(0, 0x3f800000);
    MY_INC(1, 0x3fb47ae1);
    MY_INC(2, 0x3fe66666);
    MY_INC(3, 0x402ccccd);
    // the index: (A + B MOD) * depth; depth = depth * _md_cy_mdec
    R0 = DM(4, I1);
    F9 = FLOAT R0;
    R0 = 0x4839d118;
    F9 = F9 * F0;
    R0 = 0x4de42a1e;
    F9 = F9 + F0;
    F7 = DM(16, I3);                      // depth (not F1: MD_KNOB uses R0..R2)
    F9 = F9 * F7;
    MD_KNOB(F5, _md_cy_mdec, 6);
    F7 = F7 * F5;
    DM(16, I3) = F7;
    R0 = 0x3e800000;
    F9 = F9 * F0;                         // a quarter: TRUNC's result is shifted back up, so a move past half a turn wraps
    R0 = DM(2, I1);                       // FB
    F10 = FLOAT R0;
    R0 = 0x4599999a;                      // 1.2 / 128 / 256 * 2^31 / 4, a quarter again (shifted back after TRUNC)
    F10 = F10 * F0;                       // fbk
    F12 = DM(17, I3);                     // prev
    I4 = _md_k;
    R14 = 0x3e800000;
    LCNTR = DK_BLOCK, DO _my_end UNTIL LCE;
        F0 = F10 * F12;
        R11 = TRUNC F0;
        R11 = LSHIFT R11 BY 2;            // fed
        R8 = 0;                           // the sum: 0, then each partial added
        MY_PARTIAL(0);
        MY_PARTIAL(1);
        MY_PARTIAL(2);
        MY_PARTIAL(3);
        F12 = PASS F8;
_my_end: DM(I0, M6) = F8;
    DM(17, I3) = F12;
    // the level, the high-passes and the soft top
    MD_KNOB(F11, _md_efm_dec, 1);
    MD_KNOB(F10, _md_cy_hpf, 3);
    F13 = DM(18, I3);                     // env
    F4 = DM(19, I3);                      // low1
    F5 = DM(20, I3);                      // low2
    F7 = DM(21, I3);                      // before
    R9 = 0x3e19999a;                      // 0.15
    R0 = DM(DK_IN_W_OUT, I2);
    I1 = R0;
    LCNTR = DK_BLOCK, DO _my_post_end UNTIL LCE;
        F0 = DM(0, I1);
        F0 = F0 * F13;                    // x
        F13 = F13 * F11;
        F1 = F0 - F4;
        F1 = F1 * F10;
        F4 = F4 + F1;                     // low1
        F2 = F0 - F4;
        F2 = F2 - F5;                     // z
        F3 = F2 * F10;
        F5 = F5 + F3;                     // low2
        F3 = F2 - F7;
        F3 = F3 * F9;
        F3 = F2 - F3;                     // soft
        F7 = PASS F2;
_my_post_end: DM(I1, M6) = F3;
    DM(18, I3) = F13;
    DM(19, I3) = F4;
    DM(20, I3) = F5;
    DM(21, I3) = F7;
    R0 = DK_OK;
    JUMP (M13, I13);

// ---- the shared loop ----
_md_efm_run:
    CALL _md_efm_loop;
_md_efm_post:
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
    // the clap train, when the machine has one (EFM-CP)
    R3 = DM(26, I3);
    R3 = PASS R3;
    IF EQ JUMP _md_no_claps;
    MD_KNOB(F13, _md_cp_crate, 3);        // (I1 still holds the parameter words: CP has no noise pass)        // the claps' fall a sample
    MD_KNOB(F11, _md_efm_dec, 1);         // the tail's
    MD_KNOB(F4, _md_cp_space, 3);
    R10 = TRUNC F4;                       // the spacing, samples
    R8 = DM(22, I3);                      // left
    R9 = DM(23, I3);                      // until
    F6 = F11;
    R8 = PASS R8;
    IF NE F6 = PASS F13;                  // the rate now: the claps' while boundaries are left
    R7 = 0;                               // no boundary in this block
    F12 = F11;
    R0 = 32;
    COMP(R9, R0);
    IF GE JUMP _md_cp_set;
    R7 = R9 + 1;                          // the boundary at sample `until`
    R0 = R8 - 1;
    IF NE F12 = PASS F13;                 // the rate after it: the claps' if more are left
_md_cp_set:
    R4 = PASS R7;                         // 0: no boundary in this block
    F5 = DM(21, I3);                      // env
    R14 = 0x3f800000;                     // 1.0, a clap's start
    R0 = DM(DK_IN_W_OUT, I2);
    I1 = R0;
    LCNTR = DK_BLOCK, DO _md_cp_end UNTIL LCE;
        R7 = R7 - 1;
        IF EQ F5 = PASS F14, R6 = R12;
        F0 = DM(0, I1);
        F0 = F0 * F5;
        F5 = F5 * F6;
_md_cp_end: DM(I1, M6) = F0;
    DM(21, I3) = F5;
    // the next boundary: after one in this block, a spacing on (none after the tail's start); else 32 samples nearer
    R0 = 32;
    R9 = R9 - R0;
    R4 = PASS R4;
    IF EQ JUMP _md_cp_store;              // no boundary in this block
    R9 = R9 + R10;
    R8 = R8 - 1;
    IF NE JUMP _md_cp_store;
    R9 = 0x40000000;                      // the tail has started: no more boundaries
_md_cp_store:
    DM(22, I3) = R8;
    DM(23, I3) = R9;
_md_no_claps:
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

// _md_efm_loop: one FM pair's block. I3 its state (words 0..13), I0 its output (32 floats); clobbers R0..R15, I0, I4, I5.
_md_efm_loop:
    F13 = DM(5, I3);                      // fbg (every entry's own check may have read it, or not)
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

    F1 = DM(7, I3);                       // ptch8, for the first sample (each sample loads the next's)
    LCNTR = DK_BLOCK, DO _md_efm_end UNTIL LCE;
        // Each memory access rides with an unrelated compute (the same operations, in the same order, as tests/md_ref.py).
        F7 = F1 * F11, F0 = DM(6, I3);    // ptch8 * op1; ptch
        F7 = F7 + F0, F0 = DM(8, I3);     // y1; rdec
        F11 = F11 * F0, R1 = DM(K_MASK, I4);  // op1 = op1 * rdec
        R5 = R8 + R10, R2 = DM(K_M32, I4);
        R5 = R5 + R10;                    // ph1 + m + m
        R0 = R5 AND R1;
        F0 = FLOAT R0 BY R2;              // u
        F1 = ABS F0, F3 = DM(K_A7, I4);
        F1 = F1 - F14;
        F1 = ABS F1;
        F1 = F14 - F1, F4 = DM(K_A5, I4); // w
        F2 = F1 * F1;                     // w2
        F3 = F3 * F2;
        F3 = F3 + F4, F4 = DM(K_A3, I4);
        F3 = F3 * F2;
        F3 = F3 + F4, F4 = DM(K_A1, I4);
        F3 = F3 * F2;
        F3 = F3 + F4, F4 = DM(11, I3);    // step1
        F3 = F3 * F1;
        F6 = F3 COPYSIGN F0;              // s1
        F0 = F4 * F7, F4 = DM(12, I3);    // step1 * y1; fbamt
        F0 = CLIP F0 BY F15;
        R0 = TRUNC F0;
        R8 = R8 + R0;                     // ph1 += inc(step1 * y1)
        F0 = F4 * F6, F4 = DM(9, I3);     // fbamt * s1; mdec
        R10 = TRUNC F0;                   // m
        F5 = F12 * F6;
        F5 = F5 * F7;                     // x = op2 * s1 * y1
        F12 = F12 * F4, R1 = DM(K_MASK, I4);  // op2 = op2 * mdec
        R0 = R9 AND R1, R2 = DM(K_M32, I4);
        F0 = FLOAT R0 BY R2;
        F1 = ABS F0, F3 = DM(K_A7, I4);
        F1 = F1 - F14;
        F1 = ABS F1;
        F1 = F14 - F1, F4 = DM(K_A5, I4);
        F2 = F1 * F1;
        F3 = F3 * F2;
        F3 = F3 + F4, F4 = DM(K_A3, I4);
        F3 = F3 * F2;
        F3 = F3 + F4, F4 = DM(K_A1, I4);
        F3 = F3 * F2;
        F3 = F3 + F4;
        F3 = F3 * F1;
        F6 = F3 COPYSIGN F0, F4 = DM(13, I3);  // s2; modamt
        F0 = F4 * F5, F4 = DM(10, I3);    // modamt * x; dec
        F0 = F0 + F7;
        F0 = CLIP F0 BY F15;
        R0 = TRUNC F0;
        R9 = R9 + R0;                     // ph2 += inc(modamt * x + y1)
        F0 = F13 * F6, F1 = DM(7, I3);    // out = fbg * s2; the next sample's ptch8
_md_efm_end: F13 = F13 * F4, DM(I0, M6) = F0;   // fbg = fbg * dec

    DM(0, I3) = R8;
    DM(1, I3) = R9;
    DM(2, I3) = R10;
    DM(3, I3) = F11;
    DM(4, I3) = F12;
    DM(5, I3) = F13;
    RTS;

// _md_efm_loop_cfb: _md_efm_loop with the carrier fed back too (EFM-CB): its phase ph2 + m2 + m2.
_md_efm_loop_cfb:
    F13 = DM(5, I3);                      // fbg (every entry's own check may have read it, or not)
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

    F1 = DM(7, I3);                       // ptch8, for the first sample (each sample loads the next's)
    LCNTR = DK_BLOCK, DO _md_cfb_end UNTIL LCE;
        // Each memory access rides with an unrelated compute (the same operations, in the same order, as tests/md_ref.py).
        F7 = F1 * F11, F0 = DM(6, I3);    // ptch8 * op1; ptch
        F7 = F7 + F0, F0 = DM(8, I3);     // y1; rdec
        F11 = F11 * F0, R1 = DM(K_MASK, I4);  // op1 = op1 * rdec
        R5 = R8 + R10, R2 = DM(K_M32, I4);
        R5 = R5 + R10;                    // ph1 + m + m
        R0 = R5 AND R1;
        F0 = FLOAT R0 BY R2;              // u
        F1 = ABS F0, F3 = DM(K_A7, I4);
        F1 = F1 - F14;
        F1 = ABS F1;
        F1 = F14 - F1, F4 = DM(K_A5, I4); // w
        F2 = F1 * F1;                     // w2
        F3 = F3 * F2;
        F3 = F3 + F4, F4 = DM(K_A3, I4);
        F3 = F3 * F2;
        F3 = F3 + F4, F4 = DM(K_A1, I4);
        F3 = F3 * F2;
        F3 = F3 + F4, F4 = DM(11, I3);    // step1
        F3 = F3 * F1;
        F6 = F3 COPYSIGN F0;              // s1
        F0 = F4 * F7, F4 = DM(12, I3);    // step1 * y1; fbamt
        F0 = CLIP F0 BY F15;
        R0 = TRUNC F0;
        R8 = R8 + R0;                     // ph1 += inc(step1 * y1)
        F0 = F4 * F6, F4 = DM(9, I3);     // fbamt * s1; mdec
        R10 = TRUNC F0;                   // m
        F5 = F12 * F6;
        F5 = F5 * F7;                     // x = op2 * s1 * y1
        F12 = F12 * F4, R1 = DM(16, I3);      // op2 = op2 * mdec; m2
        R0 = R9 + R1, R2 = DM(K_M32, I4);
        R0 = R0 + R1, R1 = DM(K_MASK, I4);
        R0 = R0 AND R1;                   // ph2 + m2 + m2, the sine's index
        F0 = FLOAT R0 BY R2;
        F1 = ABS F0, F3 = DM(K_A7, I4);
        F1 = F1 - F14;
        F1 = ABS F1;
        F1 = F14 - F1, F4 = DM(K_A5, I4);
        F2 = F1 * F1;
        F3 = F3 * F2;
        F3 = F3 + F4, F4 = DM(K_A3, I4);
        F3 = F3 * F2;
        F3 = F3 + F4, F4 = DM(K_A1, I4);
        F3 = F3 * F2;
        F3 = F3 + F4;
        F3 = F3 * F1;
        F6 = F3 COPYSIGN F0, F4 = DM(17, I3);  // s2; cfb
        F0 = F4 * F6, F4 = DM(13, I3);    // cfb * s2; modamt
        R0 = TRUNC F0;
        DM(16, I3) = R0;                  // m2 = trunc(cfb * s2)
        F0 = F4 * F5, F4 = DM(10, I3);    // modamt * x; dec
        F0 = F0 + F7;
        F0 = CLIP F0 BY F15;
        R0 = TRUNC F0;
        R9 = R9 + R0;                     // ph2 += inc(modamt * x + y1)
        F0 = F13 * F6, F1 = DM(7, I3);    // out = fbg * s2; the next sample's ptch8
_md_cfb_end: F13 = F13 * F4, DM(I0, M6) = F0;   // fbg = fbg * dec

    DM(0, I3) = R8;
    DM(1, I3) = R9;
    DM(2, I3) = R10;
    DM(3, I3) = F11;
    DM(4, I3) = F12;
    DM(5, I3) = F13;
    RTS;

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

// EFM-CP's note_on: the tone from phase 0 at BD's level, no ramp; CLPS >> 3 claps: left = that many boundaries, the first a
// spacing away (none: the tail now); the train's gain 1.
_mc_note_on:
    I3 = R4;
    I1 = R12;
    R0 = 0;
    DM(0, I3) = R0;                       // ph1
    DM(1, I3) = R0;                       // ph2
    DM(2, I3) = R0;                       // m
    DM(3, I3) = R0;                       // op1: no ramp
    DM(15, I3) = R0;                      // low
    R0 = 0x3f800000;
    DM(4, I3) = R0;                       // op2
    DM(21, I3) = R0;                      // env
    R0 = 0x3ea18666;
    DM(5, I3) = R0;                       // fbg, constant
    R0 = DM(2, I1);                       // CLPS
    R2 = -11;
    R8 = LSHIFT R0 BY R2;                 // claps
    DM(22, I3) = R8;
    MD_KNOB(F4, _md_cp_space, 3);
    R9 = TRUNC F4;                        // the first boundary, a spacing away
    R0 = 0x40000000;                      // none (0 claps: the tail from the start)
    R8 = PASS R8;
    IF EQ R9 = PASS R0;
    DM(23, I3) = R9;
    JUMP (M13, I13);

// EFM-RS's note_on: the rim a quarter cycle in (its peak), the snare 0.11 cycle in; no ramps; BD's level for both.
_mr_note_on:
    I3 = R4;
    R0 = MR_PAIR;
    R0 = R4 + R0;
    I5 = R0;
    R0 = 0;
    DM(2, I3) = R0;                       // m
    DM(3, I3) = R0;                       // op1
    DM(15, I3) = R0;                      // low
    DM(2, I5) = R0;
    DM(3, I5) = R0;
    R0 = 0x3f800000;
    DM(4, I3) = R0;                       // op2
    DM(4, I5) = R0;
    R0 = 0x3ea18666;
    DM(5, I3) = R0;                       // fbg
    DM(5, I5) = R0;
    R0 = 0x40000000;
    DM(0, I3) = R0;                       // the rim's phases
    DM(1, I3) = R0;
    R0 = 472446403;
    DM(0, I5) = R0;                       // the snare's
    DM(1, I5) = R0;
    JUMP (M13, I13);

// EFM-CB's note_on: both tones from phase 0 at 0.177, no ramps, no feedback yet; the snap's level 1.
_mb_note_on:
    I3 = R4;
    R0 = MR_PAIR;
    R0 = R4 + R0;
    I5 = R0;
    R0 = 0;
    DM(0, I3) = R0;
    DM(1, I3) = R0;
    DM(2, I3) = R0;
    DM(3, I3) = R0;
    DM(15, I3) = R0;
    DM(16, I3) = R0;
    DM(0, I5) = R0;
    DM(1, I5) = R0;
    DM(2, I5) = R0;
    DM(3, I5) = R0;
    DM(16, I5) = R0;
    R0 = 0x3f800000;
    DM(4, I3) = R0;
    DM(4, I5) = R0;
    DM(27, I3) = R0;                      // the snap's level
    R0 = 0x3e353f7d;                      // 0.177
    DM(5, I3) = R0;
    DM(5, I5) = R0;
    JUMP (M13, I13);

// EFM-HH's note_on: the pair from phase 0 at BD's level, no ramp, no feedback yet; the tremolo at its peak (g 1, phi 0).
_mh_note_on:
    I3 = R4;
    R0 = 0;
    DM(0, I3) = R0;
    DM(1, I3) = R0;
    DM(2, I3) = R0;
    DM(3, I3) = R0;
    DM(16, I3) = R0;                      // m2
    DM(20, I3) = R0;                      // xprev
    DM(21, I3) = R0;                      // phi
    R0 = 0x3f800000;
    DM(4, I3) = R0;
    DM(22, I3) = R0;                      // g
    R0 = 0x3ea18666;
    DM(5, I3) = R0;
    JUMP (M13, I13);

// EFM-CY's note_on: every phase 0, the index's depth 1, the level 0.0785, the filters at rest.
_my_note_on:
    I3 = R4;
    R0 = 0;
    DM(0, I3) = R0;
    DM(1, I3) = R0;
    DM(2, I3) = R0;
    DM(3, I3) = R0;
    DM(4, I3) = R0;
    DM(5, I3) = R0;
    DM(6, I3) = R0;
    DM(7, I3) = R0;
    DM(17, I3) = R0;
    DM(19, I3) = R0;
    DM(20, I3) = R0;
    DM(21, I3) = R0;
    R0 = 0x3f800000;
    DM(16, I3) = R0;
    R0 = 0x3da0c49c;                      // 0.0785
    DM(18, I3) = R0;
    JUMP (M13, I13);

.SECTION/DM seg_dmda;
// dk_machine_desc (8 words, runtime 0.8): magic, contract, n_params, voices, state_bytes, state_clear_bytes, max_call_depth,
// stack_bytes. The DSP cost is not in it: module:check measures it.
.GLOBAL _md_desc;
.VAR _md_desc = DK_MAGIC;
.VAR _md_desc1 = DK_MACHINE_V1;
.VAR _md_desc2 = 8;
.VAR _md_desc3 = DK_MAX_VOICES;
.VAR _md_desc4 = MD_STATE;
.VAR _md_desc5 = MD_CLEAR;
.VAR _md_desc6 = 1;
.VAR _md_desc7 = 0;
.GLOBAL _mx_desc;
.VAR _mx_desc = DK_MAGIC;
.VAR _mx_desc1 = DK_MACHINE_V1;
.VAR _mx_desc2 = 8;
.VAR _mx_desc3 = DK_MAX_VOICES;
.VAR _mx_desc4 = MD_STATE;
.VAR _mx_desc5 = MD_CLEAR;
.VAR _mx_desc6 = 1;
.VAR _mx_desc7 = 0;
.GLOBAL _ms_desc;
.VAR _ms_desc = DK_MAGIC;
.VAR _ms_desc1 = DK_MACHINE_V1;
.VAR _ms_desc2 = 8;
.VAR _ms_desc3 = DK_MAX_VOICES;
.VAR _ms_desc4 = MD_STATE;
.VAR _ms_desc5 = MD_CLEAR;
.VAR _ms_desc6 = 1;
.VAR _ms_desc7 = 0;
.GLOBAL _mc_desc;
.VAR _mc_desc = DK_MAGIC;
.VAR _mc_desc1 = DK_MACHINE_V1;
.VAR _mc_desc2 = 8;
.VAR _mc_desc3 = DK_MAX_VOICES;
.VAR _mc_desc4 = MD_STATE;
.VAR _mc_desc5 = MD_CLEAR;
.VAR _mc_desc6 = 1;
.VAR _mc_desc7 = 0;
.GLOBAL _mr_desc;
.VAR _mr_desc = DK_MAGIC;
.VAR _mr_desc1 = DK_MACHINE_V1;
.VAR _mr_desc2 = 8;
.VAR _mr_desc3 = DK_MAX_VOICES;
.VAR _mr_desc4 = MR_STATE;
.VAR _mr_desc5 = MR_CLEAR;
.VAR _mr_desc6 = 1;
.VAR _mr_desc7 = 0;
.GLOBAL _mb_desc;
.VAR _mb_desc = DK_MAGIC;
.VAR _mb_desc1 = DK_MACHINE_V1;
.VAR _mb_desc2 = 7;
.VAR _mb_desc3 = DK_MAX_VOICES;
.VAR _mb_desc4 = MB_STATE;
.VAR _mb_desc5 = MB_CLEAR;
.VAR _mb_desc6 = 1;
.VAR _mb_desc7 = 0;
.GLOBAL _mh_desc;
.VAR _mh_desc = DK_MAGIC;
.VAR _mh_desc1 = DK_MACHINE_V1;
.VAR _mh_desc2 = 8;
.VAR _mh_desc3 = DK_MAX_VOICES;
.VAR _mh_desc4 = MD_STATE;
.VAR _mh_desc5 = MD_CLEAR;
.VAR _mh_desc6 = 1;
.VAR _mh_desc7 = 0;
.GLOBAL _my_desc;
.VAR _my_desc = DK_MAGIC;
.VAR _my_desc1 = DK_MACHINE_V1;
.VAR _my_desc2 = 7;
.VAR _my_desc3 = DK_MAX_VOICES;
.VAR _my_desc4 = MY_STATE;
.VAR _my_desc5 = MY_CLEAR;
.VAR _my_desc6 = 0;
.VAR _my_desc7 = 0;
