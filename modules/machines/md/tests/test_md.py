"""khan/md on the concrete SHARC+ core through core/dsp-voice (DN2), against the float32 model (tests/md_ref.py EfmBd), bit for bit.
The rig draws hostile context registers for every call; Rig.run checks that they come back."""

import dataclasses

import numpy as np
import pytest
from support.machine_rig import MachineRig

import md_ref
from tools.patchkit import pk_conform, pk_toolchains

pytestmark = pytest.mark.skipif(
    pk_toolchains.selache_dir() is None,
    reason="selache not built (tools/patchkit/pk_toolchains.py selache)",
)

IDS = ("md_ptch", "md_dec", "md_ramp", "md_rdec", "md_mod", "md_mfrq", "md_mdec", "md_mfb")
DEFAULTS = (36, 76, 64, 55, 64, 64, 32, 127)


def words(knobs) -> list[int]:
    return [round(k * 256) for k in knobs]


SYMBOLS = {
    "xt": ("_mx_render", "_mx_note_on", "_mx_desc"),
    "sd": ("_ms_render", "_ms_note_on", "_ms_desc"),
}
MODELS = {"bd": md_ref.EfmBd, "xt": md_ref.EfmXt, "sd": md_ref.EfmSd}


def machine_spec(machine: str):
    """A machine of md.s by its symbols: pk_conform.spec reads only a module's first machine (and khan/md declares only BD
    and XT: 16 parameters a module), so the others are BD's spec with their symbols; the knobs sit in the same positions."""
    entry, note_on, desc = SYMBOLS[machine]
    base = pk_conform.spec("khan/md", "dn2")
    return dataclasses.replace(base, entry=entry, note_on=note_on, desc=desc)


def xt_spec():
    """EFM-XT, the module's second machine: pk_conform.spec reads only the first, so XT is BD's spec with XT's symbols
    (both machines' knobs sit in the same positions)."""
    base = pk_conform.spec("khan/md", "dn2")
    return dataclasses.replace(base, entry="_mx_render", note_on="_mx_note_on", desc="_mx_desc")


class Rig(MachineRig):
    def __init__(self, machine: str = "bd") -> None:
        super().__init__("khan/md", "dn2", spec=None if machine == "bd" else machine_spec(machine))

    def play(self, note: float, vel: int, knobs) -> None:
        self.set_note(note, vel)
        self.knobs(knobs)
        self.trigger()

    def knobs(self, knobs) -> None:
        self.set_params(dict(zip(IDS, words(knobs), strict=True)))

    def run(self, n: int):
        ys, counts = [], []
        for _ in range(n):
            b = self.block()
            assert b.returned, b.halt
            assert not b.context_bad, b.context_bad
            assert b.faults == 0
            ys.append(np.array(b.samples, dtype=np.float32))
            counts.append(b.instructions)
        return np.concatenate(ys), counts


def played(knobs, note: int = 60, vel: int = 100, blocks: int = 60, machine: str = "bd"):
    """The rig's blocks after the trigger block (the DN2 trigger bit starts the note in the next block) and the model's."""
    rig = Rig(machine)
    rig.play(note, vel, knobs)
    y, counts = rig.run(blocks + 1)
    m = MODELS[machine]()
    m.note_on(words(knobs))
    return y[32:], m.render(note << 8, words(knobs), blocks), counts[1:]


CASES = {
    "defaults": (DEFAULTS, 60),
    "low-long": ((10, 120, 100, 90, 30, 20, 80, 60), 36),
    "high-short": ((110, 10, 0, 5, 127, 127, 0, 0), 84),
    "fractional": ((36.5, 76.25, 63.75, 55.125, 64.5, 64.75, 32.5, 126.5), 60),
    "all-max": ((127,) * 8, 96),
    "all-min": ((0,) * 8, 24),
    "out-of-table-notes": (DEFAULTS, 120),
}


XT_DEFAULTS = (64, 64, 38, 87, 48, 84, 55, 127)
XT_CASES = {
    "xt-defaults": (XT_DEFAULTS, 60),
    "xt-no-click-low": ((0, 100, 16, 64, 30, 16, 80, 0), 36),
    "xt-high-fractional": ((120.5, 20.25, 90, 10, 127, 127, 3.5, 64.75), 84),
    "xt-all-max": ((127,) * 8, 96),
    "xt-all-min": ((0,) * 8, 24),
}


