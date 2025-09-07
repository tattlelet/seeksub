const std = @import("std");
const coll = @import("../collections.zig");
const meta = @import("../meta.zig");
const argIter = @import("iterator.zig");
const Allocator = std.mem.Allocator;
const FieldEnum = std.meta.FieldEnum;
const AtDepthArrayTokenIterator = argIter.AtDepthArrayTokenIterator;
const TstArgCursor = argIter.TstArgCursor;

pub const PrimitiveCodec = struct {
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

    pub fn validateConcreteType(
        comptime T: type,
        comptime OtherT: type,
    ) void {
        comptime if (T != OtherT) @compileError(std.fmt.comptimePrint("Expected type {s} found {s}", .{
            @typeName(T),
            @typeName(OtherT),
        }));
    }

    pub fn parseByType(
        codec: anytype,
        comptime T: type,
        comptime tag: anytype,
        allocator: *const Allocator,
        cursor: *CursorT,
    ) Error!T {
        if (comptime meta.ptrTypeToChild(@TypeOf(codec)).supports(T, tag)) {
            return try codec.parseByType(T, tag, allocator, cursor);
        }

        return try switch (@typeInfo(T)) {
            .bool => @This().parseBool(cursor),
            .int => @This().parseInt(T, cursor),
            .float => @This().parseFloat(T, cursor),
            .@"enum" => @This().parseEnum(T, cursor),
            .pointer => |ptr| if (ptr.child == u8) @This().parseString(
                T,
                allocator,
                cursor,
            ) else @This().parseArray(
                codec,
                T,
                tag,
                allocator,
                cursor,
            ),
            .optional => @This().parseOpt(codec, T, tag, allocator, cursor),
            else => @compileError(std.fmt.comptimePrint(
                "Codec: {s} - type {s} not supported by codec",
                .{
                    @typeName(@This()),
                    @typeName(T),
                },
            )),
        };
    }

    pub fn parseArray(
        codec: anytype,
        comptime T: type,
        comptime tag: anytype,
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
            try array.append(try parseByType(codec, ArrayT, tag, allocator, cursor));
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
        codec: anytype,
        comptime T: type,
        comptime tag: anytype,
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
            return try parseByType(codec, Tt, tag, allocator, cursor);
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

test "default codec parseBool" {
    const allocator = &std.testing.allocator;
    var tstCursor = try TstArgCursor.init(allocator,
        \\true
        \\false
    );
    defer tstCursor.deinit();
    var cursor = @constCast(&tstCursor.asCursor());
    _ = &cursor;

    try std.testing.expectEqual(true, try PrimitiveCodec.parseBool(cursor));
    try std.testing.expectEqual(false, try PrimitiveCodec.parseBool(cursor));
    try std.testing.expectError(
        PrimitiveCodec.Error.ParseBoolEndOfIterator,
        PrimitiveCodec.parseBool(cursor),
    );
}

pub fn ArgCodec(Spec: type) type {
    return struct {
        pub const Error = PrimitiveCodec.Error;
        pub const CursorT = PrimitiveCodec.CursorT;
        pub const SpecFieldEnum = std.meta.FieldEnum(Spec);

        pub fn supports(
            comptime T: type,
            comptime tag: SpecFieldEnum,
        ) bool {
            const FieldType = comptime @FieldType(Spec, @tagName(tag));
            return switch (@typeInfo(T)) {
                .bool => FieldType == ?bool or FieldType == bool,
                else => false,
            };
        }

        pub fn parseByTag(
            self: *@This(),
            comptime tag: SpecFieldEnum,
            allocator: *const Allocator,
            cursor: *CursorT,
        ) Error!@FieldType(Spec, @tagName(tag)) {
            return try self.parseByType(
                @FieldType(Spec, @tagName(tag)),
                tag,
                allocator,
                cursor,
            );
        }

        pub fn parseByType(
            codec: anytype,
            comptime T: type,
            comptime tag: SpecFieldEnum,
            allocator: *const Allocator,
            cursor: *CursorT,
        ) Error!T {
            return try switch (@typeInfo(T)) {
                .bool => @This().parseFlag(cursor),
                .optional => |opt| switch (@typeInfo(opt.child)) {
                    .bool => @This().parseOpt(codec, tag, allocator, cursor),
                    else => PrimitiveCodec.parseByType(codec, T, tag, allocator, cursor),
                },
                else => PrimitiveCodec.parseByType(codec, T, tag, allocator, cursor),
            };
        }

        pub fn parseOpt(
            codec: anytype,
            comptime tag: std.meta.FieldEnum(Spec),
            allocator: *const Allocator,
            cursor: *CursorT,
        ) Error!@FieldType(Spec, @tagName(tag)) {
            const tagT = comptime @FieldType(Spec, @tagName(tag));
            if (comptime @typeInfo(tagT).optional.child == bool)
                if (PrimitiveCodec.isNull(cursor)) {
                    cursor.consume();
                    return null;
                } else return try @This().parseFlag(
                    cursor,
                )
            else
                return try PrimitiveCodec.parseOpt(
                    codec,
                    tagT,
                    tag,
                    allocator,
                    cursor,
                );
        }

        pub fn parseFlag(
            cursor: *CursorT,
        ) Error!bool {
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

// TODO: add test with no arena to test ownership for array and string

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
    const C = ArgCodec(Spec);
    var codec = C{};
    const expectBA: []const bool = &.{ false, true };
    try std.testing.expectEqualDeep(expectBA, try codec.parseByTag(.b, allocator, cursor));
    const expectIA: []const i32 = &.{ 1, -1 };
    try std.testing.expectEqualDeep(expectIA, try codec.parseByTag(.i, allocator, cursor));
    const expectFA: []const f32 = &.{ 1.1, -2.2 };
    try std.testing.expectEqualDeep(expectFA, try codec.parseByTag(.f, allocator, cursor));
    const expectSA: []const []const u8 = &.{ "a", "b" };
    try std.testing.expectEqualDeep(expectSA, try codec.parseByTag(.s, allocator, cursor));
    const expectSZ: []const [:0]const u8 = &.{ "c", "d" };
    try std.testing.expectEqualDeep(expectSZ, try codec.parseByTag(.sz, allocator, cursor));
    const expectAD: []const [:0]const i32 = &.{&.{3}};
    try std.testing.expectEqualDeep(expectAD, try codec.parseByTag(.ad, allocator, cursor));
    const expectED: []const Spec.Size = &.{ .small, .medium, .large };
    try std.testing.expectEqualDeep(expectED, try codec.parseByTag(.e, allocator, cursor));
    const expectB2: []const ?bool = &.{ false, null };
    try std.testing.expectEqualDeep(expectB2, try codec.parseByTag(.b2, allocator, cursor));
    const expectB3: []const []const ?bool = &.{&.{ false, null }};
    try std.testing.expectEqualDeep(expectB3, try codec.parseByTag(.b3, allocator, cursor));
    const expectB4: []const ?[]const ?bool = &.{ &.{ false, null }, null };
    try std.testing.expectEqualDeep(expectB4, try codec.parseByTag(.b4, allocator, cursor));
    try std.testing.expectError(
        C.Error.ParseArrayEndOfIterator,
        codec.parseByTag(.b4, allocator, cursor),
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
        \\null
    );
    defer tstCursor.deinit();
    var cursor = @constCast(&tstCursor.asCursor());
    _ = &cursor;

    const C = ArgCodec(struct {
        b5: ?[]const ?[]const ?bool,
        b6: ?[]const []bool,
        b7: ?[]const []bool,
        a1: ?f32,
        flag1: ?bool = false,
        flag2: ?bool = null,
    });
    var codec = C{};
    const expectB5: ?[]const ?[]const ?bool = &.{ &.{ null, true, null }, &.{false}, null };
    try std.testing.expectEqualDeep(expectB5, try codec.parseByTag(.b5, allocator, cursor));
    const expectB6: ?[]const []bool = &.{};
    try std.testing.expectEqualDeep(expectB6, try codec.parseByTag(.b6, allocator, cursor));
    const expectB7: ?[]const []bool = &.{&.{}};
    try std.testing.expectEqualDeep(expectB7, try codec.parseByTag(.b7, allocator, cursor));
    try std.testing.expectEqual(null, try codec.parseByTag(.a1, allocator, cursor));
    try std.testing.expectEqual(1, (try codec.parseByTag(.a1, allocator, cursor)).?);
    try std.testing.expectEqual(null, try codec.parseByTag(.flag1, allocator, cursor));
    try std.testing.expect((try codec.parseByTag(.flag2, allocator, cursor)).?);
    // cursor.consume();
    try std.testing.expectError(
        C.Error.ParseOptEndOfIterator,
        codec.parseByTag(.a1, allocator, cursor),
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

    var codec = ArgCodec(struct { s1: []const u8, s2: [:0]const u8 }){};
    try std.testing.expectEqualDeep("hello", try codec.parseByTag(.s1, allocator, cursor));
    try std.testing.expectEqualDeep("world", try codec.parseByTag(.s2, allocator, cursor));
    try std.testing.expectError(
        @TypeOf(codec).Error.ParseStringEndOfIterator,
        codec.parseByTag(.s2, allocator, cursor),
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
    var codec = ArgCodec(Spec){};
    try std.testing.expectEqual(Spec.Size.small, try codec.parseByTag(.size, allocator, cursor));
    try std.testing.expectEqual(Spec.Size.medium, try codec.parseByTag(.size, allocator, cursor));
    try std.testing.expectEqual(Spec.Size.large, try codec.parseByTag(.size, allocator, cursor));
    try std.testing.expectError(
        @TypeOf(codec).Error.InvalidEnum,
        codec.parseByTag(.size, allocator, cursor),
    );
    try std.testing.expectError(
        @TypeOf(codec).Error.ParseEnumEndOfIterator,
        codec.parseByTag(.size, allocator, cursor),
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

    var codec = ArgCodec(struct { f1: f32, f2: f64 }){};
    try std.testing.expectEqual(44.0, try codec.parseByTag(.f1, allocator, cursor));
    try std.testing.expectEqual(-1.2, try codec.parseByTag(.f2, allocator, cursor));
    try std.testing.expectEqual(32.2222, try codec.parseByTag(.f1, allocator, cursor));
    try std.testing.expectError(
        @TypeOf(codec).Error.ParseFloatEndOfIterator,
        codec.parseByTag(.f1, allocator, cursor),
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

    var codec = ArgCodec(struct { n1: u6, n2: i2, n3: u88 }){};
    try std.testing.expectEqual(44, try codec.parseByTag(.n1, allocator, cursor));
    try std.testing.expectEqual(-1, try codec.parseByTag(.n2, allocator, cursor));
    try std.testing.expectEqual(25, try codec.parseByTag(.n3, allocator, cursor));
    try std.testing.expectError(
        @TypeOf(codec).Error.ParseIntEndOfIterator,
        codec.parseByTag(.n3, allocator, cursor),
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

    var codec = ArgCodec(struct { @"test": bool }){};
    try std.testing.expect(try codec.parseByTag(.@"test", allocator, cursor));
    try std.testing.expectEqualDeep(null, cursor.curr);

    try std.testing.expect(!try codec.parseByTag(.@"test", allocator, cursor));
    try std.testing.expectEqual(null, cursor.curr);

    try std.testing.expect(try codec.parseByTag(.@"test", allocator, cursor));
    try std.testing.expectEqualStrings("something else", cursor.curr.?);

    // 4 letter guess
    _ = cursor.next();
    try std.testing.expect(try codec.parseByTag(.@"test", allocator, cursor));
    try std.testing.expectEqualStrings("1234", cursor.curr.?);

    // 5 letter guess
    _ = cursor.next();
    try std.testing.expect(try codec.parseByTag(.@"test", allocator, cursor));
    try std.testing.expectEqualStrings("12345", cursor.curr.?);

    // null check
    _ = cursor.next();
    try std.testing.expect(try codec.parseByTag(.@"test", allocator, cursor));
    try std.testing.expectEqual(null, cursor.curr);
}
