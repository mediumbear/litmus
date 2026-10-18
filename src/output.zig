//! Writes tangled files and the map: only what changed, each whole and atomically
//! (T4), never over a change tangle did not make (T6), never deleting (T5).

const std = @import("std");
const map = @import("map.zig");
const tangle = @import("tangle.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

pub const map_path = ".litmus/map";

pub const Outcome = struct {
    /// Files changed since tangle wrote them (T6). If there are any, nothing was written.
    conflicts: []const []const u8 = &.{},
    /// Files the previous map lists that are no longer tangled (T5).
    orphans: []const []const u8 = &.{},
    /// Files written or changed.
    written: []const []const u8 = &.{},
    /// The existing map could not be read, so nothing was written.
    bad_map: ?[]const u8 = null,
};

pub fn readOrNull(io: Io, arena: Allocator, dir: Dir, path: []const u8) !?[]const u8 {
    return dir.readFileAlloc(io, path, arena, .limited(1 << 30)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

pub fn isExecutable(permissions: File.Permissions) bool {
    if (comptime !File.Permissions.has_executable_bit) return false;
    return permissions.toMode() & 0o100 != 0;
}

fn withExecutable(permissions: File.Permissions, executable: bool) File.Permissions {
    if (comptime !File.Permissions.has_executable_bit) return permissions;
    var mode = permissions.toMode();
    // An executable bit wherever there is a read bit, as `chmod +x` does.
    const x: @TypeOf(mode) = 0o111;
    mode = if (executable) mode | ((mode & 0o444) >> 2) else mode & ~x;
    return File.Permissions.fromMode(mode);
}

pub fn writeAtomic(io: Io, dir: Dir, path: []const u8, bytes: []const u8, executable: bool) !void {
    var atomic = try dir.createFileAtomic(io, path, .{
        .permissions = if (executable) .executable_file else .default_file,
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}

/// Writes the tangled files under `dir`, and the map text with them.
pub fn write(io: Io, arena: Allocator, dir: Dir, files: []const tangle.Tangled, map_text: []const u8, force: bool) !Outcome {
    // The previous map says what tangle last wrote.
    const previous_text = try readOrNull(io, arena, dir, map_path);
    var previous: ?map.Map = null;
    if (previous_text) |text| {
        previous = map.read(arena, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsupportedMap, error.BadMap => blk: {
                if (!force) return .{ .bad_map = if (err == error.UnsupportedMap) "is not a version 1 map" else "is damaged" };
                break :blk null;
            },
        };
    }

    // T6: look at every existing file before writing any.
    const Existing = struct { text: ?[]const u8 };
    const existing = try arena.alloc(Existing, files.len);
    var conflicts: std.ArrayList([]const u8) = .empty;
    for (files, existing) |file, *slot| {
        slot.text = try readOrNull(io, arena, dir, file.path);
        const text = slot.text orelse continue;
        if (std.mem.eql(u8, text, file.text) or force) continue;
        const recorded = if (previous) |p| p.find(file.path) else null;
        if (recorded == null or !std.mem.eql(u8, recorded.?.hash, &map.hashHex(text))) {
            try conflicts.append(arena, file.path);
        }
    }
    if (conflicts.items.len > 0) return .{ .conflicts = conflicts.items };

    // T4, L9
    var written: std.ArrayList([]const u8) = .empty;
    for (files, existing) |file, slot| {
        if (slot.text) |text| {
            if (std.mem.eql(u8, text, file.text)) {
                const stat = try dir.statFile(io, file.path, .{});
                if (isExecutable(stat.permissions) != file.executable) {
                    try dir.setFilePermissions(io, file.path, withExecutable(stat.permissions, file.executable), .{});
                    try written.append(arena, file.path);
                }
                continue;
            }
        }
        try writeAtomic(io, dir, file.path, file.text, file.executable);
        try written.append(arena, file.path);
    }

    // T5
    var orphans: std.ArrayList([]const u8) = .empty;
    if (previous) |p| {
        for (p.files) |old| {
            for (files) |file| {
                if (std.mem.eql(u8, file.path, old.path)) break;
            } else try orphans.append(arena, old.path);
        }
    }

    if (previous_text == null or !std.mem.eql(u8, previous_text.?, map_text)) {
        try writeAtomic(io, dir, map_path, map_text, false);
    }
    return .{ .orphans = orphans.items, .written = written.items };
}

// Tests ----------------------------------------------------------------------

const t = std.testing;

fn tfile(path: []const u8, text: []const u8, executable: bool) tangle.Tangled {
    return .{ .path = path, .executable = executable, .text = text, .runs = &.{} };
}

fn mapOf(a: Allocator, files: []const tangle.Tangled) ![]const u8 {
    return map.render(a, &.{}, files);
}

fn expectContents(dir: Dir, path: []const u8, want: []const u8) !void {
    var buffer: [256]u8 = undefined;
    const got = try dir.readFile(t.io, path, &buffer);
    try t.expectEqualStrings(want, got);
}

test "T4: a second tangle of unchanged documents writes nothing" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const files = [_]tangle.Tangled{ tfile("a.txt", "one\n", false), tfile("sub/dir/b.txt", "two\n", false) };
    const text = try mapOf(a, &files);
    const first = try write(t.io, a, tmp.dir, &files, text, false);
    try t.expectEqual(2, first.written.len);
    try expectContents(tmp.dir, "sub/dir/b.txt", "two\n");
    try expectContents(tmp.dir, map_path, text);

    const before = [_]Io.Timestamp{
        (try tmp.dir.statFile(t.io, "a.txt", .{})).mtime,
        (try tmp.dir.statFile(t.io, "sub/dir/b.txt", .{})).mtime,
        (try tmp.dir.statFile(t.io, map_path, .{})).mtime,
    };
    const second = try write(t.io, a, tmp.dir, &files, text, false);
    try t.expectEqual(0, second.written.len);
    try t.expectEqual(0, second.conflicts.len);
    const after = [_]Io.Timestamp{
        (try tmp.dir.statFile(t.io, "a.txt", .{})).mtime,
        (try tmp.dir.statFile(t.io, "sub/dir/b.txt", .{})).mtime,
        (try tmp.dir.statFile(t.io, map_path, .{})).mtime,
    };
    for (before, after) |b, f| try t.expectEqual(b.nanoseconds, f.nanoseconds);
}

test "T4: only the file that changed is written" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v1 = [_]tangle.Tangled{ tfile("a.txt", "one\n", false), tfile("b.txt", "two\n", false) };
    _ = try write(t.io, a, tmp.dir, &v1, try mapOf(a, &v1), false);
    const v2 = [_]tangle.Tangled{ tfile("a.txt", "one\n", false), tfile("b.txt", "three\n", false) };
    const out = try write(t.io, a, tmp.dir, &v2, try mapOf(a, &v2), false);
    try t.expectEqual(1, out.written.len);
    try t.expectEqualStrings("b.txt", out.written[0]);
    try expectContents(tmp.dir, "b.txt", "three\n");
}

test "T6: an edited file stops the tangle, and nothing at all is written" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v1 = [_]tangle.Tangled{ tfile("a.txt", "one\n", false), tfile("b.txt", "two\n", false) };
    _ = try write(t.io, a, tmp.dir, &v1, try mapOf(a, &v1), false);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "edited\n" });

    const v2 = [_]tangle.Tangled{ tfile("a.txt", "one more\n", false), tfile("b.txt", "changed\n", false) };
    const out = try write(t.io, a, tmp.dir, &v2, try mapOf(a, &v2), false);
    try t.expectEqual(1, out.conflicts.len);
    try t.expectEqualStrings("a.txt", out.conflicts[0]);
    try expectContents(tmp.dir, "a.txt", "edited\n");
    try expectContents(tmp.dir, "b.txt", "two\n");

    // With --force, the same tangle overwrites it.
    const forced = try write(t.io, a, tmp.dir, &v2, try mapOf(a, &v2), true);
    try t.expectEqual(0, forced.conflicts.len);
    try expectContents(tmp.dir, "a.txt", "one more\n");
    try expectContents(tmp.dir, "b.txt", "changed\n");
}

