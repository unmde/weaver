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
    REQUIRE(weaver_renderer_readiness_poll(name, strlen(name), &probe) == WEAVER_RENDERER_WAITING);
    const mach_port_t pending = probe;
    weaver_renderer_readiness_reset(&probe);
    REQUIRE(probe == MACH_PORT_NULL);
    mach_port_type_t type = 0;
    REQUIRE(mach_port_type(mach_task_self(), pending, &type) == KERN_INVALID_NAME);
    REQUIRE(mach_port_destroy(mach_task_self(), service) == KERN_SUCCESS);
    return 0;
}
