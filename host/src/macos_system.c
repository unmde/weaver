#include "macos_system.h"

#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/mach_time.h>
#include <mach/processor_info.h>
#include <mach/vm_statistics.h>
#include <signal.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <servers/bootstrap.h>

#include "../../runtime/native-sdk/src/platform/macos/renderer_protocol_mach.h"

int weaver_system_sample(uint32_t *ticks, size_t core_capacity, size_t *core_count,
                         uint64_t *used_bytes, uint64_t *total_bytes) {
    if (!ticks || !core_count || !used_bytes || !total_bytes) return -1;
    natural_t processor_count = 0;
    processor_info_array_t processor_info = NULL;
    mach_msg_type_number_t processor_info_count = 0;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                            &processor_count, &processor_info,
                            &processor_info_count) != KERN_SUCCESS) return -1;

    const size_t count = processor_count < core_capacity ? processor_count : core_capacity;
    const processor_cpu_load_info_t loads = (processor_cpu_load_info_t)processor_info;
    for (size_t core = 0; core < count; core++) {
        for (size_t state = 0; state < WEAVER_CPU_STATE_COUNT; state++) {
            ticks[core * WEAVER_CPU_STATE_COUNT + state] = loads[core].cpu_ticks[state];
        }
    }
    vm_deallocate(mach_task_self(), (vm_address_t)processor_info,
                  processor_info_count * sizeof(integer_t));

    uint64_t total = 0;
    size_t total_size = sizeof(total);
    vm_statistics64_data_t statistics = {0};
    mach_msg_type_number_t statistics_count = HOST_VM_INFO64_COUNT;
    vm_size_t page_size = 0;
    if (sysctlbyname("hw.memsize", &total, &total_size, NULL, 0) != 0 || total == 0 ||
        host_statistics64(mach_host_self(), HOST_VM_INFO64,
                          (host_info64_t)&statistics, &statistics_count) != KERN_SUCCESS ||
        host_page_size(mach_host_self(), &page_size) != KERN_SUCCESS || page_size == 0) return -1;
    const uint64_t reclaimable_pages = statistics.free_count + statistics.inactive_count;
    const uint64_t reclaimable = reclaimable_pages > total / page_size
        ? total : reclaimable_pages * page_size;
    *core_count = count;
    *total_bytes = total;
    *used_bytes = total - reclaimable;
    return 0;
}

int weaver_process_sample(int32_t pid, uint64_t *physical_footprint,
                          uint64_t *cpu_time_ns, uint32_t *threads) {
    if (!physical_footprint || !cpu_time_ns || !threads) return -1;
    struct rusage_info_v4 usage;
    struct proc_taskinfo task;
    mach_timebase_info_data_t timebase;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) return -1;
    if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) != sizeof(task)) return -1;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) return -1;
    *physical_footprint = usage.ri_phys_footprint;
    // proc_pid_rusage reports Mach absolute-time ticks, not nanoseconds.
    // Widen before scaling so a long-running process cannot overflow the product.
    const __uint128_t cpu_ticks = (__uint128_t)usage.ri_user_time + usage.ri_system_time;
    *cpu_time_ns = (uint64_t)(cpu_ticks * timebase.numer / timebase.denom);
    *threads = task.pti_threadnum < 0 ? 0 : (uint32_t)task.pti_threadnum;
    return 0;
}

int weaver_process_path(int32_t pid, char *path, size_t capacity) {
    if (!path || capacity == 0) return -1;
    return proc_pidpath(pid, path, (uint32_t)capacity);
}

void weaver_renderer_readiness_reset(uint32_t *reply_port) {
    if (!reply_port || *reply_port == MACH_PORT_NULL) return;
    mach_port_mod_refs(mach_task_self(), *reply_port, MACH_PORT_RIGHT_RECEIVE, -1);
    *reply_port = MACH_PORT_NULL;
}

