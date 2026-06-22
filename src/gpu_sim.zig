const std = @import("std");
const vk = @import("vulkan");
const abi = @import("abi.zig");
const material = @import("material.zig");
const Context = @import("vk_context.zig").Context;

const init_spv align(@alignOf(u32)) = @embedFile("init_spv").*;
const activity_spv align(@alignOf(u32)) = @embedFile("activity_spv").*;
const paint_spv align(@alignOf(u32)) = @embedFile("paint_spv").*;
const intent_spv align(@alignOf(u32)) = @embedFile("intent_spv").*;
const resolve_spv align(@alignOf(u32)) = @embedFile("resolve_spv").*;
const commit_spv align(@alignOf(u32)) = @embedFile("commit_spv").*;
const validate_spv align(@alignOf(u32)) = @embedFile("validate_spv").*;

pub const Config = struct {
    width: u32,
    height: u32,
    seed: u32,
    enable_motion: bool = true,
};
pub const Brush = struct { x: u32, y: u32, radius: u32, material: abi.Material };
pub const Timings = struct {
    intent_ms: f64 = 0,
    resolve_ms: f64 = 0,
    commit_ms: f64 = 0,
    total_ms: f64 = 0,
    active_chunks: u32 = 0,
};

const Buffer = struct {
    handle: vk.Buffer,
    memory: vk.DeviceMemory,
    size: vk.DeviceSize,
    mapped: ?*anyopaque = null,

    fn init(ctx: *Context, size: vk.DeviceSize, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags, mapped: bool) !Buffer {
        const handle = try ctx.device.createBuffer(&.{ .size = size, .usage = usage, .sharing_mode = .exclusive }, null);
        errdefer ctx.device.destroyBuffer(handle, null);
        const requirements = ctx.device.getBufferMemoryRequirements(handle);
        const memory = try ctx.device.allocateMemory(&.{
            .allocation_size = requirements.size,
            .memory_type_index = try ctx.findMemoryType(requirements.memory_type_bits, properties),
        }, null);
        errdefer ctx.device.freeMemory(memory, null);
        try ctx.device.bindBufferMemory(handle, memory, 0);
        const pointer = if (mapped) try ctx.device.mapMemory(memory, 0, size, .{}) else null;
        return .{ .handle = handle, .memory = memory, .size = size, .mapped = pointer };
    }

    fn deinit(self: *Buffer, ctx: *Context) void {
        if (self.mapped != null) ctx.device.unmapMemory(self.memory);
        ctx.device.destroyBuffer(self.handle, null);
        ctx.device.freeMemory(self.memory, null);
        self.* = undefined;
    }
};

const Activity = struct {
    flags: Buffer,
    list: Buffer,
    meta: Buffer,
    args: Buffer,

    fn init(ctx: *Context, chunk_count: u32) !Activity {
        const storage = vk.BufferUsageFlags{ .storage_buffer_bit = true, .transfer_dst_bit = true, .transfer_src_bit = true };
        var flags = try Buffer.init(ctx, @as(u64, chunk_count) * 4, storage, .{ .device_local_bit = true }, false);
        errdefer flags.deinit(ctx);
        var list = try Buffer.init(ctx, @as(u64, chunk_count) * 4, storage, .{ .device_local_bit = true }, false);
        errdefer list.deinit(ctx);
        var meta = try Buffer.init(ctx, 4, storage, .{ .device_local_bit = true }, false);
        errdefer meta.deinit(ctx);
        var args = try Buffer.init(ctx, 12, .{ .storage_buffer_bit = true, .indirect_buffer_bit = true, .transfer_dst_bit = true }, .{ .device_local_bit = true }, false);
        errdefer args.deinit(ctx);
        return .{ .flags = flags, .list = list, .meta = meta, .args = args };
    }

    fn deinit(self: *Activity, ctx: *Context) void {
        self.args.deinit(ctx);
        self.meta.deinit(ctx);
        self.list.deinit(ctx);
        self.flags.deinit(ctx);
    }
};

