const std = @import("std");
const meta = @import("../meta.zig");
const argCodec = @import("codec.zig");
const coll = @import("../collections.zig");
const argIter = @import("iterator.zig");
const Allocator = std.mem.Allocator;
const PrimitiveCodec = argCodec.PrimitiveCodec;
const TstArgCursor = argIter.TstArgCursor;

pub const PositionalConfig = struct {
    TupleType: type = void,
    // NOTE: the default allocates
    ReminderType: type = ?[]const []const u8,
    CodecType: type = PrimitiveCodec,
};

// NOTE: this essentially only handles void and ?[]const []const u8
pub fn PositionalOf(comptime Config: PositionalConfig) type {
    return PositionalOfWithDefault(Config, switch (@typeInfo(Config.ReminderType)) {
        .void => {},
        .optional => |opt| rv: {
            if (opt.child == []const []const u8) {
                break :rv null;
            } else {
                break :rv undefined;
            }
        },
        else => undefined,
    });
}

// NOTE: this is meant to be used with an arena, not owned by this object
// the only case this allocates in heap is for dynamic arrays or sentinel slices
pub fn PositionalOfWithDefault(comptime Config: PositionalConfig, reminderDefault: Config.ReminderType) type {
    return struct {
        pub const TupleT = Config.TupleType;
        pub const ReminderT = Config.ReminderType;
        const CodecT = Config.CodecType;
        const InnerList = if (reminderT() == .pointer) std.ArrayListUnmanaged(remindChildT()) else void;

        fn reminderT() std.builtin.Type {
            const unsupportedMessage = comptime std.fmt.comptimePrint(
                "Unsupported Reminder type {s}, it has to be a collection",
                .{@typeName(ReminderT)},
            );
            return comptime rfd: switch (@typeInfo(ReminderT)) {
                .optional => |opt| switch (@typeInfo(opt.child)) {
                    .array, .pointer => continue :rfd @typeInfo(opt.child),
                    else => @compileError(unsupportedMessage),
                },
                .array => |arr| @typeInfo(@Type(.{ .array = arr })),
                .pointer => |ptr| @typeInfo(@Type(.{ .pointer = ptr })),
                .void => @typeInfo(void),
                else => @compileError(unsupportedMessage),
            };
        }

        fn remindChildT() type {
            return rfd: switch (@typeInfo(ReminderT)) {
                .optional => |opt| continue :rfd @typeInfo(opt.child),
                .array => |arr| std.meta.Child(@Type(.{ .array = arr })),
                .pointer => |ptr| std.meta.Child(@Type(.{ .pointer = ptr })),
                else => @compileError(std.fmt.comptimePrint(
                    "Unsupported Reminder type {s}, it has to be a collection",
                    .{@typeName(ReminderT)},
                )),
            };
        }

        tuple: TupleT = if (TupleT == void) {} else undefined,
        reminder: ReminderT = reminderDefault,
        list: InnerList = if (InnerList != void) undefined else {},
        tupleCursor: usize = 0,
        reminderCursor: usize = 0,
        codec: CodecT = .{},

        pub const Positionals = struct {
            tuple: TupleT,
            reminder: ReminderT,
        };

        pub const CursorT = coll.Cursor([]const u8);
        pub const Error = error{
            ParseNextCalledOnTupleEnd,
            ReminderBufferShorterThanArgs,
            ParseNextCalledForEmptyPositional,
        } || CodecT.Error;

        pub fn parseNextType(
            self: *@This(),
            allocator: *const Allocator,
            cursor: *CursorT,
        ) Error!void {
            if (comptime TupleT == void and ReminderT == void) return Error.ParseNextCalledForEmptyPositional;
            if (comptime ReminderT == void) {
                if (self.tupleCursor >= self.tuple.len) return Error.ParseNextCalledOnTupleEnd;
            } else {
                if ((comptime TupleT == void) or self.tupleCursor >= self.tuple.len) {
                    if (reminderT() == .array) {
                        try self.nextReminderBuffered(allocator, cursor);
                    } else {
                        try self.nextReminder(allocator, cursor);
                    }
                    return;
                }
            }
            const TupleEnum = meta.FieldEnum(TupleT);
            switch (@as(TupleEnum, @enumFromInt(self.tupleCursor))) {
                inline else => |idx| {
                    self.tuple[@intFromEnum(idx)] = try self.codec.parseByType(
                        @TypeOf(self.tuple[@intFromEnum(idx)]),
                        .null,
                        allocator,
                        cursor,
                    );
                    self.tupleCursor += 1;
                },
            }
        }

        fn nextReminderBuffered(self: *@This(), allocator: *const Allocator, cursor: *CursorT) Error!void {
            _ = cursor.peek() orelse return;

            if (self.reminderCursor >= self.reminder.len) return Error.ReminderBufferShorterThanArgs;

            self.reminder[self.reminderCursor] = try self.codec.parseByType(
                remindChildT(),
                .null,
                allocator,
                cursor,
            );
            self.reminderCursor += 1;
        }

        fn nextReminder(self: *@This(), allc: *const Allocator, cursor: *CursorT) Error!void {
            if (cursor.peek() == null) return;

            const allocator = allc.*;
            if (self.reminderCursor == 0) {
                if (comptime InnerList == void) {
                    @compileLog(remindChildT());
                    @compileError("Unsupported call to nextReminder with non inner list");
                } else {
                    self.list = try std.ArrayListUnmanaged([]const u8).initCapacity(allocator, 8);
                }
            }

            const result = try self.codec.parseByType(
                remindChildT(),
                .null,
                allc,
                cursor,
            );

            try self.list.append(allocator, result);
            self.reminderCursor += 1;
        }

        pub fn collect(self: *@This(), allocator: *const Allocator) std.mem.Allocator.Error!Positionals {
            // TODO: required checks
            const reminder = if (comptime InnerList == void) self.reminder else rv: {
                break :rv if (self.reminderCursor == 0) &.{} else try self.list.toOwnedSlice(allocator.*);
            };
            return .{
                .tuple = self.tuple,
                .reminder = reminder,
            };
        }
    };
}

