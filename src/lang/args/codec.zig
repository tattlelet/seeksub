const std = @import("std");
const coll = @import("../collections.zig");
const meta = @import("../meta.zig");
const argIter = @import("iterator.zig");
const Allocator = std.mem.Allocator;
const FieldEnum = std.meta.FieldEnum;
const AtDepthArrayTokenIterator = argIter.AtDepthArrayTokenIterator;
const TstArgCursor = argIter.TstArgCursor;

pub const DefaultCodec = struct {
    pub const Error = error{
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

    pub const CursorT = coll.Cursor([]const u8);

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

    pub fn parseWith(comptime T: type) std.meta.DeclEnum(@This()) {
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

    pub fn parseByType(comptime T: type, args: anytype) Error!T {
        const ArgT = @TypeOf(args);
        comptime validateType(ArgT, .@"struct");
        if (!@typeInfo(ArgT).@"struct".is_tuple) @compileError(std.fmt.comptimePrint(
            "Argument time given to callByTag is not a tuple",
            .{@typeName(ArgT)},
        ));

        const fTag = comptime parseWith(T);
        return try @call(.auto, @field(@This(), @tagName(fTag)), switch (fTag) {
            .parseBool => .{args.@"1"},
            .parseInt, .parseFloat, .parseEnum => .{ T, args.@"1" },
            .parseString, .parseOpt, .parseArray => .{ T, args.@"0", args.@"1" },
            else => @compileError(std.fmt.comptimePrint(
                "Unknown args builder for {s}",
                .{@tagName(fTag)},
            )),
        });
    }

    pub fn parseArray(
        comptime T: type,
        allocator: *const Allocator,
        cursor: *CursorT,
    ) Error!T {
        comptime validateType(T, .pointer);
        const PtrT = comptime @typeInfo(T).pointer;
        const ArrayT = comptime PtrT.child;
        var array = try std.ArrayList(ArrayT).initCapacity(allocator.*, 3);
        errdefer array.deinit();

        const slice = cursor.next() orelse return Error.ParseArrayEndOfIterator;
        var arrTokenizer = AtDepthArrayTokenIterator.init(slice);
        while (try arrTokenizer.next()) |token| {
            cursor.stackItem(token);
            try array.append(try parseByType(ArrayT, .{ allocator, cursor }));
        }

        // ArrayList erases sentinel
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
        const Tt = comptime @typeInfo(T).optional.child;

        _ = cursor.peek() orelse return Error.ParseOptEndOfIterator;
        if (isNull(cursor)) {
            cursor.consume();
            return null;
        } else {
            return try parseByType(Tt, .{ allocator, cursor });
        }
    }

    pub fn parseString(
        comptime T: type,
        allocator: *const Allocator,
        cursor: *CursorT,
    ) Error!T {
        comptime validateType(T, .pointer);
        const PtrType = comptime @typeInfo(T).pointer;
        const Tt = comptime std.meta.Child(T);
        comptime validateConcreteType(Tt, u8);

        const s = cursor.next() orelse return Error.ParseStringEndOfIterator;
        if (comptime PtrType.sentinel()) |sentinel| {
            const newPtr = try allocator.allocSentinel(Tt, s.len, sentinel);
            @memcpy(newPtr, s);
            return newPtr;
        } else {
            return s;
        }
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
        pub const Error = DefaultCodec.Error;
        pub const CursorT = DefaultCodec.CursorT;
        pub const SpecFieldEnum = std.meta.FieldEnum(Spec);
        const CodecMethods = std.meta.DeclEnum(@This());

        pub fn parseWith(comptime tag: SpecFieldEnum) CodecMethods {
            const FieldType = comptime @FieldType(Spec, @tagName(tag));
            return comptime switch (@typeInfo(FieldType)) {
                .bool => .parseFlag,
                else => result: {
                    const fTag = @tagName(DefaultCodec.parseWith(FieldType));
                    break :result meta.stringToEnum(
                        CodecMethods,
                        fTag,
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
        ) Error!@FieldType(Spec, @tagName(tag)) {
            _ = self;
            return try DefaultCodec.parseArray(
                @FieldType(Spec, @tagName(tag)),
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
            const tagT = comptime @FieldType(Spec, @tagName(tag));
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
        ) Error!@FieldType(Spec, @tagName(tag)) {
            _ = self;
            return try DefaultCodec.parseString(
                @FieldType(Spec, @tagName(tag)),
                allocator,
                cursor,
            );
        }

        pub fn parseEnum(
            self: *const @This(),
            comptime tag: SpecFieldEnum,
            allocator: *const Allocator,
            cursor: *CursorT,
        ) Error!@FieldType(Spec, @tagName(tag)) {
            _ = self;
            _ = allocator;
            return try DefaultCodec.parseEnum(
                @FieldType(Spec, @tagName(tag)),
                cursor,
            );
        }

        pub fn parseFloat(
            self: *const @This(),
            comptime tag: std.meta.FieldEnum(Spec),
            allocator: *const Allocator,
            cursor: *CursorT,
        ) Error!@FieldType(Spec, @tagName(tag)) {
            _ = self;
            _ = allocator;
            return try DefaultCodec.parseFloat(
                @FieldType(Spec, @tagName(tag)),
                cursor,
            );
        }

        pub fn parseInt(
            self: *const @This(),
            comptime tag: SpecFieldEnum,
            allocator: *const Allocator,
            cursor: *CursorT,
        ) Error!@FieldType(Spec, @tagName(tag)) {
            _ = self;
            _ = allocator;
            return try DefaultCodec.parseInt(
                @FieldType(Spec, @tagName(tag)),
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
    var tstCursor = try TstArgCursor.init(allocator,
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
    );
    defer tstCursor.deinit();
    var cursor = @constCast(&tstCursor.asCursor());
    _ = &cursor;

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

        const Size = enum {
            small,
            medium,
            large,
        };
    };
    const codec = Codec(Spec){};
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
    try std.testing.expectError(
        @TypeOf(codec).Error.ParseArrayEndOfIterator,
        codec.parseArray(.b4, allocator, cursor),
    );
}

test "codec parseOpt" {
    const baseAllocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(baseAllocator);
    defer arena.deinit();
    const allocator = &arena.allocator();
    var tstCursor = try TstArgCursor.init(allocator,
        \\"[[null, true, null], [false], null]"
        \\"[]"
        \\"[[]]"
        \\null
        \\1
    );
    defer tstCursor.deinit();
    var cursor = @constCast(&tstCursor.asCursor());

    const codec = Codec(struct {
        a1: ?f32,
        b5: ?[]const ?[]const ?bool,
        b6: ?[]const []bool,
        b7: ?[]const []bool,
    }){};
    const expectB5: ?[]const ?[]const ?bool = &.{ &.{ null, true, null }, &.{false}, null };
    try std.testing.expectEqualDeep(expectB5, try codec.parseOpt(.b5, allocator, cursor));
    const expectB6: ?[]const []bool = &.{};
    try std.testing.expectEqualDeep(expectB6, try codec.parseOpt(.b6, allocator, cursor));
    const expectB7: ?[]const []bool = &.{&.{}};
    try std.testing.expectEqualDeep(expectB7, try codec.parseOpt(.b7, allocator, cursor));
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
    var tstCursor = try TstArgCursor.init(allocator,
        \\hello
        \\world
    );
    defer tstCursor.deinit();
    var cursor = @constCast(&tstCursor.asCursor());
    _ = &cursor;

    const codec = Codec(struct { s1: []const u8, s2: [:0]const u8 }){};
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
    var tstCursor = try TstArgCursor.init(allocator,
        \\small
        \\medium
        \\large
        \\invalid
    );
    defer tstCursor.deinit();
    var cursor = @constCast(&tstCursor.asCursor());
    _ = &cursor;

    const Spec = struct {
        size: Size,

        const Size = enum {
            small,
            medium,
            large,
        };
    };
    const codec = Codec(Spec){};
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
    var tstCursor = try TstArgCursor.init(allocator,
        \\44
        \\-1.2
        \\32.2222
    );
    defer tstCursor.deinit();
    var cursor = @constCast(&tstCursor.asCursor());
    _ = &cursor;

    const codec = Codec(struct { f1: f32, f2: f64 }){};
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
    var tstCursor = try TstArgCursor.init(allocator,
        \\44
        \\-1
        \\25
    );
    defer tstCursor.deinit();
    var cursor = @constCast(&tstCursor.asCursor());
    _ = &cursor;

    const codec = Codec(struct { n1: u6, n2: i2, n3: u88 }){};
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
    var tstCursor = try TstArgCursor.init(allocator,
        \\true
        \\false
    );
    defer tstCursor.deinit();
    var cursor = @constCast(&tstCursor.asCursor());
    _ = &cursor;

    const codec = Codec(struct { b1: bool }){};
    try std.testing.expectEqual(true, try codec.parseBool(.b1, allocator, cursor));
    try std.testing.expectEqual(false, try codec.parseBool(.b1, allocator, cursor));
    try std.testing.expectError(
        @TypeOf(codec).Error.ParseBoolEndOfIterator,
        codec.parseBool(.b1, allocator, cursor),
    );
}

test "codec parseFlag" {
    const allocator = &std.testing.allocator;
    var tstCursor = try TstArgCursor.init(allocator,
        \\true
        \\false
        \\"something else"
        \\1234
        \\12345
    );
    defer tstCursor.deinit();
    var cursor = @constCast(&tstCursor.asCursor());
    _ = &cursor;

    const codec = Codec(struct { @"test": bool }){};
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
