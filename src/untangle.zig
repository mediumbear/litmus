//! Untangle (U1 to U9): carries changes made in tangled files back into the document
//! blocks they came from. This file plans the edits, applies them, and checks the
//! result. No IO.

const std = @import("std");
const types = @import("types.zig");
const scan = @import("scan.zig");
const diff = @import("diff.zig");
const map = @import("map.zig");
const tangle = @import("tangle.zig");
const resolve_mod = @import("resolve.zig");

const Allocator = std.mem.Allocator;
const Block = types.Block;
const Document = types.Document;

/// An edit of one line of a document. Lines are counted before any edit is made.
pub const Edit = struct {
    doc: u32,
    line: u32,
    kind: enum { replace, delete, insert },
    /// The new text of the line, or for an insert the text that goes before `line`.
    text: []const u8 = "",
};

/// A line that untangle could not place (U5): its file, its line in that file, and why.
pub const Problem = struct {
    file: []const u8,
    line: u32,
    message: []const u8,
};

/// A line added where it could have gone in more than one place (U4).
pub const Placement = struct {
    file: []const u8,
    /// The first added line, counting from 1 in the changed file.
    line: u32,
    doc: u32,
    /// The excerpt command it is next to, or the edge of the block.
    doc_line: u32,
    kind: enum { after_command, before_command, block_start, block_end },
    /// The excerpt the command stands for. Empty at the edge of a block.
    name: []const u8 = "",
};

/// A block that got new lines (U6).
pub const Growth = struct { block: *const Block, added: u32 };

pub const Plan = struct {
    arena: Allocator,
    docs: []const Document,
    edits: std.ArrayList(Edit) = .empty,
    problems: std.ArrayList(Problem) = .empty,
    placements: std.ArrayList(Placement) = .empty,
    growth: std.ArrayList(Growth) = .empty,
    growth_index: std.AutoHashMapUnmanaged(*const Block, usize) = .empty,
    changed: u32 = 0,
    removed: u32 = 0,
    added: u32 = 0,

    pub fn init(arena: Allocator, docs: []const Document) Plan {
        return .{ .arena = arena, .docs = docs };
    }

    fn docPath(self: *const Plan, doc: u32) []const u8 {
        return self.docs[doc].path;
    }

    fn problem(self: *Plan, file: []const u8, line: u32, comptime fmt: []const u8, args: anytype) !void {
        try self.problems.append(self.arena, .{ .file = file, .line = line, .message = try std.fmt.allocPrint(self.arena, fmt, args) });
    }

    fn grew(self: *Plan, block: *const Block, lines: u32) !void {
        const slot = try self.growth_index.getOrPut(self.arena, block);
        if (!slot.found_existing) {
            slot.value_ptr.* = self.growth.items.len;
            try self.growth.append(self.arena, .{ .block = block, .added = 0 });
        }
        self.growth.items[slot.value_ptr.*].added += lines;
        self.added += lines;
    }
};

/// Where a line of a tangled file came from.
const Origin = struct {
    run: types.Run,
    doc_line: u32,
    /// What the excerpt commands around it put in front of the line (T2).
    prefix: []const u8,
};

fn prefixOf(file: tangle.Tangled, run: types.Run) []const u8 {
    if (run.expansion == types.no_expansion) return "";
    return file.expansions[run.expansion].prefix;
}

fn originOf(file: tangle.Tangled, line: u32) ?Origin {
    const at = map.findRun(file.runs, line) orelse return null;
    const run = file.runs[at];
    return .{ .run = run, .doc_line = run.doc_line + (line - run.line), .prefix = prefixOf(file, run) };
}

/// Plans the edits that carry the changes in `disk` into the documents, for one tangled
/// file. `file` is the base (U1), and the file on disk is compared with it (U2).
pub fn planFile(plan: *Plan, file: tangle.Tangled, disk: []const u8) !void {
    const arena = plan.arena;
    const base = try scan.splitLines(arena, file.text);
    const now = try scan.splitLines(arena, disk);
    if (disk.len > 0 and disk[disk.len - 1] != '\n') {
        try plan.problem(file.path, @intCast(now.len), "T3: the file does not end with a newline", .{});
    }
    const hunks = try diff.diff(arena, base, now);
    for (hunks) |h| {
        const pairs = @min(h.a_end - h.a, h.b_end - h.b);
        var i: u32 = 0;
        while (i < pairs) : (i += 1) try changeLine(plan, file, h.a + i + 1, now[h.b + i], h.b + i + 1);
        while (h.a + i < h.a_end) : (i += 1) try removeLine(plan, file, h.a + i + 1);
        if (h.b + pairs < h.b_end) {
            try addLines(plan, file, h.a_end, @intCast(base.len), now[h.b + pairs .. h.b_end], h.b + pairs + 1);
        }
    }
}

