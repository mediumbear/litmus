//! The direction of `litmus sync` (U7): the map says what tangle last wrote, so the
//! hash of a file or of its tangled text, compared with the map's, says which side
//! changed. No IO.

const std = @import("std");

/// What changed for one tangled file since tangle last wrote it.
pub const FileState = enum {
    /// Neither the file nor the documents' code.
    in_sync,
    /// The file on disk, and only that.
    files_changed,
    /// The documents' code, and only that. A file that is missing counts here, since
    /// tangle writes it again.
    documents_changed,
    both_changed,
    /// There is no map entry, and the file differs from its tangled text, so which side
    /// changed is not known.
    unknown,
};

/// `recorded` is the hash in the map, `tangled` is the hash of the text the documents tangle to, and
/// `on_disk` is the hash of the file, or null if it does not exist.
pub fn stateOf(recorded: ?[]const u8, tangled: []const u8, on_disk: ?[]const u8) FileState {
    const disk = on_disk orelse return .documents_changed;
    const entry = recorded orelse return if (std.mem.eql(u8, disk, tangled)) .in_sync else .unknown;
    const files = !std.mem.eql(u8, disk, entry);
    const documents = !std.mem.eql(u8, tangled, entry);
    if (files and documents) return .both_changed;
    if (files) return .files_changed;
    if (documents) return .documents_changed;
    return .in_sync;
}

pub const Direction = enum { in_sync, untangle, tangle, stop };

pub fn direction(states: []const FileState) Direction {
    var files = false;
    var documents = false;
    for (states) |state| switch (state) {
        .in_sync => {},
        .files_changed => files = true,
        .documents_changed => documents = true,
        .both_changed, .unknown => return .stop,
    };
    if (files and documents) return .stop;
    if (files) return .untangle;
    if (documents) return .tangle;
    return .in_sync;
}

const t = std.testing;

test "U7: the hash in the map says which side changed" {
    try t.expectEqual(.in_sync, stateOf("a", "a", "a"));
    try t.expectEqual(.files_changed, stateOf("a", "a", "b"));
    try t.expectEqual(.documents_changed, stateOf("a", "b", "a"));
    try t.expectEqual(.both_changed, stateOf("a", "b", "c"));
    // Both changed to the same text: the file and the documents already agree on something
    // new, and the map is what is behind.
    try t.expectEqual(.both_changed, stateOf("a", "b", "b"));
}

test "U7: a file that is missing is written again" {
    try t.expectEqual(.documents_changed, stateOf("a", "a", null));
    try t.expectEqual(.documents_changed, stateOf(null, "a", null));
}

test "U7: without a map, equal files are in sync and others are not known" {
    try t.expectEqual(.in_sync, stateOf(null, "a", "a"));
    try t.expectEqual(.unknown, stateOf(null, "a", "b"));
}

test "U7: neither, one side, or both" {
    try t.expectEqual(.in_sync, direction(&.{ .in_sync, .in_sync }));
    try t.expectEqual(.in_sync, direction(&.{}));
    try t.expectEqual(.untangle, direction(&.{ .in_sync, .files_changed }));
    try t.expectEqual(.tangle, direction(&.{ .documents_changed, .in_sync }));
    try t.expectEqual(.stop, direction(&.{ .files_changed, .documents_changed }));
    try t.expectEqual(.stop, direction(&.{.both_changed}));
    try t.expectEqual(.stop, direction(&.{ .in_sync, .unknown }));
}
