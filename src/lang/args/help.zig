const std = @import("std");
const coll = @import("../collections.zig");
const PositionalOf = @import("positionals.zig").PositionalOf;
const meta = @import("../meta.zig");
const GroupMatchConfig = @import("validate.zig").GroupMatchConfig;
const DefaultPosT = @import("spec.zig").defaultPositionals();
const btType = std.builtin.Type;

pub const HelpConf = struct {
    backwardsBranchesQuote: comptime_int = 1000000,
    indent: u4 = 2,
    headerDelimiter: []const u8 = "\n",
    columnSpace: u4 = 4,
    simpleTypes: bool = false,
    optionsBreakline: bool = false,
};

pub fn HelpFmt(comptime Spec: type, comptime conf: HelpConf) type {
    return struct {
        const Help: HelpData(Spec) = if (@hasDecl(Spec, "Help")) rt: {
            if (@TypeOf(Spec.Help) != HelpData(Spec)) @compileError(std.fmt.comptimePrint(
                "Spec.Help of type {s} is not of type HelpData(Spec)",
                .{@typeName(@TypeOf(Spec.Help))},
            ));
            break :rt Spec.Help;
        } else .{};
        const Verb = if (@hasDecl(Spec, "Verb")) Spec.Verb else void;
        const GroupMatch: GroupMatchConfig(Spec) = if (@hasDecl(Spec, "GroupMatch")) Spec.GroupMatch else .{};
        const INDENT: [conf.indent]u8 = @splat(' ');

        pub fn usage() ?[]const u8 {
            return comptime rt: {
                const usageList = Help.usage orelse break :rt null;
                const usageTemplate = "Usage: ";

                var b = coll.ComptSb.initTup(.{ usageTemplate, usageList[0] });
                for (usageList[1..]) |item| b.appendAll(.{ "\n", usageTemplate, item });
                break :rt b.s;
            };
        }

        pub fn description() ?[]const u8 {
            return comptime rt: {
                const desc = Help.description orelse break :rt null;
                var byLine = std.mem.tokenizeScalar(u8, desc, '\n');

                var b = coll.ComptSb.initTup(.{
                    INDENT,
                    byLine.next() orelse unreachable,
                });
                while (byLine.next()) |line| b.appendAll(.{ "\n", INDENT, line });
                break :rt b.s;
            };
        }

        pub fn examples() ?[]const u8 {
            return comptime rt: {
                const exampleList = Help.examples orelse break :rt null;
                var b = coll.ComptSb.initTup(.{
                    "Examples:\n",
                    conf.headerDelimiter,
                    INDENT,
                    exampleList[0],
                });
                for (exampleList[1..]) |item| b.appendAll(.{ "\n", INDENT, item });
                break :rt b.s;
            };
        }

        pub fn columnSize(comptime fields: anytype) usize {
            return comptime rt: {
                var size: usize = 0;
                for (fields) |f| {
                    const len = switch (@TypeOf(f)) {
                        btType.EnumField, btType.StructField, btType.UnionField => f.name.len,
                        []const u8, []u8 => f.len,
                        else => @compileError("Unknow type to calculate displacement"),
                    };
                    size = @max(size, len);
                }
                break :rt size;
            };
        }

        pub fn columnDelimiter(comptime fields: anytype) usize {
            return comptime rt: {
                var disp: usize = columnSize(fields) -| 1;
                disp += conf.indent;
                disp = ((disp / conf.columnSpace) + 2) * conf.columnSpace;
                break :rt disp;
            };
        }

        pub fn verbShortDesc(comptime name: []const u8) ?[]const u8 {
            return comptime rt: {
                const T = std.meta.TagPayloadByName(Verb, name);
                if (!@hasDecl(T, "Help")) break :rt null;
                const THelp: HelpData(T) = T.Help;
                break :rt THelp.shortDescription;
            };
        }

        pub fn commands() ?[]const u8 {
            return comptime rt: {
                if (Verb == void) break :rt null;

                const enumFields = @typeInfo(@typeInfo(Verb).@"union".tag_type.?).@"enum".fields;
                if (enumFields.len == 0) break :rt null;

                const columDelim = columnDelimiter(enumFields);

                var b = coll.ComptSb.init("Commands:");
                if (GroupMatch.mandatoryVerb) b.append(" [Required]");

                b.appendAll(.{ "\n", conf.headerDelimiter });
                for (enumFields, 0..) |f, i| {
                    b.appendAll(.{ INDENT, f.name });

                    if (verbShortDesc(f.name)) |verbDesc| {
                        b.appendAll(.{
                            @as([columDelim - f.name.len]u8, @splat(' ')),
                            verbDesc,
                        });
                    }

                    if (i != enumFields.len - 1) b.append("\n");
                }
                break :rt b.s;
            };
        }

        pub fn formatType(comptime T: type) []const u8 {
            return comptime rt: {
                const tag = @typeName(T);
                var tokenizer: coll.ReverseTokenIterator(u8, .scalar) = .{
                    .buffer = tag,
                    .delimiter = '.',
                    .index = tag.len,
                };
                break :rt tokenizer.next().?;
            };
        }

        pub fn formatStruct(comptime T: type, comptime defaultValue: T) []const u8 {
            return comptime rv: {
                const fields = std.meta.fields(T);
                var b = coll.ComptSb.initTup(.{
                    if (conf.simpleTypes) "" else formatType(T),
                    "{ ",
                });
                var addComma = false;
                for (fields, 0..) |field, i| {
                    if (meta.isUndefined(field)) continue;

                    if (addComma) {
                        addComma = false;
                        b.append(", ");
                    }

                    b.appendAll(.{
                        if (conf.simpleTypes) "\"" else ".",
                        field.name,
                        if (conf.simpleTypes) "\"" else "",
                        if (conf.simpleTypes) ": " else " = ",
                        formatDefaultValue(field.type, @field(defaultValue, field.name)),
                    });

                    if (i < fields.len - 1) addComma = true;
                }
                b.append(" }");
                break :rv b.s;
            };
        }

        pub fn formatDefaultArray(comptime T: type, comptime arr: anytype, comptime defaultValue: T) []const u8 {
            return comptime rv: {
                if (arr.child == u8) {
                    break :rv std.fmt.comptimePrint("\"{s}\"", .{defaultValue});
                }

                var b = coll.ComptSb.init(if (conf.simpleTypes) "[" else "{");
                for (defaultValue, 0..) |value, i| {
                    b.append(formatDefaultValue(arr.child, value));
                    if (i < defaultValue.len - 1) {
                        b.append(", ");
                    }
                }
                b.append(if (conf.simpleTypes) "]" else "}");
                break :rv b.s;
            };
        }

        pub fn formatDefaultValue(comptime T: type, comptime defaultValue: T) []const u8 {
            return comptime switch (@typeInfo(T)) {
                .comptime_int, .int, .comptime_float, .float => std.fmt.comptimePrint(
                    "{d}",
                    .{defaultValue},
                ),
                .bool => std.fmt.comptimePrint("{any}", .{defaultValue}),
                .pointer => |ptr| rv: {
                    if (ptr.size == .one) @compileLog(std.fmt.comptimePrint(
                        "Unsupported ptr type {s}",
                        .{@typeName(T)},
                    ));

                    break :rv formatDefaultArray(T, ptr, defaultValue);
                },
                .array => |arr| formatDefaultArray(T, arr, defaultValue),
                .optional => |opt| if (defaultValue == null) "null" else formatDefaultValue(
                    opt.child,
                    defaultValue.?,
                ),
                .@"enum" => formatType(T) ++ "." ++ @tagName(defaultValue),
                .@"struct" => formatStruct(T, defaultValue),
                .@"union" => switch (defaultValue) {
                    inline else => |e| coll.ComptSb.initTup(.{
                        if (conf.simpleTypes) "" else formatType(T),
                        "{ ",
                        if (conf.simpleTypes) "" else ".",
                        if (conf.simpleTypes) "\"" else "",
                        @tagName(defaultValue),
                        if (conf.simpleTypes) "\"" else "",
                        if (conf.simpleTypes) ": " else " = ",
                        formatStruct(@TypeOf(e), e),
                        " }",
                    }).s,
                },
                else => @compileError(std.fmt.comptimePrint(
                    "Unsupported defaultHint for {s}",
                    .{@typeName(T)},
                )),
            };
        }

        pub fn shorthand(
            comptime shortFieldsOpt: ?[]const std.builtin.Type.StructField,
            comptime field: std.builtin.Type.StructField,
        ) ?[]const u8 {
            return comptime rt: {
                const shortFields = shortFieldsOpt orelse break :rt null;
                for (shortFields) |shortField| {
                    const tag = @tagName(
                        shortField.defaultValue() orelse @compileError(
                            "Short defined with no default value",
                        ),
                    );
                    if (std.mem.eql(u8, field.name, tag)) break :rt coll.ComptSb.initTup(.{ "-", shortField.name }).s;
                }
                break :rt null;
            };
        }

        pub fn simpleTypeTranslation(comptime T: type) []const u8 {
            return comptime rt: {
                var b = coll.ComptSb.init("");
                var Tt = T;
                rfd: switch (@typeInfo(Tt)) {
                    .int => b.append("int"),
                    .float => b.append("float"),
                    .array => |arr| {
                        Tt = arr.child;
                        if (Tt == u8) b.append("string") else {
                            b.appendAll(.{
                                "[",
                                std.fmt.comptimePrint("{d}", .{arr.len}),
                                "]",
                            });
                            continue :rfd @typeInfo(Tt);
                        }
                    },
                    .pointer => |ptr| {
                        Tt = ptr.child;
                        if (Tt == u8) b.append("string") else {
                            b.append("[]");
                            continue :rfd @typeInfo(Tt);
                        }
                    },
                    .optional => |opt| {
                        b.append("?");
                        Tt = opt.child;
                        continue :rfd @typeInfo(Tt);
                    },
                    .@"struct", .@"union", .@"enum" => b.append(formatType(Tt)),
                    else => b.append(@typeName(Tt)),
                }
                break :rt b.s;
            };
        }

        pub fn zigTypeTranslation(comptime T: type) []const u8 {
            return comptime rt: {
                var b = coll.ComptSb.init("");
                var Tt = T;
                rfd: switch (@typeInfo(Tt)) {
                    .pointer => |ptr| {
                        Tt = ptr.child;
                        b.append("[]");
                        continue :rfd @typeInfo(Tt);
                    },
                    .optional => |opt| {
                        b.append("?");
                        Tt = opt.child;
                        continue :rfd @typeInfo(Tt);
                    },
                    .@"struct", .@"union", .@"enum" => b.append(formatType(Tt)),
                    else => b.append(@typeName(Tt)),
                }
                break :rt b.s;
            };
        }

        pub fn translateType(comptime T: type) []const u8 {
            return comptime if (conf.simpleTypes) simpleTypeTranslation(T) else zigTypeTranslation(T);
        }

        pub fn typeHint(
            comptime field: std.builtin.Type.StructField,
        ) ?[]const u8 {
            return comptime rt: {
                const descriptions = Help.optionsDescription orelse break :rt null;
                for (descriptions) |desc| {
                    if (!std.mem.eql(u8, @tagName(desc.field), field.name)) continue;
                    if (!desc.typeHint and !desc.defaultHint) break :rt null;

                    var b = coll.ComptSb.init("(");
                    if (desc.typeHint) b.append(translateType(field.type));

                    if (desc.typeHint and desc.defaultHint and !meta.isUndefined(field)) {
                        b.append(" = ");
                    }

                    if (desc.defaultHint and !meta.isUndefined(field)) {
                        b.append(formatDefaultValue(field.type, field.defaultValue().?));
                    }
                    b.append(")");
                    break :rt b.s;
                }
                break :rt null;
            };
        }

        pub fn groupToArgsText(comptime name: []const u8, comptime group: anytype) ?[]const u8 {
            return comptime rt: {
                var b = coll.ComptSb.init("");
                for (group) |groupBlk| {
                    for (groupBlk, 0..) |item, idxSelf| {
                        if (std.mem.eql(u8, @tagName(item), name)) {
                            for (groupBlk, 0..) |toAdd, i| {
                                if (idxSelf == i) continue;
                                if (b.s.len > 0) b.append(", ");
                                b.appendAll(.{ "--", @tagName(toAdd) });
                            }
                            break;
                        }
                    }
                }
                break :rt if (b.s.len > 0) b.s else null;
            };
        }

        pub fn isRequired(comptime name: []const u8) bool {
            return comptime for (GroupMatch.required) |req| {
                if (std.mem.eql(u8, @tagName(req), name)) break true;
            } else false;
        }

        pub fn groupMatchInfo(comptime name: []const u8) ?[]const u8 {
            return comptime rt: {
                if (!@hasDecl(Spec, "GroupMatch")) break :rt null;

                var b = coll.ComptSb.init(if (isRequired(name)) "[Required]" else "");
                if (groupToArgsText(name, GroupMatch.mutuallyInclusive)) |inclText| b.appendAll(.{
                    if (b.s.len > 0) " " else "",
                    "[Requires: ",
                    inclText,
                    "]",
                });

                if (groupToArgsText(name, GroupMatch.mutuallyExclusive)) |exclText| b.appendAll(.{
                    if (b.s.len > 0) " " else "",
                    "[Excludes: ",
                    exclText,
                    "]",
                });

                break :rt b.s;
            };
        }

        pub fn options() ?[]const u8 {
            @setEvalBranchQuota(conf.backwardsBranchesQuote);
            return comptime rt: {
                const fields = std.meta.fields(Spec);
                if (fields.len == 0) break :rt null;
                const OptShortFields: ?[]const btType.StructField = if (@hasDecl(Spec, "Short")) std.meta.fields(@TypeOf(Spec.Short)) else null;

                const KV = struct { []const u8, usize };

                var optionPieces: [fields.len][]const u8 = undefined;
                for (fields, 0..) |field, i| {
                    var piece = coll.ComptSb.init("");
                    if (shorthand(OptShortFields, field)) |shand| piece.appendAll(.{ shand, ", " });

                    piece.appendAll(.{ "--", field.name });

                    if (typeHint(field)) |tpHint| piece.appendAll(.{ " ", tpHint });

                    optionPieces[i] = piece.s;
                }

                const optsSize = if (Help.optionsDescription) |descriptions| descriptions.len else 0;
                var optsIndxKv: [optsSize]KV = undefined;
                if (Help.optionsDescription) |descriptions| for (descriptions, 0..) |desc, i| {
                    optsIndxKv[i] = .{ @tagName(desc.field), i };
                };
                const optIdx = std.static_string_map.StaticStringMap(usize).initComptime(optsIndxKv);

                var b = coll.ComptSb.initTup(.{ "Options:\n", conf.headerDelimiter });
                const columDelim = columnDelimiter(optionPieces);
                const innerBlock: [conf.indent * 2]u8 = @splat(' ');

                for (fields, &optionPieces, 0..) |field, optionPiece, i| {
                    defer if (i < fields.len - 1) b.append("\n");
                    b.appendAll(.{ INDENT, optionPiece });
                    if (Help.optionsDescription == null) continue;

                    const optI = optIdx.get(field.name) orelse continue;
                    const desc = Help.optionsDescription.?[optI];

                    const displacement: []const u8 = if (conf.optionsBreakline) "\n" ++ innerBlock else &@as(
                        [columDelim - optionPiece.len]u8,
                        @splat(' '),
                    );

                    const rules = if (desc.groupMatchHint) groupMatchInfo(field.name) else null;

                    if (rules != null or desc.description != null) {
                        b.append(displacement);
                        if (rules) |vRules| b.append(vRules);
                        if (desc.description) |vDesc| b.appendAll(.{
                            if (rules != null) " " else "",
                            vDesc,
                        });
                    }

                    if (conf.optionsBreakline and i < fields.len - 1) b.append("\n");
                }
                break :rt b.s;
            };
        }

        pub fn positionals() ?[]const u8 {
            return comptime rt: {
                const posDec = Help.positionalsDescription orelse break :rt null;

                const PosT = if (@hasDecl(Spec, "Positionals")) Spec.Positionals else DefaultPosT;
                if (PosT.TupleT == void and PosT.ReminderT == void) break :rt null;

                var b = coll.ComptSb.initTup(.{ "Positionals:\n", conf.headerDelimiter });
                const innerBlock: [conf.indent]u8 = @splat(' ');

                var typesCount: usize = if (PosT.TupleT != void) std.meta.fields(PosT.TupleT).len else 0;
                typesCount += if (PosT.ReminderT != void) 1 else 0;

                var typePieces: [typesCount][]const u8 = undefined;
                var pieceIdx: usize = 0;
                if (PosT.TupleT != void) {
                    for (std.meta.fields(PosT.TupleT)) |field| {
                        typePieces[pieceIdx] = coll.ComptSb.initTup(.{
                            "<",
                            translateType(field.type),
                            ">",
                        }).s;
                        pieceIdx += 1;
                    }
                }
                if (PosT.ReminderT != void) {
                    typePieces[pieceIdx] = coll.ComptSb.initTup(.{
                        "<",
                        translateType(PosT.ReminderT),
                        ">",
                    }).s;
                }
                const columDelim = columnDelimiter(typePieces);

                if (PosT.TupleT != void) {
                    const fields = std.meta.fields(PosT.TupleT);
                    for (0..fields.len) |tupIdx| {
                        defer if (tupIdx < fields.len - 1) b.append("\n");

                        const tupItemDesc: ?[]const u8 = if (posDec.tuple) |tupDesc| rv: {
                            if (tupIdx >= tupDesc.len) break :rv null;
                            break :rv tupDesc[tupIdx];
                        } else null;

                        const typePiece = typePieces[tupIdx];

                        b.appendAll(.{
                            innerBlock,
                            typePiece,
                            &@as(
                                [columDelim - typePiece.len]u8,
                                @splat(' '),
                            ),
                            "[Required]",
                        });

                        if (tupItemDesc) |desc| b.appendAll(.{
                            " ",
                            desc,
                        });
                    }
                }

                if (PosT.ReminderT != void) {
                    if (PosT.TupleT != void) b.append("\n");
                    const rPiece = typePieces[typePieces.len - 1];
                    b.appendAll(.{
                        innerBlock,
                        rPiece,
                    });
                    if (posDec.reminder) |rDesc| b.appendAll(.{ &@as(
                        [columDelim - rPiece.len]u8,
                        @splat(' '),
                    ), rDesc });
                }

                break :rt b.s;
            };
        }

        pub fn help() []const u8 {
            @setEvalBranchQuota(conf.backwardsBranchesQuote);
            return comptime rt: {
                var b = coll.ComptSb.init("");
                const pieces: []const ?[]const u8 = &.{
                    usage(),
                    description(),
                    examples(),
                    positionals(),
                    commands(),
                    options(),
                    Help.footer,
                };
                var addLines = 0;
                for (pieces) |pieceOpt| {
                    const piece = pieceOpt orelse continue;

                    const breakline = coll.ComptSb.init("");
                    if (addLines > 0) breakline.append("\n\n");
                    b.appendAll(.{ breakline.s, piece });
                    addLines += 1;
                }
                if (addLines > 0) b.append("\n");
                break :rt b.s;
            };
        }

        pub fn helpForErr(ErrOf: type, E: ErrOf, comptime reason: []const u8) []const u8 {
            return switch (E) {
                inline else => |e| comptime rv: {
                    break :rv coll.ComptSb.initTup(.{
                        reason,
                        @errorName(e),
                        "\n\n",
                        help(),
                    }).s;
                },
            };
        }
    };
}

