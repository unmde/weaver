#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dcomp.h>
#include <dwmapi.h>
#include <dxgi.h>
#include <inspectable.h>
#include <roapi.h>
#include <shellapi.h>
#include <winstring.h>
#include <wrl/client.h>

#include <cstdint>
#include <cstdio>
#include <cwchar>
#include <limits>
#include <vector>

#include "shared_renderer_client.h"

using Microsoft::WRL::ComPtr;

namespace {

struct CaptureSize {
    INT32 width;
    INT32 height;
};

struct EventToken {
    INT64 value;
};

struct __declspec(novtable) GraphicsCaptureItemInterop : IUnknown {
    virtual HRESULT STDMETHODCALLTYPE CreateForWindow(HWND window, REFIID iid, void **result) = 0;
    virtual HRESULT STDMETHODCALLTYPE CreateForMonitor(HMONITOR monitor, REFIID iid, void **result) = 0;
};

struct __declspec(novtable) GraphicsCaptureItem : IInspectable {
    virtual HRESULT STDMETHODCALLTYPE get_DisplayName(HSTRING *value) = 0;
    virtual HRESULT STDMETHODCALLTYPE get_Size(CaptureSize *value) = 0;
    virtual HRESULT STDMETHODCALLTYPE add_Closed(void *handler, EventToken *token) = 0;
    virtual HRESULT STDMETHODCALLTYPE remove_Closed(EventToken token) = 0;
};

struct __declspec(novtable) GraphicsCaptureSession : IInspectable {
    virtual HRESULT STDMETHODCALLTYPE StartCapture() = 0;
};

struct __declspec(novtable) GraphicsCaptureSession2 : IInspectable {
    virtual HRESULT STDMETHODCALLTYPE get_IsCursorCaptureEnabled(BYTE *value) = 0;
    virtual HRESULT STDMETHODCALLTYPE put_IsCursorCaptureEnabled(BYTE value) = 0;
};

struct __declspec(novtable) Direct3D11CaptureFrame : IInspectable {
    virtual HRESULT STDMETHODCALLTYPE get_Surface(IInspectable **value) = 0;
    virtual HRESULT STDMETHODCALLTYPE get_SystemRelativeTime(INT64 *value) = 0;
    virtual HRESULT STDMETHODCALLTYPE get_ContentSize(CaptureSize *value) = 0;
};

struct __declspec(novtable) Direct3D11CaptureFramePool : IInspectable {
    virtual HRESULT STDMETHODCALLTYPE Recreate(IInspectable *device, INT32 pixel_format,
        INT32 buffer_count, CaptureSize size) = 0;
    virtual HRESULT STDMETHODCALLTYPE TryGetNextFrame(Direct3D11CaptureFrame **result) = 0;
    virtual HRESULT STDMETHODCALLTYPE add_FrameArrived(void *handler, EventToken *token) = 0;
    virtual HRESULT STDMETHODCALLTYPE remove_FrameArrived(EventToken token) = 0;
    virtual HRESULT STDMETHODCALLTYPE CreateCaptureSession(GraphicsCaptureItem *item,
        GraphicsCaptureSession **result) = 0;
    virtual HRESULT STDMETHODCALLTYPE get_DispatcherQueue(IInspectable **value) = 0;
};

struct __declspec(novtable) Direct3D11CaptureFramePoolStatics2 : IInspectable {
    virtual HRESULT STDMETHODCALLTYPE CreateFreeThreaded(IInspectable *device,
        INT32 pixel_format, INT32 buffer_count, CaptureSize size,
        Direct3D11CaptureFramePool **result) = 0;
};

struct __declspec(novtable) Direct3DDxgiInterfaceAccess : IUnknown {
    virtual HRESULT STDMETHODCALLTYPE GetInterface(REFIID iid, void **value) = 0;
};

struct __declspec(novtable) Closable : IInspectable {
    virtual HRESULT STDMETHODCALLTYPE Close() = 0;
};

constexpr GUID kGraphicsCaptureItemInterop = {
    0x3628e81b, 0x3cac, 0x4c60, { 0xb7, 0xf4, 0x23, 0xce, 0x0e, 0x0c, 0x33, 0x56 }
};
constexpr GUID kGraphicsCaptureItem = {
    0x79c3f95b, 0x31f7, 0x4ec2, { 0xa4, 0x64, 0x63, 0x2e, 0xf5, 0xd3, 0x07, 0x60 }
};
constexpr GUID kDirect3D11CaptureFramePoolStatics2 = {
    0x589b103f, 0x6bbc, 0x5df5, { 0xa9, 0x91, 0x02, 0xe2, 0x8b, 0x3b, 0x66, 0xd5 }
};
constexpr GUID kGraphicsCaptureSession2 = {
    0x2c39ae40, 0x7d2e, 0x5044, { 0x80, 0x4e, 0x8b, 0x67, 0x99, 0xd4, 0xcf, 0x9e }
};
constexpr GUID kDirect3DDxgiInterfaceAccess = {
    0xa9b3d012, 0x3df2, 0x4ee3, { 0xb8, 0xd1, 0x86, 0x95, 0xf4, 0x57, 0xd3, 0xc1 }
};
constexpr GUID kClosable = {
    0x30d5a829, 0x7fa4, 0x4026, { 0x83, 0xbb, 0xd7, 0x5b, 0xae, 0x4e, 0xa9, 0x9e }
};
constexpr INT32 kB8G8R8A8UIntNormalized = 87;
constexpr wchar_t kCaptureProxyClass[] = L"WeaverCompositionCaptureProxy.v1";

using RoInitializeFunction = HRESULT (WINAPI *)(RO_INIT_TYPE);
using RoUninitializeFunction = void (WINAPI *)();
using RoGetActivationFactoryFunction = HRESULT (WINAPI *)(HSTRING, REFIID, void **);
using WindowsCreateStringFunction = HRESULT (WINAPI *)(PCNZWCH, UINT32, HSTRING *);
using WindowsDeleteStringFunction = HRESULT (WINAPI *)(HSTRING);

struct WinRtApi {
    HMODULE module = LoadLibraryW(L"combase.dll");
    RoInitializeFunction initialize = nullptr;
    RoUninitializeFunction uninitialize = nullptr;
    RoGetActivationFactoryFunction get_activation_factory = nullptr;
    WindowsCreateStringFunction create_string = nullptr;
    WindowsDeleteStringFunction delete_string = nullptr;

