const std = @import("std");
const trait = @import("../trait.zig");
const shared = @import("../shared.zig");
const duck = @import("../ducktape.zig");
const meta = @import("../meta.zig");
const coll = @import("../collections.zig");
const argIter = @import("iterator.zig");
const argCodec = @import("codec.zig");
const Allocator = std.mem.Allocator;
const FieldEnum = std.meta.FieldEnum;
const TstArgCursor = argIter.TstArgCursor;
const DefaultCodec = argCodec.DefaultCodec;
const Codec = argCodec.Codec;

pub fn SpecResponse(comptime Spec: type) type {
    // TODO: validate spec

    return struct {
        arena: std.heap.ArenaAllocator,
        codec: SpecCodec,
        program: ?[]const u8,
        // TODO: move const
        options: Options,
        // TODO: Move to tuple inside Spec, leverage codec
        positionals: [][]const u8,
        // TODO: optional error collection
        // TODO: better get
        verb: if (VerbT != void) ?VerbT else void,
        const Options = Spec;

        fn SpecUnionVerbs() type {
            const VerbUnion = @typeInfo(Spec.Verb).@"union";
            comptime var newUnionFields: [VerbUnion.fields.len]std.builtin.Type.UnionField = undefined;
            for (VerbUnion.fields, 0..) |f, i| {
                const newSpecR = *const SpecResponse(f.type);
                newUnionFields[i] = .{
                    .name = f.name,
                    .type = newSpecR,
                    .alignment = @alignOf(newSpecR),
                };
            }
            const newUni: std.builtin.Type = .{ .@"union" = .{
                .layout = VerbUnion.layout,
                .tag_type = VerbUnion.tag_type,
                .fields = &newUnionFields,
                .decls = VerbUnion.decls,
            } };
            return @Type(newUni);
        }

        const CursorT = coll.Cursor([]const u8);
        const VerbT = if (@hasDecl(Spec, "Verb")) SpecUnionVerbs() else void;
        const SpecCodec = if (@hasDecl(Spec, "Codec")) Spec.Codec else Codec(Spec);
        const SpecEnumFields = std.meta.FieldEnum(Spec);

        const Error = error{
            UnknownArgumentName,
            InvalidArgumentToken,
            MissingShorthandMetadata,
            MissingShorthandLink,
            UnknownShorthandName,
            ArgEqualSplitMissingValue,
            ArgEqualSplitNotConsumed,
            CodecParseMethodUnavailable,
        } || std.mem.Allocator.Error || SpecCodec.Error;

        pub fn init(allc: *const Allocator, codec: SpecCodec) !*@This() {
            var arena = std.heap.ArenaAllocator.init(allc.*);
            const allocator = arena.allocator();
            var self = try allocator.create(@This());
            self.arena = arena;
            self.codec = codec;
            self.options = Spec{};
            self.program = null;
            self.positionals = undefined;
            if (comptime @hasDecl(Spec, "Verb")) {
                self.verb = null;
            }
            return self;
        }

        // TODO: test all error returns
        pub fn parse(self: *@This(), cursor: *CursorT) Error!void {
            try self.parseInner(cursor, true);
        }

        fn parseInner(self: *@This(), cursor: *CursorT, comptime parseProgram: bool) Error!void {
            const allocator = self.arena.allocator();

            if (comptime parseProgram) {
                self.program = if (cursor.next()) |program|
                    program
                else
                    return;
            } else {
                _ = cursor.peek() orelse return;
            }

            var positionals = try std.ArrayList([]const u8).initCapacity(allocator, 4);
            while (cursor.next()) |arg|
                if (arg.len == 1 and arg[0] == '-') {
                    try positionals.append("-");
                    continue;
                } else if (arg.len == 2 and std.mem.eql(u8, "--", arg)) {
                    break;
                } else if (arg.len >= 1 and arg[0] != '-') {
                    cursor.stackItem(arg);
                    break;
                } else if (arg.len == 0) {
                    continue;
                } else {
                    var offset: usize = 1;
                    if (arg[1] == '-') offset += 1;
                    try self.namedToken(offset, arg, cursor);
                };

            // TODO: parse tuple
            while (cursor.next()) |item| {
                try positionals.append(item);
            }
            try self.parseVerb(&allocator, &positionals);
            self.positionals = try positionals.toOwnedSlice();
        }

        fn parseVerb(
            self: *@This(),
            allocator: *const Allocator,
            positionals: *std.ArrayList([]const u8),
        ) Error!void {
            if (comptime VerbT == void) return;
            if (positionals.items.len == 0) return;

            const verbArg = positionals.items[0];
            inline for (@typeInfo(Spec.Verb).@"union".fields) |f| {
                if (std.mem.eql(u8, f.name, verbArg)) {
                    const verbR = try SpecResponse(f.type).init(
                        allocator,
                        // TODO: should use SpecCodec
                        Codec(f.type){},
                    );

                    const unmanaged = positionals.moveToUnmanaged();
                    var arrCursor = coll.ArrayCursor([]const u8).init(
                        unmanaged.items,
                        1,
                    );
                    var vCursor = blk: {
                        var c = arrCursor.asCursor();
                        break :blk &c;
                    };
                    _ = &vCursor;
                    try verbR.parseInner(vCursor, false);
                    self.verb = @unionInit(VerbT, f.name, verbR);

                    break;
                }
            }
        }

        fn namedToken(self: *@This(), offset: usize, arg: []const u8, cursor: *CursorT) Error!void {
            var splitValue: ?[]const u8 = null;
            var slice: []const u8 = arg[offset..];
            const optValueIdx = std.mem.indexOf(u8, slice, "=");

            if (optValueIdx) |i| {
                splitValue = slice[i + 1 ..];
                cursor.stackItem(splitValue.?);
                slice = slice[0..i];
            }

            try switch (offset) {
                2 => self.namedArg(slice, cursor),
                1 => self.shortArg(slice, cursor),
                else => Error.InvalidArgumentToken,
            };

            // if split not consumed, it's not sane to progress
            if (splitValue) |v| {
                const peekR: [*]const u8 = @ptrCast(cursor.peek() orelse return);
                if (peekR == @as([*]const u8, @ptrCast(v))) return Error.ArgEqualSplitNotConsumed;
            }
        }

        fn shortArg(self: *@This(), arg: []const u8, cursor: *CursorT) Error!void {
            if (comptime @typeInfo(FieldEnum(Spec)).@"enum".fields.len == 0) return Error.UnknownArgumentName;
            if (comptime !@hasDecl(Spec, "Short")) return Error.MissingShorthandMetadata;

            var start: usize = 0;
            var end: usize = @min(2, arg.len);
            var noneCursor = blk: {
                var c = coll.UnitCursor([]const u8).asNoneCursor();
                break :blk &c;
            };
            _ = &noneCursor;
            while (end <= arg.len) {
                ret: inline for (std.meta.fields(@TypeOf(Spec.Short))) |s| {
                    if (std.mem.eql(u8, s.name, arg[start..end])) {
                        const tag = s.defaultValue() orelse return Error.MissingShorthandLink;
                        var vCursor = if (end == arg.len) cursor else noneCursor;
                        _ = &vCursor;
                        try self.namedArg(tag, vCursor);
                        start = end;
                        break :ret;
                    }
                } else if (end - start == 1) {
                    return Error.UnknownShorthandName;
                }

                if (start == end and end == arg.len) return else if (end - start == 0)
                    end = @min(end + 2, arg.len)
                else
                    end -= 1;
            }
        }

        fn namedArg(self: *@This(), arg: []const u8, cursor: *CursorT) Error!void {
            const fields = @typeInfo(SpecEnumFields).@"enum".fields;
            if (fields.len == 0) return Error.UnknownArgumentName;

            inline for (fields) |f| {
                if (std.mem.eql(u8, f.name, arg)) {
                    const spectag = comptime (meta.stringToEnum(SpecEnumFields, f.name) orelse @compileError(std.fmt.comptimePrint(
                        "Spec: {s}, Field: {s} - could no translate field to tag",
                        .{ @typeName(Spec), f.name },
                    )));
                    const codecFTag = comptime SpecCodec.parseWith(spectag);

                    var allocator = self.arena.allocator();
                    const r = try @call(.auto, @field(SpecCodec, @tagName(codecFTag)), .{ &self.codec, spectag, &allocator, cursor });

                    @field(self.options, f.name) = r;
                    return;
                }
            } else {
                return Error.UnknownArgumentName;
            }
        }

        pub fn deinit(self: *const @This()) void {
            self.arena.deinit();
        }
    };
}

