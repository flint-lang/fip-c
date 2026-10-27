const std = @import("std");
const aro = @import("aro");
const fip = @import("fip");

const main = @import("main.zig");
const parser = @import("parser.zig");
const toml = @import("toml.zig");

var symbol_collections: []main.CSymbolCollection = &.{};

pub fn run(io: std.Io, allocator: std.mem.Allocator, compilation: *aro.Compilation) !u8 {
    defer fip.print(main.ID, .info, "ending...");

    // Initialize slave for stdio communication
    if (!fip.slave.init(main.ID)) {
        fip.print(main.ID, .@"error", "Failed to initialize slave");
        return 1;
    }
    defer fip.slave.cleanup();
    fip.print(main.ID, .info, "Successfully initialized slave communication");

    var msg: fip.Message = .{
        .tag = .connect_request,
        .u = .{
            .connect_request = .{
                .setup_ok = true,
                .version = .{
                    .major = fip.MAJOR,
                    .minor = fip.MINOR,
                    .patch = fip.PATCH,
                },
                .module_name = @splat(0),
            },
        },
    };
    @memcpy(msg.u.connect_request.module_name[0..main.MODULE_NAME.len], main.MODULE_NAME);

    if (!try toml.parse(allocator)) {
        fip.print(main.ID, .@"error", "Failed to parse '.fip/config/%s.toml' file, aborting...", main.MODULE_NAME);
        msg.u.connect_request.setup_ok = false;
    } else {
        fip.print(main.ID, .info, "Parsed '.fip/config/%s.toml' file successfully", main.MODULE_NAME);
    }
    defer toml.free_configs(allocator);

    msg.print(main.ID);

    // Send the connect message to the master now, as we are now able to connect to it
    if (!msg.u.connect_request.setup_ok) {
        fip.print(main.ID, .info, "Sending shutdown request to master...");
        fip.slave.send_message(&msg, main.ID);
        fip.slave.cleanup();
        fip.print(main.ID, .info, "ending...");
        return 1;
    }
    fip.print(main.ID, .info, "Sending connect request to master...");
    fip.slave.send_message(&msg, main.ID);

    symbol_collections = try allocator.alloc(main.CSymbolCollection, main.configs.len);
    @memset(symbol_collections, main.CSymbolCollection{});
    defer {
        for (symbol_collections) |*collection| {
            parser.free_symbols(allocator, collection.symbols);
        }
        allocator.free(symbol_collections);
    }

    const ast_file = blk: {
        const sub_path = try std.fmt.allocPrint(allocator, ".fip/log/slave_{d}.ast", .{main.ID});
        defer allocator.free(sub_path);
        break :blk try std.Io.Dir.cwd().createFile(io, sub_path, .{});
    };
    defer ast_file.close(io);
    var ast_file_writer = ast_file.writer(io, &.{});
    const ast_file_stream = &ast_file_writer.interface;

    // Generate builtin macros once per compilation
    const builtin_macros = try compilation.generateBuiltinMacros(.include_system_defines);

    for (main.configs, symbol_collections) |*config, *collection| {
        fip.print(main.ID, .debug, "[%s]", &config.tag);
        for (config.headers) |header| {
            fip.print(main.ID, .debug, "parsing header '%s'...", header.ptr);

            const start: std.Io.Timestamp = .now(io, .real);
            try ast_file_stream.print("==== BEGIN OF FILE '{s}' ====\n", .{header});
            std.debug.assert(header[header.len - 1] == '\x00');
            parser.parse_file(allocator, ast_file_stream, compilation, builtin_macros, header[0..(header.len - 1)], collection, &config.tag) catch |err| {
                fip.print(main.ID, .debug, "parsing header '%s' failed...", header.ptr);
                collection.errored = true;
                return err;
            };
            try ast_file_stream.print("===== END OF FILE '{s}' =====\n", .{header});
            const parse_time = @as(f64, @floatFromInt(start.untilNow(io, .real).toNanoseconds())) / std.time.ns_per_s;
            fip.print(main.ID, .debug, "parsing '%s' took %f s", header.ptr, parse_time);
        }
        for (config.command, 0..) |command, i| {
            fip.print(main.ID, .debug, "  command[%lu] = \"%s\"", i, command.ptr);
        }
        fip.print(main.ID, .debug, "  output     = \"%s\"", &config.output);
    }

    // Main loop - wait for messages from master
    return blk: while (true) {
        // Recieve message is blocking, so we don't need to wait any time at all
        if (!fip.slave.recieve_message()) {
            fip.print(main.ID, .@"error", "Master died, shutting down...");
            break :blk 1;
        }

        // Only print the first time we receive a message
        fip.print(main.ID, .debug, "Recieved message");
        var message: fip.Message = .{};
        message.decode();
        defer message.free();
        message.print(main.ID);

        switch (message.tag) {
            .unknown => fip.print(main.ID, .warn, "Recieved unknown message"),
            .connect_request => @panic("Slave recieved 'connect_request' message, should not be possible"),
            .symbol_request => handle_symbol_request(&message),
            .symbol_response => @panic("Slave recieved 'symbol_response' message, should not be possible"),
            .compile_request => handle_compile_request(io, allocator, &message),
            .object_response => @panic("Slave recieved 'symbol_response' message, should not be possible"),
            .tag_request => handle_tag_request(&message) catch break :blk 1,
            .tag_present_response => @panic("Slave recieved 'tag_present_response' message, should not be possible"),
            .tag_next_symbol_request => @panic("Slave recieved 'tag_next_symbol_request' in main loop"),
            .tag_symbol_response => @panic("Slave recieved 'tag_symbol_response' message, should not be possible"),
            .kill => {
                fip.print(main.ID, .info, "Recieved Kill Command, shutting down...");
                break :blk 0;
            },
        }
    } else unreachable;
}

