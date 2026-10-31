//! `litmus assemble` (S1 to S4): a document from a template of prose, with each block of a
//! skeleton copied to where the template's placeholder for it is. No IO.

const std = @import("std");
const types = @import("types.zig");
const scan = @import("scan.zig");

const Allocator = std.mem.Allocator;
const Block = types.Block;

/// A problem, at a line of the template, or of the skeleton when `in_skeleton`.
pub const Problem = struct { in_skeleton: bool = false, line: u32, message: []const u8 };

pub const Result = struct {
    /// The text of the output, or empty if there is any problem.
    text: []const u8,
    problems: []const Problem,
    /// How many blocks placeholders placed, and how many `… :rest:` placed.
    placed: u32 = 0,
    rest: u32 = 0,
};

/// The blocks of the skeleton with one name and file, and whether a placeholder used them.
const Entry = struct {
    file: []const u8,
    name: ?[]const u8,
    blocks: std.ArrayList(*const Block) = .empty,
    used: bool = false,
};

/// The lines of a block in its document, from its label to its closing delimiter.
fn span(docs: []const types.Document, block: *const Block) []const []const u8 {
    const lines = docs[block.label.doc].lines;
    const close = block.first_line - 1 + block.lines.len;
    return lines[block.label.line - 1 .. close + 1];
}

/// The name and path of a placeholder's command text, or null without `:file:`.
fn placeholder(text: []const u8) ?struct { name: ?[]const u8, path: []const u8 } {
    var rest: []const u8 = undefined;
    var name: ?[]const u8 = null;
    if (std.mem.startsWith(u8, text, ":file: ")) {
        rest = text[":file: ".len..];
    } else if (std.mem.indexOf(u8, text, " :file: ")) |at| {
        name = std.mem.trim(u8, text[0..at], " \t");
        rest = text[at + " :file: ".len ..];
    } else return null;
    rest = std.mem.trim(u8, rest, " \t\r");
    if (std.mem.endsWith(u8, rest, ":executable:")) rest = std.mem.trimEnd(u8, rest[0 .. rest.len - ":executable:".len], " \t");
    return .{ .name = name, .path = rest };
}

fn sameName(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// The header entries of the skeleton that S4 carries over: `:litmus-style:` and
/// `:litmus-companion:` lines before its first document command.
fn headerEntries(arena: Allocator, lines: []const []const u8) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    for (lines) |line| {
        if (scan.commandOf(line) != null) break;
        if (std.mem.startsWith(u8, line, ":litmus-style:") or std.mem.startsWith(u8, line, ":litmus-companion:")) try result.append(arena, line);
    }
    return result.items;
}

