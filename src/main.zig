const std = @import("std");
const aro = @import("aro");
const fip = @import("fip");

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
// fip_c_symbol_collection_t *curr_coll;

pub fn main(init: std.process.Init) !u8 {
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
