//! Expands each file from its root into its text, and records the runs that say
//! where every line came from. No IO.

const std = @import("std");
const types = @import("types.zig");
const resolve = @import("resolve.zig");

const Allocator = std.mem.Allocator;
const Block = types.Block;
const Run = types.Run;

pub const Tangled = struct {
    path: []const u8,
    executable: bool,
    /// Every line ends with `\n` (T3).
    text: []const u8,
    runs: []const Run,
};

const Expander = struct {
    arena: Allocator,
    file: *const resolve.File,
    out: std.ArrayList(u8) = .empty,
    runs: std.ArrayList(Run) = .empty,
    /// The indents of the excerpt commands being expanded, put together.
    prefix: std.ArrayList(u8) = .empty,
    /// The lines written so far.
    lines: u32 = 0,
    /// The block line that would continue the last run.
    next_block: ?*const Block = null,
    next_index: u32 = 0,

    fn block(self: *Expander, b: *const Block) Allocator.Error!void {
        var command: usize = 0;
        for (b.lines, 0..) |line, i| {
            if (command < b.commands.len and b.commands[command].index == i) {
                const c = b.commands[command];
                command += 1;
                const mark = self.prefix.items.len;
                try self.prefix.appendSlice(self.arena, c.indent);
                // Unknown names were reported as C1, and tangling does not happen then.
                const excerpt = self.file.excerpts.get(c.name).?;
                for (excerpt.blocks.items) |inner| try self.block(inner);
                self.prefix.items.len = mark;
                continue;
            }
            try self.emitLine(b, @intCast(i), line);
        }
    }

    fn emitLine(self: *Expander, b: *const Block, index: u32, text: []const u8) !void {
        const indent: u32 = if (text.len == 0) 0 else @intCast(self.prefix.items.len);
        try self.out.ensureUnusedCapacity(self.arena, indent + text.len + 1);
        if (text.len > 0) self.out.appendSliceAssumeCapacity(self.prefix.items);
        self.out.appendSliceAssumeCapacity(text);
        self.out.appendAssumeCapacity('\n');
        self.lines += 1;

        const last: ?*Run = if (self.runs.items.len > 0) &self.runs.items[self.runs.items.len - 1] else null;
        if (last) |run| {
            // An empty line carries no indent, so it joins a run of any indent.
            const same_indent = text.len == 0 or run.indent == indent;
            if (self.next_block == b and self.next_index == index and same_indent) {
                run.count += 1;
                if (text.len > 0) run.indent = indent;
                self.next_index += 1;
                return;
            }
        }
        try self.runs.append(self.arena, .{
            .line = self.lines,
            .count = 1,
            .doc = b.label.doc,
            .doc_line = b.first_line + index,
            .indent = indent,
            .excerpt = b.label.name orelse ":file:",
        });
        self.next_block = b;
        self.next_index = index + 1;
    }
};

/// Tangles every file that has a root. The files must have passed the checks.
pub fn tangleAll(arena: Allocator, resolved: resolve.Resolved) ![]const Tangled {
    var result: std.ArrayList(Tangled) = .empty;
    for (resolved.files) |*file| {
        if (file.roots.items.len == 0) continue;
        var expander: Expander = .{ .arena = arena, .file = file };
        for (file.roots.items) |root| try expander.block(root);
        try result.append(arena, .{
            .path = file.path,
            .executable = file.executable,
            .text = expander.out.items,
            .runs = expander.runs.items,
        });
    }
    return result.items;
}

// Tests ----------------------------------------------------------------------

const t = std.testing;
const scan = @import("scan.zig");
const parse = @import("parse.zig");

fn tangleText(a: Allocator, text: []const u8) ![]const Tangled {
    var diags = types.Diagnostics.init(a);
    const doc: types.Document = .{ .path = "hello.adoc", .format = .asciidoc, .lines = try scan.splitLines(a, text), .dir = "" };
    const parsed = try parse.parse(a, 0, doc, &diags);
    const resolved = try resolve.resolve(a, try a.dupe(types.Document, &.{doc}), parsed.blocks, &diags);
    for (diags.list.items) |d| std.debug.print("{d}: {s}\n", .{ d.line, d.message });
    try t.expectEqual(0, diags.list.items.len);
    return tangleAll(a, resolved);
}

fn expectRun(run: Run, line: u32, count: u32, doc_line: u32, indent: u32, excerpt: []const u8) !void {
    try t.expectEqual(line, run.line);
    try t.expectEqual(count, run.count);
    try t.expectEqual(doc_line, run.doc_line);
    try t.expectEqual(indent, run.indent);
    try t.expectEqualStrings(excerpt, run.excerpt);
}

