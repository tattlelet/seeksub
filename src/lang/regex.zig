const std = @import("std");

pub const pcre2 = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

pub const reporter = @import("reporter.zig");

pub const CompileError = error{
    RegexInitFailed,
    BadRegex,
} || std.Io.Writer.Error;

// TODO: extract flags from pattern
pub fn compile(pattern: []const u8, rpt: *const reporter.Reporter) CompileError!Regex {
    const compContext = pcre2.pcre2_compile_context_create_8(null) orelse {
        return CompileError.RegexInitFailed;
    };
    errdefer pcre2.pcre2_compile_context_free_8(compContext);

    switch (pcre2.pcre2_set_newline_8(compContext, pcre2.PCRE2_NEWLINE_LF)) {
        0 => {},
        pcre2.PCRE2_ERROR_BADDATA => return CompileError.RegexInitFailed,
        // NOTE: no other error codes are defined in the source
        else => unreachable,
    }

    var err: c_int = undefined;
    var errOff: usize = undefined;
    const re = pcre2.pcre2_compile_8(
        pattern.ptr,
        pattern.len,
        // TODO: abstract flags support
        // NOTE: /g is actually an abstraction outside of the regex engine
        0,
        &err,
        &errOff,
        compContext,
    ) orelse {
        // TODO: make this process optional
        var buff: [4098]u8 = undefined;
        const end = pcre2.pcre2_get_error_message_8(err, &buff, buff.len);
        try rpt.stderrW.print("Compile failed {d}: {s}\n", .{ errOff, buff[0..@intCast(end)] });

        return CompileError.BadRegex;
    };

    return .{
        .re = re,
        .compContext = compContext,
    };
}

pub const Regex = struct {
    re: *pcre2.pcre2_code_8,
    compContext: *pcre2.pcre2_compile_context_8,

    pub fn deinit(self: *@This()) void {
        pcre2.pcre2_code_free_8(self.re);
        self.re = undefined;
        pcre2.pcre2_compile_context_free_8(self.compContext);
        self.compContext = undefined;
    }

    pub const MatchError = error{
        MatchInitFailed,
        NoMatch,
        MatchDataNotAvailable,
        UnknownError,
    };

    pub fn match(self: *const @This(), data: []const u8) MatchError!?RegexMatch {
        const matchData = pcre2.pcre2_match_data_create_from_pattern_8(self.re, null) orelse {
            return MatchError.MatchInitFailed;
        };
        errdefer pcre2.pcre2_match_data_free_8(matchData);

        const rc = pcre2.pcre2_match_8(
            self.re,
            data.ptr,
            data.len,
            0,
            // TODO: see if flags need to be abstracted
            // NOTE: consider (?i) etc works here
            0,
            matchData,
            null,
        );
        if (rc <= 0) {
            switch (rc) {
                // NOTE: this implies ovector is not big enough for all substr
                // matches
                0 => return MatchError.MatchDataNotAvailable,
                pcre2.PCRE2_ERROR_NOMATCH => return null,
                // NOTE: most error are data related or group related or utf related
                // check the ERROR definition in the lib
                else => return MatchError.UnknownError,
            }
        }

        return .{
            .matchData = matchData,
        };
    }
};

pub const RegexMatch = struct {
    matchData: *pcre2.pcre2_match_data_8,

    pub fn group(self: *const @This(), n: usize, data: []const u8) []const u8 {
        const ovector = pcre2.pcre2_get_ovector_pointer_8(self.matchData);
        const start = n * 2;
        const end = start + 1;
        return data[ovector[start]..ovector[end]];
    }

    pub fn deinit(self: *@This()) void {
        pcre2.pcre2_match_data_free_8(self.matchData);
    }
};
