| core/machine-list: the assembly shim. ColdFire, gas syntax, mcpu=54418.
|
| ml_get_list(out): the firmware's machine list getter returns a std::vector<int> through a pointer in a0 and takes no
|   stack arguments (finding 131); this adapts the cdecl call from C. `out` is three words: begin, end, capacity end. The
|   caller frees `begin` with the firmware's delete. core/dynreg's filter runs inside the getter, so the list holds the stock
|   types and the run-time types that have a name, in the firmware's order.
    .text
    .globl ml_get_list
ml_get_list:
    move.l  4(%sp),%a0
    jmp     cf.machine.fn.list.entry

| ml_get_filters(out): the same for the filter type list (the stock view's second page).
    .globl ml_get_filters
ml_get_filters:
    move.l  4(%sp),%a0
    jmp     cf.machine.fn.filter.list
