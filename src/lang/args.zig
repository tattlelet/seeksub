const std = @import("std");
const trait = @import("trait.zig");
const shared = @import("shared.zig");
const duck = @import("ducktape.zig");
const meta = @import("meta.zig");
const Allocator = std.mem.Allocator;
const FieldEnum = std.meta.FieldEnum;

// TODO: rename this, it's no longer an iterator
// Deque?
const ArgIterator = struct {
    destroyable: *duck.AnyDestroyable,
    concrete: *anyopaque,
    vtable: *const struct {
        next: *const fn (*anyopaque) ?[:0]const u8 = undefined,
    },
    peekR: ?[:0]const u8 = null,

    pub fn new(self: *@This()) *@This() {
        self.peekR = null;
        return self;
    }

    pub fn deinit(self: *@This(), allocator: *Allocator) void {
        self.peekR = undefined;
        self.destroyable.destroy(allocator);
        allocator.destroy(self);
    }

    // NOTE: Original ArgIterator does a lot of sanitization
    // This interface will have no responsability over sanitization
    pub fn next(self: *@This()) ?[:0]const u8 {
        if (self.peekR) |v| {
            defer self.peekR = null;
            return v;
        }
        return self.vtable.next(self.concrete);
    }

    pub fn peek(self: *@This()) ?[:0]const u8 {
        if (self.peekR) |v| return v;
        self.peekR = self.vtable.next(self.concrete);
        return self.peekR;
    }

    pub fn consume(self: *@This()) void {
        _ = self.next();
    }

    // NOTE: Iterator will not own this bit of memory
    // This interface wont sanitize anything fed back to it
    pub fn buffer(self: *@This(), buf: [:0]const u8) void {
        self.peekR = buf;
    }
};

fn createArgIterator(allocator: *const Allocator, data: [:0]const u8) !*ArgIterator {
    const GIter = std.process.ArgIteratorGeneral(.{});
    const tIter = try allocator.create(GIter);
    errdefer allocator.destroy(tIter);
    tIter.* = try GIter.init(allocator.*, data);
    errdefer tIter.deinit();

    var it = try duck.quackLikeOwned(@constCast(allocator), ArgIterator, tIter);
    return it.new();
}

test "arg iterator shim" {
    var allocator = std.testing.allocator;
    const iterator = try createArgIterator(&allocator,
        \\Hello
        \\World
    );
    defer iterator.deinit(&allocator);

    try std.testing.expectEqualStrings("Hello", iterator.next().?);
    try std.testing.expectEqualStrings("World", iterator.next().?);
    try std.testing.expectEqual(null, iterator.next());
}

test "argIter peek" {
    var allocator = std.testing.allocator;
    const iterator = try createArgIterator(&allocator,
        \\Hello
        \\World
    );
    defer iterator.deinit(&allocator);

    try std.testing.expectEqualStrings("Hello", iterator.peek().?);
    try std.testing.expectEqualStrings("Hello", iterator.next().?);
    try std.testing.expectEqualStrings("World", iterator.peek().?);
    try std.testing.expectEqualStrings("World", iterator.peek().?);
    try std.testing.expectEqualStrings("World", iterator.next().?);
    try std.testing.expectEqual(null, iterator.peek());
}

test "argIter buffer" {
    var allocator = std.testing.allocator;
    const iterator = try createArgIterator(&allocator, "");
    defer iterator.deinit(&allocator);

    iterator.buffer("Hello");
    try std.testing.expectEqualStrings("Hello", iterator.peek().?);
}

// TODO: split error sets (check @errorCast)
const CodecError = error{
    ParseFloatEndOfIterator,
    ParseIntEndOfIterator,
    ParseStringEndOfIterator,
} || std.fmt.ParseIntError || std.mem.Allocator.Error;

