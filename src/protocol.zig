const std = @import("std");
const fip = @import("fip");

const main = @import("main.zig");

pub fn handle_function_symbol_request(message: *const fip.Message, sym_res: *fip.Message.SymbolResponse) void {
    std.debug.assert(message.tag == .symbol_request);
    const msg_fn: *const fip.fip_sig_fn_t = &message.u.sym_req.sig.@"fn";
    fip.fip_print_sig_fn(main.ID, msg_fn);
    sym_res.type = fip.FIP_SYM_FUNCTION;

    var sym_match: bool = false;
    fip.fip_print(main.ID, fip.FIP_DEBUG, "symbol_list.count=%lu", main.symbol_collections.items.len);
    for (main.symbol_collections.items) |*collection| {
        fip.fip_print(main.ID, fip.FIP_DEBUG, "collection->symbol_count=%lu", collection.symbols.len);
        for (collection.symbols) |*symbol| {
            if (symbol.type != fip.FIP_SYM_FUNCTION) {
                continue;
            }
            fip.fip_print(main.ID, fip.FIP_DEBUG, "Checking function");
            const sym_fn: *const fip.fip_sig_fn_t = &symbol.sig.@"fn";
            fip.fip_print_sig_fn(main.ID, sym_fn);
            if (!std.mem.eql(u8, sym_fn.name, msg_fn.name) or
                sym_fn.args_len != msg_fn.args_len or
                sym_fn.rets_len != msg_fn.rets_len)
            {
                continue;
            }
            sym_match = true;
            // Now we need to check if the arg and ret types match
            for (sym_fn.args[0..sym_fn.args_len], msg_fn.args[0..msg_fn.args_len]) |*sym_arg, *msg_arg| {
                if (sym_arg.type != msg_arg.type or sym_arg.type.is_mutable != msg_arg.type.is_mutable) {
                    sym_match = false;
                    break;
                }
            }
            for (sym_fn.rets[0..sym_fn.rets_len], msg_fn.rets[0..msg_fn.rets_len]) |*sym_ret, *msg_ret| {
                if (sym_ret.type != msg_ret.type or sym_ret.type.is_mutable != msg_ret.type.is_mutable) {
                    sym_match = false;
                    break;
                }
            }
            if (sym_match) {
                // We found the requested symbol
                collection.needed = true;
                fip.fip_clone_sig_fn(&sym_res.sig.@"fn", sym_fn);
                @memcpy(sym_res.sig.@"fn".name, sym_fn.name);
                break;
            }
        }
        if (sym_match) {
            break;
        }
    }
    sym_res.found = sym_match;
}

pub fn handle_data_symbol_request(message: *const fip.fip_msg_t, sym_res: *fip.fip_msg_symbol_response_t) void {
    std.debug.assert(message.u.sym_req.type == fip.FIP_SYM_DATA);
    const msg_data: *const fip.fip_sig_data_t = &message.u.sym_req.sig.data;
    sym_res.type = fip.FIP_SYM_DATA;

    var sym_match: bool = false;
    fip.fip_print(main.ID, fip.FIP_DEBUG, "symbol_list.count=%lu", main.symbol_collections.items.len);
    for (main.symbol_collections.items) |*collection| {
        fip.fip_print(main.ID, fip.FIP_DEBUG, "collection->symbol_count=%lu", collection.symbols.len);
        for (collection.symbols) |*symbol| {
            if (symbol.type != fip.FIP_SYM_DATA) {
                continue;
            }
            fip.fip_print(main.ID, fip.FIP_DEBUG, "Checking data");
            const sym_data: *const fip.fip_sig_data_t = &symbol.sig.data;
            if (!std.mem.eql(u8, sym_data.name, msg_data.name) or sym_data.value_count != msg_data.value_count) {
                continue;
            }
            sym_match = true;
            // Check if field types match
            for (sym_data.value_types[0..sym_data.value_count], msg_data.value_types[0..msg_data.value_count]) |*sym_type, *msg_type| {
                if (sym_type.type != msg_type.type or sym_type.is_mutable != msg_type.is_mutable) {
                    sym_match = false;
                    break;
                }
            }
            if (sym_match) {
                // We found the requested symbol
                collection.needed = true;
                fip.fip_clone_sig_data(&sym_res.sig.data, sym_data);
                @memcpy(sym_res.sig.data.name, sym_data.name);
                break;
            }
        }
        if (sym_match) {
            break;
        }
    }
    sym_res.found = sym_match;
}

