/* Ordered cursor access for the Haskell direct-ring example. Plain peeks
 * inline to real loads on the data path. GHC does have Addr# atomics,
 * but not at this shape: atomic read/write exist only Word-sized (a
 * 64-bit access against the producer's 4-byte AtomicU32 is mixed-size,
 * outside the C11 model), the 32-bit primop is CAS only (an RMW per
 * access), and all of them are full-barrier with no acquire/release
 * grading. These two are the right width and the exact ordering;
 * `foreign import ccall unsafe` makes them bare C calls. */

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
