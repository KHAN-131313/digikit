"""khan/md on the concrete SHARC+ core through core/dsp-voice (DN2), against the float32 model (tests/md_ref.py EfmBd), bit for bit.
The rig draws hostile context registers for every call; Rig.run checks that they come back."""

import numpy as np
import pytest
from support.machine_rig import MachineRig

import md_ref
from tools.patchkit import pk_toolchains

pytestmark = pytest.mark.skipif(
    pk_toolchains.selache_dir() is None,
    reason="selache not built (tools/patchkit/pk_toolchains.py selache)",
)

IDS = ("md_ptch", "md_dec", "md_ramp", "md_rdec", "md_mod", "md_mfrq", "md_mdec", "md_mfb")
DEFAULTS = (36, 76, 64, 55, 64, 64, 32, 127)


def words(knobs) -> list[int]:
    return [round(k * 256) for k in knobs]


class Rig(MachineRig):
    def __init__(self) -> None:
        super().__init__("khan/md", "dn2")

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


def played(knobs, note: int = 60, vel: int = 100, blocks: int = 60):
    """The rig's blocks after the trigger block (the DN2 trigger bit starts the note in the next block) and the model's."""
    rig = Rig()
    rig.play(note, vel, knobs)
    y, counts = rig.run(blocks + 1)
    m = md_ref.EfmBd()
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


@pytest.mark.parametrize("name", CASES)
def test_the_routine_matches_the_model(name):
    knobs, note = CASES[name]
    got, want, _ = played(knobs, note)
    assert np.max(np.abs(want)) > 0.05
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
    """The ceiling the description declares (4000 a block, the adapter included) holds for every knob case."""
    for knobs, note in CASES.values():
        _, _, counts = played(knobs, note, blocks=4)
        assert max(counts) < 4000, counts