pub fn handle_enum_symbol_request(message: *const fip.fip_msg_t, sym_res: *fip.fip_msg_symbol_response_t) void {
    std.debug.assert(message.u.sym_req.type == fip.FIP_SYM_ENUM);
    const msg_enum: *const fip.fip_sig_enum_t = &message.u.sym_req.sig.enum_t;
    sym_res.type = fip.FIP_SYM_ENUM;

    var sym_match: bool = false;
    fip.fip_print(main.ID, fip.FIP_DEBUG, "symbol_list.count=%lu", main.symbol_collections.items.len);
    for (main.symbol_collections.items) |*collection| {
        fip.fip_print(main.ID, fip.FIP_DEBUG, "collection->symbol_count=%lu", collection.symbols.len);
        for (collection.symbols) |*symbol| {
            if (symbol.type != fip.FIP_SYM_ENUM) {
                continue;
            }
            fip.fip_print(main.ID, fip.FIP_DEBUG, "Checking enum");
            const sym_enum: *const fip.fip_sig_enum_t = &symbol.sig.@"enum";
            if (!std.mem.eql(u8, sym_enum.name, msg_enum.name) or
                sym_enum.type != msg_enum.type or
                sym_enum.value_count != msg_enum.value_count)
            {
                continue;
            }
            sym_match = true;
            // Check if values match
            for (0..sym_enum.value_count) |i| {
                if (sym_enum.values[i] != msg_enum.values[i]) {
                    sym_match = false;
                    break;
                }
            }
            if (sym_match) {
                // We found the requested symbol
                collection.needed = true;
                fip.fip_clone_sig_enum(&sym_res.sig.enum_t, sym_enum);
                @memcpy(sym_res.sig.enum_t.name, sym_enum.name);
                break;
            }
        }
        if (sym_match) {
            break;
        }
    }
    sym_res.found = sym_match;
}

pub fn handle_opaque_symbol_request(message: *const fip.fip_msg_t, sym_res: *fip.fip_msg_symbol_response_t) void {
    std.debug.assert(message.u.sym_req.type == fip.FIP_SYM_OPAQUE);
    const msg_opaque: *const fip.fip_sig_opaque_t = &message.u.sym_req.sig.@"opaque";
    sym_res.type = fip.FIP_SYM_OPAQUE;

    var sym_match: bool = false;
    fip.fip_print(main.ID, fip.FIP_DEBUG, "symbol_list.count=%lu", main.symbol_collections.items.len);
    for (main.symbol_collections.items) |*collection| {
        fip.fip_print(main.ID, fip.FIP_DEBUG, "collection->symbol_count=%lu", collection.symbols.len);
        for (collection.symbols) |*symbol| {
            if (symbol.type != fip.FIP_SYM_OPAQUE) {
                continue;
            }
            fip.fip_print(main.ID, fip.FIP_DEBUG, "Checking opaque");
            const sym_opaque: *const fip.fip_sig_opaque_t = &symbol.sig.@"opaque";
            if (!std.mem.eql(u8, sym_opaque.name, msg_opaque.name)) {
                continue;
            }
            sym_match = true;
            collection.needed = true;
            fip.fip_clone_sig_opaque(&sym_res.sig.@"opaque", sym_opaque);
            @memcpy(sym_res.sig.@"opaque".name, sym_opaque.name);
            break;
        }
        if (sym_match) {
            break;
        }
    }
    sym_res.found = sym_match;
}

pub fn handle_symbol_request(buffer: *[fip.FIP_MSG_SIZE]u8, message: *const fip.fip_msg_t) void {
    std.debug.assert(message.type == fip.FIP_MSG_SYMBOL_REQUEST);
    fip.fip_print(main.ID, fip.FIP_INFO, "Symbol Request Received");

    var response: fip.fip_msg_t = .{
        .type = fip.FIP_MSG_SYMBOL_RESPONSE,
    };
    const sym_res: *fip.fip_msg_symbol_response_t = &response.u.sym_res;
    @memcpy(sym_res.module_name[0..main.MODULE_NAME.len], main.MODULE_NAME);

    switch (message.u.sym_req.type) {
        fip.FIP_SYM_UNKNOWN => {
            fip.fip_print(main.ID, fip.FIP_DEBUG, "Not implemented yet");
            return;
        },
        fip.FIP_SYM_FUNCTION => handle_function_symbol_request(message, sym_res),
        fip.FIP_SYM_DATA => handle_data_symbol_request(message, sym_res),
        fip.FIP_SYM_ENUM => handle_enum_symbol_request(message, sym_res),
        fip.FIP_SYM_OPAQUE => handle_opaque_symbol_request(message, sym_res),
    }
    fip.fip_slave_send_message(main.ID, buffer, &response);
}

