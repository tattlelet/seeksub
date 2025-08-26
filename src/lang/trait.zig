const std = @import("std");
const meta = @import("meta.zig");
const compPrint = std.fmt.comptimePrint;
const BltType = std.builtin.Type;
const Allocator = std.mem.Allocator;

inline fn traitTableType(concrete: type) type {
    return std.meta.Child(std.meta.FieldType(
        meta.ptrTypeToChild(concrete),
        .traits,
    ));
}

test "fetch trait type" {
    const C = struct {
        traits: *const Table,
        pub const Table = struct {};
    };
    const c = C{ .traits = &.{} };
    try std.testing.expectEqual(C.Table, traitTableType(@TypeOf(&c)));
}

pub inline fn destroyTraits(allocator: *const Allocator, concrete: anytype) void {
    innerDeinitTraits(allocator, traitTableType(@TypeOf(concrete)), concrete);
}

inline fn innerDeinitTraits(allocator: *const Allocator, comptime Ttrait: type, concrete: anytype) void {
    // trait is sanitized in destroyTraits
    const trait = concrete.traits;
    inline for (comptime std.meta.fieldNames(Ttrait)) |name| {
        const field = @field(trait.*, name);
        meta.destroy(allocator, field);
    }
    meta.destroy(allocator, trait);
    meta.destroy(allocator, concrete);
}

test "deinit trait" {
    const allocator = @constCast(&std.testing.allocator);
    const I = struct {
        concrete: *anyopaque,
        vtable: *const struct {
            eval: *const fn (*const anyopaque) bool = undefined,
        },
    };

    const c = try (struct {
        traits: *const struct {
            ix: *const I,
        },

        pub fn init(allc: *const Allocator) !*@This() {
            const self = try allocator.create(@This());
            self.traits = try newTraitTable(allocator, self, .{
                try extend(allc, I, self),
            });
            return self;
        }

        pub fn eval(self: *const @This()) bool {
            _ = self;
            return true;
        }
    }).init(allocator);

    defer destroyTraits(allocator, c);
}

pub fn isTraitOf(comptime Interface: type, comptime Concrete: type) bool {
    _ = traitTableSearch(Interface, Concrete) orelse return false;
    return true;
}

inline fn traitTableOf(comptime Concrete: type) ?type {
    const tType = @FieldType(Concrete, "traits");
    if (@typeInfo(tType) != .pointer) return null;

    return meta.ptrTypeToChild(tType);
}

inline fn traitTableFields(comptime Concrete: type) ?[]const BltType.StructField {
    const cInfo = @typeInfo(Concrete);
    if (cInfo != .@"struct") return null;
    if (!@hasField(Concrete, "traits")) return null;

    const tInfo = @typeInfo(traitTableOf(Concrete) orelse return null);
    return switch (tInfo) {
        .@"struct" => |t| t.fields,
        else => null,
    };
}

inline fn traitTableSearch(comptime Interface: type, comptime Concrete: type) ?BltType.StructField {
    const iInfo = @typeInfo(Interface);
    if (iInfo != .@"struct") return null;

    const tFields = comptime traitTableFields(Concrete) orelse return null;
    return comptime outer: {
        for (tFields) |tField| {
            const fInfo = @typeInfo(tField.type);
            if (fInfo == .pointer and fInfo.pointer.child == Interface) break :outer tField;
        }
        break :outer null;
    };
}

test "is trait of" {
    const I1 = struct {};
    const I2 = struct {};
    const I3 = struct {};
    const C = struct { traits: *const struct {
        i1: *I1,
        i2: *const I2,
        i3: I3,
    } };
    try std.testing.expect(isTraitOf(I1, C));
    try std.testing.expect(isTraitOf(I2, C));
    try std.testing.expect(!isTraitOf(I3, C));
    try std.testing.expect(!isTraitOf(u8, C));
}

pub fn asTrait(comptime Interface: type, concretePtr: anytype) T: {
    const Concrete = meta.ptrTypeToChild(@TypeOf(concretePtr));
    break :T (traitTableSearch(Interface, Concrete) orelse
        @compileError(compPrint(
            "Concrete: {s} - there's not trait of {s} inside trait table",
            .{ @typeName(Concrete), @typeName(Interface) },
        ))).type;
} {
    const Concrete = meta.ptrToChild(concretePtr);
    const tField = traitTableSearch(Interface, Concrete) orelse
        @compileError(compPrint(
            "Concrete: {s} - there's not trait of {s} inside trait table",
            .{ @typeName(Concrete), @typeName(Interface) },
        ));

    // traits were sanitized by traitTableSearch
    return @field(concretePtr.traits, tField.name);
}

