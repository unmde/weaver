const std = @import("std");
const builtin = @import("builtin");
const win = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("winhttp.h");
}) else struct {};

// Network receipt (2026-07-29): shipped widgets currently issue no fetches.
// A modeled slow-but-good API exchange is 5 s, so 15 s leaves 3x latency
// headroom; the timeout retains no payload memory and cancellation tests pin
// teardown to under one second.
pub const timeout_ms: c_int = 15_000;
// A modeled large good JSON request/response is 2 MiB; 5 MiB leaves 2.5x
// headroom. Up to four bridge slots can therefore retain at most 20 MiB on
// either side, but buffers allocate actual bytes and unused allowance costs
// no memory.
pub const request_cap_bytes: usize = 5 * 1024 * 1024;
pub const response_cap_bytes: usize = 5 * 1024 * 1024;

pub const Method = enum { get, post };
pub const Failure = enum { none, invalid_url, request_failed, timed_out, request_too_large, response_too_large, cancelled };

extern fn weaver_macos_https_perform(url: [*]const u8, url_len: usize, method: c_int, headers: [*]const u8, headers_len: usize, body: [*]const u8, body_len: usize, timeout_milliseconds: c_int, response_cap: usize, cancelled: ?*const std.atomic.Value(u8), out_status: *u16, out_body: *?[*]u8, out_body_len: *usize) c_int;
extern fn weaver_macos_https_perform_test(url: [*]const u8, url_len: usize, method: c_int, headers: [*]const u8, headers_len: usize, body: [*]const u8, body_len: usize, timeout_milliseconds: c_int, response_cap: usize, cancelled: ?*const std.atomic.Value(u8), test_certificate_path: [*:0]const u8, out_status: *u16, out_body: *?[*]u8, out_body_len: *usize) c_int;
extern fn weaver_macos_https_free(bytes: ?*anyopaque) void;

pub const ParsedUrl = struct {
    declared_host: []const u8,
    connection_host: []const u8,
    path: []const u8,
    port: u16,
};

pub const Request = struct {
    method: Method = .get,
    url: []const u8 = &.{},
    headers: []const u8 = &.{},
    body: []const u8 = &.{},
    /// Set only by the bridge slot that owns this request. macOS polls it
    /// while NSURLSession is in flight so engine teardown can cancel before
    /// joining the worker.
    cancelled: ?*const std.atomic.Value(u8) = null,
    /// Test-only leaf certificate path. Production builds never call the
    /// alternate trust entry point; NSURLSession uses the system trust store.
    test_certificate_path: []const u8 = &.{},

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        if (self.url.len > 0) allocator.free(self.url);
        if (self.headers.len > 0) allocator.free(self.headers);
        if (self.body.len > 0) allocator.free(self.body);
        self.* = .{};
    }
};

pub const Result = struct {
    status: u16 = 0,
    body: ?[]u8 = null,
    failure: Failure = .none,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.body) |bytes| allocator.free(bytes);
        self.* = .{};
    }
};

/// Parse only the URL shape the public capability admits. Keeping host
/// extraction here and in the CLI intentionally boring makes the runtime's
/// authoritative exact-host check auditable instead of delegating policy to
/// redirects or proxy normalization.
pub fn parseHttpsUrl(url: []const u8) !ParsedUrl {
    const prefix = "https://";
    if (url.len <= prefix.len or !std.ascii.startsWithIgnoreCase(url, prefix)) return error.HttpsRequired;
    const rest = url[prefix.len..];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..authority_end];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return error.InvalidUrl;
    var connection_host = authority;
    var port: u16 = 443;
    if (authority[0] == '[') {
        const closing = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidUrl;
        connection_host = authority[1..closing];
        if (closing + 1 < authority.len) {
            if (authority[closing + 1] != ':') return error.InvalidUrl;
            port = std.fmt.parseInt(u16, authority[closing + 2 ..], 10) catch return error.InvalidUrl;
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, authority[0..colon], ':') != null) return error.InvalidUrl;
        connection_host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.InvalidUrl;
    }
    if (connection_host.len == 0) return error.InvalidUrl;
    const suffix = rest[authority_end..];
    const path = if (suffix.len == 0) "/" else if (suffix[0] == '/') suffix else suffix;
    return .{ .declared_host = authority, .connection_host = connection_host, .path = path, .port = port };
}