pub fn HelpData(T: type) type {
    return struct {
        const SpecEnum = meta.FieldEnum(T);
        usage: ?[]const []const u8 = null,
        description: ?[]const u8 = null,
        shortDescription: ?[]const u8 = null,
        positionalsDescription: ?PositionalDescription = null,
        examples: ?[]const []const u8 = null,
        optionsDescription: ?[]const FieldDesc = null,
        footer: ?[]const u8 = null,

        pub const PositionalDescription = struct {
            tuple: ?[]const []const u8 = null,
            reminder: ?[]const u8 = null,
        };

        pub const FieldDesc = struct {
            field: SpecEnum,
            description: ?[]const u8 = null,
            defaultHint: bool = true,
            typeHint: bool = true,
            groupMatchHint: bool = true,
        };
    };
}

pub fn enumValueHint(target: type) []const u8 {
    return comptime rv: {
        var b = coll.ComptSb.init("{ ");
        const fields = @typeInfo(target).@"enum".fields;
        for (fields, 0..) |field, i| {
            b.append(field.name);
            if (i + 1 < fields.len) b.append(", ");
        }
        b.append(" }");
        break :rv b.s;
    };
}

test "enumValueHint" {
    const Enu = enum {
        cat,
        dog,
    };
    try std.testing.expectEqualStrings("{ cat, dog }", enumValueHint(Enu));
}

