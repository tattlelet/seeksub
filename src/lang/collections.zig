const std = @import("std");
const trait = @import("trait.zig");
const Allocator = std.mem.Allocator;
const SinglyLinkedList = std.SinglyLinkedList;

pub fn SinglyLinkedQueue(comptime T: type) type {
    return struct {
        start: ?*Node = null,
        end: ?*Node = null,
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

        pub fn append(self: *@This(), allocator: *const Allocator, data: T) !void {
            const node = try Node.init(allocator, data);

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

// NOTE: should this guy transition into iterator? sounds unecessary
pub fn Cursor(T: type) type {
    return struct {
        concrete: *anyopaque,
        vtable: *const VTable,
        curr: ?T,

        pub const VTable = struct {
            destroy: *const fn (*anyopaque, *const Allocator) void = undefined,
            next: *const fn (*anyopaque) ?T = undefined,
            peek: *const fn (*anyopaque) ?T = undefined,
            consume: *const fn (*anyopaque) void = undefined,
            stackItem: *const fn (*anyopaque, item: T) void = undefined,
        };

        pub fn new(self: *@This()) *@This() {
            self.curr = null;
            return self;
        }

        pub fn destroy(self: *@This(), allocator: *const Allocator) void {
            self.vtable.destroy(self.concrete, allocator);
        }

        pub fn next(self: *@This()) ?T {
            if (self.curr) |item| {
                self.curr = null;
                return item;
            }
            return self.vtable.next(self.concrete);
        }

        pub fn peek(self: *@This()) ?T {
            if (self.curr) |item| return item;
            self.curr = self.vtable.peek(self.concrete);
            return self.curr;
        }

        pub fn consume(self: *@This()) void {
            self.vtable.consume(self.concrete);
        }

        pub fn stackItem(self: *@This(), item: T) void {
            self.vtable.stackItem(self.concrete, item);
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

        fn dfsNext(self: *@This()) ?[:0]const u8 {
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

        pub fn next(self: *@This()) ?[:0]const u8 {
            return self.dfsNext();
        }

        pub fn peek(self: *@This()) ?[:0]const u8 {
            return self.dfsNext();
        }

        pub fn consume(self: *@This()) void {
            _ = self.traits.cursor.next();
        }

        pub fn stackItem(self: *@This(), item: T) void {
            self.traits.cursor.curr = item;
        }

        pub fn prependQueue(self: *@This(), allocator: *const Allocator, queue: *SinglyLinkedQueue(T)) Allocator.Error!void {
            try self.stackQ.prepend(allocator, queue);
        }
    };
}
