const std = @import("std");
const defines = @import("defines");
const aro = @import("aro");
const fip = @import("fip");
const clap = @import("clap");

const protocol = @import("protocol.zig");
const parser = @import("parser.zig");
const toml = @import("toml.zig");

pub const MODULE_NAME = "fip-c";
pub const MAX_SYMBOLS = 1000;

pub export var LOG_LEVEL: fip.LogLevel = if (@import("builtin").mode == .Debug) .debug else .warn;

/// fip_module_config_t
pub const ModuleConfig = struct {
    tag: [128]u8 = @splat(0),
    headers: [][]u8 = &.{},
    command: [][]u8 = &.{},
    output: [@as(usize, @intCast(fip.PATH_SIZE)) + 1]u8 = @splat(0),
};

/// c_symbol_t
pub const CSymbol = struct {
    source_file_path: [512]u8 = @splat(0),
    line_number: u32,
    sig: fip.Signature = std.mem.zeroes(fip.Signature),
};

pub const CSymbolCollection = struct {
    /// @var `needed`
    /// @brief Whether this whole collection is needed, for example when the tag
    /// is non-empty and we write `use Fip.tagname` in Flint then the whole
    /// module is requested to be compiled. Or, if the tag is empty and a single
    /// (or more) symbol(s) of that module are used then the whole module is
    /// compiled and returned.
    needed: bool,
    /// @var `errored`
    /// @brief Whether parsing of this collection's headers failed (for example
    /// because a header file does not exist). An errored collection is never
    /// reported as present to the master.
    errored: bool,
    tag: [128]u8,
    symbols: []CSymbol,
};

/// The ID of this interop module
pub var ID: u32 = 0;

pub var configs: []ModuleConfig = &.{};

pub var symbol_collections: std.ArrayList(CSymbolCollection) = .empty;

const parsers = .{
    .slave_id = clap.parsers.int(u32, 10),
};
const params = clap.parseParamsComptime(
    \\-h, --help    Display this help and exit
    \\-v, --version Display the FIP version this Flint Interop Module uses
    \\<slave_id>    [required] The ID of this slave
);

pub fn main(init: std.process.Init) !u8 {
    var stdout_writer = std.Io.File.stdout().writer(init.io, &.{});
    const stdout = &stdout_writer.interface;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &.{});
    const stderr = &stderr_writer.interface;

    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();

    _ = iter.next();

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
        .terminating_positional = 0,
    }) catch {
        std.log.err("Invalid <slave_id>: {s}", .{init.minimal.args.vector[1]});
        try printHelp(stderr);
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try printHelp(stdout);
        return 0;
    }
    if (res.args.version != 0) {
        try stdout.print("fip-c v{s} ({s}, {s})", .{ defines.version, defines.hash, defines.date });
        if (@import("builtin").mode == .Debug) {
            try stdout.print(" [debug]", .{});
        }
        try stdout.print("\n └─ Flint Interop Protocol v{d}.{d}.{d}\n", .{ fip.MAJOR, fip.MINOR, fip.PATCH });
        try stdout.flush();
        return 0;
    }

    ID = res.positionals[0] orelse {
        std.log.err("Missing required argument <slave_id>", .{});
        try printHelp(stderr);
        return 1;
    };

    defer symbol_collections.deinit(init.gpa);
    defer {
        for (symbol_collections.items) |*collection| {
            parser.free_symbols(init.gpa, collection.symbols);
        }
    }

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

    defer toml.free_configs(init.gpa);
    if (!try toml.parse(init.gpa)) {
        fip.print(ID, .@"error", "Failed to parse '.fip/config/fip-c.toml' file, aborting...");
        return 1;
    }

    const file: []const u8 = "main.c";
    if (try parser.parse_file(init.gpa, out_terminal, &compilation, file)) |collection| {
        symbol_collections.append(init.gpa, collection) catch |err| {
            parser.free_symbols(init.gpa, collection.symbols);
            return err;
        };
    } else {
        fip.print(ID, .@"error", "Unable to parse file '%s'", file.ptr);
        return 1;
    }

    for (configs) |*config| {
        fip.print(ID, .debug, "[%s]", &config.tag);
        for (config.headers, 0..) |header, i| {
            fip.print(ID, .debug, "  header[%lu]  = \"%s\"", i, header.ptr);
        }
        for (config.command, 0..) |command, i| {
            fip.print(ID, .debug, "  command[%lu] = \"%s\"", i, command.ptr);
        }
        fip.print(ID, .debug, "  output     = \"%s\"", &config.output);
    }
    return 0;
}

fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: fip-c <slave_id>
        \\
    );
    try clap.help(writer, clap.Help, &params, .{
        .indent = 2,
        .spacing_between_parameters = 0,
        .description_indent = 4,
        .description_on_new_line = false,
        .max_width = 100,
    });
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