const Pipelines = struct {
    init: vk.Pipeline,
    activity: vk.Pipeline,
    paint: vk.Pipeline,
    intent: vk.Pipeline,
    resolve: vk.Pipeline,
    commit: vk.Pipeline,
    validate: vk.Pipeline,

    fn deinit(self: Pipelines, ctx: *Context) void {
        inline for (std.meta.fields(Pipelines)) |field| ctx.device.destroyPipeline(@field(self, field.name), null);
    }
};

const in_flight_ticks = 3;

const TickSlot = struct {
    command_buffer: vk.CommandBuffer,
    fence: vk.Fence,
    query_pool: vk.QueryPool,
    stats_readback: Buffer,
    pending: bool = false,

    fn init(ctx: *Context, command_buffer: vk.CommandBuffer) !TickSlot {
        const fence = try ctx.device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        errdefer ctx.device.destroyFence(fence, null);
        const query_pool = try ctx.device.createQueryPool(&.{ .query_type = .timestamp, .query_count = 8 }, null);
        errdefer ctx.device.destroyQueryPool(query_pool, null);
        const stats = try Buffer.init(ctx, 4, .{ .transfer_dst_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true }, true);
        return .{ .command_buffer = command_buffer, .fence = fence, .query_pool = query_pool, .stats_readback = stats };
    }

    fn deinit(self: *TickSlot, ctx: *Context) void {
        self.stats_readback.deinit(ctx);
        ctx.device.destroyQueryPool(self.query_pool, null);
        ctx.device.destroyFence(self.fence, null);
    }
};

