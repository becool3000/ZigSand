const std = @import("std");

pub const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});

pub const Key = enum(u8) {
    escape = c.VK_ESCAPE,
    space = c.VK_SPACE,
    period = c.VK_OEM_PERIOD,
    one = '1',
    two = '2',
    three = '3',
    clear = 'C',
    reset = 'R',
    turbo = 'T',
};

pub const Window = struct {
    hwnd: c.HWND,
    hinstance: c.HINSTANCE,
    quit: bool = false,
    resized: bool = false,
    client_width: u32 = 1,
    client_height: u32 = 1,
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    left_down: bool = false,
    right_down: bool = false,
    wheel_steps: i32 = 0,
    pressed: [256]bool = .{false} ** 256,

    pub fn init(self: *Window, width: u32, height: u32) !void {
        self.* = .{
            .hwnd = null,
            .hinstance = c.GetModuleHandleW(null) orelse return error.GetModuleHandleFailed,
        };

        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigSandWindow");
        const window_class = c.WNDCLASSEXW{
            .cbSize = @sizeOf(c.WNDCLASSEXW),
            .style = c.CS_HREDRAW | c.CS_VREDRAW | c.CS_OWNDC,
            .lpfnWndProc = windowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.hinstance,
            .hIcon = null,
            .hCursor = c.LoadCursorW(null, @ptrFromInt(32512)),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };
        if (c.RegisterClassExW(&window_class) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
            return error.RegisterWindowClassFailed;

        var rect = c.RECT{ .left = 0, .top = 0, .right = @intCast(width), .bottom = @intCast(height) };
        if (c.AdjustWindowRectEx(&rect, c.WS_OVERLAPPEDWINDOW, c.FALSE, 0) == c.FALSE)
            return error.AdjustWindowRectFailed;
        self.hwnd = c.CreateWindowExW(
            0,
            class_name,
            std.unicode.utf8ToUtf16LeStringLiteral("ZigSand"),
            c.WS_OVERLAPPEDWINDOW,
            c.CW_USEDEFAULT,
            c.CW_USEDEFAULT,
            rect.right - rect.left,
            rect.bottom - rect.top,
            null,
            null,
            self.hinstance,
            @ptrCast(self),
        ) orelse return error.CreateWindowFailed;
        self.updateClientSize();
        _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
        _ = c.UpdateWindow(self.hwnd);
        return;
    }

    pub fn deinit(self: *Window) void {
        if (self.hwnd != null and c.IsWindow(self.hwnd) != c.FALSE) _ = c.DestroyWindow(self.hwnd);
        self.hwnd = null;
    }

    pub fn poll(self: *Window) void {
        _ = self;
        var message: c.MSG = undefined;
        while (c.PeekMessageW(&message, null, 0, 0, c.PM_REMOVE) != c.FALSE) {
            _ = c.TranslateMessage(&message);
            _ = c.DispatchMessageW(&message);
        }
    }

    pub fn consumeKey(self: *Window, key: Key) bool {
        const index: usize = @intFromEnum(key);
        const value = self.pressed[index];
        self.pressed[index] = false;
        return value;
    }

    pub fn consumeWheel(self: *Window) i32 {
        const value = self.wheel_steps;
        self.wheel_steps = 0;
        return value;
    }

    pub fn consumeResize(self: *Window) bool {
        const value = self.resized;
        self.resized = false;
        return value;
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        _ = c.SetWindowTextA(self.hwnd, title.ptr);
    }

    fn updateClientSize(self: *Window) void {
        var rect: c.RECT = undefined;
        if (c.GetClientRect(self.hwnd, &rect) != c.FALSE) {
            self.client_width = @intCast(@max(0, rect.right - rect.left));
            self.client_height = @intCast(@max(0, rect.bottom - rect.top));
        }
    }
};

fn signedLow(value: c.LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(value))))));
}

fn signedHigh(value: c.LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(value)) >> 16))));
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    var window: ?*Window = null;
    if (message == c.WM_NCCREATE) {
        const create: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        window = @ptrCast(@alignCast(create.lpCreateParams));
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(window.?)));
        window.?.hwnd = hwnd;
    } else {
        const raw = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
        if (raw != 0) window = @ptrFromInt(@as(usize, @bitCast(raw)));
    }

    if (window) |self| switch (message) {
        c.WM_CLOSE => {
            _ = c.DestroyWindow(hwnd);
            return 0;
        },
        c.WM_DESTROY => {
            self.quit = true;
            c.PostQuitMessage(0);
            return 0;
        },
        c.WM_SIZE => {
            self.client_width = @intCast(@as(usize, @bitCast(lparam)) & 0xffff);
            self.client_height = @intCast((@as(usize, @bitCast(lparam)) >> 16) & 0xffff);
            self.resized = true;
            return 0;
        },
        c.WM_MOUSEMOVE => {
            self.mouse_x = signedLow(lparam);
            self.mouse_y = signedHigh(lparam);
            return 0;
        },
        c.WM_LBUTTONDOWN => {
            self.left_down = true;
            _ = c.SetCapture(hwnd);
            return 0;
        },
        c.WM_LBUTTONUP => {
            self.left_down = false;
            if (!self.right_down) _ = c.ReleaseCapture();
            return 0;
        },
        c.WM_RBUTTONDOWN => {
            self.right_down = true;
            _ = c.SetCapture(hwnd);
            return 0;
        },
        c.WM_RBUTTONUP => {
            self.right_down = false;
            if (!self.left_down) _ = c.ReleaseCapture();
            return 0;
        },
        c.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @truncate((wparam >> 16) & 0xffff)));
            self.wheel_steps += @divTrunc(@as(i32, delta), c.WHEEL_DELTA);
            return 0;
        },
        c.WM_KEYDOWN => {
            if ((@as(usize, @bitCast(lparam)) & (@as(usize, 1) << 30)) == 0 and wparam < self.pressed.len)
                self.pressed[@intCast(wparam)] = true;
            return 0;
        },
        else => {},
    };
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}
