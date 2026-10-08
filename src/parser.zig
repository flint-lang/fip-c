const std = @import("std");
const aro = @import("aro");
const fip = @import("fip");

const main = @import("main.zig");

/// All memory owned by FIP structures needs to be allocated using the C allocator
const fip_alloc = std.heap.c_allocator;

pub fn parse_file(
    allocator: std.mem.Allocator,
    terminal: std.Io.Terminal,
    compilation: *aro.Compilation,
    file_path: []const u8,
) !?main.CSymbolCollection {
    var preproc = try aro.Preprocessor.init(compilation, .testing);
    defer preproc.deinit();
    try preproc.addBuiltinMacros();
    const builtin_macros = try compilation.generateBuiltinMacros(.include_system_defines);
    _ = try preproc.preprocess(builtin_macros);

    const main_c = try compilation.addSourceFromPath(file_path);
    const eof = try preproc.preprocess(main_c);
    try preproc.addToken(eof);

    var tree: aro.Tree = try aro.Parser.parse(&preproc);
    defer tree.deinit();
    try tree.dump(terminal);

    var symbols: std.ArrayList(main.CSymbol) = .empty;
    errdefer free_symbol_list(allocator, &symbols);

    for (tree.root_decls.items) |*decl| {
        const decl_node: aro.Tree.Node = decl.get(&tree);
        try symbols.append(allocator, .{
            .line_number = decl.loc(&tree).line,
        });
        const symbol: *main.CSymbol = &symbols.items[symbols.items.len - 1];
        const path_len = @min(file_path.len, symbol.source_file_path.len - 1);
        @memcpy(symbol.source_file_path[0..path_len], file_path);
        switch (decl_node) {
            .function => |function| {
                const fn_type: aro.Type.Func = function.qt.base(compilation).type.func;
                std.debug.print("Found function: {s}\n", .{tree.tokSlice(function.name_tok)});
                symbol.type = fip.FIP_SYM_FUNCTION;
                const sym_fn: *fip.fip_sig_fn_t = &symbol.sig.@"fn";
                sym_fn.args_len = @intCast(fn_type.params.len);
                const args: []fip.fip_sig_fn_arg_t =
                    if (fn_type.params.len > 0)
                        (try fip_alloc.alloc(fip.fip_sig_fn_arg_t, fn_type.params.len))
                    else
                        &.{};
                @memset(std.mem.sliceAsBytes(args), 0);
                if (args.len > 0) sym_fn.args = args.ptr;
                for (fn_type.params, args) |*param, *arg| {
                    const param_name: []const u8 = param.name.lookup(compilation);
                    @memcpy(arg.name[0..@min(param_name.len, 127)], param_name);
                    if (!try get_type(compilation, &param.qt, &arg.type, &.{})) {
                        free_symbol_list(allocator, &symbols);
                        return null;
                    }
                }
            },
            .typedef => |typedef| {
                std.debug.print("Found typedef: {s}\n", .{tree.tokSlice(typedef.name_tok)});
            },
            .variable => |variable| {
                std.debug.print("Found variable: {s}\n", .{tree.tokSlice(variable.name_tok)});
            },
            .enum_decl => |enum_decl| {
                std.debug.print("Found enum: {s}\n", .{tree.tokSlice(enum_decl.name_or_kind_tok)});
                symbol.type = fip.FIP_SYM_ENUM;
            },
            .enum_forward_decl => |enum_forward_decl| {
                std.debug.print("Found enum forward: {s}\n", .{tree.tokSlice(enum_forward_decl.name_or_kind_tok)});
                symbol.type = fip.FIP_SYM_ENUM;
            },
            .struct_decl => |struct_decl| {
                std.debug.print("Found struct: {s}\n", .{tree.tokSlice(struct_decl.name_or_kind_tok)});
                symbol.type = fip.FIP_SYM_DATA;
            },
            .struct_forward_decl => |struct_forward_decl| {
                std.debug.print("Found struct forward: {s}\n", .{tree.tokSlice(struct_forward_decl.name_or_kind_tok)});
                symbol.type = fip.FIP_SYM_DATA;
            },
            .union_decl => |union_decl| {
                std.debug.print("Found union: {s}\n", .{tree.tokSlice(union_decl.name_or_kind_tok)});
                @panic("TODO");
            },
            .union_forward_decl => |union_forward_decl| {
                std.debug.print("Found union forward: {s}\n", .{tree.tokSlice(union_forward_decl.name_or_kind_tok)});
                @panic("TODO");
            },
            else => {
                std.debug.print("Invalid decltype: {s}\n", .{@tagName(decl_node)});
                return error.InvalidDecltype;
            },
        }
    }

    const collection: main.CSymbolCollection = .{
        .needed = false,
        .errored = false,
        .tag = @splat(0),
        .symbols = try symbols.toOwnedSlice(allocator),
    };
    // TODO: Set tag
    return collection;
}

