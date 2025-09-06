const std = @import("std");
const meta = @import("../meta.zig");
const coll = @import("../collections.zig");
const argIter = @import("iterator.zig");
const argCodec = @import("codec.zig");
const Allocator = std.mem.Allocator;

pub fn FieldBitSet(Spec: type) type {
    const SpecEnumFields = std.meta.FieldEnum(Spec);
    const size = std.meta.fields(Spec).len;
    const BitSet = std.bit_set.StaticBitSet(size);

    return struct {
        bitset: BitSet = BitSet.initEmpty(),

        pub fn fieldSet(self: *@This(), comptime tag: SpecEnumFields) void {
            const i = comptime std.meta.fieldIndex(Spec, @tagName(tag)) orelse @compileError(std.fmt.comptimePrint(
                "Invalid tag {s} for Spec {s}",
                .{ @tagName(tag), @typeName(Spec) },
            ));
            self.bitset.set(i);
        }

        fn makeMask(comptime tags: anytype) BitSet {
            var tmp = BitSet.initEmpty();
            for (tags) |tag| {
                const i = std.meta.fieldIndex(Spec, @tagName(tag)) orelse @compileError(std.fmt.comptimePrint(
                    "Invalid tag {s} for Spec {s}",
                    .{ @tagName(tag), @typeName(Spec) },
                ));
                tmp.set(i);
            }
            return tmp;
        }

        pub fn allOf(self: *const @This(), comptime tags: anytype) bool {
            return self.bitset.supersetOf(comptime makeMask(tags));
        }

        pub fn oneOf(self: *const @This(), comptime tags: anytype) bool {
            return self.bitset.intersectWith(comptime makeMask(tags)).count() == 1;
        }
    };
}

test "track bits for field" {
    const t = std.testing;
    const Spec = struct {
        a: i32,
        b: i32,
        c: i32,
    };
    var fbset = FieldBitSet(Spec){};
    fbset.fieldSet(.a);
    fbset.fieldSet(.c);
    try t.expectEqual(5, fbset.bitset.mask);

    try t.expectEqual(true, fbset.allOf(.{.a}));
    try t.expectEqual(false, fbset.allOf(.{.b}));
    try t.expectEqual(true, fbset.allOf(.{.c}));
    try t.expectEqual(false, fbset.allOf(.{ .a, .b }));
    try t.expectEqual(true, fbset.allOf(.{ .a, .c }));
    try t.expectEqual(false, fbset.allOf(.{ .b, .c }));
    try t.expectEqual(false, fbset.allOf(.{ .a, .b, .c }));

    try t.expectEqual(true, fbset.oneOf(.{.a}));
    try t.expectEqual(false, fbset.oneOf(.{.b}));
    try t.expectEqual(true, fbset.oneOf(.{.c}));
    try t.expectEqual(true, fbset.oneOf(.{ .a, .b }));
    try t.expectEqual(false, fbset.oneOf(.{ .a, .c }));
    try t.expectEqual(true, fbset.oneOf(.{ .b, .c }));
    try t.expectEqual(false, fbset.oneOf(.{ .a, .b, .c }));
}

pub fn GroupTracker(Spec: type) type {
    const SpecEnumFields = std.meta.FieldEnum(Spec);

    return struct {
        fbset: FieldBitSet(Spec) = .{},
        const GroupMatch = Spec.GroupMatch;

        pub const Error = error{
            MissingRequiredField,
            MutuallyInclusiveConstraintNotMet,
            MutuallyExclusiveConstraintNotMet,
        };

        pub fn parsed(self: *@This(), comptime tag: SpecEnumFields) void {
            self.fbset.fieldSet(tag);
        }

        pub fn required(self: *const @This()) Error!void {
            if (!self.fbset.allOf(GroupMatch.required)) return Error.MissingRequiredField;
        }

        pub fn mutuallyInclusive(self: *const @This()) Error!void {
            inline for (GroupMatch.mutuallyInclusive) |group| {
                if (!self.fbset.allOf(group)) return Error.MutuallyInclusiveConstraintNotMet;
            }
        }

        pub fn mutuallyExclusive(self: *const @This()) Error!void {
            inline for (GroupMatch.mutuallyExclusive) |group| {
                if (!self.fbset.oneOf(group)) return Error.MutuallyExclusiveConstraintNotMet;
            }
        }

        pub fn validate(self: *const @This()) Error!void {
            try self.mutuallyExclusive();
            try self.mutuallyInclusive();
            try self.required();
        }
    };
}

test "check required fields" {
    const t = std.testing;
    const Spec = struct {
        i: ?i32 = null,
        i2: ?i32 = null,
        i3: ?i32 = null,
        i4: ?i32 = null,
        i5: ?i32 = null,
        i6: ?i32 = null,

        pub const GroupMatch = .{
            .mutuallyInclusive = .{
                .{ .i, .i2 },
                .{ .i3, .i4 },
            },
            .mutuallyExclusive = .{
                .{ .i5, .i6 },
            },
            .required = .{ .i, .i2 },
        };
    };

    var tracker = GroupTracker(Spec){};
    tracker.parsed(.i);
    try t.expectError(@TypeOf(tracker).Error.MissingRequiredField, tracker.required());
    tracker.parsed(.i2);
    try t.expectEqual({}, try tracker.required());

    try t.expectError(@TypeOf(tracker).Error.MutuallyInclusiveConstraintNotMet, tracker.mutuallyInclusive());
    tracker.parsed(.i3);
    tracker.parsed(.i4);
    try t.expectEqual({}, try tracker.mutuallyInclusive());

    try t.expectError(@TypeOf(tracker).Error.MutuallyExclusiveConstraintNotMet, tracker.mutuallyExclusive());
    tracker.parsed(.i5);
    try t.expectEqual({}, try tracker.mutuallyExclusive());
    tracker.parsed(.i6);
    try t.expectError(@TypeOf(tracker).Error.MutuallyExclusiveConstraintNotMet, tracker.mutuallyExclusive());
}
