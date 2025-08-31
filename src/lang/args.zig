const std = @import("std");
const trait = @import("trait.zig");
const shared = @import("shared.zig");
const duck = @import("ducktape.zig");
const meta = @import("meta.zig");
const coll = @import("collections.zig");
const Allocator = std.mem.Allocator;
const FieldEnum = std.meta.FieldEnum;

const OwnedArgIterator = struct {
    destroyable: *duck.AnyDestroyable,
    concrete: *anyopaque,
    vtable: *const coll.Iterator([:0]const u8).VTable,

    pub fn deinit(self: *@This(), allocator: *const Allocator) void {
        self.destroyable.destroy(allocator);
        allocator.destroy(self);
    }

    pub fn next(self: *@This()) ?[:0]const u8 {
        return self.vtable.next(self.concrete);
    }
};

fn tstBaseArgIterator(allocator: *const Allocator, data: [:0]const u8) !*OwnedArgIterator {
    const ArgIteratorConcrete = std.process.ArgIteratorGeneral(.{});
    const cIt = try allocator.create(ArgIteratorConcrete);
    errdefer allocator.destroy(cIt);
    cIt.* = try ArgIteratorConcrete.init(allocator.*, data);
    errdefer cIt.deinit();

    return try duck.quackLikeOwned(
        allocator,
        OwnedArgIterator,
        cIt,
    );
}

test "owned arg iter shim test" {
    const allocator = std.testing.allocator;
    const iterator = try tstBaseArgIterator(&allocator,
        \\Hello
        \\World
    );
    defer iterator.deinit(&allocator);

    try std.testing.expectEqualStrings("Hello", iterator.next().?);
    try std.testing.expectEqualStrings("World", iterator.next().?);
    try std.testing.expectEqual(null, iterator.next());
}

pub const ArgCursor = struct {
    iterator: *OwnedArgIterator,
    traits: *const struct {
        cursor: *coll.Cursor([:0]const u8),
    },

    pub fn init(allocator: *const Allocator, iterator: *OwnedArgIterator) Allocator.Error!*@This() {
        var self = try allocator.create(@This());
        self.traits = try trait.newTraitTable(allocator, self, .{
            (try trait.extend(
                allocator,
                coll.Cursor([:0]const u8),
                self,
            )).new(),
        });
        self.iterator = iterator;
        return self;
    }

    pub fn destroy(self: *@This(), allocator: *const Allocator) void {
        self.iterator.deinit(allocator);
        trait.destroyTraits(allocator, self);
    }

    pub fn next(self: *@This()) ?[:0]const u8 {
        return self.iterator.next();
    }
};

fn tstArgCursor(allocator: *const Allocator, data: [:0]const u8) !*coll.Cursor([:0]const u8) {
    var ownedIter = try tstBaseArgIterator(allocator, data);
    errdefer ownedIter.deinit(allocator);
    const concrete = try ArgCursor.init(allocator, ownedIter);
    return trait.asTrait(coll.Cursor([:0]const u8), concrete);
}

test "arg cursor peek" {
    const allocator = std.testing.allocator;
    const cursor = try tstArgCursor(&allocator,
        \\Hello
        \\World
    );
    defer cursor.destroy(&allocator);

    try std.testing.expectEqualStrings("Hello", cursor.peek().?);
    try std.testing.expectEqualStrings("Hello", cursor.next().?);
    try std.testing.expectEqualStrings("World", cursor.peek().?);
    try std.testing.expectEqualStrings("World", cursor.peek().?);
    try std.testing.expectEqualStrings("World", cursor.next().?);
    try std.testing.expectEqual(null, cursor.peek());
}

test "arg cursor peek with stackItem" {
    const allocator = std.testing.allocator;
    const cursor = try tstArgCursor(&allocator, "");
    defer cursor.destroy(&allocator);

    cursor.stackItem("Hello");
    try std.testing.expectEqualStrings("Hello", cursor.peek().?);
}

