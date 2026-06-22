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

        if (uncapped and !paused) {
            // Saturate simulation for most of a 60 Hz frame while preserving a
            // small presentation/input budget. The safety limit matters only
            // after a completely sleeping world makes individual ticks tiny.
            const turbo_deadline = secondsNow() + 0.002;
            var turbo_ticks: u32 = 0;
            while (secondsNow() < turbo_deadline and turbo_ticks < 1024) : (turbo_ticks += 1) {
                const brush = mapBrush(&window, options.width, options.height, brush_radius, selected);
                _ = try simulation.tick(brush);
                ticks += 1;
            }
            accumulator = 0;
        } else {
            var catch_up: u32 = 0;
            while ((!paused and accumulator >= tick_seconds and catch_up < 4) or single_step) {
                const brush = mapBrush(&window, options.width, options.height, brush_radius, selected);
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
                "ZigSand | {d} FPS | {d} TPS{s} | {d}/{d} chunks | GPU I {d:.2} R {d:.2} C {d:.2} Draw {d:.2} ms | brush {d}{s}",
                .{
                    frames,
                    ticks,
                    if (uncapped) " UNCAPPED" else "",
                    simulation.last_timings.active_chunks,
                    simulation.chunk_count,
                    simulation.last_timings.intent_ms,
                    simulation.last_timings.resolve_ms,
                    simulation.last_timings.commit_ms,
                    renderer.last_render_ms,
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

fn mapBrush(window: *const win32.Window, width: u32, height: u32, radius: u32, selected: abi.Material) ?gpu.Brush {
    const material: abi.Material = if (window.right_down) .empty else if (window.left_down) selected else return null;
    const cell = coordinates.windowToCell(window.mouse_x, window.mouse_y, window.client_width, window.client_height, width, height) orelse return null;
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

    // Reset and replay a collision-heavy, cross-chunk fixture 100 times. Only
    // the compact validation record crosses back to the host; the grid remains
    // canonical GPU state throughout the test.
    const determinism_runs = 100;
    const determinism_ticks = 24;
    var deterministic_baseline: abi.TestResult = undefined;
    var mismatch_reported = false;
    for (0..determinism_runs) |run_index| {
        try simulation.resetScenario(14);
        for (0..determinism_ticks) |_| _ = try simulation.tick(null);
        const result = try simulation.validate(14);
        if (result.failures != 0) failures |= result.failures;
        if (run_index == 0) {
            deterministic_baseline = result;
            continue;
        }
        if (result.state_hash != deterministic_baseline.state_hash or
            result.sand_count != deterministic_baseline.sand_count or
            result.water_count != deterministic_baseline.water_count or
            result.stone_count != deterministic_baseline.stone_count or
            result.active_count != deterministic_baseline.active_count)
        {
            failures |= 0x8000_0000;
            if (!mismatch_reported) {
                mismatch_reported = true;
                std.log.err(
                    "determinism mismatch on run {d}: hash 0x{x}/0x{x}, counts S {d}/{d} W {d}/{d} Stone {d}/{d}, active {d}/{d}",
                    .{
                        run_index + 1,
                        deterministic_baseline.state_hash,
                        result.state_hash,
                        deterministic_baseline.sand_count,
                        result.sand_count,
                        deterministic_baseline.water_count,
                        result.water_count,
                        deterministic_baseline.stone_count,
                        result.stone_count,
                        deterministic_baseline.active_count,
                        result.active_count,
                    },
                );
            }
        }
    }

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

    if (failures != 0) return error.GpuTestsFailed;
    std.log.info("14 GPU checks passed; 100-run deterministic hash=0x{x}", .{deterministic_baseline.state_hash});
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
