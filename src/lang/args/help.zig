const std = @import("std");
const GroupMatchConfig = @import("validate.zig").GroupMatchConfig;

pub const HelpConf = struct {
    indent: u4 = 2,
    blockDelimiter: []const u8 = "\n",
    descSpaces: u4 = 4,
    nDescSpaces: u2 = 2,
    simpleTypes: bool = false,
    optionsBreakline: bool = false,
    groupMatchHint: bool = true,
};

// TODO: add GroupMatch checks for help
pub fn HelpFmt(comptime Spec: type, comptime conf: HelpConf) type {
    return struct {
        const Help: HelpData(Spec) = if (@hasDecl(Spec, "Help")) rt: {
            if (@TypeOf(Spec.Help) != HelpData(Spec)) @compileError(std.fmt.comptimePrint("Spec.Help of type {s} is not of type HelpData(Spec)", .{@typeName(@TypeOf(Spec.Help))}));
            break :rt Spec.Help;
        } else .{};
        const Verb = if (@hasDecl(Spec, "Verb")) Spec.Verb else void;
        const HasShort = if (@hasDecl(Spec, "Short")) true else false;
        const GroupMatch: GroupMatchConfig(Spec) = if (@hasDecl(Spec, "GroupMatch")) Spec.GroupMatch else .{};
        const INDENT: [conf.indent]u8 = @splat(' ');

        const Visitor = struct {
            visited: []const type,
        };

        pub fn usage() ?[]const u8 {
            return comptime rt: {
                const usageList = Help.usage orelse break :rt null;
                const usageTemplate = "Usage: ";
                var usageText: []const u8 = usageTemplate ++ usageList[0];
                for (usageList[1..]) |item| {
                    usageText = usageText ++ "\n" ++ usageTemplate ++ item;
                }
                const final = usageText;
                break :rt final;
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
                const final = descText;
                break :rt final;
            };
        }

        pub fn examples() ?[]const u8 {
            return comptime rt: {
                const exampleList = Help.examples orelse break :rt null;
                var examplesText: []const u8 = "Examples:\n" ++ conf.blockDelimiter ++ INDENT ++ exampleList[0];
                for (exampleList[1..]) |item| {
                    examplesText = examplesText ++ "\n" ++ INDENT ++ item;
                }
                const final = examplesText;
                break :rt final;
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

        pub fn displacement(comptime fields: anytype) usize {
            return comptime rt: {
                var disp: usize = columnSize(fields) -| 1;
                disp += conf.indent;
                disp = ((disp / conf.descSpaces) + conf.nDescSpaces) * conf.descSpaces;
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

                const disp = displacement(enumFields);

                var commandText: []const u8 = "Commands:";
                if (GroupMatch.mandatoryVerb) {
                    commandText = commandText ++ " [Required]";
                }
                commandText = commandText ++ "\n" ++ conf.blockDelimiter;
                for (enumFields, 0..) |f, i| {
                    commandText = commandText ++ INDENT ++ f.name;

                    if (verbShortDesc(f.name)) |verbDesc| {
                        const dispDelta = disp - f.name.len;
                        const displacementText: [dispDelta]u8 = @splat(' ');
                        commandText = commandText ++ displacementText ++ verbDesc;
                    }

                    if (i != enumFields.len - 1) {
                        commandText = commandText ++ "\n";
                    }
                }
                const final = commandText;
                break :rt final;
            };
        }

        pub fn formatDefaultValue(T: type, defaultValue: T) []const u8 {
            // TODO: format [][]u8 and so on
            const fmt = switch (T) {
                []const u8, []u8 => "'{s}'",
                ?[]const u8, ?[]u8 => if (defaultValue == null) "{?}" else "'{?s}'",
                else => "{any}",
            };

            return std.fmt.comptimePrint(fmt, .{defaultValue});
        }

        pub fn shorthand(
            comptime shortFields: []const std.builtin.Type.StructField,
            comptime field: std.builtin.Type.StructField,
        ) ?[]const u8 {
            return comptime rt: {
                for (shortFields) |shortField| {
                    if (std.mem.eql(u8, field.name, @tagName(shortField.defaultValue() orelse @compileError("Short defined with no default value")))) {
                        break :rt "-" ++ shortField.name;
                    }
                }
                break :rt null;
            };
        }

        pub fn simpleTypeTranslation(T: type) []const u8 {
            return comptime rt: {
                var typeText: []const u8 = "";
                var Tt = T;
                rfd: switch (@typeInfo(Tt)) {
                    .int => typeText = typeText ++ "int",
                    .float => typeText = typeText ++ "float",
                    .pointer => |ptr| {
                        Tt = ptr.child;
                        if (Tt == u8) {
                            typeText = typeText ++ "[]string";
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
                const final = typeText;
                break :rt final;
            };
        }

        pub fn zigTypeTranslation(T: type) []const u8 {
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
                    else => typeText = typeText ++ @typeName(Tt),
                }
                const final = typeText;
                break :rt final;
            };
        }

        pub fn translateType(T: type) []const u8 {
            return comptime if (conf.simpleTypes) simpleTypeTranslation(T) else zigTypeTranslation(T);
        }

        pub fn typeHint(
            comptime field: std.builtin.Type.StructField,
        ) ?[]const u8 {
            return comptime rt: {
                if (Help.optionsDescription == null) break :rt null;
                for (Help.optionsDescription.?) |desc| {
                    if (!std.mem.eql(u8, desc.field, field.name)) continue;

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
                const final = result;
                break :rt final;
            };
        }

        pub fn groupMatchInfo(comptime name: []const u8) []const u8 {
            return comptime rt: {
                if (!conf.groupMatchHint) break :rt "";
                if (!@hasDecl(Spec, "GroupMatch")) break :rt "";

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

                const final: []const u8 = rules;
                break :rt final;
            };
        }

        pub fn options() ?[]const u8 {
            return comptime rt: {
                const fields = std.meta.fields(Spec);
                if (fields.len == 0) break :rt null;
                const OptShortFields: ?[]const std.builtin.Type.StructField = if (HasShort) std.meta.fields(@TypeOf(Spec.Short)) else null;

                var lines: [fields.len][]const u8 = undefined;
                for (fields, 0..) |field, i| {
                    var line: []const u8 = "";
                    if (OptShortFields) |ShortFields| {
                        if (shorthand(ShortFields, field)) |shand| {
                            line = line ++ shand ++ ", ";
                        }
                    }
                    line = line ++ "--" ++ field.name;

                    if (typeHint(field)) |tpHint| {
                        line = line ++ " " ++ tpHint;
                    }
                    lines[i] = line;
                }

                var optionsText: []const u8 = "Options:\n" ++ conf.blockDelimiter;
                const disp = displacement(lines);
                const innerBlock: [conf.indent * 2]u8 = @splat(' ');
                for (fields, &lines, 0..) |field, line, i| {
                    optionsText = optionsText ++ INDENT ++ line;
                    if (Help.optionsDescription) |descriptions| for (
                        descriptions,
                    ) |desc| {
                        if (!std.mem.eql(u8, desc.field, field.name)) continue;

                        const displacementText: []const u8 = if (conf.optionsBreakline) rv: {
                            break :rv "\n" ++ innerBlock;
                        } else rv: {
                            const displacementDelta = disp - line.len;
                            const displacementText: [displacementDelta]u8 = @splat(' ');
                            break :rv &displacementText;
                        };

                        const rules = groupMatchInfo(field.name);
                        optionsText = optionsText ++ displacementText ++ rules ++ desc.description;
                        if (conf.optionsBreakline) {
                            optionsText = optionsText ++ "\n";
                        }
                        break;
                    };

                    if (i != fields.len - 1) {
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
                const pieces: []const []const u8 = &.{
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
    const SpecEnum = std.meta.FieldEnum(T);
    return struct {
        // TODO: use ?
        usage: ?[]const []const u8 = null,
        description: ?[]const u8 = null,
        shortDescription: ?[]const u8 = null,
        examples: ?[]const []const u8 = null,
        optionsDescription: ?[]const FieldDesc = null,
        footer: []const u8 = &.{},

        pub const FieldDesc = struct {
            field: []const u8,
            description: []const u8,
            defaultHint: bool = true,
            typeHint: bool = true,

            pub fn init(comptime field: SpecEnum, description: []const u8) @This() {
                return comptime .{
                    .field = @tagName(field),
                    .description = description,
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
    , HelpFmt(Spec, .{ .blockDelimiter = "" }).examples().?);
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
    }, .{ .blockDelimiter = "" }).commands().?);
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

test "options" {
    const t = std.testing;
    try t.expectEqual(null, HelpFmt(struct {}, .{}).options());
    try t.expectEqualStrings(
        \\Options:
        \\  --posX
    , HelpFmt(struct {
        posX: i32 = undefined,
    }, .{ .blockDelimiter = "" }).options().?);
    const Spec = struct {
        posX: ?i32 = null,
        posY: ?i32 = null,
        len: usize = 0,
        ranges: []const []const usize = &.{
            &.{ 0, 0 },
            &.{ 1, 1 },
            &.{ 2, 2 },
        },
        name: []const u8 = "placeholder",
        name2: ?[]const u8 = "placeholder",
        name3: ?[]const u8 = null,
        names: []const []const u8 = &.{
            "aname",
            "bname",
        },

        pub const Short = .{
            .x = .posX,
            .y = .posY,
            .l = .len,
            .rS = .ranges,
            .n = .name,
            .n2 = .name2,
        };

        const SpecHelpData = HelpData(@This());
        pub const Help: SpecHelpData = .{
            .optionsDescription = &.{ SpecHelpData.FieldDesc.init(
                .posX,
                "X position",
            ), SpecHelpData.FieldDesc.init(
                .posY,
                "Y position",
            ), SpecHelpData.FieldDesc.init(
                .len,
                "length of whatever this is",
            ), SpecHelpData.FieldDesc.init(
                .ranges,
                "range list",
            ), SpecHelpData.FieldDesc.init(
                .name,
                "a name",
            ), .{
                .field = @tagName(.name2),
                .description = "a pol of names",
                .typeHint = false,
                .defaultHint = false,
            }, .{
                .field = @tagName(.name3),
                .description = "a pol of names",
                .typeHint = false,
            }, .{
                .field = @tagName(.names),
                .description = "a pol of names",
                .defaultHint = false,
            } },
        };
    };
    try t.expectEqualStrings(
        \\Options:
        \\
        \\  -x, --posX (?i32 = null)                                            X position
        \\  -y, --posY (?i32 = null)                                            Y position
        \\  -l, --len (usize = 0)                                               length of whatever this is
        \\  -rS, --ranges ([][]usize = { { 0, 0 }, { 1, 1 }, { 2, 2 } })        range list
        \\  -n, --name ([]u8 = 'placeholder')                                   a name
        \\  -n2, --name2                                                        a pol of names
        \\  --name3 (null)                                                      a pol of names
        \\  --names ([][]u8)                                                    a pol of names
    , HelpFmt(Spec, .{}).options().?);
    try t.expectEqualStrings(
        \\Options:
        \\  -x, --posX (?i32 = null)
        \\    X position
        \\
        \\  -y, --posY (?i32 = null)
        \\    Y position
        \\
        \\  -l, --len (usize = 0)
        \\    length of whatever this is
        \\
        \\  -rS, --ranges ([][]usize = { { 0, 0 }, { 1, 1 }, { 2, 2 } })
        \\    range list
        \\
        \\  -n, --name ([]u8 = 'placeholder')
        \\    a name
        \\
        \\  -n2, --name2
        \\    a pol of names
        \\
        \\  --name3 (null)
        \\    a pol of names
        \\
        \\  --names ([][]u8)
        \\    a pol of names
        \\
    , HelpFmt(Spec, .{
        .blockDelimiter = "",
        .optionsBreakline = true,
    }).options().?);
}

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
            pub const Help: MatchHelp = .{ .usage = &.{"seeksub ... match"}, .description = "Matches based on options at the top-level. This performs no mutation or replacement, it's simply a dry-run.", .shortDescription = "Match-only operation. This is a dry-run with no replacement.", .optionsDescription = &.{
                MatchHelp.FieldDesc.init(.@"match-n", "N-match stop for each file if set."),
            } };
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
                    DiffHelp.FieldDesc.init(.replace, "Replace match on all files using this PCRE2 regex."),
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
                    ApplyHelp.FieldDesc.init(.replace, "Replace match on all files using this PCRE2 regex."),
                    ApplyHelp.FieldDesc.init(.trace, "Trace mutations"),
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
                SpecHelp.FieldDesc.init(.match, "PCRE2 Regex to match on all files."),
                SpecHelp.FieldDesc.init(.files, "File path list to run matches on."),
                SpecHelp.FieldDesc.init(
                    .byteRanges,
                    "Range of bytes for n files, top-level array length has to be of (len <= files.len) and will be applied sequentially over files.",
                ),
                SpecHelp.FieldDesc.init(.verbose, "Verbose mode."),
            },
        };

        pub const GroupMatch: GroupMatchConfig(@This()) = .{
            .required = &.{ .match, .files },
            .mandatoryVerb = true,
        };
    };
    std.debug.print("{s}", .{HelpFmt(Spec, .{ .simpleTypes = true, .optionsBreakline = true }).help()});
    std.debug.print("{s}", .{HelpFmt(Spec.Match, .{ .simpleTypes = true, .optionsBreakline = true }).help()});
    std.debug.print("{s}", .{HelpFmt(Spec.Diff, .{ .simpleTypes = true, .optionsBreakline = true }).help()});
    std.debug.print("{s}", .{HelpFmt(Spec.Apply, .{ .simpleTypes = true, .optionsBreakline = true }).help()});
    _ = t;
    // try t.expectEqualStrings("", HelpFmt(Spec, .{ .simpleTypes = true, .optionsBreakline = true }).help());
}