/// U3: a changed line is changed at the document line it came from.
fn changeLine(plan: *Plan, file: tangle.Tangled, n: u32, text: []const u8, new_n: u32) !void {
    const origin = originOf(file, n) orelse return;
    var stripped: []const u8 = "";
    if (text.len > 0) {
        if (text.len <= origin.prefix.len or !std.mem.startsWith(u8, text, origin.prefix)) {
            return plan.problem(file.path, new_n, "U5: the line is not the indent of its excerpt \"{s}\" followed by text, from {s}:{d}", .{
                origin.run.excerpt, plan.docPath(origin.run.doc), origin.doc_line,
            });
        }
        stripped = text[origin.prefix.len..];
    }
    try plan.edits.append(plan.arena, .{ .doc = origin.run.doc, .line = origin.doc_line, .kind = .replace, .text = stripped });
    plan.changed += 1;
}

/// U3: a removed line is removed at the document line it came from.
fn removeLine(plan: *Plan, file: tangle.Tangled, n: u32) !void {
    const origin = originOf(file, n) orelse return;
    try plan.edits.append(plan.arena, .{ .doc = origin.run.doc, .line = origin.doc_line, .kind = .delete });
    plan.removed += 1;
}

/// Whether every line can be a line of a block whose excerpt puts `prefix` in front of its
/// lines: empty, or the prefix and then something. A line that is only the prefix cannot
/// come from any line of a document, since empty lines stay empty (T2).
fn startWithAll(lines: []const []const u8, prefix: []const u8) bool {
    for (lines) |line| {
        if (line.len == 0) continue;
        if (line.len <= prefix.len or !std.mem.startsWith(u8, line, prefix)) return false;
    }
    return true;
}

fn allEmpty(lines: []const []const u8) bool {
    for (lines) |line| if (line.len > 0) return false;
    return true;
}

const Candidate = struct { exp: u32, after: bool };

/// Innermost first. Where two are equally deep, the one before the gap comes first.
fn innerFirst(expansions: []const types.Expansion, a: Candidate, b: Candidate) bool {
    const x = expansions[a.exp];
    const y = expansions[b.exp];
    if (x.depth != y.depth) return x.depth > y.depth;
    if (a.after != b.after) return a.after;
    return a.exp < b.exp;
}

