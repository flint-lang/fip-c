const std = @import("std");
const builtin = @import("builtin");
const defines = @import("defines");
const aro = @import("aro");
const fip = @import("fip");
const clap = @import("clap");

const protocol = @import("protocol.zig");
const parser = @import("parser.zig");

pub const MODULE_NAME = "fip-c";

pub export var LOG_LEVEL: fip.LogLevel = if (builtin.mode == .Debug) .debug else .warn;

/// fip_module_config_t
pub const ModuleConfig = struct {
    tag: [128]u8 = @splat(0),
    headers: [][]u8 = &.{},
    command: [][]u8 = &.{},
    output: [fip.PATH_SIZE:0]u8 = @splat(0),
};

/// c_symbol_t
pub const CSymbol = struct {
    source_file_path: [512]u8 = @splat(0),
    line_number: u32,
    sig: fip.Signature = std.mem.zeroes(fip.Signature),

    pub fn get_name(self: *const CSymbol) ?[]const u8 {
        return switch (self.sig.tag) {
            .unknown => null,
            .@"fn" => blk: {
                const name: [:0]const u8 = &self.sig.u.@"fn".name;
                const len = std.mem.findScalarPos(u8, name, 0, '\x00').?;
                break :blk if (len == 0) null else name[0..len];
            },
            .data => blk: {
                const name: [:0]const u8 = &self.sig.u.data.name;
                const len = std.mem.findScalarPos(u8, name, 0, '\x00').?;
                break :blk if (len == 0) null else name[0..len];
            },
            .@"enum" => blk: {
                const name: [:0]const u8 = &self.sig.u.@"enum".name;
                const len = std.mem.findScalarPos(u8, name, 0, '\x00').?;
                break :blk if (len == 0) null else name[0..len];
            },
            .@"opaque" => blk: {
                const name: [:0]const u8 = &self.sig.u.@"opaque".name;
                const len = std.mem.findScalarPos(u8, name, 0, '\x00').?;
                break :blk if (len == 0) null else name[0..len];
            },
        };
    }

    pub fn set_name(self: *CSymbol, name: []const u8) void {
        const write_len = @min(name.len, fip.NAME_SIZE);
        switch (self.sig.tag) {
            .unknown => {},
            .@"fn" => @memcpy(self.sig.u.@"fn".name[0..write_len], name[0..write_len]),
            .data => @memcpy(self.sig.u.data.name[0..write_len], name[0..write_len]),
            .@"enum" => @memcpy(self.sig.u.@"enum".name[0..write_len], name[0..write_len]),
            .@"opaque" => @memcpy(self.sig.u.@"opaque".name[0..write_len], name[0..write_len]),
        }
    }
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

pub var symbol_collections: []CSymbolCollection = &.{};

const parsers = .{
    .slave_id = clap.parsers.int(u32, 10),
};
const params = clap.parseParamsComptime(
    \\-h, --help    Display this help and exit
    \\-v, --version Display the version information and exit
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

    const cache_env_var = if (builtin.target.os.tag == .windows) "LOCALAPPDATA" else "XDG_CACHE_HOME";
    const cache_env_path: []const u8 = init.environ_map.get(cache_env_var) orelse {
        std.log.err("Failed to get environment variable '{s}'", .{cache_env_var});
        return 1;
    };
    const cache_path: []const u8 =
        if (builtin.target.os.tag == .windows)
            try std.Io.Dir.path.resolve(init.gpa, &.{ cache_env_path, "Flint", "Cache", MODULE_NAME })
        else
            try std.Io.Dir.path.resolve(init.gpa, &.{ cache_env_path, "flint", MODULE_NAME });
    defer init.gpa.free(cache_path);

    const aro_include_path: []const u8 = try std.Io.Dir.path.resolve(init.gpa, &.{ cache_path, "include" });
    defer init.gpa.free(aro_include_path);

    const aro_include_dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, aro_include_path, .{});
    defer aro_include_dir.close(init.io);
    for (defines.aro_files.names, defines.aro_files.contents) |name, content| {
        aro_include_dir.writeFile(init.io, .{
            .sub_path = name,
            .data = content,
            .flags = .{
                .truncate = false,
                .exclusive = true,
            },
        }) catch |err| {
            if (err != error.PathAlreadyExists) {
                return err;
            }
        };
    }

    if (res.args.help != 0) {
        try printHelp(stdout);
        return 0;
    }
    if (res.args.version != 0) {
        try stdout.print("{s} v{s} ({s}, {s})", .{ MODULE_NAME, defines.version, defines.hash, defines.date });
        if (builtin.mode == .Debug) {
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

    defer {
        for (symbol_collections) |*collection| {
            parser.free_symbols(init.gpa, collection.symbols);
        }
        init.gpa.free(symbol_collections);
    }

    const out_terminal: std.Io.Terminal = .{
        .writer = stderr,
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
        .resource_dir = cache_path,
    };
    defer driver.deinit();

    var toolchain: aro.Toolchain = .{ .driver = &driver };
    defer toolchain.deinit();
    try toolchain.discover();
    try toolchain.defineSystemIncludes();
    try compilation.initSearchPath(driver.includes.items, false);

    if (builtin.os.tag == .windows) {
        windows_crt.disable_crlf_translations();
    }

    return protocol.run(init.io, init.gpa, out_terminal, &compilation) catch 1;
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
    try writer.flush();
}

const windows_crt = if (builtin.os.tag == .windows) struct {
    pub extern "c" fn _fileno(stream: *anyopaque) c_int;
    pub extern "c" fn _setmode(fd: c_int, mode: c_int) c_int;

    pub const _O_BINARY: c_int = 0x8000;

    // The CRT exports these as FILE*
    pub extern "c" var stdin: *anyopaque;
    pub extern "c" var stdout: *anyopaque;

    // Disable CRLF <-> LF translations so FIP messages are sent as raw bytes.
    // Must be done before any FIP stdio I/O happens.
    pub fn disable_crlf_translations() void {
        _setmode(_fileno(stdout), _O_BINARY);
        _setmode(_fileno(stdin), _O_BINARY);
    }
} else struct {};

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