test "format usage" {
    const t = std.testing;
    try t.expectEqual(null, HelpFmt(struct {}, .{}).usage());
    const Spec = struct {
        pub const Help: HelpData(@This()) = .{
            .usage = &.{
                "test [options] <url>",
                "test [options] <path>",
            },
        };
    };
    try t.expectEqualStrings(
        \\Usage: test [options] <url>
        \\Usage: test [options] <path>
    , HelpFmt(Spec, .{}).usage().?);
}

test "description" {
    const t = std.testing;
    try t.expectEqual(null, HelpFmt(struct {}, .{}).description());
    const Spec = struct {
        pub const Help: HelpData(@This()) = .{
            .description =
            \\I'm a cool description
            \\Look at me going
            ,
        };
    };
    try t.expectEqualStrings(
        \\  I'm a cool description
        \\  Look at me going
    , HelpFmt(Spec, .{}).description().?);
    try t.expectEqualStrings(
        \\    I'm a cool description
        \\    Look at me going
    , HelpFmt(Spec, .{ .indent = 4 }).description().?);
}

test "examples" {
    const t = std.testing;
    try t.expectEqual(null, HelpFmt(struct {}, .{}).examples());
    const Spec = struct {
        pub const Help: HelpData(@This()) = .{
            .examples = &.{
                "prog --help",
                "prog --verbose help --help",
            },
        };
    };
    try t.expectEqualStrings(
        \\Examples:
        \\
        \\    prog --help
        \\    prog --verbose help --help
    , HelpFmt(Spec, .{ .indent = 4 }).examples().?);
    try t.expectEqualStrings(
        \\Examples:
        \\  prog --help
        \\  prog --verbose help --help
    , HelpFmt(Spec, .{ .headerDelimiter = "" }).examples().?);
}