/// U4: lines added after `k` lines of the base, where the base has `total` lines.
fn addLines(plan: *Plan, file: tangle.Tangled, k: u32, total: u32, lines: []const []const u8, first_n: u32) !void {
    // Between two lines of one run: into that block, at that place.
    if (k > 0 and k < total) {
        const before = map.findRun(file.runs, k);
        const after = map.findRun(file.runs, k + 1);
        if (before != null and before == after) {
            const run = file.runs[before.?];
            return insertLines(plan, file, lines, run.block.?, run.doc, run.doc_line + (k + 1 - run.line), prefixOf(file, run), first_n, null);
        }
    }

    // Where an excerpt ends or begins: next to the excerpt command.
    var candidates: std.ArrayList(Candidate) = .empty;
    for (file.expansions, 0..) |e, i| {
        if (e.last_line == k) try candidates.append(plan.arena, .{ .exp = @intCast(i), .after = true });
        if (e.first_line == k + 1) try candidates.append(plan.arena, .{ .exp = @intCast(i), .after = false });
    }
    if (candidates.items.len > 0) {
        std.mem.sort(Candidate, candidates.items, file.expansions, innerFirst);
        const outermost_first = allEmpty(lines);
        for (0..candidates.items.len) |n| {
            const c = candidates.items[if (outermost_first) candidates.items.len - 1 - n else n];
            const e = file.expansions[c.exp];
            const required = e.prefix[0..e.outer_len];
            if (!startWithAll(lines, required)) continue;
            const command_line = e.block.first_line + e.block.commands[e.command].index;
            return insertLines(plan, file, lines, e.block, e.block.label.doc, if (c.after) command_line + 1 else command_line, required, first_n, .{
                .file = file.path,
                .line = first_n,
                .doc = e.block.label.doc,
                .doc_line = command_line,
                .kind = if (c.after) .after_command else .before_command,
                .name = e.block.commands[e.command].name,
            });
        }
        const e = file.expansions[candidates.items[0].exp];
        const command_line = e.block.first_line + e.block.commands[e.command].index;
        return plan.problem(file.path, first_n, "U5: the line is not the indent of the block around \"{s}\" followed by text, at {s}:{d}", .{
            e.block.commands[e.command].name, plan.docPath(e.block.label.doc), command_line,
        });
    }

    // At the start or end of a file, or between two blocks of one excerpt: into the
    // block that follows, or the block that comes before.
    if (total == 0) {
        return plan.problem(file.path, first_n, "U4: the file has no lines, so there is no block to add to", .{});
    }
    const leaf: u32 = if (k == 0) 1 else k;
    const origin = originOf(file, leaf).?;
    const block = origin.run.block.?;
    const at_start = k == 0;
    const anchor = if (at_start) block.first_line else block.first_line + @as(u32, @intCast(block.lines.len));
    return insertLines(plan, file, lines, block, origin.run.doc, anchor, origin.prefix, first_n, .{
        .file = file.path,
        .line = first_n,
        .doc = origin.run.doc,
        .doc_line = anchor,
        .kind = if (at_start) .block_start else .block_end,
    });
}

/// Puts `lines` before the line `anchor` of a document, in the block `block`, after
/// taking `required` off their front (U5).
fn insertLines(plan: *Plan, file: tangle.Tangled, lines: []const []const u8, block: *const Block, doc: u32, anchor: u32, required: []const u8, first_n: u32, placement: ?Placement) !void {
    if (!startWithAll(lines, required)) {
        return plan.problem(file.path, first_n, "U5: the line is not the indent of its excerpt followed by text, from {s}:{d}", .{ plan.docPath(doc), anchor });
    }
    for (lines) |line| {
        const text = if (line.len == 0) line else line[required.len..];
        try plan.edits.append(plan.arena, .{ .doc = doc, .line = anchor, .kind = .insert, .text = text });
    }
    try plan.grew(block, @intCast(lines.len));
    if (placement) |p| try plan.placements.append(plan.arena, p);
}

/// Applies the edits to the documents, in one pass over each document's lines: for every
/// original line, what is inserted before it, then the line itself (replaced, deleted,
/// or kept). Edits name original line numbers, so they never disturb each other.
pub fn applyEdits(arena: Allocator, docs: []const Document, edits: []const Edit) ![]const Document {
    const sorted = try arena.dupe(Edit, edits);
    const Order = struct {
        fn less(_: void, a: Edit, b: Edit) bool {
            if (a.doc != b.doc) return a.doc < b.doc;
            return a.line < b.line;
        }
    };
    // The sort is stable, so lines inserted at one place keep their order.
    std.mem.sort(Edit, sorted, {}, Order.less);

    const result = try arena.dupe(Document, docs);
    var at: usize = 0;
    for (result, 0..) |*doc, index| {
        const first = at;
        while (at < sorted.len and sorted[at].doc == index) at += 1;
        const mine = sorted[first..at];
        if (mine.len == 0) continue;

        var lines: std.ArrayList([]const u8) = .empty;
        var next: usize = 0;
        for (doc.lines, 0..) |line, n| {
            const number: u32 = @intCast(n + 1);
            while (next < mine.len and mine[next].line == number and mine[next].kind == .insert) : (next += 1) {
                try lines.append(arena, mine[next].text);
            }
            if (next < mine.len and mine[next].line == number) {
                if (mine[next].kind == .replace) try lines.append(arena, mine[next].text);
                next += 1;
            } else {
                try lines.append(arena, line);
            }
        }
        doc.lines = lines.items;
    }
    return result;
}

/// The text of a document, as it is written to disk.
pub fn render(arena: Allocator, doc: Document) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (doc.lines, 0..) |line, n| {
        try out.appendSlice(arena, line);
        if (n + 1 < doc.lines.len or doc.final_newline) try out.append(arena, '\n');
    }
    return out.items;
}