    WinRtApi() {
        if (!module) return;
        initialize = reinterpret_cast<RoInitializeFunction>(
            GetProcAddress(module, "RoInitialize"));
        uninitialize = reinterpret_cast<RoUninitializeFunction>(
            GetProcAddress(module, "RoUninitialize"));
        get_activation_factory = reinterpret_cast<RoGetActivationFactoryFunction>(
            GetProcAddress(module, "RoGetActivationFactory"));
        create_string = reinterpret_cast<WindowsCreateStringFunction>(
            GetProcAddress(module, "WindowsCreateString"));
        delete_string = reinterpret_cast<WindowsDeleteStringFunction>(
            GetProcAddress(module, "WindowsDeleteString"));
    }

    ~WinRtApi() {
        if (module) FreeLibrary(module);
    }

    bool available() const {
        return module && initialize && uninitialize && get_activation_factory &&
            create_string && delete_string;
    }
};

struct RoApartment {
    const WinRtApi &api;

    ~RoApartment() {
        api.uninitialize();
    }
};

struct SharedSurfaceLocator {
    HWND child = nullptr;
    HANDLE remote_handle = nullptr;
};

BOOL CALLBACK findSharedSurface(HWND child, LPARAM parameter) {
    auto *locator = reinterpret_cast<SharedSurfaceLocator *>(parameter);
    HANDLE surface = GetPropW(child,
        kWeaverSharedCompositionSurfaceProperty);
    if (!surface) return TRUE;
    locator->child = child;
    locator->remote_handle = surface;
    return FALSE;
}

struct CompositionProxy {
    HWND source_child = nullptr;
    HWND window = nullptr;
    HANDLE surface_handle = nullptr;
    ComPtr<IDCompositionDesktopDevice> composition;
    ComPtr<IDCompositionTarget> target;
    ComPtr<IDCompositionVisual2> visual;
    ComPtr<IUnknown> surface;

