/* core/machine-list: the machine list that digikit owns, in place of the firmware's Machine Selection view.
 * Plan: docs/plans/machine-list.md. Facts: docs/findings/131 and 132.
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
 * Folders: a module may name a folder for its machines (dk_module_ctx_folder; the runtime gives it per machine type,
 * dkrt_machine_folder). Its machines are then not in the top list but in one folder row at its end (after the stock machines
 * and the run-time machines in no folder); YES on the folder row opens the folder, a menu of its own titled with its name, and
 * NO goes back to the folder row. Modules that name the same folder share it. The folder row is marked when the track's machine
 * is in it, and the list opens inside that folder with the cursor on the machine. Each folder's menu is made once (menus are
 * never freed), at most ML_FOLDERS; the machines of a folder past that stay in the top list.
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
#define ML_FOLDERS 8
#define ML_FNAME 16 /* a folder name with its NUL (dk_module_ctx_folder: 15 characters) */

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
/* The folder of each row of ML_TYPE (-1: none, else its slot in ML_FOLDER), the folder names in slot order (upper case) and the
   number of slots in use; ML_ROW maps the rows of the top list to ML_TYPE (>= 0) or to a folder (-1 - slot); ML_NROW rows.
   ML_IN is the folder slot whose menu was opened last (-1: none). */
int32_t ML_TF[ML_MAX];
char ML_FOLDER[ML_FOLDERS][ML_FNAME];
uint32_t ML_NF;
int32_t ML_ROW[ML_MAX];
uint32_t ML_NROW;
int32_t ML_IN = -1;
int32_t ML_FTYPE[ML_MAX];
uint32_t ML_FN;
int32_t ML_FCUR = -1;
int32_t ML_FLAST = -1;
uint32_t ML_TAB;

static dk_ui *g_ui;
static dk_ui_menu *g_menu;
static dk_ui_menu *g_filter;
static dk_ui_menu *g_sub[ML_FOLDERS];
static dk_ui_menu_desc g_sub_desc[ML_FOLDERS];
static void fill_sub(dk_ui_menu *m, void *arg);

static uint32_t kit_and_track(int32_t *track)
{
    uint32_t project = dk_fw_project_singleton();
    *track = (int32_t)dk_fw_page_view_track((const uint8_t *)dk_fw_project_settings(project));
    return dk_fw_project_active_kit(project);
}

static int32_t same(const char *a, const char *b)
{
    uint32_t i = 0;
    for (; a[i] && a[i] == b[i]; i++)
        ;
    return a[i] == b[i];
}

/* The folder slot of machine type `type`: -1 when its module names none, or when no slot is left or its menu cannot be made.
   The name is kept in upper case; the slot's menu is made the first time the name is seen. */