pub fn handle_symbol_request(message: *const fip.Message) void {
    std.debug.assert(message.tag == .symbol_request);
    const symbol_request: *const fip.Message.SymbolRequest = &message.u.symbol_request;
    fip.print(main.ID, .info, "Symbol Request Recieved");

    var response: fip.Message = .{
        .tag = .symbol_response,
        .u = .{
            .symbol_response = .{
                .sig = .{
                    .tag = message.u.symbol_request.sig.tag,
                },
            },
        },
    };
    const symbol_response: *fip.Message.SymbolResponse = &response.u.symbol_response;
    @memcpy(symbol_response.module_name[0..main.MODULE_NAME.len], main.MODULE_NAME);

    var resolver: fip.Resolver = .{ .get_type = resolve_type_name };

    fip.print(main.ID, .debug, "symbol_list.count=%lu", symbol_collections.len);
    symbol_response.found =
        blk: for (symbol_collections) |*collection| {
            fip.print(main.ID, .debug, "collection->symbol_count=%lu", collection.symbols.len);
            for (collection.symbols) |*symbol| {
                if (symbol.sig.equals(&symbol_request.sig, &resolver)) {
                    collection.needed = true;
                    symbol.sig.clone(&symbol_response.sig);
                    break :blk true;
                }
            }
        } else false;
    fip.slave.send_message(&response, main.ID);
}

pub fn compile_module(
    io: std.Io,
    allocator: std.mem.Allocator,
    path_count: *usize,
    paths: *[fip.PATHS_SIZE]u8,
    config: *main.ModuleConfig,
    compile_message: *const fip.Message,
) bool {
    // Ensure .fip/cache directory exists
    std.Io.Dir.cwd().createDirPath(io, ".fip/cache") catch {
        fip.print(main.ID, .@"error", "Failed to create .fip directory");
        return false;
    };

    // TODO: Use the target information from the compile_message
    // compile_message->u.com_req.target
    _ = compile_message;

    // Check if the hash is already part of the paths, if it is we already compiled the module
    const hash: []const u8 = &config.output;
    if (std.mem.containsAtLeast(u8, paths, 1, hash)) {
        return true;
    }

    var command_size: usize = 0;
    for (config.command) |cmd| {
        command_size += cmd.len + 1;
    }
    const command: []u8 = allocator.alloc(u8, command_size) catch @panic("OOM");
    var idx: usize = 0;
    for (config.command) |cmd| {
        @memcpy(command[idx..(idx + cmd.len)], cmd);
        idx += cmd.len;
        command[idx] = ' ';
        idx += 1;
    }
    command[command_size - 1] = '\x00';
    fip.print(main.ID, .info, "Executing: %s", command.ptr);

    var compile_output: [*c]const u8 = null;
    const exit_code: c_int = fip.execute_and_capture(&compile_output, command.ptr);
    allocator.free(command);
    if (compile_output) |output| {
        if (output[0] != '\x00') {
            fip.print(main.ID, .info, "%s", output);
        }
        std.c.free(@ptrCast(@constCast(output)));
    }
    if (exit_code != 0) {
        fip.print(main.ID, .@"error", "Compiling module '%s' failed with exit code %d", &config.tag, exit_code);
        return false;
    }

    fip.print(main.ID, .info, "Compiled '%s' successfully", &hash);
    // Add to paths array. For this we need to find the first null-byte character in the paths array, that's where
    // we will place our hash at. The good thing is that we only need to check multiples of 8 so this check is rather easy.
    // Because we know how many paths there already are in the paths string we can just offset by
    // path_count * FIP_PATH_SIZE and increment path_count afterwards, as simple as that
    const offset: usize = path_count.* * fip.PATH_SIZE;
    if (offset >= fip.PATHS_SIZE) {
        fip.print(main.ID, .@"error", "The Paths array is full: %.*s", @as(i32, fip.PATHS_SIZE), paths);
        fip.print(main.ID, .@"error", "Could not store hash '%s' in it", &hash);
        return false;
    }
    @memcpy(paths[offset..(offset + fip.PATH_SIZE)], hash);
    path_count.* += 1;
    return true;
}