/// A tangled file's path and the text it has on disk.
pub const FileText = struct { path: []const u8, text: []const u8 };

const MemoryFs = struct {
    docs: []const Document,
    texts: []const []const u8,

    pub fn read(self: *MemoryFs, _: Allocator, path: []const u8) ?[]const u8 {
        for (self.docs, self.texts) |doc, text| if (std.mem.eql(u8, doc.path, path)) return text;
        return null;
    }
};

/// U9: tangles the edited documents in memory, and compares the result with the files on
/// disk. Returns null if every file is equal, and otherwise a message for the first
/// that is not. `roots` are the documents named on the command line.
pub fn verify(arena: Allocator, docs: []const Document, roots: []const []const u8, files: []const FileText) !?[]const u8 {
    const texts = try arena.alloc([]const u8, docs.len);
    for (docs, texts) |doc, *text| text.* = try render(arena, doc);
    var fs: MemoryFs = .{ .docs = docs, .texts = texts };
    var diags = types.Diagnostics.init(arena);
    const set = try @import("docset.zig").load(arena, &fs, roots, &diags);
    if (diags.list.items.len == 0) {
        const resolved = try resolve_mod.resolve(arena, set.docs, set.blocks, &diags);
        if (diags.list.items.len == 0) {
            const tangled = try tangle.tangleAll(arena, resolved);
            for (files) |want| {
                const got = for (tangled) |file| {
                    if (std.mem.eql(u8, file.path, want.path)) break file.text;
                } else return try std.fmt.allocPrint(arena, "{s}: the edited documents no longer tangle to this file", .{want.path});
                if (std.mem.eql(u8, got, want.text)) continue;
                const at = std.mem.indexOfDiff(u8, got, want.text).?;
                const line = std.mem.countScalar(u8, want.text[0..at], '\n') + 1;
                return try std.fmt.allocPrint(arena, "{s}:{d}: the edited documents tangle to something else here", .{ want.path, line });
            }
            return null;
        }
    }
    diags.sort();
    const first = diags.list.items[0];
    return try std.fmt.allocPrint(arena, "the edited documents have errors: {s}:{d}: {s}", .{ set.docs[first.doc].path, first.line, first.message });
}

// Tests ----------------------------------------------------------------------

const t = std.testing;
const parse = @import("parse.zig");
const resolve = @import("resolve.zig");

const Fixture = struct {
    docs: []const Document,
    files: []const tangle.Tangled,
};

fn fixture(a: Allocator, text: []const u8) !Fixture {
    var diags = types.Diagnostics.init(a);
    const doc: Document = .{ .path = "d.adoc", .format = .asciidoc, .lines = try scan.splitLines(a, text), .dir = "" };
    const parsed = try parse.parse(a, 0, doc, &diags);
    const docs = try a.dupe(Document, &.{doc});
    const resolved = try resolve.resolve(a, docs, parsed.blocks, &diags);
    for (diags.list.items) |d| std.debug.print("{d}: {s}\n", .{ d.line, d.message });
    try t.expectEqual(0, diags.list.items.len);
    return .{ .docs = docs, .files = try tangle.tangleAll(a, resolved) };
}

fn expectEdit(plan: Plan, i: usize, kind: @TypeOf(@as(Edit, undefined).kind), line: u32, text: []const u8) !void {
    try t.expect(i < plan.edits.items.len);
    const e = plan.edits.items[i];
    try t.expectEqual(kind, e.kind);
    try t.expectEqual(line, e.line);
    try t.expectEqualStrings(text, e.text);
}

fn planOf(a: Allocator, fx: Fixture, disk: []const u8) !Plan {
    var plan = Plan.init(a, fx.docs);
    try planFile(&plan, fx.files[0], disk);
    return plan;
}

// The document of the examples. It tangles to
//   1 top        (root, document line 3)
//   2   one      (excerpt e, line 10)
//   3   two      (e, line 11)
//   4   deep     (excerpt f, inside e, line 17)
//   5 end        (root, line 5)
const example =
    \\… :file: f.txt
    \\----
    \\top
    \\  … e
    \\end
    \\----
    \\
    \\… e :file: f.txt
    \\----
    \\one
    \\two
    \\… f
    \\----
    \\
    \\… f :file: f.txt
    \\----
    \\deep
    \\----
    \\
