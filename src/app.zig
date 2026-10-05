const std = @import("std");
const cli = @import("cli.zig");
const Context = @import("vk_context.zig").Context;
const SurfaceTarget = @import("vk_context.zig").SurfaceTarget;
const gpu = @import("gpu_sim.zig");
const abi = @import("abi.zig");
const win32 = @import("win32.zig");
const Renderer = @import("renderer.zig").Renderer;
const coordinates = @import("coordinates.zig");

pub fn run(allocator: std.mem.Allocator, options: cli.Options) !void {
    switch (options.mode) {
        .gpu_tests => try runGpuTests(allocator, options),
        .benchmark => try runBenchmark(allocator, options),
        .interactive => try runInteractive(allocator, options),
    }
}

fn runInteractive(allocator: std.mem.Allocator, options: cli.Options) !void {
    var window: win32.Window = undefined;
    try window.init(1280, 720);
    defer window.deinit();

    var context = try Context.init(allocator, SurfaceTarget{
        .hinstance = @ptrCast(window.hinstance),
        .hwnd = @ptrCast(window.hwnd),
    }, options.validation);
    defer context.deinit();
    var simulation = try gpu.Simulation.init(&context, .{
        .width = options.width,
        .height = options.height,
        .seed = options.seed,
    });
    defer simulation.deinit();
    var renderer = try Renderer.init(
        allocator,
        &context,
        options.width,
        options.height,
        simulation.padded_width,
        options.seed,
        simulation.cellBuffer(),
        simulation.motionBuffer(),
        simulation.disturbanceBuffer(),
        simulation.pressureBuffer(),
        simulation.channelFlags(),
        window.client_width,
        window.client_height,
        options.uncapped,
    );
    defer renderer.deinit();

    var paused = false;
    var uncapped = options.uncapped;
    var single_step = false;
    var selected: abi.Material = .sand;
    var brush_radius: u32 = 8;
    var camera_center_x: f32 = @as(f32, @floatFromInt(options.width)) * 0.5;
    var camera_center_y: f32 = @as(f32, @floatFromInt(options.height)) * 0.5;
    var camera_zoom: f32 = 1;
    const tick_seconds = 1.0 / @as(f64, @floatFromInt(options.tps));
    var previous = secondsNow();
    var accumulator: f64 = 0;
    var report_start = previous;
    var frames: u32 = 0;
    var ticks: u32 = 0;

    while (!window.quit) {
        window.poll();
        if (window.consumeKey(.escape)) break;
        if (window.consumeKey(.space)) paused = !paused;
        if (window.consumeKey(.period)) single_step = true;
        if (window.consumeKey(.turbo)) {
            uncapped = !uncapped;
            try renderer.setUncappedPresentation(uncapped, window.client_width, window.client_height);
        }
        if (window.consumeKey(.view)) renderer.cycleView();
        if (window.consumeKey(.one)) selected = .sand;
        if (window.consumeKey(.two)) selected = .water;
        if (window.consumeKey(.three)) selected = .stone;
        const wheel = window.consumeWheel();
        if (wheel != 0) {
            const next = @as(i32, @intCast(brush_radius)) + wheel;
            brush_radius = @intCast(std.math.clamp(next, 1, @as(i32, abi.max_brush_radius)));
        }
        if (window.consumeKey(.clear)) try simulation.resetScenario(255);
        if (window.consumeKey(.reset)) try simulation.resetScenario(0);

        const now = secondsNow();
        const elapsed = @min(now - previous, 0.25);
        previous = now;
        if (!paused) accumulator += elapsed;
        updateCameraFromInput(&window, options.width, options.height, @floatCast(elapsed), &camera_center_x, &camera_center_y, &camera_zoom);
        renderer.setCamera(camera_center_x, camera_center_y, camera_zoom);

        if (uncapped and !paused) {
            // Saturate simulation for most of a 60 Hz frame while preserving a
            // small presentation/input budget. The safety limit matters only
            // after a completely sleeping world makes individual ticks tiny.
            const turbo_deadline = secondsNow() + 0.002;
            var turbo_ticks: u32 = 0;
            while (secondsNow() < turbo_deadline and turbo_ticks < 1024) : (turbo_ticks += 1) {
                const brush = mapBrush(&window, options.width, options.height, brush_radius, selected, camera_center_x, camera_center_y, camera_zoom);
                _ = try simulation.tick(brush);
                ticks += 1;
            }
            accumulator = 0;
        } else {
            var catch_up: u32 = 0;
            while ((!paused and accumulator >= tick_seconds and catch_up < 4) or single_step) {
                const brush = mapBrush(&window, options.width, options.height, brush_radius, selected, camera_center_x, camera_center_y, camera_zoom);
                _ = try simulation.tick(brush);
                ticks += 1;
                catch_up += 1;
                single_step = false;
                if (!paused) accumulator -= tick_seconds;
            }
            if (catch_up == 4 and accumulator >= tick_seconds) accumulator = 0;
        }

        if (window.client_width == 0 or window.client_height == 0) {
            win32.c.Sleep(16);
            continue;
        }
        if (window.consumeResize()) try renderer.recreate(window.client_width, window.client_height);
        switch (try renderer.draw()) {
            .rendered => frames += 1,
            .skipped => if (!uncapped) win32.c.Sleep(1),
            .recreate => try renderer.recreate(window.client_width, window.client_height),
        }

        if (now - report_start >= 1.0) {
            var title_storage: [256]u8 = undefined;
            const title = std.fmt.bufPrintZ(
                &title_storage,
                "ZigSand | {d} FPS | {d} TPS{s} | {d}/{d} chunks | GPU I {d:.2} R {d:.2} P {d:.2} D {d:.2} C {d:.2} Draw {d:.2} ms | view {s} | zoom {d:.1}x | brush {d}{s}",
                .{
                    frames,
                    ticks,
                    if (uncapped) " UNCAPPED" else "",
                    simulation.last_timings.active_chunks,
                    simulation.chunk_count,
                    simulation.last_timings.intent_ms,
                    simulation.last_timings.resolve_ms,
                    simulation.last_timings.pressure_ms,
                    simulation.last_timings.disturbance_ms,
                    simulation.last_timings.commit_ms,
                    renderer.last_render_ms,
                    renderer.viewName(),
                    camera_zoom,
                    brush_radius,
                    if (paused) " | PAUSED" else "",
                },
            ) catch unreachable;
            window.setTitle(title);
            frames = 0;
            ticks = 0;
            report_start = now;
        }
    }
}

