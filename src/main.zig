const std = @import("std");
const SpecResponse = @import("lang/args/spec.zig").SpecResponse;
const Cursor = @import("lang/collections.zig").Cursor;

pub const Args = struct {
    ranges: [4][2]i8 = undefined,

    pub const Positional: void = {};
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
    // var buff: [@alignOf(Args) * 500]u8 = undefined;
    // var fx = std.heap.FixedBufferAllocator.init(&buff);
    // const allocator = fx.allocator();
    const allocator = std.heap.page_allocator;
    const hot: *u8 = try allocator.create(u8);
    defer allocator.destroy(hot);

    const t0 = std.time.nanoTimestamp();
    var argIter = try std.process.argsWithAllocator(allocator);
    defer argIter.deinit();
    const t1 = std.time.nanoTimestamp();
    var result = SpecResponse(Args).init(allocator);
    defer result.deinit();
    const t2 = std.time.nanoTimestamp();
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
    const t3 = std.time.nanoTimestamp();

    try result.parse(cursor);
    const t4 = std.time.nanoTimestamp();

    const writer = std.io.getStdOut().writer();

    try writer.print("Args init: {d}ns\n", .{t1 - t0});
    try writer.print("Spec init: {d}ns\n", .{t2 - t1});
    try writer.print("Cursor init: {d}ns\n", .{t3 - t2});
    try writer.print("parse: {d}ns\n", .{t4 - t3});
    try writer.print("total: {d}ns\n", .{t4 - t0});
    try writer.print("{any}\n", .{result.options.ranges});
}
