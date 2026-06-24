const std = @import("std");
const vk = @import("vulkan");
const abi = @import("abi.zig");
const Context = @import("vk_context.zig").Context;

const vertex_spv align(@alignOf(u32)) = @embedFile("vertex_spv").*;
const fragment_spv align(@alignOf(u32)) = @embedFile("fragment_spv").*;

pub const Renderer = struct {
    pub const DrawResult = enum { rendered, skipped, recreate };

    allocator: std.mem.Allocator,
    ctx: *Context,
    world_width: u32,
    world_height: u32,
    padded_width: u32,
    seed: u32,
    cells: vk.Buffer,
    channel_flags: u32,
    prefer_immediate: bool,
    view_mode: abi.RenderView = .cells,

    descriptor_layout: vk.DescriptorSetLayout,
    descriptor_pool: vk.DescriptorPool,
    descriptor_set: vk.DescriptorSet,
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline = .null_handle,

    swapchain: vk.SwapchainKHR = .null_handle,
    format: vk.Format = .undefined,
    extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    images: []vk.Image = &.{},
    views: []vk.ImageView = &.{},
    initialized: []bool = &.{},
    render_done: []vk.Semaphore = &.{},

    command_pool: vk.CommandPool,
    command_buffer: vk.CommandBuffer,
    fence: vk.Fence,
    image_ready: vk.Semaphore,
    query_pool: vk.QueryPool,
    last_render_ms: f64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *Context,
        world_width: u32,
        world_height: u32,
        padded_width: u32,
        seed: u32,
        cells: vk.Buffer,
        motion: vk.Buffer,
        disturbance: vk.Buffer,
        pressure: vk.Buffer,
        channel_flags: u32,
        client_width: u32,
        client_height: u32,
        prefer_immediate: bool,
    ) !Renderer {
        var self: Renderer = undefined;
        self.allocator = allocator;
        self.ctx = ctx;
        self.world_width = world_width;
        self.world_height = world_height;
        self.padded_width = padded_width;
        self.seed = seed;
        self.cells = cells;
        self.channel_flags = channel_flags;
        self.prefer_immediate = prefer_immediate;

        var bindings: [4]vk.DescriptorSetLayoutBinding = undefined;
        for (&bindings, 0..) |*binding, index| binding.* = .{
            .binding = @intCast(index),
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
            .p_immutable_samplers = null,
        };
        self.descriptor_layout = try ctx.device.createDescriptorSetLayout(&.{
            .binding_count = bindings.len,
            .p_bindings = &bindings,
        }, null);
        errdefer ctx.device.destroyDescriptorSetLayout(self.descriptor_layout, null);
        self.pipeline_layout = try ctx.device.createPipelineLayout(&.{
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&self.descriptor_layout),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = &.{.{
                .stage_flags = .{ .fragment_bit = true },
                .offset = 0,
                .size = @sizeOf(abi.RenderPush),
            }},
        }, null);
        errdefer ctx.device.destroyPipelineLayout(self.pipeline_layout, null);
        self.descriptor_pool = try ctx.device.createDescriptorPool(&.{
            .max_sets = 1,
            .pool_size_count = 1,
            .p_pool_sizes = &.{.{ .type = .storage_buffer, .descriptor_count = 4 }},
        }, null);
        errdefer ctx.device.destroyDescriptorPool(self.descriptor_pool, null);
        try ctx.device.allocateDescriptorSets(&.{
            .descriptor_pool = self.descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&self.descriptor_layout),
        }, @ptrCast(&self.descriptor_set));
        const buffers = [_]vk.Buffer{ cells, motion, disturbance, pressure };
        var buffer_infos: [4]vk.DescriptorBufferInfo = undefined;
        var writes: [4]vk.WriteDescriptorSet = undefined;
        for (buffers, 0..) |buffer, binding| {
            buffer_infos[binding] = .{ .buffer = buffer, .offset = 0, .range = vk.WHOLE_SIZE };
            writes[binding] = .{
                .dst_set = self.descriptor_set,
                .dst_binding = @intCast(binding),
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_image_info = undefined,
                .p_buffer_info = @ptrCast(&buffer_infos[binding]),
                .p_texel_buffer_view = undefined,
            };
        }
        ctx.device.updateDescriptorSets(&writes, null);

        self.command_pool = try ctx.device.createCommandPool(&.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = ctx.queue.family,
        }, null);
        errdefer ctx.device.destroyCommandPool(self.command_pool, null);
        try ctx.device.allocateCommandBuffers(&.{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&self.command_buffer));
        self.fence = try ctx.device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        errdefer ctx.device.destroyFence(self.fence, null);
        self.image_ready = try ctx.device.createSemaphore(&.{}, null);
        errdefer ctx.device.destroySemaphore(self.image_ready, null);
        self.query_pool = try ctx.device.createQueryPool(&.{ .query_type = .timestamp, .query_count = 2 }, null);
        errdefer ctx.device.destroyQueryPool(self.query_pool, null);
        self.swapchain = .null_handle;
        self.pipeline = .null_handle;
        self.images = &.{};
        self.views = &.{};
        self.initialized = &.{};
        self.render_done = &.{};
        self.last_render_ms = 0;
        self.view_mode = .cells;
        errdefer self.destroySwapchain();
        try self.recreate(client_width, client_height);
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        _ = self.ctx.device.deviceWaitIdle() catch {};
        self.destroySwapchain();
        if (self.pipeline != .null_handle) self.ctx.device.destroyPipeline(self.pipeline, null);
        self.ctx.device.destroyQueryPool(self.query_pool, null);
        self.ctx.device.destroySemaphore(self.image_ready, null);
        self.ctx.device.destroyFence(self.fence, null);
        self.ctx.device.destroyCommandPool(self.command_pool, null);
        self.ctx.device.destroyDescriptorPool(self.descriptor_pool, null);
        self.ctx.device.destroyPipelineLayout(self.pipeline_layout, null);
        self.ctx.device.destroyDescriptorSetLayout(self.descriptor_layout, null);
    }

    pub fn recreate(self: *Renderer, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return;
        try self.ctx.device.deviceWaitIdle();

        const capabilities = try self.ctx.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.ctx.physical_device, self.ctx.surface);
        const formats = try self.ctx.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(self.ctx.physical_device, self.ctx.surface, self.allocator);
        defer self.allocator.free(formats);
        const modes = try self.ctx.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(self.ctx.physical_device, self.ctx.surface, self.allocator);
        defer self.allocator.free(modes);
        if (formats.len == 0 or modes.len == 0) return error.SurfaceUnsupported;

        var surface_format = formats[0];
        for (formats) |candidate| {
            if (candidate.format == .b8g8r8a8_srgb and candidate.color_space == .srgb_nonlinear_khr) {
                surface_format = candidate;
                break;
            }
        }
        var present_mode: vk.PresentModeKHR = .fifo_khr;
        if (self.prefer_immediate) {
            for (modes) |candidate| if (candidate == .immediate_khr) {
                present_mode = candidate;
                break;
            };
            if (present_mode != .immediate_khr) for (modes) |candidate| if (candidate == .mailbox_khr) {
                present_mode = candidate;
                break;
            };
        } else {
            for (modes) |candidate| if (candidate == .mailbox_khr) {
                present_mode = candidate;
                break;
            };
        }
        std.log.info("swapchain present mode: {s}", .{@tagName(present_mode)});
        const unconstrained = capabilities.current_extent.width == std.math.maxInt(u32);
        const extent = if (unconstrained) vk.Extent2D{
            .width = std.math.clamp(width, capabilities.min_image_extent.width, capabilities.max_image_extent.width),
            .height = std.math.clamp(height, capabilities.min_image_extent.height, capabilities.max_image_extent.height),
        } else capabilities.current_extent;
        var image_count = capabilities.min_image_count + 1;
        if (capabilities.max_image_count != 0) image_count = @min(image_count, capabilities.max_image_count);

        const old_swapchain = self.swapchain;
        const new_swapchain = try self.ctx.device.createSwapchainKHR(&.{
            .surface = self.ctx.surface,
            .min_image_count = image_count,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .image_sharing_mode = .exclusive,
            .pre_transform = capabilities.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = present_mode,
            .clipped = .true,
            .old_swapchain = old_swapchain,
        }, null);

        self.destroySwapchainResources(false);
        if (old_swapchain != .null_handle) self.ctx.device.destroySwapchainKHR(old_swapchain, null);
        self.swapchain = new_swapchain;
        self.extent = extent;
        const old_format = self.format;
        self.format = surface_format.format;
        const images = try self.ctx.device.getSwapchainImagesAllocKHR(self.swapchain, self.allocator);
        errdefer self.allocator.free(images);
        const views = try self.allocator.alloc(vk.ImageView, images.len);
        errdefer self.allocator.free(views);
        const initialized = try self.allocator.alloc(bool, images.len);
        errdefer self.allocator.free(initialized);
        @memset(initialized, false);
        const render_done = try self.allocator.alloc(vk.Semaphore, images.len);
        errdefer self.allocator.free(render_done);
        var made: usize = 0;
        errdefer {
            for (views[0..made], render_done[0..made]) |view, semaphore| {
                self.ctx.device.destroyImageView(view, null);
                self.ctx.device.destroySemaphore(semaphore, null);
            }
        }
        for (images, 0..) |image, index| {
            const view = try self.ctx.device.createImageView(&.{
                .image = image,
                .view_type = .@"2d",
                .format = self.format,
                .components = .{
                    .r = .identity,
                    .g = .identity,
                    .b = .identity,
                    .a = .identity,
                },
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            }, null);
            const semaphore = self.ctx.device.createSemaphore(&.{}, null) catch |err| {
                self.ctx.device.destroyImageView(view, null);
                return err;
            };
            views[index] = view;
            render_done[index] = semaphore;
            made += 1;
        }
        if (self.pipeline == .null_handle or old_format != self.format) {
            if (self.pipeline != .null_handle) {
                self.ctx.device.destroyPipeline(self.pipeline, null);
                self.pipeline = .null_handle;
            }
            self.pipeline = try createGraphicsPipeline(self.ctx, self.pipeline_layout, self.format);
        }
        self.images = images;
        self.views = views;
        self.initialized = initialized;
        self.render_done = render_done;
    }

    pub fn setUncappedPresentation(self: *Renderer, enabled: bool, width: u32, height: u32) !void {
        if (self.prefer_immediate == enabled) return;
        self.prefer_immediate = enabled;
        try self.recreate(width, height);
    }

    pub fn cycleView(self: *Renderer) void {
        self.view_mode = switch (self.view_mode) {
            .cells => .motion,
            .motion => .disturbance,
            .disturbance => .pressure,
            .pressure => .cells,
        };
    }

    pub fn viewName(self: *const Renderer) []const u8 {
        return @tagName(self.view_mode);
    }

    /// Acquisition is deliberately non-blocking: while the compositor owns all
    /// swapchain images, the application can spend that time simulating.
    pub fn draw(self: *Renderer) !DrawResult {
        _ = try self.ctx.device.waitForFences(&.{self.fence}, .true, std.math.maxInt(u64));
        self.collectTiming();

        const acquired = self.ctx.device.acquireNextImageKHR(
            self.swapchain,
            0,
            self.image_ready,
            .null_handle,
        ) catch |err| switch (err) {
            error.OutOfDateKHR => return .recreate,
            else => return err,
        };
        if (acquired.result == .not_ready or acquired.result == .timeout) return .skipped;
        const acquired_suboptimal = acquired.result == .suboptimal_khr;
        const index: usize = acquired.image_index;

        try self.ctx.device.resetFences(&.{self.fence});
        try self.ctx.device.resetCommandBuffer(self.command_buffer, .{});
        try self.ctx.device.beginCommandBuffer(self.command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });
        self.ctx.device.cmdResetQueryPool(self.command_buffer, self.query_pool, 0, 2);
        self.ctx.device.cmdWriteTimestamp2(self.command_buffer, .{ .top_of_pipe_bit = true }, self.query_pool, 0);

        const to_color = vk.ImageMemoryBarrier2{
            .src_stage_mask = if (self.initialized[index]) .{ .all_commands_bit = true } else .{ .top_of_pipe_bit = true },
            .src_access_mask = .{},
            .dst_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_access_mask = .{ .color_attachment_write_bit = true },
            .old_layout = if (self.initialized[index]) .present_src_khr else .undefined,
            .new_layout = .color_attachment_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.images[index],
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        const cells_ready = vk.MemoryBarrier2{
            .src_stage_mask = .{ .compute_shader_bit = true },
            .src_access_mask = .{ .shader_storage_write_bit = true },
            .dst_stage_mask = .{ .fragment_shader_bit = true },
            .dst_access_mask = .{ .shader_storage_read_bit = true },
        };
        self.ctx.device.cmdPipelineBarrier2(self.command_buffer, &.{
            .memory_barrier_count = 1,
            .p_memory_barriers = @ptrCast(&cells_ready),
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&to_color),
        });

        const color = vk.RenderingAttachmentInfo{
            .image_view = self.views[index],
            .image_layout = .color_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .color = .{ .float_32 = .{ 0.002, 0.003, 0.005, 1.0 } } },
        };
        self.ctx.device.cmdBeginRendering(self.command_buffer, &.{
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color),
        });
        self.ctx.device.cmdBindPipeline(self.command_buffer, .graphics, self.pipeline);
        self.ctx.device.cmdBindDescriptorSets(self.command_buffer, .graphics, self.pipeline_layout, 0, &.{self.descriptor_set}, null);
        self.ctx.device.cmdSetViewport(self.command_buffer, 0, &.{.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(self.extent.width),
            .height = @floatFromInt(self.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        }});
        self.ctx.device.cmdSetScissor(self.command_buffer, 0, &.{.{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.extent,
        }});
        const push = abi.RenderPush{
            .width = self.world_width,
            .height = self.world_height,
            .padded_width = self.padded_width,
            .viewport_width = self.extent.width,
            .viewport_height = self.extent.height,
            .seed = self.seed,
            .view_mode = @intFromEnum(self.view_mode),
            .channel_flags = self.channel_flags,
        };
        self.ctx.device.cmdPushConstants(self.command_buffer, self.pipeline_layout, .{ .fragment_bit = true }, 0, @sizeOf(abi.RenderPush), &push);
        self.ctx.device.cmdDraw(self.command_buffer, 3, 1, 0, 0);
        self.ctx.device.cmdEndRendering(self.command_buffer);

        const to_present = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .src_access_mask = .{ .color_attachment_write_bit = true },
            .dst_stage_mask = .{ .bottom_of_pipe_bit = true },
            .dst_access_mask = .{},
            .old_layout = .color_attachment_optimal,
            .new_layout = .present_src_khr,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.images[index],
            .subresource_range = to_color.subresource_range,
        };
        self.ctx.device.cmdPipelineBarrier2(self.command_buffer, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&to_present),
        });
        self.ctx.device.cmdWriteTimestamp2(self.command_buffer, .{ .bottom_of_pipe_bit = true }, self.query_pool, 1);
        try self.ctx.device.endCommandBuffer(self.command_buffer);

        const wait_info = vk.SemaphoreSubmitInfo{
            .semaphore = self.image_ready,
            .value = 0,
            .stage_mask = .{ .color_attachment_output_bit = true },
            .device_index = 0,
        };
        const command_info = vk.CommandBufferSubmitInfo{ .command_buffer = self.command_buffer, .device_mask = 0 };
        const signal_info = vk.SemaphoreSubmitInfo{
            .semaphore = self.render_done[index],
            .value = 0,
            .stage_mask = .{ .all_commands_bit = true },
            .device_index = 0,
        };
        try self.ctx.device.queueSubmit2(self.ctx.queue.handle, &.{.{
            .wait_semaphore_info_count = 1,
            .p_wait_semaphore_infos = @ptrCast(&wait_info),
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = @ptrCast(&command_info),
            .signal_semaphore_info_count = 1,
            .p_signal_semaphore_infos = @ptrCast(&signal_info),
        }}, self.fence);
        self.initialized[index] = true;

        const present_result = self.ctx.device.queuePresentKHR(self.ctx.queue.handle, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&self.render_done[index]),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.swapchain),
            .p_image_indices = @ptrCast(&acquired.image_index),
        }) catch |err| switch (err) {
            error.OutOfDateKHR => return .recreate,
            else => return err,
        };
        return if (acquired_suboptimal or present_result == .suboptimal_khr) .recreate else .rendered;
    }

    fn collectTiming(self: *Renderer) void {
        var values: [2]u64 = .{ 0, 0 };
        const result = self.ctx.device.getQueryPoolResults(
            self.query_pool,
            0,
            2,
            @sizeOf(@TypeOf(values)),
            &values,
            @sizeOf(u64),
            .{ .@"64_bit" = true },
        ) catch return;
        if (result == .success and values[1] >= values[0]) {
            const period = @as(f64, self.ctx.properties.limits.timestamp_period) / 1_000_000.0;
            self.last_render_ms = @as(f64, @floatFromInt(values[1] - values[0])) * period;
        }
    }

    fn destroySwapchain(self: *Renderer) void {
        self.destroySwapchainResources(true);
    }

    fn destroySwapchainResources(self: *Renderer, destroy_swapchain: bool) void {
        for (self.views) |view| self.ctx.device.destroyImageView(view, null);
        for (self.render_done) |semaphore| self.ctx.device.destroySemaphore(semaphore, null);
        if (self.views.len != 0) self.allocator.free(self.views);
        if (self.render_done.len != 0) self.allocator.free(self.render_done);
        if (self.initialized.len != 0) self.allocator.free(self.initialized);
        if (self.images.len != 0) self.allocator.free(self.images);
        self.views = &.{};
        self.render_done = &.{};
        self.initialized = &.{};
        self.images = &.{};
        if (destroy_swapchain and self.swapchain != .null_handle) {
            self.ctx.device.destroySwapchainKHR(self.swapchain, null);
            self.swapchain = .null_handle;
        }
    }
};

