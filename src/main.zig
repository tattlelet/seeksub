const std = @import("std");
const spec = @import("lang/args/spec.zig");
const help = @import("lang/args/help.zig");
const validate = @import("lang/args/validate.zig");
const coll = @import("lang/collections.zig");
const Cursor = coll.Cursor;
const ComptSb = coll.ComptSb;
const HelpData = help.HelpData;
const HelpFmt = help.HelpFmt;
const GroupMatchConfig = validate.GroupMatchConfig;
const SpecResponse = spec.SpecResponse;
const PositionalOf = spec.PositionalOf;

const Args = struct {
    match: []const u8 = undefined,
    byteRanges: ?[]const []const usize = null,
    verbose: bool = false,

    const Positional = PositionalOf(void, void, {});

    pub const Short = .{
        .m = .match,
        .fL = .files,
        .bR = .byteRanges,
        .v = .verbose,
    };

    pub const Verb = union(enum) {
        match: Match,
        diff: Diff,
        apply: Apply,
    };

    pub const GroupMatch: GroupMatchConfig(@This()) = .{
        .required = &.{.match},
        .mandatoryVerb = true,
    };

    pub const Help: HelpData(@This()) = .{
        .usage = &.{"seeksub [options] [command] ..."},
        .description = "CLI tool to match, diff and apply regex in bulk using PCRE2. One of the main features of this CLI is the ability to seek byte ranges before matching or replacing.",
        .optionsDescription = &.{
            .{ .field = .match, .description = "PCRE2 Regex to match on all files." },
            .{ .field = .byteRanges, .description = "Range of bytes for n files, top-level array length has to be of (len <= files.len) and will be applied sequentially over files." },
            .{ .field = .verbose, .description = "Verbose mode." },
        },
    };

    pub const Match = struct {
        @"match-n": ?usize = null,

        const Positional = PositionalOf(void, []const []const u8, undefined);

        pub const Short = .{
            .n = .@"match-n",
        };

        pub const Help: HelpData(@This()) = .{
            .usage = &.{"seeksub ... match [file1] ..."},
            .description = "Matches based on options at the top-level. This performs no mutation or replacement, it's simply a dry-run.",
            .shortDescription = "Match-only operation. This is a dry-run with no replacement.",
            .optionsDescription = &.{
                .{ .field = .@"match-n", .description = "N-match stop for each file if set." },
            },
        };
    };

    pub const Diff = struct {
        replace: []const u8 = undefined,

        const Positional = PositionalOf(void, []const []const u8, undefined);

        pub const Short = .{
            .r = .replace,
        };

        pub const Help: HelpData(@This()) = .{
            .usage = &.{"seeksub ... diff [options] [file1] ..."},
            .description = "Matches based on options at the top-level and then performs a replacement over matches, providing a diff return but not actually mutating the files.",
            .shortDescription = "Dry-runs replacement. No mutation is performed.",
            .optionsDescription = &.{
                .{ .field = .replace, .description = "Replace match on all files using this PCRE2 regex." },
            },
        };

        pub const GroupMatch: GroupMatchConfig(@This()) = .{
            .required = &.{.replace},
        };
    };

    pub const Apply = struct {
        replace: []const u8 = undefined,
        trace: bool = false,

        const Positional = PositionalOf(void, []const []const u8, undefined);

        pub const Short = .{
            .r = .replace,
            .tt = .trace,
        };

        pub const Help: HelpData(@This()) = .{
            .usage = &.{"seeksub ... apply [options] [file1] ..."},
            .description = "Matches based on options at the top-level and then performs a replacement over matches. This is mutate the files.",
            .shortDescription = "Replaces based on match and replace PCRE2 regexes over all files.",
            .optionsDescription = &.{
                .{ .field = .replace, .description = "Replace match on all files using this PCRE2 regex." },
                .{ .field = .trace, .description = "Trace mutations" },
            },
        };

        pub const GroupMatch: GroupMatchConfig(@This()) = .{
            .required = &.{.replace},
        };
    };
};

pub fn main() !void {
    // for (1..1000) |_| {
    try parse();
    // }
}

pub fn parse() !void {
    var sfba = std.heap.stackFallback(4098, std.heap.page_allocator);
    const allocator = sfba.get();

    const t0 = std.time.nanoTimestamp();
    var argIter = try std.process.argsWithAllocator(allocator);
    defer argIter.deinit();
    // const t1 = std.time.nanoTimestamp();
    var result = SpecResponse(Args).init(allocator);
    defer result.deinit();
    // const t2 = std.time.nanoTimestamp();
    var cursor = rv: {
        var c = Cursor([]const u8){
            .curr = null,
            .ptr = &argIter,
            .vtable = &.{
                .next = &coll.AsCursor(@TypeOf(argIter)).next,
            },
        };
        break :rv &c;
    };
    _ = &cursor;
    // const t3 = std.time.nanoTimestamp();

    result.parse(cursor) catch |E| {
        const helpWithReson: []const u8 = switch (E) {
            inline else => |e| comptime rv: {
                break :rv ComptSb.initTup(.{
                    "Execution failure reason: ",
                    @errorName(e),
                    "\n\n",
                    HelpFmt(Args, .{ .simpleTypes = true, .optionsBreakline = true }).help(),
                    "\n\n",
                }).s;
            },
        };
        std.log.err("Failure reason: {s}", .{@errorName(E)});
        try std.fs.File.stderr().writeAll(helpWithReson);
    };
    const t4 = std.time.nanoTimestamp();

    std.log.err("parse: {d}ns", .{t4 - t0});
    // std.log.err("{any}", .{result.options.ranges});
}