fn secondsNow() f64 {
    var frequency: win32.c.LARGE_INTEGER = undefined;
    var counter: win32.c.LARGE_INTEGER = undefined;
    _ = win32.c.QueryPerformanceFrequency(&frequency);
    _ = win32.c.QueryPerformanceCounter(&counter);
    return @as(f64, @floatFromInt(counter.QuadPart)) / @as(f64, @floatFromInt(frequency.QuadPart));
}

fn updateCameraFromInput(window: *const win32.Window, width: u32, height: u32, elapsed: f32, center_x: *f32, center_y: *f32, zoom: *f32) void {
    const zoom_step = std.math.pow(f32, 2.0, elapsed * 2.0);
    if (window.isDown(.e)) zoom.* *= zoom_step;
    if (window.isDown(.q)) zoom.* /= zoom_step;
    zoom.* = std.math.clamp(zoom.*, 1.0, 64.0);

    const visible_w = @as(f32, @floatFromInt(width)) / zoom.*;
    const visible_h = @as(f32, @floatFromInt(height)) / zoom.*;
    const pan_x = visible_w * 1.2 * elapsed;
    const pan_y = visible_h * 1.2 * elapsed;
    if (window.isDown(.a)) center_x.* -= pan_x;
    if (window.isDown(.d)) center_x.* += pan_x;
    if (window.isDown(.s)) center_y.* -= pan_y;
    if (window.isDown(.w)) center_y.* += pan_y;
    clampCamera(width, height, center_x, center_y, zoom);
}

fn clampCamera(width: u32, height: u32, center_x: *f32, center_y: *f32, zoom: *f32) void {
    zoom.* = std.math.clamp(zoom.*, 1.0, 64.0);
    const world_w: f32 = @floatFromInt(width);
    const world_h: f32 = @floatFromInt(height);
    const half_w = world_w / (zoom.* * 2.0);
    const half_h = world_h / (zoom.* * 2.0);
    center_x.* = std.math.clamp(center_x.*, half_w, world_w - half_w);
    center_y.* = std.math.clamp(center_y.*, half_h, world_h - half_h);
}