test "as trait" {
    const I1 = struct {};
    const I2 = struct {};
    const C = struct { traits: *const struct {
        i1: *I1,
        i2: *const I2,
    } };
    const c = C{
        .traits = &.{
            .i1 = @constCast(&I1{}),
            .i2 = &.{},
        },
    };

    try std.testing.expectEqual(*I1, @TypeOf(asTrait(I1, &c)));
    try std.testing.expectEqual(*const I2, @TypeOf(asTrait(I2, &c)));
}

pub fn extend(allocator: *const Allocator, comptime Interface: type, concretePtr: anytype) !*Interface {
    return extendInternal(allocator, Interface, concretePtr, true);
}

inline fn extendInternal(allocator: *const Allocator, comptime Interface: type, concretePtr: anytype, comptime checkTrait: bool) !*Interface {
    const iTypeName = @typeName(Interface);

    const Concrete = meta.ptrToChild(concretePtr);
    const cTypeName = @typeName(Concrete);
    comptime if (checkTrait and !isTraitOf(Interface, Concrete))
        @compileError(compPrint(
            "Concrete: {s} - there's not trait of {s} inside definition or trait isnt declared in table",
            .{ cTypeName, iTypeName },
        ));

    // Sanity check vtable
    comptime if (!@hasField(Interface, "vtable"))
        @compileError(compPrint(
            "There is no vtable member in interface: {s}",
            .{iTypeName},
        ));

    const vtableType = meta.ptrTypeToChild(@FieldType(Interface, "vtable"));
    const vtableInfo = @typeInfo(vtableType);
    if (vtableInfo != .@"struct")
        @compileError(compPrint(
            "{s} - member vtable pointer type is not a struct. Found: {s}",
            .{ iTypeName, @tagName(vtableInfo) },
        ));

    // Check vtable and collect fn fields
    const iFnFields = comptime collect: {
        const vtableFields = vtableInfo.@"struct".fields;
        var res: [vtableFields.len]BltType.StructField = undefined;
        for (vtableFields, &res) |field, *r| {
            if (@typeInfo(meta.ptrTypeToChild(field.type)) != .@"fn")
                @compileError(compPrint(
                    "{s} - vtable member {s} is not a function ptr.",
                    .{ iTypeName, field.name },
                ));
            r.* = field;
        }
        const final = res;
        break :collect &final;
    };

    // Match vtable signature with Concrete
    // Assign implementations to vtable
    comptime var iVTable: vtableType = .{};
    comptime for (iFnFields) |fnField| {
        const fnName = fnField.name;

        // Validate fn declaration
        if (!@hasDecl(Concrete, fnName))
            @compileError(compPrint(
                "Interface: {s}, Concrete: {s} - no implementation available for fn: {s}",
                .{ iTypeName, cTypeName, fnName },
            ));

        // Validate Concrete field
        const cFn = @field(Concrete, fnName);
        const cFnType = @typeInfo(@TypeOf(cFn));
        if (cFnType != .@"fn")
            @compileError(compPrint(
                "Interface: {s}, Concrete: {s} - concrete member [{s}] is not a function",
                .{ iTypeName, cTypeName, fnName },
            ));

        const iFnInfo = @typeInfo(@typeInfo(fnField.type).pointer.child).@"fn";
        const cFnInfo = cFnType.@"fn";

        if (iFnInfo.params.len != cFnInfo.params.len or iFnInfo.return_type != cFnInfo.return_type)
            @compileError(compPrint(
                "Interface: {s}, Concrete: {s} - signature length mismatch for member [{s}]",
                .{ iTypeName, cTypeName, fnName },
            ));

        // Check Self param for vtable and implementation
        // vtable should be *anyopaque
        // concrete should be *Concrete
        // const has to match
        const iSelfType = iFnInfo.params[0].type orelse
            @compileError(compPrint(
                "Interface: {s} - self ptr target argument not available",
                .{iTypeName},
            ));
        const iSelfInfo = @typeInfo(iSelfType);
        if (iSelfInfo != .pointer)
            @compileError(compPrint(
                "Interface: {s} - self ptr argument is not a ptr",
                .{iTypeName},
            ));

        const cSelfType = cFnInfo.params[0].type orelse
            @compileError(compPrint(
                "Concrete: {s} - self ptr target argument not available",
                .{cTypeName},
            ));
        const cSelfInfo = @typeInfo(cSelfType);
        if (cSelfInfo != .pointer)
            @compileError(compPrint(
                "Concrete: {s} - self ptr argument is not a ptr",
                .{cTypeName},
            ));

        const iSelfPtrInfo = iSelfInfo.pointer;
        const cSelfPtrInfo = cSelfInfo.pointer;
        if (iSelfPtrInfo.is_const != cSelfPtrInfo.is_const or iSelfPtrInfo.child != anyopaque or cSelfPtrInfo.child != Concrete)
            @compileError(compPrint(
                "Interface: {s}, Concrete: {s} - interface self must be ptr Interface, concrete self must be ptr Concrete. Found {s} - {s}",
                .{ iTypeName, cTypeName, @typeName(iSelfPtrInfo.child), @typeName(cSelfPtrInfo.child) },
            ));

        // Check other params
        for (iFnInfo.params[1..], cFnInfo.params[1..], 1..) |iFnParam, cFnParam, i| {
            const matchGeneric = iFnParam.is_generic == cFnParam.is_generic;
            const matchNoAlias = iFnParam.is_noalias == cFnParam.is_noalias;
            // *anyopaque -> @*This() check
            const matchGenericPair = (iFnParam.type.? == *anyopaque or
                iFnParam.type.? == *const anyopaque) and
                meta.ptrTypeToChild(cFnParam.type.?) == Concrete;
            // non *anyopaque, normal type check
            const matchType = iFnParam.type.? != *const anyopaque and
                iFnParam.type.? != *anyopaque and
                iFnParam.type == cFnParam.type;

            if (!matchGeneric or
                !matchNoAlias or
                !(matchGenericPair or matchType))
                @compileError(compPrint(
                    "Interface: {s}, Concrete: {s} - Signature mismatch in n-th param {d}",
                    .{ iTypeName, cTypeName, i },
                ));
        }

        // WARN: Evil cast for ptr
        @field(iVTable, fnName) = @ptrCast(&cFn);
    };

    const finalVTable: vtableType = iVTable;
    const interfacePtr = try allocator.create(Interface);
    interfacePtr.concrete = @ptrCast(concretePtr);
    interfacePtr.vtable = &finalVTable;

    return interfacePtr;
}

