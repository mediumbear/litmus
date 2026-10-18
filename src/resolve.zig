//! Groups the blocks of the document set into files, file roots and excerpts, and
//! runs the checks that need the whole set: C1 to C4 and C9. Names belong to their
//! file, so two files can each have an excerpt called `body`.

const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Block = types.Block;
const Document = types.Document;
const Diagnostics = types.Diagnostics;

const Where = struct { doc: u32, line: u32 };

/// An excerpt command that resolved: where it is, and what it stands for.
const Edge = struct { target: *Excerpt, at: Where };

pub const Excerpt = struct {
    name: []const u8,
    /// In document order.
    blocks: std.ArrayList(*const Block) = .empty,
    first_label: Where,
    uses: u32 = 0,
    first_use: Where = .{ .doc = 0, .line = 0 },
    /// The excerpts that this one's blocks use, for the search for cycles.
    edges: std.ArrayList(Edge) = .empty,
    state: enum { new, visiting, done } = .new,
};

pub const File = struct {
    path: []const u8,
    executable: bool = false,
    /// The blocks of the file root, in document order.
    roots: std.ArrayList(*const Block) = .empty,
    excerpts: std.StringHashMapUnmanaged(*Excerpt) = .empty,
    /// The excerpts in the order of their first label.
    order: std.ArrayList(*Excerpt) = .empty,
};

pub const Resolved = struct {
    /// In order of first appearance.
    files: []File,
};

pub fn resolve(arena: Allocator, docs: []const Document, blocks: []const Block, diags: *Diagnostics) !Resolved {
    var files: std.ArrayList(File) = .empty;
    var index: std.StringHashMapUnmanaged(usize) = .empty;

    // Group the blocks. Files are pointers into a list that grows, so find them by
    // index until grouping is done.
    for (blocks) |*block| {
        const label = block.label;
        const slot = try index.getOrPut(arena, label.file);
        if (!slot.found_existing) {
            slot.value_ptr.* = files.items.len;
            try files.append(arena, .{ .path = label.file });
        }
        const file = &files.items[slot.value_ptr.*];
        if (label.name) |name| {
            if (label.executable) try diags.add(label.doc, label.line, "C9: :executable: belongs on a file root, not on the excerpt \"{s}\"", .{name});
            const found = try file.excerpts.getOrPut(arena, name);
            if (!found.found_existing) {
                const excerpt = try arena.create(Excerpt);
                excerpt.* = .{ .name = name, .first_label = .{ .doc = label.doc, .line = label.line } };
                found.value_ptr.* = excerpt;
                try file.order.append(arena, excerpt);
            }
            try found.value_ptr.*.blocks.append(arena, block);
        } else {
            if (label.executable) file.executable = true;
            try file.roots.append(arena, block);
        }
    }

    // Find what every excerpt command stands for (C1, C3).
    for (files.items) |*file| {
        for (file.roots.items) |block| try useAll(arena, docs, files.items, file, block, null, diags);
        for (file.order.items) |excerpt| {
            for (excerpt.blocks.items) |block| try useAll(arena, docs, files.items, file, block, excerpt, diags);
        }
    }

    // C2
    for (files.items) |file| {
        for (file.order.items) |excerpt| {
            if (excerpt.uses == 0) {
                try diags.add(excerpt.first_label.doc, excerpt.first_label.line, "C2: the excerpt \"{s}\" in {s} is not used", .{ excerpt.name, file.path });
            }
        }
    }

    // C4
    for (files.items) |file| {
        for (file.order.items) |excerpt| try findCycles(arena, docs, file, excerpt, diags);
    }

    return .{ .files = files.items };
}

fn useAll(arena: Allocator, docs: []const Document, files: []const File, file: *File, block: *const Block, owner: ?*Excerpt, diags: *Diagnostics) !void {
    for (block.commands) |command| {
        const at: Where = .{ .doc = block.label.doc, .line = block.first_line + command.index };
        const target = file.excerpts.get(command.name) orelse {
            try reportMissing(diags, docs, files, file, command.name, at);
            continue;
        };
        if (target.uses > 0) {
            const first = target.first_use;
            try diags.add(at.doc, at.line, "C3: the excerpt \"{s}\" is already used at {s}:{d}", .{ command.name, docs[first.doc].path, first.line });
        } else {
            target.first_use = at;
        }
        target.uses += 1;
        if (owner) |o| try o.edges.append(arena, .{ .target = target, .at = at });
    }
}

fn reportMissing(diags: *Diagnostics, docs: []const Document, files: []const File, file: *const File, name: []const u8, at: Where) !void {
    for (files) |other| {
        if (&other == file) continue;
        if (other.excerpts.get(name)) |excerpt| {
            const label = excerpt.first_label;
            try diags.add(at.doc, at.line, "C1: no excerpt \"{s}\" in {s}; there is one in {s}, at {s}:{d}", .{ name, file.path, other.path, docs[label.doc].path, label.line });
            return;
        }
    }
    try diags.add(at.doc, at.line, "C1: no excerpt \"{s}\" in {s}", .{ name, file.path });
}

