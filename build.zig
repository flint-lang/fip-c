const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.graph.host;
    const optimize = b.standardOptimizeOption(.{});

    const aro_dep = b.dependency("aro", .{
        .target = target,
        .optimize = optimize,
    });

    const fip_dep = b.dependency("fip", .{
        .target = target,
        .optimize = optimize,
        .@"lib-mode" = .slave,
    });
    const fip_c = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = fip_dep.path("fip.h"),
    });
    fip_c.defineCMacro("FIP_SLAVE", null);
    fip_c.addIncludePath(fip_dep.builder.dependency("tomlc17", .{}).path("src"));

    const exe = b.addExecutable(.{
        .name = "fip-c",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    b.installArtifact(exe);
    exe.step.dependOn(&fip_c.step);
    exe.root_module.addImport("fip", fip_c.createModule());
    exe.root_module.linkLibrary(fip_dep.artifact("fip"));
    exe.installLibraryHeaders(fip_dep.artifact("fip"));

    // Override so that fip headers are installed
    b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{
        .h_dir = .{ .override = .header },
    }).step);

    exe.root_module.addImport("aro", aro_dep.module("aro"));

    // Optional; this will make aro's builtin includes (the `include` directory of this repo) available to `Toolchain`
    b.installDirectory(.{
        .source_dir = aro_dep.path("include"),
        .install_dir = .prefix,
        .install_subdir = "include/arocc/include",
    });
}
