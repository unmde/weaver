#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    WEAVER_CPU_STATE_COUNT = 4,
    WEAVER_CPU_STATE_IDLE = 2,
    WEAVER_PROCESS_PATH_CAPACITY = 4096,
};

int weaver_system_sample(uint32_t *ticks, size_t core_capacity, size_t *core_count,
                         uint64_t *used_bytes, uint64_t *total_bytes);
int weaver_process_sample(int32_t pid, uint64_t *physical_footprint,
                          uint64_t *cpu_time_ns, uint32_t *threads);
int weaver_process_path(int32_t pid, char *path, size_t capacity);
enum { WEAVER_RENDERER_READY = 0, WEAVER_RENDERER_WAITING = -1 };
// Nonblocking hello to the shared renderer. Other results are Mach/bootstrap
// errors. A pending receive right belongs to the caller until reset or reply.
int weaver_renderer_readiness_poll(const char *name, size_t name_len, uint32_t *reply_port);
void weaver_renderer_readiness_reset(uint32_t *reply_port);
int weaver_secure_private_dir(const char *path);
int weaver_install_termination_handler(void);
int weaver_termination_requested(void);

#include "macos_media.h"

#ifdef __cplusplus
}
#endif
