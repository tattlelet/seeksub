const std = @import("std");
const coll = @import("../collections.zig");
const Allocator = std.mem.Allocator;

pub const TstArgCursor = struct {
    iterator: std.process.ArgIteratorGeneral(.{}),

    pub fn init(allocator: *const Allocator, data: [:0]const u8) !@This() {
        return .{
            .iterator = try std.process.ArgIteratorGeneral(.{}).init(
                allocator.*,
                data,
            ),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.iterator.deinit();
    }

    pub fn asCursor(self: *@This()) coll.Cursor([]const u8) {
        return .{
            .curr = null,
            .ptr = self,
            .vtable = &.{
                .next = next,
            },
        };
    }

    pub fn next(cursor: *anyopaque) ?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(cursor));
        return self.iterator.next();
    }
};

test "arg cursor peek" {
    const allocator = std.testing.allocator;
    var tstCursor = try TstArgCursor.init(&allocator,
        \\Hello
        \\World
    );
    defer tstCursor.deinit();
    var cursor = tstCursor.asCursor();

    try std.testing.expectEqualStrings("Hello", cursor.peek().?);
    try std.testing.expectEqualStrings("Hello", cursor.next().?);
    try std.testing.expectEqualStrings("World", cursor.peek().?);
    try std.testing.expectEqualStrings("World", cursor.peek().?);
    try std.testing.expectEqualStrings("World", cursor.next().?);
    try std.testing.expectEqual(null, cursor.peek());
}

test "arg cursor peek with stackItem" {
    const allocator = std.testing.allocator;
    var tstCursor = try TstArgCursor.init(&allocator, "");
    defer tstCursor.deinit();
    var cursor = tstCursor.asCursor();

    cursor.stackItem("Hello");
    try std.testing.expectEqualStrings("Hello", cursor.peek().?);
}

