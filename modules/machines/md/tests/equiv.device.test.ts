import { defineEquiv, type Equiv } from '@digi/regression/runtime/equiv.ts';

// DN2 1.12: khan/md (the eight EFM machines) loads from the card at boot, claims its voice rows, leaves the other rows as a boot
// of no module, and its first machine plays an audible note. No PCM pin yet (pins need Em's approval).
const SCENARIOS: Equiv[] = [
  {
    name: 'equiv-dyn-md',
    device: 'dn2',
    modules: ['khan/md'],
    play: { module: 'khan/md', machine: 'md' },
    hint: 5,
    // eight machines' DSP code: setup ends near frame 9465, past DN2_TRIG
    trigFrame: 12000,
    voices: 8,
    ignoreRunMachines: ['EFM-BD', 'EFM-XT', 'EFM-SD', 'EFM-CP', 'EFM-RS', 'EFM-CB', 'EFM-HH', 'EFM-CY'],
  },
];

defineEquiv(SCENARIOS);
