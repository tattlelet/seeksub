const std = @import("std");
const Allocator = std.mem.Allocator;
const trait = @import("trait.zig");
const meta = @import("meta.zig");

// WARN: this is actually kinda useless since move isnt enforced or
// managed
pub fn Uniq(T: type) type {
    return struct {
        value: T,

        pub fn init(allocator: *const Allocator, value: T) !*Uniq(T) {
            var self = try allocator.create(Uniq(T));
            self.value = value;
            return self;
        }

        pub fn move(self: *Uniq(T), allocator: *const Allocator) !*Uniq(T) {
            const other = try Uniq(T).init(allocator, self.value);
            allocator.destroy(self);
            self.* = undefined;
            return other;
        }

        pub fn deinit(self: *Uniq(T), allocator: *const Allocator) void {
            meta.destroy(allocator, self.value);
            allocator.destroy(self);
        }
    };
}

test "uniq move" {
    var allocator = std.testing.allocator;
    const value = try allocator.create(u8);
    value.* = 'c';

    // Uniq1 will be moved so it doesnt need to be de-inited
    const uniq1 = try Uniq(@TypeOf(value)).init(&allocator, value);

    try std.testing.expect(uniq1.value == value);

    const uniq2 = try uniq1.move(&allocator);
    // Deiniting uniq2 will deinit value;
    defer uniq2.deinit(&allocator);
    try std.testing.expect(uniq1 != uniq2);
    try std.testing.expect(uniq2.value == value);
}

const SharedErrors = error{RefCountOverflow};

// NOTE: this is useful only as a convention since it can't be enforced
pub fn Shared(T: type) type {
    return struct {
        count: usize,
        value: T,

        pub fn init(allocator: *const Allocator, value: T) !*Shared(T) {
            var self = try allocator.create(Shared(T));
            self.count = 1;
            self.value = value;

            return self;
        }

        pub fn deinit(self: *Shared(T), allocator: *const Allocator) void {
            if (self.count > 1) {
                self.count = self.count - 1;
            } else {
                meta.destroy(allocator, self.value);
                allocator.destroy(self);
            }
        }

        pub fn share(self: *Shared(T)) SharedErrors!*Shared(T) {
            const count, const overflow = @addWithOverflow(self.count, 1);
            if (overflow != 0)
                return SharedErrors.RefCountOverflow;
            self.count = count;
            return self;
        }
    };
}

test "refcount deinit" {
    const Custom = struct { x: u32 };

    var allocator = std.testing.allocator;

    const c = try allocator.create(Custom);
    c.x = 10;

    var s1 = try Shared(*Custom).init(&allocator, c);
    var s2 = try s1.share();
    var s3 = try s1.share();

    try std.testing.expectEqual(3, s1.count);
    try std.testing.expect(s2.value == s1.value);
    try std.testing.expect(s3.value == s1.value);
    try std.testing.expect(s1.value == c);

    s3.deinit(&allocator);

    try std.testing.expectEqual(2, s1.count);
    try std.testing.expect(s2.value == s1.value);
    try std.testing.expect(s3.value == s1.value);
    try std.testing.expect(s1.value == c);

    s2.deinit(&allocator);

    try std.testing.expect(s2.value == s1.value);
    try std.testing.expect(s3.value == s1.value);
    try std.testing.expect(s1.value == c);

    s1.deinit(&allocator);
    // Up to last free, all references are still available
}

test "destroy with deinit" {
    var called = false;
    const Custom = struct {
        x: u32,
        called: *bool,

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            self.called.* = true;
            self.called = undefined;
            _ = allocator;
        }
    };

    var allocator = std.testing.allocator;
    const c = try allocator.create(Custom);
    c.x = 10;
    c.called = &called;

    var s1 = try Shared(*Custom).init(&allocator, c);
    try std.testing.expectEqual(1, s1.count);
    try std.testing.expect(s1.value == c);

    s1.deinit(&allocator);

    try std.testing.expect(called);
}
