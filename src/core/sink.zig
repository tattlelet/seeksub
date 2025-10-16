const std = @import("std");
const units = @import("zpec").units;
const C = @import("c.zig").C;
const regex = @import("regex.zig");
const File = std.fs.File;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;

pub const Reporter = struct {
    stdoutW: *Writer = undefined,
    stderrW: *Writer = undefined,
};

pub const DetectSinkError = error{
    UnableToQueryFd,
    UnsupportedFileType,
};

pub const SinkType = enum {
    tty,
    characterDevice,
    file,
    pipe,
    generic,
};

pub fn detectSink(file: File) DetectSinkError!SinkType {
    const stat = file.stat() catch return DetectSinkError.UnableToQueryFd;
    switch (stat.kind) {
        .character_device => {
            return if (file.isTty()) .tty else .characterDevice;
        },
        .file => return .file,
        .named_pipe => return .pipe,
        else => return .generic,
    }
    unreachable;
}

pub const SinkBufferType = enum {
    heapGrowing,
    directWrite,
};

pub const SinkBuffer = union(SinkBufferType) {
    heapGrowing: usize,
    directWrite,
};

pub fn pickSinkBuffer(sinkType: SinkType, eventHandler: EventHandler) SinkBuffer {
    switch (sinkType) {
        .tty => {
            return switch (eventHandler) {
                .colorMatch => .{ .heapGrowing = units.CacheSize.L3 },
                else => .directWrite,
            };
        },
        .generic,
        .characterDevice,
        .pipe,
        .file,
        => return .directWrite,
    }
    unreachable;
}

pub const EventHandler = union(enum) {
    colorMatch: std.Io.tty.Config,
    skipLineOnMatch,
};

pub fn pickEventHandler(sinkType: SinkType, file: File, colored: bool) EventHandler {
    switch (sinkType) {
        .tty => {
            if (colored) {
                return .{ .colorMatch = .detect(file) };
            } else {
                return .skipLineOnMatch;
            }
        },
        .generic,
        .characterDevice,
        .file,
        .pipe,
        => return .skipLineOnMatch,
    }
    unreachable;
}

pub const MatchEvent = struct {
    line: []const u8,
    data: []const u8,
};

pub const Events = union(enum) {
    matchEvent: MatchEvent,
    nonMatchEvent: []const u8,
    endOfLineEvent: []const u8,
};

// NOTE: this is not a writer because flush calls drain repeteadly
// Allocating doesnt accept chaining
pub const AllocToFileWriter = struct {
    allocating: *std.Io.Writer.Allocating,
    fdWriter: *std.fs.File.Writer,

    pub fn flush(self: *@This()) !void {
        const buff = self.allocating.writer.buffered();
        try self.fdWriter.interface.writeAll(buff);
        _ = self.allocating.writer.consumeAll();
    }

    pub fn writer(self: *@This()) *Writer {
        return &self.allocating.writer;
    }

    pub fn deinit(self: *@This()) void {
        self.allocating.deinit();
        self.allocating = undefined;
        self.fdWriter = undefined;
    }
};

pub const SinkWriter = union(SinkBufferType) {
    heapGrowing: *AllocToFileWriter,
    directWrite: *std.fs.File.Writer,
};

pub const Sink = struct {
    sinkType: SinkType,
    eventHandler: EventHandler,
    colorEnabled: bool = false,
    sinkWriter: SinkWriter,

    pub fn sendColor(
        self: *const @This(),
        config: std.Io.tty.Config,
        color: std.Io.tty.Color,
    ) std.Io.tty.Config.SetColorError!void {
        switch (self.sinkWriter) {
            .heapGrowing => |alloc| {
                try config.setColor(alloc.writer(), color);
            },
            .directWrite => |w| {
                try config.setColor(&w.interface, color);
            },
        }
    }

    pub fn resetColor(
        self: *const @This(),
        config: std.Io.tty.Config,
    ) std.Io.tty.Config.SetColorError!void {
        if (self.colorEnabled) try self.sendColor(config, .reset);
    }

    pub fn reenableColor(
        self: *const @This(),
        config: std.Io.tty.Config,
    ) std.Io.tty.Config.SetColorError!void {
        if (self.colorEnabled) try self.sendColor(config, .bright_red);
    }

    pub fn enableColor(self: *@This(), config: std.Io.tty.Config) std.Io.tty.Config.SetColorError!void {
        if (!self.colorEnabled) {
            self.colorEnabled = true;
            try self.reenableColor(config);
        }
    }

    pub fn disableColor(self: *@This(), config: std.Io.tty.Config) std.Io.tty.Config.SetColorError!void {
        if (self.colorEnabled) {
            try self.resetColor(config);
            self.colorEnabled = false;
        }
    }

    pub fn ttyReset(self: *@This()) !void {
        switch (self.eventHandler) {
            .colorMatch => |config| {
                try self.disableColor(config);
            },
            else => {},
        }
    }

    pub fn writeAll(self: *const @This(), data: []const u8) !void {
        switch (self.sinkWriter) {
            .heapGrowing => |alloc| {
                try alloc.writer().writeAll(data);
            },
            .directWrite => |writer| {
                try writer.interface.writeAll(data);
            },
        }
    }

    pub fn sinkLine(self: *const @This()) Writer.Error!void {
        switch (self.sinkType) {
            .tty => {
                switch (self.sinkWriter) {
                    .heapGrowing => |alloc| {
                        try alloc.flush();
                    },
                    .directWrite => {},
                }
            },
            else => {},
        }
    }

    pub fn sink(self: *const @This()) Writer.Error!void {
        switch (self.sinkWriter) {
            .heapGrowing => |alloc| {
                try alloc.flush();
            },
            .directWrite => {},
        }
    }

    pub fn deinit(self: *@This()) void {
        switch (self.sinkWriter) {
            .heapGrowing => |alloc| {
                alloc.deinit();
            },
            .directWrite => {},
        }
    }

    pub const ConsumeError = error{} ||
        std.fs.File.WriteError ||
        std.Io.tty.Config.SetColorError ||
        Writer.Error;

    pub const ConsumeResponse = enum {
        eventSkipped,
        eventConsumed,
        lineConsumed,
    };

    pub fn consume(self: *@This(), event: Events) ConsumeError!ConsumeResponse {
        switch (self.eventHandler) {
            .colorMatch => |config| {
                switch (event) {
                    .nonMatchEvent => |data| {
                        try self.resetColor(config);
                        try self.writeAll(data);
                        try self.reenableColor(config);
                        return .eventConsumed;
                    },
                    .matchEvent => |matchEvent| {
                        try self.enableColor(config);
                        try self.writeAll(matchEvent.data);
                        return .eventConsumed;
                    },
                    .endOfLineEvent => |data| {
                        try self.disableColor(config);
                        try self.writeAll(data);
                        return .eventConsumed;
                    },
                }
            },
            .skipLineOnMatch => {
                switch (event) {
                    // Generic events are silenced in this case
                    .endOfLineEvent,
                    .nonMatchEvent,
                    => return .eventSkipped,
                    .matchEvent => |matchEvent| {
                        try self.writeAll(matchEvent.line);
                        return .lineConsumed;
                    },
                }
            },
        }
    }
};
