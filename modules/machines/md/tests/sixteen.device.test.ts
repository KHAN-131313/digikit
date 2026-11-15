import path from 'node:path';
import { type Session } from '@digi/test-support';
import { expect, test } from 'vitest';
import { bootInfo } from '@digi/regression/runtime/card-kit.ts';
import { cardRig } from '@digi/regression/runtime/card-rig.ts';
import { rootsOf } from '@digi/regression/runtime/image-roots.ts';
import { advance, peak, pickSine, readFloatWav, rpc, word } from '@digi/regression/runtime/fx-live.ts';
import { tap } from '@digi/regression/runtime/fx-session.ts';
import { describeOn } from '@digi/regression/runtime/devices.ts';
import { planSymbol, type RuntimePlan } from '@digi/regression/runtime/runtime-plan.ts';

// DN2 1.12: the goal of khan/md, all 16 tracks on Machinedrum voices at once. The eight EFM machines go on tracks 1 to 16 (each
// twice), every track gets a trig on every beat and the pattern plays: no fault, the output is audible, and the DSP's block time
// (core/health, docs/findings/41-digikit-health.md) stays under one block. The block times are printed for the record.

const MACHINES = ['md', 'xt', 'sd', 'cp', 'rs', 'cb', 'hh', 'cy'];
/** One DSP block at 1 GHz: 32 samples at 48 kHz (finding 41). */
const BLOCK_CYCLES = 666_667;
/** The stock list position of the first run-time machine (after MIDI), as in equiv.device.test.ts. */
const FIRST_RUN_TIME = 5;
/** The steps of the trigs: every beat of the pattern's first bar. */
const BEATS = [1, 5, 9, 13];

/** core/health's published window (HealthState words 7 to 10): windows closed, sequence, average and maximum block cycles. */
async function dspWindow(session: Session, plan: RuntimePlan) {
  const hs = planSymbol(plan, 'health_hs');
  return {
    windows: await word(session, hs + 4 * 7),
    avg: await word(session, hs + 4 * 9),
    max: await word(session, hs + 4 * 10),
  };
}

/** Waits until core/health has closed `n` more windows (one a second of audio) and returns the last. */
async function nextWindows(session: Session, plan: RuntimePlan, n: number) {
  const start = (await dspWindow(session, plan)).windows;
  for (let i = 0; i < 40; i++) {
    await advance(session, 250);
    const w = await dspWindow(session, plan);
    if (w.windows >= start + n) return w;
  }
  throw new Error(`core/health closed no ${n} windows after ${start}`);
}

describeOn('dn2', 'DN2 1.12 khan/md on 16 tracks', () => {
  const rig = cardRig('dn2', 'md-sixteen', {
    dsp: 'sharc',
    roots: rootsOf('rt-health'),
    hold: true,
    symbols: ['health_hs'],
    initial: () => ({ modules: ['khan/md'], selection: ['modules/md.dkm'] }),
  });

  test('16 tracks play the eight EFM machines together: no fault, audible, the DSP under one block', async () => {
    const rt = await rig.first();
    const { session } = rt;
    const info = await bootInfo(session, rig.plan);
    expect(info.results, 'khan/md loaded').toEqual([0]);

    const idle = await nextWindows(session, rig.plan, 2);

    // the stock list by position, as equiv.device.test.ts does on the DN2 (no address reads a DN2 track's type: its getter is a
    // virtual call on the track's sound); every track starts on the list's first row
    for (let t = 1; t <= 16; t++) {
      await tap(session, `TRIG ${t}`, 300, 'TRK');
      await pickSine(session, FIRST_RUN_TIME + ((t - 1) % MACHINES.length));
    }

    // GRID RECORDING: a trig on every beat (steps 1, 5, 9, 13) of every track, so each one-second window holds note starts
    await tap(session, 'RECORD', 200);
    for (let t = 1; t <= 16; t++) {
      await tap(session, `TRIG ${t}`, 200, 'TRK');
      for (const step of BEATS) await tap(session, `TRIG ${step}`, 150);
    }
    await tap(session, 'RECORD', 200);

    // the capture runs from PLAY over the measured windows
    const file = path.join(rig.artifacts, 'sixteen.wav');
    await rpc(session, 'pcm.tap', { action: 'start' });
    await rpc(session, 'pcm.tap', { action: 'capture', path: file });
    await tap(session, 'PLAY', 100);
    const playing = await nextWindows(session, rig.plan, 2);
    await rpc(session, 'pcm.tap', { action: 'capture_stop' });
    const pcm = readFloatWav(file);
    await tap(session, 'STOP', 200);
    await session.expectNoFault('16 tracks');

    const pct = (c: number) => `${((100 * c) / BLOCK_CYCLES).toFixed(1)} %`;
    console.log(
      `DSP block, idle avg ${idle.avg} (${pct(idle.avg)}) max ${idle.max} (${pct(idle.max)}); ` +
        `16 tracks avg ${playing.avg} (${pct(playing.avg)}) max ${playing.max} (${pct(playing.max)})`,
    );
    expect(peak(pcm), 'the 16 tracks are audible').toBeGreaterThan(0.01);
    expect(playing.max, 'the busiest block of the window fits in one block').toBeLessThan(BLOCK_CYCLES);
  });
});