pub fn tstParseSpec(allocator: *const Allocator, cursor: *coll.Cursor([]const u8), Spec: type) !*const SpecResponse(Spec) {
    var response = try SpecResponse(Spec).init(allocator, Codec(Spec){});
    errdefer response.deinit();
    try response.parse(cursor);
    return response;
}

fn tstParse(allocator: *const Allocator, data: [:0]const u8, Spec: type) !*const SpecResponse(Spec) {
    var tstCursor = try TstArgCursor.init(allocator, data);
    var cursor = t: {
        var c = tstCursor.asCursor();
        break :t &c;
    };
    _ = &cursor;
    return try tstParseSpec(allocator, cursor, Spec);
}

test "empty args with default" {
    const base = &std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base.*);
    defer arena.deinit();
    const allocator = &arena.allocator();

    const r = try tstParse(allocator, "", struct {
        flag: bool = false,
    });
    defer r.deinit();
    try std.testing.expectEqual(null, r.program);
    try std.testing.expectEqual(false, r.options.flag);
}

test "program only" {
    const base = &std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base.*);
    defer arena.deinit();
    const allocator = &arena.allocator();

    const r = try tstParse(allocator, "program", struct {});
    defer r.deinit();
    try std.testing.expectEqualStrings("program", r.program.?);
}