test "parse positionals tuple" {
    const t = std.testing;

    var pos: PositionalOf(.{
        .TupleType = struct { i32, bool, [3]u4 },
        .ReminderType = [2][]const u8,
    }) = .{};

    var cursor = coll.DebugCursor{
        .data = &.{
            "-13",
            "false",
            "[1,2,3]",
            "hello",
            "world!",
        },
    };
    var c = cursor.asCursor();

    while (c.peek()) |_| try pos.parseNextType(&std.testing.allocator, &c);
    const p = try pos.collect(&std.testing.allocator);

    try t.expectEqual(-13, p.tuple[0]);
    try t.expectEqual(false, p.tuple[1]);
    try t.expectEqualDeep(@as([]const u4, &.{ 1, 2, 3 }), &p.tuple[2]);
    const expect: []const []const u8 = &.{ "hello", "world!" };
    try t.expectEqualDeep(expect, &p.reminder);
}

test "parse buffered reminder" {
    const t = std.testing;
    const allocator = &std.testing.allocator;

    var pos: PositionalOf(.{
        .ReminderType = [2][]const u8,
    }) = .{};

    var cursor = coll.DebugCursor{
        .data = &.{
            "hello",
            "world!",
            "ha!",
        },
    };
    var c = cursor.asCursor();

    for (0..2) |_| try pos.parseNextType(allocator, &c);
    const p = try pos.collect(allocator);

    try t.expectEqual({}, p.tuple);
    const expect: []const []const u8 = &.{ "hello", "world!" };
    try t.expectEqualDeep(expect, &p.reminder);
    try t.expectError(@TypeOf(pos).Error.ReminderBufferShorterThanArgs, pos.parseNextType(allocator, &c));
}

test "parse dynamic reminder" {
    const t = std.testing;
    const allocator = &std.testing.allocator;

    var pos: PositionalOf(.{}) = .{};
    var cursor = coll.DebugCursor{
        .data = &.{
            "hello",
            "world!",
            "ha!",
        },
    };
    var c = cursor.asCursor();

    while (c.peek()) |_| try pos.parseNextType(allocator, &c);

    const p = try pos.collect(&std.testing.allocator);
    defer allocator.free(p.reminder.?);

    try t.expectEqual({}, p.tuple);
    const expect: []const []const u8 = &.{ "hello", "world!", "ha!" };
    try t.expectEqualDeep(expect, p.reminder.?);
}

test "parse tuple only" {
    const t = std.testing;
    const allocator = &std.testing.allocator;

    var pos: PositionalOf(.{
        .TupleType = struct { i32, bool, [3]u4 },
        .ReminderType = void,
    }) = .{};

    var cursor = coll.DebugCursor{
        .data = &.{
            "-13",
            "false",
            "[1,2,3]",
            "hello",
            "world!",
        },
    };
    var c = cursor.asCursor();

    for (0..3) |_| try pos.parseNextType(allocator, &c);
    const p = try pos.collect(allocator);

    try t.expectEqual(-13, p.tuple[0]);
    try t.expectEqual(false, p.tuple[1]);
    try t.expectEqualDeep(@as([]const u4, &.{ 1, 2, 3 }), &p.tuple[2]);
    try t.expectError(@TypeOf(pos).Error.ParseNextCalledOnTupleEnd, pos.parseNextType(allocator, &c));
    try t.expectEqual({}, p.reminder);
}

test "parse empty positional" {
    const t = std.testing;
    const allocator = &std.testing.allocator;

    var cursor = coll.DebugCursor{
        .data = &.{},
    };
    var c = cursor.asCursor();

    var pos: PositionalOf(.{
        .TupleType = void,
        .ReminderType = void,
    }) = .{};
    try t.expectError(@TypeOf(pos).Error.ParseNextCalledForEmptyPositional, pos.parseNextType(allocator, &c));

    const p = try pos.collect(allocator);
    try t.expectEqual({}, p.reminder);
    try t.expectEqual({}, p.tuple);
}

test "custom codec doubles i32 tuple input" {
    const t = std.testing;
    const allocator = &std.testing.allocator;

    const CustomCodec = struct {
        pub const Error = error{ InvalidType, ParseIntError } || std.fmt.ParseIntError;
        pub fn parseByType(
            self: *const @This(),
            comptime T: type,
            _: anytype,
            allc: *const std.mem.Allocator,
            cursor: *coll.Cursor([]const u8),
        ) Error!T {
            _ = self;
            _ = allc;
            if (T != i32) return Error.InvalidType;
            const s = cursor.next() orelse return Error.ParseIntError;
            const val: i32 = try std.fmt.parseInt(i32, s, 10);
            return val * 2;
        }
    };

    var pos: PositionalOf(.{
        .TupleType = struct { i32 },
        .ReminderType = void,
        .CodecType = CustomCodec,
    }) = .{};

    var cursor = coll.DebugCursor{
        .data = &.{"4"},
    };
    var c = cursor.asCursor();

    try pos.parseNextType(allocator, &c);
    const p = try pos.collect(allocator);

    try t.expectEqual(@as(i32, 8), p.tuple[0]);
}
