// khan/md: Machinedrum-style machines (<dk/machine/machine.h>), one body for both devices.
// This first version holds one machine, EFM-BD: two sine operators with feedback FM.
//
// Based on Digidrum's EFM-BD (soejrd/digidrum, machines/EFM/BD/efm_bd.c, MIT, used with the author's permission),
// rewritten for the SHARC+: float32, phases as 32-bit integers (2^32 a turn, so they wrap for free), the
// Machinedrum's 15-bit sine index kept (it shapes the feedback's timbre), a branch-free sine fold, a degree-7 odd
// polynomial (max error 2.2e-6), knob curves as tables (tables.inc, gen_tables.py) and 48 kHz.
//
// Knobs (words 0..7, the Machinedrum's order): PTCH DEC RAMP RDEC MOD MFRQ MDEC MFB.
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
// A voice whose level fbg is under 2^-22 has died away: it writes zeros and returns DK_DONE (it costs nothing more).
//
// Registers: I3 state, I2 voice input, I1 parameter words, I0 output, I4 the constants, I5 a table; in the loop
// R8 ph1  R9 ph2  R10 m  F11 op1  F12 op2  F13 fbg  F14 0.25  F15 clip; F0..F7 scratch (F7 y1, F5 x, F6 the sine).

#include "dk_machine.inc"
#include "tables.inc"

#define MD_STATE 56
#define MD_CLEAR 24

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
.EXTERN _md_efm_ptch;
.EXTERN _md_efm_dec;
.EXTERN _md_efm_rdec;
.EXTERN _md_efm_mdec;
.EXTERN _md_semis;
.EXTERN _md_k;

// MD_KNOB(OUT, TABLE, WORD): OUT = T[k] + (T[k + 1] - T[k]) * f for the 8.8 word k.f of parameter WORD.
// The adapter clamps the word to 0 .. 0x7f00, so k <= 127 and k + 1 <= 128 are inside the 129 entries.
// Addresses are bytes: the entry's address is TABLE + 4 k, made in the ALU (a register modifier does not index words here).
// Clobbers R0 R1 R2 F3 F4 I5.
#define MD_KNOB(OUT, TABLE, WORD) \
    R0 = DM(WORD, I1); \
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

_md_render:
    I3 = R4;
    I2 = R8;
    I1 = R12;
    R0 = DM(DK_IN_W_OUT, I2);
    I0 = R0;

    // a voice that has died away (or whose level is not a number) ends
    F13 = DM(5, I3);
    R0 = 0x34800000;                      // 2^-22: 2^-21 of the start level 0.5
    COMP(F13, F0);
    IF LT JUMP _md_rest;

    // ---- the block's coefficients (tests/md_ref.py: coefficients) ----
    MD_KNOB(F5, _md_efm_ptch, 0);         // PTCH, turns a sample at note 60
    R0 = DM(DK_IN_W_PITCH, I2);
    R2 = -8;
    R1 = LSHIFT R0 BY R2;                 // the note
    R2 = 12;
    R1 = R1 - R2;                         // note - 60 + 48, the semitone table's index
    R2 = 0;
    R1 = MAX(R1, R2);
    R2 = 96;
    R1 = MIN(R1, R2);
    R1 = LSHIFT R1 BY 2;                  // bytes
    R2 = _md_semis;
    R1 = R1 + R2;
    I5 = R1;
    F3 = DM(0, I5);
    F5 = F5 * F3;
    R0 = 0x4f800000;                      // 2^32: phase units
    F5 = F5 * F0;
    DM(6, I3) = F5;                       // ptch
    R0 = 0x41000000;                      // 8.0
    F6 = F0 * F5;
    DM(7, I3) = F6;                       // ptch8 = 8 ptch
    MD_KNOB(F5, _md_efm_dec, 1);
    DM(10, I3) = F5;                      // dec
    MD_KNOB(F5, _md_efm_rdec, 3);
    DM(8, I3) = F5;                       // rdec
    MD_KNOB(F5, _md_efm_mdec, 6);
    DM(9, I3) = F5;                       // mdec
    R0 = DM(5, I1);                       // MFRQ, at least 1
    F5 = FLOAT R0;
    R0 = 0x3b800000;                      // 1/256
    F5 = F5 * F0;
    R0 = 0x3f800000;                      // 1.0
    F5 = MAX(F5, F0);
    R0 = 0x3c000000;                      // 1/128
    F5 = F5 * F0;
    R0 = 0x41000000;                      // 8.0
    F5 = F0 * F5;
    DM(11, I3) = F5;                      // step1 = 8 max(MFRQ, 1) / 128
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