// NOTE: default codec is really dumb and wont use tagged names, however if a tagged named
// was passed to a specific vtable function, the type for said tag was already matched
// It's the responsability of the codec to consume the iterator, use peek for opportunistic parsers
pub fn Codec(Spec: type) type {
    return struct {
        pub fn init() @This() {
            return .{};
        }

        const 

        pub fn parseWith(comptime name: []const u8) []const u8 {
            const FieldType = @FieldType(Spec, name);
            const fName = comptime refeed: switch (@typeInfo(FieldType)) {
                .bool => "parseBool",
                .int => "parseInt",
                .float => "parseFloat",
                // .array => {},
                // .@"enum" => {},
                .pointer => |ptr| ptrReturn: {
                    // TODO: add other array type support through tokenization
                    // TODO: add meta tag to treat u8 as any other numberic array for parsing
                    if (ptr.child == u8) {
                        break :ptrReturn "parseString";
                    } else @compileError(std.fmt.comptimePrint(
                        "Field: {s}, Type: []{s} - unsupported array type",
                        .{ name, @typeName(ptr.child) },
                    ));
                },
                .optional => |opt| continue :refeed @typeInfo(opt.child),
                else => @compileError(std.fmt.comptimePrint(
                    "Field: {s}, Type: {s} - no codec translation for type available",
                    .{ name, @typeName(FieldType) },
                )),
            };

            if (@hasDecl(@This(), fName)) {
                return fName;
            } else @compileError(std.fmt.comptimePrint(
                "Codec: {s}, Declare: {s} - function not found",
                .{ @typeName(@This()), fName },
            ));
        }

        pub fn parseString(
            self: *const @This(),
            comptime name: []const u8,
            allocator: *Allocator,
            it: *ArgIterator,
        ) CodecError!meta.OptTypeOf(@FieldType(Spec, name)) {
            _ = self;
            const s = it.next() orelse return CodecError.ParseIntEndOfIterator;

            const ArrType = meta.OptTypeOf(@FieldType(Spec, name));
            const PtrType = @typeInfo(ArrType).pointer;

            const newPtr = try alloc: {
                if (PtrType.sentinel()) |sentinel| {
                    break :alloc allocator.allocSentinel(PtrType.child, s.len, sentinel);
                } else {
                    break :alloc allocator.alloc(PtrType.child, s.len);
                }
            };
            @memcpy(newPtr, s);
            return newPtr;
        }

        pub fn parseFloat(
            self: *const @This(),
            comptime name: []const u8,
            allocator: *Allocator,
            it: *ArgIterator,
        ) CodecError!meta.OptTypeOf(@FieldType(Spec, name)) {
            _ = self;
            _ = allocator;
            const value = it.next() orelse return CodecError.ParseFloatEndOfIterator;
            return try std.fmt.parseFloat(meta.OptTypeOf(
                @FieldType(Spec, name),
            ), value);
        }

        pub fn parseInt(
            self: *const @This(),
            comptime name: []const u8,
            allocator: *Allocator,
            it: *ArgIterator,
        ) CodecError!meta.OptTypeOf(@FieldType(Spec, name)) {
            _ = self;
            _ = allocator;
            const value = it.next() orelse return CodecError.ParseIntEndOfIterator;
            return try std.fmt.parseInt(meta.OptTypeOf(
                @FieldType(Spec, name),
            ), value, 10);
        }

        // The only way you can change a flag is by explicitly saying false
        // all other values are oportunistic trues
        pub fn parseBool(
            self: *const @This(),
            comptime name: []const u8,
            allocator: *Allocator,
            it: *ArgIterator,
        ) CodecError!bool {
            _ = self;
            _ = allocator;
            _ = name;
            const value = it.peek() orelse return true;
            return switch (value.len) {
                4 => if (std.mem.eql(u8, "true", value)) consume: {
                    it.consume();
                    break :consume true;
                    // INFO: this looks dumb, but the purpose is not to consume the iterator
                    // only when it was explicitly said to be true
                } else true,
                5 => if (std.mem.eql(u8, "false", value)) consume: {
                    _ = it.next();
                    break :consume false;
                } else true,
                else => true,
            };
        }
    };
}

const SimpleIt = struct {
    data: []const [:0]const u8,
    i: usize = 0,
    pub fn init(allocator: *Allocator, data: []const [:0]const u8) !*@This() {
        const self = try allocator.create(@This());
        self.* = .{ .data = data };
        return self;
    }
    pub fn next(self: *@This()) ?[:0]const u8 {
        if (self.i >= self.data.len) return null;
        defer self.i += 1;
        return self.data[self.i];
    }
};

