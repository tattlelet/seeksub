const std = @import("std");
const File = std.fs.File;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;

pub const Reporter = struct {
    stdoutW: *Writer = undefined,
    stderrW: *Writer = undefined,
};

pub const PickBufferError = error{
    UnsupportedFileType,
} ||
    File.StatError;

pub const BufferType = enum {
    mmap,
    stack,
};

pub fn outputBuffType(file: *const File) PickBufferError!BufferType {
    const stat = try file.stat();
    return switch (stat.kind) {
        .character_device => if (file.isTty()) .stack else .mmap,
        .file => .mmap,
        .named_pipe => .stack,
        else => PickBufferError.UnsupportedFileType,
    };
}
