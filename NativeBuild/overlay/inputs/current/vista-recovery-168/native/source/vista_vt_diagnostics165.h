#ifndef VISTA_VT_DIAGNOSTICS165_H
#define VISTA_VT_DIAGNOSTICS165_H
#include <stdint.h>
#include <limits.h>
#include <pthread.h>
#include <time.h>
#include "flow/vista_flow_trace.h"

/* Passive scalars only. CPU time is the submitting thread's CPU time, not
 * decoder worker/GPU time; elapsed minus CPU cannot identify a wait reason. */
enum {
    VVD_API_WALL = 480, /* point: a=start_us, b=end_us, c=OSStatus */
    VVD_API_CPU = 481,  /* point: a=before_ns, b=after_ns, c=thread ID; -1 unknown */
    VVD_CALLBACK_MUTEX = 482, /* point: a=before_lock, b=locked, c=thread ID */
    VVD_CALLBACK_TAIL = 483,  /* point: a=before_free, b=after_finished, c=thread ID */
};

static inline uint64_t vvtd_thread(void)
{
    static _Thread_local uint64_t cached;
    if (!cached) {
        uint64_t value = 0;
        if (pthread_threadid_np(NULL, &value) == 0)
            cached = value;
    }
    return cached; /* 0 means unavailable, never an invented identity. */
}

static inline int64_t vvtd_cpu_ns(void)
{
    struct timespec value;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) != 0 ||
        value.tv_sec < 0 || value.tv_nsec < 0 || value.tv_nsec >= 1000000000 ||
        value.tv_sec > (INT64_MAX - value.tv_nsec) / INT64_C(1000000000))
        return -1;
    return value.tv_sec * INT64_C(1000000000) + value.tv_nsec;
}

static inline void vvtd_api_emit(uint64_t id, int64_t begin, int64_t end,
                                int64_t cpu_before, int64_t cpu_after,
                                uint64_t thread, int status)
{
    if (!id) return;
    VFEmit(id, VVD_API_WALL, VF_POINT, end, begin, end, status);
    VFEmit(id, VVD_API_CPU, VF_POINT, end, cpu_before, cpu_after, thread);
}

static inline void vvtd_callback_emit(uint64_t id, uint64_t thread,
                                     int64_t lock_begin, int64_t locked,
                                     int64_t tail_begin, int64_t finished)
{
    if (!id) return;
    /* Emit after releasing both locks/credits, never extend the mutex section. */
    VFEmit(id, VVD_CALLBACK_MUTEX, VF_POINT, locked, lock_begin, locked, thread);
    VFEmit(id, VVD_CALLBACK_TAIL, VF_POINT, finished, tail_begin, finished, thread);
}
#endif
