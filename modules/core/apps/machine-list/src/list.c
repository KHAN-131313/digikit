/* core/machine-list: the machine list that digikit owns, in place of the firmware's Machine Selection view.
 * Plan: docs/plans/machine-list.md. Facts: docs/findings/131 and 132.
 *
 * An app (docs/ARCHITECTURE.md): core/ui owns the firmware side. Where the firmware shows its Machine Selection view (FUNC + SRC on
 * the Digitakt II, FUNC + SYN on the Digitone II) core/ui calls dk_app_machine_list_open, which opens this list and returns 1;
 * when the list cannot be made it returns 0 and core/ui shows the stock view. The firmware's lists, names, the track's machine
 * and filter and their setters come from core/ui (dk_ui_core.h).
 *
 * The list is a plain core/ui menu, filled at every open from the firmware's machine list (its order; core/dynreg leaves out
 * unfilled run-time types): one row per machine, the track's machine marked and under the cursor. YES on a row sets that
 * machine for the selected track: the mark moves and the list stays open. YES on the marked row closes the list (the stock
 * view's rule). NO closes it.
 *
 * Folders: a module may name a folder for its machines (dk_module_ctx_folder) and each machine a folder below it
 * (dk_machine_folder, for example "Machinedrum (MD)" and "EFM"); the runtime gives the path per machine type (dkrt_machine_folder).
 * The folders form a tree: a menu lists its machines, then a row per folder in it that holds a machine; YES on a folder row opens
 * the folder's menu, NO goes up one level. A name may end in a short form in parentheses: the row shows the name ("MACHINEDRUM"),
 * the menu's title the short form ("MD"), as the title bar holds about eight characters. Modules that name the same path share the folder. A folder row
 * is marked when the track's machine is in it at any depth, and the list opens down to the machine. At most ML_FOLDERS folders
 * (menus are never freed); the machines of a folder past that stay at the top.
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
#include "dkrt.h"

#define ML_MAX 40
#define ML_FOLDERS 16
#define ML_FPATH                                                                                   \
    32 /* a folder path with its NUL: the module's folder, then the machine's (dkrt_machine_folder) */

/* The rows of the list as it was last filled: the machine type of each row, their number, the track they are for and the
   track's machine (-1: none). ML_OPENS counts the opens, ML_LAST is the last type a row committed (-1: none). */
int32_t ML_TYPE[ML_MAX];
uint32_t ML_N;
int32_t ML_TRACK;
int32_t ML_CUR = -1;
uint32_t ML_OPENS;
int32_t ML_LAST = -1;
/* Folders form a tree. ML_TF: the folder slot of each row of ML_TYPE (-1: at the top). ML_FOLDER: the path of each slot in upper
   case ("MACHINEDRUM/EFM"; every parent has its own slot), ML_PARENT: its parent's slot (-1: at the top), ML_NF: the slots in use.
   ML_ROW / ML_NROW: the rows of the menu laid out last (layout): >= 0 a row of ML_TYPE, < 0 a folder slot (-1 - slot). */
int32_t ML_TF[ML_MAX];
char ML_FOLDER[ML_FOLDERS][ML_FPATH];
int32_t ML_PARENT[ML_FOLDERS];
uint32_t ML_NF;
/* Each folder's menu title: the short form of its last name when it has one ("MACHINEDRUM (MD)" -> "MD"), else the name, cut to
   ML_TITLE_MAX characters (what the title bar holds next to the rows). */
#define ML_TITLE_MAX 8
static char g_title[ML_FOLDERS][ML_TITLE_MAX + 1];
int32_t ML_ROW[ML_MAX + ML_FOLDERS];
uint32_t ML_NROW;
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
static dk_ui_menu *g_sub[ML_FOLDERS];
static dk_ui_menu_desc g_sub_desc[ML_FOLDERS];
static void fill_sub(dk_ui_menu *m, void *arg);

/* The last name of a folder path: the folder's title. */
static const char *leaf(const char *path)
{
    const char *l = path;
    for (; *path; path++)
        if (*path == '/')
            l = path + 1;
    return l;
}

