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

## Open

- Which of the two tests at `0x4005f3d4` and `0x4005f3e0` is FUNC + SYN, and what the other is.
- The meaning of the two `1` arguments of the commits.
- Other paths that change a track's machine without this view: the encoder step `0x4004da90` named in the DN2 mk2 mod's notes
  (1.11), and whatever uses `MachineListView` (finding 131).
- The Digitakt II 1.17: the same owner and case are expected (the row builder has the same hash on both devices,
  [digikit-registry](../design/digikit-registry.md)), not read.