pub const AtDepthArrayTokenIterator = struct {
    i: usize,
    slice: [:0]const u8,
    state: State,

    const Error = error{} || State.Error;

    const StateTag = enum {
        noop,
        inQuotes,
        inBrackets,
        inBracketsMatching,
        seekComma,
        needValue,
        ready,
    };

    const State = struct {
        tag: StateTag,
        depth: usize,
        start: usize,
        end: usize,
        earlyStop: bool,

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
            .depth = 0,
            .start = 0,
            .end = 0,
            .earlyStop = false,
        };

        fn noop(self: *State) void {
            self.* = Noop;
        }

        fn ready(self: *State, i: usize, earlyStop: bool) void {
            self.end = i;
            self.earlyStop = earlyStop;
            self.tag = .ready;
        }

        fn inBrackets(self: *State, depth: usize) void {
            self.* = .{
                .tag = .inBrackets,
                .depth = depth,
                .start = 0,
                .end = 0,
                .earlyStop = false,
            };
        }

        fn seekComma(self: *State, depth: usize) void {
            self.* = .{
                .tag = .seekComma,
                .depth = depth,
                .start = 0,
                .end = 0,
                .earlyStop = false,
            };
        }

        fn inBracketsMatching(self: *State, i: usize) void {
            self.* = .{
                .tag = .inBracketsMatching,
                .depth = 2,
                .start = i,
                .end = i + 1,
                .earlyStop = false,
            };
        }

        fn inQuotes(self: *State, i: usize) void {
            self.* = .{
                .tag = .inQuotes,
                .depth = self.depth,
                .start = i + 1,
                .end = i + 1,
                .earlyStop = false,
            };
        }

        fn needValue(self: *State) void {
            self.* = .{
                .tag = .needValue,
                .depth = 1,
                .start = 0,
                .end = 0,
                .earlyStop = false,
            };
        }

        fn resetReady(self: *State) void {
            if (self.earlyStop == true) {
                self.seekComma(self.depth);
            } else if (self.depth == 0) {
                self.noop();
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
                        .needValue, .inBrackets, .inBracketsMatching => return State.Error.EarlyArrayTermination,
                        .inQuotes => return State.Error.EarlyQuoteTermination,
                        .ready => return State.Error.ResultBlackholed,
                    }
                },
                '[' => {
                    switch (tag) {
                        .noop => self.inBrackets(1),
                        .needValue, .inBrackets, .seekComma => self.inBracketsMatching(i),
                        .inBracketsMatching => self.depth += 1,
                        .inQuotes => self.end = i,
                        .ready => return State.Error.CharBlackholed,
                    }
                },
                ']' => {
                    switch (tag) {
                        .noop => return State.Error.MissingArrayLayer,
                        .inBrackets, .seekComma => {
                            self.depth -= 1;
                            self.noop();
                        },
                        .needValue => return State.Error.EarlyArrayTermination,
                        .inBracketsMatching => {
                            self.depth -= 1;
                            if (self.depth == 0) self.ready(i, false) else self.end = i;
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
                        .inBracketsMatching => self.end = i,
                        .inQuotes => self.ready(i, true),
                        .ready => return State.Error.CharBlackholed,
                    }
                },
                ' ', '\t' => {
                    switch (tag) {
                        .noop => self.noop(),
                        .seekComma, .needValue, .inBrackets => {},
                        .inBracketsMatching => {
                            if (self.depth == 1) self.ready(i, true) else self.end = i;
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
                            if (self.depth == 1) self.ready(i, false) else self.end = i;
                        },
                        .inQuotes => self.end = i,
                        .ready => return State.Error.CharBlackholed,
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
                        .ready => return State.Error.CharBlackholed,
                    }
                },
            }
        }
    };

    pub fn init(slice: [:0]const u8) @This() {
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

fn tstCollectTokens(allocator: *const Allocator, slice: [:0]const u8) ![]const [:0]const u8 {
    var result = std.ArrayList([:0]const u8).init(allocator.*);
    var tokenizer = AtDepthArrayTokenIterator.init(slice);

    while (try tokenizer.next()) |item| {
        try result.append(try allocator.dupeZ(u8, item));
    }

    return result.toOwnedSlice();
}

test "Depth 1 Array tokenizer (non-string)" {
    const t = std.testing;
    const E = AtDepthArrayTokenIterator.Error;
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

    const expectEmpty: []const [:0]const u8 = &.{};
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

    const expectOne: []const [:0]const u8 = &.{"1"};
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

    const expectTwo: []const [:0]const u8 = &.{ "1", "1" };
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
    const E = AtDepthArrayTokenIterator.Error;
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
    const E = AtDepthArrayTokenIterator.Error;
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
    const E = AtDepthArrayTokenIterator.Error;
    _ = E;
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

    const expectMixedBracketsAndQuotes2: []const []const u8 = &.{ "['1, 2]", "[2,3']" };
    try t.expectEqualDeep(expectMixedBracketsAndQuotes2, try tstCollectTokens(allocator, "[['1, 2], [2,3']]"));
}

pub const DefaultCodec = struct {
    const Error = error{
        ParseArrayEndOfIterator,
        ParseOptEndOfIterator,
        ParseStringEndOfIterator,
        ParseEnumEndOfIterator,
        ParseFloatEndOfIterator,
        ParseIntEndOfIterator,
        ParseBoolEndOfIterator,
        InvalidEnum,
        InvalidBoolLiteral,
    } ||
        AtDepthArrayTokenIterator.Error ||
        std.fmt.ParseIntError ||
        std.fmt.ParseFloatError ||
        std.mem.Allocator.Error;

    pub const CursorT = coll.Cursor([:0]const u8);

    pub fn validateType(comptime T: type, comptime tag: @Type(.enum_literal)) void {
        comptime if (@typeInfo(T) != tag) @compileError(std.fmt.comptimePrint(
            "Type given to parse method is not {s}, it is {s}",
            .{
                @tagName(tag),
                @typeName(T),
            },
        ));
    }

    pub fn validateConcreteType(comptime T: type, comptime OtherT: type) void {
        comptime if (T != OtherT) @compileError(std.fmt.comptimePrint("Expected type {s} found {s}", .{
            @typeName(T),
            @typeName(OtherT),
        }));
    }

    pub fn parseWith(T: type) std.meta.DeclEnum(@This()) {
        return comptime switch (@typeInfo(T)) {
            .bool => .parseBool,
            .int => .parseInt,
            .float => .parseFloat,
            .pointer => |ptr| if (ptr.child == u8) .parseString else .parseArray,
            .optional => .parseOpt,
            .@"enum" => .parseEnum,
            else => @compileError(std.fmt.comptimePrint(
                "Codec: {s} - type {s} not supported by codec",
                .{
                    @typeName(@This()),
                    @typeName(T),
                },
            )),
        };
    }

    pub fn callByTag(comptime T: type, args: anytype) Error!T {
        const ArgT = @TypeOf(args);
        comptime validateType(ArgT, .@"struct");
        if (!@typeInfo(ArgT).@"struct".is_tuple) @compileError(std.fmt.comptimePrint(
            "Argument time given to callByTag is not a tuple",
            .{@typeName(ArgT)},
        ));
        // TODO: more tuple validation

        const fTag = comptime parseWith(T);

        const fArgs = switch (fTag) {
            .parseBool => .{args.@"1"},
            .parseInt, .parseFloat, .parseEnum => .{ T, args.@"1" },
            .parseString, .parseOpt, .parseArray => .{ T, args.@"0", args.@"1" },
            else => @compileError("not supported"),
        };

        return try @call(.auto, @field(@This(), @tagName(fTag)), fArgs);
    }

    pub fn parseArray(
        comptime T: type,
        allocator: *const Allocator,
        cursor: *CursorT,
    ) Error!T {
        comptime validateType(T, .pointer);

        const PtrT = @typeInfo(T).pointer;
        const ArrayT = PtrT.child;
        var ar = std.heap.ArenaAllocator.init(allocator.*);
        defer ar.deinit();
        const scrapAllocator = &ar.allocator();

        // Array generic is always one layer lower
        // Main allocator is used here to move the results outside of stack
        var array = try std.ArrayList(ArrayT).initCapacity(allocator.*, 6);
        errdefer array.deinit();

        const slice = cursor.next() orelse return Error.ParseArrayEndOfIterator;

        // Q lives in the stack and dies in the stack
        const Q = coll.SinglyLinkedQueue([:0]const u8);
        var queue = Q{};
        const queueCursor = try coll.QueueCursor([:0]const u8).init(scrapAllocator, &queue);
        defer queueCursor.destroy(scrapAllocator);

        var arrTokenizer = AtDepthArrayTokenIterator.init(slice);

        while (try arrTokenizer.next()) |token| {
            try queueCursor.queueItem(scrapAllocator, try scrapAllocator.dupeZ(u8, token));
        }

        const vCursor = trait.asTrait(CursorT, queueCursor);
        while (queueCursor.len() > 0) {
            try array.append(try callByTag(ArrayT, .{ allocator, vCursor }));
        }

        if (PtrT.sentinel()) |sentinel| {
            return array.toOwnedSliceSentinel(sentinel);
        } else {
            return array.toOwnedSlice();
        }
    }

    pub fn isNull(cursor: *CursorT) bool {
        const s = cursor.peek() orelse return false;
        return std.mem.eql(u8, "null", s);
    }

    pub fn parseOpt(
        comptime T: type,
        allocator: *const Allocator,
        cursor: *CursorT,
    ) Error!T {
        comptime validateType(T, .optional);
        const Tt = @typeInfo(T).optional.child;

        _ = cursor.peek() orelse return Error.ParseOptEndOfIterator;
        if (isNull(cursor)) {
            cursor.consume();
            return null;
        } else {
            return try callByTag(Tt, .{ allocator, cursor });
        }
    }

    pub fn parseString(
        comptime T: type,
        allocator: *const Allocator,
        cursor: *CursorT,
    ) Error!T {
        comptime validateType(T, .pointer);
        const PtrType = @typeInfo(T).pointer;
        const Tt = comptime meta.ptrTypeToChild(T);
        comptime validateConcreteType(Tt, u8);

        const s = cursor.next() orelse return Error.ParseStringEndOfIterator;
        const newPtr = try alloc: {
            if (PtrType.sentinel()) |sentinel| {
                break :alloc allocator.allocSentinel(Tt, s.len, sentinel);
            } else {
                break :alloc allocator.alloc(Tt, s.len);
            }
        };
        @memcpy(newPtr, s);
        return newPtr;
    }

    pub fn parseEnum(
        comptime T: type,
        cursor: *CursorT,
    ) Error!T {
        comptime validateType(T, .@"enum");
        const value = cursor.next() orelse return Error.ParseEnumEndOfIterator;
        return std.meta.stringToEnum(T, value) orelse Error.InvalidEnum;
    }

    pub fn parseFloat(comptime T: type, cursor: *CursorT) Error!T {
        comptime validateType(T, .float);
        const value = cursor.next() orelse return Error.ParseFloatEndOfIterator;
        return try std.fmt.parseFloat(T, value);
    }

    pub fn parseInt(comptime T: type, cursor: *CursorT) Error!T {
        comptime validateType(T, .int);
        const value = cursor.next() orelse return Error.ParseIntEndOfIterator;
        return try std.fmt.parseInt(T, value, 10);
    }

    pub fn parseBool(cursor: *CursorT) Error!bool {
        const value = cursor.next() orelse return Error.ParseBoolEndOfIterator;
        return result: switch (value.len) {
            4 => {
                break :result if (std.mem.eql(u8, "true", value)) true else Error.InvalidBoolLiteral;
            },
            5 => {
                break :result if (std.mem.eql(u8, "false", value)) false else Error.InvalidBoolLiteral;
            },
            else => Error.InvalidBoolLiteral,
        };
    }
};

pub fn Codec(Spec: type) type {
    return struct {
        pub fn init() @This() {
            return .{};
        }

        const Error = DefaultCodec.Error;
        const CursorT = DefaultCodec.CursorT;
        const SpecFieldEnum = std.meta.FieldEnum(Spec);

        pub fn CodecOf(tag: SpecFieldEnum, tTag: @Type(.enum_literal)) type {
            comptime if (tTag != .pointer) {
                const T = meta.LeafTypeOfTag(Spec, @tagName(tag));
                return if (@typeInfo(T) == tTag) T else @compileError(std.fmt.comptimePrint(
                    "Codec: {s}, Field: {s} - codec choice of {s} doesnt match field type",
                    .{ @typeName(@This()), @tagName(tag), @typeName(T) },
                ));
            } else {
                const T = meta.LeafArrayTypeOfTag(Spec, @tagName(tag));
                return if (@typeInfo(T) == tTag) T else @compileError(std.fmt.comptimePrint(
                    "Codec: {s}, Field: {s} - codec choice of {s} doesnt match field type",
                    .{ @typeName(@This()), @tagName(tag), @typeName(T) },
                ));
            };
        }

        /// This is not an instance method and that's on purpose, this needs evaluation 100% at comptime
        pub fn parseWith(comptime tag: SpecFieldEnum) std.meta.DeclEnum(@This()) {
            const FieldType = @FieldType(Spec, @tagName(tag));
            return switch (@typeInfo(FieldType)) {
                .bool => .parseFlag,
                else => result: {
                    const fTag = @tagName(DefaultCodec.parseWith(FieldType));
                    break :result std.meta.stringToEnum(
                        std.meta.DeclEnum(@This()),
                        @tagName(DefaultCodec.parseWith(FieldType)),
                    ) orelse @compileError(std.fmt.comptimePrint(
                        "Type of {s}, parsed with {s} is not available in interface codec",
                        .{ @typeName(FieldType), fTag },
                    ));
                },
            };
        }

        pub fn parseArray(
            self: *const @This(),
            comptime tag: SpecFieldEnum,
            allocator: *const Allocator,
            cursor: *CursorT,
        ) Error!meta.OptTypeOf(@FieldType(Spec, @tagName(tag))) {
            _ = self;
            return try DefaultCodec.parseArray(
                meta.OptTypeOf(@FieldType(Spec, @tagName(tag))),
                allocator,
                cursor,
            );
        }

        pub fn parseOpt(
            self: *const @This(),
            comptime tag: std.meta.FieldEnum(Spec),
            allocator: *const Allocator,
            cursor: *CursorT,
        ) Error!@FieldType(Spec, @tagName(tag)) {
            const tagT = @FieldType(Spec, @tagName(tag));
            return if (comptime @typeInfo(tagT).optional.child == bool)
                if (DefaultCodec.isNull(cursor)) null else try self.parseFlag(
                    tag,
                    allocator,
                    cursor,
                )
            else
                try DefaultCodec.parseOpt(
                    tagT,
                    allocator,
                    cursor,
                );
        }

        pub fn parseString(
            self: *const @This(),
            comptime tag: std.meta.FieldEnum(Spec),
            allocator: *const Allocator,
            cursor: *CursorT,
        ) Error!CodecOf(tag, .pointer) {
            _ = self;
            return try DefaultCodec.parseString(
                CodecOf(tag, .pointer),
                allocator,
                cursor,
            );
        }

        pub fn parseEnum(
            self: *const @This(),
            comptime tag: SpecFieldEnum,
            allocator: *const Allocator,
            cursor: *CursorT,
        ) Error!CodecOf(tag, .@"enum") {
            _ = self;
            _ = allocator;
            return try DefaultCodec.parseEnum(
                CodecOf(tag, .@"enum"),
                cursor,
            );
        }

        pub fn parseFloat(
            self: *const @This(),
            comptime tag: std.meta.FieldEnum(Spec),
            allocator: *const Allocator,
            cursor: *CursorT,
        ) Error!CodecOf(tag, .float) {
            _ = self;
            _ = allocator;
            return try DefaultCodec.parseFloat(
                CodecOf(tag, .float),
                cursor,
            );
        }

        pub fn parseInt(
            self: *const @This(),
            comptime tag: SpecFieldEnum,
            allocator: *const Allocator,
            cursor: *CursorT,
        ) Error!CodecOf(tag, .int) {
            _ = self;
            _ = allocator;
            return try DefaultCodec.parseInt(
                CodecOf(tag, .int),
                cursor,
            );
        }

        pub fn parseBool(
            self: *const @This(),
            comptime tag: SpecFieldEnum,
            allocator: *const Allocator,
            cursor: *CursorT,
        ) Error!bool {
            _ = self;
            _ = allocator;
            _ = tag;
            return try DefaultCodec.parseBool(cursor);
        }

        pub fn parseFlag(
            self: *const @This(),
            comptime tag: SpecFieldEnum,
            allocator: *const Allocator,
            cursor: *CursorT,
        ) Error!bool {
            _ = self;
            _ = allocator;
            _ = tag;
            const value = cursor.peek() orelse return true;
            return switch (value.len) {
                4 => if (std.mem.eql(u8, "true", value)) consume: {
                    cursor.consume();
                    break :consume true;
                    // INFO: this looks dumb, but the purpose is not to consume the iterator
                    // only when it was explicitly said to be true
                } else true,
                5 => if (std.mem.eql(u8, "false", value)) consume: {
                    cursor.consume();
                    break :consume false;
                } else true,
                else => true,
            };
        }
    };
}

test "codec parseArray" {
    const baseAllocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(baseAllocator);
    defer arena.deinit();
    const allocator = &arena.allocator();
    const cursor = try tstArgCursor(allocator,
        \\"[false, true]"
        \\"[1, -1]"
        \\"[1.1, -2.2]"
        \\"['a', 'b']"
        \\"['c', 'd']"
        \\"[[3]]"
        \\"[small, medium, large]"
        \\"[false, null]"
        \\"[[false, null]]"
        \\"[[false, null], null]"
        \\"[[null, true, null], [false], null]"
        \\"[]"
        \\"[[]]"
    );
    defer cursor.destroy(allocator);
    const Spec = struct {
        b: []const bool,
        i: []const i32,
        f: []const f32,
        s: []const []const u8,
        sz: []const [:0]const u8,
        ad: []const []const i32,
        e: []const Size,
        b2: []const ?bool,
        b3: []const []const ?bool,
        b4: []const ?[]const ?bool,
        b5: ?[]const ?[]const ?bool,
        b6: ?[]const []bool,
        b7: ?[]const []bool,

        const Size = enum {
            small,
            medium,
            large,
        };
    };
    const codec = Codec(Spec).init();
    const expectBA: []const bool = &.{ false, true };
    try std.testing.expectEqualDeep(expectBA, try codec.parseArray(.b, allocator, cursor));
    const expectIA: []const i32 = &.{ 1, -1 };
    try std.testing.expectEqualDeep(expectIA, try codec.parseArray(.i, allocator, cursor));
    const expectFA: []const f32 = &.{ 1.1, -2.2 };
    try std.testing.expectEqualDeep(expectFA, try codec.parseArray(.f, allocator, cursor));
    const expectSA: []const []const u8 = &.{ "a", "b" };
    try std.testing.expectEqualDeep(expectSA, try codec.parseArray(.s, allocator, cursor));
    const expectSZ: []const [:0]const u8 = &.{ "c", "d" };
    try std.testing.expectEqualDeep(expectSZ, try codec.parseArray(.sz, allocator, cursor));
    const expectAD: []const [:0]const i32 = &.{&.{3}};
    try std.testing.expectEqualDeep(expectAD, try codec.parseArray(.ad, allocator, cursor));
    const expectED: []const Spec.Size = &.{ .small, .medium, .large };
    try std.testing.expectEqualDeep(expectED, try codec.parseArray(.e, allocator, cursor));
    const expectB2: []const ?bool = &.{ false, null };
    try std.testing.expectEqualDeep(expectB2, try codec.parseArray(.b2, allocator, cursor));
    const expectB3: []const []const ?bool = &.{&.{ false, null }};
    try std.testing.expectEqualDeep(expectB3, try codec.parseArray(.b3, allocator, cursor));
    const expectB4: []const ?[]const ?bool = &.{ &.{ false, null }, null };
    try std.testing.expectEqualDeep(expectB4, try codec.parseArray(.b4, allocator, cursor));

    // Those are really Opt recursive tests
    const expectB5: ?[]const ?[]const ?bool = &.{ &.{ null, true, null }, &.{false}, null };
    try std.testing.expectEqualDeep(expectB5, try codec.parseArray(.b5, allocator, cursor));
    const expectB6: ?[]const []bool = &.{};
    try std.testing.expectEqualDeep(expectB6, try codec.parseArray(.b6, allocator, cursor));
    const expectB7: ?[]const []bool = &.{&.{}};
    try std.testing.expectEqualDeep(expectB7, try codec.parseArray(.b7, allocator, cursor));
    try std.testing.expectError(
        @TypeOf(codec).Error.ParseArrayEndOfIterator,
        codec.parseArray(.b7, allocator, cursor),
    );
}

test "codec parseOpt" {
    const allocator = &std.testing.allocator;
    const cursor = try tstArgCursor(allocator,
        \\null
        \\1
    );
    defer cursor.destroy(allocator);
    const codec = Codec(struct { a1: ?f32 }).init();
    try std.testing.expectEqual(null, try codec.parseOpt(.a1, allocator, cursor));
    try std.testing.expectEqual(1, (try codec.parseOpt(.a1, allocator, cursor)).?);
    cursor.consume();
    try std.testing.expectError(
        @TypeOf(codec).Error.ParseOptEndOfIterator,
        codec.parseOpt(.a1, allocator, cursor),
    );
}

test "codec parseString" {
    const baseAllocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(baseAllocator);
    defer arena.deinit();
    const allocator = &arena.allocator();
    const cursor = try tstArgCursor(allocator,
        \\hello
        \\world
    );
    defer cursor.destroy(allocator);
    const codec = Codec(struct { s1: []const u8, s2: [:0]const u8 }).init();
    try std.testing.expectEqualDeep("hello", try codec.parseString(.s1, allocator, cursor));
    try std.testing.expectEqualDeep("world", try codec.parseString(.s2, allocator, cursor));
    try std.testing.expectError(
        @TypeOf(codec).Error.ParseStringEndOfIterator,
        codec.parseString(.s2, allocator, cursor),
    );
}

test "codec parseEnum" {
    const baseAllocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(baseAllocator);
    defer arena.deinit();
    const allocator = &arena.allocator();
    const cursor = try tstArgCursor(allocator,
        \\small
        \\medium
        \\large
        \\invalid
    );
    defer cursor.destroy(allocator);
    const Spec = struct {
        size: Size,

        const Size = enum {
            small,
            medium,
            large,
        };
    };
    const codec = Codec(Spec).init();
    try std.testing.expectEqual(Spec.Size.small, try codec.parseEnum(.size, allocator, cursor));
    try std.testing.expectEqual(Spec.Size.medium, try codec.parseEnum(.size, allocator, cursor));
    try std.testing.expectEqual(Spec.Size.large, try codec.parseEnum(.size, allocator, cursor));
    try std.testing.expectError(
        @TypeOf(codec).Error.InvalidEnum,
        codec.parseEnum(.size, allocator, cursor),
    );
    try std.testing.expectError(
        @TypeOf(codec).Error.ParseEnumEndOfIterator,
        codec.parseEnum(.size, allocator, cursor),
    );
}

test "codec parseFloat" {
    const allocator = &std.testing.allocator;
    const cursor = try tstArgCursor(allocator,
        \\44
        \\-1.2
        \\32.2222
    );
    defer cursor.destroy(allocator);
    const codec = Codec(struct { f1: f32, f2: f64 }).init();
    try std.testing.expectEqual(44.0, try codec.parseFloat(.f1, allocator, cursor));
    try std.testing.expectEqual(-1.2, try codec.parseFloat(.f2, allocator, cursor));
    try std.testing.expectEqual(32.2222, try codec.parseFloat(.f1, allocator, cursor));
    try std.testing.expectError(
        @TypeOf(codec).Error.ParseFloatEndOfIterator,
        codec.parseFloat(.f1, allocator, cursor),
    );
}

test "codec parseInt" {
    const allocator = &std.testing.allocator;
    const cursor = try tstArgCursor(allocator,
        \\44
        \\-1
        \\25
    );
    defer cursor.destroy(allocator);
    const codec = Codec(struct { n1: u6, n2: i2, n3: u88 }).init();
    try std.testing.expectEqual(44, try codec.parseInt(.n1, allocator, cursor));
    try std.testing.expectEqual(-1, try codec.parseInt(.n2, allocator, cursor));
    try std.testing.expectEqual(25, try codec.parseInt(.n3, allocator, cursor));
    try std.testing.expectError(
        @TypeOf(codec).Error.ParseIntEndOfIterator,
        codec.parseInt(.n3, allocator, cursor),
    );
}

test "codec parseBool" {
    const allocator = &std.testing.allocator;
    const cursor = try tstArgCursor(allocator,
        \\true
        \\false
    );
    defer cursor.destroy(allocator);
    const codec = Codec(struct { b1: bool }).init();
    try std.testing.expectEqual(true, try codec.parseBool(.b1, allocator, cursor));
    try std.testing.expectEqual(false, try codec.parseBool(.b1, allocator, cursor));
    try std.testing.expectError(
        @TypeOf(codec).Error.ParseBoolEndOfIterator,
        codec.parseBool(.b1, allocator, cursor),
    );
}

test "codec parseFlag" {
    const allocator = &std.testing.allocator;
    const cursor = try tstArgCursor(allocator,
        \\true
        \\false
        \\"something else"
        \\1234
        \\12345
    );
    defer cursor.destroy(allocator);

    const codec = Codec(struct { @"test": bool }).init();
    try std.testing.expect(try codec.parseFlag(.@"test", allocator, cursor));
    try std.testing.expectEqualDeep(null, cursor.curr);

    try std.testing.expect(!try codec.parseFlag(.@"test", allocator, cursor));
    try std.testing.expectEqual(null, cursor.curr);

    try std.testing.expect(try codec.parseFlag(.@"test", allocator, cursor));
    try std.testing.expectEqualStrings("something else", cursor.curr.?);

    // 4 letter guess
    _ = cursor.next();
    try std.testing.expect(try codec.parseFlag(.@"test", allocator, cursor));
    try std.testing.expectEqualStrings("1234", cursor.curr.?);

    // 5 letter guess
    _ = cursor.next();
    try std.testing.expect(try codec.parseFlag(.@"test", allocator, cursor));
    try std.testing.expectEqualStrings("12345", cursor.curr.?);

    // null check
    _ = cursor.next();
    try std.testing.expect(try codec.parseFlag(.@"test", allocator, cursor));
    try std.testing.expectEqual(null, cursor.curr);
}

pub fn SpecResponse(comptime Spec: type) type {
    // TODO: validate spec

    return struct {
        arena: std.heap.ArenaAllocator,
        codec: SpecCodec,
        program: ?[:0]const u8,
        // TODO: move const
        options: Options,
        // TODO: Move to tuple inside Spec, leverage codec
        positionals: [][:0]const u8,
        // TODO: optional error collection
        // TODO: better get
        verb: if (@hasDecl(Spec, "Verb")) ?VerbT else void,
        const Options = Spec;

        fn UnionVerbs() type {
            const Uni = @typeInfo(Spec.Verb).@"union";
            comptime var newFields: [Uni.fields.len]std.builtin.Type.UnionField = undefined;
            for (Uni.fields, 0..) |f, i| {
                const newSpecR = *const SpecResponse(f.type);
                newFields[i] = .{
                    .name = f.name,
                    .type = newSpecR,
                    .alignment = @alignOf(newSpecR),
                };
            }
            const newUni: std.builtin.Type = .{ .@"union" = .{
                .layout = Uni.layout,
                .tag_type = Uni.tag_type,
                .fields = &newFields,
                .decls = Uni.decls,
            } };
            return @Type(newUni);
        }

        const VerbT = if (@hasDecl(Spec, "Verb")) UnionVerbs() else void;
        const CursorT = coll.Cursor([:0]const u8);
        const SpecCodec = if (@hasDecl(Spec, "Codec")) Spec.Codec else Codec(Spec);

        const Error = error{
            UnknownArgumentName,
            InvalidArgumentToken,
            MissingShorthandMetadata,
            MissingShorthandLink,
            UnknownShorthandName,
            ArgEqualSplitMissingValue,
            ArgEqualSplitNotConsumed,
            CodecParseMethodUnavailable,
        } || std.mem.Allocator.Error || SpecCodec.Error;

        pub fn init(allc: *const Allocator, codec: SpecCodec) !*@This() {
            var arena = std.heap.ArenaAllocator.init(allc.*);
            const allocator = arena.allocator();
            var self = try allocator.create(@This());
            self.arena = arena;
            self.codec = codec;
            self.options = Spec{};
            self.program = null;
            self.positionals = undefined;
            if (comptime @hasDecl(Spec, "Verb")) {
                self.verb = null;
            }
            return self;
        }

        // TODO: test all error returns
        pub fn parse(self: *@This(), cursor: *CursorT) Error!void {
            try self.parseInner(cursor, true);
        }

        fn parseInner(self: *@This(), cursor: *CursorT, comptime parseProgram: bool) Error!void {
            const allocator = self.arena.allocator();

            if (comptime parseProgram) {
                self.program = if (cursor.next()) |program|
                    try allocator.dupeZ(u8, program)
                else
                    return;
            } else {
                _ = cursor.peek() orelse return;
            }

            var positionals = try std.ArrayList([:0]const u8).initCapacity(allocator, 32);

            while (cursor.next()) |arg|
                if (arg.len == 1 and arg[0] == '-') {
                    // single -
                    try positionals.append("-");
                    continue;
                } else if (arg.len == 2 and std.mem.eql(u8, "--", arg)) {
                    // -- positional skip
                    break;
                } else if (arg.len >= 1 and arg[0] != '-') {
                    // word, feed to positional
                    cursor.stackItem(arg);
                    break;
                } else if (arg.len == 0) {
                    // This is technically not possible with ArgIterator
                    continue;
                } else {
                    var offset: usize = 1;
                    if (arg[1] == '-') offset += 1;
                    try self.namedToken(offset, arg, cursor);
                };

            // drain remaining args
            // TODO: parse tuple
            while (cursor.next()) |item| {
                try positionals.append(try allocator.dupeZ(u8, item));
            }
            if (positionals.items.len > 0) {
                if (@hasDecl(Spec, "Verb")) {
                    cursor.stackItem(positionals.items[0]);
                    const Uni = @typeInfo(Spec.Verb).@"union";
                    const e = DefaultCodec.parseEnum(Uni.tag_type.?, cursor) catch null;
                    if (e) |ex| {
                        std.debug.print("Verb: {s}", .{@tagName(ex)});
                        inline for (Uni.fields) |f| {
                            if (std.mem.eql(u8, f.name, @tagName(ex))) {
                                const verbR = try SpecResponse(f.type).init(&allocator, Codec(f.type).init());

                                const unmanaged = positionals.moveToUnmanaged();
                                const vCursor = try coll.ArrayCursor([:0]const u8).init(&allocator, unmanaged.items, 1);

                                try verbR.parseInner(trait.asTrait(CursorT, vCursor), false);
                                self.verb = @unionInit(VerbT, f.name, verbR);

                                break;
                            }
                        }
                    }
                }
            }
            self.positionals = try positionals.toOwnedSlice();
        }

        fn namedToken(self: *@This(), offset: usize, arg: [:0]const u8, cursor: *CursorT) Error!void {
            var splitValue: ?[:0]u8 = null;
            var slice: []const u8 = arg[offset..];
            const optValueIdx = std.mem.indexOf(u8, slice, "=");

            // Feed split arg to buffer
            if (optValueIdx) |i| {
                // TODO: should this sanitize the sliced arg?
                if (i + 1 >= arg.len) return Error.ArgEqualSplitMissingValue;
                const newValue = try self.arena.allocator().allocSentinel(u8, slice.len - i - 1, 0);
                @memcpy(newValue, slice[i + 1 ..]);
                cursor.stackItem(newValue);
                splitValue = newValue;
                slice = slice[0..i];
            }
            errdefer if (splitValue) |v| self.arena.allocator().free(v);

            try switch (offset) {
                2 => self.namedArg(slice, cursor),
                1 => self.shortArg(slice, cursor),
                else => Error.InvalidArgumentToken,
            };

            // if split not consumed, it's not sane to progress
            if (splitValue) |v| {
                const peekR: [*]const u8 = @ptrCast(cursor.peek() orelse return);
                if (peekR == @as([*]u8, @ptrCast(v))) return Error.ArgEqualSplitNotConsumed;
            }
        }

        // TODO: re-feed chain of flags, enforce max n chars for shorthand
        fn shortArg(self: *@This(), arg: []const u8, cursor: *CursorT) Error!void {
            if (@typeInfo(FieldEnum(Spec)).@"enum".fields.len == 0) return Error.UnknownArgumentName;
            if (!@hasDecl(Spec, "Short")) return Error.MissingShorthandMetadata;

            // This provides isolation between shorthands and next args until last arg
            var arena = std.heap.ArenaAllocator.init(self.arena.allocator());
            const scrapAllocator = &arena.allocator();
            const unit = try coll.UnitCursor([:0]const u8).init(scrapAllocator, null);
            defer unit.destroy(scrapAllocator);
            var vCursor = trait.asTrait(CursorT, unit);

            var start: usize = 0;
            var end: usize = @min(2, arg.len);
            while (end <= arg.len) {
                if (end == arg.len) vCursor = cursor;
                ret: inline for (std.meta.fields(@TypeOf(Spec.Short))) |s| {
                    if (std.mem.eql(u8, s.name, arg[start..end])) {
                        const tag = s.defaultValue() orelse return Error.MissingShorthandLink;
                        try self.namedArg(tag, vCursor);
                        start = end;
                        break :ret;
                    }
                } else if (end - start == 1) {
                    return Error.UnknownShorthandName;
                }

                if (start == end and end == arg.len) return else if (end - start == 0)
                    end = @min(end + 2, arg.len)
                else
                    end -= 1;
            }
        }

        fn namedArg(self: *@This(), arg: []const u8, cursor: *CursorT) Error!void {
            @setEvalBranchQuota(1000000);
            const SpecEnum = FieldEnum(Spec);
            const fields = @typeInfo(SpecEnum).@"enum".fields;
            if (fields.len == 0) return Error.UnknownArgumentName;

            inline for (fields) |f| {
                // This gives me a comptime-value for name
                if (std.mem.eql(u8, f.name, arg)) {
                    const spectag = comptime (std.meta.stringToEnum(SpecEnum, f.name) orelse @compileError(std.fmt.comptimePrint(
                        "Spec: {s}, Field: {s} - could no translate field to tag",
                        .{ @typeName(Spec), f.name },
                    )));
                    const codecFTag = comptime SpecCodec.parseWith(spectag);

                    var allocator = self.arena.allocator();
                    // TODO: handle required and optional
                    const r = try @call(.auto, @field(SpecCodec, @tagName(codecFTag)), .{ &self.codec, spectag, &allocator, cursor });

                    @field(self.options, f.name) = r;
                    return;
                }
            } else {
                return Error.UnknownArgumentName;
            }
        }

        pub fn deinit(self: *const @This()) void {
            self.arena.deinit();
        }
    };
}

pub fn tstParseSpec(allocator: *const Allocator, cursor: *coll.Cursor([:0]const u8), Spec: type) !*const SpecResponse(Spec) {
    var response = try SpecResponse(Spec).init(allocator, Codec(Spec).init());
    errdefer response.deinit();
    try response.parse(cursor);
    return response;
}

fn tstParse(data: [:0]const u8, Spec: type) !*const SpecResponse(Spec) {
    const allocator = &std.testing.allocator;
    const cursor = try tstArgCursor(allocator, data);
    defer cursor.destroy(allocator);
    return try tstParseSpec(allocator, cursor, Spec);
}

test "empty args with default" {
    const r = try tstParse("", struct {
        flag: bool = false,
    });
    defer r.deinit();
    try std.testing.expectEqual(null, r.program);
    try std.testing.expectEqual(false, r.options.flag);
}

test "program only" {
    const r = try tstParse("program", struct {});
    defer r.deinit();
    try std.testing.expectEqualStrings("program", r.program.?);
}

test "parse named" {
    const r = try tstParse("program --cool-flag", struct { @"cool-flag": bool = false });
    defer r.deinit();
    const r2 = try tstParse("program --cool-flag true", struct { @"cool-flag": bool = false });
    defer r2.deinit();
    const r3 = try tstParse("program --cool-flag false", struct { @"cool-flag": bool = false });
    defer r3.deinit();
    const r4 = try tstParse("program --cool-flag something else", struct { @"cool-flag": bool = false });
    defer r4.deinit();

    try std.testing.expectEqual(true, r.options.@"cool-flag");
    try std.testing.expectEqual(true, r2.options.@"cool-flag");
    try std.testing.expectEqual(false, r3.options.@"cool-flag");
    try std.testing.expectEqual(true, r4.options.@"cool-flag");
    const expected: []const []const u8 = &.{ "something", "else" };
    try std.testing.expectEqualDeep(expected, r4.positionals);
}

test "parsed chained flags" {
    const Spec = struct {
        t1: ?bool = null,
        t2: ?bool = null,
        t3: ?bool = null,
        t4: ?bool = null,
        t5: ?bool = null,

        pub const Short = .{
            .a = "t1",
            .aA = "t2",
            .b = "t3",
            .Ss = "t4",
            .c = "t5",
        };
    };
    const r1 = try tstParse("program -aaAbSsc=false", Spec);
    defer r1.deinit();
    try std.testing.expect(r1.options.t1.?);
    try std.testing.expect(r1.options.t2.?);
    try std.testing.expect(r1.options.t3.?);
    try std.testing.expect(r1.options.t4.?);
    try std.testing.expect(!r1.options.t5.?);
}

test "parse short arg" {
    const Spec = struct {
        something: bool = false,
        @"super-something": bool = false,

        const Short = .{
            .s = "something",
            .S = "super-something",
        };
    };
    const r1 = try tstParse("program -s --super-something true", Spec);
    defer r1.deinit();
    const r2 = try tstParse("program --something false -S", Spec);
    defer r2.deinit();
    const r3 = try tstParse("program -s false -S false", Spec);
    defer r3.deinit();
    const r4 = try tstParse("program -s true -S true", Spec);
    defer r4.deinit();

    try std.testing.expectEqual(true, r1.options.something);
    try std.testing.expectEqual(true, r1.options.@"super-something");
    try std.testing.expectEqual(false, r2.options.something);
    try std.testing.expectEqual(true, r2.options.@"super-something");
    try std.testing.expectEqual(false, r3.options.something);
    try std.testing.expectEqual(false, r3.options.@"super-something");
    try std.testing.expectEqual(true, r4.options.something);
    try std.testing.expectEqual(true, r4.options.@"super-something");
}

test "parse different types" {
    const Spec = struct {
        o1: ?bool = null,
        u1: ?u1 = null,
        f1: ?f16 = null,
        b: ?bool = null,
        e: ?Animal = null,
        s1: ?[]const u8 = null,
        s2: ?[:0]const u8 = null,
        au1: ?[]const u1 = null,
        au32: ?[]const u32 = null,
        ai32: ?[]const i32 = null,
        af32: ?[]const f32 = null,
        as1: ?[]const []const u8 = null,
        as2: ?[]const [:0]const u8 = null,
        aau32: ?[]const []const u32 = null,
        aaf32: ?[]const []const f32 = null,
        aai32: ?[]const []const i32 = null,
        aab: ?[]const []const bool = null,
        ae: ?[]const Animal = null,
        o2: ?bool = null,

        pub const Animal = enum { dog, cat };
    };

    const r1 = try tstParse(
        \\program
        \\--o1
        \\--u1=0
        \\--f1 1.1
        \\--b false
        \\--e dog
        \\--s1 Hello
        \\--s2 "Hello World"
        \\--au1 [1,0,1,0]
        \\--au32=[32,23,133,99,10]
        \\--ai32 "[-1, -44, 22222   ,   -1]"
        \\--af32="[    3.4   , 58,   3.1  ]"
        \\--as1 "['Hello', ' World ', '!']"
        \\--as2="[  'Im'  ,  'Losing it'  ]"
        \\--aau32 "[[1,3], [3300, 222, 333, 33], [1]]"
        \\--aaf32 "[  [  1.1,  3.2,-1] ,   [3.1  ,2,5], [ 1.2 ], [7.1]   ]"
        \\--aai32 "[  [  -1] ,   [2, -2] ]"
        \\--aab="[[true, true, false], [false, true]]"
        \\--ae "[cat, cat]"
        \\--o2
    ,
        Spec,
    );
    defer r1.deinit();

    try std.testing.expect(r1.options.o1.?);
    try std.testing.expectEqual(0, r1.options.u1.?);
    try std.testing.expectEqual(1.1, r1.options.f1.?);
    try std.testing.expect(!r1.options.b.?);
    try std.testing.expectEqual(Spec.Animal.dog, r1.options.e.?);
    try std.testing.expectEqualStrings("Hello", r1.options.s1.?);
    try std.testing.expectEqualStrings("Hello World", r1.options.s2.?);
    try std.testing.expectEqualDeep(&[_]u1{ 1, 0, 1, 0 }, r1.options.au1.?);
    try std.testing.expectEqualDeep(&[_]u32{ 32, 23, 133, 99, 10 }, r1.options.au32.?);
    try std.testing.expectEqualDeep(&[_]i32{ -1, -44, 22222, -1 }, r1.options.ai32.?);
    const expectedAs1: []const []const u8 = &.{ "Hello", " World ", "!" };
    try std.testing.expectEqualDeep(expectedAs1, r1.options.as1.?);
    const expectedAs2: []const [:0]const u8 = &.{ "Im", "Losing it" };
    try std.testing.expectEqualDeep(expectedAs2, r1.options.as2.?);
    const expectedAau32: []const [:0]const u32 = &.{ &.{ 1, 3 }, &.{ 3300, 222, 333, 33 }, &.{1} };
    try std.testing.expectEqualDeep(expectedAau32, r1.options.aau32.?);
    const expectedAaf32: []const []const f32 = &.{ &.{ 1.1, 3.2, -1 }, &.{ 3.1, 2, 5 }, &.{1.2}, &.{7.1} };
    try std.testing.expectEqualDeep(expectedAaf32, r1.options.aaf32.?);
    const expectedAai32: []const []const i32 = &.{ &.{-1}, &.{ 2, -2 } };
    try std.testing.expectEqualDeep(expectedAai32, r1.options.aai32.?);
    const expectAab: []const []const bool = &.{ &.{ true, true, false }, &.{ false, true } };
    try std.testing.expectEqualDeep(expectAab, r1.options.aab.?);
    try std.testing.expectEqualDeep(&[_]Spec.Animal{ .cat, .cat }, r1.options.ae.?);
    try std.testing.expect(r1.options.o2.?);
}

test "parse kvargs" {
    const Spec = struct {
        something: bool = false,
        @"super-something": bool = false,

        const Short = .{
            .s = "something",
            .S = "super-something",
        };
    };

    const r1 = try tstParse("program -s=true --super-something=true", Spec);
    defer r1.deinit();

    try std.testing.expectEqual(true, r1.options.something);
    try std.testing.expectEqual(true, r1.options.@"super-something");
}

test "parse positionals" {
    const r1 = try tstParse("program positional1 positional2 positional3", struct {});
    defer r1.deinit();
    const r2 = try tstParse("program --test positional1 positional2 positional3", struct { @"test": bool = false });
    defer r2.deinit();
    const r3 = try tstParse("program -- --test positional1 positional2 positional3", struct { @"test": bool = false });
    defer r3.deinit();

    try std.testing.expect(r2.options.@"test");
    try std.testing.expect(!r3.options.@"test");

    const expectedPositionals: []const [:0]const u8 = &.{ "positional1", "positional2", "positional3" };
    try std.testing.expectEqualDeep(expectedPositionals, r1.positionals);
    try std.testing.expectEqualDeep(expectedPositionals, r2.positionals);

    const expectSkip: []const [:0]const u8 = &.{ "--test", "positional1", "positional2", "positional3" };
    try std.testing.expectEqualDeep(expectSkip, r3.positionals);
}

test "parse verb" {
    const Spec = struct {
        verbose: ?bool = null,

        pub const Copy = struct {
            src: ?[]const u8 = null,
        };

        pub const Paste = struct {
            target: ?[]const u8 = null,
        };

        pub const Verb = union(enum) {
            copy: Copy,
            paste: Paste,
        };
    };
    const r1 = try tstParse("program copy --src file1", Spec);
    defer r1.deinit();
    const r2 = try tstParse("program paste --target file2", Spec);
    defer r2.deinit();
    const r3 = try tstParse("program --verbose false copy --src file3", Spec);
    defer r3.deinit();
    const r4 = try tstParse("program --verbose true paste --target file4", Spec);
    defer r4.deinit();
    const r5 = try tstParse("program --verbose true paste --target file4 positional1", Spec);
    defer r5.deinit();

    try std.testing.expectEqual(Spec.Copy, @TypeOf(r1.verb.?.copy.options));
    try std.testing.expectEqualStrings("file1", r1.verb.?.copy.options.src.?);
    try std.testing.expectEqual(null, r1.options.verbose);
    try std.testing.expectEqual(Spec.Paste, @TypeOf(r2.verb.?.paste.options));
    try std.testing.expectEqualStrings("file2", r2.verb.?.paste.options.target.?);
    try std.testing.expectEqual(null, r2.options.verbose);
    try std.testing.expectEqual(Spec.Copy, @TypeOf(r3.verb.?.copy.options));
    try std.testing.expectEqualStrings("file3", r3.verb.?.copy.options.src.?);
    try std.testing.expectEqual(false, r3.options.verbose.?);
    try std.testing.expectEqual(Spec.Paste, @TypeOf(r4.verb.?.paste.options));
    try std.testing.expectEqualStrings("file4", r4.verb.?.paste.options.target.?);
    try std.testing.expectEqual(true, r4.options.verbose.?);
    try std.testing.expectEqual(Spec.Paste, @TypeOf(r5.verb.?.paste.options));
    try std.testing.expectEqualStrings("file4", r5.verb.?.paste.options.target.?);
    try std.testing.expectEqual(true, r5.options.verbose.?);
    const expected: []const [:0]const u8 = &.{"positional1"};
    try std.testing.expectEqualDeep(expected, r5.verb.?.paste.positionals);
}
