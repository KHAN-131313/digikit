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
 * FILTER is a folder at the end of the list (not on a MIDI track, as the stock view shows no filters there): the filter types
 * of the stock view's second page, the track's type marked. YES sets the type and the folder stays open, YES on the marked
 * type closes the list, NO goes back to the machines.
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
/* The same for the FILTER folder: the filter type of each row, their number, the track's filter type, the last one a row
   committed (-1: none), and 1 when the list was filled with the folder (0 on a MIDI track). */
int32_t ML_FTYPE[ML_MAX];
uint32_t ML_FN;
int32_t ML_FCUR = -1;
int32_t ML_FLAST = -1;
uint32_t ML_HAS_FILTER;

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
        dk_ui_menu_close(g_menu);
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
    /* fill again: the mark moves, and FILTER comes or goes with a MIDI machine; the cursor keeps its row */
    dk_ui_menu_refresh(g_menu);
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
    int32_t track;
    uint32_t kit = kit_and_track(&track);
    ML_HAS_FILTER = g_filter && !dk_fw_project_track_is_midi(kit, track);
    if (ML_HAS_FILTER)
        dk_ui_menu_add_folder(m, "FILTER", g_filter);
}

static const dk_ui_menu_desc desc = {.name = "MachineList", .title = "MACHINES", .flags = 0, .fill = fill};
static const dk_ui_menu_desc filter_desc = {
    .name = "MachineListFilter", .title = "FILTER", .flags = 0, .fill = fill_filters};

uint32_t ml_push(uint32_t manager, const shared_ptr *view, uint32_t replace)
{
    ML_OPENS++;
    if (!g_menu) {
        g_ui = dk_ui_core_handle();
        if (g_ui) {
            g_menu = dk_ui_menu_new(g_ui, &desc);
            g_filter = dk_ui_menu_new(g_ui, &filter_desc);
        }
    }
    if (!g_menu)
        return dk_fw_view_push_shared(manager, view, replace);
    scan(); /* for the cursor: the open fills again */
    int32_t row = row_of(ML_CUR);
    dk_ui_menu_select(g_menu, row < 0 ? 0 : row);
    if (g_filter) {
        scan_filters();
        row = filter_row_of(ML_FCUR);
        dk_ui_menu_select(g_filter, row < 0 ? 0 : row);
    }
    dk_ui_menu_open(g_menu);
    return 1;
}
