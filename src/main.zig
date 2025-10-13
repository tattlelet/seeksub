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
const regex = zpec.regex;

const Args = struct {
    match: []const u8 = undefined,
    // TODO: rethink this, filename and byterange are detached and can be a problem
    byteRanges: ?[]const []const usize = null,
    @"line-by-line": bool = false,
    multiline: bool = false,
    recursive: bool = false,
    @"follow-links": bool = false,
    verbose: bool = false,

    pub const Short = .{
        .m = .match,
        .bR = .byteRanges,
        .lB = .@"line-by-line",
        .mL = .multiline,
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
        .mutuallyExclusive = &.{
            &.{ .byteRanges, .@"line-by-line", .multiline },
        },
        .mandatoryVerb = true,
    };

    pub const Help: HelpData(@This()) = .{
        .usage = &.{"seeksub <options> <command> ... <files> <optionalFiles>"},
        .description = "CLI tool to match, diff and apply regex in bulk using PCRE2. One of the main features of this CLI is the ability to seek byte ranges before matching or replacing",
        .optionsDescription = &.{
            .{ .field = .match, .description = "PCRE2 Regex to match on all files" },
            .{ .field = .byteRanges, .description = "Range of bytes for n files, top-level array length has to be of (len <= files.len) and will be applied sequentially over files" },
            .{ .field = .@"line-by-line", .description = "Line by line matching" },
            .{ .field = .multiline, .description = "Multiline matching" },
            .{ .field = .recursive, .description = "Recursively matches all files in paths" },
            .{ .field = .@"follow-links", .description = "Follow symlinks, using a weakref visitor" },
            .{ .field = .verbose, .description = "Verbose mode" },
        },
        .positionalsDescription = .{
            .reminder = "Files or paths to be operated on",
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

var reporter: *const zpec.reporter.Reporter = undefined;
pub fn main() !u8 {
    reporter = rv: {
        var r: zpec.reporter.Reporter = .{};
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
    defer reporter.stdoutW.flush() catch unreachable;
    defer reporter.stderrW.flush() catch unreachable;

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

    // TODO: validate STDIN has anything
    try run(&result);
    return 0;
}

pub const MmapOpenError = std.posix.RealPathError ||
    std.posix.OpenError ||
    std.posix.MMapError;

pub fn mmapOpen(file: std.fs.File) MmapOpenError!std.Io.Reader {
    const stats = try file.stat();
    const fSize = stats.size;

    // TODO: test heap allocated mmap
    const mmapBuff = try std.posix.mmap(
        null,
        fSize,
        std.posix.PROT.READ,
        .{
            .TYPE = .SHARED,
            .NONBLOCK = true,
        },
        file.handle,
        0,
    );

    // NOTE: fixed can be copied because there's no @fieldParentPtr access
    return .fixed(mmapBuff);
}

pub const AnonyMmapPipeBuffError = std.posix.MMapError;

pub fn anonyMmapPipeBuff() AnonyMmapPipeBuffError![]u8 {
    return try std.posix.mmap(
        null,
        // NOTE: default pipe size
        units.ByteUnit.kb * 64,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{
            .TYPE = .SHARED,
            .ANONYMOUS = true,
        },
        -1,
        0,
    );
}

pub const FileType = union(enum) {
    stdin,
    file: []const u8,

    pub fn name(self: *const @This()) []const u8 {
        return switch (self.*) {
            .stdin => "stdin",
            .file => |fileArg| fileArg,
        };
    }
};

pub const OpenError = std.fs.File.OpenError || std.posix.RealPathError;

pub fn open(fileArg: []const u8) OpenError!std.fs.File {
    var buff: [4098]u8 = undefined;
    const filePath = try std.fs.cwd().realpath(fileArg, &buff);
    return try std.fs.openFileAbsolute(filePath, .{ .mode = .read_only });
}

pub const FileCursor = struct {
    files: [1]FileType = undefined,
    current: ?std.fs.File = null,
    idx: usize = 0,

    pub fn init(argsRes: *const ArgsRes) @This() {
        var self: @This() = .{};

        if (argsRes.positionals.reminder) |reminder| {
            const target = reminder[0];
            if (target.len == 1 and target[0] == '-') {
                self.files[0] = .stdin;
            } else {
                self.files[0] = .{ .file = reminder[0] };
            }
        } else {
            self.files[0] = .stdin;
        }

        return self;
    }

    pub fn currentType(self: *const @This()) FileType {
        return self.files[self.idx];
    }

    pub fn next(self: *@This()) OpenError!?std.fs.File {
        std.debug.assert(self.current == null);
        if (self.idx >= self.files.len) return null;
        const fType = self.files[self.idx];

        self.current = switch (fType) {
            .file => |fileArg| try open(fileArg),
            .stdin => std.fs.File.stdin(),
        };

        return self.current;
    }

    pub fn close(self: *@This()) void {
        std.debug.assert(self.current != null);
        self.current.?.close();
        self.current = null;
        self.idx += 1;
    }
};

pub const RunError = error{} ||
    regex.CompileError ||
    regex.Regex.MatchError ||
    MmapOpenError ||
    AnonyMmapPipeBuffError ||
    std.Io.Reader.DelimiterError ||
    std.Io.Writer.Error;

pub fn run(argsRes: *const ArgsRes) RunError!void {
    const matchPattern = argsRes.options.match;
    var rgx = try regex.compile(matchPattern, reporter);
    defer rgx.deinit();

    var fileCursor = FileCursor.init(argsRes);
    // TODO: iterate over folders and more files
    const file = try fileCursor.next() orelse return;
    defer fileCursor.close();

    var reader = switch (fileCursor.currentType()) {
        .file => rv: {
            var reader = try mmapOpen(file);
            break :rv &reader;
        },
        .stdin => rv: {
            const buff = try anonyMmapPipeBuff();
            var reader = file.reader(buff);
            break :rv &reader.interface;
        },
    };
    defer std.posix.munmap(
        @as([]align(std.heap.page_size_min) const u8, @ptrCast(@alignCast(reader.buffer))),
    );

    if (argsRes.options.@"line-by-line") {
        while (true) {
            const line = reader.peekDelimiterInclusive('\n') catch |e| switch (e) {
                std.Io.Reader.DelimiterError.EndOfStream => break,
                std.Io.Reader.DelimiterError.ReadFailed => return e,
                std.Io.Reader.DelimiterError.StreamTooLong => return e,
            };

            var optMachData = try rgx.match(line);
            if (optMachData) |*matchData| {
                defer matchData.deinit();
                try reporter.stdoutW.print("Match <{s}>\n", .{matchData.group(0, line)});
            }

            reader.toss(line.len);
        }
        return;
    }

    return;
}