pub fn compile_module(
    io: std.Io,
    allocator: std.mem.Allocator,
    path_count: *u8,
    paths: [fip.FIP_PATHS_SIZE]u8,
    config: *main.ModuleConfig,
    compile_message: *const fip.fip_msg_t,
) !bool {
    // Ensure .fip/cache directory exists
    std.Io.Dir.cwd().createDirPath(io, ".fip/cache") catch {
        fip.fip_print(main.ID, fip.FIP_ERROR, "Failed to create .fip directory");
        return false;
    };

    // TODO: Use the target information from the compile_message
    // compile_message->u.com_req.target
    _ = compile_message;

    // Check if the hash is already part of the paths, if it is we already compiled the module
    const hash: []const u8 = config.output;
    if (std.mem.containsAtLeast(u8, paths, 1, hash)) {
        return true;
    }

    var command_size: usize = 0;
    for (config.command) |cmd| {
        command_size += cmd.len + 1;
    }
    const command: []u8 = try allocator.alloc(u8, command_size);
    var idx: usize = 0;
    for (config.command) |cmd| {
        @memcpy(command[idx..(idx + cmd.len)], cmd);
        idx += cmd.len;
        command[idx] = ' ';
        idx += 1;
    }
    command[command_size - 1] = '\x00';
    fip.fip_print(main.ID, fip.FIP_INFO, "Executing: %s", command.ptr);

    var compile_output: [:0]const u8 = &.{};
    const exit_code: c_int = fip.fip_execute_and_capture(&compile_output.ptr, command.ptr);
    if (exit_code == 0) {
        if (compile_output.len > 0) {
            if (compile_output[0] != '\x00') {
                fip.fip_print(main.ID, fip.FIP_INFO, "%s", compile_output.ptr);
            }
            std.c.free(compile_output);
        }
        allocator.free(command);
    } else {
        if (compile_output.len > 0) {
            if (compile_output[0] != '\x00') {
                fip.fip_print(main.ID, fip.FIP_ERROR, "%s", compile_output.ptr);
            }
            std.c.free(compile_output);
        }
        fip.fip_print(main.ID, fip.FIP_ERROR, "Compiling module '%s' failed with exit code %d", config.tag, exit_code);
        allocator.free(command);
        return false;
    }

    fip.fip_print(main.ID, fip.FIP_INFO, "Compiled '%s' successfully", hash);
    // Add to paths array. For this we need to find the first null-byte character in the paths array, that's where
    // we will place our hash at. The good thing is that we only need to check multiples of 8 so this check is rather easy.
    // Because we know how many paths there already are in the paths string we can just offset by
    // path_count * FIP_PATH_SIZE and increment path_count afterwards, as simple as that
    const offset: u16 = path_count.* * fip.FIP_PATH_SIZE;
    if (offset >= fip.FIP_PATHS_SIZE) {
        fip.fip_print(main.ID, fip.FIP_ERROR, "The Paths array is full: %.*s", fip.FIP_PATHS_SIZE, paths);
        fip.fip_print(main.ID, fip.FIP_ERROR, "Could not store hash '%s' in it", hash);
        return false;
    }
    @memcpy(paths[offset..(offset + fip.FIP_PATH_SIZE)], hash);
    path_count.* += 1;
    return true;
}

pub fn handle_compile_request(io: std.Io, allocator: std.mem.Allocator, buffer: [fip.FIP_MSG_SIZE]u8, message: *const fip.fip_msg_t) void {
    std.debug.assert(message.type == fip.FIP_MSG_COMPILE_REQUEST);
    fip.fip_print(main.ID, fip.FIP_INFO, "Compile Request Received");
    var response: fip.fip_msg_t = .{
        .type = fip.FIP_MSG_OBJECT_RESPONSE,
    };
    const obj_res: *fip.fip_msg_object_response_t = &response.u.obj_res;
    obj_res.has_obj = false;
    obj_res.compilation_failed = false;
    @memcpy(obj_res.module_name[0..main.MODULE_NAME.len], main.MODULE_NAME);

    // We need to go through all modules and see whether they need to be compiled
    for (main.symbol_collections.items, 0..) |*collection, i| {
        if (!collection.needed) {
            continue;
        }
        if (!compile_module(io, allocator, obj_res.paths, main.configs[i], message)) {
            obj_res.has_obj = false;
            obj_res.compilation_failed = true;
            break;
        }
        obj_res.has_obj = true;
    }

    fip.fip_slave_send_message(main.ID, buffer, &response);
}

