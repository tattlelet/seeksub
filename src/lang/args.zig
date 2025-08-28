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
    brackets: usize,
    isString: bool,
    slice: [:0]const u8,
    earlyExit: bool,
    first: bool,
    state: State,

    const Error = error{
        MissingFirstArrayLayer,
        EmptyCommaSplit,
    } || State.Error;

    const State = union(enum) {
        Noop: void,
        Matching: BaseMatch,
        InBracket: BracketTracker,
        InBracketMatching: BracketMatching,
        SeekComma: BracketTracker,
        NeedValue: BracketTracker,
        Ready: ReadyS,

        const BracketTracker = struct {
            depth: usize,
        };

        const BracketMatching = struct {
            tracker: BracketTracker,
            match: BaseMatch,
        };

        const BaseMatch = struct {
            start: usize,
            end: usize,
        };

        const ReadyS = struct {
            match: BaseMatch,
            earlyStop: bool,
        };

        const Error = error{
            CharBlackholed,
            UnsupportedQuotesOnArrayType,
            UnsupportedCharacterOnArrayType,
            EarlyBracketTermination,
            MissingFirstArrayLayer,
            EmptyCommaSplit,
            EarlyArrayTermination,
            MissingCommaSeparator,
        };

        // TODO: rework state machine to be less bad to use
        fn consume(elf: *const State, i: usize, c: u8) !State {
            var self = elf.*;
            return result: switch (c) {
                0 => {
                    break :result switch (self) {
                        .Noop, .InBracket, .SeekComma => State{ .Noop = undefined },
                        .NeedValue, .InBracketMatching => return State.Error.EarlyArrayTermination,
                        .Matching => |*match| rvalue: {
                            match.end = i;
                            break :rvalue State{ .Ready = .{
                                .match = match.*,
                                .earlyStop = false,
                            } };
                        },
                        .Ready => return State.Error.CharBlackholed,
                    };
                },
                '[' => {
                    break :result switch (self) {
                        .Noop => State{ .InBracket = .{ .depth = 1 } },
                        .NeedValue, .InBracket, .SeekComma => |*bracket| rvalue: {
                            bracket.depth += 1;
                            break :rvalue State{ .InBracketMatching = .{
                                .tracker = bracket.*,
                                .match = .{ .start = i, .end = i + 1 },
                            } };
                        },
                        .InBracketMatching => |*bMatching| rvalue: {
                            bMatching.tracker.depth += 1;
                            break :rvalue .{ .InBracketMatching = bMatching.* };
                        },
                        .Matching => |*match| rvalue: {
                            match.end = i;
                            break :rvalue .{ .Matching = match.* };
                        },
                        .Ready => return State.Error.CharBlackholed,
                    };
                },
                ']' => {
                    break :result switch (self) {
                        .Noop => return State.Error.MissingFirstArrayLayer,
                        .InBracket, .SeekComma => State.Noop,
                        .NeedValue => return State.Error.EarlyArrayTermination,
                        .InBracketMatching => |*bMatching| rvalue: {
                            bMatching.match.end = i;
                            bMatching.tracker.depth -= 1;
                            if (bMatching.tracker.depth == 0) break :rvalue .{ .Ready = .{
                                .match = bMatching.match,
                                .earlyStop = false,
                            } };
                            break :rvalue .{ .InBracketMatching = bMatching.* };
                        },
                        .Matching => |*match| rvalue: {
                            match.end = i;
                            break :rvalue .{ .Matching = match.* };
                        },
                        .Ready => return State.Error.CharBlackholed,
                    };
                },
                '\'' => return State.Error.UnsupportedQuotesOnArrayType,
                ' ', '\t' => {
                    break :result switch (self) {
                        .Noop => .{ .Noop = undefined },
                        .SeekComma => |s| .{ .SeekComma = s },
                        .NeedValue => |n| .{ .NeedValue = n },
                        .InBracket => |*bracket| .{ .InBracket = bracket.* },
                        .InBracketMatching => |*bMatching| rvalue: {
                            bMatching.match.end = i;
                            if (bMatching.tracker.depth == 1) break :rvalue .{ .Ready = .{ .match = bMatching.match, .earlyStop = true } };
                            break :rvalue .{ .InBracketMatching = bMatching.* };
                        },
                        .Matching => |*match| rvalue: {
                            match.end = i;
                            break :rvalue .{ .Ready = .{ .match = match.*, .earlyStop = true } };
                        },
                        .Ready => return State.Error.CharBlackholed,
                    };
                },
                '\r', '\n' => return State.Error.UnsupportedCharacterOnArrayType,
                ',' => {
                    break :result switch (self) {
                        .Noop => .{ .Noop = undefined },
                        .SeekComma => |s| .{ .NeedValue = s },
                        .NeedValue, .InBracket => return State.Error.EmptyCommaSplit,
                        .InBracketMatching => |*bMatching| rvalue: {
                            bMatching.match.end = i;
                            if (bMatching.tracker.depth == 1) break :rvalue .{ .Ready = .{ .match = bMatching.match, .earlyStop = false } };
                            break :rvalue .{ .InBracketMatching = bMatching.* };
                        },
                        .Matching => |*match| rvalue: {
                            match.end = i;
                            break :rvalue .{ .Ready = .{ .match = match.*, .earlyStop = false } };
                        },
                        .Ready => return State.Error.CharBlackholed,
                    };
                },
                else => {
                    break :result switch (self) {
                        .Noop => return State.Error.MissingFirstArrayLayer,
                        .NeedValue, .InBracket => |bracket| .{ .InBracketMatching = .{
                            .tracker = bracket,
                            .match = .{ .start = i, .end = i },
                        } },
                        .InBracketMatching => |*bMatching| rvalue: {
                            bMatching.match.end = i;
                            break :rvalue .{ .InBracketMatching = bMatching.* };
                        },
                        .Matching => |*match| rvalue: {
                            match.end = i;
                            break :rvalue .{ .Matching = match.* };
                        },
                        .SeekComma => return State.Error.MissingCommaSeparator,
                        .Ready => return State.Error.CharBlackholed,
                    };
                },
            };
        }
    };

    pub fn init(isString: bool, slice: [:0]const u8) @This() {
        return .{
            .i = 0,
            .brackets = 0,
            .isString = isString,
            .slice = slice,
            .earlyExit = false,
            .first = true,
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
            self.state = switch (try self.state.consume(i, c)) {
                .Ready => |rMatch| {
                    i += 1;
                    self.state = if (!rMatch.earlyStop) .{ .InBracket = .{ .depth = 1 } } else .{ .SeekComma = .{ .depth = 1 } };
                    const match = rMatch.match;
                    const s = slice[match.start..match.end];
                    std.debug.print("{s}\n", .{s});
                    return s;
                },
                else => |state| state,
            };
        }
        return null;
    }

    pub fn next2(self: *@This()) Error!?[]const u8 {
        var i = self.i;
        var brackets = self.brackets;
        defer {
            self.i = i;
            self.brackets = brackets;
        }

        const slice = self.slice;

        var wordMatching: bool = false;
        var start: usize = 0;
        var end: usize = 0;
        var inQuotes: bool = false;

        // We do one over to create a token at the end
        while (i <= slice.len) : (i += 1) {
            const c = if (i < slice.len) slice[i] else endIt: {
                end = slice.len;
                if (wordMatching) break :endIt 0 else break;
            };
            rfd: switch (c) {
                0 => {
                    i += 1;
                    self.first = false;
                    const s = slice[start..end];
                    return s;
                },
                '[' => {
                    if (self.isString) end = i else {
                        brackets += 1;
                        if (brackets == 2 and !wordMatching and start == 0) {
                            wordMatching = true;
                            start = i;
                            end = i;
                        }
                    }
                },
                ']' => {
                    if (self.isString) end = i else {
                        brackets -= 1;
                        if (brackets == 0 and wordMatching) {
                            // Dont add at level bracket
                            end = i;
                            continue :rfd 0;
                        } else if (brackets == 0 and !self.earlyExit and !self.first) {
                            return Error.EarlyArrayTermination;
                        }
                    }
                },
                ' ', '\t', '\r', '\n' => {
                    if (inQuotes and !wordMatching) {
                        // Starting in-quotes match
                        start = i;
                        end = i;
                        wordMatching = true;
                    } else if (!wordMatching or brackets > 1) {
                        // Not in quotes, not matching, no need to collect
                        // or start a match
                        continue;
                    } else if (wordMatching and inQuotes) {
                        // still matching and consuming empty chars due to quotes
                        end = i;
                    } else {
                        // not inside quotes, so quotes mean stop
                        self.earlyExit = true;
                        end = i;
                        continue :rfd 0;
                    }
                },
                '\'' => {
                    if (!self.isString) return Error.UnsupportedQuotesOnArrayType;
                    inQuotes = !inQuotes;
                    if (!inQuotes and wordMatching) {
                        // end is always 1 char behind for refeeds
                        self.earlyExit = true;
                        end = i;
                        continue :rfd 0;
                    }
                },
                ',' => {
                    if (wordMatching and brackets <= 1) {
                        // end is always 1 char behind for refeeds
                        end = i;
                        continue :rfd 0;
                    } else if (!wordMatching and start == end) {
                        if (self.earlyExit) {
                            self.earlyExit = false;
                        } else {
                            return Error.EmptyCommaSplit;
                        }
                    }
                },
                else => {
                    end = i;
                    if (!wordMatching) {
                        if (!self.isString and brackets == 0) return Error.MissingFirstArrayLayer;
                        start = i;
                        wordMatching = true;
                    }
                },
            }
        }
        return null;
    }
};

