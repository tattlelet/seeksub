const Errors = error {
    CustomError
};

fn a(arg: u32) Errors!u32 {
    if (arg > 3) return Errors.CustomError;
    return arg;
}

pub fn main() !void {
    _ = try a(2);
}

