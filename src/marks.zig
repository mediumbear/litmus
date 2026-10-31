//! `adopt --diff` (A9): reads a unified diff, and marks the blocks of an adopted document
//! that hold the lines it changed (L12). No IO.

const std = @import("std");
const types = @import("types.zig");
const tangle = @import("tangle.zig");
const map = @import("map.zig");

const Allocator = std.mem.Allocator;
const Block = types.Block;

/// Lines removed from a file, after its new side's line `after` (0 is the start).
pub const Removal = struct { after: u32, count: u32 };

/// What a diff did to one file, on its new side. Lines count from 1.
pub const FileChange = struct {
    path: []const u8,
    /// The added lines, in order.
    added: []const u32,
    removed: []const Removal,
};

pub const Parsed = struct {
    files: []const FileChange,
    /// The line of the diff that could not be read, and why; then `files` is empty.
    problem: ?struct { line: u32, reason: []const u8 } = null,
};

/// A path of a `---` or `+++` line: without the tab and what follows it, without the
/// quotes git puts around unusual names, and without a leading `a/` or `b/`.
fn diffPath(arena: Allocator, raw: []const u8) ![]const u8 {
    var path = raw;
    if (std.mem.indexOfScalar(u8, path, '\t')) |tab| path = path[0..tab];
    path = std.mem.trimEnd(u8, path, " \r");
    if (path.len >= 2 and path[0] == '"' and path[path.len - 1] == '"') {
        // C-style escapes: \\, \", \t, \n, and octal bytes such as \303.
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 1;
        while (i < path.len - 1) : (i += 1) {
            const c = path[i];
            if (c != '\\' or i + 1 >= path.len - 1) {
                try out.append(arena, c);
                continue;
            }
            i += 1;
            switch (path[i]) {
                't' => try out.append(arena, '\t'),
                'n' => try out.append(arena, '\n'),
                '0'...'7' => {
                    var value: u32 = 0;
                    var digits: usize = 0;
                    while (digits < 3 and i < path.len - 1 and path[i] >= '0' and path[i] <= '7') : (digits += 1) {
                        value = value * 8 + (path[i] - '0');
                        i += 1;
                    }
                    i -= 1;
                    try out.append(arena, @truncate(value));
                },
                else => |e| try out.append(arena, e),
            }
        }
        path = out.items;
    }
    if (std.mem.startsWith(u8, path, "a/") or std.mem.startsWith(u8, path, "b/")) path = path[2..];
    return path;
}

/// The start and count of one side of a hunk header, such as `12,3` or `12`.
fn range(text: []const u8) ?struct { start: u32, count: u32 } {
    const comma = std.mem.indexOfScalar(u8, text, ',');
    const start = std.fmt.parseInt(u32, if (comma) |c| text[0..c] else text, 10) catch return null;
    const count = if (comma) |c| std.fmt.parseInt(u32, text[c + 1 ..], 10) catch return null else 1;
    return .{ .start = start, .count = count };
}

/// A9: the changes of each file a unified diff names. A file the diff deletes is left out.
pub fn parse(arena: Allocator, text: []const u8) !Parsed {
    const lines = try @import("scan.zig").splitLines(arena, text);
    var files: std.ArrayList(FileChange) = .empty;
    var added: std.ArrayList(u32) = .empty;
    var removed: std.ArrayList(Removal) = .empty;
    var path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const line = lines[i];
        if (std.mem.startsWith(u8, line, "+++ ")) {
            if (path) |p| try files.append(arena, .{ .path = p, .added = try added.toOwnedSlice(arena), .removed = try removed.toOwnedSlice(arena) });
            const name = try diffPath(arena, line[4..]);
            path = if (std.mem.eql(u8, name, "/dev/null")) null else name;
            continue;
        }
        if (!std.mem.startsWith(u8, line, "@@ -")) continue;

        // @@ -a,b +c,d @@
        const bad: Parsed = .{ .files = &.{}, .problem = .{ .line = @intCast(i + 1), .reason = "A9: a hunk header that cannot be read" } };
        const rest = line[4..];
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return bad;
        const old = range(rest[0..space]) orelse return bad;
        if (!std.mem.startsWith(u8, rest[space..], " +")) return bad;
        const after_plus = rest[space + 2 ..];
        const end = std.mem.indexOfScalar(u8, after_plus, ' ') orelse return bad;
        const new = range(after_plus[0..end]) orelse return bad;

        // The new side's lines before the next line of the hunk.
        var at: u32 = if (new.count == 0) new.start else new.start - @min(new.start, 1);
        var old_left = old.count;
        var new_left = new.count;
        // The group of removed and added lines being read.
        var minus: u32 = 0;
        var plus: u32 = 0;
        while (old_left > 0 or new_left > 0) {
            i += 1;
            if (i >= lines.len) return .{ .files = &.{}, .problem = .{ .line = @intCast(lines.len), .reason = "A9: the diff ends inside a hunk" } };
            const body = lines[i];
            const too_long: Parsed = .{ .files = &.{}, .problem = .{ .line = @intCast(i + 1), .reason = "A9: the hunk has more lines than its header says" } };
            // Some tools drop the space of an empty line of context.
            switch (if (body.len == 0) ' ' else body[0]) {
                '\\' => continue, // "\ No newline at end of file"
                ' ' => {
                    if (path != null and minus > plus) try removed.append(arena, .{ .after = at, .count = minus - plus });
                    minus = 0;
                    plus = 0;
                    if (old_left == 0 or new_left == 0) return too_long;
                    old_left -= 1;
                    new_left -= 1;
                    at += 1;
                },
                '+' => {
                    if (new_left == 0) return too_long;
                    new_left -= 1;
                    at += 1;
                    plus += 1;
                    if (path != null) try added.append(arena, at);
                },
                '-' => {
                    if (old_left == 0) return too_long;
                    old_left -= 1;
                    minus += 1;
                },
                else => return .{ .files = &.{}, .problem = .{ .line = @intCast(i + 1), .reason = "A9: a line of a hunk that is neither context, added nor removed" } },
            }
        }
        if (path != null and minus > plus) try removed.append(arena, .{ .after = at, .count = minus - plus });
    }
    if (path) |p| try files.append(arena, .{ .path = p, .added = try added.toOwnedSlice(arena), .removed = try removed.toOwnedSlice(arena) });
    return .{ .files = files.items };
}