fn findCycles(arena: Allocator, docs: []const Document, file: File, excerpt: *Excerpt, diags: *Diagnostics) !void {
    if (excerpt.state != .new) return;
    excerpt.state = .visiting;
    for (excerpt.edges.items) |edge| {
        switch (edge.target.state) {
            .new => try findCycles(arena, docs, file, edge.target, diags),
            .visiting => try diags.add(edge.at.doc, edge.at.line, "C4: the excerpt \"{s}\" in {s} contains itself, through \"{s}\"", .{ edge.target.name, file.path, excerpt.name }),
            .done => {},
        }
    }
    excerpt.state = .done;
}

// Tests ----------------------------------------------------------------------

const t = std.testing;
const scan = @import("scan.zig");
const parse = @import("parse.zig");

const Checked = struct {
    diags: Diagnostics,
    resolved: Resolved,

    fn expect(self: Checked, line: u32, needle: []const u8) !void {
        for (self.diags.list.items) |d| {
            if (d.line == line and std.mem.indexOf(u8, d.message, needle) != null) return;
        }
        std.debug.print("no diagnostic at line {d} with \"{s}\"; have:\n", .{ line, needle });
        for (self.diags.list.items) |d| std.debug.print("  {d}: {s}\n", .{ d.line, d.message });
        return error.MissingDiagnostic;
    }

    fn expectCount(self: Checked, n: usize) !void {
        for (self.diags.list.items) |d| std.debug.print("  {d}: {s}\n", .{ d.line, d.message });
        try t.expectEqual(n, self.diags.list.items.len);
    }
};

fn check(a: Allocator, text: []const u8) !Checked {
    var diags = Diagnostics.init(a);
    const doc: Document = .{ .path = "d.adoc", .format = .asciidoc, .lines = try scan.splitLines(a, text), .dir = "" };
    const parsed = try parse.parse(a, 0, doc, &diags);
    const docs = try a.dupe(Document, &.{doc});
    const resolved = try resolve(a, docs, parsed.blocks, &diags);
    return .{ .diags = diags, .resolved = resolved };
}

test "files, roots and excerpts are grouped, in order of first appearance" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const c = try check(arena_state.allocator(),
        \\… :file: b.sh :executable:
        \\----
        \\… one
        \\----
        \\… :file: a.zig
        \\----
        \\… one
        \\----
        \\… one :file: a.zig
        \\----
        \\x
        \\----
        \\… :file: b.sh
        \\----
        \\y
        \\----
        \\… one :file: b.sh
        \\----
        \\z
        \\----
        \\… one :file: a.zig
        \\----
        \\w
        \\----
    );
    try c.expectCount(0);
    const files = c.resolved.files;
    try t.expectEqual(2, files.len);
    try t.expectEqualStrings("b.sh", files[0].path);
    try t.expect(files[0].executable);
    try t.expect(!files[1].executable);
    try t.expectEqual(2, files[0].roots.items.len);
    try t.expectEqual(1, files[1].roots.items.len);
    try t.expectEqual(2, files[1].excerpts.get("one").?.blocks.items.len);
}

test "C1: an excerpt command that names nothing, and one that names another file's excerpt" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const c = try check(a, "… :file: a\n----\n… gone\n----\n");
    try c.expect(3, "C1");
    try c.expectCount(1);
    const d = try check(a,
        \\… :file: a
        \\----
        \\… body
        \\----
        \\… body :file: b
        \\----
        \\x
        \\----
        \\… :file: b
        \\----
        \\… body
        \\----
    );
    try d.expect(3, "there is one in b, at d.adoc:5");
    // Just misses: a name is exact.
    const e = try check(a, "… :file: a\n----\n… Body\n----\n… body :file: a\n----\n----\n");
    try e.expect(3, "C1");
    try e.expect(5, "C2");
}

test "C2: an unused excerpt, reported at its first label" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const c = try check(a, "… :file: a\n----\n----\n… spare :file: a\n----\n----\n… spare :file: a\n----\n----\n");
    try c.expect(4, "C2");
    try c.expectCount(1);
    const d = try check(a, "… :file: a\n----\n… used\n----\n… used :file: a\n----\n----\n");
    try d.expectCount(0);
}

test "C3: an excerpt used twice, reported at the second use" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const c = try check(a, "… :file: a\n----\n… e\n  … e\n----\n… e :file: a\n----\n----\n");
    try c.expect(4, "d.adoc:3");
    try c.expectCount(1);
    // Used once in each of two files is fine.
    const d = try check(a, "… :file: a\n----\n… e\n----\n… :file: b\n----\n… e\n----\n… e :file: a\n----\n----\n… e :file: b\n----\n----\n");
    try d.expectCount(0);
}

test "C4: a cycle, even one that no root reaches" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const c = try check(a, "… :file: a\n----\n… x\n----\n… x :file: a\n----\n… y\n----\n… y :file: a\n----\n… z\n----\n… z :file: a\n----\n----\n");
    try c.expectCount(0);
    const d = try check(a, "… :file: a\n----\n----\n… p :file: a\n----\n… q\n----\n… q :file: a\n----\n… p\n----\n");
    try d.expect(10, "C4");
    try d.expectCount(1);
    const e = try check(a, "… :file: a\n----\n----\n… s :file: a\n----\n… s\n----\n");
    try e.expect(6, "C4");
    try e.expectCount(1);
}

test "C9: :executable: on an excerpt" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const c = try check(a, "… :file: a\n----\n… e\n----\n… e :file: a :executable:\n----\n----\n");
    try c.expect(5, "C9");
    try c.expectCount(1);
}
