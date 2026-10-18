//! Reads the documents named on the command line and follows `include::` (L6),
//! giving the document set and its blocks in reading order. The reading itself is
//! left to a `fs` value, so the tests need no files.

const std = @import("std");
const scan = @import("scan.zig");
const parse = @import("parse.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Document = types.Document;
const Block = types.Block;
const Diagnostics = types.Diagnostics;

pub const Set = struct {
    /// In the order they were first read: a document, then what it includes.
    docs: []const Document,
    /// Every labeled block of the set in reading order: a block of an including
    /// document that comes after an include follows the included document's blocks.
    blocks: []const Block,
};

/// `.adoc`, `.asciidoc` and `.asc` are asciidoc, and `.md` is Markdown.
pub fn formatOf(path: []const u8) ?types.Format {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".adoc") or std.mem.eql(u8, ext, ".asciidoc") or std.mem.eql(u8, ext, ".asc")) return .asciidoc;
    if (std.mem.eql(u8, ext, ".md")) return .markdown;
    return null;
}

/// Joins `rel` to the directory `dir` and removes `.` and `..` parts.
pub fn joinPath(arena: Allocator, dir: []const u8, rel: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    inline for (.{ dir, rel }) |path| {
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..") and parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
            } else {
                try parts.append(arena, part);
            }
        }
    }
    return std.mem.join(arena, "/", parts.items);
}

fn dirOf(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse "";
}

const Loader = struct {
    arena: Allocator,
    fs: *anyopaque,
    read: *const fn (fs: *anyopaque, arena: Allocator, path: []const u8) ?[]const u8,
    diags: *Diagnostics,
    docs: std.ArrayList(Document) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    /// The documents of the set by path, with whether they are still being read.
    seen: std.StringHashMapUnmanaged(Seen) = .empty,

    const Seen = struct { doc: u32, reading: bool };
    const From = struct { doc: u32, line: u32 };

    fn visit(self: *Loader, path: []const u8, from: ?From) !void {
        if (self.seen.get(path)) |seen| {
            const at: From = from orelse .{ .doc = seen.doc, .line = 0 };
            if (seen.reading) {
                try self.diags.add(at.doc, at.line, "C10: {s} includes itself", .{path});
            } else {
                try self.diags.add(at.doc, at.line, "C10: {s} is in the document set twice", .{path});
            }
            return;
        }
        const index: u32 = @intCast(self.docs.items.len);
        const format = formatOf(path);
        const text = if (format != null) self.read(self.fs, self.arena, path) else null;
        const lines = if (text) |bytes| try scan.splitLines(self.arena, bytes) else &[0][]const u8{};
        try self.docs.append(self.arena, .{ .path = path, .format = format orelse .asciidoc, .lines = lines, .dir = dirOf(path) });
        try self.seen.put(self.arena, path, .{ .doc = index, .reading = true });
        defer self.seen.getPtr(path).?.reading = false;
        if (text == null) {
            const at: From = from orelse .{ .doc = index, .line = 0 };
            if (format == null) {
                try self.diags.add(at.doc, at.line, "C10: {s} is not a .adoc, .asciidoc, .asc or .md document", .{path});
            } else {
                try self.diags.add(at.doc, at.line, "C10: cannot read {s}", .{path});
            }
            return;
        }
        const parsed = try parse.parse(self.arena, index, self.docs.items[index], self.diags);
        var b: usize = 0;
        var i: usize = 0;
        while (b < parsed.blocks.len or i < parsed.includes.len) {
            if (i == parsed.includes.len or (b < parsed.blocks.len and parsed.blocks[b].first_line < parsed.includes[i].line)) {
                try self.blocks.append(self.arena, parsed.blocks[b]);
                b += 1;
            } else {
                const include = parsed.includes[i];
                i += 1;
                const child = try joinPath(self.arena, self.docs.items[index].dir, include.path);
                try self.visit(child, .{ .doc = index, .line = include.line });
            }
        }
    }
};

/// Loads the document set. `fs.read(arena, path)` gives a file's text or null.
pub fn load(arena: Allocator, fs: anytype, paths: []const []const u8, diags: *Diagnostics) !Set {
    const Fs = @typeInfo(@TypeOf(fs)).pointer.child;
    const Thunk = struct {
        fn read(ptr: *anyopaque, a: Allocator, path: []const u8) ?[]const u8 {
            const real: *Fs = @ptrCast(@alignCast(ptr));
            return real.read(a, path);
        }
    };
    var loader: Loader = .{ .arena = arena, .fs = fs, .read = Thunk.read, .diags = diags };
    for (paths) |path| try loader.visit(try joinPath(arena, "", path), null);
    return .{ .docs = loader.docs.items, .blocks = loader.blocks.items };
}

// Tests ----------------------------------------------------------------------

const t = std.testing;