fn mapBrush(window: *const win32.Window, width: u32, height: u32, radius: u32, selected: abi.Material, camera_center_x: f32, camera_center_y: f32, zoom: f32) ?gpu.Brush {
    const material: abi.Material = if (window.right_down) .empty else if (window.left_down) selected else return null;
    const cell = coordinates.windowToCell(window.mouse_x, window.mouse_y, window.client_width, window.client_height, width, height, camera_center_x, camera_center_y, zoom) orelse return null;
    return .{ .x = cell.x, .y = cell.y, .radius = radius, .material = material };
}

fn runGpuTests(allocator: std.mem.Allocator, options: cli.Options) !void {
    var context = try Context.init(allocator, null, options.validation);
    defer context.deinit();
    var simulation = try gpu.Simulation.init(&context, .{ .width = 32, .height = 32, .seed = options.seed });
    defer simulation.deinit();

    var failures: u32 = 0;
    for (1..10) |test_case| {
        try simulation.resetScenario(@intCast(test_case));
        _ = try simulation.tick(null);
        const result = try simulation.validate(@intCast(test_case));
        if (result.failures != 0) {
            failures |= result.failures;
            std.log.err("GPU test case {d} failed: mask=0x{x}", .{ test_case, result.failures });
        }
    }
    for ([_]u32{ 20, 21, 22 }) |test_case| {
        try simulation.resetScenario(test_case);
        _ = try simulation.tick(null);
        const result = try simulation.validate(test_case);
        if (result.failures != 0) {
            failures |= result.failures;
            std.log.err("GPU atmosphere case {d} failed: mask=0x{x}", .{ test_case, result.failures });
        }
    }
    try simulation.resetScenario(24);
    _ = try simulation.tick(null);
    const sand_steam = try simulation.validate(24);
    if (sand_steam.failures != 0) {
        failures |= sand_steam.failures;
        std.log.err("GPU Sand/Steam swap case failed: mask=0x{x}", .{sand_steam.failures});
    }
    try simulation.resetScenario(25);
    for (0..4) |_| _ = try simulation.tick(null);
    const steam_escape = try simulation.validate(25);
    if (steam_escape.failures != 0) {
        failures |= steam_escape.failures;
        std.log.err("GPU Steam-under-Sand escape case failed: mask=0x{x}", .{steam_escape.failures});
    }

    try simulation.resetScenario(26);
    _ = try simulation.tick(null);
    const sand_avalanche_spread = try simulation.validate(26);
    if (sand_avalanche_spread.failures != 0) {
        failures |= sand_avalanche_spread.failures;
        std.log.err("GPU Sand avalanche spread case failed: mask=0x{x}", .{sand_avalanche_spread.failures});
    }

    try simulation.resetScenario(27);
    for (0..3) |_| _ = try simulation.tick(null);
    const settled_sand = try simulation.validate(27);
    if (settled_sand.failures != 0) {
        failures |= settled_sand.failures;
        std.log.err("GPU Sand settle case failed: mask=0x{x}", .{settled_sand.failures});
    }
    _ = try simulation.tick(.{ .x = 15, .y = 11, .radius = 0, .material = .empty });
    const disturbed_sand = try simulation.validate(28);
    if (disturbed_sand.failures != 0) {
        failures |= disturbed_sand.failures;
        std.log.err("GPU Sand disturbance wake case failed: mask=0x{x}", .{disturbed_sand.failures});
    }

    // Only compact validation records cross back to the host; canonical GPU
    // layers are reset and replayed independently for every run.
    const water_determinism = try runDeterminismCheck(&simulation, "Water basin", 15, 32, 100);
    failures |= water_determinism.failures;
    const sand_determinism = try runDeterminismCheck(&simulation, "Sand avalanche", 16, 10, 100);
    failures |= sand_determinism.failures;
    const sand_spread_determinism = try runDeterminismCheck(&simulation, "Sand avalanche spread", 26, 1, 100);
    failures |= sand_spread_determinism.failures;
    const disturbance_determinism = try runDeterminismCheck(&simulation, "Water disturbance", 17, 8, 100);
    failures |= disturbance_determinism.failures;
    const pressure_determinism = try runDeterminismCheck(&simulation, "Water pressure", 18, 12, 100);
    failures |= pressure_determinism.failures;
    const atmosphere_determinism = try runDeterminismCheck(&simulation, "Atmospheric cycle", 23, 32, 100);
    failures |= atmosphere_determinism.failures;
    failures |= try runMassConservationCheck(&simulation, "Demo atmosphere long cycle", 0, 8192, 75);
    failures |= try runMassConservationCheck(&simulation, "Atmospheric long cycle", 23, 8192, 13);

    // Once a blank world sleeps, repeated canonical/scratch ticks must neither
    // wake chunks nor mutate state.
    try simulation.resetScenario(10);
    _ = try simulation.tick(null);
    const sleeping = try simulation.validate(10);
    for (0..3) |_| {
        _ = try simulation.tick(null);
        const repeated = try simulation.validate(10);
        if (repeated.failures != 0 or repeated.active_count != 0 or repeated.state_hash != sleeping.state_hash) {
            std.log.err("sleeping chunk check failed: mask=0x{x} active={d} hash=0x{x}/0x{x}", .{ repeated.failures, repeated.active_count, repeated.state_hash, sleeping.state_hash });
            failures |= 512;
        }
    }

    try simulation.resetScenario(11);
    _ = try simulation.tick(null);
    const crossing = try simulation.validate(11);
    if (crossing.failures != 0) std.log.err("chunk-crossing check failed: mask=0x{x} active={d}", .{ crossing.failures, crossing.active_count });
    failures |= crossing.failures;

    // Painting directly across four chunk corners must activate each chunk once.
    try simulation.resetScenario(255);
    _ = try simulation.tick(.{ .x = 15, .y = 15, .radius = 2, .material = .stone });
    const painted = try simulation.validate(0);
    if (painted.active_count != 4 or (painted.failures & (65536 | 131072)) != 0) {
        std.log.err("boundary paint check failed: mask=0x{x} active={d}", .{ painted.failures, painted.active_count });
        failures |= 2048;
    }

    // A non-multiple-of-16 world keeps its padded storage solid and inaccessible.
    var odd_simulation = try gpu.Simulation.init(&context, .{ .width = 30, .height = 27, .seed = options.seed });
    defer odd_simulation.deinit();
    try odd_simulation.resetScenario(13);
    _ = try odd_simulation.tick(null);
    const odd = try odd_simulation.validate(13);
    if (odd.failures != 0) std.log.err("padded-boundary check failed: mask=0x{x}", .{odd.failures});
    failures |= odd.failures;

    // Exercise the optional-channel ownership branches independently.
    var pressure_only_simulation = try gpu.Simulation.init(&context, .{
        .width = 32,
        .height = 32,
        .seed = options.seed,
        .enable_disturbance = false,
    });
    defer pressure_only_simulation.deinit();
    try pressure_only_simulation.resetScenario(18);
    for (0..12) |_| _ = try pressure_only_simulation.tick(null);
    const pressure_only = try pressure_only_simulation.validate(18);
    if (pressure_only.failures != 0 or pressure_only.pressure_hash == 0 or pressure_only.pressurized_cells < 100) {
        std.log.err("pressure-only channel check failed: mask=0x{x} pressure=0x{x} cells={d}", .{ pressure_only.failures, pressure_only.pressure_hash, pressure_only.pressurized_cells });
        failures |= 262144;
    }

    var disturbance_only_simulation = try gpu.Simulation.init(&context, .{
        .width = 32,
        .height = 32,
        .seed = options.seed,
        .enable_pressure = false,
    });
    defer disturbance_only_simulation.deinit();
    try disturbance_only_simulation.resetScenario(17);
    for (0..8) |_| _ = try disturbance_only_simulation.tick(null);
    const disturbance_only = try disturbance_only_simulation.validate(17);
    if (disturbance_only.failures != 0 or disturbance_only.disturbance_hash == 0 or disturbance_only.disturbed_cells <= 2) {
        std.log.err("disturbance-only channel check failed: mask=0x{x} disturbance=0x{x} cells={d}", .{ disturbance_only.failures, disturbance_only.disturbance_hash, disturbance_only.disturbed_cells });
        failures |= 16384;
    }

    // Optional paths bind one-word dummy buffers and preserve cell-only state.
    var no_motion_simulation = try gpu.Simulation.init(&context, .{
        .width = 32,
        .height = 32,
        .seed = options.seed,
        .enable_motion = false,
        .enable_disturbance = false,
        .enable_pressure = false,
    });
    defer no_motion_simulation.deinit();
    try no_motion_simulation.resetScenario(4);
    _ = try no_motion_simulation.tick(null);
    const no_motion = try no_motion_simulation.validate(4);
    if (no_motion.failures != 0 or no_motion.motion_hash != 0 or no_motion.disturbance_hash != 0 or no_motion.pressure_hash != 0 or no_motion.state_hash != no_motion.cell_hash) {
        std.log.err(
            "disabled layered-channel check failed: mask=0x{x} state=0x{x} cells=0x{x} motion=0x{x} disturbance=0x{x} pressure=0x{x}",
            .{ no_motion.failures, no_motion.state_hash, no_motion.cell_hash, no_motion.motion_hash, no_motion.disturbance_hash, no_motion.pressure_hash },
        );
        failures |= 16384;
    }

    if (failures != 0) return error.GpuTestsFailed;
    std.log.info(
        "28 GPU checks passed; Water state=0x{x} motion=0x{x}; Sand state=0x{x} motion=0x{x}; Disturbance state=0x{x} layer=0x{x}; Pressure state=0x{x} layer=0x{x}; Atmosphere state=0x{x} W/S/C={d}/{d}/{d}",
        .{
            water_determinism.baseline.state_hash,
            water_determinism.baseline.motion_hash,
            sand_determinism.baseline.state_hash,
            sand_determinism.baseline.motion_hash,
            disturbance_determinism.baseline.state_hash,
            disturbance_determinism.baseline.disturbance_hash,
            pressure_determinism.baseline.state_hash,
            pressure_determinism.baseline.pressure_hash,
            atmosphere_determinism.baseline.state_hash,
            atmosphere_determinism.baseline.water_count,
            atmosphere_determinism.baseline.steam_count,
            atmosphere_determinism.baseline.cloud_count,
        },
    );
}