pub const AtDepthArrayTokenizer = struct {
    i: usize,
    slice: []const u8,
    state: State,

    pub const Error = State.Error;

    const StateTag = enum {
        noop,
        inQuotes,
        inBrackets,
        inBracketsMatching,
        seekComma,
        needValue,
        ready,
        finish,
    };

    const State = struct {
        tag: StateTag,
        depth: usize = 0,
        quoted: bool = false,
        start: usize = 0,
        end: usize = 0,
        earlyStop: bool = false,

        const Error = error{
            CharBlackholed,
            UnsupportedQuotesOnArrayType,
            UnsupportedCharacterOnArrayType,
            EarlyBracketTermination,
            MissingArrayLayer,
            EmptyCommaSplit,
            EarlyArrayTermination,
            MissingCommaSeparator,
            ResultBlackholed,
            EarlyQuoteTermination,
            MissingTypeToken,
        };

        const Noop: State = .{
            .tag = .noop,
        };

        fn noop(self: *State) void {
            self.* = Noop;
        }

        fn ready(self: *State, i: usize, earlyStop: bool) void {
            self.end = i;
            self.earlyStop = earlyStop;
            self.quoted = false;
            self.tag = .ready;
        }

        fn inBrackets(self: *State, depth: usize) void {
            self.* = .{
                .tag = .inBrackets,
                .depth = depth,
            };
        }

        fn seekComma(self: *State, depth: usize) void {
            self.* = .{
                .tag = .seekComma,
                .depth = depth,
            };
        }

        fn inBracketsMatching(self: *State, i: usize) void {
            self.* = .{
                .tag = .inBracketsMatching,
                .depth = self.depth + 1,
                .quoted = self.quoted,
                .start = i,
                .end = i + 1,
            };
        }

        fn inQuotes(self: *State, i: usize) void {
            self.* = .{
                .tag = .inQuotes,
                .depth = self.depth,
                .quoted = true,
                .start = i + 1,
                .end = i + 1,
            };
        }

        fn needValue(self: *State) void {
            self.* = .{
                .tag = .needValue,
                .depth = 1,
            };
        }

        fn finish(self: *State) void {
            self.* = .{
                .tag = .finish,
            };
        }

        fn resetReady(self: *State) void {
            if (self.earlyStop == true) {
                self.seekComma(self.depth);
            } else if (self.depth == 0) {
                self.finish();
            } else if (self.depth == 1) {
                self.needValue();
            } else {
                self.inBrackets(self.depth);
            }
        }

        fn consume(self: *State, i: usize, c: u8) State.Error!void {
            const tag = self.tag;
            switch (c) {
                0 => {
                    switch (tag) {
                        .noop, .seekComma => {
                            if (self.depth > 0) return State.Error.EarlyArrayTermination;
                        },
                        .needValue, .inBrackets, .inBracketsMatching => {
                            if (self.quoted) return State.Error.EarlyQuoteTermination;
                            return State.Error.EarlyArrayTermination;
                        },
                        .inQuotes => return State.Error.EarlyQuoteTermination,
                        .ready => return State.Error.ResultBlackholed,
                        .finish => {},
                    }
                },
                '[' => {
                    switch (tag) {
                        .noop => self.inBrackets(1),
                        .needValue, .inBrackets, .seekComma => self.inBracketsMatching(i),
                        .inBracketsMatching => {
                            if (!self.quoted) {
                                self.depth += 1;
                            } else {
                                self.end = i;
                            }
                        },
                        .inQuotes => self.end = i,
                        .ready, .finish => return State.Error.CharBlackholed,
                    }
                },
                ']' => {
                    switch (tag) {
                        .noop, .finish => return State.Error.MissingArrayLayer,
                        .inBrackets, .seekComma => {
                            self.depth -= 1;
                            self.finish();
                        },
                        .needValue => return State.Error.EarlyArrayTermination,
                        .inBracketsMatching => {
                            if (!self.quoted) {
                                self.depth -= 1;
                                if (self.depth == 0) self.ready(i, false) else self.end = i;
                            } else {
                                self.end = i;
                            }
                        },
                        .inQuotes => self.end = i,
                        .ready => return State.Error.CharBlackholed,
                    }
                },
                '\'' => {
                    switch (tag) {
                        .noop => return State.Error.MissingArrayLayer,
                        .inBrackets => {
                            if (self.depth == 1) self.inQuotes(i) else self.end = i;
                        },
                        .seekComma => return State.Error.MissingCommaSeparator,
                        .needValue => self.inQuotes(i),
                        .inBracketsMatching => {
                            self.end = i;
                            self.quoted = !self.quoted;
                        },
                        .inQuotes => self.ready(i, true),
                        .ready, .finish => return State.Error.CharBlackholed,
                    }
                },
                ' ', '\t' => {
                    switch (tag) {
                        .noop, .finish => self.noop(),
                        .seekComma, .needValue, .inBrackets => {},
                        .inBracketsMatching => {
                            if (!self.quoted and self.depth == 1) {
                                self.ready(i, true);
                            } else {
                                self.end = i;
                            }
                        },
                        .inQuotes => self.end = i,
                        .ready => return State.Error.CharBlackholed,
                    }
                },
                '\r', '\n' => return State.Error.UnsupportedCharacterOnArrayType,
                ',' => {
                    switch (tag) {
                        .noop => return State.Error.MissingTypeToken,
                        .seekComma => self.tag = .needValue,
                        .needValue, .inBrackets => return State.Error.EmptyCommaSplit,
                        .inBracketsMatching => {
                            if (!self.quoted and self.depth == 1) {
                                self.ready(i, false);
                            } else {
                                self.end = i;
                            }
                        },
                        .inQuotes => self.end = i,
                        .ready, .finish => return State.Error.CharBlackholed,
                    }
                },
                else => {
                    switch (tag) {
                        .noop => return State.Error.MissingArrayLayer,
                        .needValue, .inBrackets => {
                            self.tag = .inBracketsMatching;
                            self.start = i;
                            self.end = i;
                        },
                        .inBracketsMatching => self.end = i,
                        .inQuotes => self.end = i,
                        .seekComma => return State.Error.MissingCommaSeparator,
                        .ready, .finish => return State.Error.CharBlackholed,
                    }
                },
            }
        }
    };

    pub fn init(slice: []const u8) @This() {
        return .{
            .i = 0,
            .slice = slice,
            .state = State.Noop,
        };
    }

    pub fn next(self: *@This()) Error!?[]const u8 {
        var i = self.i;
        defer {
            self.i = i;
        }

        const slice = self.slice;
        while (i <= slice.len) : (i += 1) {
            const c = if (i < slice.len) slice[i] else 0;
            try self.state.consume(i, c);
            var state = &self.state;
            if (state.tag == .ready) {
                i += 1;

                const s = slice[state.start..state.end];
                state.resetReady();
                return s;
            }
        }
        return null;
    }
};