test "T6: an edit that makes a file equal to its tangled text is no conflict" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v1 = [_]tangle.Tangled{tfile("a.txt", "one\n", false)};
    _ = try write(t.io, a, tmp.dir, &v1, try mapOf(a, &v1), false);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "two\n" });
    // The writer carried the edit into the documents.
    const v2 = [_]tangle.Tangled{tfile("a.txt", "two\n", false)};
    const out = try write(t.io, a, tmp.dir, &v2, try mapOf(a, &v2), false);
    try t.expectEqual(0, out.conflicts.len);
    try t.expectEqual(0, out.written.len);
}

test "T6: with no map, files equal to their tangled text are accepted and others stop the tangle" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "same.txt", .data = "same\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "other.txt", .data = "mine\n" });
    const ok = [_]tangle.Tangled{tfile("same.txt", "same\n", false)};
    const first = try write(t.io, a, tmp.dir, &ok, try mapOf(a, &ok), false);
    try t.expectEqual(0, first.conflicts.len);
    try expectContents(tmp.dir, map_path, try mapOf(a, &ok));

    try tmp.dir.deleteFile(t.io, map_path);
    const bad = [_]tangle.Tangled{ tfile("same.txt", "same\n", false), tfile("other.txt", "tangled\n", false) };
    const out = try write(t.io, a, tmp.dir, &bad, try mapOf(a, &bad), false);
    try t.expectEqual(1, out.conflicts.len);
    try t.expectEqualStrings("other.txt", out.conflicts[0]);
    try expectContents(tmp.dir, "other.txt", "mine\n");
    if (tmp.dir.statFile(t.io, map_path, .{})) |_| return error.MapWritten else |_| {}
}

