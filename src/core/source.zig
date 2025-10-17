const std = @import("std");
const units = @import("zpec").units;
const fs = @import("fs.zig");
const File = std.fs.File;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

pub const SourceBufferType = enum {
    growingDoubleBuffer,
    mmap,
};

pub const GrowingDoubleBufferConfig = struct {
    readBuffer: usize,
    targetInitialSize: usize,
};

pub const SourceBuffer = union(SourceBufferType) {
    growingDoubleBuffer: GrowingDoubleBufferConfig,
    mmap,
};

pub fn pickSourceBuffer(fileType: fs.FileType) SourceBuffer {
    switch (fileType) {
        .tty,
        .pipe,
        .generic,
        .characterDevice,
        => return .{
            .growingDoubleBuffer = .{
                .readBuffer = units.PipeSize,
                .targetInitialSize = units.CacheSize.L3,
            },
        },
        .file,
        => return .mmap,
    }
    unreachable;
}

pub const ReadEvent = union(enum) {
    endOfFile,
    endOfFileChunk: []const u8,
    line: []const u8,

    pub const Error = error{
        ReadFailed,
    };
};

pub const MmapSource = struct {
    buffer: []align(std.heap.page_size_min) const u8,
    reader: *Reader,

    pub fn nextLine(self: *const @This()) ReadEvent.Error!ReadEvent {
        const line = self.reader.takeDelimiterInclusive('\n') catch |e| switch (e) {
            std.Io.Reader.DelimiterError.EndOfStream => {
                if (self.reader.bufferedLen() == 0) return .endOfFile;
                const slice = self.reader.buffered();
                self.reader.toss(slice.len);
                return .{
                    .endOfFileChunk = slice,
                };
            },
            std.Io.Reader.DelimiterError.ReadFailed,
            std.Io.Reader.DelimiterError.StreamTooLong,
            => return ReadEvent.Error.ReadFailed,
        };
        return .{ .line = line };
    }

    pub fn deinit(self: *@This()) void {
        std.posix.munmap(self.buffer);
    }
};

pub const MmapBufferError = std.posix.RealPathError || std.posix.MMapError;

pub fn mmapBuffer(file: std.fs.File) MmapBufferError![]align(std.heap.page_size_min) u8 {
    const stats = try file.stat();
    const fSize = stats.size;

    return try std.posix.mmap(
        null,
        fSize,
        std.posix.PROT.READ,
        .{
            .TYPE = .SHARED,
            .NONBLOCK = true,
        },
        file.handle,
        0,
    );
}

pub fn readWithMmapSource(file: File) !void {
    const buff: []align(std.heap.page_size_min) u8 = try mmapBuffer(file);
    var reader = Reader.fixed(buff);
    var mmapSource: MmapSource = .{
        .buffer = buff,
        .reader = &reader,
    };
    defer mmapSource.deinit();

    while (true) {
        switch (try mmapSource.nextLine()) {
            .endOfFileChunk,
            .line,
            => |data| {
                std.debug.print("{s}", .{data});
            },
            .endOfFile => break,
        }
    }
}

pub const GrowingDoubleBufferSource = struct {
    reader: *Reader,
    growingWriter: *Writer.Allocating,

    fn recoverBuffer(self: *const @This()) []const u8 {
        const slice = self.growingWriter.writer.buffered();
        _ = self.growingWriter.writer.consumeAll();
        return slice;
    }

    pub fn nextLine(self: *const @This()) ReadEvent.Error!ReadEvent {
        var writer = &self.growingWriter.writer;
        _ = &writer;

        const chunk = self.reader.streamDelimiterEnding(writer, '\n') catch |e| switch (e) {
            Reader.StreamRemainingError.ReadFailed,
            Reader.StreamRemainingError.WriteFailed,
            => return ReadEvent.Error.ReadFailed,
        };

        if (chunk == 0 and self.reader.bufferedLen() == 0) return .endOfFile;

        if (self.reader.bufferedLen() >= 1) {
            self.reader.streamExact(writer, 1) catch |e| switch (e) {
                Reader.StreamError.EndOfStream => return .{
                    .endOfFileChunk = self.recoverBuffer(),
                },
                Reader.StreamError.ReadFailed,
                Reader.StreamError.WriteFailed,
                => return ReadEvent.Error.ReadFailed,
            };
        }

        return .{ .line = self.recoverBuffer() };
    }

    pub fn deinit(self: *@This()) void {
        self.growingWriter.deinit();
    }
};

// pub fn r() !void {
//     var buff: [1]u8 = undefined;
//     // var buff: [units.PipeSize]u8 = undefined;
//     var fsReader = std.fs.File.stdin().reader(&buff);
//     var writer = try std.Io.Writer.Allocating.initCapacity(std.heap.page_allocator, units.CacheSize.L3);
//
//     var source: GrowingDoubleBufferSource = .{
//         .growingWriter = &writer,
//         .reader = &fsReader.interface,
//     };
//
//     defer source.deinit();
//     while (true) {
//         switch (try source.nextLine()) {
//             .endOfFileChunk,
//             .line,
//             => |data| {
//                 std.debug.print("{s}", .{data});
//             },
//             .endOfFile => break,
//         }
//     }
// }

pub const SourceReader = union(SourceBufferType) {
    growingDoubleBuffer: *GrowingDoubleBufferSource,
    mmap: *MmapSource,
};

pub const Source = struct {
    sourceReader: SourceReader,

    pub fn nextLine(self: *const @This()) ReadEvent.Error!ReadEvent {
        switch (self.sourceReader) {
            inline else => |source| {
                return try source.nextLine();
            },
        }
    }

    pub fn deinit(self: *@This()) void {
        switch (self.sourceReader) {
            inline else => |source| source.deinit(),
        }
    }
};
