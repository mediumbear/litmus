//! The `check` command's comparison of tangled text with the files on disk.

const std = @import("std");
const types = @import("types.zig");
const map = @import("map.zig");
const output = @import("output.zig");
const tangle = @import("tangle.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Difference = struct {
    path: []const u8,
    kind: enum { missing, differs, should_be_executable, should_not_be_executable },
    /// For `differs`: the first line that differs, counting from 1.
    line: u32 = 0,
    /// The tangled line and the line on disk, if each exists.
    expected: ?[]const u8 = null,
    found: ?[]const u8 = null,
    /// Where the tangled line, or for a difference past the end the file's last
    /// line, came from.
    origin: ?Origin = null,

    pub const Origin = struct { doc: []const u8, line: u32, excerpt: []const u8 };

    pub fn print(self: Difference, w: *Io.Writer) !void {
        switch (self.kind) {
            .missing => try w.print("{s}: missing\n", .{self.path}),
            .should_be_executable => try w.print("{s}: should be executable\n", .{self.path}),
            .should_not_be_executable => try w.print("{s}: should not be executable\n", .{self.path}),
            .differs => {
                try w.print("{s}:{d}: differs from the tangled text", .{ self.path, self.line });
                if (self.origin) |o| {
                    try w.print("; the line comes from {s}:{d} ({s})", .{ o.doc, o.line, o.excerpt });
                }
                try w.writeAll("\n");
                try w.print("  tangled: {s}\n", .{self.expected orelse "(end of file)"});
                try w.print("  on disk: {s}\n", .{self.found orelse "(end of file)"});
            },
        }
    }
};

/// The line `n` of a text, counting from 1, without its `\n`; null past the end.
fn lineOf(text: []const u8, n: u32) ?[]const u8 {
    var start: usize = 0;
    var i: u32 = 1;
    while (i < n) : (i += 1) {
        start = (std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return null) + 1;
    }
    if (start >= text.len) return null;
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return text[start..end];
}

fn compareFile(docs: []const types.Document, file: tangle.Tangled, text: []const u8) !Difference {
    const common = std.mem.indexOfDiff(u8, file.text, text) orelse unreachable;
    const line: u32 = @intCast(std.mem.countScalar(u8, file.text[0..common], '\n') + 1);
    var difference: Difference = .{
        .path = file.path,
        .kind = .differs,
        .line = line,
        .expected = lineOf(file.text, line),
        .found = lineOf(text, line),
    };
    // A difference past the end of the tangled text is reported at its last run.
    if (map.findRun(file.runs, line)) |at| {
        const run = file.runs[at];
        difference.origin = .{ .doc = docs[run.doc].path, .line = run.doc_line + (line - run.line), .excerpt = run.excerpt };
    } else if (file.runs.len > 0) {
        const run = file.runs[file.runs.len - 1];
        difference.origin = .{ .doc = docs[run.doc].path, .line = run.doc_line + run.count - 1, .excerpt = run.excerpt };
    }
    return difference;
}

/// Compares each tangled file with the file of the same path under `dir`.
pub fn compare(io: Io, arena: Allocator, dir: Io.Dir, docs: []const types.Document, files: []const tangle.Tangled) ![]const Difference {
    var result: std.ArrayList(Difference) = .empty;
    for (files) |file| {
        const text = try output.readOrNull(io, arena, dir, file.path) orelse {
            try result.append(arena, .{ .path = file.path, .kind = .missing });
            continue;
        };
        if (!std.mem.eql(u8, text, file.text)) {
            try result.append(arena, try compareFile(docs, file, text));
        }
        if (comptime Io.File.Permissions.has_executable_bit) {
            const stat = try dir.statFile(io, file.path, .{});
            if (output.isExecutable(stat.permissions) != file.executable) {
                try result.append(arena, .{
                    .path = file.path,
                    .kind = if (file.executable) .should_be_executable else .should_not_be_executable,
                });
            }
        }
    }
    return result.items;
}

// Tests ----------------------------------------------------------------------

const t = std.testing;

const test_docs = [_]types.Document{.{ .path = "d.adoc", .format = .asciidoc, .lines = &.{}, .dir = "" }};
const runs = [_]types.Run{
    .{ .line = 1, .count = 2, .doc = 0, .doc_line = 10, .indent = 0, .excerpt = ":file:" },
    .{ .line = 3, .count = 1, .doc = 0, .doc_line = 20, .indent = 4, .excerpt = "e" },
};

fn tangled(text: []const u8, executable: bool) tangle.Tangled {
    return .{ .path = "a.txt", .executable = executable, .text = text, .runs = &runs, .expansions = &.{} };
}

fn compareText(tmp: *std.testing.TmpDir, a: Allocator, on_disk: ?[]const u8, file: tangle.Tangled) ![]const Difference {
    if (on_disk) |bytes| try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = bytes });
    return compare(t.io, a, tmp.dir, &test_docs, &.{file});
}

test "check: equal files and a missing file" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqual(1, (try compareText(&tmp, a, null, tangled("x\n", false))).len);
    try t.expectEqual(0, (try compareText(&tmp, a, "x\ny\nz\n", tangled("x\ny\nz\n", false))).len);
    const missing = (try compare(t.io, a, tmp.dir, &test_docs, &.{.{ .path = "b.txt", .executable = false, .text = "", .runs = &.{}, .expansions = &.{} }}))[0];
    try t.expectEqual(.missing, missing.kind);
}

test "check: the first differing line, and the document line it came from" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d = (try compareText(&tmp, a, "x\nY\nz\n", tangled("x\ny\nz\n", false)))[0];
    try t.expectEqual(2, d.line);
    try t.expectEqualStrings("y", d.expected.?);
    try t.expectEqualStrings("Y", d.found.?);
    try t.expectEqual(11, d.origin.?.line);
    const e = (try compareText(&tmp, a, "x\ny\nQ\n", tangled("x\ny\nz\n", false)))[0];
    try t.expectEqual(3, e.line);
    try t.expectEqual(20, e.origin.?.line);
    try t.expectEqualStrings("e", e.origin.?.excerpt);
}

test "check: a difference past the end of the tangled text is reported at the last run" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const longer = (try compareText(&tmp, a, "x\ny\nz\nextra\n", tangled("x\ny\nz\n", false)))[0];
    try t.expectEqual(4, longer.line);
    try t.expect(longer.expected == null);
    try t.expectEqualStrings("extra", longer.found.?);
    try t.expectEqual(20, longer.origin.?.line);
    const shorter = (try compareText(&tmp, a, "x\ny\n", tangled("x\ny\nz\n", false)))[0];
    try t.expectEqual(3, shorter.line);
    try t.expect(shorter.found == null);
    try t.expectEqual(20, shorter.origin.?.line);
}

test "check: a difference of executable permission" {
    if (comptime !Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d = (try compareText(&tmp, a, "x\n", tangled("x\n", true)))[0];
    try t.expectEqual(.should_be_executable, d.kind);
    try tmp.dir.setFilePermissions(t.io, "a.txt", .executable_file, .{});
    const e = (try compareText(&tmp, a, null, tangled("x\n", false)))[0];
    try t.expectEqual(.should_not_be_executable, e.kind);
}
