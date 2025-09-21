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

pub fn OptTypeOf(comptime T: type) type {
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
    concrete = 20,
    lastPtr,
};

pub fn TypeAtDepth(T: type, comptime tag: []const u8, comptime depth: AtDepthArgs) type {
    // + 1 at the end because depth is usize :)
    comptime var maxDepth: usize = switch (depth) {
        .concrete => 3,
        .lastPtr => 2,
    };

    return T: {
        comptime var Tt = OptTypeOf(@FieldType(T, tag));
        comptime while (maxDepth > 0) : (maxDepth -= 1) {
            switch (@typeInfo(Tt)) {
                // TODO: add array, optional and vector
                .pointer => |ptr| {
                    if (@typeInfo(ptr.child) != .pointer and depth == .lastPtr) break :T Tt else Tt = ptr.child;
                },
                .optional => |ptr| {
                    Tt = ptr.child;
                },
                else => break :T Tt,
            }
        } else @compileError(std.fmt.comptimePrint(
            "Pointer chain for {s} is longer than max depth supported by {s}",
            .{ tag, @tagName(depth) },
        ));
    };
}

pub fn stringToEnum(comptime T: type, str: []const u8) ?T {
    inline for (@typeInfo(T).@"enum".fields) |enumField| {
        if (std.mem.eql(u8, str, enumField.name)) {
            return @field(T, enumField.name);
        }
    }
    return null;
}

pub fn isUndefined(field: std.builtin.Type.StructField) bool {
    // NOTE: https://github.com/ziglang/zig/issues/18047#issuecomment-1818265581
    // Apparently not IB but would keep an eye on this
    return comptime field.default_value_ptr != null and field.default_value_ptr.? == @as(*const anyopaque, @ptrCast(&@as(field.type, undefined)));
}

pub fn FieldEnum(comptime T: type) type {
    const field_infos = std.meta.fields(T);

    if (field_infos.len == 0) {
        return @Type(.{
            .@"enum" = .{
                .tag_type = u0,
                .fields = &.{},
                .decls = &.{},
                .is_exhaustive = true,
            },
        });
    }

    if (@typeInfo(T) == .@"union") {
        if (@typeInfo(T).@"union".tag_type) |tag_type| {
            for (std.enums.values(tag_type), 0..) |v, i| {
                if (@intFromEnum(v) != i) break; // enum values not consecutive
                if (!std.mem.eql(u8, @tagName(v), field_infos[i].name)) break; // fields out of order
            } else {
                return tag_type;
            }
        }
    }

    var enumFields: [field_infos.len]std.builtin.Type.EnumField = undefined;
    var decls = [_]std.builtin.Type.Declaration{};
    inline for (field_infos, 0..) |field, i| {
        enumFields[i] = .{
            .name = field.name ++ "",
            .value = i,
        };
    }
    return @Type(.{
        .@"enum" = .{
            .tag_type = std.math.IntFittingRange(0, field_infos.len),
            .fields = &enumFields,
            .decls = &decls,
            .is_exhaustive = true,
        },
    });
}
