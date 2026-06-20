//
//  RTAtomics.h
//  Minimal acquire/release atomics for the lock-free SPSC ring buffer.
//
//  We deliberately avoid Swift's `Synchronization.Atomic` (macOS 15+) so the
//  deployment target can stay at macOS 14.2. These are plain `int64_t` loads
//  and stores with explicit memory ordering — safe to call from the real-time
//  Core Audio IO thread (no allocation, no locks, no ObjC/Swift runtime).
//

#ifndef RTAtomics_h
#define RTAtomics_h

#include <stdint.h>

static inline int64_t rt_atomic_load_acquire(const volatile int64_t *p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

static inline void rt_atomic_store_release(volatile int64_t *p, int64_t v) {
    __atomic_store_n(p, v, __ATOMIC_RELEASE);
}

#endif /* RTAtomics_h */