/// A document's lines with the marks, and how many blocks have them.
pub const Marked = struct { lines: []const []const u8, blocks: u32 };

/// The marks of one block: its changed lines, counting from its first line, and how many
/// lines were removed in it.
const Marks = struct {
    lines: std.ArrayList(u32) = .empty,
    removed: u32 = 0,
};

/// `3..7;12`: the numbers, which are in order, as ranges.
pub fn ranges(arena: Allocator, numbers: []const u32) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < numbers.len) {
        var j = i;
        while (j + 1 < numbers.len and numbers[j + 1] == numbers[j] + 1) j += 1;
        if (out.items.len > 0) try out.append(arena, ';');
        if (j == i) {
            try out.print(arena, "{d}", .{numbers[i]});
        } else {
            try out.print(arena, "{d}..{d}", .{ numbers[i], numbers[j] });
        }
        i = j + 1;
    }
    return out.items;
}

/// The block that `line` of a tangled file comes from, and the line's number in it.
fn origin(file: tangle.Tangled, line: u32) ?struct { block: *const Block, index: u32 } {
    const r = map.findRun(file.runs, line) orelse return null;
    const run = file.runs[r];
    const block = run.block orelse return null;
    return .{ .block = block, .index = run.doc_line - block.first_line + (line - run.line) + 1 };
}

fn lessU32(_: void, a: u32, b: u32) bool {
    return a < b;
}

/// A9: the lines of an adopted document, with the marks of L12 on the source lines of the
/// blocks that hold changed lines. `files` are the document's files, tangled. Adopt
/// writes each source line two lines above the block's first line of code.
pub fn mark(arena: Allocator, doc_lines: []const []const u8, files: []const tangle.Tangled, changes: []const FileChange) !Marked {
    var marks: std.AutoArrayHashMapUnmanaged(*const Block, Marks) = .empty;
    for (changes) |change| {
        const file = for (files) |f| {
            if (std.mem.eql(u8, f.path, change.path)) break f;
        } else continue;
        const count: u32 = @intCast(std.mem.countScalar(u8, file.text, '\n'));
        for (change.added) |line| {
            const o = origin(file, line) orelse continue;
            const entry = try marks.getOrPutValue(arena, o.block, .{});
            try entry.value_ptr.lines.append(arena, o.index);
        }
        for (change.removed) |removal| {
            if (count == 0) continue;
            const o = origin(file, @min(@max(removal.after, 1), count)) orelse continue;
            const entry = try marks.getOrPutValue(arena, o.block, .{});
            entry.value_ptr.removed += removal.count;
        }
    }

    const result = try arena.dupe([]const u8, doc_lines);
    var marked: u32 = 0;
    var it = marks.iterator();
    while (it.next()) |entry| {
        const block = entry.key_ptr.*;
        const m = entry.value_ptr;
        const at = block.first_line - 3;
        const source = result[at];
        if (!std.mem.startsWith(u8, source, "[source,") or !std.mem.endsWith(u8, source, "]")) continue;
        var line: std.ArrayList(u8) = .empty;
        try line.appendSlice(arena, source[0 .. source.len - 1]);
        if (m.lines.items.len > 0) {
            std.mem.sort(u32, m.lines.items, {}, lessU32);
            try line.print(arena, ",litmus-changed=\"{s}\"", .{try ranges(arena, m.lines.items)});
        }
        if (m.removed > 0) try line.print(arena, ",litmus-removed=\"{d}\"", .{m.removed});
        try line.append(arena, ']');
        result[at] = line.items;
        marked += 1;
    }
    return .{ .lines = result, .blocks = marked };
}

