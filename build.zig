const std = @import("std");
const manifest = @import("src/shader_manifest.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");
    const vulkan = b.dependency("vulkan_zig", .{ .registry = registry }).module("vulkan-zig");

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "vulkan", .module = vulkan }},
    });
    addShaders(b, root);

    const exe = b.addExecutable(.{ .name = "zigsand", .root_module = root });
    exe.root_module.linkSystemLibrary("user32", .{});
    exe.root_module.linkSystemLibrary("gdi32", .{});
    exe.root_module.linkSystemLibrary("kernel32", .{});
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the interactive ZigSand sandbox");
    run_step.dependOn(&run_cmd.step);

    const host_tests = b.addTest(.{ .root_module = root });
    const run_host_tests = b.addRunArtifact(host_tests);
    const gpu_tests = b.addRunArtifact(exe);
    gpu_tests.addArg("--gpu-tests");
    const test_step = b.step("test", "Run host and headless GPU tests");
    test_step.dependOn(&run_host_tests.step);
    test_step.dependOn(&gpu_tests.step);

    const benchmark = b.addRunArtifact(exe);
    benchmark.addArgs(&.{ "--benchmark", "10" });
    const benchmark_step = b.step("benchmark", "Run the GPU benchmark workload");
    benchmark_step.dependOn(&benchmark.step);

    const shader_step = b.step("shaders", "Compile all HLSL shaders to SPIR-V");
    for (manifest.shaders) |shader| {
        const output = compileShader(b, shader);
        shader_step.dependOn(output.step);
    }
}

fn addShaders(b: *std.Build, module: *std.Build.Module) void {
    for (manifest.shaders) |shader| {
        const output = compileShader(b, shader);
        module.addAnonymousImport(shader.name, .{ .root_source_file = output.output });
    }
}

const CompiledShader = struct {
    step: *std.Build.Step,
    output: std.Build.LazyPath,
};

fn compileShader(b: *std.Build, shader: manifest.Shader) CompiledShader {
    const dxc = b.addSystemCommand(&.{
        "dxc",
        "-spirv",
        "-fspv-target-env=vulkan1.3",
        "-fvk-use-dx-layout",
        "-WX",
        "-O3",
        "-T",
        shader.profile,
        "-E",
        shader.entry,
        "-Fo",
    });
    const output = dxc.addOutputFileArg(b.fmt("{s}.spv", .{shader.entry}));
    dxc.addFileArg(b.path(shader.source));
    return .{ .step = &dxc.step, .output = output };
}