/// S1 to S4: the output for the skeleton's set (its documents and blocks) and the template.
pub fn assemble(arena: Allocator, docs: []const types.Document, blocks: []const Block, template: []const []const u8) !Result {
    var problems: std.ArrayList(Problem) = .empty;

    // The skeleton's blocks, by file and name, in the order they first appear.
    var entries: std.ArrayList(Entry) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    for (blocks) |*block| {
        const entry = for (entries.items) |*e| {
            if (std.mem.eql(u8, e.file, block.label.file) and sameName(e.name, block.label.name)) break e;
        } else blk: {
            try entries.append(arena, .{ .file = block.label.file, .name = block.label.name });
            break :blk &entries.items[entries.items.len - 1];
        };
        try entry.blocks.append(arena, block);
        for (files.items) |f| {
            if (std.mem.eql(u8, f, block.label.file)) break;
        } else try files.append(arena, block.label.file);
    }

    // S1: the template, line by line, with each placeholder replaced. `rest_at` is where the
    // rest goes, as an index into `out`.
    var out: std.ArrayList([]const u8) = .empty;
    var rest_at: ?usize = null;
    var placed: u32 = 0;
    var scanner = scan.Scanner.init(.asciidoc);
    for (template, 1..) |line, n| {
        const line_no: u32 = @intCast(n);
        if (scanner.next(line) != .command) {
            try out.append(arena, line);
            continue;
        }
        const text = std.mem.trim(u8, scan.commandOf(line).?.text, " \t\r");
        if (std.mem.eql(u8, text, ":rest:")) {
            if (rest_at != null) {
                try problems.append(arena, .{ .line = line_no, .message = "S3: a second … :rest:" });
            } else rest_at = out.items.len;
            continue;
        }
        // A label that a block follows is the template's own, and stays as it is.
        var look = scanner;
        var follows: scan.Kind = .prose;
        for (template[n..]) |next_line| {
            follows = look.next(next_line);
            if (follows != .attribute and follows != .title) break;
        }
        if (follows == .open) {
            try out.append(arena, line);
            continue;
        }

        const p = placeholder(text) orelse {
            try problems.append(arena, .{ .line = line_no, .message = try std.fmt.allocPrint(arena, "S3: a placeholder needs :file:, as in … NAME :file: PATH: {s}", .{text}) });
            continue;
        };
        // The path, or the end of exactly one file's path.
        var file: ?[]const u8 = null;
        var matches: u32 = 0;
        for (files.items) |f| {
            if (std.mem.eql(u8, f, p.path)) {
                file = f;
                matches = 1;
                break;
            }
            if (f.len > p.path.len and std.mem.endsWith(u8, f, p.path) and f[f.len - p.path.len - 1] == '/') {
                file = f;
                matches += 1;
            }
        }
        if (matches == 0) {
            try problems.append(arena, .{ .line = line_no, .message = try std.fmt.allocPrint(arena, "S3: no file of the skeleton is or ends with {s}", .{p.path}) });
            continue;
        }
        if (matches > 1) {
            try problems.append(arena, .{ .line = line_no, .message = try std.fmt.allocPrint(arena, "S3: more than one file of the skeleton ends with {s}; write more of its path", .{p.path}) });
            continue;
        }
        const entry = for (entries.items) |*e| {
            if (std.mem.eql(u8, e.file, file.?) and sameName(e.name, p.name)) break e;
        } else {
            try problems.append(arena, .{ .line = line_no, .message = try std.fmt.allocPrint(arena, "S3: the skeleton has no block {s} of {s}", .{ p.name orelse "(file root)", file.? }) });
            continue;
        };
        if (entry.used) {
            try problems.append(arena, .{ .line = line_no, .message = try std.fmt.allocPrint(arena, "S3: the block {s} of {s} is placed twice", .{ p.name orelse "(file root)", file.? }) });
            continue;
        }
        entry.used = true;
        for (entry.blocks.items, 0..) |block, i| {
            if (i > 0) try out.append(arena, "");
            try out.appendSlice(arena, span(docs, block));
        }
        placed += @intCast(entry.blocks.items.len);
    }

    // S2: the blocks no placeholder placed, file by file, each file in a collapsible block.
    var rest: std.ArrayList([]const u8) = .empty;
    var rest_count: u32 = 0;
    for (files.items) |f| {
        var count: u32 = 0;
        for (entries.items) |e| if (!e.used and std.mem.eql(u8, e.file, f)) {
            count += @intCast(e.blocks.items.len);
        };
        if (count == 0) continue;
        if (rest_at == null) {
            for (entries.items) |e| if (!e.used and std.mem.eql(u8, e.file, f)) {
                try problems.append(arena, .{ .in_skeleton = true, .line = e.blocks.items[0].label.line, .message = try std.fmt.allocPrint(arena, "S3: the block {s} of {s} is not placed, and the template has no … :rest:", .{ e.name orelse "(file root)", f }) });
            };
            continue;
        }
        try rest.appendSlice(arena, &.{
            try std.fmt.allocPrint(arena, "=== {s}", .{f}),
            "",
            try std.fmt.allocPrint(arena, ".The rest of the code ({d} {s})", .{ count, if (count == 1) "block" else "blocks" }),
            "[%collapsible]",
            "====",
        });
        var first = true;
        for (entries.items) |e| if (!e.used and std.mem.eql(u8, e.file, f)) {
            for (e.blocks.items) |block| {
                if (!first) try rest.append(arena, "");
                first = false;
                try rest.appendSlice(arena, span(docs, block));
            }
        };
        try rest.appendSlice(arena, &.{ "====", "" });
        rest_count += count;
    }
    if (problems.items.len > 0) return .{ .text = "", .problems = problems.items };
    if (rest_at) |at| {
        // A blank line after the rest would double the one the template has.
        if (rest.items.len > 0) rest.items.len -= 1;
        try out.insertSlice(arena, at, rest.items);
    }

    // S4: the skeleton's header entries, after the title, unless the template has its own.
    const own = try headerEntries(arena, template);
    if (own.len == 0 and docs.len > 0) {
        const entries_of_skeleton = try headerEntries(arena, docs[0].lines);
        const at: usize = if (out.items.len > 0 and std.mem.startsWith(u8, out.items[0], "= ")) 1 else 0;
        try out.insertSlice(arena, at, entries_of_skeleton);
    }

    var text: std.ArrayList(u8) = .empty;
    for (out.items) |line| {
        try text.appendSlice(arena, line);
        try text.append(arena, '\n');
    }
    return .{ .text = text.items, .problems = &.{}, .placed = placed, .rest = rest_count };
}