pub inline fn newTraitTable(allocator: *const Allocator, concrete: anytype, interfaces: anytype) !*traitTableType(@TypeOf(concrete)) {
    const Concrete = @TypeOf(concrete);
    const cName = @typeName(Concrete);
    const traits = try allocator.create(traitTableType(Concrete));
    const tFields = comptime traitTableFields(meta.ptrTypeToChild(Concrete)) orelse
        @compileError(compPrint(
            "Concrete: {s} - no traits field available",
            .{cName},
        ));

    // Look at tuple
    switch (@typeInfo(@TypeOf(interfaces))) {
        .@"struct" => |tuple| {
            const tupleFields = tuple.fields;
            comptime if (tupleFields.len != tFields.len)
                @compileError(compPrint(
                    "Concrete: {s} - unmatched tuple and trait length",
                    .{cName},
                ));

            // Inline-match tuple and tfields linearly (all fields must be in order)
            inline for (tupleFields, tFields, 0..) |field, tField, i| {
                comptime if (meta.ptrTypeToChild(tField.type) != meta.ptrTypeToChild(field.type))
                    @compileLog(compPrint(
                        "Concrete: {s} - mismatch trait at n-th {d} param. Found - {s}",
                        .{ cName, i, field.type },
                    ));

                @field(traits.*, tField.name) = interfaces[i];
            }
        },
        else => @compileError(compPrint(
            "Concrete: {s} - unsupported type",
            .{cName},
        )),
    }
    return traits;
}