test "parseBool" {
    var allocator = @constCast(&std.testing.allocator);
    _ = &allocator;
    var it = (try duck.quackLikeOwned(
        allocator,
        ArgIterator,
        try SimpleIt.init(allocator, &.{
            "true",
            "false",
            "something else",
        }),
    )).new();
    defer it.deinit(allocator);
    const codec = Codec(struct { @"test": bool }).init();
    try std.testing.expect(try codec.parseBool("test", allocator, it));
    try std.testing.expectEqual(null, it.peekR);

    try std.testing.expect(!try codec.parseBool("test", allocator, it));
    try std.testing.expectEqual(null, it.peekR);

    try std.testing.expect(try codec.parseBool("test", allocator, it));
    try std.testing.expectEqualStrings("something else", it.peekR.?);
}

test "parseInt" {
    var allocator = @constCast(&std.testing.allocator);
    _ = &allocator;
    var it = (try duck.quackLikeOwned(
        allocator,
        ArgIterator,
        try SimpleIt.init(allocator, &.{
            "44",
            "-1",
            "25",
        }),
    )).new();
    defer it.deinit(allocator);
    const codec = Codec(struct { n1: u6, n2: i2, n3: u88 }).init();
    try std.testing.expectEqual(44, try codec.parseInt("n1", allocator, it));
    try std.testing.expectEqual(-1, try codec.parseInt("n2", allocator, it));
    try std.testing.expectEqual(25, try codec.parseInt("n3", allocator, it));
}

// TODO: construct errorset based on codec
const ParseSpecError = error{
    UnknownArgumentName,
    InvalidArgumentToken,
    MissingShorthandMetadata,
    MissingShorthandLink,
    UnknownShorthandName,
    ArgEqualSplitMissingValue,
    ArgEqualSplitNotConsumed,
    CodecParseMethodUnavailable,
    ToBeAdded,
} || std.mem.Allocator.Error || CodecError;