test "parse named" {
    const base = &std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base.*);
    defer arena.deinit();
    const allocator = &arena.allocator();

    const r = try tstParse(allocator, "program --cool-flag", struct { @"cool-flag": bool = false });
    defer r.deinit();
    const r2 = try tstParse(allocator, "program --cool-flag true", struct { @"cool-flag": bool = false });
    defer r2.deinit();
    const r3 = try tstParse(allocator, "program --cool-flag false", struct { @"cool-flag": bool = false });
    defer r3.deinit();
    const r4 = try tstParse(allocator, "program --cool-flag something else", struct { @"cool-flag": bool = false });
    defer r4.deinit();

    try std.testing.expectEqual(true, r.options.@"cool-flag");
    try std.testing.expectEqual(true, r2.options.@"cool-flag");
    try std.testing.expectEqual(false, r3.options.@"cool-flag");
    try std.testing.expectEqual(true, r4.options.@"cool-flag");
    const expected: []const []const u8 = &.{ "something", "else" };
    try std.testing.expectEqualDeep(expected, r4.positionals);
}

test "parsed chained flags" {
    const base = &std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base.*);
    defer arena.deinit();
    const allocator = &arena.allocator();

    const Spec = struct {
        t1: ?bool = null,
        t2: ?bool = null,
        t3: ?bool = null,
        t4: ?bool = null,
        t5: ?bool = null,

        pub const Short = .{
            .a = "t1",
            .aA = "t2",
            .b = "t3",
            .Ss = "t4",
            .c = "t5",
        };
    };
    const r1 = try tstParse(allocator, "program -aaAbSsc=false", Spec);
    defer r1.deinit();
    try std.testing.expect(r1.options.t1.?);
    try std.testing.expect(r1.options.t2.?);
    try std.testing.expect(r1.options.t3.?);
    try std.testing.expect(r1.options.t4.?);
    try std.testing.expect(!r1.options.t5.?);
}