/* A folder name's parts: "MACHINEDRUM (MD)" is the row label MACHINEDRUM with the short form MD; a name without " (...)" at its
   end is its own label. Writes the label (at most DK_UI_ROW - 1 characters) and returns the short form's start (0: none). */
static const char *name_parts(const char *name, char *label)
{
    uint32_t n = 0;
    while (name[n])
        n++;
    uint32_t open = n;
    if (n >= 4 && name[n - 1] == ')')
        for (uint32_t i = n - 1; i > 0; i--)
            if (name[i] == '(') {
                if (name[i - 1] == ' ' && i + 1 < n - 1)
                    open = i - 1;
                break;
            }
    uint32_t k = 0;
    for (; k < open && k + 1 < DK_UI_ROW; k++)
        label[k] = name[k];
    label[k] = 0;
    return open < n ? name + open + 2 : 0;
}

/* The menu title of folder slot f (g_title[f]). */
static void make_title(uint32_t f)
{
    char label[DK_UI_ROW];
    const char *shrt = name_parts(leaf(ML_FOLDER[f]), label);
    const char *from = shrt ? shrt : label;
    uint32_t k = 0;
    for (; from[k] && from[k] != ')' && k < ML_TITLE_MAX; k++)
        g_title[f][k] = from[k];
    g_title[f][k] = 0;
}

/* The slot of the folder `path` (its first n characters, upper case); a new folder gets a slot, and so do its parents, and a menu
   titled with its last name. -1 when no slot is left or the menu cannot be made. Menus are never freed: a slot lives for the boot. */
static int32_t slot_of(const char *path, int32_t n)
{
    for (uint32_t f = 0; f < ML_NF; f++) {
        int32_t i = 0;
        while (i < n && ML_FOLDER[f][i] == path[i])
            i++;
        if (i == n && ML_FOLDER[f][n] == 0)
            return (int32_t)f;
    }
    int32_t cut = n;
    while (cut > 0 && path[cut - 1] != '/')
        cut--;
    int32_t parent = cut > 1 ? slot_of(path, cut - 1) : -1;
    if ((cut > 1 && parent < 0) || ML_NF >= ML_FOLDERS || !g_ui)
        return -1;
    uint32_t f = ML_NF;
    for (int32_t i = 0; i < n; i++)
        ML_FOLDER[f][i] = path[i];
    ML_FOLDER[f][n] = 0;
    ML_PARENT[f] = parent;
    g_sub_desc[f].name = "MachineListFolder";
    make_title(f);
    g_sub_desc[f].title = g_title[f];
    g_sub_desc[f].flags = 0;
    g_sub_desc[f].fill = fill_sub;
    g_sub_desc[f].arg = (void *)(uintptr_t)f;
    g_sub[f] = dk_ui_menu_new(g_ui, &g_sub_desc[f]);
    if (!g_sub[f])
        return -1;
    ML_NF++;
    return (int32_t)f;
}

/* The folder slot of machine type `type`: -1 when its module names no folder (or no slot is left). */
static int32_t folder_of(int32_t type)
{
    char path[ML_FPATH];
    int32_t n = dkrt_machine_folder((uint32_t)type, (uint8_t *)path, ML_FPATH);
    if (n <= 0)
        return -1;
    for (int32_t i = 0; i < n; i++)
        if (path[i] >= 'a' && path[i] <= 'z')
            path[i] = (char)(path[i] - 32);
    return slot_of(path, n);
}

/* 1 when folder f is folder g or inside it (g -1: the top holds everything). */
static int32_t within(int32_t f, int32_t g)
{
    for (; f >= 0; f = ML_PARENT[f])
        if (f == g)
            return 1;
    return g < 0;
}

static dk_ui_menu *menu_of(int32_t g)
{
    return g < 0 ? g_menu : g_sub[g];
}