test "simple array iterator" {
    const t = std.testing;
    var iterator = AtDepthArrayTokenizer.init("[1,2,3]");
    try t.expectEqualStrings("1", (try iterator.next()).?);
    try t.expectEqualStrings("2", (try iterator.next()).?);
    try t.expectEqualStrings("3", (try iterator.next()).?);
    try t.expectEqual(null, try iterator.next());
}

fn tstCollectTokens(allocator: *const Allocator, slice: []const u8) ![]const []const u8 {
    var result = try std.ArrayListUnmanaged([]const u8).initCapacity(allocator.*, slice.len);
    var tokenizer = AtDepthArrayTokenizer.init(slice);

    while (try tokenizer.next()) |item| {
        try result.append(allocator.*, item);
    }

    return result.toOwnedSlice(allocator.*);
}

test "Depth 1 Array tokenizer (non-string)" {
    const t = std.testing;
    const E = AtDepthArrayTokenizer.Error;
    const base = &std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base.*);
    defer arena.deinit();
    const allocator = &arena.allocator();

    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "]"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, " ]"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "] "));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, " ] "));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "\t]"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "]\t"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "\t]\t"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, " \t] \t "));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "1"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, " 1 "));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "\t1\t"));

    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "1,2"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "1, 2"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, " 1 , 2 "));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "\t1,\t2\t"));

    try t.expectError(E.MissingTypeToken, tstCollectTokens(allocator, ","));
    try t.expectError(E.MissingTypeToken, tstCollectTokens(allocator, " ,"));
    try t.expectError(E.MissingTypeToken, tstCollectTokens(allocator, ", "));
    try t.expectError(E.MissingTypeToken, tstCollectTokens(allocator, " , "));
    try t.expectError(E.MissingTypeToken, tstCollectTokens(allocator, "\t,\t"));
    try t.expectError(E.MissingTypeToken, tstCollectTokens(allocator, " \t,"));
    try t.expectError(E.MissingTypeToken, tstCollectTokens(allocator, ",\t "));
    try t.expectError(E.MissingTypeToken, tstCollectTokens(allocator, " \t, \t "));

    const expectEmpty: []const []const u8 = &.{};
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, ""));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, " "));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "  "));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "\t"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "\t "));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, " \t"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "\t\t"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, " \t "));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "[]"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "[ ]"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "[  ]"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "[\t]"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "[ \t]"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "[\t ]"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "[\t\t]"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "[ \t\t ]"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, " []"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "[] "));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, " [ ] "));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "\t[ ]\t"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, " \t[ \t ] \t"));

    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "["));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, " ["));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[ "));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "\t["));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[\t"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "\t[ \t"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, " \t[ \t "));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[1,"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[1, ]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[1,  ]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[1,\t]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[1,\t\t]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[1, \t]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[1\t,]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[1 \t,]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[1\t,\t]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, " [1,"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[1, "));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, " [1, ] "));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "\t[1,"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[1,\t"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "\t[1,\t]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, " \t[1, ]\t "));

    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[ ,]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[  ,]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[\t,]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[,\t]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[ \t,\t ]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[ ,1]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[  ,1]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[\t,1]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[\t ,1]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[ ,\t1]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[ \t,\t1]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[1,,]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[1, ,]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[1,\t,]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[1, ,\t]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[1,\t,\t]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[1,,1]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[1, ,1]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[1,\t,1]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[1, ,\t1]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[1,\t,\t1]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[1,\t, 1]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, " [1,,1]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[1,,1] "));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, " [1,,1] "));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "\t[1,,1]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[1,,1]\t"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "\t[1,,1]\t"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, " \t[1,,1]\t "));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[ ,1]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, " [ ,1] "));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "\t[ ,1]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[ ,1]\t"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, " \t[ ,1]\t "));

    const expectOne: []const []const u8 = &.{"1"};
    try t.expectEqualDeep(expectOne, try tstCollectTokens(allocator, "[1]"));
    try t.expectEqualDeep(expectOne, try tstCollectTokens(allocator, "[ 1]"));
    try t.expectEqualDeep(expectOne, try tstCollectTokens(allocator, "[1 ]"));
    try t.expectEqualDeep(expectOne, try tstCollectTokens(allocator, "[ 1 ]"));
    try t.expectEqualDeep(expectOne, try tstCollectTokens(allocator, "[\t1]"));
    try t.expectEqualDeep(expectOne, try tstCollectTokens(allocator, "[1\t]"));
    try t.expectEqualDeep(expectOne, try tstCollectTokens(allocator, "[\t1\t]"));
    try t.expectEqualDeep(expectOne, try tstCollectTokens(allocator, "[ \t1\t ]"));
    try t.expectEqualDeep(expectOne, try tstCollectTokens(allocator, " [1]"));
    try t.expectEqualDeep(expectOne, try tstCollectTokens(allocator, "[1] "));
    try t.expectEqualDeep(expectOne, try tstCollectTokens(allocator, " [1] "));
    try t.expectEqualDeep(expectOne, try tstCollectTokens(allocator, "\t[1]"));
    try t.expectEqualDeep(expectOne, try tstCollectTokens(allocator, "[1]\t"));
    try t.expectEqualDeep(expectOne, try tstCollectTokens(allocator, "\t[1]\t"));
    try t.expectEqualDeep(expectOne, try tstCollectTokens(allocator, " \t[1]\t "));

    const expectTwo: []const []const u8 = &.{ "1", "1" };
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[1,1]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[1, 1]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[1 ,1]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[1 , 1]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[ 1,1]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[1,1 ]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[ 1,1 ]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[ 1 ,1]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[1 , 1 ]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[ 1 , 1 ]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[\t1,1]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[1,\t1]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[1,1\t]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[\t1,\t1\t]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[ \t1\t , \t1\t ]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, " [1,1]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[1,1] "));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, " [1,1] "));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "\t[1,1]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[1,1]\t"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "\t[1,1]\t"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, " \t[1,1]\t "));
}

