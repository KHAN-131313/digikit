"""khan/md: the knob tables of the machines, as float32 words for tables.inc.

    uv run python modules/machines/md/src/dsp/gen_tables.py

EFM-BD's control curves are Digidrum's (soejrd/digidrum, machines/EFM/BD/efm_bd.c, MIT, used with the
author's permission), which run at the Machinedrum's 44.1 kHz. The Digitone II renders at 48 kHz, so every
phase step is scaled by 44100/48000 and every per-sample decay coefficient c becomes c ** (44100/48000): the
same pitches and the same decay times at 48 kHz.

Each knob table has 129 entries (knob 0..128), so a fractional knob (the 8.8 word) interpolates between k and
k + 1. tests/md_ref.py reads the same values through `tables()`.
"""

from __future__ import annotations

import struct
from pathlib import Path

import numpy as np

R = 44100.0 / 48000.0
OUT = Path(__file__).with_name("tables.inc")


# EFM-SD's HPF: the one-pole coefficient that gives the Machinedrum's tone level at these knobs (MOD 0, PTCH 64)
SD_HPF_KNOBS = [0, 4, 8, 12, 16, 24, 32, 48, 64, 80, 96, 112, 127, 128]
SD_HPF = [0, 0.01279, 0.02735, 0.0409, 0.0547, 0.0818, 0.10697, 0.15643, 0.20456, 0.25015, 0.29253, 0.33452, 0.37409, 0.37409]


# EFM-CP's clap spacing at 48 kHz, samples, at these CDEC knobs
CP_SPACE_KNOBS = [0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120, 127, 128]
CP_SPACE = [55, 61, 77, 99, 124, 157, 199, 251, 317, 401, 507, 640, 809, 1022, 1291, 1631, 1979, 1979]


def cp_space(k: np.ndarray) -> np.ndarray:
    return np.exp(np.interp(k, CP_SPACE_KNOBS, np.log(CP_SPACE)))


# EFM-HH's tremolo rates in Hz at these TFRQ knobs (OP-XY-MNMD's, MIT: Q32 turns at 44.1 kHz; checked against the original)
HH_TREM_KNOBS = [0, 16, 32, 48, 64, 80, 96, 112, 127, 128]
HH_TREM_HZ = [r / 2.0**32 * 44100.0 for r in (92522, 155826, 262957, 438262, 749915, 1246612, 2093918, 3535313, 5746101, 5746101)]


KN9 = [0, 16, 32, 48, 64, 80, 96, 112, 127]
CY_MDEC = [2136736994, 2140558027, 2143155135, 2144725657, 2145752243, 2146408983, 2146820557, 2147056726, 2147200327]
CY_HPF = [0, 125627793, 223123551, 320834057, 417470821, 515181327, 611603343, 708240107, 799508162]


def cy_hpf(k: np.ndarray) -> np.ndarray:
    c = np.interp(k, KN9, np.array(CY_HPF) / 2.0**31)
    fc = -np.log(1 - c) * 44100.0 / (2 * np.pi)
    return 1 - np.exp(-2 * np.pi * fc / 48000.0)