test "positionals" {
    const t = std.testing;
    try t.expectEqual(null, HelpFmt(struct {}, .{}).examples());
    const Spec = struct {
        pub const Positionals = PositionalOf(.{
            .TupleType = struct { i32, u32 },
        });

        pub const Help: HelpData(@This()) = .{
            .positionalsDescription = .{
                .tuple = &.{
                    "src number",
                },
                .reminder = "file paths",
            },
        };
    };
    try t.expectEqualStrings(
        \\Positionals:
        \\
        \\    <i32>               [Required] src number
        \\    <u32>               [Required]
        \\    <?[][]u8>           file paths
    , HelpFmt(Spec, .{ .indent = 4 }).positionals().?);
    try t.expectEqualStrings(
        \\Positionals:
        \\  <int>               [Required] src number
        \\  <int>               [Required]
        \\  <?[]string>         file paths
    , HelpFmt(Spec, .{ .headerDelimiter = "", .simpleTypes = true }).positionals().?);

    const SpecWithoutTup = struct {
        pub const Positionals = PositionalOf(.{});

        pub const Help: HelpData(@This()) = .{
            .positionalsDescription = .{
                .reminder = "file paths",
            },
        };
    };
    try t.expectEqualStrings(
        \\Positionals:
        \\
        \\    <?[][]u8>           file paths
    , HelpFmt(SpecWithoutTup, .{ .indent = 4 }).positionals().?);
    try t.expectEqualStrings(
        \\Positionals:
        \\  <?[]string>         file paths
    , HelpFmt(SpecWithoutTup, .{ .headerDelimiter = "", .simpleTypes = true }).positionals().?);

    const SpecWithoutRemind = struct {
        pub const Positionals = PositionalOf(.{
            .TupleType = struct { i32, u32 },
            .ReminderType = void,
        });

        pub const Help: HelpData(@This()) = .{
            .positionalsDescription = .{
                .tuple = &.{
                    "src number",
                },
            },
        };
    };
    try t.expectEqualStrings(
        \\Positionals:
        \\
        \\    <i32>           [Required] src number
        \\    <u32>           [Required]
    , HelpFmt(SpecWithoutRemind, .{ .indent = 4 }).positionals().?);
    try t.expectEqualStrings(
        \\Positionals:
        \\  <int>       [Required] src number
        \\  <int>       [Required]
    , HelpFmt(SpecWithoutRemind, .{ .headerDelimiter = "", .simpleTypes = true }).positionals().?);

    const SpecWithoutTupEmptyDesc = struct {
        pub const Positionals = PositionalOf(.{});

        pub const Help: HelpData(@This()) = .{
            .positionalsDescription = .{},
        };
    };
    try t.expectEqualStrings(
        \\Positionals:
        \\
        \\    <?[][]u8>
    , HelpFmt(SpecWithoutTupEmptyDesc, .{ .indent = 4 }).positionals().?);
    try t.expectEqualStrings(
        \\Positionals:
        \\  <?[]string>
    , HelpFmt(SpecWithoutTupEmptyDesc, .{ .headerDelimiter = "", .simpleTypes = true }).positionals().?);
}

test "commands" {
    const t = std.testing;
    try t.expectEqual(null, HelpFmt(struct {}, .{}).commands());
    try t.expectEqualStrings(
        \\Commands:
        \\  a
    , HelpFmt(struct {
        pub const A = struct {};
        pub const Verb = union(enum) { a: A };
    }, .{ .headerDelimiter = "" }).commands().?);
    const Spec = struct {
        pub const A = struct {
            pub const Help: HelpData(@This()) = .{
                .shortDescription =
                \\This happens to be a very very long description on how to use a very specific piece of software create by a very specific human being (sometimes human).
                ,
            };
        };
        pub const B = struct {
            pub const Help: HelpData(@This()) = .{
                .shortDescription = "Just a brief description of a sorts",
            };
        };
        pub const C = struct {
            pub const Help: HelpData(@This()) = .{
                .shortDescription = "A",
            };
        };
        pub const D = struct {
            pub const Help: HelpData(@This()) = .{
                .shortDescription = "grapefruit",
            };
        };
        pub const Verb = union(enum) {
            aVeryBigNameWithLotsOfLettersHereRightNow: A,
            nameForSomething: B,
            short: C,
            d: D,
        };
    };
    try t.expectEqualStrings(
        \\Commands:
        \\
        \\  aVeryBigNameWithLotsOfLettersHereRightNow       This happens to be a very very long description on how to use a very specific piece of software create by a very specific human being (sometimes human).
        \\  nameForSomething                                Just a brief description of a sorts
        \\  short                                           A
        \\  d                                               grapefruit
    , HelpFmt(Spec, .{}).commands().?);
}

test "options basic" {
    const t = std.testing;
    try t.expectEqual(null, HelpFmt(struct {}, .{}).options());

    try t.expectEqualStrings(
        \\Options:
        \\  --posX
    , HelpFmt(struct {
        posX: i32 = undefined,
    }, .{ .headerDelimiter = "" }).options().?);

    try t.expectEqualStrings(
        \\Options:
        \\
        \\  -x, --posX (i32)        position X
        \\  --posY (u17)            position Y
    , HelpFmt(struct {
        posX: i32 = undefined,
        posY: u17 = undefined,
        pub const Short = .{ .x = .posX };
        const HelpThis = HelpData(@This());
        pub const Help: HelpThis = .{
            .optionsDescription = &.{
                .{ .field = .posX, .description = "position X" },
                .{ .field = .posY, .description = "position Y" },
            },
        };
    }, .{}).options().?);
    try t.expectEqualStrings(
        \\Options:
        \\  -x, --posX (u1 = 0)
        \\    position X
    , HelpFmt(struct {
        posX: u1 = 0,
        pub const Short = .{ .x = .posX };
        const HelpThis = HelpData(@This());
        pub const Help: HelpThis = .{
            .optionsDescription = &.{
                .{ .field = .posX, .description = "position X" },
            },
        };
    }, .{ .headerDelimiter = "", .optionsBreakline = true }).options().?);
    try t.expectEqualStrings(
        \\Options:
        \\  --posX (usize)
    , HelpFmt(struct {
        posX: usize = 3,
        const HelpThis = HelpData(@This());
        pub const Help: HelpThis = .{
            .optionsDescription = &.{
                .{ .field = .posX, .defaultHint = false },
            },
        };
    }, .{ .headerDelimiter = "" }).options().?);
    try t.expectEqualStrings(
        \\Options:
        \\  --posX (-1.1)
    , HelpFmt(struct {
        posX: f32 = -1.1,
        const HelpThis = HelpData(@This());
        pub const Help: HelpThis = .{
            .optionsDescription = &.{
                .{ .field = .posX, .typeHint = false },
            },
        };
    }, .{ .headerDelimiter = "" }).options().?);
    try t.expectEqualStrings(
        \\Options:
        \\  --posX
    , HelpFmt(struct {
        posX: f32 = 1.1,
        const HelpThis = HelpData(@This());
        pub const Help: HelpThis = .{
            .optionsDescription = &.{
                .{ .field = .posX, .typeHint = false, .defaultHint = false },
            },
        };
    }, .{ .headerDelimiter = "" }).options().?);
}