    ~CompositionProxy() {
        if (target) target->SetRoot(nullptr);
        if (composition) composition->Commit();
        if (window) DestroyWindow(window);
        if (surface_handle) CloseHandle(surface_handle);
    }
};

HRESULT createCompositionProxy(HWND root, CompositionProxy *proxy) {
    if (!root || !proxy) return E_INVALIDARG;
    SharedSurfaceLocator locator;
    EnumChildWindows(root, findSharedSurface,
        reinterpret_cast<LPARAM>(&locator));
    if (!locator.child || !locator.remote_handle) return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);

    DWORD widget_pid = 0;
    GetWindowThreadProcessId(locator.child, &widget_pid);
    HANDLE widget_process = OpenProcess(PROCESS_DUP_HANDLE, FALSE, widget_pid);
    if (!widget_process) return HRESULT_FROM_WIN32(GetLastError());
    HANDLE local_surface = nullptr;
    const BOOL duplicated = DuplicateHandle(widget_process,
        locator.remote_handle, GetCurrentProcess(), &local_surface,
        0, FALSE, DUPLICATE_SAME_ACCESS);
    const DWORD duplicate_error = GetLastError();
    CloseHandle(widget_process);
    if (!duplicated) return HRESULT_FROM_WIN32(duplicate_error);

    RECT child_rect = {};
    RECT root_rect = {};
    if (!GetClientRect(locator.child, &child_rect) ||
        !GetWindowRect(root, &root_rect)) {
        const HRESULT result = HRESULT_FROM_WIN32(GetLastError());
        CloseHandle(local_surface);
        return result;
    }
    const LONG width = child_rect.right - child_rect.left;
    const LONG height = child_rect.bottom - child_rect.top;
    if (width <= 0 || height <= 0) {
        CloseHandle(local_surface);
        return E_UNEXPECTED;
    }

    WNDCLASSEXW window_class = {};
    window_class.cbSize = sizeof(window_class);
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpfnWndProc = DefWindowProcW;
    window_class.lpszClassName = kCaptureProxyClass;
    if (!RegisterClassExW(&window_class) &&
        GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        const HRESULT result = HRESULT_FROM_WIN32(GetLastError());
        CloseHandle(local_surface);
        return result;
    }
    HWND proxy_window = CreateWindowExW(
        WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_NOREDIRECTIONBITMAP,
        kCaptureProxyClass, L"Weaver composition capture", WS_POPUP,
        root_rect.left, root_rect.top, width, height, nullptr, nullptr,
        window_class.hInstance, nullptr);
    if (!proxy_window) {
        const HRESULT result = HRESULT_FROM_WIN32(GetLastError());
        CloseHandle(local_surface);
        return result;
    }

    proxy->source_child = locator.child;
    proxy->window = proxy_window;
    proxy->surface_handle = local_surface;
    HRESULT result = DCompositionCreateDevice2(nullptr,
        IID_PPV_ARGS(&proxy->composition));
    if (SUCCEEDED(result)) {
        result = proxy->composition->CreateTargetForHwnd(
            proxy_window, TRUE, &proxy->target);
    }
    if (SUCCEEDED(result)) {
        result = proxy->composition->CreateVisual(&proxy->visual);
    }
    if (SUCCEEDED(result)) {
        result = proxy->composition->CreateSurfaceFromHandle(
            local_surface, &proxy->surface);
    }
    if (SUCCEEDED(result)) result = proxy->visual->SetContent(proxy->surface.Get());
    if (SUCCEEDED(result)) result = proxy->target->SetRoot(proxy->visual.Get());
    if (SUCCEEDED(result)) result = proxy->composition->Commit();
    if (FAILED(result)) return result;