const DeterminismCheck = struct {
    baseline: abi.TestResult,
    failures: u32,
};

fn runDeterminismCheck(simulation: *gpu.Simulation, label: []const u8, scenario: u32, ticks: usize, runs: usize) !DeterminismCheck {
    var baseline: abi.TestResult = undefined;
    var failures: u32 = 0;
    var mismatch_reported = false;
    for (0..runs) |run_index| {
        try simulation.resetScenario(scenario);
        for (0..ticks) |_| _ = try simulation.tick(null);
        const result = try simulation.validate(scenario);
        failures |= result.failures;
        if (run_index == 0) {
            baseline = result;
            continue;
        }
        if (!sameDeterministicState(baseline, result)) {
            failures |= 0x8000_0000;
            if (!mismatch_reported) {
                mismatch_reported = true;
                std.log.err(
                    "{s} determinism mismatch on run {d}: state 0x{x}/0x{x}, cells 0x{x}/0x{x}, motion 0x{x}/0x{x}, disturbance 0x{x}/0x{x} ({d}/{d} cells), pressure 0x{x}/0x{x} ({d}/{d} cells), counts Sand {d}/{d} Water {d}/{d} Steam {d}/{d} Cloud {d}/{d} Stone {d}/{d}, active {d}/{d}",
                    .{
                        label,
                        run_index + 1,
                        baseline.state_hash,
                        result.state_hash,
                        baseline.cell_hash,
                        result.cell_hash,
                        baseline.motion_hash,
                        result.motion_hash,
                        baseline.disturbance_hash,
                        result.disturbance_hash,
                        baseline.disturbed_cells,
                        result.disturbed_cells,
                        baseline.pressure_hash,
                        result.pressure_hash,
                        baseline.pressurized_cells,
                        result.pressurized_cells,
                        baseline.sand_count,
                        result.sand_count,
                        baseline.water_count,
                        result.water_count,
                        baseline.steam_count,
                        result.steam_count,
                        baseline.cloud_count,
                        result.cloud_count,
                        baseline.stone_count,
                        result.stone_count,
                        baseline.active_count,
                        result.active_count,
                    },
                );
            }
        }
    }
    return .{ .baseline = baseline, .failures = failures };
}

