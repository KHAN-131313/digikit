/* core/machine-list: the machine list that digikit owns, in place of the firmware's Machine Selection view.
 * Plan: docs/plans/machine-list.md. Facts: docs/findings/130 and 131.
 *
 * ml_push takes the place of the stock push at the one call site that shows the stock view on FUNC + SRC (Digitakt II) or
 * FUNC + SYN (Digitone II): same arguments (the view manager, the shared_ptr of the stock view, replace), same result. It opens
 * the list and leaves the stock view unpushed; when the list cannot be made it calls the stock push, so the stock view opens.
 *
 * The list is a plain core/ui menu, filled at every open from the firmware's machine list (its order; core/dynreg leaves out
 * unfilled run-time types): one row per machine, the track's machine marked and under the cursor. YES on a row sets that
 * machine for the selected track: the mark moves and the list stays open. YES on the marked row closes the list (the stock
 * view's rule). NO closes it.
 *
 * The filter types are a second tab, as in the stock view: LEFT and RIGHT switch between the machines and the filter types
 * (core/ui tabs: the label and the page dots under the title). The list opens on the filter tab when the track shows its
 * filter page, as the stock view does. The track's filter type is marked; YES sets a type and the tab stays open, YES on the
 * marked type closes the list. On a MIDI track the tab says that MIDI tracks have no filters.
 *
 * The globals without static are read by the proofs by name. The module links without memcpy and memset. */
#include <stdint.h>
#include <stddef.h>
#include <dk/platform/ui.h>
#include <dk_ui_core.h>
#include <dk_fw_machine.h>
#include <dk_fw_mem.h>
#include <dk_fw_page.h>
#include <dk_fw_project.h>
#include <dk_fw_view.h>
#include "dkrt.h"

#define ML_MAX 40

/* std::vector<int> as the getter returns it. */
typedef struct vec {
    int32_t *begin, *end, *cap;
} vec;

void ml_get_list(vec *out);    /* shim.s */
void ml_get_filters(vec *out); /* shim.s */

/* The rows of the list as it was last filled: the machine type of each row, their number, the track they are for and the
   track's machine (-1: none). ML_OPENS counts the opens, ML_LAST is the last type a row committed (-1: none). */
int32_t ML_TYPE[ML_MAX];
uint32_t ML_N;
int32_t ML_TRACK;
int32_t ML_CUR = -1;
uint32_t ML_OPENS;
int32_t ML_LAST = -1;
/* The same for the filter tab: the filter type of each row, their number (0 on a MIDI track), the track's filter type and
   the last one a row committed (-1: none). ML_TAB is the tab that is open or was open last: 0 machines, 1 filter types. */
int32_t ML_FTYPE[ML_MAX];
uint32_t ML_FN;
int32_t ML_FCUR = -1;
int32_t ML_FLAST = -1;
uint32_t ML_TAB;

static dk_ui *g_ui;
static dk_ui_menu *g_menu;
static dk_ui_menu *g_filter;

static uint32_t kit_and_track(int32_t *track)
{
    uint32_t project = dk_fw_project_singleton();
    *track = (int32_t)dk_fw_page_view_track((const uint8_t *)dk_fw_project_settings(project));
    return dk_fw_project_active_kit(project);
}

/* Reads the machine list and the track's machine into the ML_ globals. */
static void scan(void)
{
    vec v;
    v.begin = v.end = v.cap = 0;
    ml_get_list(&v);
    uint32_t kit = kit_and_track(&ML_TRACK);
    ML_CUR = dk_fw_project_track_type(kit, ML_TRACK);
    ML_N = 0;
    for (int32_t *p = v.begin; p && p < v.end && ML_N < ML_MAX; p++) {
        const char *name = *p < 0 ? 0 : dk_fw_machine_name_long(*p);
        if (name && name[0])
            ML_TYPE[ML_N++] = *p;
    }
    if (v.begin)
        dk_fw_mem_free((uint8_t *)v.begin);
}

static int32_t row_of(int32_t type)
{
    for (uint32_t i = 0; i < ML_N; i++)
        if (ML_TYPE[i] == type)
            return (int32_t)i;
    return -1;
}

/* Reads the filter type list and the track's filter type into the ML_F globals. */
static void scan_filters(void)
{
    vec v;
    v.begin = v.end = v.cap = 0;
    ml_get_filters(&v);
    int32_t track;
    uint32_t kit = kit_and_track(&track);
    ML_FCUR = dk_fw_project_track_filter(kit, track);
    ML_FN = 0;
    for (int32_t *p = v.begin; p && p < v.end && ML_FN < ML_MAX; p++) {
        const char *name = *p < 0 ? 0 : dk_fw_machine_filter_name(*p);
        if (name && name[0])
            ML_FTYPE[ML_FN++] = *p;
    }
    if (v.begin)
        dk_fw_mem_free((uint8_t *)v.begin);
}

static int32_t filter_row_of(int32_t filter)
{
    for (uint32_t i = 0; i < ML_FN; i++)
        if (ML_FTYPE[i] == filter)
            return (int32_t)i;
    return -1;
}

static void pick_filter(void *arg, int32_t row)
{
    (void)arg;
    if (row < 0 || (uint32_t)row >= ML_FN)
        return;
    int32_t filter = ML_FTYPE[row];
    if (filter == ML_FCUR) { /* YES on the marked type closes the list */
        dk_ui_menu_close(g_filter);
        return;
    }
    int32_t track;
    uint32_t kit = kit_and_track(&track);
    dk_fw_project_set_track_filter(kit, track, filter, 1, 1);
    ML_FLAST = filter;
    ML_FCUR = dk_fw_project_track_filter(kit, track);
    for (uint32_t i = 0; i < ML_FN; i++)
        dk_ui_menu_check(g_filter, (int32_t)i, ML_FTYPE[i] == ML_FCUR);
}

