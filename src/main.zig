const std = @import("std");
const SpecResponse = @import("lang/args/spec.zig").SpecResponse;
const PositionalOf = @import("lang/args/spec.zig").PositionalOf;
const Cursor = @import("lang/collections.zig").Cursor;

pub const Args = struct {
    ranges: [4][2]u7 = undefined,

    pub const Positional = PositionalOf(void, void, {});
};

pub fn AsCursor(comptime T: type) type {
    return struct {
        pub fn next(erased: *anyopaque) ?[]const u8 {
            const cursor: *T = @alignCast(@ptrCast(erased));
            return cursor.next();
        }
    };
}

pub fn main() !void {
    var buff: [@alignOf(Args) * 500]u8 = undefined;
    var fx = std.heap.FixedBufferAllocator.init(&buff);
    const allocator = fx.allocator();
    // const allocator = std.heap.page_allocator;

    const t0 = std.time.nanoTimestamp();
    var argIter = try std.process.argsWithAllocator(allocator);
    defer argIter.deinit();
    // const t1 = std.time.nanoTimestamp();
    var result = SpecResponse(Args).init(allocator);
    defer result.deinit();
    // const t2 = std.time.nanoTimestamp();
    var cursor = rv: {
        var c = Cursor([]const u8){
            .curr = null,
            .ptr = &argIter,
            .vtable = &.{
                .next = &AsCursor(@TypeOf(argIter)).next,
            },
        };
        break :rv &c;
    };
    _ = &cursor;
    // const t3 = std.time.nanoTimestamp();

    try result.parse(cursor);
    const t4 = std.time.nanoTimestamp();

    std.log.err("parse: {d}ns", .{t4 - t0});
    // std.log.err("{any}", .{result.options.ranges});
}