fn runMassConservationCheck(simulation: *gpu.Simulation, label: []const u8, scenario: u32, ticks: usize, expected_h2o: u32) !u32 {
    try simulation.resetScenario(scenario);
    for (0..ticks) |_| _ = try simulation.tick(null);
    const result = try simulation.validate(scenario);
    const total_h2o = result.water_count + result.steam_count + result.cloud_count;
    if (result.failures != 0 or total_h2o != expected_h2o) {
        const drift = try findMassDrift(simulation, scenario, ticks, expected_h2o);
        std.log.err(
            "{s} mass check failed after {d} ticks: mask=0x{x} H2O={d}/{d} W/S/C={d}/{d}/{d}; first drift tick {d} H2O={d} W/S/C={d}/{d}/{d}, prior H2O={d} W/S/C={d}/{d}/{d}",
            .{
                label,
                ticks,
                result.failures,
                total_h2o,
                expected_h2o,
                result.water_count,
                result.steam_count,
                result.cloud_count,
                drift.tick,
                drift.total_h2o,
                drift.water_count,
                drift.steam_count,
                drift.cloud_count,
                drift.prior_total_h2o,
                drift.prior_water_count,
                drift.prior_steam_count,
                drift.prior_cloud_count,
            },
        );
        return result.failures | 33554432;
    }
    return 0;
}