test "T5: a file no longer tangled is reported and left in place" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v1 = [_]tangle.Tangled{ tfile("a.txt", "one\n", false), tfile("gone.txt", "bye\n", false) };
    _ = try write(t.io, a, tmp.dir, &v1, try mapOf(a, &v1), false);
    const v2 = [_]tangle.Tangled{tfile("a.txt", "one\n", false)};
    const out = try write(t.io, a, tmp.dir, &v2, try mapOf(a, &v2), false);
    try t.expectEqual(1, out.orphans.len);
    try t.expectEqualStrings("gone.txt", out.orphans[0]);
    try expectContents(tmp.dir, "gone.txt", "bye\n");
}

test "L9: executable files are written executable, and a change of permission alone changes only that" {
    if (comptime !File.Permissions.has_executable_bit) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v1 = [_]tangle.Tangled{ tfile("run.sh", "echo\n", true), tfile("plain.txt", "x\n", false) };
    _ = try write(t.io, a, tmp.dir, &v1, try mapOf(a, &v1), false);
    try t.expect(isExecutable((try tmp.dir.statFile(t.io, "run.sh", .{})).permissions));
    try t.expect(!isExecutable((try tmp.dir.statFile(t.io, "plain.txt", .{})).permissions));

    const v2 = [_]tangle.Tangled{ tfile("run.sh", "echo\n", false), tfile("plain.txt", "x\n", true) };
    const mtime = (try tmp.dir.statFile(t.io, "run.sh", .{})).mtime;
    const out = try write(t.io, a, tmp.dir, &v2, try mapOf(a, &v2), false);
    try t.expectEqual(2, out.written.len);
    try t.expect(!isExecutable((try tmp.dir.statFile(t.io, "run.sh", .{})).permissions));
    try t.expect(isExecutable((try tmp.dir.statFile(t.io, "plain.txt", .{})).permissions));
    try t.expectEqual(mtime.nanoseconds, (try tmp.dir.statFile(t.io, "run.sh", .{})).mtime.nanoseconds);
}

test "a map of another version stops the tangle unless forced" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try tmp.dir.createDirPath(t.io, ".litmus");
    try tmp.dir.writeFile(t.io, .{ .sub_path = map_path, .data = "litmus map 9\n" });
    const files = [_]tangle.Tangled{tfile("a.txt", "one\n", false)};
    const out = try write(t.io, a, tmp.dir, &files, try mapOf(a, &files), false);
    try t.expect(out.bad_map != null);
    const forced = try write(t.io, a, tmp.dir, &files, try mapOf(a, &files), true);
    try t.expect(forced.bad_map == null);
    try expectContents(tmp.dir, "a.txt", "one\n");
}
