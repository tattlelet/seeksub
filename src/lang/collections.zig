const std = @import("std");
const trait = @import("trait.zig");
const Allocator = std.mem.Allocator;
const SinglyLinkedList = std.SinglyLinkedList;

pub fn SinglyLinkedQueue(comptime T: type) type {
    return struct {
        start: ?*Node = null,
        end: ?*Node = null,
        len: usize = 0,
        allocator: *const Allocator,

        pub const Node = struct {
            data: T,
            next: ?*Node = null,

            pub fn init(allocator: *const Allocator, data: T) !*@This() {
                const self = try allocator.create(@This());
                self.next = null;
                self.data = data;
                return self;
            }

            pub fn deinit(self: *@This(), allocator: *const Allocator) void {
                allocator.destroy(self);
                self.next = undefined;
                self.data = undefined;
                self.* = undefined;
            }
        };

        pub fn append(self: *@This(), data: T) !void {
            const node = try Node.init(self.allocator, data);

            self.len += 1;
            if (self.end) |prevNode| {
                prevNode.next = node;
                self.end = node;
            } else {
                self.end = node;
                if (self.start == null) self.start = node;
            }
        }

        pub fn pop(self: *@This()) ?T {
            if (self.start) |sNode| {
                defer sNode.deinit(self.allocator);
                self.len -= 1;
                self.start = sNode.next;
                return sNode.data;
            }
            return null;
        }
    };
}

pub fn SinglyLinkedStack(comptime T: type) type {
    return struct {
        start: ?*Node = null,
        len: usize = 0,

        pub const Node = struct {
            data: T,
            next: ?*Node = null,

            pub fn init(allocator: *const Allocator, data: T) !*@This() {
                const self = try allocator.create(@This());
                self.next = null;
                self.data = data;
                return self;
            }

            pub fn deinit(self: *@This(), allocator: *const Allocator) void {
                allocator.destroy(self);
                self.next = undefined;
                self.data = undefined;
                self.* = undefined;
            }
        };

        pub fn prepend(self: *@This(), allocator: *const Allocator, data: T) !void {
            const node = try Node.init(allocator, data);

            self.len += 1;
            if (self.start) |prevNode| {
                node.next = prevNode;

                self.start = node;
            } else {
                self.start = node;
            }
        }

        pub fn pop(self: *@This()) ?T {
            if (self.start) |sNode| {
                self.len -= 1;
                self.start = sNode.next;
                return sNode.data;
            }
            return null;
        }

        pub fn peek(self: *@This()) ?T {
            return if (self.start) |sNode| sNode.data else null;
        }
    };
}

pub fn Iterator(T: type) type {
    return struct {
        concrete: *anyopaque,
        vtable: *VTable,

        pub const VTable = struct {
            next: *const fn (*anyopaque) ?T = undefined,
        };

        pub fn next(self: *@This()) ?T {
            return self.vtable.next(self.concrete);
        }
    };
}

pub fn Cursor(T: type) type {
    return struct {
        ptr: *anyopaque,
        vtable: *const VTable,
        curr: ?T,

        pub const VTable = struct {
            next: *const fn (*anyopaque) ?T = undefined,
        };

        pub fn next(self: *@This()) ?T {
            if (self.curr) |item| {
                self.curr = null;
                return item;
            }
            return self.vtable.next(self.ptr);
        }

        pub fn peek(self: *@This()) ?T {
            if (self.curr) |item| return item;
            self.curr = self.vtable.next(self.ptr);
            return self.curr;
        }

        pub fn consume(self: *@This()) void {
            _ = self.next();
        }

        pub fn stackItem(self: *@This(), item: T) void {
            self.curr = item;
        }
    };
}

pub fn UnitCursor(T: type) type {
    return struct {
        pub fn asCursor(item: ?T) Cursor(T) {
            return .{
                .curr = item,
                .ptr = @constCast(@ptrCast(&{})),
                .vtable = &.{
                    .next = @This().next,
                },
            };
        }

        pub fn asNoneCursor() Cursor(T) {
            return .{
                .curr = null,
                .ptr = @constCast(@ptrCast(&{})),
                .vtable = &.{
                    .next = @This().next,
                },
            };
        }

        pub fn next(cursor: *anyopaque) ?[]const u8 {
            _ = cursor;
            return null;
        }
    };
}

pub fn DFSCursor(T: type) type {
    return struct {
        stackQ: *SinglyLinkedStack(*SinglyLinkedQueue(T)),
        traits: *const struct {
            cursor: *Cursor(T),
        },

        pub fn init(allocator: *const Allocator, stackQ: *SinglyLinkedStack(*SinglyLinkedQueue(T))) !*@This() {
            var self = try allocator.create(@This());
            self.traits = try trait.newTraitTable(allocator, self, .{
                (try trait.extend(
                    allocator,
                    Cursor(T),
                    self,
                )).new(),
            });
            self.stackQ = stackQ;
            return self;
        }

        pub fn destroy(self: *@This(), allocator: *const Allocator) void {
            trait.destroyTraits(allocator, self);
        }

        pub fn next(self: *@This()) ?[:0]const u8 {
            const stack = self.stackQ;
            while (stack.peek() != null) : (_ = stack.pop()) {
                if (stack.peek()) |q| {
                    const optValue = q.pop();
                    if (optValue == null) continue;
                    defer if (q.len == 0) {
                        _ = stack.pop();
                    };
                    return optValue;
                }
            } else return null;
        }

        pub fn prependQueue(self: *@This(), allocator: *const Allocator, queue: *SinglyLinkedQueue(T)) Allocator.Error!void {
            try self.stackQ.prepend(allocator, queue);
        }
    };
}

