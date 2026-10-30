//! Ctrl-C: SIGINT and SIGTERM set a flag that workers look at between
//! batches. A worker that sees it stops, and the deferred cleanup deletes
//! its temporary output, so an interrupted run leaves no partial file. The
//! handler does nothing but store, which is all a signal handler may do.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

var flag: std.atomic.Value(bool) = .init(false);

pub fn requested() bool {
    return flag.load(.acquire);
}

/// For tests, and for a second run in one process.
pub fn reset() void {
    flag.store(false, .release);
}

pub fn request() void {
    flag.store(true, .release);
}

const supported = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
    else => false,
};

/// Routes SIGINT and SIGTERM to the flag. Where signals are not posix
/// ones, Ctrl-C ends the process as it would anyway.
pub fn install() void {
    if (!supported) return;
    const act: posix.Sigaction = .{
        .handler = .{ .handler = handle },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(.INT, &act, null);
    posix.sigaction(.TERM, &act, null);
}

fn handle(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    flag.store(true, .release);
}

test "the flag" {
    reset();
    try std.testing.expect(!requested());
    request();
    try std.testing.expect(requested());
    reset();
}
