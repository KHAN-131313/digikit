/* core/machine-list (SPIKE): a machine list that digikit owns, in place of the firmware's Machine Selection view.
 *
 * It answers two questions (docs/findings/131-dn2-machine-sel-open-and-commit.md):
 *   1. can a core/ui list open where FUNC + SYN opens the stock view (the push call at the end of that key case)?
 *   2. does the stock commit, called from the list's row action, set the track's machine as the stock YES does?
 *
 * ml_push takes the place of the stock push at that one call site: same arguments (the view manager, the shared_ptr of the
 * stock view, replace), same result. It opens the list and leaves the stock view unpushed; when the list cannot be made it
 * calls the stock push, so the stock view still opens.
 *
 * The list is filled at every open: one row per machine type that has a name (stock types and filled run-time rows), in
 * type order. YES on a row commits that type for the selected track and closes the list.
 * The globals without static are read by the proof by name. */
#include <stdint.h>
#include <stddef.h>
#include <dk/platform/ui.h>
#include <dk_ui_core.h>
#include <dk_fw_page.h>
#include <dk_fw_project.h>
#include <dk_fw_view.h>

/* SPIKE: declared here, not through `sig` in devices/fw, so that the generated Rust bindings (and with them the committed core
   objects) stay as they are. The real module declares them in devices/fw. */
const char *dk_fw_machine_name_long(int32_t type) __asm__("cf.machine.fn.name.long");
void dk_fw_project_set_track_type(uint32_t kit, int32_t track, int32_t type, int32_t a, int32_t b)
    __asm__("cf.project.fn.set_track_type");
uint32_t dk_fw_view_push_shared(uint32_t manager, const shared_ptr *sp, uint32_t replace) __asm__("cf.view.fn.push_shared");

#define ML_TYPES 24

/* How often the hook ran and the last type a row committed (-1: none). */
uint32_t ML_OPENS;
int32_t ML_LAST = -1;

static dk_ui *g_ui;
static dk_ui_menu *g_menu;

static void pick(void *arg, int32_t type)
{
    (void)arg;
    uint32_t project = dk_fw_project_singleton();
    uint32_t kit = dk_fw_project_active_kit(project);
    int32_t track = (int32_t)dk_fw_page_view_track((const uint8_t *)dk_fw_project_settings(project));
    ML_LAST = type;
    dk_fw_project_set_track_type(kit, track, type, 1, 1);
    dk_ui_menu_close(g_menu);
}

static void fill(dk_ui_menu *m, void *arg)
{
    (void)arg;
    for (int32_t type = 0; type < ML_TYPES; type++) {
        const char *name = dk_fw_machine_name_long(type);
        if (name && name[0])
            dk_ui_menu_add_action(m, name, pick, NULL, type);
    }
}

static const dk_ui_menu_desc desc = {.name = "MachineList", .title = "MACHINES", .flags = 0, .fill = fill};

uint32_t ml_push(uint32_t manager, const shared_ptr *view, uint32_t replace)
{
    ML_OPENS++;
    if (!g_menu) {
        g_ui = dk_ui_core_handle();
        if (g_ui)
            g_menu = dk_ui_menu_new(g_ui, &desc);
    }
    if (!g_menu)
        return dk_fw_view_push_shared(manager, view, replace);
    dk_ui_menu_refresh(g_menu);
    dk_ui_menu_open(g_menu);
    return 1;
}