test "options bool" {
    const t = std.testing;

    try t.expectEqualStrings(
        \\Options:
        \\  --b1 (bool)
        \\  --b2 (bool = false)
        \\  --b3 (?bool = null)
    , HelpFmt(struct {
        b1: bool = undefined,
        b2: bool = false,
        b3: ?bool = null,
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .b1 },
                .{ .field = .b2 },
                .{ .field = .b3 },
            },
        };
    }, .{ .headerDelimiter = "" }).options().?);

    try t.expectEqualStrings(
        \\Options:
        \\  --b1 (bool)
        \\  --b2 (bool = false)
        \\  --b3 (?bool = null)
    , HelpFmt(struct {
        b1: bool = undefined,
        b2: bool = false,
        b3: ?bool = null,
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .b1 },
                .{ .field = .b2 },
                .{ .field = .b3 },
            },
        };
    }, .{ .headerDelimiter = "", .simpleTypes = true }).options().?);
}

test "options ints" {
    const t = std.testing;

    try t.expectEqualStrings(
        \\Options:
        \\  --posX (i1)
        \\  --posY (i2 = -1)
        \\  --posZ (?i1 = null)
    , HelpFmt(struct {
        posX: i1 = undefined,
        posY: i2 = -1,
        posZ: ?i1 = null,
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .posX },
                .{ .field = .posY },
                .{ .field = .posZ },
            },
        };
    }, .{ .headerDelimiter = "" }).options().?);

    try t.expectEqualStrings(
        \\Options:
        \\  --posX (int)
        \\  --posZ (?int = null)
    , HelpFmt(struct {
        posX: i32 = undefined,
        posZ: ?i1 = null,
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .posX },
                .{ .field = .posZ },
            },
        };
    }, .{ .headerDelimiter = "", .simpleTypes = true }).options().?);
}

test "options floats" {
    const t = std.testing;
    try t.expectEqualStrings(
        \\Options:
        \\  --posX (f32)
        \\  --posY (f32 = -1.11)
        \\  --posZ (?f64 = 4.41)
    , HelpFmt(struct {
        posX: f32 = undefined,
        posY: f32 = -1.11,
        posZ: ?f64 = 4.41,
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .posX },
                .{ .field = .posY },
                .{ .field = .posZ },
            },
        };
    }, .{ .headerDelimiter = "" }).options().?);

    try t.expectEqualStrings(
        \\Options:
        \\  --posX (float)
        \\  --posZ (?float = null)
    , HelpFmt(struct {
        posX: f32 = undefined,
        posZ: ?f64 = null,
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .posX },
                .{ .field = .posZ },
            },
        };
    }, .{ .headerDelimiter = "", .simpleTypes = true }).options().?);
}

test "options string" {
    const t = std.testing;
    try t.expectEqualStrings(
        \\Options:
        \\  --nameA ([]u8)
        \\  --nameB ([]u8 = "name")
        \\  --nameC (?[]u8 = "name2")
        \\  --nameD (?[]u8 = null)
    , HelpFmt(struct {
        nameA: []const u8 = undefined,
        nameB: []const u8 = "name",
        nameC: ?[]u8 = @as([]u8, @ptrCast(@constCast("name2"))),
        nameD: ?[]const u8 = null,
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .nameA },
                .{ .field = .nameB },
                .{ .field = .nameC },
                .{ .field = .nameD },
            },
        };
    }, .{ .headerDelimiter = "" }).options().?);

    try t.expectEqualStrings(
        \\Options:
        \\  --nameA (string)
        \\  --nameB (string = "name")
        \\  --nameC (?string = "name2")
        \\  --nameD (?string = null)
    , HelpFmt(struct {
        nameA: []const u8 = undefined,
        nameB: []const u8 = "name",
        nameC: ?[]u8 = @as([]u8, @ptrCast(@constCast("name2"))),
        nameD: ?[]const u8 = null,
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .nameA },
                .{ .field = .nameB },
                .{ .field = .nameC },
                .{ .field = .nameD },
            },
        };
    }, .{ .headerDelimiter = "", .simpleTypes = true }).options().?);
}

test "options arrays" {
    const t = std.testing;
    try t.expectEqualStrings(
        \\Options:
        \\  --names ([][]u8 = {"name1", "name2"})
        \\  --nbers ([]usize = {1, 2, 3})
        \\  --floats ([]f32 = {1.1, 2.2, 3.3})
        \\  --ranges ([][]usize = {{1, 2}, {3, 4}})
        \\  --optNames (?[][]u8 = {"name1", "name2"})
        \\  --optNbers (?[]usize = {1, 2, 3})
        \\  --optFloats (?[]f32 = {1.1, 2.2, 3.3})
        \\  --optRanges (?[][]usize = {{1, 2}, {3, 4}})
        \\  --namesOpt ([]?[]u8 = {"name1", null})
        \\  --nbersOpt ([]?usize = {1, 2, null})
        \\  --floatsOpt ([]?f32 = {1.1, 2.2, null})
        \\  --rangesOpt ([]?[]usize = {{1, 2}, null})
        \\  --rangesNOpt ([][]?usize = {{1, 2}, {3, null}})
        \\  --arr ([2]u32 = {1, 2})
        \\  --arrStr ([5]u8 = "Hello")
    , HelpFmt(struct {
        names: []const []const u8 = &.{ "name1", "name2" },
        nbers: []const usize = &.{ 1, 2, 3 },
        floats: []const f32 = &.{ 1.1, 2.2, 3.3 },
        ranges: []const []const usize = &.{ &.{ 1, 2 }, &.{ 3, 4 } },
        optNames: ?[]const []const u8 = &.{ "name1", "name2" },
        optNbers: ?[]const usize = &.{ 1, 2, 3 },
        optFloats: ?[]const f32 = &.{ 1.1, 2.2, 3.3 },
        optRanges: ?[]const []const usize = &.{ &.{ 1, 2 }, &.{ 3, 4 } },
        namesOpt: []const ?[]const u8 = &.{ "name1", null },
        nbersOpt: []const ?usize = &.{ 1, 2, null },
        floatsOpt: []const ?f32 = &.{ 1.1, 2.2, null },
        rangesOpt: []const ?[]const usize = &.{ &.{ 1, 2 }, null },
        rangesNOpt: []const []const ?usize = &.{ &.{ 1, 2 }, &.{ 3, null } },
        arr: [2]u32 = .{ 1, 2 },
        arrStr: [5]u8 = "Hello".*,
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .names },
                .{ .field = .nbers },
                .{ .field = .floats },
                .{ .field = .ranges },
                .{ .field = .optNames },
                .{ .field = .optNbers },
                .{ .field = .optFloats },
                .{ .field = .optRanges },
                .{ .field = .namesOpt },
                .{ .field = .nbersOpt },
                .{ .field = .floatsOpt },
                .{ .field = .rangesOpt },
                .{ .field = .rangesNOpt },
                .{ .field = .arr },
                .{ .field = .arrStr },
            },
        };
    }, .{ .headerDelimiter = "" }).options().?);

    try t.expectEqualStrings(
        \\Options:
        \\  --names ([]string = ["name1", "name2"])
        \\  --nbers ([]int = [1, 2, 3])
        \\  --floats ([]float = [1.1, 2.2, 3.3])
        \\  --ranges ([][]int = [[1, 2], [3, 4]])
        \\  --optNames (?[]string = ["name1", "name2"])
        \\  --optNbers (?[]int = [1, 2, 3])
        \\  --optFloats (?[]float = [1.1, 2.2, 3.3])
        \\  --optRanges (?[][]int = [[1, 2], [3, 4]])
        \\  --namesOpt ([]?string = ["name1", null])
        \\  --nbersOpt ([]?int = [1, 2, null])
        \\  --floatsOpt ([]?float = [1.1, 2.2, null])
        \\  --rangesOpt ([]?[]int = [[1, 2], null])
        \\  --rangesNOpt ([][]?int = [[1, 2], [3, null]])
        \\  --arr ([2]int = [1, 2])
        \\  --arrStr (string = "Hello")
    , HelpFmt(struct {
        names: []const []const u8 = &.{ "name1", "name2" },
        nbers: []const usize = &.{ 1, 2, 3 },
        floats: []const f32 = &.{ 1.1, 2.2, 3.3 },
        ranges: []const []const usize = &.{ &.{ 1, 2 }, &.{ 3, 4 } },
        optNames: ?[]const []const u8 = &.{ "name1", "name2" },
        optNbers: ?[]const usize = &.{ 1, 2, 3 },
        optFloats: ?[]const f32 = &.{ 1.1, 2.2, 3.3 },
        optRanges: ?[]const []const usize = &.{ &.{ 1, 2 }, &.{ 3, 4 } },
        namesOpt: []const ?[]const u8 = &.{ "name1", null },
        nbersOpt: []const ?usize = &.{ 1, 2, null },
        floatsOpt: []const ?f32 = &.{ 1.1, 2.2, null },
        rangesOpt: []const ?[]const usize = &.{ &.{ 1, 2 }, null },
        rangesNOpt: []const []const ?usize = &.{ &.{ 1, 2 }, &.{ 3, null } },
        arr: [2]u32 = .{ 1, 2 },
        arrStr: [5]u8 = "Hello".*,
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .names },
                .{ .field = .nbers },
                .{ .field = .floats },
                .{ .field = .ranges },
                .{ .field = .optNames },
                .{ .field = .optNbers },
                .{ .field = .optFloats },
                .{ .field = .optRanges },
                .{ .field = .namesOpt },
                .{ .field = .nbersOpt },
                .{ .field = .floatsOpt },
                .{ .field = .rangesOpt },
                .{ .field = .rangesNOpt },
                .{ .field = .arr },
                .{ .field = .arrStr },
            },
        };
    }, .{ .headerDelimiter = "", .simpleTypes = true }).options().?);
}

