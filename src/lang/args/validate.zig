const std = @import("std");
const argIter = @import("iterator.zig");

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

pub fn GroupMatchConfig(Spec: type) type {
    const SpecEnumFields = std.meta.FieldEnum(Spec);
    return struct {
        mutuallyInclusive: []const []const SpecEnumFields = &.{},
        mutuallyExclusive: []const []const SpecEnumFields = &.{},
        required: []const SpecEnumFields = &.{},
        mandatoryVerb: bool = false,
        ensureCursorDone: bool = true,
    };
}

pub fn GroupTracker(Spec: type) type {
    std.debug.assert(@TypeOf(Spec.GroupMatch) == GroupMatchConfig(Spec));
    return GroupTrackerWithConfig(Spec, Spec.GroupMatch);
}

pub fn GroupTrackerWithConfig(Spec: type, comptime config: GroupMatchConfig(Spec)) type {
    const SpecEnumFields = std.meta.FieldEnum(Spec);

    return struct {
        fbset: FieldBitSet(Spec) = .{},
        verb: bool = false,
        cursorDoneFlag: bool = false,

        pub const Error = error{
            MissingRequiredField,
            MutuallyInclusiveConstraintNotMet,
            MutuallyExclusiveConstraintNotMet,
            MissingVerb,
            CursorNotDone,
        };

        pub fn parsed(self: *@This(), comptime tag: SpecEnumFields) void {
            self.fbset.fieldSet(tag);
        }

        pub fn parsedVerb(self: *@This()) void {
            self.verb = true;
        }

        pub fn cursorDone(self: *@This()) void {
            self.cursorDoneFlag = true;
        }

        pub fn checkRequired(self: *const @This()) Error!void {
            if (!self.fbset.allOf(config.required)) return Error.MissingRequiredField;
        }

        pub fn checkMutuallyInclusive(self: *const @This()) Error!void {
            inline for (config.mutuallyInclusive) |group| {
                if (!self.fbset.allOf(group)) return Error.MutuallyInclusiveConstraintNotMet;
            }
        }

        pub fn checkMutuallyExclusive(self: *const @This()) Error!void {
            inline for (config.mutuallyExclusive) |group| {
                if (!self.fbset.oneOf(group)) return Error.MutuallyExclusiveConstraintNotMet;
            }
        }

        pub fn checkVerb(self: *const @This()) Error!void {
            if (comptime config.mandatoryVerb) {
                if (!self.verb) return Error.MissingVerb;
            }
        }

        pub fn checkCursorDone(self: *const @This()) Error!void {
            if (comptime config.ensureCursorDone) {
                if (!self.cursorDoneFlag) return Error.CursorNotDone;
            }
        }

        // TODO: add validation chains (if a, then b, but only if a)
        pub fn validate(self: *const @This()) Error!void {
            try self.checkMutuallyExclusive();
            try self.checkMutuallyInclusive();
            try self.checkRequired();
            try self.checkVerb();
            try self.checkCursorDone();
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
        i7: ?i32 = null,
        i8: ?i32 = null,

        pub const GroupMatch: GroupMatchConfig(@This()) = .{
            .mutuallyInclusive = &.{
                &.{ .i, .i2 },
                &.{ .i3, .i4 },
            },
            .mutuallyExclusive = &.{
                &.{ .i5, .i6 },
            },
            .required = &.{ .i7, .i8 },
            .mandatoryVerb = true,
        };
    };

    var tracker = GroupTracker(Spec){};
    try t.expectError(@TypeOf(tracker).Error.MutuallyExclusiveConstraintNotMet, tracker.validate());
    try t.expectError(@TypeOf(tracker).Error.MutuallyExclusiveConstraintNotMet, tracker.checkMutuallyExclusive());
    tracker.parsed(.i5);
    try t.expectEqual({}, try tracker.checkMutuallyExclusive());
    const tracker1 = tracker;
    tracker.parsed(.i6);
    try t.expectError(@TypeOf(tracker).Error.MutuallyExclusiveConstraintNotMet, tracker.checkMutuallyExclusive());
    tracker = tracker1;

    try t.expectError(@TypeOf(tracker).Error.MutuallyInclusiveConstraintNotMet, tracker.validate());
    try t.expectError(@TypeOf(tracker).Error.MutuallyInclusiveConstraintNotMet, tracker.checkMutuallyInclusive());
    tracker.parsed(.i);
    tracker.parsed(.i2);
    try t.expectError(@TypeOf(tracker).Error.MutuallyInclusiveConstraintNotMet, tracker.checkMutuallyInclusive());
    tracker.parsed(.i3);
    tracker.parsed(.i4);
    try t.expectEqual({}, try tracker.checkMutuallyInclusive());

    try t.expectError(@TypeOf(tracker).Error.MissingRequiredField, tracker.validate());
    try t.expectError(@TypeOf(tracker).Error.MissingRequiredField, tracker.checkRequired());
    tracker.parsed(.i7);
    tracker.parsed(.i8);
    try t.expectEqual({}, try tracker.checkRequired());

    try t.expectError(@TypeOf(tracker).Error.MissingVerb, tracker.validate());
    try t.expectError(@TypeOf(tracker).Error.MissingVerb, tracker.checkVerb());
    tracker.parsedVerb();
    try t.expectEqual({}, try tracker.checkVerb());

    try t.expectError(@TypeOf(tracker).Error.CursorNotDone, tracker.validate());
    try t.expectError(@TypeOf(tracker).Error.CursorNotDone, tracker.checkCursorDone());
    tracker.cursorDone();
    try t.expectEqual({}, try tracker.validate());
    try t.expectEqual({}, try tracker.checkCursorDone());
}
