const std = @import("std");
const vk = @import("vulkan");
const win32 = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});

const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;

pub const SurfaceTarget = struct {
    hinstance: std.os.windows.HINSTANCE,
    hwnd: std.os.windows.HWND,
};

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    loader: win32.HMODULE,
    base: BaseWrapper,
    instance: vk.InstanceProxy,
    debug_messenger: vk.DebugUtilsMessengerEXT = .null_handle,
    surface: vk.SurfaceKHR = .null_handle,
    physical_device: vk.PhysicalDevice,
    properties: vk.PhysicalDeviceProperties,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    device: vk.DeviceProxy,
    queue: Queue,
    validation_enabled: bool,

    pub fn init(allocator: std.mem.Allocator, target: ?SurfaceTarget, request_validation: bool) !Context {
        var self: Context = undefined;
        self.allocator = allocator;
        self.loader = win32.LoadLibraryA("vulkan-1.dll") orelse return error.VulkanLoaderNotFound;
        errdefer _ = win32.FreeLibrary(self.loader);
        const get_instance_proc_addr: vk.PfnGetInstanceProcAddr = @ptrCast(
            win32.GetProcAddress(self.loader, "vkGetInstanceProcAddr") orelse
                return error.VulkanLoaderMissingEntryPoint,
        );
        self.base = BaseWrapper.load(get_instance_proc_addr);

        const validation_available = try hasLayer(&self.base, allocator, "VK_LAYER_KHRONOS_validation");
        self.validation_enabled = request_validation and validation_available;
        if (request_validation and !validation_available) {
            std.log.warn("VK_LAYER_KHRONOS_validation is unavailable; continuing without validation", .{});
        }

        if (target != null) {
            if (!try hasInstanceExtension(&self.base, allocator, vk.extensions.khr_surface.name) or
                !try hasInstanceExtension(&self.base, allocator, vk.extensions.khr_win_32_surface.name))
                return error.RequiredSurfaceExtensionUnavailable;
        }
        const debug_utils_available = self.validation_enabled and
            try hasInstanceExtension(&self.base, allocator, vk.extensions.ext_debug_utils.name);
        if (self.validation_enabled and !debug_utils_available)
            std.log.warn("VK_EXT_debug_utils is unavailable; validation messages may only reach the system log", .{});

        var extensions: [3][*:0]const u8 = undefined;
        var extension_count: usize = 0;
        if (target != null) {
            extensions[extension_count] = vk.extensions.khr_surface.name;
            extension_count += 1;
            extensions[extension_count] = vk.extensions.khr_win_32_surface.name;
            extension_count += 1;
        }
        if (debug_utils_available) {
            extensions[extension_count] = vk.extensions.ext_debug_utils.name;
            extension_count += 1;
        }
        const validation_layer = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
        const app_name: [*:0]const u8 = "ZigSand";
        const instance_handle = try self.base.createInstance(&.{
            .p_application_info = &.{
                .p_application_name = app_name,
                .application_version = vk.makeApiVersion(0, 0, 1, 0).toU32(),
                .p_engine_name = app_name,
                .engine_version = vk.makeApiVersion(0, 0, 1, 0).toU32(),
                .api_version = vk.API_VERSION_1_3.toU32(),
            },
            .enabled_layer_count = if (self.validation_enabled) 1 else 0,
            .pp_enabled_layer_names = if (self.validation_enabled) @ptrCast(&validation_layer) else null,
            .enabled_extension_count = @intCast(extension_count),
            .pp_enabled_extension_names = if (extension_count != 0) extensions[0..extension_count].ptr else null,
        }, null);
        const instance_wrapper = try allocator.create(InstanceWrapper);
        errdefer allocator.destroy(instance_wrapper);
        instance_wrapper.* = InstanceWrapper.load(instance_handle, self.base.dispatch.vkGetInstanceProcAddr.?);
        self.instance = vk.InstanceProxy.init(instance_handle, instance_wrapper);
        errdefer self.instance.destroyInstance(null);

        if (debug_utils_available) {
            self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&.{
                .message_severity = .{ .warning_bit_ext = true, .error_bit_ext = true },
                .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
                .pfn_user_callback = debugCallback,
            }, null);
        } else self.debug_messenger = .null_handle;

        if (target) |window| {
            self.surface = try self.instance.createWin32SurfaceKHR(&.{
                .hinstance = window.hinstance,
                .hwnd = window.hwnd,
            }, null);
        } else self.surface = .null_handle;
        errdefer if (self.surface != .null_handle) self.instance.destroySurfaceKHR(self.surface, null);

        const candidate = try pickDevice(self.instance, allocator, self.surface);
        self.physical_device = candidate.device;
        self.properties = candidate.properties;
        self.memory_properties = self.instance.getPhysicalDeviceMemoryProperties(candidate.device);

        const priority = [_]f32{1.0};
        var features13 = vk.PhysicalDeviceVulkan13Features{
            .synchronization_2 = .true,
            .dynamic_rendering = .true,
        };
        const swapchain_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};
        const device_handle = try self.instance.createDevice(candidate.device, &.{
            .p_next = &features13,
            .queue_create_info_count = 1,
            .p_queue_create_infos = &.{.{
                .queue_family_index = candidate.queue_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            }},
            .enabled_extension_count = if (self.surface != .null_handle) 1 else 0,
            .pp_enabled_extension_names = if (self.surface != .null_handle) @ptrCast(&swapchain_extensions) else null,
        }, null);
        const device_wrapper = try allocator.create(DeviceWrapper);
        errdefer allocator.destroy(device_wrapper);
        device_wrapper.* = DeviceWrapper.load(device_handle, self.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
        self.device = vk.DeviceProxy.init(device_handle, device_wrapper);
        errdefer self.device.destroyDevice(null);
        self.queue = .{ .handle = self.device.getDeviceQueue(candidate.queue_family, 0), .family = candidate.queue_family };

        std.log.info("Vulkan device: {s}", .{std.mem.sliceTo(&self.properties.device_name, 0)});
        return self;
    }

    pub fn deinit(self: *Context) void {
        self.device.destroyDevice(null);
        self.allocator.destroy(self.device.wrapper);
        if (self.surface != .null_handle) self.instance.destroySurfaceKHR(self.surface, null);
        if (self.debug_messenger != .null_handle) self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
        self.instance.destroyInstance(null);
        self.allocator.destroy(self.instance.wrapper);
        _ = win32.FreeLibrary(self.loader);
    }

    pub fn findMemoryType(self: *const Context, bits: u32, required: vk.MemoryPropertyFlags) !u32 {
        for (self.memory_properties.memory_types[0..self.memory_properties.memory_type_count], 0..) |memory_type, index| {
            if ((bits & (@as(u32, 1) << @intCast(index))) != 0 and memory_type.property_flags.contains(required))
                return @intCast(index);
        }
        return error.NoSuitableMemoryType;
    }
};