fn createGraphicsPipeline(ctx: *Context, layout: vk.PipelineLayout, format: vk.Format) !vk.Pipeline {
    const vertex_module = try ctx.device.createShaderModule(&.{ .code_size = vertex_spv.len, .p_code = @ptrCast(&vertex_spv) }, null);
    defer ctx.device.destroyShaderModule(vertex_module, null);
    const fragment_module = try ctx.device.createShaderModule(&.{ .code_size = fragment_spv.len, .p_code = @ptrCast(&fragment_spv) }, null);
    defer ctx.device.destroyShaderModule(fragment_module, null);
    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex_bit = true }, .module = vertex_module, .p_name = "VertexMain" },
        .{ .stage = .{ .fragment_bit = true }, .module = fragment_module, .p_name = "FragmentMain" },
    };
    const vertex_input = vk.PipelineVertexInputStateCreateInfo{};
    const assembly = vk.PipelineInputAssemblyStateCreateInfo{ .topology = .triangle_list, .primitive_restart_enable = .false };
    const viewport = vk.PipelineViewportStateCreateInfo{ .viewport_count = 1, .scissor_count = 1 };
    const raster = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .{},
        .front_face = .clockwise,
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };
    const multisample = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 0,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };
    const attachment = vk.PipelineColorBlendAttachmentState{
        .blend_enable = .false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };
    const blend = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&attachment),
        .blend_constants = .{ 0, 0, 0, 0 },
    };
    const states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic = vk.PipelineDynamicStateCreateInfo{ .dynamic_state_count = states.len, .p_dynamic_states = &states };
    const rendering = vk.PipelineRenderingCreateInfo{
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachment_formats = @ptrCast(&format),
        .depth_attachment_format = .undefined,
        .stencil_attachment_format = .undefined,
    };
    var pipeline: vk.Pipeline = undefined;
    _ = try ctx.device.createGraphicsPipelines(.null_handle, &.{.{
        .p_next = &rendering,
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = &vertex_input,
        .p_input_assembly_state = &assembly,
        .p_viewport_state = &viewport,
        .p_rasterization_state = &raster,
        .p_multisample_state = &multisample,
        .p_color_blend_state = &blend,
        .p_dynamic_state = &dynamic,
        .layout = layout,
        .render_pass = .null_handle,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    }}, null, (&pipeline)[0..1]);
    return pipeline;
}