def tables() -> dict[str, np.ndarray]:
    k = np.arange(129, dtype=np.float64)
    return {
        # PTCH: the base pitch step in turns a sample at note 60
        "_md_efm_ptch": (0.000581 * 2.0 ** (k / 32.0) * R).astype(np.float32),
        # DEC, RDEC, MDEC: per-sample decay of the output, the pitch ramp and the modulation
        "_md_efm_dec": ((1.0 - 0.009469 * 2.0 ** (-k / 13.5)) ** R).astype(np.float32),
        "_md_efm_rdec": ((1.0 - 0.009468 * 2.0 ** (-k / 12.6)) ** R).astype(np.float32),
        "_md_efm_mdec": ((1.0 - 0.009474 * 2.0 ** (-k / 11.52)) ** R).astype(np.float32),
        # EFM-XT's deviation scale: (3/8) / 16 of BD's pitch at PTCH over XT's (BD's table at 24 + PTCH / 2)
        "_md_xt_dev": (0.375 / 16 * 2.0 ** (k / 64.0 - 0.75)).astype(np.float32),
        # EFM-SD (research/fit_efm_sd.py): PTCH on BD's pitch curve at 72 + 5 PTCH / 8; NDEC on BD's decay curve at
        # 1.6 + 0.72 NDEC; HPF's one-pole coefficient, measured at 13 knobs and interpolated (0: off)
        "_md_sd_ptch": (0.000581 * 2.0 ** ((72 + 5 * k / 8) / 32.0) * R).astype(np.float32),
        "_md_sd_ndec": ((1.0 - 0.009469 * 2.0 ** (-(1.6 + 0.72 * k) / 13.5)) ** R).astype(np.float32),
        "_md_sd_hpf": np.interp(k, SD_HPF_KNOBS, SD_HPF).astype(np.float32),
        # EFM-CP (research/fit_efm_cp.py): PTCH on BD's pitch curve at 72 + 11 PTCH / 8; CDEC's clap spacing in samples
        # (measured at 17 knobs, interpolated in log) and the claps' fall a sample, 22 dB a spacing
        "_md_cp_ptch": (0.000581 * 2.0 ** ((72 + 11 * k / 8) / 32.0) * R).astype(np.float32),
        "_md_cp_space": cp_space(k).astype(np.float32),
        "_md_cp_crate": (10.0 ** (-22.0 / 20.0 / cp_space(k))).astype(np.float32),
        # EFM-RS (research/fit_efm_rs.py): the rim's PTCH on BD's pitch curve at 104 + PTCH (the snare's is EFM-SD's)
        "_md_rs_ptch": (0.000581 * 2.0 ** ((104 + k) / 32.0) * R).astype(np.float32),
        # EFM-CB (research/fit_efm_cb.py): the low tone's PTCH on BD's pitch curve at 88 + 5 PTCH / 8
        "_md_cb_ptch": (0.000581 * 2.0 ** ((88 + 5 * k / 8) / 32.0) * R).astype(np.float32),
        # EFM-HH (research/fit_efm_hh.py): PTCH on BD's pitch curve at 104 + 5 PTCH / 8; TFRQ's tremolo rate, 2^32-turn units
        # a sample at 48 kHz (OP-XY-MNMD's rates, 0.95 Hz to 59 Hz, interpolated in log)
        "_md_hh_ptch": (0.000581 * 2.0 ** ((104 + 5 * k / 8) / 32.0) * R).astype(np.float32),
        "_md_hh_trem": (np.exp(np.interp(k, HH_TREM_KNOBS, np.log(HH_TREM_HZ))) / 48000.0 * 2.0**32).astype(np.float32),
        # EFM-CY (research/fit_efm_cy.py): MDEC's index fall a block (48 kHz) and HPF's one-pole coefficient, from OP-XY-MNMD's
        # fit (MIT): its per-block steps at twice their time (fitted here), its coefficients at the same cutoffs
        "_md_cy_mdec": (np.interp(k, KN9, np.array(CY_MDEC) / 2.0**31) ** (0.5 * 44100.0 / 48000.0)).astype(np.float32),
        "_md_cy_hpf": cy_hpf(k).astype(np.float32),
        # the note's transposition, 2^(s/12) for s = -48..+48
        "_md_semis": (2.0 ** (np.arange(-48, 49) / 12.0)).astype(np.float32),
    }


# the loop's constants: the sine polynomial a1 a3 a5 a7 (float32 bit patterns), the 15-bit index mask, FLOAT's scale -32
MD_K = np.array([0x40C90FCC, 0xC2255B43, 0x42A2D193, 0xC28F55A1, 0xFFFE0000, 0xFFFFFFE0], dtype=np.uint32)


def pkhex(name: str, words: np.ndarray) -> str:
    if words.dtype == np.uint32:
        raw = b"".join(struct.pack("<I", int(w)) for w in words)
    else:
        raw = b"".join(struct.pack("<f", float(w)) for w in words)
    return f".PKHEX {name}, {raw.hex()};\n"


def main() -> None:
    text = "// khan/md: knob tables. Generated by gen_tables.py; do not edit.\n"
    text += "// EFM-BD's curves are Digidrum's (MIT), rescaled from 44.1 to 48 kHz.\n"
    for name, words in {**tables(), "_md_k": MD_K}.items():
        text += f"// {name}: {len(words)} float32 words\n" + pkhex(name, words)
    OUT.write_text(text)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
