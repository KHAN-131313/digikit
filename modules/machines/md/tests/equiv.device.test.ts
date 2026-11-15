import { defineEquiv, DN2_TRIG, type Equiv } from '@digi/regression/runtime/equiv.ts';

// DN2 1.12: khan/md (EFM-BD and EFM-XT) loads from the card at boot, claims its voice rows, leaves the other rows as a boot
// of no module, and its first machine plays an audible note. No PCM pin yet (pins need Em's approval).
const SCENARIOS: Equiv[] = [
  {
    name: 'equiv-dyn-md',
    device: 'dn2',
    modules: ['khan/md'],
    play: { module: 'khan/md', machine: 'md' },
    hint: 5,
    trigFrame: DN2_TRIG,
    voices: 2,
    ignoreRunMachines: ['EFM-BD', 'EFM-XT'],
  },
];

defineEquiv(SCENARIOS);
