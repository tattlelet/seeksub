const std = @import("std");
const GroupMatchConfig = @import("validate.zig").GroupMatchConfig;

pub const HelpConf = struct {
    indent: u4 = 2,
    headerDelimiter: []const u8 = "\n",
    columnSpace: u4 = 4,
    simpleTypes: bool = false,
    optionsBreakline: bool = false,
    groupMatchHint: bool = true,
};

// TODO: add GroupMatch checks for help
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
                var usageText: []const u8 = usageTemplate ++ usageList[0];
                for (usageList[1..]) |item| {
                    usageText = usageText ++ "\n" ++ usageTemplate ++ item;
                }
                break :rt usageText;
            };
        }

        pub fn description() ?[]const u8 {
            return comptime rt: {
                const desc = Help.description orelse break :rt null;
                var byLine = std.mem.tokenizeScalar(u8, desc, '\n');

                var descText: []const u8 = INDENT ++ (byLine.next() orelse unreachable);
                while (byLine.next()) |line| {
                    descText = descText ++ "\n" ++ INDENT ++ line;
                }
                break :rt descText;
            };
        }

        pub fn examples() ?[]const u8 {
            return comptime rt: {
                const exampleList = Help.examples orelse break :rt null;
                var examplesText: []const u8 = "Examples:\n" ++ conf.headerDelimiter ++ INDENT ++ exampleList[0];
                for (exampleList[1..]) |item| {
                    examplesText = examplesText ++ "\n" ++ INDENT ++ item;
                }
                break :rt examplesText;
            };
        }

        pub fn columnSize(comptime fields: anytype) usize {
            return comptime rt: {
                var size: usize = 0;
                for (fields) |f| {
                    const len = switch (@TypeOf(f)) {
                        std.builtin.Type.EnumField, std.builtin.Type.StructField, std.builtin.Type.UnionField => f.name.len,
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

        fn verbShortDesc(comptime name: []const u8) ?[]const u8 {
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

                var commandText: []const u8 = "Commands:";
                if (GroupMatch.mandatoryVerb) {
                    commandText = commandText ++ " [Required]";
                }
                commandText = commandText ++ "\n" ++ conf.headerDelimiter;
                for (enumFields, 0..) |f, i| {
                    commandText = commandText ++ INDENT ++ f.name;

                    if (verbShortDesc(f.name)) |verbDesc| {
                        const dispDelta = columDelim - f.name.len;
                        const displacementText: [dispDelta]u8 = @splat(' ');
                        commandText = commandText ++ displacementText ++ verbDesc;
                    }

                    if (i != enumFields.len - 1) {
                        commandText = commandText ++ "\n";
                    }
                }
                break :rt commandText;
            };
        }

        pub fn formatDefaultValue(comptime T: type, comptime defaultValue: T) []const u8 {
            return comptime switch (@typeInfo(T)) {
                .float => std.fmt.comptimePrint("{d}", .{defaultValue}),
                .pointer => |ptr| rv: {
                    if (ptr.child == u8) {
                        break :rv std.fmt.comptimePrint("'{s}'", .{defaultValue});
                    }
                    var valueText: []const u8 = if (conf.simpleTypes) "[" else "{";
                    for (defaultValue, 0..) |value, i| {
                        valueText = valueText ++ formatDefaultValue(ptr.child, value);
                        if (i < defaultValue.len - 1) {
                            valueText = valueText ++ ", ";
                        }
                    }
                    break :rv valueText ++ if (conf.simpleTypes) "]" else "}";
                },
                .optional => |opt| rv: {
                    if (defaultValue == null) break :rv "null" else {
                        break :rv formatDefaultValue(opt.child, defaultValue.?);
                    }
                },
                else => std.fmt.comptimePrint("{any}", .{defaultValue}),
            };
        }

        pub fn shorthand(
            comptime shortFieldsOpt: ?[]const std.builtin.Type.StructField,
            comptime field: std.builtin.Type.StructField,
        ) ?[]const u8 {
            return comptime rt: {
                const shortFields = shortFieldsOpt orelse break :rt null;
                for (shortFields) |shortField| {
                    if (std.mem.eql(u8, field.name, @tagName(shortField.defaultValue() orelse @compileError("Short defined with no default value")))) {
                        break :rt "-" ++ shortField.name;
                    }
                }
                break :rt null;
            };
        }

        pub fn simpleTypeTranslation(comptime T: type) []const u8 {
            return comptime rt: {
                var typeText: []const u8 = "";
                var Tt = T;
                rfd: switch (@typeInfo(Tt)) {
                    .int => typeText = typeText ++ "int",
                    .float => typeText = typeText ++ "float",
                    .pointer => |ptr| {
                        Tt = ptr.child;
                        if (Tt == u8) {
                            typeText = typeText ++ "string";
                        } else {
                            typeText = typeText ++ "[]";
                            continue :rfd @typeInfo(Tt);
                        }
                    },
                    .optional => |opt| {
                        // TODO: consider groupmatch before including ?
                        typeText = typeText ++ "?";
                        Tt = opt.child;
                        continue :rfd @typeInfo(Tt);
                    },
                    else => typeText = typeText ++ @typeName(Tt),
                }
                break :rt typeText;
            };
        }

        pub fn zigTypeTranslation(comptime T: type) []const u8 {
            return comptime rt: {
                var typeText: []const u8 = "";
                var Tt = T;
                rfd: switch (@typeInfo(Tt)) {
                    .pointer => |ptr| {
                        Tt = ptr.child;
                        typeText = typeText ++ "[]";
                        continue :rfd @typeInfo(Tt);
                    },
                    .optional => |opt| {
                        // TODO: consider groupmatch before including ?
                        typeText = typeText ++ "?";
                        Tt = opt.child;
                        continue :rfd @typeInfo(Tt);
                    },
                    // TODO: get only the last token for struct/complex type name translation
                    else => typeText = typeText ++ @typeName(Tt),
                }
                break :rt typeText;
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

                    var hint: []const u8 = "(";
                    if (desc.typeHint) {
                        hint = hint ++ translateType(field.type);
                    }

                    // NOTE: https://github.com/ziglang/zig/issues/18047#issuecomment-1818265581
                    // Apparently not IB but would keep an eye on this
                    const defaultAvailable = if (field.default_value_ptr) |ptr| ptr != @as(*const anyopaque, @ptrCast(&@as(field.type, undefined))) else false;

                    if (desc.typeHint and desc.defaultHint and defaultAvailable) {
                        hint = hint ++ " = ";
                    }

                    if (desc.defaultHint and defaultAvailable) {
                        hint = hint ++ formatDefaultValue(field.type, field.defaultValue().?);
                    }
                    break :rt hint ++ ")";
                }
                break :rt null;
            };
        }

        // TODO: test group match info
        // TODO: optional?
        fn groupInfo(comptime name: []const u8, T: type, group: T) T {
            return comptime rt: {
                var result: T = &.{};
                outer: for (group) |groupBlk| {
                    for (groupBlk) |item| {
                        if (std.mem.eql(u8, @tagName(item), name)) {
                            result = result ++ @as(T, &.{groupBlk});
                            continue :outer;
                        }
                    }
                }
                break :rt result;
            };
        }

        fn groupToArgsText(comptime name: []const u8, group: anytype) []const u8 {
            return comptime rt: {
                var result: []const u8 = "";
                for (group) |groupBlk| {
                    for (groupBlk) |item| {
                        if (std.mem.eql(u8, @tagName(item), name)) continue;
                        if (result.len != 0) {
                            result = result ++ ", ";
                        }
                        result = result ++ "--" ++ @tagName(item);
                    }
                }
                break :rt result;
            };
        }

        pub fn groupMatchInfo(comptime name: []const u8) ?[]const u8 {
            return comptime rt: {
                if (!conf.groupMatchHint) break :rt null;
                if (!@hasDecl(Spec, "GroupMatch")) break :rt null;

                var required = false;
                for (Spec.GroupMatch.required) |req| {
                    if (std.mem.eql(u8, @tagName(req), name)) {
                        required = true;
                        break;
                    }
                }

                const inclusive = groupInfo(name, @TypeOf(Spec.GroupMatch.mutuallyInclusive), Spec.GroupMatch.mutuallyInclusive);

                const exclusive = groupInfo(name, @TypeOf(Spec.GroupMatch.mutuallyExclusive), Spec.GroupMatch.mutuallyExclusive);

                var rules: []const u8 = "";
                if (required) {
                    rules = rules ++ "[Required] ";
                }

                if (inclusive.len > 0) {
                    const inclText: []const u8 = groupToArgsText(name, inclusive);
                    if (inclText.len > 0) {
                        rules = rules ++ "[Requires: " ++ inclText ++ "] ";
                    }
                }

                if (exclusive.len > 0) {
                    const exclText: []const u8 = groupToArgsText(name, exclusive);
                    if (exclText.len > 0) {
                        rules = rules ++ "[Excludes: " ++ exclText ++ "] ";
                    }
                }
                break :rt rules;
            };
        }

        pub fn options() ?[]const u8 {
            return comptime rt: {
                const fields = std.meta.fields(Spec);
                if (fields.len == 0) break :rt null;
                const OptShortFields: ?[]const std.builtin.Type.StructField = if (@hasDecl(Spec, "Short")) std.meta.fields(@TypeOf(Spec.Short)) else null;

                var optionPieces: [fields.len][]const u8 = undefined;
                for (fields, 0..) |field, i| {
                    var optionPiece: []const u8 = "";
                    if (shorthand(OptShortFields, field)) |shand| {
                        optionPiece = optionPiece ++ shand ++ ", ";
                    }

                    optionPiece = optionPiece ++ "--" ++ field.name;

                    if (typeHint(field)) |tpHint| {
                        optionPiece = optionPiece ++ " " ++ tpHint;
                    }
                    optionPieces[i] = optionPiece;
                }

                var optionsText: []const u8 = "Options:\n" ++ conf.headerDelimiter;
                const columDelim = columnDelimiter(optionPieces);
                const innerBlock: [conf.indent * 2]u8 = @splat(' ');

                for (fields, &optionPieces, 0..) |field, optionPiece, i| {
                    optionsText = optionsText ++ INDENT ++ optionPiece;
                    // TODO: build config on the fly for field based on config
                    // config will enable default typehint / default hint
                    // with not description
                    if (Help.optionsDescription) |descriptions| for (
                        descriptions,
                    ) |desc| {
                        if (!std.mem.eql(u8, @tagName(desc.field), field.name)) continue;

                        const displacementText: []const u8 = if (conf.optionsBreakline) rv: {
                            break :rv "\n" ++ innerBlock;
                        } else rv: {
                            const displacementDelta = columDelim - optionPiece.len;
                            const displacementText: [displacementDelta]u8 = @splat(' ');
                            break :rv &displacementText;
                        };

                        // TODO: work more here
                        const rules = groupMatchInfo(field.name);

                        if (rules != null or desc.description != null) {
                            optionsText = optionsText ++ displacementText;
                            if (rules) |vRules| {
                                optionsText = optionsText ++ vRules;
                            }
                            if (desc.description) |vDesc| {
                                optionsText = optionsText ++ vDesc;
                            }
                        }

                        if (conf.optionsBreakline and i < fields.len - 1) {
                            optionsText = optionsText ++ "\n";
                        }
                        break;
                    };

                    if (i < fields.len - 1) {
                        optionsText = optionsText ++ "\n";
                    }
                }
                const final = optionsText;
                break :rt final;
            };
        }

        pub fn help() []const u8 {
            return comptime rt: {
                var helpText: []const u8 = "";
                // TODO: add footer
                const pieces: []const []const u8 = &.{
                    // TODO: trickle down opts
                    usage().?,
                    description().?,
                    examples() orelse "",
                    commands() orelse "",
                    options() orelse "",
                };
                for (pieces, 0..) |piece, i| {
                    if (piece.len > 1) {
                        var breakline: []const u8 = "\n";
                        if (i < pieces.len - 1) {
                            breakline = breakline ++ "\n";
                        }
                        helpText = helpText ++ piece ++ breakline;
                    }
                }
                break :rt helpText;
            };
        }
    };
}