test "options enum" {
    const t = std.testing;

    try t.expectEqualStrings(
        \\Options:
        \\  --enumA (E = E.A)
        \\  --enumB (E = E.B)
    , HelpFmt(struct {
        enumA: E = .A,
        enumB: E = .B,
        pub const E = enum { A, B, C };
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .enumA },
                .{ .field = .enumB },
            },
        };
    }, .{ .headerDelimiter = "" }).options().?);

    try t.expectEqualStrings(
        \\Options:
        \\  --enumA (E = E.A)
        \\  --enumB (E = E.B)
    , HelpFmt(struct {
        enumA: E = .A,
        enumB: E = .B,
        pub const E = enum { A, B, C };
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .enumA },
                .{ .field = .enumB },
            },
        };
    }, .{ .headerDelimiter = "", .simpleTypes = true }).options().?);
}

test "options union" {
    const t = std.testing;

    try t.expectEqualStrings(
        \\Options:
        \\  --unionA (U = U{ .a = A{ .x = -1, .name = "name", .z = null, .arr = {"asdas", null} } })
        \\  --unionB (U = U{ .b = B{ .y = 2 } })
    , HelpFmt(struct {
        unionA: U = .{ .a = .{ .x = -1 } },
        unionB: U = .{ .b = .{ .y = 2 } },
        pub const A = struct {
            x: i32,
            name: []const u8 = "name",
            z: ?usize = null,
            arr: ?[]const ?[]const u8 = &.{
                "asdas",
                null,
            },
        };
        pub const B = struct {
            y: i32,
        };
        pub const U = union(enum) {
            a: A,
            b: B,
        };
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .unionA },
                .{ .field = .unionB },
            },
        };
    }, .{ .headerDelimiter = "" }).options().?);

    try t.expectEqualStrings(
        \\Options:
        \\  --unionA (U = { "a": { "x": -1, "name": "name", "z": null, "arr": ["asdas", null] } })
        \\  --unionB (U = { "b": { "y": 2 } })
    , HelpFmt(struct {
        unionA: U = .{ .a = .{ .x = -1 } },
        unionB: U = .{ .b = .{ .y = 2 } },
        pub const A = struct {
            x: i32,
            name: []const u8 = "name",
            z: ?usize = null,
            arr: ?[]const ?[]const u8 = &.{
                "asdas",
                null,
            },
        };
        pub const B = struct {
            y: i32,
        };
        pub const U = union(enum) {
            a: A,
            b: B,
        };
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .unionA },
                .{ .field = .unionB },
            },
        };
    }, .{ .headerDelimiter = "", .simpleTypes = true }).options().?);
}

test "options struct" {
    const t = std.testing;

    try t.expectEqualStrings(
        \\Options:
        \\  --struct1 (A = A{ .x = 1, .y = "name", .z = null, .w = {"asdas", null}, .a = U{ .aa = Opt1{  } } })
        \\  --struct2 (A = A{ .x = -1, .y = "name", .z = null, .w = {"asdas", null}, .a = U{ .bb = Opt2{  } } })
    , HelpFmt(struct {
        struct1: A = .{ .x = 1, .a = .{ .aa = .{} } },
        struct2: A = .{ .x = -1, .a = .{ .bb = .{} } },
        pub const A = struct {
            x: i32,
            y: []const u8 = "name",
            z: ?usize = null,
            w: ?[]const ?[]const u8 = &.{
                "asdas",
                null,
            },
            a: U,
            pub const U = union(enum) {
                aa: Opt1,
                bb: Opt2,
            };
            pub const Opt1 = struct {};
            pub const Opt2 = struct {};
        };
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .struct1 },
                .{ .field = .struct2 },
            },
        };
    }, .{ .headerDelimiter = "" }).options().?);

    try t.expectEqualStrings(
        \\Options:
        \\  --struct1 (A = { "x": 1, "y": "name", "z": null, "w": ["asdas", null], "a": { "aa": {  } } })
        \\  --struct2 (A = { "x": -1, "y": "name", "z": null, "w": ["asdas", null], "a": { "bb": {  } } })
    , HelpFmt(struct {
        struct1: A = .{ .x = 1, .a = .{ .aa = .{} } },
        struct2: A = .{ .x = -1, .a = .{ .bb = .{} } },
        pub const A = struct {
            x: i32,
            y: []const u8 = "name",
            z: ?usize = null,
            w: ?[]const ?[]const u8 = &.{
                "asdas",
                null,
            },
            a: U,
            pub const U = union(enum) {
                aa: Opt1,
                bb: Opt2,
            };
            pub const Opt1 = struct {};
            pub const Opt2 = struct {};
        };
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .struct1 },
                .{ .field = .struct2 },
            },
        };
    }, .{ .headerDelimiter = "", .simpleTypes = true }).options().?);
}