int weaver_renderer_readiness_poll(const char *name, size_t name_len, uint32_t *reply_port) {
    if (!name || !reply_port || name_len == 0 || name_len >= BOOTSTRAP_MAX_NAME_LEN) return KERN_INVALID_ARGUMENT;
    if (*reply_port == MACH_PORT_NULL) {
        char service_name[BOOTSTRAP_MAX_NAME_LEN];
        memcpy(service_name, name, name_len);
        service_name[name_len] = '\0';
        mach_port_t service = MACH_PORT_NULL;
        kern_return_t result = bootstrap_look_up(bootstrap_port, service_name, &service);
        if (result == BOOTSTRAP_UNKNOWN_SERVICE) return WEAVER_RENDERER_WAITING;
        if (result != KERN_SUCCESS) return result;
        result = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, reply_port);
        if (result != KERN_SUCCESS) {
            mach_port_deallocate(mach_task_self(), service);
            return result;
        }
        WeaverRendererMachHello hello = {0};
        hello.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
        hello.header.msgh_remote_port = service;
        hello.header.msgh_local_port = *reply_port;
        hello.header.msgh_size = sizeof(hello);
        hello.header.msgh_id = kWeaverRendererMachMsgHello;
        hello.magic = kWeaverRendererMachMagic;
        hello.version = kWeaverRendererMachVersion;
        hello.struct_size = sizeof(hello);
        hello.widget_pid = (uint32_t)getpid();
        // A zero timeout means poll, not a startup deadline. Even an occupied
        // service queue cannot block provider delivery or the down command.
        result = mach_msg(&hello.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(hello), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
        mach_port_deallocate(mach_task_self(), service);
        if (result != KERN_SUCCESS) {
            mach_msg_destroy(&hello.header);
            weaver_renderer_readiness_reset(reply_port);
            return result == MACH_SEND_TIMED_OUT ? WEAVER_RENDERER_WAITING : result;
        }
    }
    struct { WeaverRendererMachHelloReply reply; mach_msg_trailer_t trailer; } message = {0};
    kern_return_t result = mach_msg(&message.reply.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(message), *reply_port, 0, MACH_PORT_NULL);
    if (result == MACH_RCV_TIMED_OUT) return WEAVER_RENDERER_WAITING;
    weaver_renderer_readiness_reset(reply_port);
    if (result != KERN_SUCCESS) return result;
    const WeaverRendererMachHelloReply *reply = &message.reply;
    const bool valid = reply->header.msgh_size == sizeof(*reply) &&
        (reply->header.msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0 &&
        reply->magic == kWeaverRendererMachMagic && reply->version == kWeaverRendererMachVersion &&
        reply->status == kWeaverRendererMachStatusOk && reply->body.msgh_descriptor_count == 1 &&
        reply->session_port.type == MACH_MSG_PORT_DESCRIPTOR &&
        reply->session_port.disposition == MACH_MSG_TYPE_PORT_SEND &&
        MACH_PORT_VALID(reply->session_port.name);
    // Readiness does not render: release the returned session immediately.
    // Native's no-senders handler reclaims it without allocating a renderer.
    mach_msg_destroy(&message.reply.header);
    return valid ? WEAVER_RENDERER_READY : KERN_INVALID_ARGUMENT;
}

int weaver_secure_private_dir(const char *path) {
    if (!path) return -1;
    struct stat info;
    if (lstat(path, &info) != 0) return -1;
    if (!S_ISDIR(info.st_mode)) return -1;
    if (info.st_uid != getuid()) return -1;
    if (chmod(path, 0700) != 0) return -1;
    if (lstat(path, &info) != 0) return -1;
    if ((info.st_mode & 0777) != 0700) return -1;
    return 0;
}

static volatile sig_atomic_t weaver_termination_flag = 0;

static void weaver_handle_termination(int signal_number) {
    (void)signal_number;
    weaver_termination_flag = 1;
}

int weaver_install_termination_handler(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = weaver_handle_termination;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) != 0) return -1;
    if (sigaction(SIGINT, &action, NULL) != 0) return -1;
    return 0;
}

int weaver_termination_requested(void) {
    return weaver_termination_flag != 0;
}
