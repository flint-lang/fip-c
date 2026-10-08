const std = @import("std");
const aro = @import("aro");
const fip = @import("fip");

const main = @import("main.zig");

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

    for (tree.root_decls.items) |*decl| {
        const decl_node: aro.Tree.Node = decl.get(&tree);
        var symbol: main.CSymbol = .{
            .line_number = decl.loc(&tree).line,
        };
        @memcpy(symbol.source_file_path[0..file_path.len], file_path);
        switch (decl_node) {
            .function => |function| {
                const fn_type: aro.Type.Func = function.qt.base(compilation).type.func;
                std.debug.print("Found function: {s}\n", .{tree.tokSlice(function.name_tok)});
                symbol.type = fip.FIP_SYM_FUNCTION;
                var sym_fn: *fip.fip_sig_fn_t = &symbol.sig.@"fn";
                sym_fn.args_len = @intCast(fn_type.params.len);
                sym_fn.args = (try allocator.alloc(fip.fip_sig_fn_arg_t, fn_type.params.len)).ptr;
                for (fn_type.params, sym_fn.args[0..fn_type.params.len]) |*param, *arg| {
                    const param_name: []const u8 = param.name.lookup(compilation);
                    @memcpy(arg.name[0..param_name.len], param_name);
                    if (!try get_type(allocator, compilation, &param.qt, &arg.type)) {
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

fn get_type(
    allocator: std.mem.Allocator,
    compilation: *const aro.Compilation,
    qt_in: *const aro.QualType,
    out: *fip.fip_type_t,
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
            const base_type: *fip.fip_type_t = try allocator.create(fip.fip_type_t);
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
            const inner: *fip.fip_type_t = try allocator.create(fip.fip_type_t);
            if (!try get_type(allocator, compilation, &ptr.child, inner)) {
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
            const inner: *fip.fip_type_t = try allocator.create(fip.fip_type_t);
            if (!try get_type(allocator, compilation, &arr.elem, inner)) {
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
            const sname = if (rec.name == .empty) "" else rec.name.lookup(compilation);
            @memcpy(out_struct.name[0..@min(sname.len, 127)], sname);
            if (sname.len < 127) out_struct.name[sname.len] = 0;

            out_struct.field_count = @intCast(rec.fields.len);
            out_struct.fields = (try allocator.alloc(fip.fip_type_t, rec.fields.len)).ptr;

            // Fill each field's type (in declaration order)
            for (rec.fields, out_struct.fields[0..rec.fields.len]) |*field, *ftype| {
                if (!try get_type(allocator, compilation, &field.qt, ftype)) {
                    // Don't forget to free if you want to be clean on error
                    allocator.free(out_struct.fields[0..out_struct.field_count]);
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
                .values = (try allocator.alloc(usize, enum_type.fields.len)).ptr,
            };

            const enum_name = enum_type.name.lookup(compilation);
            @memcpy(out_enum.name[0..@min(enum_name.len, 127)], enum_name);

            for (enum_type.fields, out_enum.values[0..enum_type.fields.len]) |*field, *value| {
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