pub fn HelpData(T: type) type {
    return struct {
        const SpecEnum = std.meta.FieldEnum(T);
        usage: ?[]const []const u8 = null,
        description: ?[]const u8 = null,
        shortDescription: ?[]const u8 = null,
        examples: ?[]const []const u8 = null,
        optionsDescription: ?[]const FieldDesc = null,
        footer: ?[]const u8 = null,

        pub const FieldDesc = struct {
            field: SpecEnum,
            description: ?[]const u8 = null,
            defaultHint: bool = true,
            typeHint: bool = true,

            pub fn init(field: @Type(.enum_literal), description: ?[]const u8, defaultHint: bool, typeHint: bool) @This() {
                return .{
                    .field = field,
                    .description = description,
                    .defaultHint = defaultHint,
                    .typeHint = typeHint,
                };
            }
        };
    };
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
        \\  --posZ
    , HelpFmt(struct {
        posZ: i32 = undefined,
    }, .{ .headerDelimiter = "" }).options().?);

    try t.expectEqualStrings(
        \\Options:
        \\  -x, --posX (i32)        position Z
    , HelpFmt(struct {
        posX: i32 = undefined,
        pub const Short = .{ .x = .posX };
        const HelpThis = HelpData(@This());
        pub const Help: HelpThis = .{
            .optionsDescription = &.{
                // NOTE: getting weird issues with field enum recognition
                HelpThis.FieldDesc.init(.posX, "position Z", true, true),
            },
        };
    }, .{ .headerDelimiter = "" }).options().?);
    try t.expectEqualStrings(
        \\Options:
        \\  -x, --posX (i32 = 1)
        \\    position Z
    , HelpFmt(struct {
        posX: i32 = 1,
        pub const Short = .{ .x = .posX };
        const HelpThis = HelpData(@This());
        pub const Help: HelpThis = .{
            .optionsDescription = &.{
                // NOTE: getting weird issues with field enum recognition
                HelpThis.FieldDesc.init(.posX, "position Z", true, true),
            },
        };
    }, .{ .headerDelimiter = "", .optionsBreakline = true }).options().?);
    try t.expectEqualStrings(
        \\Options:
        \\  -x, --posX (i32)
    , HelpFmt(struct {
        posX: i32 = 1,
        pub const Short = .{ .x = .posX };
        const HelpThis = HelpData(@This());
        pub const Help: HelpThis = .{
            .optionsDescription = &.{
                // NOTE: getting weird issues with field enum recognition
                HelpThis.FieldDesc.init(.posX, null, false, true),
            },
        };
    }, .{ .headerDelimiter = "" }).options().?);
    try t.expectEqualStrings(
        \\Options:
        \\  -x, --posX (1)
    , HelpFmt(struct {
        posX: i32 = 1,
        pub const Short = .{ .x = .posX };
        const HelpThis = HelpData(@This());
        pub const Help: HelpThis = .{
            .optionsDescription = &.{
                // NOTE: getting weird issues with field enum recognition
                HelpThis.FieldDesc.init(.posX, null, true, false),
            },
        };
    }, .{ .headerDelimiter = "" }).options().?);
    try t.expectEqualStrings(
        \\Options:
        \\  -x, --posX
    , HelpFmt(struct {
        posX: i32 = 1,
        pub const Short = .{ .x = .posX };
        const HelpThis = HelpData(@This());
        pub const Help: HelpThis = .{
            .optionsDescription = &.{
                // NOTE: getting weird issues with field enum recognition
                HelpThis.FieldDesc.init(.posX, null, false, false),
            },
        };
    }, .{ .headerDelimiter = "" }).options().?);
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
        \\  --nameB ([]u8 = 'name')
        \\  --nameC (?[]u8 = 'name2')
        \\  --nameD (?[]u8 = null)
    , HelpFmt(struct {
        nameA: []const u8 = undefined,
        nameB: []const u8 = "name",
        nameC: ?[]u8 = @as([]u8, @constCast(@ptrCast("name2"))),
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
        \\  --nameB (string = 'name')
        \\  --nameC (?string = 'name2')
        \\  --nameD (?string = null)
    , HelpFmt(struct {
        nameA: []const u8 = undefined,
        nameB: []const u8 = "name",
        nameC: ?[]u8 = @as([]u8, @constCast(@ptrCast("name2"))),
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
        \\  --names ([][]u8 = {'name1', 'name2'})
        \\  --nbers ([]usize = {1, 2, 3})
        \\  --floats ([]f32 = {1.1, 2.2, 3.3})
        \\  --ranges ([][]usize = {{1, 2}, {3, 4}})
        \\  --optNames (?[][]u8 = {'name1', 'name2'})
        \\  --optNbers (?[]usize = {1, 2, 3})
        \\  --optFloats (?[]f32 = {1.1, 2.2, 3.3})
        \\  --optRanges (?[][]usize = {{1, 2}, {3, 4}})
        \\  --namesOpt ([]?[]u8 = {'name1', null})
        \\  --nbersOpt ([]?usize = {1, 2, null})
        \\  --floatsOpt ([]?f32 = {1.1, 2.2, null})
        \\  --rangesOpt ([]?[]usize = {{1, 2}, null})
        \\  --rangesNOpt ([][]?usize = {{1, 2}, {3, null}})
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
            },
        };
    }, .{ .headerDelimiter = "" }).options().?);

    try t.expectEqualStrings(
        \\Options:
        \\  --names ([]string = ['name1', 'name2'])
        \\  --nbers ([]int = [1, 2, 3])
        \\  --floats ([]float = [1.1, 2.2, 3.3])
        \\  --ranges ([][]int = [[1, 2], [3, 4]])
        \\  --optNames (?[]string = ['name1', 'name2'])
        \\  --optNbers (?[]int = [1, 2, 3])
        \\  --optFloats (?[]float = [1.1, 2.2, 3.3])
        \\  --optRanges (?[][]int = [[1, 2], [3, 4]])
        \\  --namesOpt ([]?string = ['name1', null])
        \\  --nbersOpt ([]?int = [1, 2, null])
        \\  --floatsOpt ([]?float = [1.1, 2.2, null])
        \\  --rangesOpt ([]?[]int = [[1, 2], null])
        \\  --rangesNOpt ([][]?int = [[1, 2], [3, null]])
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
            },
        };
    }, .{ .headerDelimiter = "", .simpleTypes = true }).options().?);
}