pub fn originDeclared(origins: []const []const u8, host: []const u8) bool {
    for (origins) |origin| if (std.ascii.eqlIgnoreCase(origin, host)) return true;
    return false;
}

pub fn requestWithinCap(url_len: usize, headers_len: usize, body_len: usize) bool {
    if (url_len > request_cap_bytes) return false;
    const after_url = request_cap_bytes - url_len;
    if (headers_len > after_url) return false;
    return body_len <= after_url - headers_len;
}

/// WinHTTP is already the fork's proven Windows HTTPS substrate. Requests run
/// only on bridge workers; automatic redirects are disabled so a response can
/// never cross the manifest's host boundary behind the policy check.
pub fn perform(request: *const Request, allocator: std.mem.Allocator) Result {
    return performWithTimeout(request, allocator, timeout_ms);
}

fn performWithTimeout(request: *const Request, allocator: std.mem.Allocator, exchange_timeout_ms: c_int) Result {
    if (!requestWithinCap(request.url.len, request.headers.len, request.body.len)) return .{ .failure = .request_too_large };
    const result = if (builtin.os.tag == .windows)
        performWindowsFallible(request, allocator, exchange_timeout_ms)
    else if (builtin.os.tag == .macos)
        performMacFallible(request, allocator, exchange_timeout_ms)
    else
        error.RequestFailed;
    return result catch |err| .{ .failure = failureFromError(err) };
}

fn failureFromError(err: anyerror) Failure {
    return switch (err) {
        error.HttpsRequired, error.InvalidUrl => .invalid_url,
        error.ResponseTooLarge => .response_too_large,
        error.TimedOut => .timed_out,
        error.Cancelled => .cancelled,
        else => .request_failed,
    };
}

fn performWindowsFallible(request: *const Request, allocator: std.mem.Allocator, exchange_timeout_ms: c_int) !Result {
    const deadline_ms = win.GetTickCount64() + @as(u64, @intCast(exchange_timeout_ms));
    const parsed = try parseHttpsUrl(request.url);
    const agent = std.unicode.utf8ToUtf16LeAllocZ(allocator, "weaver-widget/0.2") catch return error.OutOfMemory;
    defer allocator.free(agent);
    const host = std.unicode.utf8ToUtf16LeAllocZ(allocator, parsed.connection_host) catch return error.OutOfMemory;
    defer allocator.free(host);
    var path_bytes: []const u8 = parsed.path;
    var prefixed_path: ?[]u8 = null;
    if (path_bytes.len > 0 and path_bytes[0] != '/') {
        prefixed_path = std.fmt.allocPrint(allocator, "/{s}", .{path_bytes}) catch return error.OutOfMemory;
        path_bytes = prefixed_path.?;
    }
    defer if (prefixed_path) |bytes| allocator.free(bytes);
    const path = std.unicode.utf8ToUtf16LeAllocZ(allocator, path_bytes) catch return error.OutOfMemory;
    defer allocator.free(path);
    const method = std.unicode.utf8ToUtf16LeAllocZ(allocator, if (request.method == .post) "POST" else "GET") catch return error.OutOfMemory;
    defer allocator.free(method);

    const session = win.WinHttpOpen(agent.ptr, win.WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, null, null, 0) orelse return mapLastError();
    defer _ = win.WinHttpCloseHandle(session);
    try applyRemainingTimeout(session, deadline_ms);
    const connection = win.WinHttpConnect(session, host.ptr, parsed.port, 0) orelse return mapLastError();
    defer _ = win.WinHttpCloseHandle(connection);
    const handle = win.WinHttpOpenRequest(connection, method.ptr, path.ptr, null, null, null, win.WINHTTP_FLAG_SECURE) orelse return mapLastError();
    defer _ = win.WinHttpCloseHandle(handle);
    var disabled: win.DWORD = win.WINHTTP_DISABLE_REDIRECTS;
    if (win.WinHttpSetOption(handle, win.WINHTTP_OPTION_DISABLE_FEATURE, &disabled, @sizeOf(win.DWORD)) == 0) return mapLastError();
    if (request.headers.len > 0) {
        const headers = std.unicode.utf8ToUtf16LeAllocZ(allocator, request.headers) catch return error.OutOfMemory;
        defer allocator.free(headers);
        const header_flags: win.DWORD = 0x20000000 | 0x80000000; // ADD | REPLACE; translate-c types the high-bit macro as signed.
        if (win.WinHttpAddRequestHeaders(handle, headers.ptr, @intCast(headers.len), header_flags) == 0) return mapLastError();
    }
    const payload = request.body;
    const payload_pointer: win.LPVOID = if (payload.len == 0) win.WINHTTP_NO_REQUEST_DATA else @ptrCast(@constCast(payload.ptr));
    try applyRemainingTimeout(handle, deadline_ms);
    if (win.WinHttpSendRequest(handle, null, 0, payload_pointer, @intCast(payload.len), @intCast(payload.len), 0) == 0) return mapLastError();
    try applyRemainingTimeout(handle, deadline_ms);
    if (win.WinHttpReceiveResponse(handle, null) == 0) return mapLastError();
    var status: win.DWORD = 0;
    var status_size: win.DWORD = @sizeOf(win.DWORD);
    if (win.WinHttpQueryHeaders(handle, win.WINHTTP_QUERY_STATUS_CODE | win.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &status_size, null) == 0) return mapLastError();
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    while (true) {
        try applyRemainingTimeout(handle, deadline_ms);
        var available: win.DWORD = 0;
        if (win.WinHttpQueryDataAvailable(handle, &available) == 0) return mapLastError();
        if (available == 0) break;
        if (body.items.len + available > response_cap_bytes) return error.ResponseTooLarge;
        const start = body.items.len;
        try body.resize(allocator, start + available);
        var read: win.DWORD = 0;
        if (win.WinHttpReadData(handle, body.items[start..].ptr, available, &read) == 0) return mapLastError();
        body.shrinkRetainingCapacity(start + read);
    }
    return .{ .status = @intCast(status), .body = try body.toOwnedSlice(allocator) };
}