    ShowWindow(proxy_window, SW_SHOWNOACTIVATE);
    if (!SetWindowPos(proxy_window, HWND_TOPMOST, root_rect.left,
            root_rect.top, width, height,
            SWP_NOACTIVATE | SWP_SHOWWINDOW)) {
        return HRESULT_FROM_WIN32(GetLastError());
    }
    result = DwmFlush();
    return result;
}

bool writeAll(HANDLE file, const void *bytes, DWORD length) {
    const auto *cursor = static_cast<const uint8_t *>(bytes);
    DWORD remaining = length;
    while (remaining > 0) {
        DWORD written = 0;
        if (!WriteFile(file, cursor, remaining, &written, nullptr) || written == 0) return false;
        cursor += written;
        remaining -= written;
    }
    return true;
}

bool writeTopDownBmp(const wchar_t *path, const D3D11_MAPPED_SUBRESOURCE &mapped,
    UINT width, UINT height) {
    const uint64_t row_bytes = static_cast<uint64_t>(width) * 4;
    const uint64_t pixel_bytes = row_bytes * height;
    const uint64_t header_bytes = sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER);
    if (row_bytes > std::numeric_limits<DWORD>::max() ||
        pixel_bytes > std::numeric_limits<DWORD>::max() ||
        header_bytes + pixel_bytes > std::numeric_limits<DWORD>::max()) return false;

    HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;

    BITMAPFILEHEADER file_header = {};
    file_header.bfType = 0x4d42;
    file_header.bfOffBits = static_cast<DWORD>(header_bytes);
    file_header.bfSize = static_cast<DWORD>(header_bytes + pixel_bytes);
    BITMAPINFOHEADER info_header = {};
    info_header.biSize = sizeof(info_header);
    info_header.biWidth = static_cast<LONG>(width);
    info_header.biHeight = -static_cast<LONG>(height);
    info_header.biPlanes = 1;
    info_header.biBitCount = 32;
    info_header.biCompression = BI_RGB;
    info_header.biSizeImage = static_cast<DWORD>(pixel_bytes);

    bool ok = writeAll(file, &file_header, sizeof(file_header)) &&
        writeAll(file, &info_header, sizeof(info_header));
    std::vector<uint8_t> row(static_cast<size_t>(row_bytes));
    for (UINT y = 0; ok && y < height; ++y) {
        const auto *source = static_cast<const uint8_t *>(mapped.pData) +
            static_cast<size_t>(y) * mapped.RowPitch;
        memcpy(row.data(), source, static_cast<size_t>(row_bytes));
        for (UINT x = 0; x < width; ++x) row[static_cast<size_t>(x) * 4 + 3] = 255;
        ok = writeAll(file, row.data(), static_cast<DWORD>(row_bytes));
    }
    if (!CloseHandle(file)) ok = false;
    if (!ok) DeleteFileW(path);
    return ok;
}

int fail(const char *operation, HRESULT result) {
    fprintf(stderr, "weaver-window-capture: %s failed hr=0x%08lx\n",
        operation, static_cast<unsigned long>(result));
    return 1;
}

int failWin32(const char *operation) {
    fprintf(stderr, "weaver-window-capture: %s failed win32=%lu\n",
        operation, static_cast<unsigned long>(GetLastError()));
    return 1;
}

HRESULT activationFactory(const WinRtApi &api, const wchar_t *class_name,
    REFIID iid, void **factory) {
    HSTRING name = nullptr;
    HRESULT result = api.create_string(class_name,
        static_cast<UINT32>(wcslen(class_name)), &name);
    if (FAILED(result)) return result;
    result = api.get_activation_factory(name, iid, factory);
    api.delete_string(name);
    return result;
}

void closeObject(IInspectable *object) {
    if (!object) return;
    ComPtr<Closable> closable;
    if (SUCCEEDED(object->QueryInterface(kClosable,
            reinterpret_cast<void **>(closable.GetAddressOf())))) {
        closable->Close();
    }
}

