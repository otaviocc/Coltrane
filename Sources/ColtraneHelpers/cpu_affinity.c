#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include "ColtraneHelpers.h"

#if defined(__linux__)
#include <pthread.h>
#include <sched.h>

void coltrane_bind_to_core(int logical_id, int core_count) {
    int cpu = logical_id % (core_count > 0 ? core_count : 1);
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &set);
}
#else
void coltrane_bind_to_core(int logical_id, int core_count) {
    (void)logical_id;
    (void)core_count;
}
#endif