fn performMacFallible(request: *const Request, allocator: std.mem.Allocator, exchange_timeout_ms: c_int) !Result {
    _ = try parseHttpsUrl(request.url);
    var status: u16 = 0;
    var raw_body: ?[*]u8 = null;
    var raw_body_len: usize = 0;
    const result_code = if (builtin.is_test and request.test_certificate_path.len > 0) block: {
        const certificate_path = try allocator.dupeZ(u8, request.test_certificate_path);
        defer allocator.free(certificate_path);
        break :block weaver_macos_https_perform_test(
            request.url.ptr,
            request.url.len,
            if (request.method == .post) 1 else 0,
            request.headers.ptr,
            request.headers.len,
            request.body.ptr,
            request.body.len,
            exchange_timeout_ms,
            response_cap_bytes,
            request.cancelled,
            certificate_path.ptr,
            &status,
            &raw_body,
            &raw_body_len,
        );
    } else weaver_macos_https_perform(
        request.url.ptr,
        request.url.len,
        if (request.method == .post) 1 else 0,
        request.headers.ptr,
        request.headers.len,
        request.body.ptr,
        request.body.len,
        exchange_timeout_ms,
        response_cap_bytes,
        request.cancelled,
        &status,
        &raw_body,
        &raw_body_len,
    );
    defer if (raw_body) |bytes| weaver_macos_https_free(bytes);
    return switch (result_code) {
        0 => .{
            .status = status,
            .body = try allocator.dupe(u8, if (raw_body) |bytes| bytes[0..raw_body_len] else &.{}),
        },
        1 => error.InvalidUrl,
        3 => error.TimedOut,
        4 => error.ResponseTooLarge,
        5 => error.Cancelled,
        else => error.RequestFailed,
    };
}

