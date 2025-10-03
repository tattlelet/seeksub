pub const codec = @import("args/codec.zig");
pub const iterator = @import("args/iterator.zig");
pub const help = @import("args/help.zig");
pub const positionals = @import("args/positionals.zig");
pub const spec = @import("args/spec.zig");
pub const validate = @import("args/validate.zig");

test {
    comptime {
        _ = @import("args/iterator.zig");
        _ = @import("args/codec.zig");
        _ = @import("args/spec.zig");
        _ = @import("args/validate.zig");
        _ = @import("args/help.zig");
        _ = @import("args/positionals.zig");
    }
}