;

test "U3: a changed line is changed at the document line it came from" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fx = try fixture(a, example);
    try t.expectEqualStrings("top\n  one\n  two\n  deep\nend\n", fx.files[0].text);
    const plan = try planOf(a, fx, "TOP\n  one\n  two\n  DEEP\nend\n");
    try t.expectEqual(2, plan.edits.items.len);
    try expectEdit(plan, 0, .replace, 3, "TOP");
    try expectEdit(plan, 1, .replace, 17, "DEEP");
    try t.expectEqual(2, plan.changed);
    try t.expectEqual(0, plan.problems.items.len);
    try t.expectEqual(0, plan.growth.items.len);
}

test "U3: a removed line is removed at the document line it came from" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fx = try fixture(a, example);
    const plan = try planOf(a, fx, "top\n  one\n  deep\nend\n");
    try t.expectEqual(1, plan.edits.items.len);
    try expectEdit(plan, 0, .delete, 11, "");
    try t.expectEqual(1, plan.removed);
}

test "U1, U2: a file equal to its base needs no edits" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fx = try fixture(a, example);
    const plan = try planOf(a, fx, fx.files[0].text);
    try t.expectEqual(0, plan.edits.items.len);
}

test "U4: a line added between two lines of a run goes into that block" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fx = try fixture(a, example);
    const plan = try planOf(a, fx, "top\n  one\n  new\n  two\n  deep\nend\n");
    try t.expectEqual(1, plan.edits.items.len);
    try expectEdit(plan, 0, .insert, 11, "new");
    try t.expectEqual(0, plan.placements.items.len);
    // U6: the block grew.
    try t.expectEqual(1, plan.growth.items.len);
    try t.expectEqual(1, plan.growth.items[0].added);
    try t.expectEqual(8, plan.growth.items[0].block.label.line);
}

test "U4: a line added where an excerpt begins goes before its command" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fx = try fixture(a, example);
    const plan = try planOf(a, fx, "top\n  one\n  two\n  x\n  deep\nend\n");
    try expectEdit(plan, 0, .insert, 12, "x");
    try t.expectEqual(1, plan.placements.items.len);
    const p = plan.placements.items[0];
    try t.expectEqual(.before_command, p.kind);
    try t.expectEqual(12, p.doc_line);
    try t.expectEqualStrings("f", p.name);
    try t.expectEqual(4, p.line);
}

test "U4: where several excerpts end, the innermost whose indent the line has is taken" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fx = try fixture(a, example);
    const deeper = try planOf(a, fx, "top\n  one\n  two\n  deep\n  x\nend\n");
    try expectEdit(deeper, 0, .insert, 13, "x");
    try t.expectEqual(.after_command, deeper.placements.items[0].kind);
    try t.expectEqualStrings("f", deeper.placements.items[0].name);
    const outer = try planOf(a, fx, "top\n  one\n  two\n  deep\ny\nend\n");
    try expectEdit(outer, 0, .insert, 5, "y");
    try t.expectEqualStrings("e", outer.placements.items[0].name);
    // An empty line goes with the outermost.
    const empty = try planOf(a, fx, "top\n  one\n  two\n  deep\n\nend\n");
    try expectEdit(empty, 0, .insert, 5, "");
}

test "U4: a line added at the start or the end of a file goes into the block there" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fx = try fixture(a, example);
    const start = try planOf(a, fx, "first\ntop\n  one\n  two\n  deep\nend\n");
    try expectEdit(start, 0, .insert, 3, "first");
    try t.expectEqual(.block_start, start.placements.items[0].kind);
    const end = try planOf(a, fx, "top\n  one\n  two\n  deep\nend\nlast\n");
    try expectEdit(end, 0, .insert, 6, "last");
    try t.expectEqual(.block_end, end.placements.items[0].kind);
}

test "U4: several added lines go to one place, and their order is kept" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fx = try fixture(a, example);
    const plan = try planOf(a, fx, "top\n  one\n  two\n  deep\n  x\n\n  y\nend\n");
    try t.expectEqual(3, plan.edits.items.len);
    try expectEdit(plan, 0, .insert, 13, "x");
    try expectEdit(plan, 1, .insert, 13, "");
    try expectEdit(plan, 2, .insert, 13, "y");
    try t.expectEqual(3, plan.growth.items[0].added);
}

