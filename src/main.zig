const std = @import("std");
const aro = @import("aro");
const fip = @import("fip");

pub fn main(init: std.process.Init) !void {
    var writer = std.Io.File.stdout().writer(init.io, &.{});

    const out_terminal: std.Io.Terminal = .{
        .writer = &writer.interface,
        .mode = .escape_codes,
    };
    var diagnostics: aro.Diagnostics = .{
        .output = .{
            .to_writer = out_terminal,
        },
    };
    defer diagnostics.deinit();

    var environ_map = try init.minimal.environ.createMap(init.gpa);
    defer environ_map.deinit();

    var compilation = try aro.Compilation.init(.{
        .gpa = init.gpa,
        .arena = init.arena.allocator(),
        .io = init.io,
        .diagnostics = &diagnostics,
        .environ_map = &environ_map,
    });
    defer compilation.deinit();

    var driver: aro.Driver = .{
        .comp = &compilation,
        .diagnostics = &diagnostics,
        .resource_dir = "zig-out/include/arocc",
    };
    defer driver.deinit();

    var toolchain: aro.Toolchain = .{ .driver = &driver };
    defer toolchain.deinit();
    try toolchain.discover();
    try toolchain.defineSystemIncludes();
    try compilation.initSearchPath(driver.includes.items, false);

    var file_tree = try parse_file(&compilation);
    defer file_tree.deinit();

    try file_tree.dump(out_terminal);
}

fn parse_file(compilation: *aro.Compilation) !aro.Tree {
    var preproc = try aro.Preprocessor.init(compilation, .testing);
    defer preproc.deinit();
    try preproc.addBuiltinMacros();
    const builtin_macros = try compilation.generateBuiltinMacros(.include_system_defines);
    _ = try preproc.preprocess(builtin_macros);

    const main_c = try compilation.addSourceFromPath("main.c");
    const eof = try preproc.preprocess(main_c);
    try preproc.addToken(eof);

    return try aro.Parser.parse(&preproc);
}