test "parse short arg" {
    const base = &std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base.*);
    defer arena.deinit();
    const allocator = &arena.allocator();

    const Spec = struct {
        something: bool = false,
        @"super-something": bool = false,

        const Short = .{
            .s = "something",
            .S = "super-something",
        };
    };
    const r1 = try tstParse(allocator, "program -s --super-something true", Spec);
    defer r1.deinit();
    const r2 = try tstParse(allocator, "program --something false -S", Spec);
    defer r2.deinit();
    const r3 = try tstParse(allocator, "program -s false -S false", Spec);
    defer r3.deinit();
    const r4 = try tstParse(allocator, "program -s true -S true", Spec);
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
    const base = &std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base.*);
    defer arena.deinit();
    const allocator = &arena.allocator();

    const Spec = struct {
        o1: ?bool = null,
        u1: ?u1 = null,
        f1: ?f16 = null,
        b: ?bool = null,
        e: ?Animal = null,
        s1: ?[]const u8 = null,
        s2: ?[:0]const u8 = null,
        au1: ?[]const u1 = null,
        au32: ?[]const u32 = null,
        ai32: ?[]const i32 = null,
        af32: ?[]const f32 = null,
        as1: ?[]const []const u8 = null,
        as2: ?[]const [:0]const u8 = null,
        aau32: ?[]const []const u32 = null,
        aaf32: ?[]const []const f32 = null,
        aai32: ?[]const []const i32 = null,
        aab: ?[]const []const bool = null,
        ae: ?[]const Animal = null,
        o2: ?bool = null,

        pub const Animal = enum { dog, cat };
    };

    const r1 = try tstParse(
        allocator,
        \\program
        \\--o1
        \\--u1=0
        \\--f1 1.1
        \\--b false
        \\--e dog
        \\--s1 Hello
        \\--s2 "Hello World"
        \\--au1 [1,0,1,0]
        \\--au32=[32,23,133,99,10]
        \\--ai32 "[-1, -44, 22222   ,   -1]"
        \\--af32="[    3.4   , 58,   3.1  ]"
        \\--as1 "['Hello', ' World ', '!']"
        \\--as2="[  'Im'  ,  'Losing it'  ]"
        \\--aau32 "[[1,3], [3300, 222, 333, 33], [1]]"
        \\--aaf32 "[  [  1.1,  3.2,-1] ,   [3.1  ,2,5], [ 1.2 ], [7.1]   ]"
        \\--aai32 "[  [  -1] ,   [2, -2] ]"
        \\--aab="[[true, true, false], [false, true]]"
        \\--ae "[cat, cat]"
        \\--o2
    ,
        Spec,
    );
    defer r1.deinit();

    try std.testing.expect(r1.options.o1.?);
    try std.testing.expectEqual(0, r1.options.u1.?);
    try std.testing.expectEqual(1.1, r1.options.f1.?);
    try std.testing.expect(!r1.options.b.?);
    try std.testing.expectEqual(Spec.Animal.dog, r1.options.e.?);
    try std.testing.expectEqualStrings("Hello", r1.options.s1.?);
    try std.testing.expectEqualStrings("Hello World", r1.options.s2.?);
    try std.testing.expectEqualDeep(&[_]u1{ 1, 0, 1, 0 }, r1.options.au1.?);
    try std.testing.expectEqualDeep(&[_]u32{ 32, 23, 133, 99, 10 }, r1.options.au32.?);
    try std.testing.expectEqualDeep(&[_]i32{ -1, -44, 22222, -1 }, r1.options.ai32.?);
    const expectedAs1: []const []const u8 = &.{ "Hello", " World ", "!" };
    try std.testing.expectEqualDeep(expectedAs1, r1.options.as1.?);
    const expectedAs2: []const [:0]const u8 = &.{ "Im", "Losing it" };
    try std.testing.expectEqualDeep(expectedAs2, r1.options.as2.?);
    const expectedAau32: []const [:0]const u32 = &.{ &.{ 1, 3 }, &.{ 3300, 222, 333, 33 }, &.{1} };
    try std.testing.expectEqualDeep(expectedAau32, r1.options.aau32.?);
    const expectedAaf32: []const []const f32 = &.{ &.{ 1.1, 3.2, -1 }, &.{ 3.1, 2, 5 }, &.{1.2}, &.{7.1} };
    try std.testing.expectEqualDeep(expectedAaf32, r1.options.aaf32.?);
    const expectedAai32: []const []const i32 = &.{ &.{-1}, &.{ 2, -2 } };
    try std.testing.expectEqualDeep(expectedAai32, r1.options.aai32.?);
    const expectAab: []const []const bool = &.{ &.{ true, true, false }, &.{ false, true } };
    try std.testing.expectEqualDeep(expectAab, r1.options.aab.?);
    try std.testing.expectEqualDeep(&[_]Spec.Animal{ .cat, .cat }, r1.options.ae.?);
    try std.testing.expect(r1.options.o2.?);
}

