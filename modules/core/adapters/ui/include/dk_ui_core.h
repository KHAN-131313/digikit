/* dk_ui_core.h: calls of core/ui for other core modules only. Not part of the module SDK (sdk/include/dk/platform/ui.h). */
#ifndef DK_UI_CORE_H
#define DK_UI_CORE_H
#include <stdint.h>
#include <dk/platform/ui.h>

/* The UI handle for core modules, which have no dk_module_ctx to open it with: the same handle dk_ui_open gives a content module. */
dk_ui *dk_ui_core_handle(void);

/* A row among the rows of a stock firmware menu (SETTINGS), with the menu's icon. fn(arg, 0) runs on YES.
   Call it from a hook that rebuilds the stock menu; stock_menu is the menu object the hook gets. */
void dk_ui_stock_row(uint8_t *stock_menu, const char *text, dk_ui_action_fn *fn, void *arg);

/* Tabs for a plain menu, in the look of the firmware's Machine Selection view: under the title, `label` between two arrows and a
   row of `count` dots, the one at `index` larger. LEFT and RIGHT call side(arg, -1) and side(arg, +1); the caller closes this
   menu and opens the other tab's. `label` is kept, not copied. Returns 1, or 0 when the menu cannot take tabs. */
int32_t dk_ui_menu_tabs(dk_ui_menu *m, const char *label, int32_t index, int32_t count,
                        dk_ui_action_fn *side, void *arg);
/* A submenu row with a folder sign in the icon column (a plain menu; in a list it is a plain submenu row). */
void dk_ui_menu_add_folder(dk_ui_menu *m, const char *text, dk_ui_menu *sub);
/* In a plain menu dk_ui_menu_check(m, row, on) puts a mark (a dot at the right end) on a row and dk_ui_menu_checked reads it:
   a "current choice" mark. It is the caller's state: YES does not toggle it, and a refill clears it (set it again in fill). */
/* Implemented by an app (core/digikit-menu) and called by core/ui from its hook at the end of the SETTINGS item list rebuild: add the
   app's rows with dk_ui_stock_row. An optional link: core/ui resolves it at patch time and does nothing when no module provides it. */
void dk_app_settings_rows(uint8_t *stock_menu);

/* The machine list's firmware side (core/machine-list; docs/findings/131 and 132). The track is the selected one; a type is a
   machine type number, a filter a filter type number.
   dk_ui_machine_types: the firmware's machine list (its order; core/dynreg leaves out unfilled run-time types), at most `max`
   types into `out`; returns how many. dk_ui_filter_types: the same for the filter types (the stock view's second page). */
uint32_t dk_ui_machine_types(int32_t *out, uint32_t max);
uint32_t dk_ui_filter_types(int32_t *out, uint32_t max);
/* The long name of a machine type and the name of a filter type (0 when none). */
const char *dk_ui_machine_name(int32_t type);
const char *dk_ui_filter_name(int32_t filter);
/* The selected track, its machine type and filter type, and the setters the stock view's YES uses. */
int32_t dk_ui_track(void);
int32_t dk_ui_track_machine(void);
int32_t dk_ui_track_filter(void);
void dk_ui_set_track_machine(int32_t type);
void dk_ui_set_track_filter(int32_t filter);
/* 1 when the selected track is a MIDI track (it has no filter). */
int32_t dk_ui_track_is_midi(void);
/* 1 when the selected track shows its filter page (the stock view opens on its filter page then). */
int32_t dk_ui_track_on_filter_page(void);

/* Implemented by an app (core/machine-list) and called by core/ui where the firmware shows its Machine Selection view (FUNC + SRC
   on the Digitakt II, FUNC + SYN on the Digitone II): return 1 when the app showed its own list, 0 to show the stock view. An
   optional link, as dk_app_settings_rows: without it the stock view opens. */
int32_t dk_app_machine_list_open(void);

#endif