int captureWindow(HWND window, const wchar_t *path) {
    RECT client = {};
    if (!GetClientRect(window, &client)) return failWin32("GetClientRect");
    const LONG expected_width = client.right - client.left;
    const LONG expected_height = client.bottom - client.top;
    if (expected_width <= 0 || expected_height <= 0) {
        fprintf(stderr, "weaver-window-capture: client rect is not positive: %ldx%ld\n",
            expected_width, expected_height);
        return 1;
    }

    CompositionProxy proxy;
    HRESULT result = createCompositionProxy(window, &proxy);
    if (FAILED(result)) return fail("create DirectComposition proxy", result);
    window = proxy.window;

    WinRtApi winrt;
    if (!winrt.available()) {
        fprintf(stderr, "weaver-window-capture: combase WinRT APIs are unavailable\n");
        return 1;
    }
    result = winrt.initialize(RO_INIT_MULTITHREADED);
    if (FAILED(result)) return fail("RoInitialize", result);
    RoApartment apartment{winrt};

    ComPtr<GraphicsCaptureItemInterop> item_interop;
    result = activationFactory(winrt,
        L"Windows.Graphics.Capture.GraphicsCaptureItem",
        kGraphicsCaptureItemInterop,
        reinterpret_cast<void **>(item_interop.GetAddressOf()));
    if (FAILED(result)) {
        return fail("GraphicsCaptureItem activation", result);
    }
    ComPtr<GraphicsCaptureItem> item;
    result = item_interop->CreateForWindow(window, kGraphicsCaptureItem,
        reinterpret_cast<void **>(item.GetAddressOf()));
    if (FAILED(result)) {
        return fail("GraphicsCaptureItem::CreateForWindow", result);
    }
    CaptureSize item_size = {};
    result = item->get_Size(&item_size);
    if (FAILED(result) || item_size.width <= 0 || item_size.height <= 0) {
        return fail("GraphicsCaptureItem::get_Size", FAILED(result) ? result : E_UNEXPECTED);
    }

    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    D3D_FEATURE_LEVEL feature_level = {};
    result = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
        &device, &feature_level, &context);
    if (FAILED(result)) {
        return fail("D3D11CreateDevice", result);
    }
    ComPtr<IDXGIDevice> dxgi_device;
    result = device.As(&dxgi_device);
    if (FAILED(result)) {
        return fail("IDXGIDevice", result);
    }
    ComPtr<IDXGIAdapter> adapter;
    result = dxgi_device->GetAdapter(&adapter);
    if (FAILED(result)) {
        return fail("IDXGIDevice::GetAdapter", result);
    }
    DXGI_ADAPTER_DESC adapter_desc = {};
    result = adapter->GetDesc(&adapter_desc);
    if (FAILED(result)) {
        return fail("IDXGIAdapter::GetDesc", result);
    }
    HMODULE d3d11 = GetModuleHandleW(L"d3d11.dll");
    using CreateDirect3DDevice = HRESULT (WINAPI *)(IDXGIDevice *, IInspectable **);
    auto create_direct3d_device = reinterpret_cast<CreateDirect3DDevice>(
        d3d11 ? GetProcAddress(d3d11, "CreateDirect3D11DeviceFromDXGIDevice") : nullptr);
    if (!create_direct3d_device) {
        return failWin32("CreateDirect3D11DeviceFromDXGIDevice lookup");
    }
    ComPtr<IInspectable> direct3d_device;
    result = create_direct3d_device(dxgi_device.Get(), &direct3d_device);
    if (FAILED(result)) {
        return fail("CreateDirect3D11DeviceFromDXGIDevice", result);
    }

    ComPtr<Direct3D11CaptureFramePoolStatics2> frame_pool_statics;
    result = activationFactory(winrt,
        L"Windows.Graphics.Capture.Direct3D11CaptureFramePool",
        kDirect3D11CaptureFramePoolStatics2,
        reinterpret_cast<void **>(frame_pool_statics.GetAddressOf()));
    if (FAILED(result)) {
        return fail("Direct3D11CaptureFramePool activation", result);
    }
    ComPtr<Direct3D11CaptureFramePool> frame_pool;
    result = frame_pool_statics->CreateFreeThreaded(direct3d_device.Get(),
        kB8G8R8A8UIntNormalized, 1, item_size, &frame_pool);
    if (FAILED(result)) {
        return fail("Direct3D11CaptureFramePool::CreateFreeThreaded", result);
    }
    ComPtr<GraphicsCaptureSession> session;
    result = frame_pool->CreateCaptureSession(item.Get(), &session);
    if (FAILED(result)) {
        closeObject(frame_pool.Get());
        return fail("Direct3D11CaptureFramePool::CreateCaptureSession", result);
    }
    ComPtr<GraphicsCaptureSession2> session2;
    if (SUCCEEDED(session->QueryInterface(kGraphicsCaptureSession2,
            reinterpret_cast<void **>(session2.GetAddressOf())))) {
        session2->put_IsCursorCaptureEnabled(FALSE);
    }
    result = session->StartCapture();
    if (FAILED(result)) {
        closeObject(session.Get());
        closeObject(frame_pool.Get());
        return fail("GraphicsCaptureSession::StartCapture", result);
    }

    ComPtr<Direct3D11CaptureFrame> frame;
    // A static window normally yields its initial frame within one refresh.
    // Five seconds is a tripwire for a wedged capture session, not pacing.
    const ULONGLONG deadline = GetTickCount64() + 5000;
    while (!frame && GetTickCount64() < deadline) {
        result = frame_pool->TryGetNextFrame(&frame);
        if (FAILED(result)) break;
        if (!frame) Sleep(1);
    }
    if (FAILED(result) || !frame) {
        closeObject(session.Get());
        closeObject(frame_pool.Get());
        return fail("Direct3D11CaptureFramePool::TryGetNextFrame",
            FAILED(result) ? result : HRESULT_FROM_WIN32(WAIT_TIMEOUT));
    }
    CaptureSize frame_size = {};
    result = frame->get_ContentSize(&frame_size);
    if (FAILED(result) || frame_size.width <= 0 || frame_size.height <= 0) {
        closeObject(session.Get());
        closeObject(frame_pool.Get());
        return fail("Direct3D11CaptureFrame::get_ContentSize",
            FAILED(result) ? result : E_UNEXPECTED);
    }
    ComPtr<IInspectable> surface;
    result = frame->get_Surface(&surface);
    if (FAILED(result)) {
        closeObject(session.Get());
        closeObject(frame_pool.Get());
        return fail("Direct3D11CaptureFrame::get_Surface", result);
    }
    ComPtr<Direct3DDxgiInterfaceAccess> surface_access;
    result = surface->QueryInterface(kDirect3DDxgiInterfaceAccess,
        reinterpret_cast<void **>(surface_access.GetAddressOf()));
    if (FAILED(result)) {
        closeObject(session.Get());
        closeObject(frame_pool.Get());
        return fail("IDirect3DDxgiInterfaceAccess", result);
    }
    ComPtr<ID3D11Texture2D> frame_texture;
    result = surface_access->GetInterface(__uuidof(ID3D11Texture2D),
        reinterpret_cast<void **>(frame_texture.GetAddressOf()));
    if (FAILED(result)) {
        closeObject(session.Get());
        closeObject(frame_pool.Get());
        return fail("capture frame ID3D11Texture2D", result);
    }
    D3D11_TEXTURE2D_DESC frame_desc = {};
    frame_texture->GetDesc(&frame_desc);
    if (frame_desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM ||
        frame_size.width > static_cast<INT32>(frame_desc.Width) ||
        frame_size.height > static_cast<INT32>(frame_desc.Height)) {
        closeObject(session.Get());
        closeObject(frame_pool.Get());
        fprintf(stderr,
            "weaver-window-capture: unexpected frame format=%u content=%dx%d texture=%ux%u\n",
            static_cast<unsigned>(frame_desc.Format), frame_size.width,
            frame_size.height, frame_desc.Width, frame_desc.Height);
        return 1;
    }

    D3D11_TEXTURE2D_DESC staging_desc = {};
    staging_desc.Width = static_cast<UINT>(frame_size.width);
    staging_desc.Height = static_cast<UINT>(frame_size.height);
    staging_desc.MipLevels = 1;
    staging_desc.ArraySize = 1;
    staging_desc.Format = frame_desc.Format;
    staging_desc.SampleDesc.Count = 1;
    staging_desc.Usage = D3D11_USAGE_STAGING;
    staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> staging;
    result = device->CreateTexture2D(&staging_desc, nullptr, &staging);
    if (FAILED(result)) {
        closeObject(session.Get());
        closeObject(frame_pool.Get());
        return fail("ID3D11Device::CreateTexture2D", result);
    }
    D3D11_BOX source_box = {};
    source_box.right = static_cast<UINT>(frame_size.width);
    source_box.bottom = static_cast<UINT>(frame_size.height);
    source_box.back = 1;
    context->CopySubresourceRegion(staging.Get(), 0, 0, 0, 0,
        frame_texture.Get(), 0, &source_box);
    D3D11_MAPPED_SUBRESOURCE mapped = {};
    result = context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(result)) {
        closeObject(session.Get());
        closeObject(frame_pool.Get());
        return fail("ID3D11DeviceContext::Map", result);
    }
    const bool wrote = writeTopDownBmp(path, mapped,
        static_cast<UINT>(frame_size.width), static_cast<UINT>(frame_size.height));
    context->Unmap(staging.Get(), 0);
    closeObject(session.Get());
    closeObject(frame_pool.Get());
    if (!wrote) return failWin32("write BMP");
    fprintf(stderr,
        "weaver-window-capture: method=dcomp-proxy-windows-graphics-capture adapter=0x%04x:0x%04x source_child=0x%llx client=%ldx%ld item=%dx%d frame=%dx%d\n",
        adapter_desc.VendorId, adapter_desc.DeviceId,
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(proxy.source_child)),
        expected_width, expected_height, item_size.width, item_size.height,
        frame_size.width, frame_size.height);
    return 0;
}

} // namespace