// TODO: test other types (enum, union, struct)
// TODO: test groupmatch
// TODO: wrap up helper test

test "help" {
    const t = std.testing;
    const Spec = struct {
        match: []const u8 = undefined,
        files: []const []const u8 = undefined,
        byteRanges: ?[]const []const usize = null,
        verbose: bool = false,

        pub const Match = struct {
            @"match-n": ?usize = null,

            pub const Short = .{
                .n = .@"match-n",
            };

            const MatchHelp = HelpData(@This());
            pub const Help: MatchHelp = .{
                .usage = &.{"seeksub ... match"},
                .description = "Matches based on options at the top-level. This performs no mutation or replacement, it's simply a dry-run.",
                .shortDescription = "Match-only operation. This is a dry-run with no replacement.",
                .optionsDescription = &.{MatchHelp.FieldDesc.init(.@"match-n", "N-match stop for each file if set.", true, true)},
            };
        };

        pub const Diff = struct {
            replace: []const u8 = undefined,

            pub const Short = .{
                .r = .replace,
            };

            const DiffHelp = HelpData(@This());
            pub const Help: DiffHelp = .{
                .usage = &.{"seeksub ... diff [options]"},
                .description = "Matches based on options at the top-level and then performs a replacement over matches, providing a diff return but not actually mutating the files.",
                .shortDescription = "Dry-runs replacement. No mutation is performed.",
                .optionsDescription = &.{
                    DiffHelp.FieldDesc.init(.replace, "Replace match on all files using this PCRE2 regex.", true, true),
                },
            };

            pub const GroupMatch: GroupMatchConfig(@This()) = .{
                .required = &.{.replace},
            };
        };

        pub const Apply = struct {
            replace: []const u8 = undefined,
            trace: bool = false,

            pub const Short = .{
                .r = .replace,
                .tt = .trace,
            };

            pub const ApplyHelp = HelpData(@This());
            pub const Help: ApplyHelp = .{
                .usage = &.{"seeksub ... apply [options]"},
                .description = "Matches based on options at the top-level and then performs a replacement over matches. This is mutate the files.",
                .shortDescription = "Replaces based on match and replace PCRE2 regexes over all files.",
                .optionsDescription = &.{
                    .{
                        .field = .replace,
                        .description = "Replace match on all files using this PCRE2 regex.",
                    },
                    .{ .field = .trace, .description = "Trace mutations" },
                },
            };

            pub const GroupMatch: GroupMatchConfig(@This()) = .{
                .required = &.{.replace},
            };
        };

        pub const Verb = union(enum) {
            match: Match,
            diff: Diff,
            apply: Apply,
        };

        pub const Short = .{
            .m = .match,
            .fL = .files,
            .bR = .byteRanges,
            .v = .verbose,
        };

        const SpecHelp = HelpData(@This());
        pub const Help: SpecHelp = .{
            .usage = &.{"seeksub [options] [command] ..."},
            .description = "CLI tool to match, diff and apply regex in bulk using PCRE2. One of the main features of this CLI is the ability to seek byte ranges before matching or replacing.",
            .optionsDescription = &.{
                .{
                    .field = .match,
                    .description = "PCRE2 Regex to match on all files.",
                },
                .{
                    .field = .files,
                    .description = "File path list to run matches on.",
                },
                .{
                    .field = .byteRanges,
                    .description = "Range of bytes for n files, top-level array length has to be of (len <= files.len) and will be applied sequentially over files.",
                },
                .{ .field = .verbose, .description = "Verbose mode." },
            },
        };

        pub const GroupMatch: GroupMatchConfig(@This()) = .{
            .required = &.{ .match, .files },
            .mandatoryVerb = true,
        };
    };
    std.debug.print("{s}\n", .{HelpFmt(Spec, .{ .simpleTypes = true, .optionsBreakline = true }).help()});
    std.debug.print("{s}\n", .{HelpFmt(Spec.Match, .{ .simpleTypes = true, .optionsBreakline = true }).help()});
    std.debug.print("{s}\n", .{HelpFmt(Spec.Diff, .{ .simpleTypes = true, .optionsBreakline = true }).help()});
    std.debug.print("{s}\n", .{HelpFmt(Spec.Apply, .{ .simpleTypes = true, .optionsBreakline = true }).help()});
    _ = t;
    // try t.expectEqualStrings("", HelpFmt(Spec, .{ .simpleTypes = true, .optionsBreakline = true }).help());
}
