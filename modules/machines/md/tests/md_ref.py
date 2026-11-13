"""khan/md's EFM-BD as a float32 model: src/dsp/md.s operation for operation (each float operation rounds to float32 the way the
SHARC+ does, integers wrap at 32 bits). tests/test_md.py holds the routine to it bit for bit."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import numpy as np

f32 = np.float32
_spec = importlib.util.spec_from_file_location(
    "md_gen_tables", Path(__file__).parents[1] / "src/dsp/gen_tables.py"
)
assert _spec and _spec.loader
gen_tables = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gen_tables)
T = gen_tables.tables()
K = gen_tables.MD_K
A1, A3, A5, A7 = (K[:4].view(np.float32)).tolist()
A1, A3, A5, A7 = f32(A1), f32(A3), f32(A5), f32(A7)
MASK = int(K[4])
QUARTER = f32(0.25)
CLIPV = f32(2147483520.0)
REST = f32(2.0**-22)
TINY = np.uint32(0x0DA24260).view(np.float32)
BLOCK = 32


def i32(x: int) -> int:
    x &= 0xFFFFFFFF
    return x - (1 << 32) if x & 0x80000000 else x


def trunc(x: np.float32) -> int:
    """TRUNC: toward zero, saturating at the int32 range."""
    v = float(x)
    if v >= 2147483647.0:
        return 2147483647
    if v <= -2147483648.0:
        return -2147483648
    return int(v)


def clip(x: np.float32, c: np.float32) -> np.float32:
    return f32(np.copysign(c, x)) if abs(x) > c else x


def sine(p: int) -> np.float32:
    u = f32(i32(p & MASK)) * f32(2.0**-32)  # exact: 15 significant bits
    w = QUARTER - abs(abs(u) - QUARTER)
    w2 = w * w
    s = A7 * w2
    s = s + A5
    s = s * w2
    s = s + A3
    s = s * w2
    s = s + A1
    s = s * w
    return f32(np.copysign(s, u))


def knob(table: str, word: int) -> np.float32:
    t = T[table]
    k, fr = word >> 8, f32(word & 255) * f32(1 / 256)
    return t[k] + (t[k + 1] - t[k]) * fr


class EfmBd:
    """One voice. `params` are the eight 8.8 words PTCH DEC RAMP RDEC MOD MFRQ MDEC MFB; `pitch` the voice's 8.8 note word."""

    def __init__(self) -> None:
        self.ph1 = self.ph2 = self.m = 0
        self.op1 = self.op2 = self.fbg = f32(0)

    def note_on(self, params: list[int]) -> None:
        self.op1 = (f32(params[2]) * f32(1 / 256) - f32(16)) * f32(1 / 128)
        self.op2 = f32(1)
        self.fbg = np.uint32(0x3EA18666).view(np.float32)
        self.ph1 = self.ph2 = 524288000
        self.m = 0

    def ptch_word(self, params: list[int]) -> int:
        return params[0]

    def feedback(self, params: list[int]) -> np.float32:
        return f32(params[7]) * f32(1 / 256) * f32(1 / 128) * f32(2.0**31)

    def deviation(self, params: list[int]) -> np.float32:
        return f32(8) * (f32(params[4]) * f32(1 / 256) * f32(1 / 128))

    hpc = f32(0)

    def block(self, pitch: int, params: list[int]) -> tuple[np.ndarray, bool]:
        """One block: the samples and whether the voice is done (DK_DONE)."""
        if not self.fbg >= REST:  # NaN rests too
            return np.zeros(BLOCK, np.float32), True
        ptch = knob("_md_efm_ptch", self.ptch_word(params))
        s = min(max((pitch >> 8) - 12, 0), 96)
        ptch = ptch * T["_md_semis"][s]
        ptch = ptch * f32(2.0**32)
        ptch8 = f32(8) * ptch
        dec = knob("_md_efm_dec", params[1])
        rdec = knob("_md_efm_rdec", params[3])
        mdec = knob("_md_efm_mdec", params[6])
        step1 = f32(params[5]) * f32(1 / 256)
        step1 = max(step1, f32(1)) * f32(1 / 128)
        step1 = f32(8) * step1
        fbamt = self.feedback(params)
        modamt = self.deviation(params)
        op1, op2, fbg = self.op1, self.op2, self.fbg
        if abs(op1) < TINY:
            op1 = f32(0)
        if abs(op2) < TINY:
            op2 = f32(0)
        ph1, ph2, m = self.ph1, self.ph2, self.m
        out = np.empty(BLOCK, np.float32)
        for n in range(BLOCK):
            y1 = ptch8 * op1
            y1 = y1 + ptch
            op1 = op1 * rdec
            s1 = sine(i32(ph1 + m + m))
            ph1 = i32(ph1 + trunc(clip(step1 * y1, CLIPV)))
            m = trunc(fbamt * s1)
            x = op2 * s1
            x = x * y1
            op2 = op2 * mdec
            s2 = sine(ph2)
            v = modamt * x
            v = v + y1
            ph2 = i32(ph2 + trunc(clip(v, CLIPV)))
            out[n] = fbg * s2
            fbg = fbg * dec
        self.ph1, self.ph2, self.m = ph1, ph2, m
        self.op1, self.op2, self.fbg = op1, op2, fbg
        if self.hpc:
            low = self.low
            for n in range(BLOCK):
                d = out[n] - low
                d = d * self.hpc
                low = low + d
                out[n] = out[n] - low
            self.low = low
        return out, False

    def render(self, pitch: int, params: list[int], blocks: int) -> np.ndarray:
        return np.concatenate([self.block(pitch, params)[0] for _ in range(blocks)])


class EfmXt(EfmBd):
    """EFM-XT: BD's voice with PTCH at 24 + PTCH / 2 on BD's table, feedback 2^30, the deviation from _md_xt_dev, a one-pole
    high-pass after the loop, the start level MX_LEVEL and CLIC's carrier start (src/dsp/md.s)."""

    hpc = np.uint32(0x3C84F35C).view(np.float32)

    def __init__(self) -> None:
        super().__init__()
        self.low = f32(0)

    def note_on(self, params: list[int]) -> None:
        super().note_on(params)
        self.fbg = np.uint32(0x3E8784FC).view(np.float32)
        self.ph2 = trunc(f32(params[7]) * np.uint32(0x46C28F5C).view(np.float32))
        self.low = f32(0)

    def ptch_word(self, params: list[int]) -> int:
        return 0x1800 + (params[0] >> 1)

    def feedback(self, params: list[int]) -> np.float32:
        return f32(2.0**30)

    def deviation(self, params: list[int]) -> np.float32:
        return f32(params[4]) * f32(1 / 256) * knob("_md_xt_dev", params[0])
