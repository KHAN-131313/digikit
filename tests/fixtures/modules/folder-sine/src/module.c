/* test/folder-sine: two machines on test/sine's DSP body in the folder TEST, for core/machine-list's folder rows. */
#include <dk/core/module.h>
#include "module_ids.h"

static void sine(dk_module_ctx *ctx, uint32_t id, const char *name, const char *tab)
{
    dk_machine *m = dk_module_ctx_add_machine(ctx, id, name, tab);
    dk_page *p = dk_machine_add_page(m, name, tab);
    dk_page_add_param(p, "Level", "LEVEL", 127);
}

static int32_t init(dk_module_ctx *ctx)
{
    dk_module_ctx_folder(ctx, "Test");
    sine(ctx, DK_MACHINE_ID_FSA, "Sine A", "SNA");
    sine(ctx, DK_MACHINE_ID_FSB, "Sine B", "SNB");
    return DK_OK;
}

const dk_module_def dk_module = {.init = init};