/* Reads the machine list and the track's machine into the ML_ globals. */
static void scan(void)
{
    int32_t t[ML_MAX];
    uint32_t n = dk_ui_machine_types(t, ML_MAX);
    ML_TRACK = dk_ui_track();
    ML_CUR = dk_ui_track_machine();
    ML_N = 0;
    for (uint32_t i = 0; i < n; i++) {
        const char *name = dk_ui_machine_name(t[i]);
        if (name && name[0]) {
            ML_TF[ML_N] = folder_of(t[i]);
            ML_TYPE[ML_N++] = t[i];
        }
    }
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
    int32_t t[ML_MAX];
    uint32_t n = dk_ui_filter_types(t, ML_MAX);
    ML_FCUR = dk_ui_track_filter();
    ML_FN = 0;
    for (uint32_t i = 0; i < n; i++) {
        const char *name = dk_ui_filter_name(t[i]);
        if (name && name[0])
            ML_FTYPE[ML_FN++] = t[i];
    }
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
    dk_ui_set_track_filter(filter);
    ML_FLAST = filter;
    ML_FCUR = dk_ui_track_filter();
    for (uint32_t i = 0; i < ML_FN; i++)
        dk_ui_menu_check(g_filter, (int32_t)i, ML_FTYPE[i] == ML_FCUR);
}

/* The folder slot of the track's machine (-1: at the top, or not in the list). */
static int32_t cur_folder(void)
{
    int32_t i = row_of(ML_CUR);
    return i < 0 ? -1 : ML_TF[i];
}

/* 1 when row v of a menu (layout's encoding) carries the mark: the track's machine, or a folder that holds it at any depth. */
static int32_t marked(int32_t v)
{
    if (v >= 0)
        return ML_TYPE[v] == ML_CUR;
    int32_t cf = cur_folder();
    return cf >= 0 && within(cf, -1 - v);
}

static void layout(int32_t g, int32_t rescan);

/* The marks of the top list and of every open folder. */
static void marks(void)
{
    for (int32_t g = -1; g < (int32_t)ML_NF; g++) {
        if (g >= 0 && !dk_ui_menu_is_open(g_sub[g]))
            continue;
        layout(g, 0);
        for (uint32_t r = 0; r < ML_NROW; r++)
            dk_ui_menu_check(menu_of(g), (int32_t)r, marked(ML_ROW[r]));
    }
}

/* Closes the open folders, the deepest first, then the top list. */
static void close_all(void)
{
    for (int32_t more = 1; more;) {
        more = 0;
        for (uint32_t f = 0; f < ML_NF; f++) {
            if (!dk_ui_menu_is_open(g_sub[f]))
                continue;
            int32_t child_open = 0;
            for (uint32_t c = 0; c < ML_NF; c++)
                if (ML_PARENT[c] == (int32_t)f && dk_ui_menu_is_open(g_sub[c]))
                    child_open = 1;
            if (!child_open) {
                dk_ui_menu_close(g_sub[f]);
                more = 1;
            }
        }
    }
    dk_ui_menu_close(g_menu);
}

static void pick(void *arg, int32_t row)
{
    (void)arg;
    if (row < 0 || (uint32_t)row >= ML_N)
        return;
    int32_t type = ML_TYPE[row];
    if (type == ML_CUR) { /* YES on the marked machine closes the list */
        close_all();
        return;
    }
    dk_ui_set_track_machine(type);
    ML_LAST = type;
    ML_CUR = dk_ui_track_machine();
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
    if (dk_ui_track_is_midi()) { /* the stock view's words */
        ML_FN = 0;
        dk_ui_menu_add_text(m, "NO FILTERS ON");
        dk_ui_menu_add_text(m, "MIDI TRACKS.");
        return;
    }
    scan_filters();
    for (uint32_t i = 0; i < ML_FN; i++) {
        label(text, dk_ui_filter_name(ML_FTYPE[i]));
        dk_ui_menu_add_action(m, text, pick_filter, NULL, (int32_t)i);
        if (ML_FTYPE[i] == ML_FCUR)
            dk_ui_menu_check(m, (int32_t)i, 1);
    }
}

/* 1 when folder g holds a loaded machine at any depth. */
static int32_t holds(int32_t g)
{
    for (uint32_t i = 0; i < ML_N; i++)
        if (ML_TF[i] >= 0 && within(ML_TF[i], g))
            return 1;
    return 0;
}