static int32_t folder_of(int32_t type)
{
    char name[ML_FNAME];
    int32_t n = dkrt_machine_folder((uint32_t)type, (uint8_t *)name, ML_FNAME);
    if (n <= 0 || !g_ui)
        return -1;
    for (int32_t i = 0; i < n; i++)
        if (name[i] >= 'a' && name[i] <= 'z')
            name[i] = (char)(name[i] - 32);
    for (uint32_t f = 0; f < ML_NF; f++)
        if (same(ML_FOLDER[f], name))
            return (int32_t)f;
    if (ML_NF >= ML_FOLDERS)
        return -1;
    uint32_t f = ML_NF;
    for (int32_t i = 0; i <= n; i++)
        ML_FOLDER[f][i] = name[i];
    g_sub_desc[f].name = "MachineListFolder";
    g_sub_desc[f].title = ML_FOLDER[f];
    g_sub_desc[f].flags = 0;
    g_sub_desc[f].fill = fill_sub;
    g_sub_desc[f].arg = (void *)(uintptr_t)f;
    g_sub[f] = dk_ui_menu_new(g_ui, &g_sub_desc[f]);
    if (!g_sub[f])
        return -1;
    ML_NF++;
    return (int32_t)f;
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
        if (name && name[0]) {
            ML_TF[ML_N] = folder_of(*p);
            ML_TYPE[ML_N++] = *p;
        }
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

/* The folder slot of the track's machine (-1: none or not in the list). */
static int32_t cur_folder(void)
{
    int32_t i = row_of(ML_CUR);
    return i < 0 ? -1 : ML_TF[i];
}

/* The mark on the top list's rows (a machine row, or the folder row that holds the track's machine) and in the folder last
   opened. */
static void marks(void)
{
    int32_t cf = cur_folder();
    for (uint32_t r = 0; r < ML_NROW; r++) {
        int32_t v = ML_ROW[r];
        dk_ui_menu_check(g_menu, (int32_t)r, v >= 0 ? ML_TYPE[v] == ML_CUR : -1 - v == cf);
    }
    if (ML_IN >= 0) {
        int32_t k = 0;
        for (uint32_t i = 0; i < ML_N; i++)
            if (ML_TF[i] == ML_IN)
                dk_ui_menu_check(g_sub[ML_IN], k++, ML_TYPE[i] == ML_CUR);
    }
}

static void pick(void *arg, int32_t row)
{
    (void)arg;
    if (row < 0 || (uint32_t)row >= ML_N)
        return;
    int32_t type = ML_TYPE[row];
    if (type == ML_CUR) { /* YES on the marked machine closes the list */
        if (ML_IN >= 0)
            dk_ui_menu_close(g_sub[ML_IN]);
        dk_ui_menu_close(g_menu);
        return;
    }
    int32_t track;
    uint32_t kit = kit_and_track(&track);
    dk_fw_project_set_track_type(kit, track, type, 1, 1);
    ML_LAST = type;
    ML_CUR = dk_fw_project_track_type(kit, track);
    marks();
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

/* Scans and lays out the top list into ML_ROW: the machines in no folder in the firmware's order, then one row per folder that
   holds a machine. */
static void layout(void)
{
    scan();
    ML_NROW = 0;
    for (uint32_t i = 0; i < ML_N; i++)
        if (ML_TF[i] < 0)
            ML_ROW[ML_NROW++] = (int32_t)i;
    for (uint32_t f = 0; f < ML_NF; f++) {
        uint32_t i = 0;
        while (i < ML_N && ML_TF[i] != (int32_t)f)
            i++;
        if (i < ML_N) /* else no loaded machine names it now */
            ML_ROW[ML_NROW++] = -1 - (int32_t)f;
    }
}

static void fill(dk_ui_menu *m, void *arg)
{
    (void)arg;
    char text[DK_UI_ROW];
    layout();
    int32_t cf = cur_folder();
    for (uint32_t r = 0; r < ML_NROW; r++) {
        int32_t v = ML_ROW[r];
        if (v >= 0) {
            label(text, dk_fw_machine_name_long(ML_TYPE[v]));
            dk_ui_menu_add_action(m, text, pick, NULL, v);
        } else
            dk_ui_menu_add_folder(m, ML_FOLDER[-1 - v], g_sub[-1 - v]);
        if (v >= 0 ? ML_TYPE[v] == ML_CUR : -1 - v == cf)
            dk_ui_menu_check(m, (int32_t)r, 1);
    }
}

/* A folder's menu: its machines in the firmware's order. Filled from the scan of the top list, which is open under it. */
static void fill_sub(dk_ui_menu *m, void *arg)
{
    char text[DK_UI_ROW];
    int32_t f = (int32_t)(uintptr_t)arg, k = 0;
    ML_IN = f;
    for (uint32_t i = 0; i < ML_N; i++) {
        if (ML_TF[i] != f)
            continue;
        label(text, dk_fw_machine_name_long(ML_TYPE[i]));
        dk_ui_menu_add_action(m, text, pick, NULL, (int32_t)i);
        if (ML_TYPE[i] == ML_CUR)
            dk_ui_menu_check(m, k, 1);
        k++;
    }
}

/* The row of the top list that shows machine row `i` (its own, or its folder's); -1 when none. */
static int32_t top_row_of(int32_t i)
{
    if (i < 0)
        return -1;
    int32_t want = ML_TF[i] < 0 ? i : -1 - ML_TF[i];
    for (uint32_t r = 0; r < ML_NROW; r++)
        if (ML_ROW[r] == want)
            return (int32_t)r;
    return -1;
}

/* The row of machine row `i` inside its folder. */
static int32_t sub_row_of(int32_t i)
{
    int32_t k = 0;
    for (int32_t j = 0; j < i; j++)
        if (ML_TF[j] == ML_TF[i])
            k++;
    return k;
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
        layout();
        row = top_row_of(row_of(ML_CUR));
    }
    ML_TAB = tab;
    if (off)
        dk_ui_menu_close(off);
    dk_ui_menu_select(on, row < 0 ? 0 : row);
    dk_ui_menu_open(on);
}

/* Opens the folder that holds the track's machine over the top list, with the cursor on the machine. */
static void open_in_folder(void)
{
    int32_t i = row_of(ML_CUR);
    if (i < 0 || ML_TF[i] < 0)
        return;
    dk_ui_menu_select(g_sub[ML_TF[i]], sub_row_of(i));
    dk_ui_menu_open(g_sub[ML_TF[i]]);
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
    ML_IN = -1;
    if (g_filter && dk_fw_page_track_page(settings, track) == 2)
        show(1);
    else {
        if (g_filter)
            show(0);
        else {
            layout();
            int32_t row = top_row_of(row_of(ML_CUR));
            dk_ui_menu_select(g_menu, row < 0 ? 0 : row);
            dk_ui_menu_open(g_menu);
        }
        open_in_folder();
    }
    return 1;
}