SD_DEFAULTS = (64, 55, 64, 64, 64, 32, 44, 16)
SD_CASES = {
    "sd-defaults": (SD_DEFAULTS, 60),
    "sd-tone-only": ((30, 90, 0, 64, 40, 64, 64, 0), 48),
    "sd-noise-only": ((64, 0, 127, 100, 0, 64, 64, 0), 60),
    "sd-hpf-fractional": ((100.5, 40.25, 80.75, 30.5, 127, 127, 10.5, 127), 84),
    "sd-all-min": ((0,) * 8, 24),
}
ALL_CASES = {**{k: ("bd", *v) for k, v in CASES.items()}, **{k: ("xt", *v) for k, v in XT_CASES.items()},
             **{k: ("sd", *v) for k, v in SD_CASES.items()}}


@pytest.mark.parametrize("name", ALL_CASES)
def test_the_routine_matches_the_model(name):
    machine, knobs, note = ALL_CASES[name]
    got, want, _ = played(knobs, note, machine=machine)
    assert np.max(np.abs(want)) > (0.05 if machine == "bd" else 5e-4)  # high-passes take the lowest notes away
    np.testing.assert_array_equal(got, want)


def test_a_voice_dies_away_and_rests():
    """Short decay: the level falls under 2^-22 and the routine writes zeros (DK_DONE) at the model's block, cheaply."""
    knobs = (36, 0, 64, 55, 64, 64, 32, 127)
    got, want, counts = played(knobs, blocks=200)
    np.testing.assert_array_equal(got, want)
    quiet = [k for k in range(200) if not np.any(want[32 * k : 32 * k + 32])]
    assert quiet, "the voice never rested"
    assert max(counts[quiet[0] + 1 :] or [0]) < 600, counts[quiet[0] :]


def test_knobs_flipping_every_block_stay_finite_and_bounded():
    rig, m = Rig(), md_ref.EfmBd()
    lo, hi = (0,) * 8, (127,) * 8
    rig.play(60, 100, hi)
    rig.run(1)
    for k in range(80):
        knobs = hi if k % 2 else lo
        rig.knobs(knobs)
        if k == 0:  # the note starts in this block, with this block's knobs
            m.note_on(words(knobs))
        y, _ = rig.run(1)
        z = m.block(60 << 8, words(knobs))[0]
        np.testing.assert_array_equal(y, z)
        assert np.all(np.abs(y) <= 1.0)


def test_cost_per_block():
    """The ceilings the descriptions declare (BD 4000, XT 4400 a block, the adapter included) hold for every knob case."""
    for knobs, note in CASES.values():
        _, _, counts = played(knobs, note, blocks=4)
        assert max(counts) < 4000, counts
    for knobs, note in XT_CASES.values():
        _, _, counts = played(knobs, note, blocks=4, machine="xt")
        assert max(counts) < 4400, counts
    for knobs, note in SD_CASES.values():
        _, _, counts = played(knobs, note, blocks=4, machine="sd")
        assert max(counts) < 5000, counts


# ---- likeness to the Machinedrum: figures measured on the original (OS 1.63 DSP2, rendered locally; numbers only) ----
# Each is a knob sweep that isolates one control, as OP-XY-MNMD's reference/fit_efm_bd.py lays them out.


def model_audio(knobs, seconds: float) -> np.ndarray:
    m = md_ref.EfmBd()
    m.note_on(words(knobs))
    return m.render(60 << 8, words(knobs), int(seconds * 48000 / 32) + 1).astype(np.float64)


def peak_hz(x: np.ndarray, t0: float = 0.1, t1: float = 0.3) -> float:
    s = x[int(t0 * 48000) : int(t1 * 48000)]
    s = s * np.hanning(len(s))
    spec = np.abs(np.fft.rfft(s, 1 << 17))
    f = np.fft.rfftfreq(1 << 17, 1 / 48000)
    return float(f[f > 10][np.argmax(spec[f > 10])])


