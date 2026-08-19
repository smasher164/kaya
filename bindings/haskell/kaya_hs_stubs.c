/* Ordered cursor access for the Haskell direct-ring example. GHC's own
 * Addr# atomics are the wrong shape for this; DESIGN.md's milestone-0
 * note has the reasons. */

#include <stdatomic.h>
#include <stdint.h>

uint32_t kaya_hs_load_acquire_u32(const uint32_t *p)
{
    return atomic_load_explicit((const _Atomic uint32_t *)p,
                                memory_order_acquire);
}

void kaya_hs_store_release_u32(uint32_t *p, uint32_t v)
{
    atomic_store_explicit((_Atomic uint32_t *)p, v, memory_order_release);
}
