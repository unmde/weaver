#include "macos_system.h"
#include "../../runtime/native-sdk/src/platform/macos/renderer_protocol_mach.h"
#include <servers/bootstrap.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define REQUIRE(expression) do { \
    if (!(expression)) { \
        fprintf(stderr, "renderer readiness regression failed at line %d: %s\n", __LINE__, #expression); \
        return 1; \
    } \
} while (0)

static size_t port_name_count(void) {
    mach_port_name_array_t names = NULL;
    mach_port_type_array_t types = NULL;
    mach_msg_type_number_t name_count = 0, type_count = 0;
    if (mach_port_names(mach_task_self(), &names, &name_count, &types, &type_count) != KERN_SUCCESS) return SIZE_MAX;
    vm_deallocate(mach_task_self(), (vm_address_t)names, name_count * sizeof(*names));
    vm_deallocate(mach_task_self(), (vm_address_t)types, type_count * sizeof(*types));
    return name_count;
}

int weaver_test_renderer_readiness(void) {
    char name[BOOTSTRAP_MAX_NAME_LEN];
    snprintf(name, sizeof(name), "com.weaver.readiness-test.%d", getpid());
    mach_port_t service = MACH_PORT_NULL;
    uint32_t probe = MACH_PORT_NULL;
    REQUIRE(weaver_renderer_readiness_poll(name, strlen(name), &probe) == WEAVER_RENDERER_WAITING);
    REQUIRE(probe == MACH_PORT_NULL);
    REQUIRE(bootstrap_check_in(bootstrap_port, name, &service) == KERN_SUCCESS);

    for (int malformed = 0; malformed < 2; malformed++) {
        // Service registration happens before Metal startup. Only a reply
        // from the running message loop makes this service ready.
        REQUIRE(weaver_renderer_readiness_poll(name, strlen(name), &probe) == WEAVER_RENDERER_WAITING);
        REQUIRE(probe != MACH_PORT_NULL);
        REQUIRE(weaver_renderer_readiness_poll(name, strlen(name), &probe) == WEAVER_RENDERER_WAITING);
        struct { WeaverRendererMachHello hello; mach_msg_trailer_t trailer; } request = {0};
        REQUIRE(mach_msg(&request.hello.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(request), service, 0, MACH_PORT_NULL) == KERN_SUCCESS);
        REQUIRE(weaverRendererMachHelloValid(&request.hello));
        mach_port_t session = MACH_PORT_NULL;
        REQUIRE(mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &session) == KERN_SUCCESS);
        WeaverRendererMachHelloReply reply = {0};
        reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0) | MACH_MSGH_BITS_COMPLEX;
        reply.header.msgh_remote_port = request.hello.header.msgh_remote_port;
        reply.header.msgh_size = sizeof(reply);
        reply.body.msgh_descriptor_count = 1;
        reply.session_port.name = session;
        reply.session_port.disposition = MACH_MSG_TYPE_MAKE_SEND;
        reply.session_port.type = MACH_MSG_PORT_DESCRIPTOR;
        reply.magic = kWeaverRendererMachMagic;
        reply.version = kWeaverRendererMachVersion + malformed;
        reply.status = kWeaverRendererMachStatusOk;
        REQUIRE(mach_msg(&reply.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(reply), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL) == KERN_SUCCESS);
        REQUIRE(weaver_renderer_readiness_poll(name, strlen(name), &probe) == (malformed ? KERN_INVALID_ARGUMENT : WEAVER_RENDERER_READY));
        REQUIRE(probe == MACH_PORT_NULL);
        // Both accepted and rejected replies must release the session right.
        mach_port_status_t status;
        mach_msg_type_number_t count = MACH_PORT_RECEIVE_STATUS_COUNT;
        REQUIRE(mach_port_get_attributes(mach_task_self(), session, MACH_PORT_RECEIVE_STATUS, (mach_port_info_t)&status, &count) == KERN_SUCCESS);
        REQUIRE(status.mps_srights == 0);
        REQUIRE(mach_port_destroy(mach_task_self(), session) == KERN_SUCCESS);
    }
    // A busy service must neither block supervision nor leak the send-once
    // reply right returned by Mach's failed-send pseudo-receive.
    REQUIRE(mach_port_insert_right(mach_task_self(), service, service, MACH_MSG_TYPE_MAKE_SEND) == KERN_SUCCESS);
    mach_port_status_t service_status;
    mach_msg_type_number_t service_count = MACH_PORT_RECEIVE_STATUS_COUNT;
    REQUIRE(mach_port_get_attributes(mach_task_self(), service, MACH_PORT_RECEIVE_STATUS, (mach_port_info_t)&service_status, &service_count) == KERN_SUCCESS);
    for (mach_port_msgcount_t i = 0; i < service_status.mps_qlimit; i++) {
        mach_msg_header_t filler = {0};
        filler.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
        filler.msgh_remote_port = service;
        filler.msgh_size = sizeof(filler);
        REQUIRE(mach_msg(&filler, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(filler), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL) == KERN_SUCCESS);
    }
    const size_t before = port_name_count();
    REQUIRE(before != SIZE_MAX);
    REQUIRE(weaver_renderer_readiness_poll(name, strlen(name), &probe) == WEAVER_RENDERER_WAITING);
    REQUIRE(probe == MACH_PORT_NULL);
    REQUIRE(port_name_count() == before);
    for (mach_port_msgcount_t i = 0; i < service_status.mps_qlimit; i++) {
        struct { mach_msg_header_t header; mach_msg_trailer_t trailer; } filler = {0};
        REQUIRE(mach_msg(&filler.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(filler), service, 0, MACH_PORT_NULL) == KERN_SUCCESS);
        mach_msg_destroy(&filler.header);
    }
    REQUIRE(mach_port_deallocate(mach_task_self(), service) == KERN_SUCCESS);
    REQUIRE(weaver_renderer_readiness_poll(name, strlen(name), &probe) == WEAVER_RENDERER_WAITING);
    const mach_port_t pending = probe;
    weaver_renderer_readiness_reset(&probe);
    REQUIRE(probe == MACH_PORT_NULL);
    mach_port_type_t type = 0;
    REQUIRE(mach_port_type(mach_task_self(), pending, &type) == KERN_INVALID_NAME);
    REQUIRE(mach_port_destroy(mach_task_self(), service) == KERN_SUCCESS);
    return 0;
}
