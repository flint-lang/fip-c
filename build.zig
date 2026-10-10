const std = @import("std");

pub fn build(b: *std.Build) !void {
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
    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const commit_hash: []const u8 = std.mem.trim(
        u8,
        b.run(&[_][]const u8{ "git", "rev-parse", "--short", "HEAD" }),
        &std.ascii.whitespace,
    );
    std.debug.print("-- Commit Hash is {s}\n", .{commit_hash});

    const build_date: []const u8 = blk: {
        const current_timestamp: u64 = @intCast(std.Io.Timestamp.now(b.graph.io, .real).toSeconds());
        const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = current_timestamp };
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        break :blk b.fmt("{d}-{d:0>2}-{d:0>2}", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1, // day_index is 0-based
        });
    };
    std.debug.print("-- Build Date is {s}\n", .{build_date});

    var defines = b.addOptions();
    defines.addOption([]const u8, "version", @import("build.zig.zon").version);
    defines.addOption([]const u8, "hash", commit_hash);
    defines.addOption([]const u8, "date", build_date);
    if (aro_dep.builder.build_root.handle.openDir(b.graph.io, "include", .{ .iterate = true })) |aro_files_dir| {
        defer aro_files_dir.close(b.graph.io);
        var aro_file_names: std.ArrayList([]const u8) = .empty;
        var aro_file_contents: std.ArrayList([]const u8) = .empty;
        defer aro_file_contents.deinit(b.allocator);

        var iter = aro_files_dir.iterate();
        while (try iter.next(b.graph.io)) |entry| {
            std.debug.assert(entry.kind == .file);
            std.debug.assert(std.mem.eql(u8, entry.name[entry.name.len - ".h".len ..], ".h"));
            const file_content: []const u8 = try aro_files_dir.readFileAlloc(
                b.graph.io,
                entry.name,
                b.allocator,
                .limited(std.math.maxInt(u16)),
            );
            try aro_file_names.append(b.allocator, entry.name);
            try aro_file_contents.append(b.allocator, file_content);
        }

        const AroFiles = struct { names: []const []const u8, contents: []const []const u8 };
        defines.addOption(AroFiles, "aro_files", .{
            .names = try aro_file_names.toOwnedSlice(b.allocator),
            .contents = try aro_file_contents.toOwnedSlice(b.allocator),
        });
    } else |err| {
        std.log.err("Unable to open 'include' dir of 'aro' dependency", .{});
        return err;
    }

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "defines", .module = defines.createModule() },
        .{ .name = "aro", .module = aro_dep.module("aro") },
        .{ .name = "fip", .module = fip_dep.module("fip") },
        .{ .name = "toml", .module = fip_dep.module("toml") },
        .{ .name = "clap", .module = clap_dep.module("clap") },
    };

    const exe = b.addExecutable(.{
        .name = "fip-c",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    b.installArtifact(exe);

    // Override so that fip headers are installed
    b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{
        .h_dir = .{ .override = .header },
    }).step);

    const tests_step = b.step("test", "Run tests");
    const mode_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = imports,
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    tests_step.dependOn(&b.addRunArtifact(mode_tests).step);
}