pub const Simulation = struct {
    ctx: *Context,
    config: Config,
    padded_width: u32,
    padded_height: u32,
    chunks_x: u32,
    chunks_y: u32,
    chunk_count: u32,
    cells: Buffer,
    scratch: Buffer,
    intents: Buffer,
    material_specs: Buffer,
    motion: Buffer,
    activity: [2]Activity,
    results: Buffer,
    descriptor_layout: vk.DescriptorSetLayout,
    descriptor_pool: vk.DescriptorPool,
    descriptor_sets: [2]vk.DescriptorSet,
    pipeline_layout: vk.PipelineLayout,
    pipelines: Pipelines,
    command_pool: vk.CommandPool,
    sync_command_buffer: vk.CommandBuffer,
    command_buffer: vk.CommandBuffer,
    fence: vk.Fence,
    tick_slots: [in_flight_ticks]TickSlot,
    tick_slot: usize = 0,
    parity: u1 = 0,
    tick_index: u32 = 0,
    last_timings: Timings = .{},

    pub fn init(ctx: *Context, config: Config) !Simulation {
        const registry = material.MaterialRegistry.builtins();
        return initWithMaterials(ctx, config, &registry);
    }

    /// Custom registries are validated and copied to device-local memory during
    /// startup. The simulation does not retain this pointer or upload specs in
    /// the tick loop, leaving a clean future seam for material tooling.
    pub fn initWithMaterials(ctx: *Context, config: Config, registry: *const material.MaterialRegistry) !Simulation {
        try registry.validate(&.{});
        var self: Simulation = undefined;
        self.ctx = ctx;
        self.config = config;
        self.padded_width = abi.padded(config.width);
        self.padded_height = abi.padded(config.height);
        self.chunks_x = self.padded_width / abi.chunk_size;
        self.chunks_y = self.padded_height / abi.chunk_size;
        self.chunk_count = self.chunks_x * self.chunks_y;
        const cell_bytes = @as(u64, self.padded_width) * self.padded_height * 4;
        const cell_usage = vk.BufferUsageFlags{ .storage_buffer_bit = true, .transfer_dst_bit = true, .transfer_src_bit = true };
        self.cells = try Buffer.init(ctx, cell_bytes, cell_usage, .{ .device_local_bit = true }, false);
        errdefer self.cells.deinit(ctx);
        self.scratch = try Buffer.init(ctx, cell_bytes, cell_usage, .{ .device_local_bit = true }, false);
        errdefer self.scratch.deinit(ctx);
        self.intents = try Buffer.init(ctx, cell_bytes, cell_usage, .{ .device_local_bit = true }, false);
        errdefer self.intents.deinit(ctx);
        self.material_specs = try Buffer.init(ctx, @sizeOf(material.MaterialSpec) * material.max_materials, .{
            .storage_buffer_bit = true,
            .transfer_dst_bit = true,
        }, .{ .device_local_bit = true }, false);
        errdefer self.material_specs.deinit(ctx);
        self.motion = try Buffer.init(ctx, if (config.enable_motion) cell_bytes else @sizeOf(u32), .{
            .storage_buffer_bit = true,
        }, .{ .device_local_bit = true }, false);
        errdefer self.motion.deinit(ctx);
        self.activity[0] = try Activity.init(ctx, self.chunk_count);
        errdefer self.activity[0].deinit(ctx);
        self.activity[1] = try Activity.init(ctx, self.chunk_count);
        errdefer self.activity[1].deinit(ctx);
        self.results = try Buffer.init(ctx, @sizeOf(abi.TestResult), .{ .storage_buffer_bit = true, .transfer_dst_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true }, true);
        errdefer self.results.deinit(ctx);

        self.descriptor_layout = try createDescriptorLayout(ctx);
        errdefer ctx.device.destroyDescriptorSetLayout(self.descriptor_layout, null);
        self.pipeline_layout = try ctx.device.createPipelineLayout(&.{
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&self.descriptor_layout),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = &.{.{
                .stage_flags = .{ .compute_bit = true },
                .offset = 0,
                .size = @sizeOf(abi.SimPush),
            }},
        }, null);
        errdefer ctx.device.destroyPipelineLayout(self.pipeline_layout, null);
        self.descriptor_pool = try ctx.device.createDescriptorPool(&.{
            .max_sets = 2,
            .pool_size_count = 1,
            .p_pool_sizes = &.{.{ .type = .storage_buffer, .descriptor_count = 28 }},
        }, null);
        errdefer ctx.device.destroyDescriptorPool(self.descriptor_pool, null);
        const layouts = [_]vk.DescriptorSetLayout{ self.descriptor_layout, self.descriptor_layout };
        try ctx.device.allocateDescriptorSets(&.{
            .descriptor_pool = self.descriptor_pool,
            .descriptor_set_count = layouts.len,
            .p_set_layouts = &layouts,
        }, &self.descriptor_sets);
        self.updateDescriptorSet(0, 0, 1);
        self.updateDescriptorSet(1, 1, 0);

        self.pipelines = .{
            .init = try createPipeline(ctx, self.pipeline_layout, &init_spv, "InitMain"),
            .activity = try createPipeline(ctx, self.pipeline_layout, &activity_spv, "InitActivityMain"),
            .paint = try createPipeline(ctx, self.pipeline_layout, &paint_spv, "PaintMain"),
            .intent = try createPipeline(ctx, self.pipeline_layout, &intent_spv, "IntentMain"),
            .resolve = try createPipeline(ctx, self.pipeline_layout, &resolve_spv, "ResolveMain"),
            .commit = try createPipeline(ctx, self.pipeline_layout, &commit_spv, "CommitMain"),
            .validate = try createPipeline(ctx, self.pipeline_layout, &validate_spv, "ValidateMain"),
        };
        errdefer self.pipelines.deinit(ctx);
        self.command_pool = try ctx.device.createCommandPool(&.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = ctx.queue.family,
        }, null);
        errdefer ctx.device.destroyCommandPool(self.command_pool, null);
        var command_buffers: [in_flight_ticks + 1]vk.CommandBuffer = undefined;
        try ctx.device.allocateCommandBuffers(&.{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = command_buffers.len,
        }, &command_buffers);
        self.sync_command_buffer = command_buffers[0];
        self.command_buffer = self.sync_command_buffer;
        self.fence = try ctx.device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        errdefer ctx.device.destroyFence(self.fence, null);
        var slots_initialized: usize = 0;
        errdefer for (self.tick_slots[0..slots_initialized]) |*slot| slot.deinit(ctx);
        for (&self.tick_slots, 0..) |*slot, index| {
            slot.* = try TickSlot.init(ctx, command_buffers[index + 1]);
            slots_initialized += 1;
        }
        self.tick_slot = 0;
        self.parity = 0;
        self.tick_index = 0;
        self.last_timings = .{};
        try self.uploadMaterialSpecs(registry.gpuSlice());
        try self.resetScenario(0);
        return self;
    }

    pub fn deinit(self: *Simulation) void {
        self.wait() catch {};
        for (&self.tick_slots) |*slot| slot.deinit(self.ctx);
        self.ctx.device.destroyFence(self.fence, null);
        self.ctx.device.destroyCommandPool(self.command_pool, null);
        self.pipelines.deinit(self.ctx);
        self.ctx.device.destroyDescriptorPool(self.descriptor_pool, null);
        self.ctx.device.destroyPipelineLayout(self.pipeline_layout, null);
        self.ctx.device.destroyDescriptorSetLayout(self.descriptor_layout, null);
        self.results.deinit(self.ctx);
        self.activity[1].deinit(self.ctx);
        self.activity[0].deinit(self.ctx);
        self.motion.deinit(self.ctx);
        self.material_specs.deinit(self.ctx);
        self.intents.deinit(self.ctx);
        self.scratch.deinit(self.ctx);
        self.cells.deinit(self.ctx);
    }

    pub fn resetScenario(self: *Simulation, test_case: u32) !void {
        try self.waitTicks();
        try self.begin();
        const push = self.makePush(test_case, null);
        self.bind(self.pipelines.init, 0, &push);
        self.ctx.device.cmdDispatch(self.command_buffer, divCeil(self.padded_width, 16), divCeil(self.padded_height, 16), 1);
        self.computeBarrier();
        self.bind(self.pipelines.activity, 0, &push);
        self.ctx.device.cmdDispatch(self.command_buffer, divCeil(self.chunk_count, 256), 1, 1);
        self.computeBarrier();
        try self.endSubmitWait();
        self.parity = 0;
        self.tick_index = 0;
    }

    pub fn tick(self: *Simulation, brush: ?Brush) !Timings {
        return self.tickInternal(brush, false);
    }

    /// Benchmark path: preserve the same simulation kernels while forcing every
    /// chunk into the next compact list, producing a repeatable worst-case load.
    pub fn tickFullyActive(self: *Simulation) !Timings {
        return self.tickInternal(null, true);
    }

    fn tickInternal(self: *Simulation, brush: ?Brush, force_all_active: bool) !Timings {
        // The command order is the simulation contract: metadata clear/paint,
        // intent, destination-centric resolve, active-only commit, then list-role
        // swap. Barriers make that order explicit on every Vulkan 1.3 driver.
        const slot = &self.tick_slots[self.tick_slot];
        _ = try self.ctx.device.waitForFences(&.{slot.fence}, .true, std.math.maxInt(u64));
        if (slot.pending) self.collectTimings(slot);
        try self.ctx.device.resetFences(&.{slot.fence});
        try self.ctx.device.resetCommandBuffer(slot.command_buffer, .{});
        self.command_buffer = slot.command_buffer;
        try self.ctx.device.beginCommandBuffer(self.command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });
        const set_index: usize = self.parity;
        const next_index: usize = 1 - set_index;
        const next = &self.activity[next_index];
        self.ctx.device.cmdResetQueryPool(self.command_buffer, slot.query_pool, 0, 8);
        self.ctx.device.cmdWriteTimestamp2(self.command_buffer, .{ .top_of_pipe_bit = true }, slot.query_pool, 0);
        self.ctx.device.cmdFillBuffer(self.command_buffer, next.flags.handle, 0, vk.WHOLE_SIZE, 0);
        self.ctx.device.cmdFillBuffer(self.command_buffer, next.meta.handle, 0, 4, 0);
        self.ctx.device.cmdFillBuffer(self.command_buffer, next.args.handle, 0, 4, 0);
        self.transferToComputeBarrier();

        const push = self.makePush(0, brush);
        if (brush) |value| {
            self.bind(self.pipelines.paint, set_index, &push);
            const diameter = value.radius * 2 + 1;
            self.ctx.device.cmdDispatch(self.command_buffer, divCeil(diameter, 16), divCeil(diameter, 16), 1);
            self.computeToIndirectBarrier();
        }

        self.bind(self.pipelines.intent, set_index, &push);
        self.ctx.device.cmdDispatchIndirect(self.command_buffer, self.activity[set_index].args.handle, 0);
        self.ctx.device.cmdWriteTimestamp2(self.command_buffer, .{ .compute_shader_bit = true }, slot.query_pool, 1);
        self.computeBarrier();
        self.bind(self.pipelines.resolve, set_index, &push);
        self.ctx.device.cmdDispatchIndirect(self.command_buffer, self.activity[set_index].args.handle, 0);
        self.ctx.device.cmdWriteTimestamp2(self.command_buffer, .{ .compute_shader_bit = true }, slot.query_pool, 2);
        self.computeBarrier();
        self.bind(self.pipelines.commit, set_index, &push);
        self.ctx.device.cmdDispatchIndirect(self.command_buffer, self.activity[set_index].args.handle, 0);
        self.ctx.device.cmdWriteTimestamp2(self.command_buffer, .{ .compute_shader_bit = true }, slot.query_pool, 3);
        self.computeBarrier();
        if (force_all_active) {
            self.bind(self.pipelines.activity, next_index, &push);
            self.ctx.device.cmdDispatch(self.command_buffer, divCeil(self.chunk_count, 256), 1, 1);
            self.computeBarrier();
        }
        self.ctx.device.cmdCopyBuffer(self.command_buffer, next.meta.handle, slot.stats_readback.handle, &.{.{ .src_offset = 0, .dst_offset = 0, .size = 4 }});
        self.ctx.device.cmdWriteTimestamp2(self.command_buffer, .{ .bottom_of_pipe_bit = true }, slot.query_pool, 4);
        try self.ctx.device.endCommandBuffer(self.command_buffer);
        const command_info = vk.CommandBufferSubmitInfo{ .command_buffer = self.command_buffer, .device_mask = 0 };
        try self.ctx.device.queueSubmit2(self.ctx.queue.handle, &.{.{
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = @ptrCast(&command_info),
        }}, slot.fence);
        slot.pending = true;

        self.parity = @intCast(next_index);
        self.tick_index +%= 1;
        self.tick_slot = (self.tick_slot + 1) % in_flight_ticks;
        self.command_buffer = self.sync_command_buffer;
        return self.last_timings;
    }

    pub fn validate(self: *Simulation, test_case: u32) !abi.TestResult {
        try self.waitTicks();
        @as(*abi.TestResult, @ptrCast(@alignCast(self.results.mapped.?))).* = .{};
        try self.begin();
        const prior_set: usize = 1 - @as(usize, self.parity);
        var push = self.makePush(test_case, null);
        if (push.tick != 0) push.tick -= 1;
        self.bind(self.pipelines.validate, prior_set, &push);
        self.ctx.device.cmdDispatch(self.command_buffer, 1, 1, 1);
        self.computeBarrier();
        try self.endSubmitWait();
        return @as(*const abi.TestResult, @ptrCast(@alignCast(self.results.mapped.?))).*;
    }

    pub fn wait(self: *Simulation) !void {
        try self.waitTicks();
        try self.waitSync();
    }

    fn waitSync(self: *Simulation) !void {
        _ = try self.ctx.device.waitForFences(&.{self.fence}, .true, std.math.maxInt(u64));
    }

    fn waitTicks(self: *Simulation) !void {
        var fences: [in_flight_ticks]vk.Fence = undefined;
        for (self.tick_slots, 0..) |slot, index| fences[index] = slot.fence;
        _ = try self.ctx.device.waitForFences(&fences, .true, std.math.maxInt(u64));
        for (&self.tick_slots) |*slot| if (slot.pending) {
            self.collectTimings(slot);
            slot.pending = false;
        };
    }

    pub fn cellBuffer(self: *const Simulation) vk.Buffer {
        return self.cells.handle;
    }

    fn begin(self: *Simulation) !void {
        self.command_buffer = self.sync_command_buffer;
        try self.waitSync();
        try self.ctx.device.resetFences(&.{self.fence});
        try self.ctx.device.resetCommandBuffer(self.command_buffer, .{});
        try self.ctx.device.beginCommandBuffer(self.command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });
    }

    fn uploadMaterialSpecs(self: *Simulation, specs: []const material.MaterialSpec) !void {
        std.debug.assert(specs.len == material.max_materials);
        const bytes = std.mem.sliceAsBytes(specs);
        var staging = try Buffer.init(self.ctx, bytes.len, .{ .transfer_src_bit = true }, .{
            .host_visible_bit = true,
            .host_coherent_bit = true,
        }, true);
        defer staging.deinit(self.ctx);
        const destination: [*]u8 = @ptrCast(staging.mapped.?);
        @memcpy(destination[0..bytes.len], bytes);

        try self.begin();
        self.ctx.device.cmdCopyBuffer(self.command_buffer, staging.handle, self.material_specs.handle, &.{.{
            .src_offset = 0,
            .dst_offset = 0,
            .size = bytes.len,
        }});
        self.transferToComputeBarrier();
        try self.endSubmitWait();
    }

    fn endSubmitWait(self: *Simulation) !void {
        try self.ctx.device.endCommandBuffer(self.command_buffer);
        const command_info = vk.CommandBufferSubmitInfo{ .command_buffer = self.command_buffer, .device_mask = 0 };
        try self.ctx.device.queueSubmit2(self.ctx.queue.handle, &.{.{
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = @ptrCast(&command_info),
        }}, self.fence);
        try self.waitSync();
    }

    fn bind(self: *Simulation, pipeline: vk.Pipeline, set_index: usize, push: *const abi.SimPush) void {
        self.ctx.device.cmdBindPipeline(self.command_buffer, .compute, pipeline);
        self.ctx.device.cmdBindDescriptorSets(self.command_buffer, .compute, self.pipeline_layout, 0, &.{self.descriptor_sets[set_index]}, null);
        self.ctx.device.cmdPushConstants(self.command_buffer, self.pipeline_layout, .{ .compute_bit = true }, 0, @sizeOf(abi.SimPush), push);
    }

    fn makePush(self: *const Simulation, test_case: u32, brush: ?Brush) abi.SimPush {
        var push = abi.SimPush{
            .width = self.config.width,
            .height = self.config.height,
            .padded_width = self.padded_width,
            .padded_height = self.padded_height,
            .chunks_x = self.chunks_x,
            .chunks_y = self.chunks_y,
            .tick = self.tick_index,
            .seed = self.config.seed,
            .test_case = test_case,
            .channel_flags = if (self.config.enable_motion) abi.channel_motion else 0,
        };
        if (brush) |value| {
            push.brush_x = value.x;
            push.brush_y = value.y;
            push.brush_radius = @min(value.radius, abi.max_brush_radius);
            push.brush_material = @intFromEnum(value.material);
            push.command_flags = 1;
        }
        return push;
    }

    fn updateDescriptorSet(self: *Simulation, set_index: usize, now_index: usize, next_index: usize) void {
        const buffers = [_]*const Buffer{
            &self.cells,                     &self.scratch,                    &self.intents,
            &self.activity[now_index].flags, &self.activity[now_index].list,   &self.activity[now_index].meta,
            &self.activity[now_index].args,  &self.activity[next_index].flags, &self.activity[next_index].list,
            &self.activity[next_index].meta, &self.activity[next_index].args,  &self.results,
            &self.material_specs,            &self.motion,
        };
        var infos: [14]vk.DescriptorBufferInfo = undefined;
        var writes: [14]vk.WriteDescriptorSet = undefined;
        for (buffers, 0..) |buffer, binding| {
            infos[binding] = .{ .buffer = buffer.handle, .offset = 0, .range = buffer.size };
            writes[binding] = .{
                .dst_set = self.descriptor_sets[set_index],
                .dst_binding = @intCast(binding),
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_image_info = undefined,
                .p_buffer_info = @ptrCast(&infos[binding]),
                .p_texel_buffer_view = undefined,
            };
        }
        self.ctx.device.updateDescriptorSets(&writes, null);
    }

    fn computeBarrier(self: *Simulation) void {
        const barrier = vk.MemoryBarrier2{
            .src_stage_mask = .{ .compute_shader_bit = true },
            .src_access_mask = .{ .shader_storage_write_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .shader_storage_read_bit = true, .shader_storage_write_bit = true },
        };
        self.ctx.device.cmdPipelineBarrier2(self.command_buffer, &.{ .memory_barrier_count = 1, .p_memory_barriers = @ptrCast(&barrier) });
    }

    fn transferToComputeBarrier(self: *Simulation) void {
        const barrier = vk.MemoryBarrier2{
            .src_stage_mask = .{ .all_transfer_bit = true },
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .shader_storage_read_bit = true, .shader_storage_write_bit = true },
        };
        self.ctx.device.cmdPipelineBarrier2(self.command_buffer, &.{ .memory_barrier_count = 1, .p_memory_barriers = @ptrCast(&barrier) });
    }

    fn computeToIndirectBarrier(self: *Simulation) void {
        const barrier = vk.MemoryBarrier2{
            .src_stage_mask = .{ .compute_shader_bit = true },
            .src_access_mask = .{ .shader_storage_write_bit = true },
            .dst_stage_mask = .{ .draw_indirect_bit = true, .compute_shader_bit = true },
            .dst_access_mask = .{ .indirect_command_read_bit = true, .shader_storage_read_bit = true },
        };
        self.ctx.device.cmdPipelineBarrier2(self.command_buffer, &.{ .memory_barrier_count = 1, .p_memory_barriers = @ptrCast(&barrier) });
    }

    fn collectTimings(self: *Simulation, slot: *const TickSlot) void {
        var values: [5]u64 = .{0} ** 5;
        const result = self.ctx.device.getQueryPoolResults(slot.query_pool, 0, values.len, @sizeOf(@TypeOf(values)), &values, @sizeOf(u64), .{ .@"64_bit" = true }) catch return;
        if (result != .success) return;
        const period = @as(f64, self.ctx.properties.limits.timestamp_period) / 1_000_000.0;
        self.last_timings.intent_ms = @as(f64, @floatFromInt(values[1] - values[0])) * period;
        self.last_timings.resolve_ms = @as(f64, @floatFromInt(values[2] - values[1])) * period;
        self.last_timings.commit_ms = @as(f64, @floatFromInt(values[3] - values[2])) * period;
        self.last_timings.total_ms = @as(f64, @floatFromInt(values[4] - values[0])) * period;
        self.last_timings.active_chunks = @as(*const u32, @ptrCast(@alignCast(slot.stats_readback.mapped.?))).*;
    }
};

fn createDescriptorLayout(ctx: *Context) !vk.DescriptorSetLayout {
    var bindings: [14]vk.DescriptorSetLayoutBinding = undefined;
    for (&bindings, 0..) |*binding, index| binding.* = .{
        .binding = @intCast(index),
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .compute_bit = true },
        .p_immutable_samplers = null,
    };
    return try ctx.device.createDescriptorSetLayout(&.{ .binding_count = bindings.len, .p_bindings = &bindings }, null);
}

fn createPipeline(ctx: *Context, layout: vk.PipelineLayout, code: []align(4) const u8, entry: [*:0]const u8) !vk.Pipeline {
    const module = try ctx.device.createShaderModule(&.{ .code_size = code.len, .p_code = @ptrCast(code.ptr) }, null);
    defer ctx.device.destroyShaderModule(module, null);
    var pipeline: vk.Pipeline = undefined;
    _ = try ctx.device.createComputePipelines(.null_handle, &.{.{
        .stage = .{ .stage = .{ .compute_bit = true }, .module = module, .p_name = entry },
        .layout = layout,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    }}, null, (&pipeline)[0..1]);
    return pipeline;
}

fn divCeil(value: u32, divisor: u32) u32 {
    return (value + divisor - 1) / divisor;
}
