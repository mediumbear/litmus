//! The Litmus command line. See doc/litmus.adoc for the rules.

const std = @import("std");

const usage =
    \\Usage: litmus tangle [-o DIR] [--force] DOCUMENT...
    \\       litmus check [-o DIR] DOCUMENT...
    \\       litmus where FILE:LINE
    \\       litmus guide
    \\       litmus init [-o DIR] DOCUMENT...
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_writer.interface;
    var err_buf: [4096]u8 = undefined;
    var err_writer: std.Io.File.Writer = .init(.stderr(), io, &err_buf);
    const err = &err_writer.interface;
    defer out.flush() catch {};
    defer err.flush() catch {};

    try err.writeAll(usage);
    return 2;
}