extern "C" int weaver_window_capture_run() {
    int argument_count = 0;
    wchar_t **arguments = CommandLineToArgvW(GetCommandLineW(), &argument_count);
    if (!arguments) return failWin32("CommandLineToArgvW");
    const wchar_t *window_text = nullptr;
    const wchar_t *output_path = nullptr;
    for (int index = 1; index < argument_count; ++index) {
        if (wcscmp(arguments[index], L"--hwnd") == 0 && index + 1 < argument_count) {
            window_text = arguments[++index];
        } else if (wcscmp(arguments[index], L"--out") == 0 && index + 1 < argument_count) {
            output_path = arguments[++index];
        } else {
            fwprintf(stderr, L"weaver-window-capture: unrecognized argument: %ls\n", arguments[index]);
            LocalFree(arguments);
            return 2;
        }
    }
    if (!window_text || !output_path) {
        fprintf(stderr, "usage: weaver-window-capture --hwnd <handle> --out <bmp-path>\n");
        LocalFree(arguments);
        return 2;
    }
    wchar_t *end = nullptr;
    const unsigned long long raw_window = wcstoull(window_text, &end, 0);
    if (end == window_text || *end != L'\0' || raw_window == 0) {
        fwprintf(stderr, L"weaver-window-capture: invalid window handle: %ls\n", window_text);
        LocalFree(arguments);
        return 2;
    }
    HWND window = reinterpret_cast<HWND>(static_cast<uintptr_t>(raw_window));
    if (!IsWindow(window)) {
        fwprintf(stderr, L"weaver-window-capture: window does not exist: %ls\n", window_text);
        LocalFree(arguments);
        return 2;
    }
    const int result = captureWindow(window, output_path);
    LocalFree(arguments);
    return result;
}
