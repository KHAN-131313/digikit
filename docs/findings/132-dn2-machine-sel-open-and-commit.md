# MACHINE SEL on the Digitone II 1.12: where it is opened, and what a commit needs

Static read of DN2 OS 1.12 (MAIN OS, load address `0x40000400`) with `tools/coldfire/disasm.py`, `tools/coldfire/refscan.py` and
Ghidra 12.2; marks [D]. It continues [finding 131](131-dn2-machine-sel-rows.md) and is the ground for a machine list that digikit
owns (folders, a list built at every open) in place of the stock view.

## The view is made once and kept

**[D]** `0x4019f456(out)` is the `make_shared` of the `Machine Selection` view: it allocates `0x1c4` bytes (the control block,
then the view from `+0x10`) and runs the constructor `0x4005b56e`. Its only caller is `0x40061c96`, in the constructor
`0x40060e72` of the view that owns the page views; the pointer pair is stored in that owner at `+0xcc` (`0x40061cc2`).

## Where FUNC + SYN opens it

**[D]** The owner's key handler is `0x4005ed12` (a2 = the owner, d2 = the key event). For key code 2 (the SYN page key;
`0x4005f3c2`) it branches to `0x40060212` when `0x4011637c(event)` is true (`0x4005f3d4`) or when the test at `0x4005f3da` is
(`0x4005f3e0`); which of the two is the FUNC chord is **[O]**. The case is:

```
40060212  pea     $cc(a2)            ; the owner's pointer to the view
4006021e  move.l  d4, -(a7)          ; a local shared_ptr at -$10(a6)
40060220  jsr     0x4019ea4e         ; copy
40060226  pea     1
4006022a  move.l  d4, -(a7)
4006022c  move.l  $2c(a2), -(a7)     ; the view manager
40060230  jsr     0x4011e6cc         ; push(manager, &local, 1)
40060236  pea     -$c(a6)
4006023a  jsr     0x401883ac         ; release the local
40060240  move.l  d2, -(a7)
40060242  jsr     0x401162a8         ; (event)
4006024c  bra.w   0x400606e6
```

`0x4011e6cc(manager, shared_ptr*, replace)` is the push this handler uses for every view it opens (eight call sites in it).

So the one call at `0x40060230` decides what FUNC + SYN shows. A hook that retargets this call gets the manager and the stock
view as arguments, with the stock stack discipline around it: it can show another view and leave the stock one unpushed, or
call the stock push.

## What the view reads and what a commit calls

**[D]** The constructor keeps two objects: `view+0x80` = `cf.project.fn.settings(cf.project.fn.singleton())` (`0x4003e40e`,
`0x4018ac5a`) and `view+0x84` = `cf.project.fn.active_kit(singleton())` (`0x4003e41a`). With them:

| What | Call |
| --- | --- |
| the track the view is for | `cf.page.fn.view_track(settings)` (`0x40046bfe`); the title prints it plus 1 |
| the track's machine type | `cf.project.fn.track_type(kit, track)` (`0x4003134e`) |
| the track's filter type | `0x400313a6(kit, track)` |
| commit a machine | `0x40031880(kit, track, type, 1, 1)` |
| commit a filter type | `0x40031a56(kit, track, value, 1, 1)` |

The first three and the singleton already have anchors in `devices/ports/dn2-1.12.toml`; the two commits and `0x400313a6` do
not. Nothing in the YES path reads the view besides its cursor and marker (finding 131), so the commits can be called from
other UI-task code with the same arguments. Not run yet **[O]**.

## Spike: a digikit list in place of the view

**[V] run here (emulator, DN2 1.12, 2026-11-14; no second byte check yet).** `modules/core/apps/machine-list` retargets the call
at `0x40060230` (`cf.machine.hook.sel.open_push`) to a C function with the same arguments. It opens a core/ui menu filled with
the named machine types and does not push the stock view; a row's action calls `cf.project.fn.set_track_type(kit, track, type,
1, 1)` with the kit and track from the project singleton. Run with `mise run dk:dev -- <the emulator set>,core/machine-list
--device dn2` and a key script:

- FUNC + SYN shows the list `MACHINES` (FM Tone, WaveTone, FM Drum, Swarmer, MIDI: type order) and not `MACHINE SEL`.
- DOWN, then YES on WaveTone: the list closes and the track's SYN page is WaveTone's (TUN1, WAV1, PD1, LEV1 ...). So the commit
  works when called from outside the stock view.
- FUNC + SYN again shows the list again; NO closes it.

Both declarations resolve from the cfdb built here (Ghidra 12.2 with the ColdfireEMAC language): regenerating
`devices/ports/dn2-1.12.toml` with `tools.patchkit.port_resolve` gave the committed file plus only the new anchors and the hook.

## The Digitakt II 1.17

**[D] read here, and run.** The same structure (`tools.coldfire.cfport dn2-1.12-emac dt2-1.17-emac` maps the functions; the weak
matches were read at their call sites):

| What | DN2 1.12 | DT2 1.17 |
| --- | --- | --- |
| view constructor | `0x4005b56e` | `0x400611fe` |
| its `make_shared`, and the caller | `0x4019f456`, `0x40061c96` | `0x401b0066`, `0x400673e6` |
| owner field that keeps the view | `+0xcc` | `+0xcc` |
| row builder | `0x4005b2c0` | `0x40060f50` |
| view key handler | `0x4005b9e8` | `0x40061678` |
| owner key handler | `0x4005ed12` | `0x400649c4` |
| the push call (the hook site) | `0x40060230` | `0x40065ce0` |
| the push function | `0x4011e6cc` | `0x4011cd58` |
| machine list getter (out vector in a0) | `0x4004d8b6` | `0x40052a08` |
| commit a machine | `0x40031880` | `0x40036798` |
| filter list getter (out vector in a0) | `0x4004dae2` | `0x40052c98` |
| filter type name | `0x400dc508` | `0x400da71e` |
| a track's filter type | `0x400313a6` | `0x400362be` |
| commit a filter type | `0x40031a56` | `0x4003696e` |
| is the track a MIDI track | `0x40031274` | `0x4003618c` |

The Digitakt view has the same page word and second list, so its second page is the filter types too. Run in the emulator
(2026-11-15, `core/machine-list` on DT2 1.17): FUNC + SRC shows the list (ONESHOT, WERP, STRETCH, REPITCH, SLICE, GRID, MIDI and
the FILTER folder), a pick sets the track's machine (the track's page becomes WERP's), and the FILTER folder sets the filter
type.

## Open


- Which of the two tests at `0x4005f3d4` and `0x4005f3e0` is FUNC + SYN, and what the other is.
- The meaning of the two `1` arguments of the commits.
- Other paths that change a track's machine without this view: the encoder step `0x4004da90` named in the DN2 mk2 mod's notes
  (1.11), and whatever uses `MachineListView` (finding 131).