test "U5: a line that lost its excerpt's indent is reported, not guessed" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fx = try fixture(a, example);
    const changed = try planOf(a, fx, "top\none\n  two\n  deep\nend\n");
    try t.expectEqual(1, changed.problems.items.len);
    try t.expectEqual(2, changed.problems.items[0].line);
    try t.expectEqual(0, changed.edits.items.len);
    const added = try planOf(a, fx, "top\n  one\nnew\n  two\n  deep\nend\n");
    try t.expectEqual(1, added.problems.items.len);
    try t.expectEqual(3, added.problems.items[0].line);
    // A line of spaces that is shorter than the indent is no empty line.
    const spaces = try planOf(a, fx, "top\n  one\n \n  two\n  deep\nend\n");
    try t.expectEqual(1, spaces.problems.items.len);
}

test "T3: a changed file that does not end with a newline is reported" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fx = try fixture(a, example);
    const plan = try planOf(a, fx, "top\n  one\n  two\n  deep\nend");
    try t.expectEqual(1, plan.problems.items.len);
}

test "U3: a changed empty line takes the prefix of its excerpt" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fx = try fixture(a, "… :file: g\n----\n  … e\n----\n\n… e :file: g\n----\na\n\nb\n----\n");
    try t.expectEqualStrings("  a\n\n  b\n", fx.files[0].text);
    const plan = try planOf(a, fx, "  a\n  mid\n  b\n");
    try expectEdit(plan, 0, .replace, 9, "mid");
}

fn expectVerified(a: Allocator, fx: Fixture, plan: Plan, disk: []const u8) !void {
    const docs = try applyEdits(a, fx.docs, plan.edits.items);
    const message = try verify(a, docs, &.{"d.adoc"}, &.{.{ .path = "f.txt", .text = disk }});
    if (message) |m| std.debug.print("{s}\n", .{m});
    try t.expect(message == null);
}

test "U9: edits of every kind give documents that tangle to the changed file" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fx = try fixture(a, example);
    const disk = "TOP\n  one\n  deep\n  x\n  y\nend\n";
    const plan = try planOf(a, fx, disk);
    try t.expectEqual(0, plan.problems.items.len);
    try expectVerified(a, fx, plan, disk);
    const docs = try applyEdits(a, fx.docs, plan.edits.items);
    try t.expectEqualStrings(
        "… :file: f.txt\n----\nTOP\n  … e\nend\n----\n\n… e :file: f.txt\n----\none\n… f\nx\ny\n----\n\n… f :file: f.txt\n----\ndeep\n----\n",
        try render(a, docs[0]),
    );
}

test "U9: edits that break the documents are caught, and nothing is trusted" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fx = try fixture(a, example);
    // A line that closes the block early.
    const bad = [_]Edit{.{ .doc = 0, .line = 3, .kind = .replace, .text = "----" }};
    const docs = try applyEdits(a, fx.docs, &bad);
    const message = try verify(a, docs, &.{"d.adoc"}, &.{.{ .path = "f.txt", .text = "----\n  one\n  two\n  deep\nend\n" }});
    try t.expect(message != null);
    // A line that would be read as an excerpt command.
    const command = [_]Edit{.{ .doc = 0, .line = 3, .kind = .replace, .text = "… x" }};
    const docs2 = try applyEdits(a, fx.docs, &command);
    const message2 = try verify(a, docs2, &.{"d.adoc"}, &.{.{ .path = "f.txt", .text = "… x\n  one\n  two\n  deep\nend\n" }});
    try t.expect(message2 != null);
}

test "render keeps a missing final newline" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const doc: Document = .{ .path = "x.adoc", .format = .asciidoc, .lines = &.{ "a", "b" }, .dir = "", .final_newline = false };
    try t.expectEqualStrings("a\nb", try render(a, doc));
    var with = doc;
    with.final_newline = true;
    try t.expectEqualStrings("a\nb\n", try render(a, with));
    with.lines = &.{};
    try t.expectEqualStrings("", try render(a, with));
}

