# Machine list (plan, 2026-11-14)

Goal: a machine list that digikit owns, in place of the firmware's Machine Selection view, so that run-time machines can sit in
folders, the list is built when it opens (hot reload, collections, project modules), and its size is not tied to the firmware's
list tables. Facts: findings [131](../findings/131-dn2-machine-sel-rows.md) and
[132](../findings/132-dn2-machine-sel-open-and-commit.md). Branch: `khan/machine-list`.

Payoff: high (folders are what many-machine modules such as a Machinedrum set need; one list for both devices). Confidence:
medium-high: the spike (step 0) showed the two unknowns work on the DN2 1.12 in the emulator.

## Why not patch the stock view

The stock view can be patched to rebuild its rows for a folder (finding 131 has the sites), but that is one level deep, depends on
register and stack state inside its key handler, costs a machine type per folder row, and its rows are built once at boot. The
stock view already shows its second list (filter types) as a sideways page, which reads as a tab, not as a folder.

## Behaviour

- FUNC + SYN (DN2) or FUNC + SRC (DT2) opens the list for the selected track, as now.
- Rows: the stock machines, then run-time machines that are in no folder, then one row per folder.
- The filter types are a second tab, as in the stock view (decided by Khan): LEFT and RIGHT switch between the machines tab
  (labelled `SYN` on the DN2, `SRC` on the DT2) and the `FLTR` tab, with the label and page dots under the title. The list
  opens on the filter tab when the track shows its filter page. On a MIDI track the filter tab shows the stock words
  `NO FILTERS ON` / `MIDI TRACKS.`.
- The cursor starts on the track's machine. When that machine is in a folder the list opens inside the folder, over the top
  list (Claude's call, 2026-11-15: it saves a press when moving between the machines of one folder, such as the MD set); NO
  goes up to the folder row, and LEFT from the filter tab shows the top list with the cursor on the folder row. The track's
  machine carries a marker, and so does the folder row that holds it.
- YES on a machine sets it for the track: the marker moves and the list stays open (decided by Khan, as the stock view does).
  YES on the marked machine closes the list (the stock rule). YES on a folder opens it.
- NO closes the list; inside a folder NO goes up one level, with the cursor on the folder.
- A folder with no loaded machine is not shown. A module's machines are in the folder the module names
  (`dk_module_ctx_folder(ctx, "MD")` in `init`, runtime 0.8.1); a module that names none has its machines in the root. Modules
  that name the same folder share it (names compared in upper case). One level only.

## Look

Built on core/ui, which draws with the firmware's own views. The plain menu (the SETTINGS look: title at the left, large rows)
is the closest to the stock screens; it need not match the stock screen exactly, similar is enough (Khan). Each row has a draw function (finding 71, MenuItem `+0x2c`), so a row can carry a marker,
a folder sign or a small icon. Wanted later (Khan): closer to the stock machine screen, and a sign that the list is digikit's
(an icon or text). First version: plain menu, marker on the track's machine, a sign on folder rows.

## Steps

0. [x] Spike (`modules/core/apps/machine-list`, commit 6c61be5d): the push of the stock view retargeted
   (`cf.machine.hook.sel.open_push`), a core/ui menu of the named machine types, `cf.project.fn.set_track_type` from a row. Run in
   the emulator: list opens, the commit changes the track's machine, NO closes.
1. [x] Declarations with `sig` in `devices/fw` (the spike declares in C): `set_track_type`, `push_shared`, `name.long`, and for
   the DN2 filter types `0x40031a56` (set) and `0x400313a6` (get). Core Rust objects rebuilt (the toolchain works here).
2. [x] Digitakt II 1.17: the same owner, open site and commits read and declared (`rule.dt2`); run in the emulator. [ ] The DN2
   1.11 port needs its image (not on this machine).
3. [x] core/ui: a row mark (`dk_ui_menu_check` on a plain menu) and a folder row (`dk_ui_menu_add_folder`), drawn by the row
   draw function. [ ] Host tests in `modules/core/adapters/ui/host`.
4. [x] The list proper: rows from the machine list getter (so the registry's filter and order apply), mark and cursor on
   the track's machine, stays open after a commit. The filter types as a second tab (`dk_ui_menu_tabs` in core/ui,
   `cf.page.fn.track_page` for opening on it), run on both devices in the emulator: LEFT and RIGHT, a pick on each tab, opening
   on the filter tab, the MIDI text. A first version put them in a `FILTER` folder row; that was replaced by the tab, which is
   what the stock view does.
5. [x] Folders: a module names a folder for its machines with the builder call `dk_module_ctx_folder(ctx, "MD")` (chosen over a
   manifest key: machines are declared by builder calls in `init`, and the folder commits with them); the runtime keeps it per
   module from the commit until the unload and gives it per machine type to core modules (`dkrt_machine_folder`, through the
   registry's row owners); the list groups by it. Runtime 0.8.1 (a new import). Host tests in `collect/tests.rs`; the fixture
   `test/folder-sine` (two machines in the folder TEST). [ ] Run on both devices.
6. [ ] Tests: host tests of the list logic; a device test on both devices (open, pick, marker, folder in and out, NO).
7. [ ] Fallback and safety: when the list cannot be made the stock view opens (the spike does this); a patch set without
   `core/machine-list` keeps the stock view.
8. [ ] Docs: MODULE-AUTHORING (folders), finding 132 completed, this plan closed.

## Open

- Other ways a track's machine changes without the view (an encoder step; `MachineListView`): read before step 4, so the list
  and those paths agree on the marker.
- The device-wide limits (8 machine types, 16 parameter rows, 8 pages) still cap what a folder can hold; raising them is
  [module-limits](module-limits.md) step 4 and is separate from this plan.
- Whether the root should show stock machines first or a `STOCK` folder when many modules are loaded.