fn tstCollectTokens(allocator: *const Allocator, isString: bool, slice: [:0]const u8) ![]const [:0]const u8 {
    var result = std.ArrayList([:0]const u8).init(allocator.*);
    var tokenizer = AtDepthArrayTokenIterator.init(isString, slice);
    // var tokenizer2 = AtDepthArrayTokenIterator.init(isString, slice);
    while (true) {
        // const item2 = try tokenizer2.next();
        const item = try tokenizer.next();
        // try std.testing.expectEqualDeep(item, item);
        if (item == null) break;
        try result.append(try allocator.dupeZ(u8, item.?));
    }

    return result.toOwnedSlice();
}

test "Array tokenizer (non-string)" {
    const t = std.testing;
    const E = AtDepthArrayTokenIterator.Error;
    const base = &std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base.*);
    defer arena.deinit();
    const allocator = &arena.allocator();

    const expectEmpty: []const [:0]const u8 = &.{};
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, false, ""));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, false, "["));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, false, "[]"));
    try t.expectEqualDeep(expectEmpty, try tstCollectTokens(allocator, false, "[ ]"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, false, "[  ,]"));
    try t.expectError(E.UnsupportedQuotesOnArrayType, tstCollectTokens(allocator, false, "'"));
    try t.expectError(E.UnsupportedQuotesOnArrayType, tstCollectTokens(allocator, false, "[1,']"));
    try t.expectError(E.EmptyCommaSplit, tstCollectTokens(allocator, false, "[1,,]"));
    try t.expectError(E.EarlyArrayTermination, tstCollectTokens(allocator, false, "[1 ,]"));
    const expectTwo: []const [:0]const u8 = &.{ "1", "1" };
    try t.expectEqualDeep(expectTwo, tstCollectTokens(allocator, false, "[1,1]"));
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

            const LeafT = meta.LeafTypeOfTag(Spec, @tagName(tag));
            var arrTokenizer = AtDepthArrayTokenIterator.init(LeafT == u8, slice);

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

                    // TODO: append if array?
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
        // s1: ?[]const u8 = null,
        // s2: ?[:0]const u8 = null,
        au1: ?[]const u1 = null,
        au32: ?[]const u32 = null,
        ai32: ?[]const i32 = null,
        af32: ?[]const f32 = null,
        // // // TODO: missing enum, []enum, []bool
        // as1: ?[]const []const u8 = null,
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
        // \\--s1 Hello
        // \\--s2 "Hello World"
        \\--au1 [1,0,1,0]
        \\--au32=[32,23,133,99,10]
        \\--ai32 "[-1, -44, 22222   ,   -1]"
        \\--af32="[    3.4   , 58,   3.1  ]"
        // \\--as1 "'Hello', ' World ', '!'"
        // \\--as2="  'Im'  ,  'Losing it'  "
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
    // try std.testing.expectEqualStrings("Hello", r1.options.s1.?);
    // try std.testing.expectEqualStrings("Hello World", r1.options.s2.?);
    try std.testing.expectEqualDeep(&[_]u1{ 1, 0, 1, 0 }, r1.options.au1.?);
    try std.testing.expectEqualDeep(&[_]u32{ 32, 23, 133, 99, 10 }, r1.options.au32.?);
    try std.testing.expectEqualDeep(&[_]i32{ -1, -44, 22222, -1 }, r1.options.ai32.?);
    // const expectedAs1: []const []const u8 = &.{ "Hello", " World ", "!" };
    // try std.testing.expectEqualDeep(expectedAs1, r1.options.as1.?);
    // const expectedAs2: []const [:0]const u8 = &.{ "Im", "Losing it" };
    // try std.testing.expectEqualDeep(expectedAs2, r1.options.as2.?);
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