const MassDrift = struct {
    tick: usize,
    total_h2o: u32,
    water_count: u32,
    steam_count: u32,
    cloud_count: u32,
    prior_total_h2o: u32,
    prior_water_count: u32,
    prior_steam_count: u32,
    prior_cloud_count: u32,
};

fn findMassDrift(simulation: *gpu.Simulation, scenario: u32, ticks: usize, expected_h2o: u32) !MassDrift {
    try simulation.resetScenario(scenario);
    var prior = try simulation.validate(scenario);
    for (0..ticks) |tick_index| {
        _ = try simulation.tick(null);
        const result = try simulation.validate(scenario);
        const total_h2o = result.water_count + result.steam_count + result.cloud_count;
        if (total_h2o != expected_h2o) {
            return .{
                .tick = tick_index + 1,
                .total_h2o = total_h2o,
                .water_count = result.water_count,
                .steam_count = result.steam_count,
                .cloud_count = result.cloud_count,
                .prior_total_h2o = prior.water_count + prior.steam_count + prior.cloud_count,
                .prior_water_count = prior.water_count,
                .prior_steam_count = prior.steam_count,
                .prior_cloud_count = prior.cloud_count,
            };
        }
        prior = result;
    }
    return .{
        .tick = ticks,
        .total_h2o = expected_h2o,
        .water_count = 0,
        .steam_count = 0,
        .cloud_count = 0,
        .prior_total_h2o = expected_h2o,
        .prior_water_count = 0,
        .prior_steam_count = 0,
        .prior_cloud_count = 0,
    };
}

fn sameDeterministicState(a: abi.TestResult, b: abi.TestResult) bool {
    return a.state_hash == b.state_hash and
        a.cell_hash == b.cell_hash and
        a.motion_hash == b.motion_hash and
        a.disturbance_hash == b.disturbance_hash and
        a.disturbed_cells == b.disturbed_cells and
        a.pressure_hash == b.pressure_hash and
        a.pressurized_cells == b.pressurized_cells and
        a.sand_count == b.sand_count and
        a.water_count == b.water_count and
        a.steam_count == b.steam_count and
        a.cloud_count == b.cloud_count and
        a.stone_count == b.stone_count and
        a.active_count == b.active_count;
}

fn runBenchmark(allocator: std.mem.Allocator, options: cli.Options) !void {
    var context = try Context.init(allocator, null, options.validation);
    defer context.deinit();
    var simulation = try gpu.Simulation.init(&context, .{ .width = options.width, .height = options.height, .seed = options.seed });
    defer simulation.deinit();

    const warmup_end = secondsNow() + 2.0;
    while (secondsNow() < warmup_end) _ = try simulation.tickFullyActive();
    const sample_capacity: usize = @as(usize, options.benchmark_seconds) * 100_000;
    const samples = try allocator.alloc(f64, sample_capacity);
    defer allocator.free(samples);
    const measurement_end = secondsNow() + @as(f64, @floatFromInt(options.benchmark_seconds));
    var sample_count: usize = 0;
    while (sample_count < samples.len and secondsNow() < measurement_end) : (sample_count += 1)
        samples[sample_count] = (try simulation.tickFullyActive()).total_ms;
    const measured = samples[0..sample_count];
    std.mem.sort(f64, measured, {}, std.sort.asc(f64));
    const median = measured[measured.len / 2];
    const p95 = measured[@min(measured.len - 1, (measured.len * 95) / 100)];
    std.log.info(
        "benchmark {d}x{d}: median={d:.3} ms p95={d:.3} ms active={d}/{d}",
        .{ options.width, options.height, median, p95, simulation.last_timings.active_chunks, simulation.chunk_count },
    );
    std.log.info("benchmark samples: {d} after 2 s warmup + {d} s measurement", .{ measured.len, options.benchmark_seconds });
    if (p95 > 1000.0 / @as(f64, @floatFromInt(options.tps))) return error.PerformanceTargetMissed;
}