test "Depth 2+ Array tokenizer (non-string)" {
    const t = std.testing;
    const E = AtDepthArrayTokenizer.Error;
    const base = &std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base.*);
    defer arena.deinit();
    const allocator = &arena.allocator();

    const expectOneEmpty: []const []const u8 = &.{"[]"};
    try t.expectEqualDeep(expectOneEmpty, try tstCollectTokens(allocator, "[[]]"));
    try t.expectEqualDeep(expectOneEmpty, try tstCollectTokens(allocator, " [[]]"));
    try t.expectEqualDeep(expectOneEmpty, try tstCollectTokens(allocator, "[[]] "));
    try t.expectEqualDeep(expectOneEmpty, try tstCollectTokens(allocator, " [[]] "));
    try t.expectEqualDeep(expectOneEmpty, try tstCollectTokens(allocator, "\t[[]]\t"));

    try t.expectEqualDeep(expectOneEmpty, try tstCollectTokens(allocator, "[ [] ]"));
    try t.expectEqualDeep(expectOneEmpty, try tstCollectTokens(allocator, " [ [] ]"));
    try t.expectEqualDeep(expectOneEmpty, try tstCollectTokens(allocator, "[ [] ] "));
    try t.expectEqualDeep(expectOneEmpty, try tstCollectTokens(allocator, " [ [] ] "));
    try t.expectEqualDeep(expectOneEmpty, try tstCollectTokens(allocator, "\t[ [] ]\t"));

    const expectOneSpace: []const []const u8 = &.{"[ ]"};
    try t.expectEqualDeep(expectOneSpace, try tstCollectTokens(allocator, "[ [ ] ]"));
    try t.expectEqualDeep(expectOneSpace, try tstCollectTokens(allocator, " [ [ ] ]"));
    try t.expectEqualDeep(expectOneSpace, try tstCollectTokens(allocator, "[ [ ] ] "));
    try t.expectEqualDeep(expectOneSpace, try tstCollectTokens(allocator, " [ [ ] ] "));
    try t.expectEqualDeep(expectOneSpace, try tstCollectTokens(allocator, "\t[ [ ] ]\t"));

    const expectOneRaw1: []const []const u8 = &.{"[1,]"};
    const expectOneRaw1Space: []const []const u8 = &.{"[1, ]"};
    const expectMultipleRaw: []const []const u8 = &.{ "[]", "[1]", "[2,3]" };

    try t.expectEqualDeep(expectOneRaw1, try tstCollectTokens(allocator, "[[1,]]"));
    try t.expectEqualDeep(expectOneRaw1, try tstCollectTokens(allocator, " [[1,]] "));
    try t.expectEqualDeep(expectOneRaw1, try tstCollectTokens(allocator, "\t[[1,]]\t"));
    try t.expectEqualDeep(expectOneRaw1Space, try tstCollectTokens(allocator, "[[1, ]]"));
    try t.expectEqualDeep(expectOneRaw1Space, try tstCollectTokens(allocator, " [[1, ]] "));
    try t.expectEqualDeep(expectOneRaw1Space, try tstCollectTokens(allocator, "\t[[1, ]]\t"));
    try t.expectEqualDeep(expectMultipleRaw, try tstCollectTokens(allocator, "[[],[1],[2,3]]"));
    try t.expectEqualDeep(expectMultipleRaw, try tstCollectTokens(allocator, " [[],[1],[2,3]] "));
    try t.expectEqualDeep(expectMultipleRaw, try tstCollectTokens(allocator, "\t[[],[1],[2,3]]\t"));
    try t.expectEqualDeep(expectMultipleRaw, try tstCollectTokens(allocator, "[ [], [1], [2,3] ]"));
    try t.expectEqualDeep(expectMultipleRaw, try tstCollectTokens(allocator, " [ [], [1], [2,3] ] "));
    try t.expectEqualDeep(expectMultipleRaw, try tstCollectTokens(allocator, "\t[ [], [1], [2,3] ]\t"));

    const expectOneRawNested: []const []const u8 = &.{"[[]]"};
    try t.expectEqualDeep(expectOneRawNested, try tstCollectTokens(allocator, "[[[]]]"));
    try t.expectEqualDeep(expectOneRawNested, try tstCollectTokens(allocator, " [[[]]] "));
    try t.expectEqualDeep(expectOneRawNested, try tstCollectTokens(allocator, "\t[[[]]]\t"));

    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[["));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[[]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[[[]]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[[1,]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[[], [1], [2,3]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[[1, 2], ]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[[1, 2], [3],]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, " [ [ ]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[[1], [2,]"));

    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[[], , [1]]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[[1, 2], , [3]]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[[], , [1]]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[[],  , [1]]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[[], \t, [1]]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[[], ,\t[1]]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[[], , [1]] "));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, " [[], , [1]]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[[1, 2], , [3]]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[[1, 2],  , [3]]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[[1, 2], \t, [3]]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[[1, 2], ,\t[3]]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[[1, 2], , [3]] "));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, " [[1, 2], , [3]]"));

    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "[[]] ]"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "[[]]]"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "[[]] ]"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "[[]]] "));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, " [ []]]"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "[ [ ] ] ]"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "[ [ ] ] ] "));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "\t[[]]]\t"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "[1]]"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "[1] ]"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "[1]] "));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, " [1]]"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "[ 1 ] ]"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "[ 1 ] ] "));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "\t[1]]\t"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "[1, 2]]"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "[1, 2] ]"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "[1, 2]] "));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, " [1, 2]]"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "[ 1, 2 ] ]"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "[ 1, 2 ] ] "));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "\t[1, 2]]\t"));

    const expectMixedDepth: []const []const u8 = &.{ "1", "[3, 4]", "2", "[[4], 4]" };
    try t.expectEqualDeep(expectMixedDepth, try tstCollectTokens(allocator, "[1, [3, 4], 2, [[4], 4]]"));

    const expectMixedDepthSpaces: []const []const u8 = &.{ "1", "[ 3 , 4 ]", "2", "[[4], 4]" };
    try t.expectEqualDeep(expectMixedDepthSpaces, try tstCollectTokens(allocator, "[ 1 , [ 3 , 4 ] , 2 , [[4], 4] ]"));

    const expectMixedDepthTabs: []const []const u8 = &.{ "1", "[3,\t4]", "2", "[[4],\t4]" };
    try t.expectEqualDeep(expectMixedDepthTabs, try tstCollectTokens(allocator, "[1,\t[3,\t4],2,[[4],\t4]]"));

    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[1, [3, 4], 2, [[4], 4]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[1, [3, 4], 2, [[4], 4"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[1, [3, 4], 2, [[4], 4],"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[1, [3, 4], , 2, [[4], 4]]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[1,, [3, 4], 2, [[4], 4]]"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "1, [3, 4], 2, [[4], 4]"));
    try t.expectError(E.MissingArrayLayer, tstCollectTokens(allocator, "[1, [3, 4], 2, [[4], 4]]]"));
}

test "Depth 1 Array tokenizer (strings)" {
    const t = std.testing;
    const E = AtDepthArrayTokenizer.Error;
    const base = &std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base.*);
    defer arena.deinit();
    const allocator = &arena.allocator();

    const expectEmptyString: []const []const u8 = &.{""};
    try t.expectEqualDeep(expectEmptyString, try tstCollectTokens(allocator, "[ '' ]"));
    const expectSpaceString: []const []const u8 = &.{" "};
    try t.expectEqualDeep(expectSpaceString, try tstCollectTokens(allocator, "[ ' ' ]"));
    const expectWhitespaceString: []const []const u8 = &.{"  "};
    try t.expectEqualDeep(expectWhitespaceString, try tstCollectTokens(allocator, "[ '  ' ]"));
    const expectTabString: []const []const u8 = &.{"\t"};
    try t.expectEqualDeep(expectTabString, try tstCollectTokens(allocator, "[ '\t' ]"));
    const expectTabSpaceString: []const []const u8 = &.{"\t "};
    try t.expectEqualDeep(expectTabSpaceString, try tstCollectTokens(allocator, "[ '\t ' ]"));
    const expectMixedWhitespaceString: []const []const u8 = &.{" \t\t "};
    try t.expectEqualDeep(expectMixedWhitespaceString, try tstCollectTokens(allocator, "[ ' \t\t ' ]"));

    const expectTwo: []const []const u8 = &.{ "a", "b" };
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "['a','b']"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[ 'a', 'b' ]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[ 'a' , 'b' ]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[ 'a'\t,\t'b' ]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[\t'a'\t,\t'b'\t]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[\t'a' , 'b'\t]"));
    try t.expectEqualDeep(expectTwo, try tstCollectTokens(allocator, "[\t'a'\t, 'b' ]"));

    const expectEmpty: []const []const u8 = &.{ "", "" };
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "['','']"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "[ '', '' ]"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "[ '' , '' ]"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "[ ''\t,\t'' ]"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "[\t''\t,\t''\t]"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "[\t'' , ''\t]"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, "[\t''\t, '' ]"));

    const expectArrayStrings: []const []const u8 = &.{ "[1,2]", "[3,4]" };
    try t.expectEqualDeep(expectArrayStrings, try tstCollectTokens(allocator, "['[1,2]', '[3,4]']"));
    try t.expectEqualDeep(expectArrayStrings, try tstCollectTokens(allocator, "[ '[1,2]' , '[3,4]' ]"));
    try t.expectEqualDeep(expectArrayStrings, try tstCollectTokens(allocator, "[\t'[1,2]',\t'[3,4]'\t]"));
    try t.expectEqualDeep(expectArrayStrings, try tstCollectTokens(allocator, "[ '[1,2]', '[3,4]' ]"));

    const expectArrayInsideString: []const []const u8 = &.{"[1,2]"};
    try t.expectEqualDeep(expectArrayInsideString, try tstCollectTokens(allocator, "['[1,2]']"));

    const expectNestedArrayInString: []const []const u8 = &.{"[[1,2]]"};
    try t.expectEqualDeep(expectNestedArrayInString, try tstCollectTokens(allocator, "['[[1,2]]']"));

    const expectArrayAndCommaInString: []const []const u8 = &.{"[1, 2], [3,4]"};
    try t.expectEqualDeep(expectArrayAndCommaInString, try tstCollectTokens(allocator, "['[1, 2], [3,4]']"));

    const expectMixed: []const []const u8 = &.{ "a", "[1,2]", "b" };
    try t.expectEqualDeep(expectMixed, try tstCollectTokens(allocator, "['a', '[1,2]', 'b']"));

    const expectMoreMixed: []const []const u8 = &.{ "[a]", "[b,c]", "x", "y" };
    try t.expectEqualDeep(expectMoreMixed, try tstCollectTokens(allocator, "['[a]', '[b,c]', 'x', 'y']"));

    const expectSpaced: []const []const u8 = &.{ "[ 1 , 2 ]", "[ 3 , 4 ]" };
    try t.expectEqualDeep(expectSpaced, try tstCollectTokens(allocator, "[ '[ 1 , 2 ]' , '[ 3 , 4 ]' ]"));
    try t.expectEqualDeep(expectSpaced, try tstCollectTokens(allocator, "[\t'[ 1 , 2 ]',\t'[ 3 , 4 ]'\t]"));

    const expectUnbalancedBracketsInString: []const []const u8 = &.{"[[[["};
    try t.expectEqualDeep(expectUnbalancedBracketsInString, try tstCollectTokens(allocator, "['[[[[']"));

    const expectMixedBracketInString2: []const []const u8 = &.{ "[w,]", "[", "]" };
    try t.expectEqualDeep(expectMixedBracketInString2, try tstCollectTokens(allocator, "['[w,]', '[', ']']"));

    try t.expectError(E.EarlyQuoteTermination, tstCollectTokens(allocator, "['a]"));
    try t.expectError(E.EarlyQuoteTermination, tstCollectTokens(allocator, "[ 'a ]"));
    try t.expectError(E.EarlyQuoteTermination, tstCollectTokens(allocator, "['a', 'b]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "['a', 'b'"));

    try t.expectError(E.MissingCommaSeparator, tstCollectTokens(allocator, "[''w]"));
    try t.expectError(E.MissingCommaSeparator, tstCollectTokens(allocator, "[ 'a'b ]"));
    try t.expectError(E.MissingCommaSeparator, tstCollectTokens(allocator, "[ 'abc'1 ]"));
    try t.expectError(E.MissingCommaSeparator, tstCollectTokens(allocator, "['it'broken']"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "[, 'a']"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, "['a', , 'b']"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "['a', ]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "[ 'a',    ]"));

    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "['a',"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, "['a'"));
}

test "Depth 2+ Array tokenizer (strings)" {
    const t = std.testing;
    const base = &std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base.*);
    defer arena.deinit();
    const allocator = &arena.allocator();

    const expectInnerQuoted: []const []const u8 = &.{ "[1, 'a']", "[2, 'b']" };
    try t.expectEqualDeep(expectInnerQuoted, try tstCollectTokens(allocator, "[[1, 'a'], [2, 'b']]"));

    const expectQuotedOnlyInner: []const []const u8 = &.{ "['a','b']", "['c','d']" };
    try t.expectEqualDeep(expectQuotedOnlyInner, try tstCollectTokens(allocator, "[['a','b'], ['c','d']]"));

    const expectNestedMix: []const []const u8 = &.{ "[1, 'a', [2, 'b']]", "x" };
    try t.expectEqualDeep(expectNestedMix, try tstCollectTokens(allocator, "[[1, 'a', [2, 'b']], 'x']"));

    const expectDeepStringInside: []const []const u8 = &.{ "[[ 'abc', [1,2] ]]", "tail" };
    try t.expectEqualDeep(expectDeepStringInside, try tstCollectTokens(allocator, "[[[ 'abc', [1,2] ]], 'tail']"));

    const expectSpacedQuoted: []const []const u8 = &.{ "[ 1 , 'a' ]", "[ 'b' , 2 ]" };
    try t.expectEqualDeep(expectSpacedQuoted, try tstCollectTokens(allocator, "[ [ 1 , 'a' ] , [ 'b' , 2 ] ]"));

    const expectMixedWhitespace: []const []const u8 = &.{ "[1,\t'a']", "[\t'b',2]" };
    try t.expectEqualDeep(expectMixedWhitespace, try tstCollectTokens(allocator, "[ [1,\t'a'] , [\t'b',2] ]"));
}

test "Any depth any match tricky cases" {
    const t = std.testing;
    const E = AtDepthArrayTokenizer.Error;
    const base = &std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base.*);
    defer arena.deinit();
    const allocator = &arena.allocator();

    try t.expectError(E.CharBlackholed, tstCollectTokens(allocator, "['a', 'b']['c', 'd']"));

    try t.expectError(E.EarlyQuoteTermination, tstCollectTokens(allocator, "[[1, 2], [3, 4']"));

    const expectTricky1: []const []const u8 = &.{ "['a,b', 'c']", "['d', 'e']" };
    try t.expectEqualDeep(expectTricky1, try tstCollectTokens(allocator, "[['a,b', 'c'], ['d', 'e']]"));

    const expectTricky2: []const []const u8 = &.{"['[1,2]', '[3,4]']"};
    try t.expectEqualDeep(expectTricky2, try tstCollectTokens(allocator, "[['[1,2]', '[3,4]']]"));

    const expectTricky3: []const []const u8 = &.{"['1, 2], [2,3']"};
    try t.expectEqualDeep(expectTricky3, try tstCollectTokens(allocator, "[['1, 2], [2,3']]"));

    const expectTricky4: []const []const u8 = &.{"1, 2], [2,3"};
    try t.expectEqualDeep(expectTricky4, try tstCollectTokens(allocator, "['1, 2], [2,3']"));

    try t.expectError(E.EarlyQuoteTermination, tstCollectTokens(allocator, "['[1, 2]', [3, '4]"));

    const expectTricky5: []const []const u8 = &.{ "1", "2, 3], [4, 5" };
    try t.expectEqualDeep(expectTricky5, try tstCollectTokens(allocator, "[1, '2, 3], [4, 5']"));

    try t.expectError(E.CharBlackholed, tstCollectTokens(allocator, "['[a, b'],"));

    const expectTricky6: []const []const u8 = &.{ "['[x, y], z']", "['a, b]']" };
    try t.expectEqualDeep(expectTricky6, try tstCollectTokens(allocator, "[['[x, y], z'], ['a, b]']]"));

    try t.expectError(E.EarlyQuoteTermination, tstCollectTokens(allocator, "[['1, 2'], ['3]]"));

    const expectTricky7: []const []const u8 = &.{ "1", "2", "3, [4, 5]" };
    try t.expectEqualDeep(expectTricky7, try tstCollectTokens(allocator, "[1, 2, '3, [4, 5]']"));
}
