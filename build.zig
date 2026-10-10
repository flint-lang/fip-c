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
    exe.root_module.addImport("fip", fip_dep.module("fip"));
    exe.root_module.addImport("toml", fip_dep.module("toml"));

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