test "autowire interface" {
    const Iterator = struct {
        concrete: *anyopaque,
        vtable: *const VTable,
        value: u8,

        pub const VTable = struct {
            next: *const fn (*anyopaque) ?([:0]const u8) = undefined,
        };

        pub fn init(allocator: *const Allocator, concrete: anytype, value: u8) !*@This() {
            var self = try extend(allocator, @This(), concrete);
            self.value = value;
            return self;
        }

        pub inline fn next(self: *@This()) ?([:0]const u8) {
            return self.vtable.next(self.concrete);
        }

        pub fn sumSquare(self: *@This(), i: u8) u8 {
            return (self.value + i) * (self.value + i);
        }
    };

    const CustomIt = struct {
        traits: *const Traits,
        i: u8,
        data: []const [:0]const u8,

        const Self = @This();
        pub const Traits = struct {
            iterator: *Iterator,
        };

        pub fn init(allocator: *const Allocator, data: []const [:0]const u8) !*Self {
            var self = try allocator.create(@This());
            self.traits = try newTraitTable(allocator, self, .{
                try Iterator.init(allocator, self, 2),
            });
            self.data = data;
            self.i = 0;
            return self;
        }

        pub fn next(self: *Self) ?([:0]const u8) {
            if (self.i >= self.data.len) return null;

            defer self.i += 1;
            return self.data[self.i];
        }
    };
    const allocator = @constCast(&std.testing.allocator);
    const c = try CustomIt.init(allocator, &.{ "xd", "test" });
    defer destroyTraits(allocator, c);
    const c2 = try CustomIt.init(allocator, &.{ "aayy", "yaa", "3" });
    defer destroyTraits(allocator, c2);

    try std.testing.expect(isTraitOf(Iterator, CustomIt));

    var it = asTrait(Iterator, c);
    var it2 = asTrait(Iterator, c2);

    try std.testing.expectEqual(*Iterator, @TypeOf(it));
    try std.testing.expectEqual(*Iterator, @TypeOf(it2));

    try std.testing.expectEqual("aayy", c2.traits.iterator.next());
    try std.testing.expectEqual("yaa", c2.next());
    try std.testing.expectEqual("3", it2.next());

    try std.testing.expectEqual("xd", it.next());
    try std.testing.expectEqual("test", c.next());
    try std.testing.expectEqual(null, CustomIt.next(c2));

    // Super method call
    try std.testing.expectEqual(16, c.traits.iterator.sumSquare(2));
}

test "autowire interface for generics" {
    const Interface = (struct {
        fn init(T: type) type {
            return struct {
                concrete: *anyopaque,
                vtable: *const struct {
                    add: *const fn (*const anyopaque, T, T) T = undefined,
                },

                pub fn add(self: *const @This(), a: T, b: T) T {
                    return self.vtable.add(self.concrete, a, b);
                }
            };
        }
    }).init(u32);

    const Adder = struct {
        traits: *const struct {
            adder: *const Interface,
        },

        pub fn init(allocator: *const Allocator) !*@This() {
            const self = try allocator.create(@This());
            self.traits = try newTraitTable(allocator, self, .{
                try extend(allocator, Interface, self),
            });
            return self;
        }

        pub fn add(self: *const @This(), a: u32, b: u32) u32 {
            _ = self;
            return a + b;
        }
    };

    const allocator = @constCast(&std.testing.allocator);
    const adder = try Adder.init(allocator);
    defer destroyTraits(allocator, adder);

    const iAdder = asTrait(Interface, adder);

    try std.testing.expectEqual(4, adder.add(2, 2));
    try std.testing.expectEqual(6, iAdder.add(3, 3));
    try std.testing.expectEqual(*const Interface, @TypeOf(iAdder));
}

test "autowire multiple interfaces" {
    const Greeter = struct {
        concrete: *anyopaque,
        vtable: *const struct {
            greet: *const fn (*const anyopaque, *const Allocator) anyerror![]const u8 = undefined,
        },

        const greeting = "Greeting: {s}\n";

        pub fn greet(self: *const @This(), allocator: *const Allocator) ![]const u8 {
            const baseGreting = try self.vtable.greet(self.concrete, allocator);
            defer allocator.free(baseGreting);

            return try std.fmt.allocPrint(
                allocator.*,
                @This().greeting,
                .{baseGreting},
            );
        }
    };
    const Identifier = struct {
        concrete: *anyopaque,
        vtable: *const struct {
            id: *const fn (*const anyopaque) []const u8 = undefined,
        },

        pub fn id(self: *const @This()) []const u8 {
            return self.vtable.id(self.concrete);
        }
    };
    const Level = struct {
        concrete: *anyopaque,
        vtable: *const struct {
            lv: *const fn (*const anyopaque) u8 = undefined,
        },

        pub fn lv(self: *const @This()) u8 {
            return self.vtable.lv(self.concrete);
        }
    };
    const Person = struct {
        traits: *const struct {
            lv: *const Level,
            id: *const Identifier,
            greeter: *const Greeter,
        },
        name: []const u8,

        pub fn init(allocator: *const Allocator, name: []const u8) !*@This() {
            var self = try allocator.create(@This());
            self.traits = try newTraitTable(allocator, self, .{
                try extend(allocator, Level, self),
                try extend(allocator, Identifier, self),
                try extend(allocator, Greeter, self),
            });
            self.name = name;
            return self;
        }

        pub fn lv(self: *const @This()) u8 {
            _ = self;
            return '!';
        }

        pub fn id(self: *const @This()) []const u8 {
            return self.name;
        }

        pub fn greet(self: *const @This(), allocator: *const Allocator) anyerror![]const u8 {
            return try std.fmt.allocPrint(
                allocator.*,
                "Hello, my name is {s}{c}",
                .{ self.traits.id.id(), self.traits.lv.lv() },
            );
        }
    };

    const allc = @constCast(&std.testing.allocator);
    const p = try Person.init(allc, "John");
    defer destroyTraits(allc, p);

    const personGreet = try p.greet(allc);
    defer allc.free(personGreet);

    try std.testing.expectEqualStrings(
        "Hello, my name is John!",
        personGreet,
    );

    const g = asTrait(Greeter, p);
    const superGreet = try g.greet(allc);
    defer allc.free(superGreet);

    try std.testing.expectEqualStrings(
        \\Greeting: Hello, my name is John!
        \\
    , superGreet);

    const lv = asTrait(Level, p);
    try std.testing.expectEqual(@as(u8, '!'), lv.lv());

    const id = asTrait(Identifier, p);
    try std.testing.expectEqualStrings("John", id.id());
}