@pytest.mark.parametrize(
    "ptch, hz", [(48, 72.5), (64, 102.5), (96, 205.1), (127, 401.4)]
)
def test_ptch_tunes_as_the_machinedrum(ptch, hz):
    x = model_audio((ptch, 96, 16, 64, 0, 64, 64, 0), 0.32)
    assert abs(np.log2(peak_hz(x) / hz)) * 1200 < 25  # cents


# From MFB 32 the feedback turns chaotic: ours is 0.75 semitone high at 32, and from 48 about 2.5-3 semitones brighter
# (spectral centroid) than the original. Smoothing the fed-back sine or scaling it did not close that without breaking 16..48.
@pytest.mark.parametrize("mfb, hz, st", [(0, 102.5, 0.1), (16, 86.4, 0.5), (32, 31.9, 1.0)])
def test_feedback_pulls_the_pitch_down_as_the_machinedrums_does(mfb, hz, st):
    x = model_audio((64, 96, 16, 64, 64, 64, 127, mfb), 0.32)
    assert abs(np.log2(peak_hz(x) / hz)) * 12 < st


@pytest.mark.parametrize(
    "dec, at, db", [(32, 0.05, -39.9), (64, 0.05, -10.1), (64, 0.2, -30.3), (96, 0.2, -8.3), (96, 0.5, -16.1)]
)
def test_dec_falls_as_the_machinedrums_does(dec, at, db):
    x = model_audio((64, dec, 16, 64, 0, 64, 64, 0), at + 0.02)
    x = x / np.max(np.abs(x))
    seg = x[int(at * 48000) : int(at * 48000) + 480]
    assert abs(10 * np.log10(np.mean(seg**2)) - db) < 1.5


@pytest.mark.parametrize("ptch, hz", [(0, 43.2), (64, 86.1), (127, 171.0)])
def test_xt_ptch_tunes_as_the_machinedrum(ptch, hz):
    m = md_ref.EfmXt()
    k = (ptch, 96, 16, 64, 0, 64, 64, 0)
    m.note_on(words(k))
    x = m.render(60 << 8, words(k), 300).astype(np.float64)
    assert abs(np.log2(peak_hz(x) / hz)) * 1200 < 25  # cents


def test_sd_rests_after_its_noise_and_tone_have_died():
    """The noise can outlast the tone (DEC 0, NDEC 40): the voice sounds until both are under 2^-22, then rests cheaply;
    with NOIS 0 the noise's level does not hold it."""
    for knobs in ((64, 0, 127, 40, 0, 64, 64, 0), (64, 20, 0, 127, 0, 64, 64, 0)):
        got, want, counts = played(knobs, blocks=300, machine="sd")
        np.testing.assert_array_equal(got, want)
        quiet = [k for k in range(300) if not np.any(want[32 * k : 32 * k + 32])]
        assert quiet, "the voice never rested"
        assert max(counts[quiet[0] + 1 :] or [0]) < 600


def sd_audio(knobs, seconds: float) -> np.ndarray:
    m = md_ref.EfmSd()
    m.note_on(words(knobs))
    return m.render(60 << 8, words(knobs), int(seconds * 48000 / 32) + 1).astype(np.float64)


@pytest.mark.parametrize("ptch, hz", [(0, 121.9), (64, 290.4), (127, 679.7)])
def test_sd_ptch_tunes_as_the_machinedrum(ptch, hz):
    x = sd_audio((ptch, 96, 0, 64, 0, 64, 64, 0), 0.22)
    assert abs(np.log2(peak_hz(x, 0.05, 0.2) / hz)) * 1200 < 25  # cents


@pytest.mark.parametrize("hpf, db", [(16, -5.34), (64, -16.87), (127, -24.07)])
def test_sd_hpf_takes_the_tone_down_as_the_machinedrums_does(hpf, db):
    """The tone's level 50-100 ms against HPF 0 (PTCH 64, MOD 0), as measured on the original."""

    def level(h):
        x = sd_audio((64, 96, 0, 64, 0, 64, 64, h), 0.1)[2400:4800]
        return 10 * np.log10(np.mean(x**2))

    assert abs(level(hpf) - level(0) - db) < 0.5
