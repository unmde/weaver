#include "renderer_server.h"
#include "d3d_presenter.h"
#include "renderer_protocol.h"

#include <windows.h>

#include <cstdio>
#include <memory>
#include <mutex>
#include <thread>
#include <string>
#include <vector>

static wchar_t rendererLogPath[32768] = {};
static wchar_t dpiLogPath[32768] = {};
static std::mutex rendererLogMutex;

static void logEvent(const char *kind, DWORD widget_pid, uint64_t frames, uint64_t elapsed_ms) {
    if (rendererLogPath[0] == L'\0') return;
    char line[256] = {};
    const int length = snprintf(line, sizeof(line), "%llu %s renderer=%lu widget=%lu frames=%llu elapsed_ms=%llu\r\n",
        (unsigned long long)GetTickCount64(), kind, (unsigned long)GetCurrentProcessId(),
        (unsigned long)widget_pid, (unsigned long long)frames, (unsigned long long)elapsed_ms);
    if (length <= 0) return;
    std::lock_guard<std::mutex> lock(rendererLogMutex);
    HANDLE file = CreateFileW(rendererLogPath, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(file, line, (DWORD)length, &written, nullptr);
    CloseHandle(file);
}

static void logDpiEvent(const WeaverRendererFrame &frame, const char *action) {
    if (dpiLogPath[0] == L'\0') return;
    char line[640] = {};
    const int length = snprintf(line, sizeof(line),
        "%llu renderer-surface renderer=%lu widget=%lu scale=%.6f "
        "logical_surface_dip=%.6fx%.6f destination_dip=(%.6f,%.6f %.6fx%.6f) "
        "destination_edges_px=(%ld,%ld,%ld,%ld) texture_px=%ux%u generation=%llu action=%s\r\n",
        (unsigned long long)GetTickCount64(), (unsigned long)GetCurrentProcessId(),
        (unsigned long)frame.widget_pid, frame.device_scale,
        frame.logical_surface_width_dip, frame.logical_surface_height_dip,
        frame.destination_x_dip, frame.destination_y_dip,
        frame.destination_width_dip, frame.destination_height_dip,
        frame.destination_left_px, frame.destination_top_px,
        frame.destination_right_px, frame.destination_bottom_px,
        frame.source_texture_width_px, frame.source_texture_height_px,
        (unsigned long long)frame.geometry_generation, action);
    if (length <= 0) return;
    std::lock_guard<std::mutex> lock(rendererLogMutex);
    HANDLE file = CreateFileW(dpiLogPath, FILE_APPEND_DATA,
        FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(file, line, (DWORD)length, &written, nullptr);
    CloseHandle(file);
}

static bool readExact(HANDLE file, void *bytes, size_t length) {
    uint8_t *cursor = static_cast<uint8_t *>(bytes);
    while (length > 0) {
        DWORD read = 0;
        if (!ReadFile(file, cursor, (DWORD)length, &read, nullptr) || read == 0) return false;
        cursor += read;
        length -= read;
    }
    return true;
}

static bool writeExact(HANDLE file, const void *bytes, size_t length) {
    const uint8_t *cursor = static_cast<const uint8_t *>(bytes);
    while (length > 0) {
        DWORD written = 0;
        if (!WriteFile(file, cursor, (DWORD)length, &written, nullptr) || written == 0) return false;
        cursor += written;
        length -= written;
    }
    return true;
}

static void serveWidget(HANDLE pipe, NativeSdkD3DSharedRenderer *renderer) {
    NativeSdkD3DSharedSurface *surface = nullptr;
    DWORD widget_pid = 0;
    uint64_t frames = 0;
    uint64_t interval_start_ms = GetTickCount64();
    HANDLE retained_mapping = nullptr;
    const uint8_t *retained_pixels = nullptr;
    std::wstring retained_name;
    size_t retained_bytes = 0;
    WeaverRendererHello hello = {};
    if (!readExact(pipe, &hello, sizeof(hello))) {
        CloseHandle(pipe);
        return;
    }
    WeaverRendererHelloReply hello_reply = {};
    hello_reply.magic = kWeaverRendererMagic;
    hello_reply.version = kWeaverRendererVersion;
    hello_reply.struct_size = sizeof(hello_reply);
    hello_reply.status = weaverRendererHelloValid(hello)
        ? kWeaverRendererStatusOk : kWeaverRendererStatusVersionMismatch;
    if (!writeExact(pipe, &hello_reply, sizeof(hello_reply)) ||
        hello_reply.status != kWeaverRendererStatusOk) {
        FlushFileBuffers(pipe);
        DisconnectNamedPipe(pipe);
        CloseHandle(pipe);
        return;
    }
    widget_pid = hello.widget_pid;
    uint64_t last_geometry_generation = 0;
    uint32_t last_texture_width_px = 0;
    uint32_t last_texture_height_px = 0;
    for (;;) {
        WeaverRendererFrame frame = {};
        if (!readExact(pipe, &frame, sizeof(frame))) break;
        WeaverRendererReply reply = {};
        reply.magic = kWeaverRendererMagic;
        reply.version = kWeaverRendererVersion;
        if (!weaverRendererFrameValid(frame) || frame.widget_pid != widget_pid) {
            writeExact(pipe, &reply, sizeof(reply));
            break;
        }
        if (!surface) {
            surface = nativeSdkD3DSharedSurfaceCreate(renderer, widget_pid, nullptr);
            logEvent("connect", widget_pid, 0, 0);
        }
        if (!surface) break;
        std::vector<uint8_t> packet(frame.packet_len);
        if (!readExact(pipe, packet.data(), packet.size())) break;
        if (frame.retained_generation != 0) {
            const size_t bytes = (size_t)frame.retained_width * frame.retained_height * 4;
            const std::wstring name(frame.retained_section_name, frame.retained_section_name_len);
            if (bytes == 0 || name.empty()) break;
            if (!retained_mapping || retained_name != name || retained_bytes != bytes) {
                if (retained_pixels) UnmapViewOfFile(retained_pixels);
                if (retained_mapping) CloseHandle(retained_mapping);
                retained_pixels = nullptr;
                retained_mapping = OpenFileMappingW(FILE_MAP_READ, FALSE, name.c_str());
                if (!retained_mapping) break;
                retained_pixels = static_cast<const uint8_t *>(MapViewOfFile(retained_mapping,
                    FILE_MAP_READ, 0, 0, bytes));
                if (!retained_pixels) break;
                retained_name = name;
                retained_bytes = bytes;
            }
        }
        uint64_t replacement_handle = 0;
        if (nativeSdkD3DSharedSurfacePresent(surface,
            frame.logical_surface_width_dip,
            frame.logical_surface_height_dip, frame.device_scale,
            frame.source_texture_width_px, frame.source_texture_height_px,
            frame.geometry_generation, frame.clear_r, frame.clear_g,
            frame.clear_b, frame.clear_a, packet.data(), packet.size(),
            frame.retained_above_packet != 0,
            frame.retained_generation, frame.retained_width, frame.retained_height,
            reinterpret_cast<const float *>(frame.retained_dirty_rects),
            frame.retained_dirty_rect_count,
            frame.retained_generation != 0 ? retained_pixels : nullptr,
            &replacement_handle)) {
            reply.status = kWeaverRendererStatusOk;
            reply.surface_handle = replacement_handle;
            if (frame.geometry_generation != last_geometry_generation) {
                const bool resized = weaverSurfaceExtentChanged(
                    last_texture_width_px, last_texture_height_px,
                    frame.source_texture_width_px,
                    frame.source_texture_height_px);
                logDpiEvent(frame, replacement_handle != 0
                    ? (last_geometry_generation == 0 ? "created" : "resized-recreated")
                    : (resized ? "resized-reused" : "geometry-reused"));
                last_geometry_generation = frame.geometry_generation;
                last_texture_width_px = frame.source_texture_width_px;
                last_texture_height_px = frame.source_texture_height_px;
            }
            if (frame.retained_generation != 0) {
                logEvent("retained-upload", widget_pid, frame.retained_generation,
                    frame.retained_dirty_rect_count);
            }
            frames += 1;
            if (frames % 300 == 0) {
                const uint64_t now = GetTickCount64();
                logEvent("fps", widget_pid, 300, now - interval_start_ms);
                interval_start_ms = now;
            }
        }
        if (!writeExact(pipe, &reply, sizeof(reply)) || reply.status == 0) break;
    }
    nativeSdkD3DSharedSurfaceDestroy(surface);
    if (retained_pixels) UnmapViewOfFile(retained_pixels);
    if (retained_mapping) CloseHandle(retained_mapping);
    logEvent("disconnect", widget_pid, frames, 0);
    FlushFileBuffers(pipe);
    DisconnectNamedPipe(pipe);
    CloseHandle(pipe);
}

int weaver_renderer_run(void) {
    wchar_t pipe_name[512] = {};
    const DWORD length = GetEnvironmentVariableW(L"WEAVER_RENDERER_PIPE",
        pipe_name, ARRAYSIZE(pipe_name));
    if (length == 0 || length >= ARRAYSIZE(pipe_name)) return 2;
    GetEnvironmentVariableW(L"WEAVER_RENDERER_LOG", rendererLogPath, ARRAYSIZE(rendererLogPath));
    GetEnvironmentVariableW(L"WEAVER_DPI_LOG", dpiLogPath, ARRAYSIZE(dpiLogPath));
    NativeSdkD3DSharedRenderer *renderer = nativeSdkD3DSharedRendererCreate();
    if (!renderer) return 3;
    logEvent("start", 0, 0, 0);
    for (;;) {
        HANDLE pipe = CreateNamedPipeW(pipe_name,
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            PIPE_UNLIMITED_INSTANCES, 1024 * 1024, 1024 * 1024, 0, nullptr);
        if (pipe == INVALID_HANDLE_VALUE) break;
        const BOOL connected = ConnectNamedPipe(pipe, nullptr) ? TRUE :
            GetLastError() == ERROR_PIPE_CONNECTED;
        if (!connected) {
            CloseHandle(pipe);
            continue;
        }
        std::thread(serveWidget, pipe, renderer).detach();
    }
    nativeSdkD3DSharedRendererDestroy(renderer);
    return 4;
}
