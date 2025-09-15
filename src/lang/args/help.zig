const std = @import("std");
const GroupMatchConfig = @import("validate.zig").GroupMatchConfig;

pub const HelpConf = struct {
    spacesPerBlock: u4 = 2,
    blockDelimiter: []const u8 = "\n",
    descSpaces: u4 = 4,
    nDescSpaces: u2 = 2,
    simpleTypes: bool = false,
    optionsBreakline: bool = false,
    groupMatchHint: bool = true,
};

// TODO: add GroupMatch checks for help
pub fn HelpFmt(Spec: type, conf: HelpConf) type {
    return struct {
        const Visitor = struct {
            visited: []const type,
        };

        pub fn verbPath(comptime program: []const u8, comptime T: type) []const u8 {
            return comptime rt: {
                if (T == Spec) break :rt program;
                var visited: Visitor = .{
                    .visited = &.{Spec},
                };

                break :rt program ++ " " ++ (verbCallInner(
                    Spec,
                    T,
                    &visited,
                ) orelse @compileError("Not found"));
            };
        }

        fn verbCallInner(
            comptime T: type,
            comptime Target: type,
            comptime visitor: *Visitor,
        ) ?[]const u8 {
            if (@hasDecl(T, "Verb")) {
                outer: for (@typeInfo(T.Verb).@"union".fields) |f| {
                    for (visitor.visited) |v| if (f.type == v) continue :outer;
                    if (f.type == Target) return @as([]const u8, f.name);
                    visitor.visited = .{f.type} ++ visitor.visited;
                    const found = verbCallInner(
                        f.type,
                        Target,
                        visitor,
                    );
                    if (found) |path| {
                        return f.name ++ " " ++ path;
                    }
                }
            }
            return null;
        }

        pub fn usage() []const u8 {
            return comptime rt: {
                if (Spec.Help.usage.len == 0) break :rt "";
                const args = Spec.Help.usage;
                const usageTemplate = "Usage: ";
                var usageText: []const u8 = usageTemplate ++ args[0];
                for (args[1..]) |case| {
                    usageText = usageText ++ "\n" ++ usageTemplate ++ case;
                }
                const final = usageText;
                break :rt final;
            };
        }

        pub fn description() []const u8 {
            return comptime rt: {
                if (Spec.Help.description.len == 0) break :rt "";
                var byLine = std.mem.tokenizeScalar(u8, Spec.Help.description, '\n');

                const block: [conf.spacesPerBlock]u8 = @splat(' ');
                var desc: []const u8 = block ++ (byLine.next() orelse unreachable);
                while (byLine.next()) |line| {
                    desc = desc ++ "\n" ++ block ++ line;
                }
                const final = desc;
                break :rt final;
            };
        }

        pub fn examples() []const u8 {
            return comptime rt: {
                if (Spec.Help.examples.len == 0) break :rt "";
                const args = Spec.Help.examples;
                const block: [conf.spacesPerBlock]u8 = @splat(' ');
                var examplesText: []const u8 = "Examples:\n" ++ conf.blockDelimiter ++ block ++ args[0];
                for (args[1..]) |case| {
                    examplesText = examplesText ++ "\n" ++ block ++ case;
                }
                const final = examplesText;
                break :rt final;
            };
        }

        pub fn maxChars(fields: anytype) usize {
            var disp: usize = 0;
            for (fields) |f| {
                const len = switch (@TypeOf(f)) {
                    std.builtin.Type.EnumField, std.builtin.Type.StructField, std.builtin.Type.UnionField => f.name.len,
                    []const u8, []u8 => f.len,
                    else => @compileError("Unknow type to calculate displacement"),
                };
                disp = @max(disp, len);
            }
            return disp;
        }

        pub fn displacement(fields: anytype) usize {
            var disp: usize = maxChars(fields) - 1;
            disp += conf.spacesPerBlock;
            disp = ((disp / conf.descSpaces) + conf.nDescSpaces) * conf.descSpaces;
            return disp;
        }

        pub fn commands() []const u8 {
            return comptime rt: {
                if (!@hasDecl(Spec, "Verb")) break :rt "";

                const enumFields = @typeInfo(@typeInfo(Spec.Verb).@"union".tag_type.?).@"enum".fields;
                if (enumFields.len == 0) break :rt "";

                const block: [conf.spacesPerBlock]u8 = @splat(' ');
                const disp = displacement(enumFields);

                var commandText: []const u8 = "Commands:";
                if (@hasDecl(Spec, "GroupMatch") and Spec.GroupMatch.mandatoryVerb) {
                    commandText = commandText ++ " [Required]";
                }
                commandText = commandText ++ "\n" ++ conf.blockDelimiter;
                for (enumFields, 0..) |f, i| {
                    const desc = std.meta.TagPayloadByName(Spec.Verb, f.name).Help.shortDescription;
                    const displacementDelta = disp - f.name.len;
                    const displacementText: [displacementDelta]u8 = @splat(' ');
                    commandText = commandText ++ block ++ f.name ++ displacementText ++ desc;
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
            shortFields: []const std.builtin.Type.StructField,
            field: std.builtin.Type.StructField,
        ) ?[]const u8 {
            for (shortFields) |shortField| {
                if (std.mem.eql(u8, field.name, @tagName(shortField.defaultValue() orelse @compileError("Short defined with no default value")))) {
                    return "-" ++ shortField.name;
                }
            }
            return null;
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
            field: std.builtin.Type.StructField,
        ) ?[]const u8 {
            for (Spec.Help.optionsDescription) |desc| {
                if (std.mem.eql(u8, desc.field, field.name)) {
                    if (!desc.typeHint and !desc.defaultHint) return null;

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
                    return hint ++ ")";
                }
            }
            return null;
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

        pub fn options() []const u8 {
            return comptime rt: {
                const fields = std.meta.fields(Spec);
                if (fields.len == 0) break :rt "";
                const ShortFields = std.meta.fields(@TypeOf(Spec.Short));

                const block: [conf.spacesPerBlock]u8 = @splat(' ');
                var lines: [fields.len][]const u8 = undefined;
                for (fields, 0..) |field, i| {
                    var line: []const u8 = "";
                    if (shorthand(ShortFields, field)) |shand| {
                        line = line ++ shand ++ ", ";
                    }
                    line = line ++ "--" ++ field.name;

                    if (typeHint(field)) |tpHint| {
                        line = line ++ " " ++ tpHint;
                    }
                    lines[i] = line;
                }

                var optionsText: []const u8 = "Options:\n" ++ conf.blockDelimiter;
                const disp = displacement(lines);
                for (fields, &lines, 0..) |field, line, i| {
                    for (Spec.Help.optionsDescription) |desc| {
                        if (std.mem.eql(u8, desc.field, field.name)) {
                            const displacementText: []const u8 = if (conf.optionsBreakline) rv: {
                                const innerBlock: [conf.spacesPerBlock * 2]u8 = @splat(' ');
                                break :rv "\n" ++ innerBlock;
                            } else rv: {
                                const displacementDelta = disp - line.len;
                                const displacementText: [displacementDelta]u8 = @splat(' ');
                                break :rv &displacementText;
                            };

                            const rules = groupMatchInfo(field.name);
                            optionsText = optionsText ++ block ++ line ++ displacementText ++ rules ++ desc.description;
                            if (conf.optionsBreakline) {
                                optionsText = optionsText ++ "\n";
                            }
                            break;
                        }
                    }
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
                    usage(),
                    description(),
                    examples(),
                    commands(),
                    options(),
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
        usage: []const []const u8 = &.{},
        description: []const u8 = &.{},
        shortDescription: []const u8 = &.{},
        examples: []const []const u8 = &.{},
        optionsDescription: []const FieldDesc = &.{},
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
    const Spec = struct {
        pub const Help: HelpData(@This()) = .{
            .usage = &.{
                "test [options] <url>",
                "test [options] <path>",
            },
        };
    };
    try t.expectEqualStrings("", HelpFmt(struct {
        pub const Help: HelpData(@This()) = .{};
    }, .{}).usage());
    try t.expectEqualStrings(
        \\Usage: test [options] <url>
        \\Usage: test [options] <path>
    , HelpFmt(Spec, .{}).usage());
}

test "verb path" {
    const t = std.testing;
    const Spec = struct {};
    try t.expectEqualStrings("prog", comptime HelpFmt(Spec, .{}).verbPath("prog", Spec));
    const Spec2 = struct {
        pub const Looper = @This();
        pub const A = struct {};
        pub const B = struct {};
        pub const C = struct {
            pub const CA = struct {};
            pub const CB = struct {
                pub const Verb = union(enum) {
                    c: Looper.C,
                };
            };
            pub const CC = struct {};
            pub const Verb = union(enum) {
                ca: CA,
                cb: CB,
                cc: CC,
            };
        };
        pub const D = struct {};
        pub const E = struct {};
        pub const Verb = union(enum) {
            a: A,
            b: B,
            c: C,
            d: D,
            e: E,
        };
    };
    try t.expectEqualStrings("prog e", comptime HelpFmt(Spec2, .{}).verbPath("prog", Spec2.E));
    try t.expectEqualStrings("prog c cc", comptime HelpFmt(Spec2, .{}).verbPath("prog", Spec2.C.CC));
}

test "description" {
    const t = std.testing;
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
    , HelpFmt(Spec, .{}).description());
    try t.expectEqualStrings(
        \\    I'm a cool description
        \\    Look at me going
    , HelpFmt(Spec, .{ .spacesPerBlock = 4 }).description());
}

test "examples" {
    const t = std.testing;
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
    , HelpFmt(Spec, .{ .spacesPerBlock = 4 }).examples());
    try t.expectEqualStrings(
        \\Examples:
        \\  prog --help
        \\  prog --verbose help --help
    , HelpFmt(Spec, .{ .blockDelimiter = "" }).examples());
}

test "commands" {
    const t = std.testing;
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
    , HelpFmt(Spec, .{}).commands());
    try t.expectEqualStrings(
        \\Commands:
        \\  aVeryBigNameWithLotsOfLettersHereRightNow       This happens to be a very very long description on how to use a very specific piece of software create by a very specific human being (sometimes human).
        \\  nameForSomething                                Just a brief description of a sorts
        \\  short                                           A
        \\  d                                               grapefruit
    , HelpFmt(Spec, .{ .blockDelimiter = "" }).commands());
}

test "options" {
    const t = std.testing;
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
    , HelpFmt(Spec, .{}).options());
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
    }).options());
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