// NOTE: it's the user's responsability to move pieces outside of the lifecycle of
// a spec response
pub fn SpecResponse(comptime Spec: type) type {
    // TODO: validate spec
    const Options = Spec;

    const SpecCodec = if (@hasDecl(Spec, "Codec")) Spec.Codec else Codec(Spec);
    return struct {
        arena: std.heap.ArenaAllocator,
        codec: SpecCodec,
        program: ?[:0]const u8,
        options: Options,
        // TODO: Move to tuple inside Spec, leverage codec
        positionals: [][:0]const u8,
        // TODO: optional error collection

        pub fn init(allc: *const Allocator, codec: SpecCodec) !*@This() {
            var arena = std.heap.ArenaAllocator.init(allc.*);
            const allocator = arena.allocator();
            var self = try allocator.create(@This());
            self.arena = arena;
            self.codec = codec;
            self.options = Spec{};
            self.program = null;
            self.positionals = undefined;
            return self;
        }

        // TODO: test all error returns
        pub fn parse(self: *@This(), it: *ArgIterator) ParseSpecError!void {
            const allocator = self.arena.allocator();
            self.program = if (it.next()) |program| blk: {
                break :blk try allocator.dupeZ(u8, program);
            } else return;

            var positionals = try std.ArrayList([:0]const u8).initCapacity(allocator, 32);

            while (it.next()) |arg|
                if (arg.len == 1 and arg[0] == '-') {
                    // single -
                    @branchHint(.unlikely);
                    try positionals.append("-");
                    continue;
                } else if (arg.len == 2 and std.mem.eql(u8, "--", arg)) {
                    // -- positional skip
                    @branchHint(.cold);
                    break;
                } else if (arg.len >= 1 and arg[0] != '-') {
                    // word, feed to positional
                    @branchHint(.likely);
                    it.buffer(arg);
                    break;
                } else if (arg.len == 0) {
                    // This is technically not possible with ArgIterator
                    @branchHint(.cold);
                    continue;
                } else {
                    @branchHint(.likely);
                    var offset: usize = 1;
                    if (arg[1] == '-') offset += 1;
                    try self.namedToken(offset, arg, it);
                };

            // drain remaining args
            // TODO: parse tuple
            while (it.next()) |item| {
                try positionals.append(try allocator.dupeZ(u8, item));
            }
            self.positionals = try positionals.toOwnedSlice();
        }

        fn namedToken(self: *@This(), offset: usize, arg: [:0]const u8, it: *ArgIterator) ParseSpecError!void {
            var splitValue: ?[:0]u8 = null;
            var slice: []const u8 = arg[offset..];
            const needSplit = std.mem.indexOf(u8, slice, "=");

            // Feed split arg to buffer
            if (needSplit) |i| {
                // TODO: should this sanitize the sliced arg?
                if (i + 1 >= arg.len) return ParseSpecError.ArgEqualSplitMissingValue;
                splitValue = try self.arena.allocator().allocSentinel(u8, slice.len - i - 1, 0);
                @memcpy(splitValue.?, slice[i + 1 ..]);
                it.buffer(splitValue.?);
                slice = slice[0..i];
            }
            errdefer if (splitValue) |v| self.arena.allocator().free(v);

            try switch (offset) {
                2 => self.namedArg(slice, it),
                1 => self.shortArg(slice, it),
                else => ParseSpecError.InvalidArgumentToken,
            };

            // if split not consumed, it's not sane to progress
            if (splitValue) |v| {
                const peekR: [*]const u8 = @ptrCast(it.peek() orelse return);
                if (peekR == @as([*]u8, @ptrCast(v))) return ParseSpecError.ArgEqualSplitNotConsumed;
            }
        }

        // TODO: re-feed chain of flags, enforce max n chars for shorthand
        fn shortArg(self: *@This(), arg: []const u8, it: *ArgIterator) ParseSpecError!void {
            if (@typeInfo(FieldEnum(Spec)).@"enum".fields.len == 0) return ParseSpecError.UnknownArgumentName;
            if (!@hasDecl(Spec, "Short")) return ParseSpecError.MissingShorthandMetadata;

            inline for (std.meta.fields(@TypeOf(Spec.Short))) |s| {
                if (std.mem.eql(u8, s.name, arg)) {
                    const tag = s.defaultValue() orelse return ParseSpecError.MissingShorthandLink;
                    try self.namedArg(tag, it);
                    return;
                }
            } else {
                return ParseSpecError.UnknownShorthandName;
            }
        }

        fn namedArg(self: *@This(), arg: []const u8, it: *ArgIterator) ParseSpecError!void {
            if (@typeInfo(FieldEnum(Spec)).@"enum".fields.len == 0) return ParseSpecError.UnknownArgumentName;

            inline for (std.meta.fields(Spec)) |f| {
                // This gives me a comptime-value for name
                if (std.mem.eql(u8, f.name, arg)) {
                    const codecFTag = comptime SpecCodec.parseWith(f.name);
                    var allocator = self.arena.allocator();

                    // TODO: handle required and optional

                    const r = try @call(.auto, @field(SpecCodec, codecFTag), .{ &self.codec, f.name, &allocator, it });

                    // TODO: append if array?
                    @field(self.options, f.name) = r;
                    return;
                }
            } else {
                return ParseSpecError.UnknownArgumentName;
            }
        }

        pub fn deinit(self: *const @This()) void {
            self.arena.deinit();
        }
    };
}

// NOTE: this method wont own the ArgIterator lifecycle
pub fn parseSpec(allocator: *Allocator, it: *ArgIterator, Spec: type) ParseSpecError!*const SpecResponse(Spec) {
    var response = try SpecResponse(Spec).init(allocator, Codec(Spec).init());
    errdefer response.deinit();
    try response.parse(it);
    return response;
}

fn tstParse(data: [:0]const u8, Spec: type) !*const SpecResponse(Spec) {
    var allocator = @constCast(&std.testing.allocator);
    _ = &allocator;
    const it = try createArgIterator(allocator, data);
    defer it.deinit(allocator);
    return try parseSpec(allocator, it, Spec);
}

test "empty args with default" {
    const r = try tstParse("", struct {
        flag: bool = false,
    });
    defer r.deinit();
    try std.testing.expectEqual(null, r.program);
    try std.testing.expectEqual(false, r.options.flag);
}

test "program only" {
    const r = try tstParse("program", struct {});
    defer r.deinit();
    try std.testing.expectEqualStrings("program", r.program.?);
}