fn free_symbol(symbol: *main.CSymbol) void {
    switch (symbol.type) {
        fip.FIP_SYM_FUNCTION => {
            const fn_sig = &symbol.sig.@"fn";
            if (fn_sig.args_len > 0 and fn_sig.args != null) {
                for (fn_sig.args[0..fn_sig.args_len]) |*arg| {
                    fip.fip_free_type(&arg.type);
                }
                fip_alloc.free(fn_sig.args[0..fn_sig.args_len]);
            }
            fn_sig.args = null;
            fn_sig.args_len = 0;
            if (fn_sig.rets_len > 0 and fn_sig.rets != null) {
                for (fn_sig.rets[0..fn_sig.rets_len]) |*ret| {
                    fip.fip_free_type(ret);
                }
                fip_alloc.free(fn_sig.rets[0..fn_sig.rets_len]);
            }
            fn_sig.rets = null;
            fn_sig.rets_len = 0;
        },
        fip.FIP_SYM_DATA => {
            const data_sig = &symbol.sig.data;
            if (data_sig.value_count > 0) {
                if (data_sig.value_names != null) {
                    for (data_sig.value_names[0..data_sig.value_count]) |name| {
                        if (name != null) {
                            const str: [*:0]const u8 = @ptrCast(name);
                            fip_alloc.free(str[0 .. std.mem.len(str) + 1]);
                        }
                    }
                    fip_alloc.free(data_sig.value_names[0..data_sig.value_count]);
                }
                if (data_sig.value_types != null) {
                    for (data_sig.value_types[0..data_sig.value_count]) |*t| {
                        fip.fip_free_type(t);
                    }
                    fip_alloc.free(data_sig.value_types[0..data_sig.value_count]);
                }
                data_sig.value_count = 0;
            }
        },
        fip.FIP_SYM_ENUM => {
            const enum_sig = &symbol.sig.enumt;
            if (enum_sig.value_count > 0) {
                if (enum_sig.tags != null) {
                    for (enum_sig.tags[0..enum_sig.value_count]) |tag| {
                        if (tag != null) {
                            const str: [*:0]const u8 = @ptrCast(tag);
                            fip_alloc.free(str[0 .. std.mem.len(str) + 1]);
                        }
                    }
                    fip_alloc.free(enum_sig.tags[0..enum_sig.value_count]);
                }
                if (enum_sig.values != null) {
                    fip_alloc.free(enum_sig.values[0..enum_sig.value_count]);
                }
                enum_sig.value_count = 0;
            }
        },
        else => {},
    }
}

pub fn free_symbols(allocator: std.mem.Allocator, symbols: []main.CSymbol) void {
    for (symbols) |*symbol| {
        free_symbol(symbol);
    }
    allocator.free(symbols);
}

fn free_symbol_list(allocator: std.mem.Allocator, symbols: *std.ArrayList(main.CSymbol)) void {
    for (symbols.items) |*symbol| {
        free_symbol(symbol);
    }
    symbols.deinit(allocator);
}

fn free_type_array(fields: []fip.fip_type_t) void {
    for (fields) |*field| {
        fip.fip_free_type(field);
    }
    if (fields.len > 0) {
        fip_alloc.free(fields);
    }
}

fn findInStack(stack: []const []const u8, name: []const u8) ?usize {
    if (name.len == 0) {
        return null;
    }
    var i = stack.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, stack[i], name)) {
            return i;
        }
    }
    return null;
}

