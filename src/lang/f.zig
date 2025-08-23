const std = @import("std");
const meta = @import("meta.zig");

pub inline fn bind(origF: anytype, currentArg: anytype) type {
    return bindInternal(origF, currentArg, .{}, 0);
}

inline fn bindInternal(origF: anytype, currentArg: anytype, previousArgs: anytype, argIdx: usize) type {
    const fInfo = @typeInfo(meta.ptrToChild(origF));
    comptime if (fInfo != .@"fn")
        @compileError(std.fmt.comptimePrint(
            "Function ptr doesnt point to a function. Found {}",
            .{@tagName(fInfo)},
        ));

    const cArgT = @TypeOf(currentArg);
    const argEnd: usize = type_rt: switch (@typeInfo(cArgT)) {
        .@"struct" => |st| if (st.is_tuple)
            break :type_rt argIdx + st.fields.len
        else
            break :type_rt argIdx + 1,
        else => break :type_rt argIdx + 1,
    };

    const fInfoFn = fInfo.@"fn";
    comptime if (argEnd > fInfoFn.params.len)
        @compileError(std.fmt.comptimePrint(
            "Params length greater than function params. Params length {}",
            .{argEnd},
        ));

    const targetFParams = fInfoFn.params[argIdx..argEnd];
    const currentVarArgs = type_rt: switch (@typeInfo(cArgT)) {
        .@"struct" => |st| if (st.is_tuple)
            break :type_rt currentArg
        else
            break :type_rt .{currentArg},
        else => break :type_rt .{currentArg},
    };
    comptime for (targetFParams, currentVarArgs) |fParam, arg| {
        const pType = fParam.type orelse
            @compileError(std.fmt.comptimePrint(
                "Function has no param type. Fn {}",
                .{fInfoFn},
            ));

        // WARN: Evil cast, I dont know if I can do anything else but this does what I want
        // Purpose is to break if cast isnt safe
        _ = @as(pType, arg);
    };

    const fRType = fInfoFn.return_type orelse
        @compileError(std.fmt.comptimePrint(
            "Function missing return type. Fn {}",
            .{fInfoFn},
        ));

    comptime if (fInfoFn.params.len == argEnd) {
        return struct {
            pub inline fn f() fRType {
                return @call(.auto, origF, previousArgs ++ currentVarArgs);
            }
        };
    } else {
        return struct {
            pub inline fn f(argX: anytype) type {
                return bindInternal(origF, argX, previousArgs ++ currentVarArgs, argEnd);
            }
        };
    };
}

test "currying functions" {
    const C = struct {
        pub fn identity(a: u32) u32 {
            return a;
        }

        pub fn add(a: u32, b: u32) u32 {
            return a + b;
        }

        pub fn addEvenMore(a: u32, b: u32, c: u32, d: u32) u32 {
            return a + b + c + d;
        }
    };

    try std.testing.expectEqual(
        2,
        bind(&C.identity, 2).f(),
    );
    try std.testing.expectEqual(
        5,
        bind(&C.add, 2).f(3).f(),
    );
    try std.testing.expectEqual(
        5,
        bind(&C.add, .{ 3, 2 }).f(),
    );
    try std.testing.expectEqual(
        11,
        bind(&C.addEvenMore, .{ 1, 3 }).f(.{ 3, 4 }).f(),
    );
}