const Candidate = struct {
    device: vk.PhysicalDevice,
    properties: vk.PhysicalDeviceProperties,
    queue_family: u32,
    score: u32,
};

fn pickDevice(instance: vk.InstanceProxy, allocator: std.mem.Allocator, surface: vk.SurfaceKHR) !Candidate {
    const devices = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(devices);
    var best: ?Candidate = null;
    for (devices) |device| {
        const properties = instance.getPhysicalDeviceProperties(device);
        if (properties.api_version < vk.API_VERSION_1_3.toU32()) continue;
        if (properties.limits.timestamp_compute_and_graphics != .true) continue;
        if (surface != .null_handle and !try hasDeviceExtension(instance, allocator, device, vk.extensions.khr_swapchain.name)) continue;

        var features13 = vk.PhysicalDeviceVulkan13Features{};
        var features2 = vk.PhysicalDeviceFeatures2{ .p_next = &features13, .features = .{} };
        instance.getPhysicalDeviceFeatures2(device, &features2);
        if (features13.synchronization_2 != .true or features13.dynamic_rendering != .true) continue;

        const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(device, allocator);
        defer allocator.free(families);
        for (families, 0..) |family, index| {
            if (!family.queue_flags.graphics_bit or !family.queue_flags.compute_bit) continue;
            if (surface != .null_handle and try instance.getPhysicalDeviceSurfaceSupportKHR(device, @intCast(index), surface) != .true) continue;
            const score: u32 = if (properties.device_type == .discrete_gpu) 1000 else 100;
            const candidate = Candidate{ .device = device, .properties = properties, .queue_family = @intCast(index), .score = score };
            if (best == null or candidate.score > best.?.score) best = candidate;
            break;
        }
    }
    return best orelse error.NoVulkan13Device;
}

fn hasLayer(base: *const BaseWrapper, allocator: std.mem.Allocator, wanted: []const u8) !bool {
    const layers = try base.enumerateInstanceLayerPropertiesAlloc(allocator);
    defer allocator.free(layers);
    for (layers) |layer| if (std.mem.eql(u8, wanted, std.mem.sliceTo(&layer.layer_name, 0))) return true;
    return false;
}

fn hasInstanceExtension(base: *const BaseWrapper, allocator: std.mem.Allocator, wanted: [*:0]const u8) !bool {
    const extensions = try base.enumerateInstanceExtensionPropertiesAlloc(null, allocator);
    defer allocator.free(extensions);
    for (extensions) |extension|
        if (std.mem.eql(u8, std.mem.span(wanted), std.mem.sliceTo(&extension.extension_name, 0))) return true;
    return false;
}

fn hasDeviceExtension(instance: vk.InstanceProxy, allocator: std.mem.Allocator, device: vk.PhysicalDevice, wanted: [*:0]const u8) !bool {
    const extensions = try instance.enumerateDeviceExtensionPropertiesAlloc(device, null, allocator);
    defer allocator.free(extensions);
    for (extensions) |extension| if (std.mem.eql(u8, std.mem.span(wanted), std.mem.sliceTo(&extension.extension_name, 0))) return true;
    return false;
}

fn debugCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_type: vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(.c) vk.Bool32 {
    _ = message_type;
    const message: [*c]const u8 = if (callback_data) |data| data.p_message else "Vulkan validation message unavailable";
    if (severity.error_bit_ext) std.log.err("Vulkan: {s}", .{message}) else std.log.warn("Vulkan: {s}", .{message});
    return .false;
}
