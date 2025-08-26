const std = @import("std");
const compPrint = std.fmt.comptimePrint;
const BltType = std.builtin.Type;
const Allocator = std.mem.Allocator;

// NOTE: self.* undefined can only be done from the inside
pub inline fn destroy(allocator: *const Allocator, concrete: anytype) void {
    const Concrete = @TypeOf(concrete);
    const ptrChild = ptrToChild(Concrete);
    const ptrChildType = @typeInfo(ptrChild);
    // Call deinit
    switch (ptrChildType) {
        .@"struct" => {
            if (@hasDecl(ptrChild, "deinit")) {
                const params: []const BltType.Fn.Param = comptime blk: {
                    const deinitField = @field(ptrChild, "deinit");
                    const fType = @TypeOf(deinitField);
                    const fTypeInfo = @typeInfo(fType);
                    break :blk switch (fTypeInfo) {
                        .@"fn" => |fInfo| fInfo.params,
                        else => @compileError(std.fmt.comptimePrint(
                            "Concrete: {} - Called meta destroy on type with non-fn deinit",
                            .{@typeName(ptrChild)},
                        )),
                    };
                };
                switch (params.len) {
                    2 => {
                        switch (params[1].type.?) {
                            Allocator => concrete.deinit(allocator.*),
                            *const Allocator => concrete.deinit(allocator),
                            else => @compileError(compPrint(
                                "Concrete: {} - Invalid type of param for 2nd param",
                                .{ptrChild},
                            )),
                        }
                    },
                    1 => concrete.deinit(),
                    else => @compileError(compPrint(
                        "Concrete: {} - Invalid number of params for deinit",
                        .{ptrChild},
                    )),
                }
            }
        },
        else => {},
    }
    // Default self-destory, happens in all branches
    allocator.destroy(concrete);
}

test "destroy general" {
    var allocator = @constCast(&std.testing.allocator);
    const value = try allocator.create(u8);
    defer destroy(allocator, value);

    const st = try allocator.create(struct { u: u32 });
    defer destroy(allocator, st);
}

test "destroy 1 param" {
    var called = false;
    var allocator = @constCast(&std.testing.allocator);
    const v = try allocator.create(struct {
        called: *bool,
        pub fn deinit(self: *@This()) void {
            self.called.* = true;
            self.* = undefined;
        }
    });
    v.called = &called;
    destroy(allocator, v);
    try std.testing.expect(called);
}

test "destroy 2 param" {
    var called = false;
    var allocator = @constCast(&std.testing.allocator);
    const c = try allocator.create(struct {
        called: *bool,
        pub fn deinit(self: *@This(), allc: *const Allocator) void {
            _ = allc;
            self.called.* = true;
        }
    });
    c.called = &called;
    destroy(@constCast(allocator), c);
    try std.testing.expect(called);
}

// INFO: Not comptime
pub inline fn ptrToChild(ptr: anytype) type {
    const ptrT = @TypeOf(ptr);
    return ptrTypeToChild(switch (@typeInfo(ptrT)) {
        .type => ptr,
        .pointer => ptrT,
        else => @compileError(compPrint(
            "Type {s} is not a ptr",
            .{@typeName(@TypeOf(ptr))},
        )),
    });
}

pub inline fn ptrTypeToChild(comptime PtrType: type) type {
    return switch (@typeInfo(PtrType)) {
        .pointer => std.meta.Child(PtrType),
        else => |t| @compileError(compPrint(
            "Argument PtrType is not a Pointer. Found: {s}",
            .{@tagName(t)},
        )),
    };
}

test "ptr to type" {
    const value: u8 = 'c';
    const p = &value;

    try std.testing.expectEqual(u8, ptrToChild(p));
    try std.testing.expectEqual(u8, ptrTypeToChild(*u8));
}

pub fn OptTypeOf(T: type) type {
    return comptime switch (@typeInfo(T)) {
        .optional => |opt| opt.child,
        else => T,
    };
}

pub fn LeafTypeOfTag(T: type, comptime tag: []const u8) type {
    return TypeAtDepth(T, tag, .concrete);
}

pub fn LeafArrayTypeOfTag(T: type, comptime tag: []const u8) type {
    return TypeAtDepth(T, tag, .lastPtr);
}

// This is annoyingly strict on purpose
pub const AtDepthArgs = enum(usize) {
    @"0" = 0,
    @"1" = 1,
    @"2" = 2,
    @"3" = 3,
    concrete = 20,
    lastPtr,
};

pub fn TypeAtDepthN(T: type, comptime tag: []const u8, comptime n: usize) type {
    return comptime switch (n) {
        0...3 => TypeAtDepth(T, tag, @enumFromInt(n)),
        else => @compileError(std.fmt.comptimePrint("Depth of {d} is unsupported", .{n})),
    };
}

pub fn TypeAtDepth(T: type, comptime tag: []const u8, comptime depth: AtDepthArgs) type {
    // + 1 at the end because depth is usize :)
    comptime var maxDepth: usize = switch (depth) {
        .concrete => 3,
        .lastPtr => 2,
        else => |en| @intFromEnum(en),
    };

    return T: {
        comptime var Tt = OptTypeOf(@FieldType(T, tag));
        comptime while (maxDepth > 0) : (maxDepth -= 1) {
            switch (@typeInfo(Tt)) {
                // TODO: add array, optional and vector
                .pointer => |ptr| {
                    if (@typeInfo(ptr.child) != .pointer and depth == .lastPtr) break :T Tt else Tt = ptr.child;
                },
                else => break :T Tt,
            }
        } else {
            switch (@intFromEnum(depth)) {
                0...3 => break :T Tt,
                else => @compileError(std.fmt.comptimePrint(
                    "Pointer chain for {s} is longer than max depth supported by {s}",
                    .{ tag, @tagName(depth) },
                )),
            }
        };
    };
}