/// L12: the value of `name="..."` in a block attribute line, or null.
pub fn attribute(line: []const u8, name: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, name)) |at| {
        from = at + name.len;
        const before_ok = at > 0 and (line[at - 1] == ',' or line[at - 1] == '[');
        if (!before_ok or !std.mem.startsWith(u8, line[from..], "=\"")) continue;
        const start = from + 2;
        const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
        return line[start..end];
    }
    return null;
}

/// L12: what a block's source line says changed, as written there.
pub const BlockMarks = struct { changed: ?[]const u8 = null, removed: ?[]const u8 = null };

/// L12: the marks of a block, from the attribute lines between its label and its code.
pub fn blockMarks(doc: types.Document, block: Block) BlockMarks {
    if (block.first_line < 2 or block.label.line + 1 > block.first_line - 1) return .{};
    var result: BlockMarks = .{};
    for (doc.lines[block.label.line .. block.first_line - 2]) |line| {
        if (attribute(line, "litmus-changed")) |v| result.changed = v;
        if (attribute(line, "litmus-removed")) |v| result.removed = v;
    }
    return result;
}

/// A9: the text of an adopted document with the marks of the changes. The document must
/// pass the checks, as adopt's does by construction.
pub fn markDocument(arena: Allocator, doc: types.Document, changes: []const FileChange) !struct { text: []const u8, blocks: u32 } {
    var diags = types.Diagnostics.init(arena);
    const parsed = try @import("parse.zig").parse(arena, 0, doc, &diags);
    const resolved = try @import("resolve.zig").resolve(arena, try arena.dupe(types.Document, &.{doc}), parsed.blocks, &diags);
    if (diags.list.items.len > 0) return error.InvalidDocument;
    const files = try tangle.tangleAll(arena, resolved);
    const marked = try mark(arena, doc.lines, files, changes);
    var out: std.ArrayList(u8) = .empty;
    for (marked.lines) |line| {
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    return .{ .text = out.items, .blocks = marked.blocks };
}

// Tests ----------------------------------------------------------------------

const t = std.testing;

test "A9: a diff with context, a new file, a deleted file and a quoted path" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parsed = try parse(a,
        \\diff --git a/x.zig b/x.zig
        \\index 1..2 100644
        \\--- a/x.zig
        \\+++ b/x.zig
        \\@@ -1,5 +1,4 @@
        \\ one
        \\-two
        \\+TWO
        \\ three
        \\-four
        \\ five
        \\@@ -9,0 +9,2 @@ fn tail
        \\+nine
        \\+ten
        \\diff --git a/gone.zig b/gone.zig
        \\--- a/gone.zig
        \\+++ /dev/null
        \\@@ -1,2 +0,0 @@
        \\-a
        \\-b
        \\--- /dev/null
        \\+++ "b/caf\303\251 x.txt"
        \\@@ -0,0 +1 @@
        \\+new
        \\\ No newline at end of file
        \\
    );
    try t.expect(parsed.problem == null);
    try t.expectEqual(2, parsed.files.len);
    const x = parsed.files[0];
    try t.expectEqualStrings("x.zig", x.path);
    try t.expectEqualSlices(u32, &.{ 2, 9, 10 }, x.added);
    // `two` was replaced, so it is not removed; `four` was removed after `three`.
    try t.expectEqual(1, x.removed.len);
    try t.expectEqual(Removal{ .after = 3, .count = 1 }, x.removed[0]);
    try t.expectEqualStrings("café x.txt", parsed.files[1].path);
    try t.expectEqualSlices(u32, &.{1}, parsed.files[1].added);
}

test "A9: a removal without context, and a hunk that is cut short" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parsed = try parse(a, "+++ b/y.txt\n@@ -4,2 +3,0 @@\n-x\n-y\n@@ -10 +9 @@\n-old\n+new\n");
    try t.expectEqual(Removal{ .after = 3, .count = 2 }, parsed.files[0].removed[0]);
    try t.expectEqualSlices(u32, &.{9}, parsed.files[0].added);
    const short = try parse(a, "+++ b/y.txt\n@@ -1,3 +1,3 @@\n a\n");
    try t.expect(short.problem != null);
    try t.expectEqual(0, short.files.len);
}

test "L12: the marks of a source line" {
    const line = "[source,swift,litmus-changed=\"3..7;12\",litmus-removed=\"2\"]";
    try t.expectEqualStrings("3..7;12", attribute(line, "litmus-changed").?);
    try t.expectEqualStrings("2", attribute(line, "litmus-removed").?);
    try t.expect(attribute("[source,swift]", "litmus-changed") == null);
    try t.expect(attribute("[source,swift,xlitmus-changed=\"1\"]", "litmus-changed") == null);
}

test "A9: ranges" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    try t.expectEqualStrings("3..7;12", try ranges(arena_state.allocator(), &.{ 3, 4, 5, 6, 7, 12 }));
    try t.expectEqualStrings("1", try ranges(arena_state.allocator(), &.{1}));
}