pub fn handle_tag_request(buffer: [fip.FIP_MSG_SIZE]u8, message: *const fip.fip_msg_t) void {
    std.debug.assert(message.type == fip.FIP_MSG_TAG_REQUEST);
    fip.fip_print(main.ID, fip.FIP_INFO, "Tag Request Received");
    const msg_tag: *const [128]u8 = &message.u.tag_req.tag;

    var response: fip.fip_msg_t = .{
        .type = fip.FIP_MSG_TAG_PRESENT_RESPONSE,
    };

    var collection_id: usize = 0;
    var is_present: bool = false;
    for (main.symbol_collections.items) |*collection| {
        if (std.mem.eql(u8, collection.tag, msg_tag)) {
            is_present = true;
            break;
        }
        collection_id += 1;
    }

    // If tag exists but its headers failed to parse, reject it
    if (is_present and main.symbol_collections.items[collection_id].errored) {
        fip.fip_print(main.ID, fip.FIP_ERROR, "Tag '%s' headers failed to parse", msg_tag);
        is_present = false;
    }

    response.u.tag_pres_res.is_present = is_present;
    fip.fip_slave_send_message(main.ID, buffer, &response);
    fip.fip_free_msg(&response);

    if (!is_present) {
        return;
    }

    // Wait for `FIP_MSG_TAG_NEXT_SYMBOL_REQUEST` from master to tell us that it wants to have the next symbol.
    // We simply ping-pong between the master and the slave. The master requests new symbols until we send it an
    // empy symbol as we reached the end of the list. If we reached the end of the list then the slave will automatically
    // fall back to it's normal execution, the master does not need to send any other message to us in this case.
    const collection: *main.CSymbolCollection = &main.symbol_collections.items[collection_id];
    collection.needed = true;
    for (collection.symbols, 0..) |*symbol, i| {
        fip.fip_print(main.ID, fip.FIP_INFO, "Sending symbol %u/%u", i, collection.symbols.len);
        // Wait for master to request the next symbol
        while (!fip.fip_slave_receive_message(buffer)) {
            fip.fip_print(main.ID, fip.FIP_WARN, "No message from master yet...");
        }
        var next_message: fip.fip_msg_t = .{};
        fip.fip_decode_msg(buffer, &next_message);
        switch (next_message.type) {
            fip.FIP_MSG_TAG_NEXT_SYMBOL_REQUEST => break,
            else => {
                fip.fip_print(
                    main.ID,
                    fip.FIP_ERROR,
                    "Unexpected message from master: %s, expected %s",
                    fip.fip_msg_type_str[next_message.type],
                    fip.fip_msg_type_str[fip.FIP_MSG_TAG_NEXT_SYMBOL_REQUEST],
                );
                fip.fip_free_msg(&next_message);
                return;
            },
        }
        response = .{
            .type = fip.FIP_MSG_TAG_SYMBOL_RESPONSE,
            .u = .{
                .tag_sym_res = .{
                    .is_empty = false,
                    .type = symbol.type,
                },
            },
        };
        switch (symbol.type) {
            fip.FIP_SYM_UNKNOWN => continue,
            fip.FIP_SYM_FUNCTION => fip.fip_clone_sig_fn(&response.u.tag_sym_res.sig.@"fn", &symbol.sig.@"fn"),
            fip.FIP_SYM_DATA => fip.fip_clone_sig_data(&response.u.tag_sym_res.sig.data, &symbol.sig.data),
            fip.FIP_SYM_ENUM => fip.fip_clone_sig_enum(&response.u.tag_sym_res.sig.enum_t, &symbol.sig.enum_t),
            fip.FIP_SYM_OPAQUE => fip.fip_clone_sig_opaque(&response.u.tag_sym_res.sig.@"opaque", &symbol.sig.@"opaque"),
        }
        // Send the next symbol to the master
        fip.fip_slave_send_message(main.ID, buffer, &response);
        fip.fip_free_msg(&response);
    }

    // Wait for master to request the next symbol before sending the empty symbol to it
    while (!fip.fip_slave_receive_message(buffer)) {
        fip.fip_print(main.ID, fip.FIP_WARN, "No message from master yet...");
    }
    // Only print the first time we receive a message
    var next_message: fip.fip_msg_t = .{};
    fip.fip_decode_msg(buffer, &next_message);
    if (next_message.type != fip.FIP_MSG_TAG_NEXT_SYMBOL_REQUEST) {
        fip.fip_print(
            main.ID,
            fip.FIP_ERROR,
            "Unexpected message from master: %s, expected %s",
            fip.fip_msg_type_str[next_message.type],
            fip.fip_msg_type_str[fip.FIP_MSG_TAG_NEXT_SYMBOL_REQUEST],
        );
        fip.fip_free_msg(&next_message);
        return;
    }
    // Send "end of list" message
    response = .{
        .type = fip.FIP_MSG_TAG_SYMBOL_RESPONSE,
        .u = .{
            .tag_sym_res = .{
                .is_empty = true,
                .type = fip.FIP_SYM_UNKNOWN,
            },
        },
    };
    fip.fip_slave_send_message(main.ID, buffer, &response);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
