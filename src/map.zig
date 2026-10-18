//! The map: `.litmus/map` says where every line of every tangled file came from,
//! and records what tangle last wrote (T6). It is text, with tabs between fields.

const std = @import("std");
const types = @import("types.zig");
const tangle = @import("tangle.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const header = "litmus map 1";

/// The SHA-256 of a file's text, in lowercase hexadecimal.
pub fn hashHex(text: []const u8) [Sha256.digest_length * 2]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(text, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// The text of the map for tangled files whose runs refer to `docs`.
pub fn render(arena: Allocator, docs: []const types.Document, files: []const tangle.Tangled) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, header ++ "\n");
    for (files) |file| {
        try out.print(arena, "file\t{s}\t{s}\n", .{ file.path, &hashHex(file.text) });
        for (file.runs) |run| {
            try out.print(arena, "{d}\t{d}\t{s}\t{d}\t{d}\t{s}\n", .{ run.line, run.count, docs[run.doc].path, run.doc_line, run.indent, run.excerpt });
        }
    }
    return out.items;
}

pub const MapRun = struct {
    line: u32,
    count: u32,
    doc: []const u8,
    doc_line: u32,
    indent: u32,
    excerpt: []const u8,
};

pub const MapFile = struct {
    path: []const u8,
    hash: []const u8,
    runs: []const MapRun,
};

pub const Map = struct {
    files: []const MapFile,

    pub fn find(self: Map, path: []const u8) ?MapFile {
        for (self.files) |file| if (std.mem.eql(u8, file.path, path)) return file;
        return null;
    }
};

pub const ReadError = error{ UnsupportedMap, BadMap } || Allocator.Error;

/// Reads a map. Anything but the first version is rejected.
pub fn read(arena: Allocator, text: []const u8) ReadError!Map {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return error.BadMap;
    if (!std.mem.eql(u8, first, header)) return error.UnsupportedMap;

    var files: std.ArrayList(MapFile) = .empty;
    var runs: std.ArrayList(MapRun) = .empty;
    var current: ?MapFile = null;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const head = fields.next().?;
        if (std.mem.eql(u8, head, "file")) {
            if (current) |*file| {
                file.runs = try runs.toOwnedSlice(arena);
                try files.append(arena, file.*);
            }
            const path = fields.next() orelse return error.BadMap;
            const hash = fields.next() orelse return error.BadMap;
            if (hash.len != Sha256.digest_length * 2 or fields.next() != null) return error.BadMap;
            current = .{ .path = path, .hash = hash, .runs = &.{} };
            continue;
        }
        if (current == null) return error.BadMap;
        const count = fields.next() orelse return error.BadMap;
        const doc = fields.next() orelse return error.BadMap;
        const doc_line = fields.next() orelse return error.BadMap;
        const indent = fields.next() orelse return error.BadMap;
        const excerpt = fields.rest();
        try runs.append(arena, .{
            .line = std.fmt.parseInt(u32, head, 10) catch return error.BadMap,
            .count = std.fmt.parseInt(u32, count, 10) catch return error.BadMap,
            .doc = doc,
            .doc_line = std.fmt.parseInt(u32, doc_line, 10) catch return error.BadMap,
            .indent = std.fmt.parseInt(u32, indent, 10) catch return error.BadMap,
            .excerpt = excerpt,
        });
    }
    if (current) |*file| {
        file.runs = try runs.toOwnedSlice(arena);
        try files.append(arena, file.*);
    }
    return .{ .files = files.items };
}

/// The run holding `line` of a file, among runs in order; null if none does.
pub fn findRun(runs: anytype, line: u32) ?usize {
    var lo: usize = 0;
    var hi: usize = runs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const run = runs[mid];
        if (line < run.line) {
            hi = mid;
        } else if (line >= run.line + run.count) {
            lo = mid + 1;
        } else return mid;
    }
    return null;
}

// Tests ----------------------------------------------------------------------

const t = std.testing;

test "M: the map of the spec's example, and the hash of its file" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text =
        \\const std = @import("std");
        \\
        \\pub fn main() void {
        \\    std.debug.print("Hello, Litmus!\n", .{});
        \\}
        \\
    ;
    try t.expectEqualStrings("2bc975ea988a6520d4c5937fbec6d64a98ce153bb2dc852c50affe981da286c2", &hashHex(text));
    const docs = [_]types.Document{.{ .path = "hello.adoc", .format = .asciidoc, .lines = &.{}, .dir = "" }};
    const runs = [_]types.Run{
        .{ .line = 1, .count = 1, .doc = 0, .doc_line = 24, .indent = 0, .excerpt = "imports" },
        .{ .line = 2, .count = 2, .doc = 0, .doc_line = 7, .indent = 0, .excerpt = ":file:" },
        .{ .line = 4, .count = 1, .doc = 0, .doc_line = 18, .indent = 4, .excerpt = "greet" },
        .{ .line = 5, .count = 1, .doc = 0, .doc_line = 10, .indent = 0, .excerpt = ":file:" },
    };
    const rendered = try render(a, &docs, &.{.{ .path = "hello.zig", .executable = false, .text = text, .runs = &runs, .expansions = &.{} }});
    try t.expectEqualStrings(
        "litmus map 1\n" ++
            "file\thello.zig\t2bc975ea988a6520d4c5937fbec6d64a98ce153bb2dc852c50affe981da286c2\n" ++
            "1\t1\thello.adoc\t24\t0\timports\n" ++
            "2\t2\thello.adoc\t7\t0\t:file:\n" ++
            "4\t1\thello.adoc\t18\t4\tgreet\n" ++
            "5\t1\thello.adoc\t10\t0\t:file:\n",
        rendered,
    );
    const map = try read(a, rendered);
    try t.expectEqual(1, map.files.len);
    const file = map.find("hello.zig").?;
    try t.expectEqual(4, file.runs.len);
    try t.expectEqualStrings("greet", file.runs[2].excerpt);
    try t.expectEqual(4, file.runs[2].indent);
    try t.expect(map.find("other") == null);
}

test "M: reading rejects other versions and broken lines" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectError(error.UnsupportedMap, read(a, "litmus map 2\n"));
    try t.expectError(error.UnsupportedMap, read(a, ""));
    try t.expectError(error.BadMap, read(a, "litmus map 1\n1\t1\td\t1\t0\tx\n"));
    try t.expectError(error.BadMap, read(a, "litmus map 1\nfile\tp\tabc\n"));
    try t.expectError(error.BadMap, read(a, "litmus map 1\nfile\tp\t0000000000000000000000000000000000000000000000000000000000000000\nx\t1\td\t1\t0\tx\n"));
    try t.expectEqual(0, (try read(a, "litmus map 1\n")).files.len);
}

test "findRun finds the run that holds a line" {
    const runs = [_]types.Run{
        .{ .line = 1, .count = 1, .doc = 0, .doc_line = 24, .indent = 0, .excerpt = "a" },
        .{ .line = 2, .count = 3, .doc = 0, .doc_line = 7, .indent = 0, .excerpt = "b" },
        .{ .line = 6, .count = 1, .doc = 0, .doc_line = 18, .indent = 4, .excerpt = "c" },
    };
    try t.expectEqual(0, findRun(&runs, 1).?);
    try t.expectEqual(1, findRun(&runs, 2).?);
    try t.expectEqual(1, findRun(&runs, 4).?);
    try t.expectEqual(2, findRun(&runs, 6).?);
    try t.expect(findRun(&runs, 5) == null);
    try t.expect(findRun(&runs, 7) == null);
    try t.expect(findRun(&runs, 0) == null);
}