/* Lays out the menu of folder g (-1: the top list) into ML_ROW: its machines in the firmware's order, then one row per folder in
   it that holds a machine. `rescan` reads the machine list first (the top list does; a folder opens over it and uses that scan). */
static void layout(int32_t g, int32_t rescan)
{
    if (rescan)
        scan();
    ML_NROW = 0;
    for (uint32_t i = 0; i < ML_N; i++)
        if (ML_TF[i] == g)
            ML_ROW[ML_NROW++] = (int32_t)i;
    for (uint32_t f = 0; f < ML_NF; f++)
        if (ML_PARENT[f] == g && holds((int32_t)f))
            ML_ROW[ML_NROW++] = -1 - (int32_t)f;
}

static void fill_rows(dk_ui_menu *m, int32_t g, int32_t rescan)
{
    char text[DK_UI_ROW];
    layout(g, rescan);
    for (uint32_t r = 0; r < ML_NROW; r++) {
        int32_t v = ML_ROW[r];
        if (v >= 0) {
            label(text, dk_ui_machine_name(ML_TYPE[v]));
            dk_ui_menu_add_action(m, text, pick, NULL, v);
        } else {
            name_parts(leaf(ML_FOLDER[-1 - v]), text);
            dk_ui_menu_add_folder(m, text, g_sub[-1 - v]);
        }
        if (marked(v))
            dk_ui_menu_check(m, (int32_t)r, 1);
    }
}

static void fill(dk_ui_menu *m, void *arg)
{
    (void)arg;
    fill_rows(m, -1, 1);
}

/* A folder's menu. */
static void fill_sub(dk_ui_menu *m, void *arg)
{
    fill_rows(m, (int32_t)(uintptr_t)arg, 0);
}

/* The row of folder g's menu (-1: the top list) that leads to machine row i: its own row, or the row of the folder in g on the way
   to it; -1 when none. */
static int32_t row_in(int32_t g, int32_t i)
{
    if (i < 0)
        return -1;
    int32_t want = i;
    if (ML_TF[i] != g) {
        int32_t f = ML_TF[i];
        while (f >= 0 && ML_PARENT[f] != g)
            f = ML_PARENT[f];
        if (f < 0)
            return -1;
        want = -1 - f;
    }
    layout(g, 0);
    for (uint32_t r = 0; r < ML_NROW; r++)
        if (ML_ROW[r] == want)
            return (int32_t)r;
    return -1;
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
        layout(-1, 1);
        row = row_in(-1, row_of(ML_CUR));
    }
    ML_TAB = tab;
    if (off)
        dk_ui_menu_close(off);
    dk_ui_menu_select(on, row < 0 ? 0 : row);
    dk_ui_menu_open(on);
}

/* Opens the folders down to the track's machine over the top list, each with the cursor on the row that leads on, the last on the
   machine. */
static void open_in_folder(void)
{
    int32_t i = row_of(ML_CUR);
    if (i < 0 || ML_TF[i] < 0)
        return;
    int32_t chain[ML_FOLDERS], n = 0;
    for (int32_t f = ML_TF[i]; f >= 0 && n < ML_FOLDERS; f = ML_PARENT[f])
        chain[n++] = f;
    while (n-- > 0) {
        int32_t row = row_in(chain[n], i);
        dk_ui_menu_select(g_sub[chain[n]], row < 0 ? 0 : row);
        dk_ui_menu_open(g_sub[chain[n]]);
    }
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

int32_t dk_app_machine_list_open(void)
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
        return 0; /* core/ui shows the stock view */
    /* the stock view opens on its filter page when the track shows its filter page */
    if (g_filter && dk_ui_track_on_filter_page())
        show(1);
    else {
        if (g_filter)
            show(0);
        else {
            layout(-1, 1);
            int32_t row = row_in(-1, row_of(ML_CUR));
            dk_ui_menu_select(g_menu, row < 0 ? 0 : row);
            dk_ui_menu_open(g_menu);
        }
        open_in_folder();
    }
    return 1;
}
