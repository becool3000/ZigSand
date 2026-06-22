const std = @import("std");
const abi = @import("abi.zig");

/// Startup-only linear layout helper for packing future Vulkan allocations.
/// It performs layout arithmetic only; no allocation can occur in a frame loop.
pub const LinearLayout = struct {
    capacity: u64,
    cursor: u64 = 0,

    pub fn reserve(self: *LinearLayout, size: u64, alignment: u64) !u64 {
        const offset = abi.alignUp(self.cursor, alignment);
        if (offset > self.capacity or size > self.capacity - offset) return error.OutOfDeviceArena;
        self.cursor = offset + size;
        return offset;
    }
};

test "device-memory suballocations honor alignment and capacity" {
    var layout = LinearLayout{ .capacity = 1024 };
    try std.testing.expectEqual(@as(u64, 0), try layout.reserve(129, 64));
    try std.testing.expectEqual(@as(u64, 256), try layout.reserve(200, 256));
    try std.testing.expectEqual(@as(u64, 512), try layout.reserve(128, 512));
    try std.testing.expectError(error.OutOfDeviceArena, layout.reserve(512, 256));
}