static void pick(void *arg, int32_t row)
{
    (void)arg;
    if (row < 0 || (uint32_t)row >= ML_N)
        return;
    int32_t type = ML_TYPE[row];
    if (type == ML_CUR) { /* YES on the marked machine closes the list */
        dk_ui_menu_close(g_menu);
        return;
    }
    int32_t track;
    uint32_t kit = kit_and_track(&track);
    dk_fw_project_set_track_type(kit, track, type, 1, 1);
    ML_LAST = type;
    ML_CUR = dk_fw_project_track_type(kit, track);
    for (uint32_t i = 0; i < ML_N; i++)
        dk_ui_menu_check(g_menu, (int32_t)i, ML_TYPE[i] == ML_CUR);
}

/* The label of a row: the machine's name in upper case, as the firmware's menus write their rows. */
static void label(char *out, const char *name)
{
    uint32_t i = 0;
    for (; name[i] && i + 1 < DK_UI_ROW; i++)
        out[i] = name[i] >= 'a' && name[i] <= 'z' ? (char)(name[i] - 32) : name[i];
    out[i] = 0;
}

static void fill_filters(dk_ui_menu *m, void *arg)
{
    (void)arg;
    char text[DK_UI_ROW];
    int32_t track;
    uint32_t kit = kit_and_track(&track);
    if (dk_fw_project_track_is_midi(kit, track)) { /* the stock view's words */
        ML_FN = 0;
        dk_ui_menu_add_text(m, "NO FILTERS ON");
        dk_ui_menu_add_text(m, "MIDI TRACKS.");
        return;
    }
    scan_filters();
    for (uint32_t i = 0; i < ML_FN; i++) {
        label(text, dk_fw_machine_filter_name(ML_FTYPE[i]));
        dk_ui_menu_add_action(m, text, pick_filter, NULL, (int32_t)i);
        if (ML_FTYPE[i] == ML_FCUR)
            dk_ui_menu_check(m, (int32_t)i, 1);
    }
}

static void fill(dk_ui_menu *m, void *arg)
{
    (void)arg;
    char text[DK_UI_ROW];
    scan();
    for (uint32_t i = 0; i < ML_N; i++) {
        label(text, dk_fw_machine_name_long(ML_TYPE[i]));
        dk_ui_menu_add_action(m, text, pick, NULL, (int32_t)i);
        if (ML_TYPE[i] == ML_CUR)
            dk_ui_menu_check(m, (int32_t)i, 1);
    }
}

/* Shows tab `tab` (0 machines, 1 filter types) with the cursor on its marked row, and closes the other. */
static void show(uint32_t tab)
{
    dk_ui_menu *on = tab ? g_filter : g_menu, *off = tab ? g_menu : g_filter;
    int32_t row;
    if (tab) {
        scan_filters();
        row = filter_row_of(ML_FCUR);
    } else {
        scan();
        row = row_of(ML_CUR);
    }
    ML_TAB = tab;
    dk_ui_menu_close(off);
    dk_ui_menu_select(on, row < 0 ? 0 : row);
    dk_ui_menu_open(on);
}

/* LEFT or RIGHT on a tab: `tab` is the tab the key came from. */
static void side(void *tab, int32_t dir)
{
    uint32_t from = (uint32_t)(uintptr_t)tab;
    if (from == 0 && dir > 0)
        show(1);
    else if (from == 1 && dir < 0)
        show(0);
}

static const dk_ui_menu_desc desc = {
    .name = "MachineList", .title = "MACHINES", .flags = 0, .fill = fill};
static const dk_ui_menu_desc filter_desc = {
    .name = "MachineListFilter", .title = "MACHINES", .flags = 0, .fill = fill_filters};

/* The first tab's label is the page key's name: SRC on the Digitakt II, SYN on the Digitone II. */
static const char *machines_label(void)
{
    DkrtStatus st;
    st.device = 0;
    dkrt_status(&st);
    return st.device == 1 ? "SRC" : "SYN";
}

uint32_t ml_push(uint32_t manager, const shared_ptr *view, uint32_t replace)
{
    ML_OPENS++;
    if (!g_menu) {
        g_ui = dk_ui_core_handle();
        if (g_ui) {
            g_menu = dk_ui_menu_new(g_ui, &desc);
            g_filter = dk_ui_menu_new(g_ui, &filter_desc);
        }
        if (g_menu && g_filter &&
            !(dk_ui_menu_tabs(g_menu, machines_label(), 0, 2, side, (void *)0) &&
              dk_ui_menu_tabs(g_filter, "FLTR", 1, 2, side, (void *)1)))
            g_filter = 0; /* no tabs: the machines alone */
    }
    if (!g_menu)
        return dk_fw_view_push_shared(manager, view, replace);
    /* the stock view opens on its filter page when the track shows its filter page (page 2) */
    int32_t track;
    uint32_t project = dk_fw_project_singleton();
    const uint8_t *settings = (const uint8_t *)dk_fw_project_settings(project);
    track = (int32_t)dk_fw_page_view_track(settings);
    if (g_filter)
        show(dk_fw_page_track_page(settings, track) == 2);
    else {
        scan();
        int32_t row = row_of(ML_CUR);
        dk_ui_menu_select(g_menu, row < 0 ? 0 : row);
        dk_ui_menu_open(g_menu);
    }
    return 1;
}
