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
        seekCommaQuotes,
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

        fn seekCommaQuotes(self: *State) void {
            self.* = .{
                .tag = .seekCommaQuotes,
                .depth = self.depth,
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
                        .noop, .seekComma, .seekCommaQuotes => {
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
                        .seekCommaQuotes => return State.Error.MissingCommaSeparator,
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
                        .seekCommaQuotes => {
                            if (self.depth == 0) return State.Error.MissingArrayLayer;
                            self.depth -= 1;
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
                        .seekComma, .seekCommaQuotes => return State.Error.MissingCommaSeparator,
                        .needValue => self.inQuotes(i),
                        .inBracketsMatching => self.end = i,
                        .inQuotes => self.ready(i, true),
                        .ready => return State.Error.CharBlackholed,
                    }
                },
                ' ', '\t' => {
                    switch (tag) {
                        .noop => self.noop(),
                        .seekComma, .needValue, .inBrackets, .seekCommaQuotes => {},
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
                        .seekCommaQuotes => self.inBrackets(self.depth),
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
                        .seekComma, .seekCommaQuotes => return State.Error.MissingCommaSeparator,
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

test "arg cursor peek with stackItem" {
    const allocator = std.testing.allocator;
    const cursor = try tstArgCursor(&allocator, "");
    defer cursor.destroy(&allocator);

    cursor.stackItem("Hello");
    try std.testing.expectEqualStrings("Hello", cursor.peek().?);
}

// TODO: split error per operation, glue them together later recursively
const CodecError = error{
    ParseIntEndOfIterator,
    ParseFloatEndOfIterator,
    ParseStringEndOfIterator,
    ParseArrayEndOfIterator,
} ||
    AtDepthArrayTokenIterator.Error ||
    std.fmt.ParseIntError ||
    std.fmt.ParseFloatError ||
    std.mem.Allocator.Error;

pub fn Codec(Spec: type) type {
    return struct {
        pub fn init() @This() {
            return .{};
        }

        const CursorT = coll.Cursor([:0]const u8);
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
            const name = @tagName(tag);
            const FieldType = @FieldType(Spec, @tagName(tag));
            return refeed: switch (@typeInfo(FieldType)) {
                .bool => .parseBool,
                .int => .parseInt,
                .float => .parseFloat,
                .@"enum" => @compileError("Enum not supported yet"),
                .pointer => |ptr| ptrReturn: {
                    // TODO: add meta tag to treat u8 as any other numberic array for parsing
                    if (ptr.child == u8) break :ptrReturn .parseString;
                    // if (ptr.child == []const u8) break :ptrReturn .parseArray;

                    break :ptrReturn arrayRefeed: switch (@typeInfo(ptr.child)) {
                        .bool, .int, .float, .@"enum", .pointer => .parseArray,
                        .optional => |opt| continue :arrayRefeed @typeInfo(opt.chid),
                        else => @compileError(std.fmt.comptimePrint(
                            "Field: {s}, Type: []{s} - unsupported array type",
                            .{ name, @typeName(ptr.child) },
                        )),
                    };
                },
                .optional => |opt| continue :refeed @typeInfo(opt.child),
                else => @compileError(std.fmt.comptimePrint(
                    "Field: {s}, Type: {s} - no codec translation for type available",
                    .{ name, @typeName(FieldType) },
                )),
            };
        }

        pub fn parseArray(
            self: *const @This(),
            comptime tag: SpecFieldEnum,
            allocator: *const Allocator,
            cursor: *CursorT,
        ) CodecError!meta.OptTypeOf(@FieldType(Spec, @tagName(tag))) {
            const token = if (cursor.next()) |t| t else return ParseSpecError.ParseArrayEndOfIterator;

            const unitCursor = try coll.UnitCursor([:0]const u8).init(allocator, token);
            defer unitCursor.destroy(allocator);

            var arena = std.heap.ArenaAllocator.init(allocator.*);
            const scrapAllocator = &arena.allocator();
            defer arena.deinit();

            return self.parseArrayInner(tag, 0, allocator, scrapAllocator, trait.asTrait(CursorT, unitCursor));
        }

        pub fn parseArrayInner(self: *const @This(), comptime tag: SpecFieldEnum, comptime depth: usize, allocator: *const Allocator, scrapAllocator: *const Allocator, cursor: *CursorT) CodecError!meta.TypeAtDepthN(Spec, @tagName(tag), depth) {
            // Array generic is always one layer lower
            const ArrayT = meta.TypeAtDepthN(Spec, @tagName(tag), depth + 1);
            const codecFTag = comptime switch (@typeInfo(ArrayT)) {
                .bool => .parseBool,
                .int => .parseInt,
                .float => .parseFloat,
                .pointer => |ptr| if (ptr.child == u8) .parseString else .parseArrayInner,
                // TODO: add a check for opt and return null on catch if that's the type we are dealing with
                // .optional
                // .@"enum"
                else => @compileError(std.fmt.comptimePrint(
                    "Spec: {s}, Codec: {s}, Field: {s} - type {s} not supported by codec",
                    .{
                        @typeName(Spec),
                        @typeName(@This()),
                        @tagName(tag),
                        @TypeOf(@FieldType(Spec, @tagName(tag))),
                    },
                )),
            };

            // Main allocator is used here to move the results outside of stack
            var array = try std.ArrayList(ArrayT).initCapacity(allocator.*, 6);
            errdefer array.deinit();

            const slice = cursor.next() orelse return CodecError.ParseArrayEndOfIterator;

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
                const args = if (comptime codecFTag == .parseArrayInner) .{
                    self,
                    tag,
                    depth + 1,
                    allocator,
                    scrapAllocator,
                    vCursor,
                } else .{
                    self,
                    tag,
                    allocator,
                    vCursor,
                };
                try array.append(
                    try @call(.auto, @field(@This(), @tagName(codecFTag)), args),
                );
            }

            return array.toOwnedSlice();
        }

        pub fn parseString(
            self: *const @This(),
            comptime tag: std.meta.FieldEnum(Spec),
            allocator: *const Allocator,
            cursor: *CursorT,
        ) CodecError!CodecOf(tag, .pointer) {
            _ = self;
            const s = cursor.next() orelse return CodecError.ParseIntEndOfIterator;

            const PtrType = @typeInfo(meta.LeafArrayTypeOfTag(Spec, @tagName(tag))).pointer;

            const newPtr = try alloc: {
                if (PtrType.sentinel()) |sentinel| {
                    break :alloc allocator.allocSentinel(PtrType.child, s.len, sentinel);
                } else {
                    break :alloc allocator.alloc(PtrType.child, s.len);
                }
            };
            @memcpy(newPtr, s);
            return newPtr;
        }

        pub fn parseFloat(
            self: *const @This(),
            comptime tag: std.meta.FieldEnum(Spec),
            allocator: *const Allocator,
            cursor: *CursorT,
        ) CodecError!CodecOf(tag, .float) {
            _ = self;
            _ = allocator;
            const value = cursor.next() orelse return CodecError.ParseFloatEndOfIterator;
            return try std.fmt.parseFloat(CodecOf(
                tag,
                .float,
            ), value);
        }

        pub fn parseInt(
            self: *const @This(),
            comptime tag: SpecFieldEnum,
            allocator: *const Allocator,
            cursor: *CursorT,
        ) CodecError!CodecOf(tag, .int) {
            _ = self;
            _ = allocator;
            const value = cursor.next() orelse return CodecError.ParseIntEndOfIterator;
            return try std.fmt.parseInt(meta.LeafTypeOfTag(Spec, @tagName(tag)), value, 10);
        }

        // The only way you can change a flag is by explicitly saying false
        // all other values are oportunistic trues
        // TODO: write a require check if it's for arrays
        pub fn parseBool(
            self: *const @This(),
            comptime tag: SpecFieldEnum,
            allocator: *const Allocator,
            cursor: *CursorT,
        ) CodecError!bool {
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

test "Codec parseBool" {
    const allocator = &std.testing.allocator;
    const cursor = try tstArgCursor(allocator,
        \\true
        \\false
        \\"something else"
    );
    defer cursor.destroy(allocator);

    const codec = Codec(struct { @"test": bool }).init();
    try std.testing.expect(try codec.parseBool(.@"test", allocator, cursor));
    try std.testing.expectEqualDeep(null, cursor.curr);

    try std.testing.expect(!try codec.parseBool(.@"test", allocator, cursor));
    try std.testing.expectEqual(null, cursor.curr);

    try std.testing.expect(try codec.parseBool(.@"test", allocator, cursor));
    try std.testing.expectEqualStrings("something else", cursor.curr.?);
}

test "Codec parseInt" {
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
}

// TODO: construct errorset based on codec
const ParseSpecError = error{
    UnknownArgumentName,
    InvalidArgumentToken,
    MissingShorthandMetadata,
    MissingShorthandLink,
    UnknownShorthandName,
    ArgEqualSplitMissingValue,
    ArgEqualSplitNotConsumed,
    CodecParseMethodUnavailable,
} || std.mem.Allocator.Error || CodecError;

// NOTE: it's the user's responsability to move pieces outside of the lifecycle of
// a spec response
pub fn SpecResponse(comptime Spec: type) type {
    // TODO: validate spec
    const Options = Spec;

    const CursorT = coll.Cursor([:0]const u8);
    const SpecCodec = if (@hasDecl(Spec, "Codec")) Spec.Codec else Codec(Spec);
    return struct {
        arena: std.heap.ArenaAllocator,
        codec: SpecCodec,
        program: ?[:0]const u8,
        options: Options,
        // TODO: Move to tuple inside Spec, leverage codec
        positionals: [][:0]const u8,
        // TODO: optional error collection

        pub fn init(allc: *const Allocator, codec: SpecCodec) !*@This() {
            var arena = std.heap.ArenaAllocator.init(allc.*);
            const allocator = arena.allocator();
            var self = try allocator.create(@This());
            self.arena = arena;
            self.codec = codec;
            self.options = Spec{};
            self.program = null;
            self.positionals = undefined;
            return self;
        }

        // TODO: test all error returns
        pub fn parse(self: *@This(), cursor: *CursorT) ParseSpecError!void {
            const allocator = self.arena.allocator();
            self.program = if (cursor.next()) |program| blk: {
                break :blk try allocator.dupeZ(u8, program);
            } else return;

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
            self.positionals = try positionals.toOwnedSlice();
        }

        fn namedToken(self: *@This(), offset: usize, arg: [:0]const u8, cursor: *CursorT) ParseSpecError!void {
            var splitValue: ?[:0]u8 = null;
            var slice: []const u8 = arg[offset..];
            const optValueIdx = std.mem.indexOf(u8, slice, "=");

            // Feed split arg to buffer
            if (optValueIdx) |i| {
                // TODO: should this sanitize the sliced arg?
                if (i + 1 >= arg.len) return ParseSpecError.ArgEqualSplitMissingValue;
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
                else => ParseSpecError.InvalidArgumentToken,
            };

            // if split not consumed, it's not sane to progress
            if (splitValue) |v| {
                const peekR: [*]const u8 = @ptrCast(cursor.peek() orelse return);
                if (peekR == @as([*]u8, @ptrCast(v))) return ParseSpecError.ArgEqualSplitNotConsumed;
            }
        }

        // TODO: re-feed chain of flags, enforce max n chars for shorthand
        fn shortArg(self: *@This(), arg: []const u8, cursor: *CursorT) ParseSpecError!void {
            if (@typeInfo(FieldEnum(Spec)).@"enum".fields.len == 0) return ParseSpecError.UnknownArgumentName;
            if (!@hasDecl(Spec, "Short")) return ParseSpecError.MissingShorthandMetadata;

            inline for (std.meta.fields(@TypeOf(Spec.Short))) |s| {
                if (std.mem.eql(u8, s.name, arg)) {
                    const tag = s.defaultValue() orelse return ParseSpecError.MissingShorthandLink;
                    try self.namedArg(tag, cursor);
                    return;
                }
            } else {
                return ParseSpecError.UnknownShorthandName;
            }
        }

        fn namedArg(self: *@This(), arg: []const u8, cursor: *CursorT) ParseSpecError!void {
            @setEvalBranchQuota(10000);
            const SpecEnum = FieldEnum(Spec);
            const fields = @typeInfo(SpecEnum).@"enum".fields;
            if (fields.len == 0) return ParseSpecError.UnknownArgumentName;

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
                return ParseSpecError.UnknownArgumentName;
            }
        }

        pub fn deinit(self: *const @This()) void {
            self.arena.deinit();
        }
    };
}

pub fn tstParseSpec(allocator: *const Allocator, cursor: *coll.Cursor([:0]const u8), Spec: type) ParseSpecError!*const SpecResponse(Spec) {
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
        u1: ?u1 = null,
        f1: ?f16 = null,
        b: ?bool = null,
        s1: ?[]const u8 = null,
        s2: ?[:0]const u8 = null,
        au1: ?[]const u1 = null,
        au32: ?[]const u32 = null,
        ai32: ?[]const i32 = null,
        af32: ?[]const f32 = null,
        // TODO: missing enum, []enum, []bool
        as1: ?[]const []const u8 = null,
        as2: ?[]const [:0]const u8 = null,
        aau32: ?[]const []const u32 = null,
        aaf32: ?[]const []const f32 = null,
        aai32: ?[]const []const i32 = null,
    };

    const r1 = try tstParse(
        \\program
        \\--u1=0
        \\--f1 1.1
        \\--b false
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
    ,
        Spec,
    );
    defer r1.deinit();

    try std.testing.expectEqual(0, r1.options.u1.?);
    try std.testing.expectEqual(1.1, r1.options.f1.?);
    try std.testing.expect(!r1.options.b.?);
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
    const expectedAaf32: []const [:0]const f32 = &.{ &.{ 1.1, 3.2, -1 }, &.{ 3.1, 2, 5 }, &.{1.2}, &.{7.1} };
    try std.testing.expectEqualDeep(expectedAaf32, r1.options.aaf32.?);
    const expectedAai32: []const [:0]const i32 = &.{ &.{-1}, &.{ 2, -2 } };
    try std.testing.expectEqualDeep(expectedAai32, r1.options.aai32.?);
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