pub fn QueueCursor(T: type) type {
    return struct {
        queue: *SinglyLinkedQueue(T),

        pub fn init(queue: *SinglyLinkedQueue(T)) @This() {
            return .{
                .queue = queue,
            };
        }

        pub fn asCursor(self: *const @This()) Cursor(T) {
            return .{
                .curr = null,
                .ptr = @constCast(self),
                .vtable = &.{
                    .next = next,
                },
            };
        }

        pub fn next(cursor: *anyopaque) ?[:0]const u8 {
            const self: *const @This() = @alignCast(@ptrCast(cursor));
            return self.queue.pop();
        }

        pub fn queueItem(self: *const @This(), item: T) Allocator.Error!void {
            try self.queue.append(item);
        }

        pub fn len(self: *const @This()) usize {
            return self.queue.len;
        }
    };
}

pub fn ArrayCursor(T: type) type {
    return struct {
        i: usize,
        list: []const T,

        pub fn init(list: []const T, start: usize) @This() {
            return .{
                .i = start,
                .list = list,
            };
        }

        pub fn asCursor(self: *@This()) Cursor(T) {
            return .{
                .curr = null,
                .ptr = self,
                .vtable = &.{
                    .next = next,
                },
            };
        }

        pub fn next(cursor: *anyopaque) ?T {
            var self: *@This() = @alignCast(@ptrCast(cursor));
            return if (self.i >= self.list.len) null else ret: {
                defer self.i += 1;
                break :ret self.list[self.i];
            };
        }
    };
}

pub fn ReverseTokenIterator(comptime T: type, comptime delimiter_type: std.mem.DelimiterType) type {
    return struct {
        buffer: []const T,
        delimiter: switch (delimiter_type) {
            .sequence, .any => []const T,
            .scalar => T,
        },
        index: usize,

        const Self = @This();

        /// Returns a slice of the current token, or null if tokenization is
        /// complete, and advances to the next token.
        pub fn next(self: *Self) ?[]const T {
            const result = self.peek() orelse return null;
            self.index -= result.len;
            return result;
        }

        /// Returns a slice of the current token, or null if tokenization is
        /// complete. Does not advance to the next token.
        pub fn peek(self: *Self) ?[]const T {
            // move to beginning of token
            while (self.index > 0 and self.isDelimiter(self.index)) : (self.index -= switch (delimiter_type) {
                .sequence => self.delimiter.len,
                .any, .scalar => 1,
            }) {}
            const end = self.index;
            if (end == 0) {
                return null;
            }

            // move to end of token
            var start = end;
            while (start > 0 and !self.isDelimiter(start)) : (start -= 1) {}

            return self.buffer[start..end];
        }

        /// Returns a slice of the remaining bytes. Does not affect iterator state.
        pub fn rest(self: Self) []const T {
            // move to beginning of token
            var index: usize = self.index;
            while (index > 0 and self.isDelimiter(index)) : (index -= switch (delimiter_type) {
                .sequence => self.delimiter.len,
                .any, .scalar => 1,
            }) {}
            return self.buffer[0..index];
        }

        /// Resets the iterator to the initial token.
        pub fn reset(self: *Self) void {
            self.index = self.buffer.len;
        }

        fn isDelimiter(self: Self, index: usize) bool {
            switch (delimiter_type) {
                .sequence => return std.mem.endsWith(T, self.buffer[0..index], self.delimiter),
                .any => {
                    const item = self.buffer[index - 1];
                    for (self.delimiter) |delimiter_item| {
                        if (item == delimiter_item) {
                            return true;
                        }
                    }
                    return false;
                },
                .scalar => return self.buffer[index - 1] == self.delimiter,
            }
        }
    };
}

test "reverse tokenizer" {
    const t = std.testing;
    const s: []const u8 = "conf.type.text.banana";
    var tokenizer = ReverseTokenIterator(u8, .scalar){
        .buffer = s,
        .delimiter = '.',
        .index = s.len,
    };

    try t.expectEqualStrings("banana", tokenizer.next().?);
    try t.expectEqualStrings("text", tokenizer.next().?);
    try t.expectEqualStrings("type", tokenizer.next().?);
    try t.expectEqualStrings("conf", tokenizer.next().?);
    try t.expectEqual(null, tokenizer.next());

    const s2: []const u8 = "conf.-.type.-.text.-.banana";
    var tokenizer2 = ReverseTokenIterator(u8, .sequence){
        .buffer = s2,
        .delimiter = ".-.",
        .index = s2.len,
    };

    try t.expectEqualStrings("banana", tokenizer2.next().?);
    try t.expectEqualStrings("text", tokenizer2.next().?);
    try t.expectEqualStrings("type", tokenizer2.next().?);
    try t.expectEqualStrings("conf", tokenizer2.next().?);
    try t.expectEqual(null, tokenizer2.next());
}