// Tests ----------------------------------------------------------------------

const t = std.testing;
const parse = @import("parse.zig");

const skeleton_text =
    \\= Skeleton
    \\:litmus-companion:
    \\
    \\… :file: src/a/one.zig
    \\[source,zig]
    \\----
    \\… first
    \\
    \\… second
    \\----
    \\
    \\… first :file: src/a/one.zig
    \\[source,zig]
    \\----
    \\const first = 1;
    \\----
    \\
    \\… second :file: src/a/one.zig
    \\[source,zig,litmus-changed="1"]
    \\.A title
    \\----
    \\const second = 2;
    \\----
    \\
    \\… :file: src/b/one.zig
    \\[source,zig]
    \\----
    \\const other = 3;
    \\----
    \\
;

fn run(a: Allocator, template: []const u8) !Result {
    var diags = types.Diagnostics.init(a);
    const doc: types.Document = .{ .path = "s.adoc", .format = .asciidoc, .lines = try scan.splitLines(a, skeleton_text), .dir = "" };
    const parsed = try parse.parse(a, 0, doc, &diags);
    try t.expectEqual(0, diags.list.items.len);
    return assemble(a, &.{doc}, parsed.blocks, try scan.splitLines(a, template));
}

test "S1, S2, S4: placeholders, a shortened path, the rest, and the header" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const result = try run(arena_state.allocator(),
        \\= Review
        \\
        \\The second, which changed:
        \\
        \\… second :file: a/one.zig
        \\
        \\And the root:
        \\
        \\… :file: src/a/one.zig
        \\
        \\== The rest
        \\
        \\… :rest:
        \\
    );
    try t.expectEqual(0, result.problems.len);
    try t.expectEqual(2, result.placed);
    try t.expectEqual(2, result.rest);
    try t.expectEqualStrings(
        \\= Review
        \\:litmus-companion:
        \\
        \\The second, which changed:
        \\
        \\… second :file: src/a/one.zig
        \\[source,zig,litmus-changed="1"]
        \\.A title
        \\----
        \\const second = 2;
        \\----
        \\
        \\And the root:
        \\
        \\… :file: src/a/one.zig
        \\[source,zig]
        \\----
        \\… first
        \\
        \\… second
        \\----
        \\
        \\== The rest
        \\
        \\=== src/a/one.zig
        \\
        \\.The rest of the code (1 block)
        \\[%collapsible]
        \\====
        \\… first :file: src/a/one.zig
        \\[source,zig]
        \\----
        \\const first = 1;
        \\----
        \\====
        \\
        \\=== src/b/one.zig
        \\
        \\.The rest of the code (1 block)
        \\[%collapsible]
        \\====
        \\… :file: src/b/one.zig
        \\[source,zig]
        \\----
        \\const other = 3;
        \\----
        \\====
        \\
    , result.text);
}

test "S3: an ambiguous path, an unknown block, a block placed twice, a block left over" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const result = try run(arena_state.allocator(),
        \\= Review
        \\
        \\… :file: one.zig
        \\
        \\… third :file: a/one.zig
        \\
        \\… first :file: a/one.zig
        \\
        \\… first :file: a/one.zig
        \\
        \\… nothing here
        \\
    );
    try t.expectEqual(0, result.text.len);
    const want = [_][]const u8{
        "S3: more than one file of the skeleton ends with one.zig; write more of its path",
        "S3: the skeleton has no block third of src/a/one.zig",
        "S3: the block first of src/a/one.zig is placed twice",
        "S3: a placeholder needs :file:, as in … NAME :file: PATH: nothing here",
        "S3: the block (file root) of src/a/one.zig is not placed, and the template has no … :rest:",
        "S3: the block second of src/a/one.zig is not placed, and the template has no … :rest:",
        "S3: the block (file root) of src/b/one.zig is not placed, and the template has no … :rest:",
    };
    try t.expectEqual(want.len, result.problems.len);
    for (want, result.problems) |w, p| try t.expectEqualStrings(w, p.message);
    try t.expectEqual(true, result.problems[4].in_skeleton);
    try t.expectEqual(4, result.problems[4].line);
}

test "S1: a label with a block is the template's own" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const result = try run(arena_state.allocator(),
        \\… :rest:
        \\
        \\… extra :file: src/a/one.zig
        \\[source,zig]
        \\----
        \\shown as it is
        \\----
        \\
    );
    try t.expectEqual(0, result.problems.len);
    try t.expectEqual(0, result.placed);
    try t.expect(std.mem.indexOf(u8, result.text, "shown as it is") != null);
}