test "T1, T2, T3: the example of the spec" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const out = try tangleText(arena_state.allocator(),
        \\The program prints a greeting from its main function.
        \\
        \\… :file: hello.zig
        \\[source,zig]
        \\----
        \\… imports
        \\
        \\pub fn main() void {
        \\    … greet
        \\}
        \\----
        \\
        \\The greeting goes to standard error, which needs no setup:
        \\
        \\… greet :file: hello.zig
        \\[source,zig]
        \\----
        \\std.debug.print("Hello, Litmus!\n", .{});
        \\----
        \\
        \\… imports :file: hello.zig
        \\[source,zig]
        \\----
        \\const std = @import("std");
        \\----
        \\
    );
    try t.expectEqual(1, out.len);
    try t.expectEqualStrings("hello.zig", out[0].path);
    try t.expectEqualStrings(
        \\const std = @import("std");
        \\
        \\pub fn main() void {
        \\    std.debug.print("Hello, Litmus!\n", .{});
        \\}
        \\
    , out[0].text);
    try t.expectEqual(4, out[0].runs.len);
    try expectRun(out[0].runs[0], 1, 1, 24, 0, "imports");
    try expectRun(out[0].runs[1], 2, 2, 7, 0, ":file:");
    try expectRun(out[0].runs[2], 4, 1, 18, 4, "greet");
    try expectRun(out[0].runs[3], 5, 1, 10, 0, ":file:");
}

test "T2: indents accumulate through nested excerpts, tabs included" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const out = try tangleText(arena_state.allocator(), "… :file: a\n----\ntop\n  … outer\nend\n----\n… outer :file: a\n----\no1\n\t… inner\no2\n----\n… inner :file: a\n----\ni1\n\n  i2\n----\n");
    try t.expectEqualStrings("top\n  o1\n  \t" ++ "i1\n\n  \t  i2\n  o2\nend\n", out[0].text);
}

test "T2: a line of spaces is not empty and gets the indent" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const out = try tangleText(arena_state.allocator(), "… :file: a\n----\n  … e\n----\n… e :file: a\n----\n \n\n----\n");
    try t.expectEqualStrings("   \n\n", out[0].text);
}

test "T2: an excerpt of several blocks is joined in document order" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const out = try tangleText(arena_state.allocator(),
        \\… :file: a
        \\----
        \\a
        \\… e
        \\b
        \\----
        \\… e :file: a
        \\----
        \\1
        \\----
        \\text
        \\… :file: a
        \\----
        \\c
        \\----
        \\… e :file: a
        \\----
        \\2
        \\----
    );
    try t.expectEqualStrings("a\n1\n2\nb\nc\n", out[0].text);
    const runs = out[0].runs;
    try t.expectEqual(5, runs.len);
    try expectRun(runs[1], 2, 1, 9, 0, "e");
    try expectRun(runs[2], 3, 1, 18, 0, "e");
    try expectRun(runs[3], 4, 1, 5, 0, ":file:");
    try expectRun(runs[4], 5, 1, 14, 0, ":file:");
}

test "L7: a \\r stays part of its line" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const out = try tangleText(arena_state.allocator(), "… :file: a\n----\nx\r\n  … e\n----\n… e :file: a\n----\ny\r\n----\n");
    try t.expectEqualStrings("x\r\n  y\r\n", out[0].text);
}

test "a run covers consecutive lines, empty ones included, and splits at other blocks" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const out = try tangleText(arena_state.allocator(), "… :file: a\n----\n1\n\n3\n    … e\n5\n----\n… e :file: a\n----\nx\n\ny\n----\n");
    const runs = out[0].runs;
    try t.expectEqual(3, runs.len);
    try expectRun(runs[0], 1, 3, 3, 0, ":file:");
    try expectRun(runs[1], 4, 3, 11, 4, "e");
    try expectRun(runs[2], 7, 1, 7, 0, ":file:");
}

test "an excerpt used in a file with no lines, and a file with an empty root" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const out = try tangleText(arena_state.allocator(), "… :file: a\n----\n----\n… :file: b :executable:\n----\nx\n----\n");
    try t.expectEqual(2, out.len);
    try t.expectEqualStrings("", out[0].text);
    try t.expectEqual(0, out[0].runs.len);
    try t.expect(out[1].executable);
}