fn applyRemainingTimeout(handle: win.HINTERNET, deadline_ms: u64) !void {
    const now = win.GetTickCount64();
    if (now >= deadline_ms) return error.TimedOut;
    const remaining: c_int = @intCast(@min(deadline_ms - now, @as(u64, @intCast(std.math.maxInt(c_int)))));
    if (win.WinHttpSetTimeouts(handle, remaining, remaining, remaining, remaining) == 0) return mapLastError();
}

fn mapLastError() error{ TimedOut, RequestFailed } {
    return if (win.GetLastError() == win.ERROR_WINHTTP_TIMEOUT) error.TimedOut else error.RequestFailed;
}

test "HTTPS parser and declared-origin matcher use the exact host" {
    const parsed = try parseHttpsUrl("https://api.example.com:8443/v1?a=1");
    try std.testing.expectEqualStrings("api.example.com:8443", parsed.declared_host);
    try std.testing.expectEqualStrings("api.example.com", parsed.connection_host);
    try std.testing.expectEqualStrings("/v1?a=1", parsed.path);
    try std.testing.expectEqual(@as(u16, 8443), parsed.port);
    try std.testing.expect(originDeclared(&.{"API.EXAMPLE.COM:8443"}, parsed.declared_host));
    try std.testing.expect(!originDeclared(&.{"example.com"}, parsed.declared_host));
    const ipv6 = try parseHttpsUrl("https://[::1]:9443/status");
    try std.testing.expectEqualStrings("[::1]:9443", ipv6.declared_host);
    try std.testing.expectEqualStrings("::1", ipv6.connection_host);
    try std.testing.expectError(error.HttpsRequired, parseHttpsUrl("http://api.example.com"));
    try std.testing.expectError(error.InvalidUrl, parseHttpsUrl("https:///missing-host"));
    try std.testing.expectError(error.InvalidUrl, parseHttpsUrl("https://user@example.com/private"));
    try std.testing.expectError(error.InvalidUrl, parseHttpsUrl("https://example.com:not-a-port"));
    try std.testing.expect(requestWithinCap(64, 128, request_cap_bytes - 192));
    try std.testing.expect(!requestWithinCap(64, 128, request_cap_bytes - 191));
}

fn expectTestCommand(argv: []const []const u8) !void {
    var child = try std.process.spawn(std.testing.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    switch (try child.wait(std.testing.io)) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
}

fn waitForTestPort(path: []const u8) !u16 {
    const cwd = std.Io.Dir.cwd();
    for (0..250) |_| {
        const bytes = cwd.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(64)) catch {
            try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
            continue;
        };
        defer std.testing.allocator.free(bytes);
        const value = std.mem.trim(u8, bytes, " \r\n\t");
        if (value.len == 0) {
            try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
            continue;
        }
        return std.fmt.parseInt(u16, value, 10);
    }
    return error.TestUnexpectedResult;
}

const TestFetchContext = struct {
    request: *const Request,
    result: Result = .{},
};

fn testFetchWorker(context: *TestFetchContext) void {
    context.result = performWithTimeout(context.request, std.heap.page_allocator, 5_000);
}

