const std = @import("std");
const fip = @import("fip");
const toml = @import("toml");

const main = @import("main.zig");

pub fn parse(allocator: std.mem.Allocator) !bool {
    const toml_file: toml.toml_result_t = fip.slave.load_config(main.ID, main.MODULE_NAME);

    // Validate top-level is a table (toml.toptab)
    if (toml_file.toptab.type != toml.TOML_TABLE) {
        fip.print(main.ID, .@"error", "Toml root is not a table");
        return false;
    }

    // First pass: count top-level tables (each is a module config)
    const top_count: i32 = toml_file.toptab.u.tab.size;
    if (top_count <= 0) {
        fip.print(main.ID, .@"error", "No top-level entries in TOML");
        return false;
    }
    const top_count_usize: usize = @intCast(top_count);
    for (0..top_count_usize) |i| {
        const v: toml.toml_datum_t = toml_file.toptab.u.tab.value[i];
        if (v.type != toml.TOML_TABLE) {
            fip.print(main.ID, .@"error", "Incorrect top-level entry in TOML");
            return false;
        }
    }

    // Allocate CONFIGS
    main.configs = try allocator.alloc(main.ModuleConfig, top_count_usize);
    for (main.configs) |*config| {
        config.* = .{};
    }

    // Second pass: fill CONFIGS
    var cfg_idx: usize = 0;
    for (0..top_count_usize) |i| {
        const v: toml.toml_datum_t = toml_file.toptab.u.tab.value[i];
        const keyname: [*c]const u8 = toml_file.toptab.u.tab.key[i];
        const keylen: usize = @intCast(toml_file.toptab.u.tab.len[i]);

        var cfg: *main.ModuleConfig = &main.configs[cfg_idx];

        // copy tag (may be empty)
        const copy_len: usize = if (keylen < cfg.tag.len - 1) keylen else cfg.tag.len - 1;
        @memcpy(cfg.tag[0..copy_len], keyname[0..copy_len]);
        cfg.tag[copy_len] = '\x00';

        // module table datum, this is the table itself
        const module: toml.toml_datum_t = v;
        // headers (required, array of strings)
        const headers_d: toml.toml_datum_t = toml.toml_get(module, "headers");
        if (headers_d.type != toml.TOML_ARRAY) {
            fip.print(main.ID, .@"error", "Missing or invalid 'headers' in table '%s'", &cfg.tag);
            free_configs(allocator);
            return false;
        }
        if (headers_d.u.arr.size > 0) {
            const headers_len: usize = @intCast(headers_d.u.arr.size);
            cfg.headers = try allocator.alloc([]u8, headers_len);
            const header_elems: [*c]toml.toml_datum_t = headers_d.u.arr.elem;
            for (header_elems[0..headers_len], 0..) |*elem, j| {
                if (elem.type != toml.TOML_STRING) {
                    fip.print(main.ID, .@"error", "Non-string in 'headers' of table '%s'", &cfg.tag);
                    // free allocated so far for this cfg
                    for (0..j) |k| {
                        allocator.free(cfg.headers[k]);
                    }
                    allocator.free(cfg.headers);
                    free_configs(allocator);
                    return false;
                }
                const slen: usize = @intCast(elem.u.str.len);
                cfg.headers[j] = try allocator.alloc(u8, slen + 1);
                @memcpy(cfg.headers[j][0..slen], elem.u.str.ptr[0..slen]);
                cfg.headers[j][slen] = '\x00';
            }
        }
        // sources (optional, array of strings)
        const sources_d: toml.toml_datum_t = toml.toml_get(module, "sources");
        var sources_len: usize = 0;
        var sources: [][]u8 = &.{};
        const sources_present: bool = sources_d.type == toml.TOML_ARRAY;
        if (sources_present) {
            sources_len = if (sources_d.u.arr.size < 0) 0 else @intCast(sources_d.u.arr.size);
            sources = try allocator.alloc([]u8, sources_len);
            const elems: [*c]toml.toml_datum_t = sources_d.u.arr.elem;
            for (elems[0..sources_len], 0..) |*elem, j| {
                if (elem.type != toml.TOML_STRING) {
                    fip.print(main.ID, .@"error", "Non-string in 'sources' of table '%s'", &cfg.tag);
                    // free allocated so far for this cfg
                    for (0..j) |k| {
                        allocator.free(sources[k]);
                    }
                    allocator.free(sources);
                    free_configs(allocator);
                    return false;
                }
                const slen: usize = @intCast(elem.u.str.len);
                sources[j] = try allocator.alloc(u8, slen + 1);
                @memcpy(sources[j][0..slen], elem.u.str.ptr[0..slen]);
                sources[j][slen] = '\x00';
            }
        }
        // command (optional, array of strings)
        // Fails if command is present but no sources are present
        const command_d: toml.toml_datum_t = toml.toml_get(module, "command");
        const command_present: bool = command_d.type == toml.TOML_ARRAY;
        var command_sources_substituted: bool = false;
        var command_output_substituted: bool = false;
        if (command_present) {
            if (!sources_present or sources_len == 0) {
                fip.print(main.ID, .@"error", "Missing, infalid or empty 'sources' in table '%s'", &cfg.tag);
                free_configs(allocator);
                return false;
            }
            var command_len: usize = if (command_d.u.arr.size < 0) 0 else @intCast(command_d.u.arr.size);
            // The command needs to be the size of the actual command strings + the number of sources - 1 (since the `__SOURCES__` string is substituted with the sources)
            command_len += sources_len - 1;
            cfg.command = try allocator.alloc([]u8, command_len);
            const elems: [*c]toml.toml_datum_t = command_d.u.arr.elem;
            for (elems[0 .. command_len - sources_len + 1], 0..) |*elem, j| {
                const cmd_idx = if (command_sources_substituted) j + sources_len - 1 else j;
                if (elem.type != toml.TOML_STRING) {
                    fip.print(main.ID, .@"error", "Non-string in 'command' of table '%s'", &cfg.tag);
                    // // Clean up all command string so far
                    for (0..cmd_idx) |k| {
                        allocator.free(cfg.command[k]);
                    }
                    allocator.free(cfg.command);
                    for (0..sources_len) |k| {
                        allocator.free(sources[k]);
                    }
                    allocator.free(sources);
                    free_configs(allocator);
                    return false;
                }
                const slen: usize = @intCast(elem.u.str.len);
                if (std.mem.eql(u8, elem.u.str.ptr[0..slen], "__SOURCES__")) {
                    if (command_sources_substituted) {
                        // Substituting the sources twice is not allowed
                        fip.print(main.ID, .@"error", "Substituting '__SOURCES__' twice in 'command' in table '%s'", &cfg.tag);
                        // Clean up all command string so far
                        for (0..cmd_idx) |k| {
                            allocator.free(cfg.command[k]);
                        }
                        allocator.free(cfg.command);
                        for (0..sources_len) |k| {
                            allocator.free(sources[k]);
                        }
                        allocator.free(sources);
                        free_configs(allocator);
                        return false;
                    }
                    // Substitute the sources' content into the command by simply copying over the pointer shallowly
                    // and then just freeing the `sources` itself instead of freeing the strings themselves.
                    std.debug.assert(cmd_idx == j);
                    for (0..sources_len) |k| {
                        cfg.command[j + k] = sources[k];
                    }
                    allocator.free(sources);
                    command_sources_substituted = true;
                } else if (std.mem.eql(u8, elem.u.str.ptr[0..slen], "__OUTPUT__")) {
                    if (command_output_substituted) {
                        // Substituting the sources twice is not allowed
                        fip.print(main.ID, .@"error", "Substituting '__OUTPUT__' twice in 'command' in table '%s'", &cfg.tag);
                        // Clean up all command strings so far
                        for (0..j) |k| {
                            allocator.free(cfg.command[k]);
                        }
                        allocator.free(cfg.command);
                        for (0..sources_len) |k| {
                            allocator.free(sources[k]);
                        }
                        allocator.free(sources);
                        free_configs(allocator);
                        return false;
                    }
                    const cache_dir = ".fip/cache/";
                    const file_ext: []const u8 = if (@import("builtin").os.tag == .windows) ".obj" else ".o";
                    const output_len: usize = cache_dir.len + fip.PATH_SIZE + file_ext.len + 1;
                    // Hash the full path `.fip/cache/<tag>` as input so the string is always long enough for good hash distribution.
                    var hash_input: [128]u8 = @splat(0);
                    const hash_input_slice = try std.fmt.bufPrint(&hash_input, "{s}{s}", .{ cache_dir, cfg.tag });
                    // cfg->command[cmd_idx] = (char *)malloc(output_len);
                    cfg.command[cmd_idx] = try allocator.alloc(u8, output_len);
                    // char *insert_ptr = cfg->command[cmd_idx];
                    var insert_ptr: []u8 = cfg.command[cmd_idx];
                    // memcpy(insert_ptr, cache_dir, cache_dir_len);
                    @memcpy(insert_ptr[0..cache_dir.len], cache_dir[0..cache_dir.len]);
                    // insert_ptr += cache_dir_len;
                    insert_ptr = insert_ptr[cache_dir.len..];
                    // fip_create_hash(insert_ptr, hash_input);
                    fip.create_hash(insert_ptr[0..fip.PATH_SIZE], hash_input_slice.ptr);
                    // memcpy(cfg->output, insert_ptr, FIP_PATH_SIZE);
                    @memcpy(cfg.output[0..fip.PATH_SIZE], insert_ptr[0..fip.PATH_SIZE]);
                    // insert_ptr += FIP_PATH_SIZE;
                    insert_ptr = insert_ptr[fip.PATH_SIZE..];
                    // memcpy(insert_ptr, file_ext, ext_len);
                    @memcpy(insert_ptr[0..file_ext.len], file_ext[0..file_ext.len]);
                    cfg.command[cmd_idx][output_len - 1] = '\x00';
                    cfg.output[fip.PATH_SIZE] = '\x00';
                    command_output_substituted = true;
                } else {
                    cfg.command[cmd_idx] = try allocator.alloc(u8, slen + 1);
                    @memcpy(cfg.command[cmd_idx][0..slen], elem.u.str.ptr[0..slen]);
                    cfg.command[cmd_idx][slen] = '\x00';
                }
            }
        }
        if (command_present and !command_sources_substituted) {
            fip.print(main.ID, .@"error", "Missing substitute '__SOURCES__' in 'command' in table '%s'", &cfg.tag);
            if (sources_present) {
                for (0..sources_len) |j| {
                    allocator.free(sources[j]);
                }
                allocator.free(sources);
            }
            free_configs(allocator);
            return false;
        }
        if (command_present and !command_output_substituted) {
            fip.print(main.ID, .@"error", "Missing substitute '__OUTPUT__' in 'command' in table '%s'", &cfg.tag);
            if (sources_present) {
                for (0..sources_len) |j| {
                    allocator.free(sources[j]);
                }
                allocator.free(sources);
            }
            free_configs(allocator);
            return false;
        }
        // Check if 'sources' are present but 'command' is not. In this case we need to free the 'sources'
        // manually here since otherwise they would leak since nothing consumed them
        if (sources_present and !command_present) {
            fip.print(main.ID, .@"error", "Missing or invalid 'command' in table '%s'", &cfg.tag);
            for (0..sources_len) |j| {
                allocator.free(sources[j]);
            }
            allocator.free(sources);
            free_configs(allocator);
            return false;
        }
        cfg_idx += 1;
    }

    // Success: cfg_idx should equal CONFIGS.count
    std.debug.assert(cfg_idx == main.configs.len);
    return true;
}

pub fn free_configs(allocator: std.mem.Allocator) void {
    for (0..main.configs.len) |i| {
        const c: *main.ModuleConfig = &main.configs[i];
        if (c.headers.len > 0) {
            for (0..c.headers.len) |j| {
                allocator.free(c.headers[j]);
            }
            allocator.free(c.headers);
        }
        if (c.command.len > 0) {
            for (0..c.command.len) |j| {
                allocator.free(c.command[j]);
            }
            allocator.free(c.command);
        }
    }
    allocator.free(main.configs);
    main.configs = &.{};
}