pub fn handle_compile_request(io: std.Io, allocator: std.mem.Allocator, message: *const fip.Message) void {
    std.debug.assert(message.tag == .compile_request);
    fip.print(main.ID, .info, "Compile Request Recieved");
    var response: fip.Message = .{
        .tag = .object_response,
        .u = .{
            .object_response = .{
                .has_obj = false,
                .compilation_failed = false,
            },
        },
    };
    const object_response: *fip.Message.ObjectResponse = &response.u.object_response;
    object_response.* = .{};
    @memcpy(object_response.module_name[0..main.MODULE_NAME.len], main.MODULE_NAME);

    // We need to go through all modules and see whether they need to be compiled
    for (main.configs, symbol_collections) |*cfg, *collection| {
        if (!collection.needed) {
            continue;
        }
        if (!compile_module(io, allocator, &object_response.path_count, &object_response.paths, cfg, message)) {
            object_response.has_obj = false;
            object_response.compilation_failed = true;
            break;
        }
        object_response.has_obj = true;
    }

    fip.slave.send_message(&response, main.ID);
}

pub fn handle_tag_request(message: *const fip.Message) error{MasterDied}!void {
    std.debug.assert(message.tag == .tag_request);
    fip.print(main.ID, .info, "Tag Request Recieved");
    const msg_tag: *const [fip.NAME_SIZE:0]u8 = &message.u.tag_request.tag;
    fip.print(main.ID, .info, "Searching for tag '%s'...", msg_tag);

    var response: fip.Message = .{
        .tag = .tag_present_response,
    };

    var collection_id: usize = 0;
    var is_present: bool = false;
    for (symbol_collections) |*collection| {
        fip.print(main.ID, .debug, "Checking if tag '%s' equals searched-for tag '%s'...", &collection.tag, msg_tag);
        if (std.mem.eql(u8, &collection.tag, msg_tag)) {
            is_present = true;
            break;
        }
        collection_id += 1;
    }

    // If tag exists but its headers failed to parse, reject it
    if (is_present and symbol_collections[collection_id].errored) {
        fip.print(main.ID, .@"error", "Headers of tag '%s' failed to parse", msg_tag);
        is_present = false;
    }

    if (is_present) {
        fip.print(main.ID, .debug, "Tag '%s' was found in this module", msg_tag);
    } else {
        fip.print(main.ID, .debug, "Tag '%s' was not found in this module", msg_tag);
    }

    response.u.tag_present_response.is_present = is_present;
    fip.slave.send_message(&response, main.ID);
    response.free();

    if (!is_present) {
        return;
    }

    // Wait for `FIP_MSG_TAG_NEXT_SYMBOL_REQUEST` from master to tell us that it wants to have the next symbol.
    // We simply ping-pong between the master and the slave. The master requests new symbols until we send it an
    // empy symbol as we reached the end of the list. If we reached the end of the list then the slave will automatically
    // fall back to it's normal execution, the master does not need to send any other message to us in this case.
    const collection: *main.CSymbolCollection = &symbol_collections[collection_id];
    collection.needed = true;
    for (collection.symbols, 0..) |*symbol, i| {
        fip.print(main.ID, .info, "Sending symbol %u/%u", i, collection.symbols.len);
        // Wait for master to request the next symbol
        if (!fip.slave.recieve_message()) {
            fip.print(main.ID, .@"error", "Master died, shutting down...");
            return error.MasterDied;
        }
        var next_message: fip.Message = .{};
        next_message.decode();
        if (next_message.tag != .tag_next_symbol_request) {
            fip.print(
                main.ID,
                .@"error",
                "Unexpected message from master: '%s', expected 'tag_next_symbol_request'",
                @tagName(next_message.tag).ptr,
            );
            next_message.free();
            return;
        }
        response = .{
            .tag = .tag_symbol_response,
            .u = .{
                .tag_symbol_response = .{
                    .is_empty = false,
                    .sig = fip.Signature{},
                },
            },
        };

        // Send the next symbol to the master
        symbol.sig.clone(&response.u.tag_symbol_response.sig);
        fip.slave.send_message(&response, main.ID);
        response.free();
    }

    // Wait for master to request the next symbol before sending the empty symbol to it
    if (!fip.slave.recieve_message()) {
        fip.print(main.ID, .@"error", "Master died, shutting down...");
        return error.MasterDied;
    }
    // Only print the first time we receive a message
    var next_message: fip.Message = .{};
    next_message.decode();
    if (next_message.tag != .tag_next_symbol_request) {
        fip.print(
            main.ID,
            .@"error",
            "Unexpected message from master: '%s', expected 'tag_next_symbol_request'",
            @tagName(next_message.tag).ptr,
        );
        next_message.free();
        return;
    }
    // Send "end of list" message
    response = .{
        .tag = .tag_symbol_response,
        .u = .{
            .tag_symbol_response = .{
                .is_empty = true,
                .sig = .{ .tag = .unknown, .u = .{ .unknown = {} } },
            },
        },
    };
    fip.slave.send_message(&response, main.ID);
}

fn resolve_type_name(name: []const u8) ?*const fip.Signature {
    for (symbol_collections) |*collection| {
        for (collection.symbols) |*symbol| {
            if (symbol.get_name()) |symbol_name| {
                if (std.mem.eql(u8, symbol_name, name)) {
                    return &symbol.sig;
                }
            }
        }
    }
    return null;
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