const words = [_][]const u8{ "alpha", "beta", "", "  x", "}", "{ y", "  ", "gamma delta" };
const indents = [_][]const u8{ "", " ", "  ", "\t" };

/// A random document: a file root, and excerpts that are each used once by an earlier one.
fn randomDocument(a: Allocator, random: std.Random) ![]const u8 {
    const count = random.uintLessThan(usize, 6);
    const containers = try a.alloc(std.ArrayList([]const u8), count + 1);
    for (containers) |*c| {
        c.* = .empty;
        for (0..1 + random.uintLessThan(usize, 5)) |_| try c.append(a, words[random.uintLessThan(usize, words.len)]);
    }
    // Container 0 is the root; excerpt j is container j, used once by an earlier one.
    var j = count;
    while (j >= 1) : (j -= 1) {
        const parent = random.uintLessThan(usize, j);
        const command = try std.fmt.allocPrint(a, "{s}… e{d}", .{ indents[random.uintLessThan(usize, indents.len)], j });
        const at = random.uintLessThan(usize, containers[parent].items.len + 1);
        try containers[parent].insert(a, at, command);
    }
    var out: std.ArrayList(u8) = .empty;
    for (containers, 0..) |c, n| {
        const label = if (n == 0) try a.dupe(u8, "… :file: f.txt") else try std.fmt.allocPrint(a, "… e{d} :file: f.txt", .{n});
        // Some excerpts are split in two blocks, with prose between.
        const split = if (n > 0 and c.items.len > 1 and random.boolean()) random.uintLessThan(usize, c.items.len - 1) + 1 else c.items.len;
        const parts = [_][]const []const u8{ c.items[0..split], c.items[split..] };
        for (parts, 0..) |part, p| {
            if (p == 1 and part.len == 0) break;
            try out.print(a, "{s}\n----\n", .{label});
            for (part) |line| try out.print(a, "{s}\n", .{line});
            try out.appendSlice(a, "----\n\nSome prose.\n\n");
        }
    }
    return out.items;
}

/// Random edits of a tangled file: lines changed, removed, and added, mostly with the indent of
/// the line next to them, and sometimes without it.
fn randomEdits(a: Allocator, random: std.Random, text: []const u8) ![]const u8 {
    const lines = try scan.splitLines(a, text);
    var out: std.ArrayList(u8) = .empty;
    if (random.uintLessThan(u8, 10) == 0) try out.appendSlice(a, "first\n");
    for (lines) |line| {
        var lead: usize = 0;
        while (lead < line.len and (line[lead] == ' ' or line[lead] == '\t')) lead += 1;
        const keep = if (random.uintLessThan(u8, 8) == 0 and lead > 0) lead - 1 else lead;
        const new = words[random.uintLessThan(usize, words.len)];
        switch (random.uintLessThan(u8, 10)) {
            0 => {},
            1 => try out.print(a, "{s}{s}\n", .{ line[0..keep], new }),
            2 => try out.print(a, "{s}\n{s}{s}\n", .{ line, line[0..keep], new }),
            else => try out.print(a, "{s}\n", .{line}),
        }
    }
    return out.items;
}

test "U9: random edits of random documents are carried back exactly, or reported" {
    var prng = std.Random.DefaultPrng.init(0x7a9613);
    const random = prng.random();
    var carried: usize = 0;
    var reported: usize = 0;
    for (0..600) |round| {
        var arena_state = std.heap.ArenaAllocator.init(t.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const text = try randomDocument(a, random);
        const fx = try fixture(a, text);
        const disk = try randomEdits(a, random, fx.files[0].text);
        const plan = try planOf(a, fx, disk);
        if (plan.problems.items.len > 0) {
            reported += 1;
            continue;
        }
        const docs = try applyEdits(a, fx.docs, plan.edits.items);
        if (try verify(a, docs, &.{"d.adoc"}, &.{.{ .path = "f.txt", .text = disk }})) |message| {
            std.debug.print("round {d}: {s}\n--- document\n{s}--- tangled\n{s}--- changed\n{s}--- new document\n{s}\n", .{
                round, message, text, fx.files[0].text, disk, try render(a, docs[0]),
            });
            return error.UntangleNotExact;
        }
        carried += 1;
    }
    try t.expect(carried > 200);
    try t.expect(reported > 20);
}