fn get_type(
    compilation: *const aro.Compilation,
    qt_in: *const aro.QualType,
    out: *fip.fip_type_t,
    type_stack: []const []const u8,
) !bool {
    const base = qt_in.base(compilation);
    const in = base.type;
    out.* = switch (in) {
        .void => .{
            .is_mutable = !qt_in.@"const",
            .type = fip.FIP_TYPE_PRIMITIVE,
            .u = .{ .prim = fip.FIP_VOID },
        },
        .bool => .{
            .is_mutable = !qt_in.@"const",
            .type = fip.FIP_TYPE_PRIMITIVE,
            .u = .{ .prim = fip.FIP_BOOL },
        },
        .nullptr_t => blk: {
            const base_type: *fip.fip_type_t = try fip_alloc.create(fip.fip_type_t);
            base_type.* = .{
                .is_mutable = false,
                .type = fip.FIP_TYPE_PRIMITIVE,
                .u = .{ .prim = fip.FIP_VOID },
            };
            break :blk .{
                .is_mutable = !qt_in.@"const",
                .type = fip.FIP_TYPE_PTR,
                .u = .{
                    .ptr = .{
                        .base_type = base_type,
                    },
                },
            };
        },

        .int => |int| .{
            .is_mutable = !qt_in.@"const",
            .type = fip.FIP_TYPE_PRIMITIVE,
            .u = .{
                .prim = switch (int) {
                    .char => fip.FIP_I8,
                    .schar => fip.FIP_I8,
                    .uchar => fip.FIP_U8,
                    .short => fip.FIP_I16,
                    .ushort => fip.FIP_U16,
                    .int => fip.FIP_I32,
                    .uint => fip.FIP_U32,
                    .long, .long_long => fip.FIP_I64,
                    .ulong, .ulong_long => fip.FIP_U64,
                    .int128 => {
                        fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot hanlde int128 types");
                        return false;
                    },
                    .uint128 => {
                        fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot hanlde uint128 types");
                        return false;
                    },
                },
            },
        },
        .float => |float| .{
            .is_mutable = !qt_in.@"const",
            .type = fip.FIP_TYPE_PRIMITIVE,
            .u = .{
                .prim = switch (float) {
                    .bf16 => {
                        fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle 'bf16' types");
                        return false;
                    },
                    .fp16, .float16 => {
                        fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle 'f16' types");
                        return false;
                    },
                    .float, .float32 => fip.FIP_F32,
                    .double, .float64 => fip.FIP_F64,
                    .long_double => {
                        fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle 'long double' types");
                        return false;
                    },
                    .float128 => {
                        fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle 'f128' types");
                        return false;
                    },
                    .float32x => {
                        fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle 'float32x' types");
                        return false;
                    },
                    .float64x => {
                        fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle 'float64x' types");
                        return false;
                    },
                    .float128x => {
                        fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle 'float128x' types");
                        return false;
                    },
                    .dfloat32 => {
                        fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle 'dfloat32' types");
                        return false;
                    },
                    .dfloat64 => {
                        fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle 'dfloat64' types");
                        return false;
                    },
                    .dfloat128 => {
                        fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle 'dfloat128' types");
                        return false;
                    },
                    .dfloat64x => {
                        fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle 'dfloat64x' types");
                        return false;
                    },
                },
            },
        },
        .complex => {
            fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle complex types");
            return false;
        },
        .bit_int => {
            fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle bit int types");
            return false;
        },
        .atomic => {
            fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle atomic types");
            return false;
        },

        .func => {
            fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle function types");
            return false;
        },
        .pointer => |ptr| blk: {
            // Check for recursive reference through pointer
            const child_base = ptr.child.base(compilation);
            switch (child_base.type) {
                .@"struct" => |r| if (findInStack(type_stack, r.name.lookup(compilation))) |_| {
                    const levels_back = 1;
                    break :blk .{
                        .is_mutable = !qt_in.@"const",
                        .type = fip.FIP_TYPE_RECURSIVE,
                        .u = .{ .recursive = .{ .levels_back = @intCast(levels_back) } },
                    };
                },
                .@"union" => |u| if (findInStack(type_stack, u.name.lookup(compilation))) |_| {
                    const levels_back = 1;
                    break :blk .{
                        .is_mutable = !qt_in.@"const",
                        .type = fip.FIP_TYPE_RECURSIVE,
                        .u = .{ .recursive = .{ .levels_back = @intCast(levels_back) } },
                    };
                },
                else => {},
            }

            // Normal pointer: expand child
            const inner: *fip.fip_type_t = try fip_alloc.create(fip.fip_type_t);
            errdefer fip_alloc.destroy(inner);
            if (!try get_type(compilation, &ptr.child, inner, type_stack)) {
                fip_alloc.destroy(inner);
                return false;
            }
            break :blk .{
                .is_mutable = !qt_in.@"const",
                .type = fip.FIP_TYPE_PTR,
                .u = .{ .ptr = .{ .base_type = inner } },
            };
        },
        .array => |arr| blk: {
            const len: usize = switch (arr.len) {
                .incomplete => {
                    fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle dynamic array types");
                    return false;
                },
                .fixed => |size| size,
                .static => |size| size,
                .variable => {
                    fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle variable length array types");
                    return false;
                },
                .unspecified_variable => {
                    fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle unspecified variable length array types");
                    return false;
                },
            };
            const inner: *fip.fip_type_t = try fip_alloc.create(fip.fip_type_t);
            errdefer fip_alloc.destroy(inner);
            if (!try get_type(compilation, &arr.elem, inner, type_stack)) {
                fip_alloc.destroy(inner);
                return false;
            }
            break :blk .{
                .is_mutable = !qt_in.@"const",
                .type = fip.FIP_TYPE_ARRAY,
                .u = .{
                    .array = .{
                        .size = len,
                        .base_type = inner,
                    },
                },
            };
        },
        .vector => {
            fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle vector types");
            return false;
        },

        .@"struct" => |rec| blk: {
            var out_struct = fip.fip_type_struct_t{};

            // Copy struct name
            const sname = rec.name.lookup(compilation);
            @memcpy(out_struct.name[0..@min(sname.len, 127)], sname);
            if (sname.len < 127) {
                out_struct.name[sname.len] = '\x00';
            }

            // Check for recursion before expanding fields
            if (findInStack(type_stack, sname) != null) {
                break :blk .{
                    .is_mutable = !qt_in.@"const",
                    .type = fip.FIP_TYPE_RECURSIVE,
                    .u = .{ .recursive = .{ .levels_back = 1 } },
                };
            }

            // Build new stack if named
            var new_stack_allocated: ?std.ArrayList([]const u8) = null;
            const new_stack =
                if (sname.len > 0) blk_ns: {
                    var list = std.ArrayList([]const u8).empty;
                    try list.appendSlice(fip_alloc, type_stack);
                    try list.append(fip_alloc, sname);
                    new_stack_allocated = list;
                    break :blk_ns list.items;
                } else type_stack;
            defer if (new_stack_allocated) |*lst| {
                lst.deinit(fip_alloc);
            };

            out_struct.field_count = @intCast(rec.fields.len);
            const fields: []fip.fip_type_t =
                if (rec.fields.len > 0)
                    (try fip_alloc.alloc(fip.fip_type_t, rec.fields.len))
                else
                    &.{};
            // Zero so that partially-built field entries are FIP_TYPE_PRIMITIVE
            // no-ops for fip_free_type on the error path.
            @memset(std.mem.sliceAsBytes(fields), 0);
            if (fields.len > 0) {
                out_struct.fields = fields.ptr;
            }
            errdefer free_type_array(fields[0..out_struct.field_count]);

            // Fill each field's type (in declaration order)
            for (rec.fields, fields) |*field, *ftype| {
                if (!try get_type(compilation, &field.qt, ftype, new_stack)) {
                    free_type_array(fields[0..out_struct.field_count]);
                    return false;
                }
            }

            break :blk .{
                .is_mutable = !qt_in.@"const",
                .type = fip.FIP_TYPE_STRUCT,
                .u = .{ .struct_t = out_struct },
            };
        },
        .@"union" => {
            fip.fip_print(main.ID, fip.FIP_ERROR, "FIP cannot handle union types");
            return false;
        },
        .@"enum" => |enum_type| blk: {
            var out_enum: fip.fip_type_enum_t = .{
                .name = @splat(0),
                .bit_width = 32,
                .is_signed = 1,
                .value_count = @intCast(enum_type.fields.len),
                .values = null,
            };
            const values: []usize =
                if (enum_type.fields.len > 0)
                    (try fip_alloc.alloc(usize, enum_type.fields.len))
                else
                    &.{};
            if (values.len > 0) {
                out_enum.values = values.ptr;
            }

            const enum_name = enum_type.name.lookup(compilation);
            @memcpy(out_enum.name[0..@min(enum_name.len, 127)], enum_name);

            for (enum_type.fields, values) |*field, *value| {
                // TODO: Set fields of enum values
                _ = field;
                _ = value;
            }

            break :blk .{
                .is_mutable = !qt_in.@"const",
                .type = fip.FIP_TYPE_ENUM,
                .u = .{ .enum_t = out_enum },
            };
        },

        .typeof, .typedef, .attributed => @panic("These types should have disappeared because of the  base type unwrap"),
    };
    return true;
}