test "parse named" {
    const r = try tstParse("program --cool-flag", struct { @"cool-flag": bool = false });
    defer r.deinit();
    const r2 = try tstParse("program --cool-flag true", struct { @"cool-flag": bool = false });
    defer r2.deinit();
    const r3 = try tstParse("program --cool-flag false", struct { @"cool-flag": bool = false });
    defer r3.deinit();
    const r4 = try tstParse("program --cool-flag something else", struct { @"cool-flag": bool = false });
    defer r4.deinit();

    try std.testing.expectEqual(true, r.options.@"cool-flag");
    try std.testing.expectEqual(true, r2.options.@"cool-flag");
    try std.testing.expectEqual(false, r3.options.@"cool-flag");
    try std.testing.expectEqual(true, r4.options.@"cool-flag");
    const expectedPositionals: []const [:0]const u8 = &.{ "something", "else" };
    for (expectedPositionals, r4.positionals) |expected, item| {
        try std.testing.expectEqualStrings(expected, item);
    }
}

test "parse short arg" {
    const Spec = struct {
        something: bool = false,
        @"super-something": bool = false,

        const Short = .{
            .s = "something",
            .S = "super-something",
        };
    };
    const r1 = try tstParse("program -s --super-something true", Spec);
    defer r1.deinit();
    const r2 = try tstParse("program --something false -S", Spec);
    defer r2.deinit();
    const r3 = try tstParse("program -s false -S false", Spec);
    defer r3.deinit();
    const r4 = try tstParse("program -s true -S true", Spec);
    defer r4.deinit();

    try std.testing.expectEqual(true, r1.options.something);
    try std.testing.expectEqual(true, r1.options.@"super-something");
    try std.testing.expectEqual(false, r2.options.something);
    try std.testing.expectEqual(true, r2.options.@"super-something");
    try std.testing.expectEqual(false, r3.options.something);
    try std.testing.expectEqual(false, r3.options.@"super-something");
    try std.testing.expectEqual(true, r4.options.something);
    try std.testing.expectEqual(true, r4.options.@"super-something");
}

test "parse different types" {
    const Spec = struct {
        u1: ?u1 = null,
        f1: ?f16 = null,
        b: ?bool = null,
        s1: ?[]const u8 = null,
        s2: ?[:0]const u8 = null,
    };

    const r1 = try tstParse(
        "program --u1=0 --f1 1.1 --b false --s1 Hello --s2 \"Hello World\"",
        Spec,
    );
    defer r1.deinit();

    try std.testing.expectEqual(0, r1.options.u1.?);
    try std.testing.expectEqual(1.1, r1.options.f1.?);
    try std.testing.expect(!r1.options.b.?);
    try std.testing.expectEqualStrings("Hello", r1.options.s1.?);
    try std.testing.expectEqualStrings("Hello World", r1.options.s2.?);
}

test "parse kvargs" {
    const Spec = struct {
        something: bool = false,
        @"super-something": bool = false,

        const Short = .{
            .s = "something",
            .S = "super-something",
        };
    };

    const r1 = try tstParse("program -s=true --super-something=true", Spec);
    defer r1.deinit();

    try std.testing.expectEqual(true, r1.options.something);
    try std.testing.expectEqual(true, r1.options.@"super-something");
}

test "parse positionals" {
    const r1 = try tstParse("program positional1 positional2 positional3", struct {});
    defer r1.deinit();
    const r2 = try tstParse("program --test positional1 positional2 positional3", struct { @"test": bool = false });
    defer r2.deinit();
    const r3 = try tstParse("program -- --test positional1 positional2 positional3", struct { @"test": bool = false });
    defer r3.deinit();

    try std.testing.expect(r2.options.@"test");
    try std.testing.expect(!r3.options.@"test");

    const expectedPositionals: []const [:0]const u8 = &.{ "positional1", "positional2", "positional3" };
    const allCases: []const []const [:0]const u8 = &.{ r1.positionals, r2.positionals };
    for (allCases) |positionals| {
        for (expectedPositionals, positionals) |expected, item| {
            try std.testing.expectEqualStrings(expected, item);
        }
    }

    const expectSkip: []const [:0]const u8 = &.{ "--test", "positional1", "positional2", "positional3" };
    for (expectSkip, r3.positionals) |expected, item| {
        try std.testing.expectEqualStrings(expected, item);
    }
}