test "macOS HTTPS transport preserves policy, bounds, timeout, trust, and cancellation" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const directory = ".zig-cache/weaver-network-macos-test";
    const certificate_pem = directory ++ "/certificate.pem";
    const certificate_der = directory ++ "/certificate.der";
    const private_key = directory ++ "/private-key.pem";
    const port_file = directory ++ "/port";
    // Test setup/teardown cleanup must not hide the transport assertion.
    cwd.deleteTree(io, directory) catch {};
    try cwd.createDirPath(io, directory);
    defer cwd.deleteTree(io, directory) catch {};

    try expectTestCommand(&.{
        "/usr/bin/openssl", "req",           "-x509",   "-nodes",                                    "-newkey", "rsa:2048",
        "-keyout",          private_key,     "-out",    certificate_pem,                             "-days",   "1",
        "-subj",            "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
    });
    try expectTestCommand(&.{
        "/usr/bin/openssl", "x509", "-in", certificate_pem, "-outform", "DER", "-out", certificate_der,
    });

    var server = try std.process.spawn(io, .{
        .argv = &.{
            "python3", "test/https_server.py", "--cert",      certificate_pem,
            "--key",   private_key,            "--port-file", port_file,
        },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    defer server.kill(io);
    const port = try waitForTestPort(port_file);

    const base = try std.fmt.allocPrint(std.testing.allocator, "https://localhost:{d}", .{port});
    defer std.testing.allocator.free(base);

    const success_url = try std.fmt.allocPrint(std.testing.allocator, "{s}/success", .{base});
    defer std.testing.allocator.free(success_url);
    var success = performWithTimeout(&.{
        .url = success_url,
        .headers = "X-Weaver-Test: alpha\r\n",
        .test_certificate_path = certificate_der,
    }, std.testing.allocator, 2_000);
    defer success.deinit(std.testing.allocator);
    try std.testing.expectEqual(Failure.none, success.failure);
    try std.testing.expectEqual(@as(u16, 200), success.status);
    try std.testing.expectEqualStrings("GET|alpha|ok", success.body.?);

    const post_url = try std.fmt.allocPrint(std.testing.allocator, "{s}/echo", .{base});
    defer std.testing.allocator.free(post_url);
    var post = performWithTimeout(&.{
        .method = .post,
        .url = post_url,
        .headers = "X-Weaver-Test: beta\r\nContent-Type: text/plain\r\n",
        .body = "payload",
        .test_certificate_path = certificate_der,
    }, std.testing.allocator, 2_000);
    defer post.deinit(std.testing.allocator);
    try std.testing.expectEqual(Failure.none, post.failure);
    try std.testing.expectEqual(@as(u16, 201), post.status);
    try std.testing.expectEqualStrings("POST|beta|payload", post.body.?);

    const redirect_url = try std.fmt.allocPrint(std.testing.allocator, "{s}/redirect", .{base});
    defer std.testing.allocator.free(redirect_url);
    var redirect = performWithTimeout(&.{
        .url = redirect_url,
        .test_certificate_path = certificate_der,
    }, std.testing.allocator, 2_000);
    defer redirect.deinit(std.testing.allocator);
    try std.testing.expectEqual(Failure.none, redirect.failure);
    try std.testing.expectEqual(@as(u16, 302), redirect.status);

    const oversized_url = try std.fmt.allocPrint(std.testing.allocator, "{s}/oversized", .{base});
    defer std.testing.allocator.free(oversized_url);
    var oversized = performWithTimeout(&.{
        .url = oversized_url,
        .test_certificate_path = certificate_der,
    }, std.testing.allocator, 2_000);
    defer oversized.deinit(std.testing.allocator);
    try std.testing.expectEqual(Failure.response_too_large, oversized.failure);

    const slow_url = try std.fmt.allocPrint(std.testing.allocator, "{s}/slow", .{base});
    defer std.testing.allocator.free(slow_url);
    var timed_out = performWithTimeout(&.{
        .url = slow_url,
        .test_certificate_path = certificate_der,
    }, std.testing.allocator, 100);
    defer timed_out.deinit(std.testing.allocator);
    try std.testing.expectEqual(Failure.timed_out, timed_out.failure);

    var untrusted = performWithTimeout(&.{ .url = success_url }, std.testing.allocator, 2_000);
    defer untrusted.deinit(std.testing.allocator);
    try std.testing.expectEqual(Failure.request_failed, untrusted.failure);

    var cancelled = std.atomic.Value(u8).init(0);
    const cancel_request = Request{
        .url = slow_url,
        .cancelled = &cancelled,
        .test_certificate_path = certificate_der,
    };
    var cancellation_context = TestFetchContext{ .request = &cancel_request };
    const cancellation_started = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const cancellation_thread = try std.Thread.spawn(.{}, testFetchWorker, .{&cancellation_context});
    try std.Io.sleep(io, .fromMilliseconds(100), .awake);
    cancelled.store(1, .release);
    cancellation_thread.join();
    const cancellation_elapsed = std.Io.Timestamp.now(io, .awake).nanoseconds - cancellation_started;
    defer cancellation_context.result.deinit(std.heap.page_allocator);
    try std.testing.expectEqual(Failure.cancelled, cancellation_context.result.failure);
    try std.testing.expect(cancellation_elapsed < std.time.ns_per_s);
}
