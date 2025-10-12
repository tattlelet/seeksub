const std = @import("std");
const zpec = @import("zpec");
const units = zpec.units;
const args = zpec.args;
const spec = args.spec;
const help = args.help;
const validate = args.validate;
const coll = zpec.collections;
const Cursor = coll.Cursor;
const ComptSb = coll.ComptSb;
const HelpData = help.HelpData;
const GroupMatchConfig = validate.GroupMatchConfig;
const SpecResponseWithConfig = spec.SpecResponseWithConfig;
const positionals = args.positionals;
const c = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

const Args = struct {
    match: []const u8 = undefined,
    // TODO: rethink this, filename and byterange are detached and can be a problem
    byteRanges: ?[]const []const usize = null,
    recursive: bool = false,
    @"follow-links": bool = false,
    verbose: bool = false,

    pub const Positionals = positionals.PositionalOf(.{
        .TupleType = struct { []const u8 },
        .ReminderType = ?[]const []const u8,
    });

    pub const Short = .{
        .m = .match,
        .bR = .byteRanges,
        .r = .recursive,
        .fL = .@"follow-links",
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
        .usage = &.{"seeksub <options> <command> ... <files> <optionalFiles>"},
        .description = "CLI tool to match, diff and apply regex in bulk using PCRE2. One of the main features of this CLI is the ability to seek byte ranges before matching or replacing",
        .optionsDescription = &.{
            .{ .field = .match, .description = "PCRE2 Regex to match on all files" },
            .{ .field = .byteRanges, .description = "Range of bytes for n files, top-level array length has to be of (len <= files.len) and will be applied sequentially over files" },
            .{ .field = .recursive, .description = "Recursively matches all files in paths" },
            .{ .field = .@"follow-links", .description = "Follow symlinks, using a weakref visitor" },
            .{ .field = .verbose, .description = "Verbose mode" },
        },
        .positionalsDescription = .{
            .tuple = &.{
                "File or path to be operated on. Use -r for recusive",
            },
            .reminder = "More files or paths",
        },
    };

    pub const Match = struct {
        @"match-n": ?usize = null,

        pub const Positionals = positionals.EmptyPositionalsOf;

        pub const Short = .{
            .n = .@"match-n",
        };

        pub const Help: HelpData(@This()) = .{
            .usage = &.{"seeksub ... match <options> ..."},
            .description = "Matches based on options at the top-level. This performs no mutation or replacement, it's simply a dry-run",
            .shortDescription = "Match-only operation. This is a dry-run with no replacement",
            .optionsDescription = &.{
                .{ .field = .@"match-n", .description = "N-match stop for each file if set" },
            },
        };

        pub const GroupMatch: GroupMatchConfig(@This()) = .{
            .ensureCursorDone = false,
        };
    };

    pub const Diff = struct {
        replace: []const u8 = undefined,

        const Positionals = positionals.EmptyPositionalsOf;

        pub const Short = .{
            .r = .replace,
        };

        pub const Help: HelpData(@This()) = .{
            .usage = &.{"seeksub ... diff <options> ..."},
            .description = "Matches based on options at the top-level and then performs a replacement over matches, providing a diff return but not actually mutating the files",
            .shortDescription = "Dry-runs replacement. No mutation is performed",
            .optionsDescription = &.{
                .{ .field = .replace, .description = "Replace match on all files using this PCRE2 regex" },
            },
        };

        pub const GroupMatch: GroupMatchConfig(@This()) = .{
            .required = &.{.replace},
            .ensureCursorDone = false,
        };
    };

    pub const Apply = struct {
        replace: []const u8 = undefined,
        trace: bool = false,

        pub const Positionals = positionals.EmptyPositionalsOf;

        pub const Short = .{
            .r = .replace,
            .tt = .trace,
        };

        pub const Help: HelpData(@This()) = .{
            .usage = &.{"seeksub ... apply <options> ..."},
            .description = "Matches based on options at the top-level and then performs a replacement over matches. This is mutate the files",
            .shortDescription = "Replaces based on match and replace PCRE2 regexes over all files",
            .optionsDescription = &.{
                .{ .field = .replace, .description = "Replace match on all files using this PCRE2 regex" },
                .{ .field = .trace, .description = "Trace mutations" },
            },
        };

        pub const GroupMatch: GroupMatchConfig(@This()) = .{
            .required = &.{.replace},
            .ensureCursorDone = false,
        };
    };
};