const MemoryFs = struct {
    files: []const [2][]const u8,

    fn read(self: *MemoryFs, _: Allocator, path: []const u8) ?[]const u8 {
        for (self.files) |file| if (std.mem.eql(u8, file[0], path)) return file[1];
        return null;
    }
};

fn expectDiag(diags: Diagnostics, doc: u32, line: u32, needle: []const u8) !void {
    for (diags.list.items) |d| {
        if (d.doc == doc and d.line == line and std.mem.indexOf(u8, d.message, needle) != null) return;
    }
    for (diags.list.items) |d| std.debug.print("  {d}:{d}: {s}\n", .{ d.doc, d.line, d.message });
    return error.MissingDiagnostic;
}

test "L6: includes are followed at their position, depth first, relative to the includer" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fs: MemoryFs = .{ .files = &.{
        .{ "book/main.adoc", "… :file: m1\n----\n----\ninclude::part/one.adoc[]\n… :file: m2\n----\n----\ninclude::two.adoc[]\n" },
        .{ "book/part/one.adoc", "… :file: o1\n----\n----\ninclude::../three.adoc[]\n… :file: o2\n----\n----\n" },
        .{ "book/two.adoc", "… :file: t1\n----\n----\n" },
        .{ "book/three.adoc", "… :file: h1\n----\n----\n" },
        .{ "other.md", "… :file: x1\n```\n```\n" },
    } };
    var diags = Diagnostics.init(a);
    const set = try load(a, &fs, &.{ "book/main.adoc", "./other.md" }, &diags);
    try t.expectEqual(0, diags.list.items.len);
    const want = [_][]const u8{ "m1", "o1", "h1", "o2", "m2", "t1", "x1" };
    try t.expectEqual(want.len, set.blocks.len);
    for (want, set.blocks) |w, block| try t.expectEqualStrings(w, block.label.file);
    const docs = [_][]const u8{ "book/main.adoc", "book/part/one.adoc", "book/three.adoc", "book/two.adoc", "other.md" };
    try t.expectEqual(docs.len, set.docs.len);
    for (docs, set.docs) |w, doc| try t.expectEqualStrings(w, doc.path);
    try t.expectEqual(types.Format.markdown, set.docs[4].format);
    try t.expectEqual(2, set.blocks[2].label.doc);
}

test "C10: a document that includes itself, directly or through others" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fs: MemoryFs = .{ .files = &.{
        .{ "a.adoc", "include::a.adoc[]\n" },
        .{ "b.adoc", "x\ninclude::c.adoc[]\n" },
        .{ "c.adoc", "include::b.adoc[]\n" },
    } };
    var diags = Diagnostics.init(a);
    _ = try load(a, &fs, &.{ "a.adoc", "b.adoc" }, &diags);
    try expectDiag(diags, 0, 1, "includes itself");
    try expectDiag(diags, 2, 1, "includes itself");
    try t.expectEqual(2, diags.list.items.len);
}

test "C10: a document in the set twice" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fs: MemoryFs = .{ .files = &.{
        .{ "a.adoc", "include::sub/b.adoc[]\ninclude::sub/../sub/b.adoc[]\n" },
        .{ "sub/b.adoc", "" },
    } };
    var diags = Diagnostics.init(a);
    _ = try load(a, &fs, &.{ "a.adoc", "sub/b.adoc", "a.adoc" }, &diags);
    try expectDiag(diags, 0, 2, "twice");
    try expectDiag(diags, 1, 0, "twice");
    try expectDiag(diags, 0, 0, "twice");
    try t.expectEqual(3, diags.list.items.len);
}

test "C10: a missing document, and a document of an unknown kind" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fs: MemoryFs = .{ .files = &.{
        .{ "a.adoc", "include::gone.adoc[]\ninclude::notes.txt[]\n" },
        .{ "notes.txt", "" },
    } };
    var diags = Diagnostics.init(a);
    const set = try load(a, &fs, &.{ "a.adoc", "missing.md" }, &diags);
    try expectDiag(diags, 0, 1, "cannot read gone.adoc");
    try expectDiag(diags, 0, 2, "notes.txt is not");
    try expectDiag(diags, 3, 0, "cannot read missing.md");
    try t.expectEqual(4, set.docs.len);
}

test "formatOf and joinPath" {
    try t.expectEqual(types.Format.asciidoc, formatOf("a/b.asciidoc").?);
    try t.expectEqual(types.Format.asciidoc, formatOf("b.asc").?);
    try t.expectEqual(types.Format.markdown, formatOf("b.md").?);
    try t.expect(formatOf("b.txt") == null);
    try t.expect(formatOf("adoc") == null);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqualStrings("a/c.adoc", try joinPath(a, "a/b", "../c.adoc"));
    try t.expectEqualStrings("../x", try joinPath(a, "", "../x"));
    try t.expectEqualStrings("x", try joinPath(a, "", "./x"));
}