test "parse kvargs" {
    const base = &std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base.*);
    defer arena.deinit();
    const allocator = &arena.allocator();

    const Spec = struct {
        something: bool = false,
        @"super-something": bool = false,

        const Short = .{
            .s = "something",
            .S = "super-something",
        };
    };

    const r1 = try tstParse(allocator, "program -s=true --super-something=true", Spec);
    defer r1.deinit();

    try std.testing.expectEqual(true, r1.options.something);
    try std.testing.expectEqual(true, r1.options.@"super-something");
}

test "parse positionals" {
    const base = &std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base.*);
    defer arena.deinit();
    const allocator = &arena.allocator();

    const r1 = try tstParse(allocator, "program positional1 positional2 positional3", struct {});
    defer r1.deinit();
    const r2 = try tstParse(allocator, "program --test positional1 positional2 positional3", struct { @"test": bool = false });
    defer r2.deinit();
    const r3 = try tstParse(allocator, "program -- --test positional1 positional2 positional3", struct { @"test": bool = false });
    defer r3.deinit();

    try std.testing.expect(r2.options.@"test");
    try std.testing.expect(!r3.options.@"test");

    const expectedPositionals: []const []const u8 = &.{ "positional1", "positional2", "positional3" };
    try std.testing.expectEqualDeep(expectedPositionals, r1.positionals);
    try std.testing.expectEqualDeep(expectedPositionals, r2.positionals);

    const expectSkip: []const []const u8 = &.{ "--test", "positional1", "positional2", "positional3" };
    try std.testing.expectEqualDeep(expectSkip, r3.positionals);
}

test "parse verb" {
    const base = &std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base.*);
    defer arena.deinit();
    const allocator = &arena.allocator();

    const Spec = struct {
        verbose: ?bool = null,

        pub const Copy = struct {
            src: ?[]const u8 = null,
        };

        pub const Paste = struct {
            target: ?[]const u8 = null,
        };

        pub const Verb = union(enum) {
            copy: Copy,
            paste: Paste,
        };
    };
    const r1 = try tstParse(allocator, "program copy --src file1", Spec);
    defer r1.deinit();
    const r2 = try tstParse(allocator, "program paste --target file2", Spec);
    defer r2.deinit();
    const r3 = try tstParse(allocator, "program --verbose false copy --src file3", Spec);
    defer r3.deinit();
    const r4 = try tstParse(allocator, "program --verbose true paste --target file4", Spec);
    defer r4.deinit();
    const r5 = try tstParse(allocator, "program --verbose true paste --target file4 positional1", Spec);
    defer r5.deinit();

    try std.testing.expectEqual(Spec.Copy, @TypeOf(r1.verb.?.copy.options));
    try std.testing.expectEqualStrings("file1", r1.verb.?.copy.options.src.?);
    try std.testing.expectEqual(null, r1.options.verbose);
    try std.testing.expectEqual(Spec.Paste, @TypeOf(r2.verb.?.paste.options));
    try std.testing.expectEqualStrings("file2", r2.verb.?.paste.options.target.?);
    try std.testing.expectEqual(null, r2.options.verbose);
    try std.testing.expectEqual(Spec.Copy, @TypeOf(r3.verb.?.copy.options));
    try std.testing.expectEqualStrings("file3", r3.verb.?.copy.options.src.?);
    try std.testing.expectEqual(false, r3.options.verbose.?);
    try std.testing.expectEqual(Spec.Paste, @TypeOf(r4.verb.?.paste.options));
    try std.testing.expectEqualStrings("file4", r4.verb.?.paste.options.target.?);
    try std.testing.expectEqual(true, r4.options.verbose.?);
    try std.testing.expectEqual(Spec.Paste, @TypeOf(r5.verb.?.paste.options));
    try std.testing.expectEqualStrings("file4", r5.verb.?.paste.options.target.?);
    try std.testing.expectEqual(true, r5.options.verbose.?);
    const expected: []const []const u8 = &.{"positional1"};
    try std.testing.expectEqualDeep(expected, r5.verb.?.paste.positionals);
}