pub const HelpConf: help.HelpConf = .{
    .simpleTypes = true,
};
pub const ArgsRes = SpecResponseWithConfig(Args, HelpConf, true);

const Reporter = struct {
    stdoutW: *std.Io.Writer = undefined,
    stderrW: *std.Io.Writer = undefined,
};

var reporter: *const Reporter = undefined;
pub fn main() !u8 {
    reporter = rv: {
        var r: Reporter = .{};
        var buffOut: [units.ByteUnit.kb * 2]u8 = undefined;
        var buffErr: [units.ByteUnit.kb * 2]u8 = undefined;

        r.stdoutW = rOut: {
            var writer = std.fs.File.stdout().writer(&buffOut);
            break :rOut &writer.interface;
        };
        r.stderrW = rErr: {
            var writer = std.fs.File.stderr().writer(&buffErr);
            break :rErr &writer.interface;
        };

        break :rv &r;
    };

    var sfba = std.heap.stackFallback(4098, std.heap.page_allocator);
    const allocator = sfba.get();

    var result: ArgsRes = .init(allocator);
    defer result.deinit();
    defer reporter.stderrW.flush() catch unreachable;
    defer reporter.stdoutW.flush() catch unreachable;

    if (result.parseArgs()) |err| {
        if (err.message) |message| {
            try reporter.stderrW.print("Last opt <{?s}>, Last token <{?s}>. ", .{
                err.lastOpt,
                err.lastToken,
            });
            try reporter.stderrW.writeAll(message);
            return 1;
        }
    }

    try run(&result);
    return 0;
}

pub const RunError = error{
    BadRegex,
    FailedMatchCreation,
    NoMatch,
    UnknownError,
} || std.posix.RealPathError ||
    std.posix.OpenError ||
    std.posix.MMapError ||
    std.Io.Writer.Error;

pub fn run(argsRes: *const ArgsRes) RunError!void {
    const fileArg = argsRes.positionals.tuple.@"0";
    var buff: [4098]u8 = undefined;
    const filePath = try std.fs.cwd().realpath(fileArg, &buff);
    const fd = try std.fs.openFileAbsolute(filePath, .{ .mode = .read_only });
    const stats = try fd.stat();
    const fSize = stats.size;

    // TODO: test heap allocated mmap
    const data = try std.posix.mmap(
        null,
        fSize,
        std.posix.PROT.READ,
        .{
            .TYPE = .PRIVATE,
            .NONBLOCK = true,
        },
        fd.handle,
        0,
    );

    var err: c_int = undefined;
    var errOff: usize = undefined;
    const re = c.pcre2_compile_8(
        argsRes.options.match.ptr,
        argsRes.options.match.len,
        // TODO: abstract flags support
        // NOTE: /g is actually an abstraction outside of the regex engine
        c.PCRE2_UTF | c.PCRE2_UCP,
        &err,
        &errOff,
        null,
    );
    if (re == null) {
        const end = c.pcre2_get_error_message_8(err, &buff, buff.len);
        try reporter.stderrW.print("Compile failed {d}: {s}\n", .{ errOff, buff[0..@intCast(end)] });

        return RunError.BadRegex;
    }
    defer c.pcre2_code_free_8(re);

    const match = c.pcre2_match_data_create_from_pattern_8(re, null);
    if (match == null) {
        return RunError.FailedMatchCreation;
    }
    defer c.pcre2_match_data_free_8(match);

    const rc = c.pcre2_match_8(
        re,
        data.ptr,
        data.len,
        0,
        // TODO: see if flags need to be abstracted
        // consider PCRE2_NO_UTF_CHECK
        0,
        match,
        null,
    );
    if (rc < 0) {
        switch (rc) {
            c.PCRE2_ERROR_NOMATCH => {
                try reporter.stderrW.writeAll("Pattern did not match\n");
                return RunError.NoMatch;
            },
            // NOTE: most error are data related or group related or utf related
            // check the ERROR definition in the lib
            else => {
                try reporter.stderrW.print("Unknown match return: {d}\n", .{rc});
                return RunError.UnknownError;
            },
        }
    }

    try reporter.stderrW.print("RC {d}\n", .{rc});
    const ovec = c.pcre2_get_ovector_pointer_8(match);
    try reporter.stdoutW.print("Match: {s}\n", .{data[@intCast(ovec[0])..@intCast(ovec[1])]});

    return;
}
