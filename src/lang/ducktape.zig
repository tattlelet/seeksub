const std = @import("std");
const meta = @import("meta.zig");
const trait = @import("trait.zig");
const Allocator = std.mem.Allocator;

// NOTE: use sparsingly, this will handle destroying a type through meta
// It will also encapsulate it in a delegate and erased trait-duo
// this is expensive but necessary if we want to create an air-gap shim
// between interfaces and concrete which have not agreed to implement said interface
pub const AnyDestroyable = struct {
    concrete: *anyopaque,
    vtable: *const struct {
        destroy: *const fn (*anyopaque, *const Allocator) void = undefined,
    },

    pub inline fn deinit(self: *AnyDestroyable) void {
        self.* = undefined;
    }

    pub inline fn destroy(self: *AnyDestroyable, allocator: *const Allocator) void {
        self.vtable.destroy(self.concrete, allocator);
    }
};

// Delegate
pub fn Destroyable(comptime T: type) type {
    return struct {
        value: *T,
        traits: *const struct {
            destroyable: *AnyDestroyable,
        },

        const Self = @This();

        pub fn init(allocator: *const Allocator, value: *T) !*Self {
            const self = try allocator.create(Self);
            self.traits = try trait.newTraitTable(allocator, self, .{
                try trait.extend(allocator, AnyDestroyable, self),
            });
            self.value = value;
            return self;
        }

        pub inline fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn destroy(self: *Self, allocator: *const Allocator) void {
            meta.destroy(allocator, self.value);
            trait.destroyTraits(allocator, self);
        }

        pub inline fn erased(self: *Self) *AnyDestroyable {
            return trait.asTrait(AnyDestroyable, self);
        }
    };
}

pub fn quackLikeOwned(allocator: *const Allocator, comptime Interface: type, concretePtr: anytype) !*Interface {
    comptime if (!@hasField(Interface, "destroyable"))
        @compileError(std.fmt.comptimePrint(
            "Interface: {s} - no field destroyable found",
            .{@typeName(Interface)},
        ));

    comptime if (std.meta.FieldType(Interface, .destroyable) != *AnyDestroyable)
        @compileError(std.fmt.comptimePrint(
            "Interface: {s} - destroyable is not *AnyDestroyable",
            .{@typeName(Interface)},
        ));

    return innerQuackLikeOwned(allocator, Interface, meta.ptrToChild(concretePtr), concretePtr);
}

inline fn innerQuackLikeOwned(allocator: *const Allocator, comptime Interface: type, Concrete: type, concretePtr: *Concrete) !*Interface {
    const destroyable = try Destroyable(Concrete).init(allocator, concretePtr);
    errdefer destroyable.destroy(allocator);

    var self = try trait.quackLike(allocator, Interface, concretePtr);
    self.destroyable = destroyable.erased();
    return self;
}

test "destroy generic" {
    const DoSomething = struct {
        allocator: Allocator,
        didSomething: *bool,

        pub fn init(allocator: Allocator) !@This() {
            const didSomething = try allocator.create(bool);
            didSomething.* = false;
            return .{
                .allocator = allocator,
                .didSomething = didSomething,
            };
        }

        pub fn do(self: *@This()) anyerror!bool {
            const old = self.didSomething;
            old.* = true;
            defer self.allocator.destroy(old);
            self.didSomething = try self.allocator.create(bool);
            self.didSomething.* = false;
            return old.*;
        }

        pub fn deinit(self: *@This()) void {
            self.allocator.destroy(self.didSomething);
            self.* = undefined;
        }
    };
    const I = struct {
        destroyable: *AnyDestroyable,
        concrete: *anyopaque,
        vtable: *const struct {
            do: *const fn (*anyopaque) anyerror!bool = undefined,
        },

        pub fn do(self: *@This()) anyerror!bool {
            return self.vtable.do(self.concrete);
        }

        pub fn deinit(self: *@This(), allocator: *const Allocator) void {
            self.destroyable.destroy(allocator);
            allocator.destroy(self);
        }
    };

    var allocator = @constCast(&std.testing.allocator);
    const doSomething = try allocator.create(DoSomething);
    errdefer allocator.destroy(doSomething);
    doSomething.* = try DoSomething.init(allocator.*);
    errdefer doSomething.deinit();

    const i = try quackLikeOwned(allocator, I, doSomething);
    defer i.deinit(allocator);

    try std.testing.expect(try i.do());
    try std.testing.expect(try i.do());
}