test "groupmatch info" {
    const t = std.testing;

    try t.expectEqualStrings(
        \\Options:
        \\  --n1
        \\    [Required]
        \\
        \\  --n2
        \\    [Required]
        \\
        \\  --a1
        \\    [Required] [Requires: --a2, --a6, --a3, --a7] [Excludes: --a5, --a8]
        \\
        \\  --a2
        \\    [Requires: --a1, --a6]
        \\
        \\  --a3
        \\    [Requires: --a1, --a7]
        \\
        \\  --a4
        \\    [Requires: --a5, --a8]
        \\
        \\  --a5
        \\    [Requires: --a4, --a8] [Excludes: --a1, --a8]
        \\
        \\  --a6
        \\    [Requires: --a1, --a2]
        \\
        \\  --a7
        \\    [Requires: --a1, --a3]
        \\
        \\  --a8
        \\    [Requires: --a4, --a5] [Excludes: --a1, --a5]
        \\
        \\  --b1
        \\    [Required] [Requires: --b5, --b8] [Excludes: --b2, --b6, --b3, --b7]
        \\
        \\  --b2
        \\    [Excludes: --b1, --b6]
        \\
        \\  --b3
        \\    [Excludes: --b1, --b7]
        \\
        \\  --b4
        \\    [Excludes: --b5, --b8]
        \\
        \\  --b5
        \\    [Requires: --b1, --b8] [Excludes: --b4, --b8]
        \\
        \\  --b6
        \\    [Excludes: --b1, --b2]
        \\
        \\  --b7
        \\    [Excludes: --b1, --b3]
        \\
        \\  --b8
        \\    [Requires: --b1, --b5] [Excludes: --b4, --b5]
    , HelpFmt(struct {
        n1: u32 = undefined,
        n2: u32 = undefined,
        a1: u32 = undefined,
        a2: u32 = undefined,
        a3: u32 = undefined,
        a4: u32 = undefined,
        a5: u32 = undefined,
        a6: u32 = undefined,
        a7: u32 = undefined,
        a8: u32 = undefined,
        b1: u32 = undefined,
        b2: u32 = undefined,
        b3: u32 = undefined,
        b4: u32 = undefined,
        b5: u32 = undefined,
        b6: u32 = undefined,
        b7: u32 = undefined,
        b8: u32 = undefined,
        pub const GroupMatch: GroupMatchConfig(@This()) = .{
            .mutuallyInclusive = &.{
                &.{ .a1, .a2, .a6 },
                &.{ .a1, .a3, .a7 },
                &.{ .a4, .a5, .a8 },
                &.{ .b1, .b5, .b8 },
            },
            .mutuallyExclusive = &.{
                &.{ .a1, .a5, .a8 },
                &.{ .b1, .b2, .b6 },
                &.{ .b1, .b3, .b7 },
                &.{ .b4, .b5, .b8 },
            },
            .required = &.{ .n1, .n2, .a1, .b1 },
        };
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .n1, .typeHint = false, .defaultHint = false },
                .{ .field = .n2, .typeHint = false, .defaultHint = false },
                .{ .field = .a1, .typeHint = false, .defaultHint = false },
                .{ .field = .a2, .typeHint = false, .defaultHint = false },
                .{ .field = .a3, .typeHint = false, .defaultHint = false },
                .{ .field = .a4, .typeHint = false, .defaultHint = false },
                .{ .field = .a5, .typeHint = false, .defaultHint = false },
                .{ .field = .a6, .typeHint = false, .defaultHint = false },
                .{ .field = .a7, .typeHint = false, .defaultHint = false },
                .{ .field = .a8, .typeHint = false, .defaultHint = false },
                .{ .field = .b1, .typeHint = false, .defaultHint = false },
                .{ .field = .b2, .typeHint = false, .defaultHint = false },
                .{ .field = .b3, .typeHint = false, .defaultHint = false },
                .{ .field = .b4, .typeHint = false, .defaultHint = false },
                .{ .field = .b5, .typeHint = false, .defaultHint = false },
                .{ .field = .b6, .typeHint = false, .defaultHint = false },
                .{ .field = .b7, .typeHint = false, .defaultHint = false },
                .{ .field = .b8, .typeHint = false, .defaultHint = false },
            },
        };
    }, .{ .headerDelimiter = "", .optionsBreakline = true }).options().?);

    try t.expectEqualStrings(
        \\Options:
        \\  --n1
        \\    [Required] n1 desc
        \\
        \\  --n2
    , HelpFmt(struct {
        n1: u32 = undefined,
        n2: u32 = undefined,
        pub const GroupMatch: GroupMatchConfig(@This()) = .{
            .required = &.{ .n1, .n2 },
        };
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .n1, .description = "n1 desc", .typeHint = false, .defaultHint = false },
                .{ .field = .n2, .groupMatchHint = false, .typeHint = false, .defaultHint = false },
            },
        };
    }, .{ .headerDelimiter = "", .optionsBreakline = true }).options().?);
}

