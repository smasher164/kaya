/* Ordered cursor access for the OCaml direct-ring example. OCaml reaches
 * the ring's bytes through a Bigarray without FFI, but has no ordered
 * loads and stores on foreign memory, so these two carry the
 * acquire/release — the recipe ocaml-uring uses for the real io_uring.
 * [@@noalloc] on the OCaml side makes them bare C calls: no runtime-lock
 * traffic, no allocation. */

#include <caml/mlvalues.h>

#include <stdatomic.h>
#include <stdint.h>

CAMLprim value kaya_ml_load_acquire_u32(value addr)
{
    uint32_t v = atomic_load_explicit(
        (_Atomic uint32_t *)Nativeint_val(addr), memory_order_acquire);
    return Val_long(v);
}

CAMLprim value kaya_ml_store_release_u32(value addr, value v)
{
    atomic_store_explicit((_Atomic uint32_t *)Nativeint_val(addr),
                          (uint32_t)Long_val(v), memory_order_release);
    return Val_unit;
}
