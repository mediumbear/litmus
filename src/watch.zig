//! What `litmus watch` needs that is not a command: a snapshot of the watched files, the
//! comparison of two snapshots (W3), and the wait until the files have been quiet (W1).

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// What was seen of one file: whether it exists, how big it was, and when it was changed.
pub const Entry = struct {
    path: []const u8,
    exists: bool = false,
    size: u64 = 0,
    mtime: i96 = 0,
};

pub const Snapshot = struct { entries: []const Entry };

/// Looks at each path, relative to the current directory. A path that cannot be
/// looked at is a file that does not exist.
pub fn take(io: Io, arena: Allocator, paths: []const []const u8) Allocator.Error!Snapshot {
    const entries = try arena.alloc(Entry, paths.len);
    for (paths, entries) |path, *entry| {
        entry.* = .{ .path = path };
        const stat = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        entry.exists = true;
        entry.size = stat.size;
        entry.mtime = stat.mtime.nanoseconds;
    }
    return .{ .entries = entries };
}

/// The paths whose existence, size or modification time differ between two snapshots
/// (W3). A path that is in only one of them is a change.
pub fn changed(arena: Allocator, old: Snapshot, new: Snapshot) Allocator.Error![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(Entry) = .empty;
    for (old.entries) |entry| try seen.put(arena, entry.path, entry);
    for (new.entries) |entry| {
        const before = seen.get(entry.path) orelse {
            try result.append(arena, entry.path);
            continue;
        };
        _ = seen.remove(entry.path);
        if (before.exists != entry.exists or before.size != entry.size or before.mtime != entry.mtime) {
            try result.append(arena, entry.path);
        }
    }
    for (old.entries) |entry| {
        if (seen.contains(entry.path)) try result.append(arena, entry.path);
    }
    return result.items;
}

/// W1: a change starts a wait, every further change starts it again, and the files are
/// ready to be acted on when nothing changed for `quiet` nanoseconds.
pub const Debounce = struct {
    quiet: i64,
    last_change: ?i64 = null,

    /// Tells the debounce what one look found, and the time of it. Returns true once, when
    /// the files have been quiet for long enough after a change.
    pub fn observe(self: *Debounce, found_change: bool, now: i64) bool {
        if (found_change) {
            self.last_change = now;
            return false;
        }
        const last = self.last_change orelse return false;
        if (now - last < self.quiet) return false;
        self.last_change = null;
        return true;
    }
};

// Tests ----------------------------------------------------------------------

const t = std.testing;

fn file(path: []const u8, size: u64, mtime: i96) Entry {
    return .{ .path = path, .exists = true, .size = size, .mtime = mtime };
}

fn expectChanged(old: []const Entry, new: []const Entry, want: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const got = try changed(arena_state.allocator(), .{ .entries = old }, .{ .entries = new });
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

test "W3: equal snapshots have no changes" {
    try expectChanged(&.{ file("a", 1, 10), file("b", 2, 20) }, &.{ file("a", 1, 10), file("b", 2, 20) }, &.{});
    try expectChanged(&.{}, &.{}, &.{});
}

test "W3: a change of size, of modification time, or of existence is a change" {
    try expectChanged(&.{ file("a", 1, 10), file("b", 2, 20) }, &.{ file("a", 5, 10), file("b", 2, 20) }, &.{"a"});
    try expectChanged(&.{ file("a", 1, 10), file("b", 2, 20) }, &.{ file("a", 1, 10), file("b", 2, 21) }, &.{"b"});
    try expectChanged(&.{file("a", 1, 10)}, &.{.{ .path = "a" }}, &.{"a"});
    try expectChanged(&.{.{ .path = "a" }}, &.{file("a", 1, 10)}, &.{"a"});
    try expectChanged(&.{.{ .path = "a" }}, &.{.{ .path = "a" }}, &.{});
}

test "W3: a path in only one snapshot is a change" {
    try expectChanged(&.{file("a", 1, 10)}, &.{ file("a", 1, 10), file("new", 1, 1) }, &.{"new"});
    try expectChanged(&.{ file("a", 1, 10), file("gone", 1, 1) }, &.{file("a", 1, 10)}, &.{"gone"});
}

test "W3: take looks at real files, and a missing file does not exist" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "f.txt", .data = "abc" });
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/f.txt", .{tmp.sub_path});
    const missing = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/none.txt", .{tmp.sub_path});
    const before = try take(t.io, a, &.{ path, missing });
    try t.expect(before.entries[0].exists);
    try t.expectEqual(3, before.entries[0].size);
    try t.expect(!before.entries[1].exists);
    try t.expectEqual(0, (try changed(a, before, try take(t.io, a, &.{ path, missing }))).len);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "f.txt", .data = "abcdef" });
    const after = try changed(a, before, try take(t.io, a, &.{ path, missing }));
    try t.expectEqual(1, after.len);
    try t.expectEqualStrings(path, after[0]);
}

test "W1: sync is ready when the files have been quiet for one interval" {
    var d: Debounce = .{ .quiet = 200 };
    try t.expect(!d.observe(false, 0));
    try t.expect(!d.observe(true, 200));
    try t.expect(!d.observe(false, 300));
    try t.expect(d.observe(false, 400));
    // Once only.
    try t.expect(!d.observe(false, 600));
}

test "W1: every further change starts the wait again" {
    var d: Debounce = .{ .quiet = 200 };
    try t.expect(!d.observe(true, 0));
    try t.expect(!d.observe(true, 200));
    try t.expect(!d.observe(true, 400));
    try t.expect(!d.observe(false, 500));
    try t.expect(d.observe(false, 600));
    // A change after a quiet time starts a new wait.
    try t.expect(!d.observe(true, 800));
    try t.expect(d.observe(false, 1000));
}