// Extend without concrete-side wiring
// this is dangerous because Concrete never agreed to the contract
pub fn quackLike(allocator: *const Allocator, comptime Interface: type, concretePtr: anytype) !*Interface {
    return extendInternal(allocator, Interface, concretePtr, false);
}

test "quackLike counting" {
    const Person = struct {
        name: []const u8,

        pub fn init(allocator: *const Allocator, name: []const u8) !*@This() {
            var self = try allocator.create(@This());
            self.name = name;
            return self;
        }

        pub fn eql(self: *const @This(), other: *const @This()) bool {
            return std.mem.eql(u8, self.name, other.name);
        }
    };
    const Stone = struct {
        weight: u8,

        pub fn init(allocator: *const Allocator, weight: u8) !*@This() {
            var self = try allocator.create(@This());
            self.weight = weight;
            return self;
        }

        pub fn eql(self: *const @This(), other: *const @This()) bool {
            return self.weight == other.weight;
        }
    };
    const Identifier = struct {
        concrete: *anyopaque,
        vtable: *const struct {
            eql: *const fn (*const anyopaque, *const anyopaque) bool = undefined,
        },

        pub fn eql(self: *const @This(), other: *const @This()) bool {
            if (self == other) return true;
            if (self.vtable != other.vtable) return false;
            return self.vtable.eql(self.concrete, other.concrete);
        }
    };

    var base = comptime std.heap.ArenaAllocator.init(std.testing.allocator);
    var allocator = @constCast(&base.allocator());
    defer base.deinit();

    const p1 = try quackLike(
        allocator,
        Identifier,
        try Person.init(allocator, "John"),
    );
    const p2 = try quackLike(
        allocator,
        Identifier,
        try Person.init(allocator, "John"),
    );
    const p3 = try quackLike(
        allocator,
        Identifier,
        try Person.init(allocator, "Dawei"),
    );
    const p4 = try quackLike(
        allocator,
        Identifier,
        try Person.init(allocator, "Dawei"),
    );
    const p5 = try quackLike(
        allocator,
        Identifier,
        try Person.init(allocator, "Dawei"),
    );
    const s1 = try quackLike(
        allocator,
        Identifier,
        try Stone.init(allocator, 10),
    );
    const s2 = try quackLike(
        allocator,
        Identifier,
        try Stone.init(allocator, 1),
    );
    const s3 = try quackLike(
        allocator,
        Identifier,
        try Stone.init(allocator, 1),
    );
    const s4 = try quackLike(
        allocator,
        Identifier,
        try Stone.init(allocator, 1),
    );
    const s5 = try quackLike(
        allocator,
        Identifier,
        try Stone.init(allocator, 1),
    );

    const identifiables = [_](*const Identifier){ p1, p2, p3, p4, p5, s1, s2, s3, s4, s5 };

    const M = struct {
        pub fn count(id: *const Identifier, ids: []const (*const Identifier)) usize {
            var r: usize = 0;
            for (ids) |i| {
                if (i.eql(id)) r += 1;
            }
            return r;
        }
    };

    const john = try Person.init(allocator, "John");
    const dawei = try Person.init(allocator, "Dawei");
    const light = try Stone.init(allocator, 1);
    const heavy = try Stone.init(allocator, 10);
    try std.testing.expectEqual(2, M.count(
        try quackLike(allocator, Identifier, john),
        identifiables[0..],
    ));
    try std.testing.expectEqual(3, M.count(
        try quackLike(allocator, Identifier, dawei),
        identifiables[0..],
    ));
    try std.testing.expectEqual(4, M.count(
        try quackLike(allocator, Identifier, light),
        identifiables[0..],
    ));
    try std.testing.expectEqual(1, M.count(
        try quackLike(allocator, Identifier, heavy),
        identifiables[0..],
    ));
    _ = &allocator;
}
