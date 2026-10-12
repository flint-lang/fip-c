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
    collection: *main.CSymbolCollection,
) !void {
    var preproc = try aro.Preprocessor.init(compilation, .testing);
    defer preproc.deinit();
    try preproc.addBuiltinMacros();
    const builtin_macros = try compilation.generateBuiltinMacros(.include_system_defines);
    _ = try preproc.preprocess(builtin_macros);

    const source = try compilation.addSourceFromPath(file_path);
    const eof = try preproc.preprocess(source);
    try preproc.addToken(eof);

    var tree: aro.Tree = try aro.Parser.parse(&preproc);
    defer tree.deinit();
    if (main.LOG_LEVEL == .debug) {
        try tree.dump(terminal);
    }

    var symbols: std.ArrayList(main.CSymbol) = .empty;
    errdefer free_symbol_list(allocator, &symbols);

    for (tree.root_decls.items) |*decl| {
        if (decl.loc(&tree).id != source.id) {
            // Only collect files from the actual pointed-to source file
            continue;
        }
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
                symbol.sig.tag = .@"fn";
                const sym_fn: *fip.Signature.Fn = &symbol.sig.u.@"fn";
                const fn_name: []const u8 = tree.tokSlice(function.name_tok);
                const fn_name_len = @min(fn_name.len, fip.NAME_SIZE);
                sym_fn.name = @splat(0);
                @memcpy(sym_fn.name[0..fn_name_len], fn_name[0..fn_name_len]);

                sym_fn.args_len = @intCast(fn_type.params.len);
                sym_fn.args =
                    if (fn_type.params.len > 0)
                        (try fip_alloc.alloc(fip.Signature.Fn.Arg, fn_type.params.len)).ptr
                    else
                        undefined;
                for (fn_type.params, sym_fn.args[0..sym_fn.args_len]) |*param, *arg| {
                    const param_name: []const u8 = param.name.lookup(compilation);
                    arg.name = @splat(0);
                    @memcpy(arg.name[0..@min(param_name.len, fip.NAME_SIZE)], param_name);
                    try get_type(compilation, symbols, &param.qt, &arg.type);
                }

                var ret_type: fip.Type = .{ .tag = .primitive, .u = .{ .primitive = .void } };
                try get_type(compilation, symbols, &fn_type.return_type, &ret_type);
                sym_fn.rets_len = 0;
                sym_fn.rets = undefined;
                if (ret_type.tag != .primitive and ret_type.u.primitive != .void) {
                    sym_fn.rets_len = 1;
                    sym_fn.rets = (try fip_alloc.alloc(fip.Type, 1)).ptr;
                    sym_fn.rets[0] = ret_type;
                }
            },
            .typedef => |typedef| {
                const name_slice = tree.tokSlice(typedef.name_tok);
                fip.print(main.ID, .debug, "typedef.name = '%.*s'", @as(i32, @intCast(name_slice.len)), name_slice.ptr);
                std.debug.assert(symbols.items.len > 1);
                var last_symbol: *main.CSymbol = &symbols.items[symbols.items.len - 2];

                // If the last thing we parsed was an anonymous definition, we assume that this type def defines it
                if (last_symbol.get_name() == null) {
                    // Change the name of the last parsed symbol and pop the typedef to make it "disappear"
                    last_symbol.set_name(tree.tokSlice(typedef.name_tok));
                    _ = symbols.pop();
                }
                // It is a type alias
                symbol.sig.tag = .alias;
                symbol.set_name(tree.tokSlice(typedef.name_tok));
                try get_type(compilation, symbols, &typedef.qt, &symbol.sig.u.alias.type);
            },
            .variable => |variable| {
                std.debug.print("Found variable: {s}\n", .{tree.tokSlice(variable.name_tok)});
                @panic("TODO");
            },
            .enum_decl => |enum_decl| {
                const enum_t: aro.Type.Enum = enum_decl.container_qt.base(compilation).type.@"enum";
                std.debug.assert(enum_decl.fields.len == enum_t.fields.len);
                symbol.sig.tag = .@"enum";
                // Don't set the name if the token is anything other than an identifier
                const id = tree.tokens.items(.id)[enum_decl.name_or_kind_tok];
                if (id == .identifier) {
                    symbol.set_name(tree.tokSlice(enum_decl.name_or_kind_tok));
                }
                const @"enum" = &symbol.sig.u.@"enum";
                @"enum".value_count = enum_t.fields.len;
                @"enum".values = (try fip_alloc.alloc(fip.Signature.Enum.Value, @"enum".value_count)).ptr;
                for (enum_t.fields, enum_decl.fields, @"enum".values[0..@"enum".value_count]) |*field, decl_field, *value| {
                    const value_tag: []const u8 = field.name.lookup(compilation);
                    const value_tag_len: usize = @min(value_tag.len, fip.NAME_SIZE);
                    value.tag = @splat(0);
                    @memcpy(value.tag[0..value_tag_len], value_tag[0..value_tag_len]);
                    value.value =
                        if (tree.value_map.get(decl_field)) |val|
                            if (val.toInt(usize, compilation)) |uval| .{
                                .is_signed = false,
                                .value = uval,
                            } else if (val.toInt(i64, compilation)) |ival| .{
                                .is_signed = ival < 0,
                                .value = @abs(ival),
                            } else .{ .is_signed = false, .value = 0 }
                        else
                            .{ .is_signed = false, .value = 0 };
                }
            },
            .enum_forward_decl => |enum_forward_decl| {
                std.debug.print("Found enum forward: {s}\n", .{tree.tokSlice(enum_forward_decl.name_or_kind_tok)});
                @panic("TODO");
            },
            .struct_decl => |struct_decl| {
                const record: aro.Type.Record = struct_decl.container_qt.base(compilation).type.@"struct";
                symbol.sig.tag = .data;
                // Don't set the name if the token is anything other than an identifier
                const id = tree.tokens.items(.id)[struct_decl.name_or_kind_tok];
                if (id == .identifier) {
                    symbol.set_name(tree.tokSlice(struct_decl.name_or_kind_tok));
                }
                const data = &symbol.sig.u.data;
                data.field_count = record.fields.len;
                data.fields = (try fip_alloc.alloc(fip.Signature.Data.Field, data.field_count)).ptr;
                for (record.fields, data.fields[0..data.field_count]) |*rfield, *dfield| {
                    try get_type(compilation, symbols, &rfield.qt, &dfield.type);
                    const field_name: []const u8 = rfield.name.lookup(compilation);
                    const field_name_len: usize = @min(field_name.len, fip.NAME_SIZE);
                    dfield.name = @splat(0);
                    @memcpy(dfield.name[0..field_name_len], field_name[0..field_name_len]);
                }
            },
            .struct_forward_decl => |struct_forward_decl| {
                std.debug.print("Found struct forward: {s}\n", .{tree.tokSlice(struct_forward_decl.name_or_kind_tok)});
                @panic("TODO");
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

    for (symbols.items) |*symbol| {
        symbol.sig.print(main.ID);
    }

    collection.* = .{
        .needed = false,
        .errored = false,
        .tag = @splat(0),
        .symbols = try symbols.toOwnedSlice(allocator),
    };
    // TODO: Set tag
}

fn free_symbol(symbol: *main.CSymbol) void {
    switch (symbol.sig.tag) {
        .@"fn" => {
            const fn_sig = &symbol.sig.u.@"fn";
            if (fn_sig.args_len > 0) {
                for (fn_sig.args[0..fn_sig.args_len]) |*arg| {
                    arg.type.free();
                }
                fip_alloc.free(fn_sig.args[0..fn_sig.args_len]);
            }
            fn_sig.args = undefined;
            fn_sig.args_len = 0;
            if (fn_sig.rets_len > 0) {
                for (fn_sig.rets[0..fn_sig.rets_len]) |*ret| {
                    ret.free();
                }
                fip_alloc.free(fn_sig.rets[0..fn_sig.rets_len]);
            }
            fn_sig.rets = undefined;
            fn_sig.rets_len = 0;
        },
        .data => {
            const data_sig = &symbol.sig.u.data;
            if (data_sig.field_count > 0) {
                for (data_sig.fields[0..data_sig.field_count]) |*field| {
                    field.type.free();
                }
                fip_alloc.free(data_sig.fields[0..data_sig.field_count]);
            }
            data_sig.fields = undefined;
            data_sig.field_count = 0;
        },
        .@"enum" => {
            const enum_sig = &symbol.sig.u.@"enum";
            if (enum_sig.value_count > 0) {
                fip_alloc.free(enum_sig.values[0..enum_sig.value_count]);
            }
            enum_sig.values = undefined;
            enum_sig.value_count = 0;
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

fn free_type_array(types: []fip.Type) void {
    for (types) |*field| {
        field.free();
    }
    if (types.len > 0) {
        fip_alloc.free(types);
    }
}

fn get_named_type(symbols: std.ArrayList(main.CSymbol), name: []const u8) ?fip.Type.Named {
    const cmp_size = @min(name.len, fip.NAME_SIZE);
    var named_type: fip.Type.Named = .{};
    @memcpy(named_type.name[0..cmp_size], name[0..cmp_size]);
    for (symbols.items) |*symbol| {
        if (symbol.get_name()) |symbol_name| {
            if (std.mem.eql(u8, symbol_name, name)) {
                return named_type;
            }
        }
    }
    return null;
}

fn get_type(
    compilation: *const aro.Compilation,
    symbols: std.ArrayList(main.CSymbol),
    qt_in: *const aro.QualType,
    out: *fip.Type,
) !void {
    out.* = switch (qt_in.type(compilation)) {
        .void => .{
            .is_mutable = !qt_in.@"const",
            .tag = .primitive,
            .u = .{ .primitive = .void },
        },
        .bool => .{
            .is_mutable = !qt_in.@"const",
            .tag = .primitive,
            .u = .{ .primitive = .bool },
        },
        .nullptr_t => blk: {
            const base_type: *fip.Type = try fip_alloc.create(fip.Type);
            base_type.* = .{
                .is_mutable = false,
                .tag = .primitive,
                .u = .{ .primitive = .void },
            };
            break :blk .{
                .is_mutable = !qt_in.@"const",
                .tag = .pointer,
                .u = .{
                    .pointer = .{
                        .base_type = base_type,
                    },
                },
            };
        },

        .int => |int| .{
            .is_mutable = !qt_in.@"const",
            .tag = .primitive,
            .u = .{
                .primitive = switch (int) {
                    .char => .i8,
                    .schar => .i8,
                    .uchar => .u8,
                    .short => .i16,
                    .ushort => .u16,
                    .int => .i32,
                    .uint => .u32,
                    .long, .long_long => .i64,
                    .ulong, .ulong_long => .u64,
                    .int128 => {
                        fip.print(main.ID, .@"error", "FIP cannot hanlde int128 types");
                        return error.CannotHandleType;
                    },
                    .uint128 => {
                        fip.print(main.ID, .@"error", "FIP cannot hanlde uint128 types");
                        return error.CannotHandleType;
                    },
                },
            },
        },
        .float => |float| .{
            .is_mutable = !qt_in.@"const",
            .tag = .primitive,
            .u = .{
                .primitive = switch (float) {
                    .bf16 => {
                        fip.print(main.ID, .@"error", "FIP cannot handle 'bf16' types");
                        return error.CannotHandleType;
                    },
                    .fp16, .float16 => {
                        fip.print(main.ID, .@"error", "FIP cannot handle 'f16' types");
                        return error.CannotHandleType;
                    },
                    .float, .float32 => .f32,
                    .double, .float64 => .f32,
                    .long_double => {
                        fip.print(main.ID, .@"error", "FIP cannot handle 'long double' types");
                        return error.CannotHandleType;
                    },
                    .float128 => {
                        fip.print(main.ID, .@"error", "FIP cannot handle 'f128' types");
                        return error.CannotHandleType;
                    },
                    .float32x => {
                        fip.print(main.ID, .@"error", "FIP cannot handle 'float32x' types");
                        return error.CannotHandleType;
                    },
                    .float64x => {
                        fip.print(main.ID, .@"error", "FIP cannot handle 'float64x' types");
                        return error.CannotHandleType;
                    },
                    .float128x => {
                        fip.print(main.ID, .@"error", "FIP cannot handle 'float128x' types");
                        return error.CannotHandleType;
                    },
                    .dfloat32 => {
                        fip.print(main.ID, .@"error", "FIP cannot handle 'dfloat32' types");
                        return error.CannotHandleType;
                    },
                    .dfloat64 => {
                        fip.print(main.ID, .@"error", "FIP cannot handle 'dfloat64' types");
                        return error.CannotHandleType;
                    },
                    .dfloat128 => {
                        fip.print(main.ID, .@"error", "FIP cannot handle 'dfloat128' types");
                        return error.CannotHandleType;
                    },
                    .dfloat64x => {
                        fip.print(main.ID, .@"error", "FIP cannot handle 'dfloat64x' types");
                        return error.CannotHandleType;
                    },
                },
            },
        },
        .complex => {
            fip.print(main.ID, .@"error", "FIP cannot handle complex types");
            return error.CannotHandleType;
        },
        .bit_int => {
            fip.print(main.ID, .@"error", "FIP cannot handle bit int types");
            return error.CannotHandleType;
        },
        .atomic => {
            fip.print(main.ID, .@"error", "FIP cannot handle atomic types");
            return error.CannotHandleType;
        },

        .func => {
            fip.print(main.ID, .@"error", "FIP cannot handle function types");
            return error.CannotHandleType;
        },
        .pointer => |ptr| blk: {
            const child_base = ptr.child.base(compilation);
            const inner: *fip.Type = try fip_alloc.create(fip.Type);
            errdefer fip_alloc.destroy(inner);
            // Check for recursive types
            var inner_initialized: bool = false;
            switch (child_base.type) {
                .@"struct" => |@"struct"| if (get_named_type(symbols, @"struct".name.lookup(compilation))) |named| {
                    inner.* = .{
                        .is_mutable = !qt_in.@"const",
                        .tag = .named,
                        .u = .{ .named = named },
                    };
                    inner_initialized = true;
                },
                .@"union" => |@"union"| if (get_named_type(symbols, @"union".name.lookup(compilation))) |named| {
                    inner.* = .{
                        .is_mutable = !qt_in.@"const",
                        .tag = .named,
                        .u = .{ .named = named },
                    };
                    inner_initialized = true;
                },
                else => {},
            }
            if (!inner_initialized) {
                try get_type(compilation, symbols, &ptr.child, inner);
            }
            break :blk .{
                .is_mutable = !qt_in.@"const",
                .tag = .pointer,
                .u = .{ .pointer = .{ .base_type = inner } },
            };
        },
        .array => |arr| blk: {
            const len: usize = switch (arr.len) {
                .incomplete => {
                    fip.print(main.ID, .@"error", "FIP cannot handle dynamic array types");
                    return error.CannotHandleType;
                },
                .fixed => |size| size,
                .static => |size| size,
                .variable => {
                    fip.print(main.ID, .@"error", "FIP cannot handle variable length array types");
                    return error.CannotHandleType;
                },
                .unspecified_variable => {
                    fip.print(main.ID, .@"error", "FIP cannot handle unspecified variable length array types");
                    return error.CannotHandleType;
                },
            };
            const inner: *fip.Type = try fip_alloc.create(fip.Type);
            errdefer fip_alloc.destroy(inner);
            try get_type(compilation, symbols, &arr.elem, inner);
            break :blk .{
                .is_mutable = !qt_in.@"const",
                .tag = .array,
                .u = .{
                    .array = .{
                        .size = len,
                        .base_type = inner,
                    },
                },
            };
        },
        .vector => {
            fip.print(main.ID, .@"error", "FIP cannot handle vector types");
            return error.CannotHandleType;
        },

        .@"struct" => |rec| blk: {
            var out_struct = fip.Type.Struct{};

            // Copy struct name
            const sname = rec.name.lookup(compilation);
            @memcpy(out_struct.name[0..@min(sname.len, 127)], sname);
            if (sname.len < 127) {
                out_struct.name[sname.len] = '\x00';
            }

            // Check for recursion before expanding fields
            if (get_named_type(symbols, sname)) |named| {
                break :blk .{
                    .is_mutable = !qt_in.@"const",
                    .tag = .named,
                    .u = .{ .named = named },
                };
            }

            out_struct.field_count = @intCast(rec.fields.len);
            const fields: []fip.Type =
                if (rec.fields.len > 0)
                    (try fip_alloc.alloc(fip.Type, rec.fields.len))
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
                try get_type(compilation, symbols, &field.qt, ftype);
            }

            break :blk .{
                .is_mutable = !qt_in.@"const",
                .tag = .@"struct",
                .u = .{ .@"struct" = out_struct },
            };
        },
        .@"union" => {
            fip.print(main.ID, .@"error", "FIP cannot handle union types");
            return error.CannotHandleType;
        },
        .@"enum" => |enum_type| blk: {
            var out_enum: fip.Type.Enum = .{
                .bit_width = 32,
                .is_signed = true,
                .value_count = @intCast(enum_type.fields.len),
            };
            const values: []fip.Type.Enum.Value =
                if (enum_type.fields.len > 0)
                    (try fip_alloc.alloc(fip.Type.Enum.Value, enum_type.fields.len))
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
                .tag = .@"enum",
                .u = .{ .@"enum" = out_enum },
            };
        },

        .typeof => |typeof| return try get_type(compilation, symbols, &typeof.base, out),
        .typedef => |typedef| if (get_named_type(symbols, typedef.name.lookup(compilation))) |named|
            .{
                .is_mutable = !qt_in.@"const",
                .tag = .named,
                .u = .{ .named = named },
            }
        else
            return try get_type(compilation, symbols, &typedef.base, out),
        .attributed => |attributed| return try get_type(compilation, symbols, &attributed.base, out),
    };
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