test "help" {
    const t = std.testing;
    try t.expectEqualStrings("", HelpFmt(
        struct {},
        .{ .headerDelimiter = "" },
    ).help());

    try t.expectEqualStrings(
        \\Usage: test [options] [commands] ...
        \\
    , HelpFmt(struct {
        pub const Help: HelpData(@This()) = .{
            .usage = &.{"test [options] [commands] ..."},
        };
    }, .{ .headerDelimiter = "" }).help());

    try t.expectEqualStrings(
        \\  Some description about test
        \\
    , HelpFmt(struct {
        pub const Help: HelpData(@This()) = .{
            .description = "Some description about test",
        };
    }, .{ .headerDelimiter = "" }).help());

    try t.expectEqualStrings(
        \\Usage: test [options] [commands] ...
        \\
        \\  Some description about test
        \\
    , HelpFmt(struct {
        pub const Help: HelpData(@This()) = .{
            .usage = &.{"test [options] [commands] ..."},
            .description = "Some description about test",
        };
    }, .{ .headerDelimiter = "" }).help());

    try t.expectEqualStrings(
        \\Usage: test [options] [commands] ...
        \\
        \\  Some description about test
        \\
        \\Examples:
        \\
        \\  test --verbose match 1 1
        \\  test --verbose match 2 1
        \\
    , HelpFmt(struct {
        pub const Help: HelpData(@This()) = .{
            .usage = &.{"test [options] [commands] ..."},
            .description = "Some description about test",
            .examples = &.{
                "test --verbose match 1 1",
                "test --verbose match 2 1",
            },
        };
    }, .{}).help());

    try t.expectEqualStrings(
        \\Options:
        \\  --i1 (i32 = 0)      i1 desc
        \\
    , HelpFmt(struct {
        i1: i32 = 0,
        pub const Help: HelpData(@This()) = .{
            .optionsDescription = &.{
                .{ .field = .i1, .description = "i1 desc" },
            },
        };
    }, .{ .headerDelimiter = "" }).help());

    try t.expectEqualStrings(
        \\Usage: test [options] [commands] ...
        \\
        \\  Some description about test
        \\
        \\Examples:
        \\
        \\  test --verbose match 1 1
        \\  test --verbose match 2 1
        \\
        \\Options:
        \\
        \\  -i, --i1 (i32 = 0)      [Required] i1 desc
        \\
    , HelpFmt(struct {
        i1: i32 = 0,
        pub const Short = .{ .i = .i1 };
        pub const GroupMatch: GroupMatchConfig(@This()) = .{
            .required = &.{.i1},
        };
        pub const Help: HelpData(@This()) = .{
            .usage = &.{"test [options] [commands] ..."},
            .description = "Some description about test",
            .examples = &.{
                "test --verbose match 1 1",
                "test --verbose match 2 1",
            },
            .optionsDescription = &.{
                .{ .field = .i1, .description = "i1 desc" },
            },
        };
    }, .{}).help());

    try t.expectEqualStrings(
        \\Commands:
        \\  match       matches args
        \\  trace       trace-matches args
        \\
    , HelpFmt(struct {
        pub const Match = struct {
            pub const Help: HelpData(@This()) = .{
                .shortDescription = "matches args",
            };
        };
        pub const Trace = struct {
            pub const Help: HelpData(@This()) = .{
                .shortDescription = "trace-matches args",
            };
        };
        pub const Verb = union(enum) {
            match: Match,
            trace: Trace,
        };
    }, .{ .headerDelimiter = "" }).help());

    try t.expectEqualStrings(
        \\Usage: test [options] [commands] ...
        \\
        \\  Some description about test
        \\
        \\Examples:
        \\
        \\  test --verbose match 1 1
        \\  test --verbose match 2 1
        \\
        \\Commands: [Required]
        \\
        \\  match       matches args
        \\  trace       trace-matches args
        \\
    , HelpFmt(struct {
        pub const Match = struct {
            pub const Help: HelpData(@This()) = .{
                .shortDescription = "matches args",
            };
        };
        pub const Trace = struct {
            pub const Help: HelpData(@This()) = .{
                .shortDescription = "trace-matches args",
            };
        };
        pub const Verb = union(enum) {
            match: Match,
            trace: Trace,
        };
        pub const Short = .{ .i = .i1 };
        pub const GroupMatch: GroupMatchConfig(@This()) = .{
            .mandatoryVerb = true,
        };
        pub const Help: HelpData(@This()) = .{
            .usage = &.{"test [options] [commands] ..."},
            .description = "Some description about test",
            .examples = &.{
                "test --verbose match 1 1",
                "test --verbose match 2 1",
            },
        };
    }, .{}).help());

    try t.expectEqualStrings(
        \\Usage: test [options] [commands] ...
        \\
        \\  Some description about test
        \\
        \\Examples:
        \\
        \\  test --verbose match 1 1
        \\  test --verbose match 2 1
        \\
        \\Commands: [Required]
        \\
        \\  match       matches args
        \\  trace       trace-matches args
        \\
        \\Options:
        \\
        \\  -i, --i1 (i32 = 0)      [Required] i1 desc
        \\
    , HelpFmt(struct {
        i1: i32 = 0,
        pub const Match = struct {
            pub const Help: HelpData(@This()) = .{
                .shortDescription = "matches args",
            };
        };
        pub const Trace = struct {
            pub const Help: HelpData(@This()) = .{
                .shortDescription = "trace-matches args",
            };
        };
        pub const Verb = union(enum) {
            match: Match,
            trace: Trace,
        };
        pub const Short = .{ .i = .i1 };
        pub const GroupMatch: GroupMatchConfig(@This()) = .{
            .mandatoryVerb = true,
            .required = &.{.i1},
        };
        pub const Help: HelpData(@This()) = .{
            .usage = &.{"test [options] [commands] ..."},
            .description = "Some description about test",
            .examples = &.{
                "test --verbose match 1 1",
                "test --verbose match 2 1",
            },
            .optionsDescription = &.{
                .{ .field = .i1, .description = "i1 desc" },
            },
        };
    }, .{}).help());

    try t.expectEqualStrings(
        \\This is a footer, it gets added as typed
        \\
    , HelpFmt(struct {
        pub const Help: HelpData(@This()) = .{
            .footer = "This is a footer, it gets added as typed",
        };
    }, .{ .headerDelimiter = "" }).help());

    try t.expectEqualStrings(
        \\Usage: test [options] [commands] ...
        \\
        \\  Some description about test
        \\
        \\Examples:
        \\
        \\  test --verbose match 1 1
        \\  test --verbose match 2 1
        \\
        \\Commands: [Required]
        \\
        \\  match       matches args
        \\  trace       trace-matches args
        \\
        \\Options:
        \\
        \\  -i, --i1 (int = 0)      [Required] i1 desc
        \\
        \\This is a footer, it gets added as typed
        \\
    , HelpFmt(struct {
        i1: i32 = 0,
        pub const Match = struct {
            pub const Help: HelpData(@This()) = .{
                .shortDescription = "matches args",
            };
        };
        pub const Trace = struct {
            pub const Help: HelpData(@This()) = .{
                .shortDescription = "trace-matches args",
            };
        };
        pub const Verb = union(enum) {
            match: Match,
            trace: Trace,
        };
        pub const Short = .{ .i = .i1 };
        pub const GroupMatch: GroupMatchConfig(@This()) = .{
            .mandatoryVerb = true,
            .required = &.{.i1},
        };
        pub const Help: HelpData(@This()) = .{
            .usage = &.{"test [options] [commands] ..."},
            .description = "Some description about test",
            .examples = &.{
                "test --verbose match 1 1",
                "test --verbose match 2 1",
            },
            .optionsDescription = &.{
                .{ .field = .i1, .description = "i1 desc" },
            },
            .footer = "This is a footer, it gets added as typed",
        };
    }, .{ .simpleTypes = true }).help());

    try t.expectEqualStrings(
        \\Usage: test [options] [commands] ...
        \\
        \\  Some description about test
        \\
        \\Examples:
        \\
        \\  test --verbose match 1 1
        \\  test --verbose match 2 1
        \\
        \\Positionals:
        \\
        \\  <[2]int>            [Required] range
        \\  <string>            [Required] some string
        \\  <?[]string>         reminder
        \\
        \\Commands: [Required]
        \\
        \\  match       matches args
        \\  trace       trace-matches args
        \\
        \\Options:
        \\
        \\  -i, --i1 (int = 0)      [Required] i1 desc
        \\
        \\This is a footer, it gets added as typed
        \\
    , HelpFmt(struct {
        i1: i32 = 0,
        pub const Positionals = PositionalOf(.{
            .TupleType = struct { [2]i32, []const u8 },
        });
        pub const Match = struct {
            pub const Help: HelpData(@This()) = .{
                .shortDescription = "matches args",
            };
        };
        pub const Trace = struct {
            pub const Help: HelpData(@This()) = .{
                .shortDescription = "trace-matches args",
            };
        };
        pub const Verb = union(enum) {
            match: Match,
            trace: Trace,
        };
        pub const Short = .{ .i = .i1 };
        pub const GroupMatch: GroupMatchConfig(@This()) = .{
            .mandatoryVerb = true,
            .required = &.{.i1},
        };
        pub const Help: HelpData(@This()) = .{
            .usage = &.{"test [options] [commands] ..."},
            .description = "Some description about test",
            .examples = &.{
                "test --verbose match 1 1",
                "test --verbose match 2 1",
            },
            .positionalsDescription = .{
                .tuple = &.{
                    "range",
                    "some string",
                },
                .reminder = "reminder",
            },
            .optionsDescription = &.{
                .{ .field = .i1, .description = "i1 desc" },
            },
            .footer = "This is a footer, it gets added as typed",
        };
    }, .{ .simpleTypes = true }).help());
}

test "helpForErr" {
    const t = std.testing;
    const Spec = struct {
        flag: bool,
    };

    try t.expectEqualStrings(
        \\Error: Test
        \\
        \\Options:
        \\
        \\  --flag
        \\
    , HelpFmt(Spec, .{}).helpForErr(error{Test}, error{Test}.Test, "Error: "));
}
