//! Turns one scanned document into labels, blocks, excerpt commands, includes and
//! the `:litmus-dir:` directory. It reports every problem it finds as a
//! diagnostic and goes on. No IO.

const std = @import("std");
const scan = @import("scan.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Document = types.Document;
const Label = types.Label;
const Block = types.Block;
const Command = types.Command;
const Diagnostics = types.Diagnostics;

pub const Include = struct {
    line: u32,
    /// As written, relative to the including document.
    path: []const u8,
};

pub const Parsed = struct {
    blocks: []const Block,
    includes: []const Include,
};

const blank = " \t\r";

/// Why a path breaks L1, or null if it is fine.
pub fn pathProblem(path: []const u8) ?[]const u8 {
    if (path.len == 0) return "the path is empty";
    if (path[0] == '/') return "the path must be relative";
    if (std.mem.indexOfScalar(u8, path, '\t') != null) return "the path has a tab";
    var parts = std.mem.splitScalar(u8, path, '/');
    var real_parts: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0) return "the path has an empty part";
        if (std.mem.eql(u8, part, "..")) return "the path has a '..' part";
        if (!std.mem.eql(u8, part, ".")) real_parts += 1;
    }
    if (real_parts == 0) return "the path is empty";
    return null;
}

/// Removes the `.` parts of a path that `pathProblem` accepted.
pub fn normalizePath(arena: Allocator, path: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, path, "./") == null and !std.mem.endsWith(u8, path, "/.")) return path;
    var out: std.ArrayList(u8) = .empty;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (out.items.len > 0) try out.append(arena, '/');
        try out.appendSlice(arena, part);
    }
    return out.items;
}

const ParsedLabel = struct { name: ?[]const u8, path: []const u8, executable: bool };

fn isAttribute(word: []const u8) bool {
    return word.len >= 3 and word[0] == ':' and word[word.len - 1] == ':';
}

/// Reads the text of a document command (L1, L9). Reports C11 and C7 itself.
fn parseLabel(diags: *Diagnostics, doc: u32, line: u32, text: []const u8) !?ParsedLabel {
    var file_at: ?usize = null; // where the text after `:file:` starts
    var file_start: usize = 0;
    var path_end: usize = text.len;
    var executable = false;
    var ok = true;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and std.mem.indexOfScalar(u8, blank, text[i]) != null) i += 1;
        const start = i;
        while (i < text.len and std.mem.indexOfScalar(u8, blank, text[i]) == null) i += 1;
        const word = text[start..i];
        if (!isAttribute(word)) continue;
        if (std.mem.eql(u8, word, ":file:")) {
            if (file_at != null) {
                try diags.add(doc, line, "C11: the label has :file: twice", .{});
                ok = false;
            } else {
                file_at = i;
                file_start = start;
            }
        } else if (std.mem.eql(u8, word, ":executable:") and file_at != null) {
            executable = true;
            path_end = @min(path_end, start);
        } else {
            try diags.add(doc, line, "C11: the label has the attribute {s}, and only :file: and :executable: are allowed", .{word});
            ok = false;
            if (file_at != null) path_end = @min(path_end, start);
        }
    }
    const at = file_at orelse {
        if (ok) try diags.add(doc, line, "C11: the label has no :file:", .{});
        return null;
    };
    if (!ok) return null;
    const name = std.mem.trim(u8, text[0..file_start], blank);
    if (name.len > 0 and name[0] == ':') {
        try diags.add(doc, line, "C11: a name may not start with ':'", .{});
        return null;
    }
    const path = std.mem.trim(u8, text[at..path_end], blank);
    if (pathProblem(path)) |problem| {
        try diags.add(doc, line, "C7: {s}", .{problem});
        return null;
    }
    return .{ .name = if (name.len == 0) null else name, .path = path, .executable = executable };
}

/// Reads the path of an `include::path[...]` line (L6).
fn includePath(line: []const u8) ?[]const u8 {
    const rest = line["include::".len..];
    const open = std.mem.indexOfScalar(u8, rest, '[') orelse return null;
    if (open == 0 or rest[0] == '/') return null;
    if (std.mem.indexOfScalar(u8, rest[0..open], '\t') != null) return null;
    return rest[0..open];
}

pub fn parse(arena: Allocator, doc_index: u32, doc: Document, diags: *Diagnostics) !Parsed {
    var scanner = scan.Scanner.init(doc.format);
    var blocks: std.ArrayList(Block) = .empty;
    var includes: std.ArrayList(Include) = .empty;

    var litmus_dir: []const u8 = "";
    var dir_seen = false;
    var command_seen = false;

    var pending: ?Label = null;
    var block_label: ?Label = null;
    var block_open: usize = 0; // the index of the line that opened the block
    var commands: std.ArrayList(Command) = .empty;

    for (doc.lines, 0..) |line, index| {
        const n: u32 = @intCast(index + 1);
        const kind = scanner.next(line);
        switch (kind) {
            .attribute, .title => continue,
            .open => {
                block_open = index;
                block_label = pending;
                pending = null;
                commands = .empty;
                continue;
            },
            .code => {
                if (block_label == null) continue;
                if (doc.format == .asciidoc and std.mem.startsWith(u8, line, "include::")) {
                    try diags.add(doc_index, n, "C7: an include inside a labeled block", .{});
                } else if (scan.commandOf(line)) |command| {
                    const name = std.mem.trim(u8, command.text, blank);
                    try commands.append(arena, .{ .index = @intCast(index - block_open - 1), .indent = command.indent, .name = name });
                }
                continue;
            },
            .close => {
                if (block_label) |label| {
                    try blocks.append(arena, .{
                        .label = label,
                        .first_line = @intCast(block_open + 2),
                        .lines = doc.lines[block_open + 1 .. index],
                        .commands = try commands.toOwnedSlice(arena),
                    });
                }
                block_label = null;
                continue;
            },
            .prose, .skip, .command, .include, .dir => {},
        }
        // Whatever else comes after a document command ends its wait for a block (L2).
        if (pending) |label| {
            try diags.add(doc_index, label.line, "C5: the label is not followed by a code block", .{});
            pending = null;
        }
        switch (kind) {
            .command => {
                command_seen = true;
                const command = scan.commandOf(line).?;
                const parsed = (try parseLabel(diags, doc_index, n, command.text)) orelse continue;
                const file = if (litmus_dir.len == 0)
                    try normalizePath(arena, parsed.path)
                else
                    try std.fmt.allocPrint(arena, "{s}/{s}", .{ litmus_dir, try normalizePath(arena, parsed.path) });
                pending = .{ .doc = doc_index, .line = n, .name = parsed.name, .file = file, .executable = parsed.executable };
            },
            .include => {
                if (includePath(line)) |path| {
                    try includes.append(arena, .{ .line = n, .path = path });
                } else {
                    try diags.add(doc_index, n, "C7: the include line needs a path and brackets", .{});
                }
            },
            .dir => {
                const value = if (doc.format == .markdown) scan.markdownDir(line).? else scan.asciidocDir(line);
                if (command_seen) {
                    try diags.add(doc_index, n, "C8: :litmus-dir: comes after a document command", .{});
                } else if (dir_seen) {
                    try diags.add(doc_index, n, "C8: :litmus-dir: appears twice", .{});
                } else if (pathProblem(value)) |problem| {
                    try diags.add(doc_index, n, "C7: {s}", .{problem});
                } else {
                    litmus_dir = try normalizePath(arena, value);
                }
                dir_seen = true;
            },
            else => {},
        }
    }
    if (pending) |label| try diags.add(doc_index, label.line, "C5: the label is not followed by a code block", .{});
    if (scanner.inCodeBlock()) try diags.add(doc_index, @intCast(block_open + 1), "C6: the code block is never closed", .{});
    return .{ .blocks = try blocks.toOwnedSlice(arena), .includes = try includes.toOwnedSlice(arena) };
}

// Tests ----------------------------------------------------------------------

const t = std.testing;

const Result = struct {
    parsed: Parsed,
    diags: Diagnostics,

    fn expectDiag(self: Result, line: u32, needle: []const u8) !void {
        for (self.diags.list.items) |d| {
            if (d.line == line and std.mem.indexOf(u8, d.message, needle) != null) return;
        }
        std.debug.print("no diagnostic at line {d} with \"{s}\"; have:\n", .{ line, needle });
        for (self.diags.list.items) |d| std.debug.print("  {d}: {s}\n", .{ d.line, d.message });
        return error.MissingDiagnostic;
    }

    fn expectNoDiags(self: Result) !void {
        if (self.diags.list.items.len != 0) {
            for (self.diags.list.items) |d| std.debug.print("  {d}: {s}\n", .{ d.line, d.message });
        }
        try t.expectEqual(0, self.diags.list.items.len);
    }
};

fn run(arena: Allocator, format: types.Format, text: []const u8) !Result {
    var diags = Diagnostics.init(arena);
    const doc: Document = .{ .path = "d", .format = format, .lines = try scan.splitLines(arena, text), .dir = "" };
    const parsed = try parse(arena, 0, doc, &diags);
    return .{ .parsed = parsed, .diags = diags };
}

test "L1: a file root, an excerpt, and a name with spaces" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const r = try run(arena_state.allocator(), .asciidoc,
        \\… :file: a/b.zig
        \\----
        \\x
        \\----
        \\… the main loop :file: ./a/./c.zig
        \\----
        \\y
        \\----
    );
    try r.expectNoDiags();
    try t.expectEqual(2, r.parsed.blocks.len);
    const root = r.parsed.blocks[0];
    try t.expect(root.label.name == null);
    try t.expectEqualStrings("a/b.zig", root.label.file);
    try t.expectEqual(1, root.label.line);
    try t.expectEqual(3, root.first_line);
    try t.expectEqual(1, root.lines.len);
    const named = r.parsed.blocks[1];
    try t.expectEqualStrings("the main loop", named.label.name.?);
    try t.expectEqualStrings("a/c.zig", named.label.file);
    try t.expectEqual(7, named.first_line);
}

test "L9: :executable: ends the path" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const r = try run(arena_state.allocator(), .asciidoc, "… :file: run.sh :executable:\n----\n----\n");
    try r.expectNoDiags();
    try t.expect(r.parsed.blocks[0].label.executable);
    try t.expectEqualStrings("run.sh", r.parsed.blocks[0].label.file);
}

test "C11: no :file:, another attribute, a repeated :file:, a name starting with ':'" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try (try run(a, .asciidoc, "… name\n----\n----\n")).expectDiag(1, "C11");
    try (try run(a, .asciidoc, "… a :file: x :other:\n----\n----\n")).expectDiag(1, ":other:");
    try (try run(a, .asciidoc, "… a :other: :file: x\n----\n----\n")).expectDiag(1, ":other:");
    try (try run(a, .asciidoc, "… :file: x :file: y\n----\n----\n")).expectDiag(1, "twice");
    try (try run(a, .asciidoc, "… :a b :file: x\n----\n----\n")).expectDiag(1, "start with");
    try (try run(a, .asciidoc, "… :executable: :file: x\n----\n----\n")).expectDiag(1, ":executable:");
    // Just misses: attribute-like text that is not a whole word is part of the name.
    const r = try run(a, .asciidoc, "… a:file:b :file: x\n----\n----\n");
    try r.expectNoDiags();
    try t.expectEqualStrings("a:file:b", r.parsed.blocks[0].label.name.?);
}

test "L2: attribute and title lines may sit between a label and its block" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const r = try run(arena_state.allocator(), .asciidoc, "… :file: x\n.Title\n[source,zig]\n[[anchor]]\n----\nc\n----\n");
    try r.expectNoDiags();
    try t.expectEqual(1, r.parsed.blocks.len);
}

test "C5: a label with no block next to it" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try (try run(a, .asciidoc, "… :file: x\n\n----\nc\n----\n")).expectDiag(1, "C5");
    try (try run(a, .asciidoc, "… :file: x\n// note\n----\nc\n----\n")).expectDiag(1, "C5");
    try (try run(a, .asciidoc, "… :file: x\n....\nc\n....\n")).expectDiag(1, "C5");
    try (try run(a, .asciidoc, "… :file: x\n… :file: y\n----\n----\n")).expectDiag(1, "C5");
    try (try run(a, .asciidoc, "text\n… :file: x\n")).expectDiag(2, "C5");
    const r = try run(a, .asciidoc, "… :file: x\n… :file: y\n----\n----\n");
    try t.expectEqual(1, r.parsed.blocks.len);
    try t.expectEqualStrings("y", r.parsed.blocks[0].label.file);
}

test "M2: a Markdown label labels the fence on the next line" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try run(a, .markdown, "… :file: x\n```zig\ncode\n```\n");
    try r.expectNoDiags();
    try t.expectEqual(1, r.parsed.blocks.len);
    try (try run(a, .markdown, "… :file: x\n\n```\n```\n")).expectDiag(1, "C5");
}

test "L3, L4: excerpt commands in a labeled block, with indent and name" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const r = try run(arena_state.allocator(), .asciidoc, "… :file: x\n----\na\n\t  … one two  \n… three\n----\n");
    try r.expectNoDiags();
    const cmds = r.parsed.blocks[0].commands;
    try t.expectEqual(2, cmds.len);
    try t.expectEqual(1, cmds[0].index);
    try t.expectEqualStrings("\t  ", cmds[0].indent);
    try t.expectEqualStrings("one two", cmds[0].name);
    try t.expectEqual(2, cmds[1].index);
    try t.expectEqualStrings("", cmds[1].indent);
}

test "L5: an illustration holds commands that are ignored" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const r = try run(arena_state.allocator(), .asciidoc, "----\n… :file: x\n… y\n----\n....\n… :file: x\n....\n");
    try r.expectNoDiags();
    try t.expectEqual(0, r.parsed.blocks.len);
}

test "C6: a block open at the end of the document" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try (try run(a, .asciidoc, "text\n… :file: x\n----\ncode\n")).expectDiag(3, "C6");
    try (try run(a, .asciidoc, "----\ncode\n")).expectDiag(1, "C6");
    try (try run(a, .markdown, "```\ncode\n")).expectDiag(1, "C6");
    try (try run(a, .asciidoc, "....\ncode\n")).expectNoDiags();
}

test "L6, C7: includes outside blocks are recorded, inside a labeled block they are errors" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try run(a, .asciidoc, "include::a/b.adoc[]\n… :file: x\n----\ninclude::c.txt[]\n----\n----\ninclude::d[]\n----\n");
    try t.expectEqual(1, r.parsed.includes.len);
    try t.expectEqualStrings("a/b.adoc", r.parsed.includes[0].path);
    try t.expectEqual(1, r.parsed.includes[0].line);
    try r.expectDiag(4, "C7");
    try t.expectEqual(1, r.diags.list.items.len);
    try (try run(a, .asciidoc, "include::[]\n")).expectDiag(1, "C7");
    try (try run(a, .asciidoc, "include::a.adoc\n")).expectDiag(1, "C7");
    try (try run(a, .asciidoc, "include::/a.adoc[]\n")).expectDiag(1, "C7");
    // M4
    const md = try run(a, .markdown, "include::a.md[]\n");
    try t.expectEqual(0, md.parsed.includes.len);
}

test "L8, M5: the directory goes in front of every path of the document" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try run(a, .asciidoc, ":litmus-dir: ./src/core\n… :file: vm.zig\n----\n----\n");
    try r.expectNoDiags();
    try t.expectEqualStrings("src/core/vm.zig", r.parsed.blocks[0].label.file);
    const md = try run(a, .markdown, "<!-- :litmus-dir: src -->\n… :file: vm.zig\n```\n```\n");
    try md.expectNoDiags();
    try t.expectEqualStrings("src/vm.zig", md.parsed.blocks[0].label.file);
}

test "C8: a directory after a document command, or twice" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try (try run(a, .asciidoc, "… :file: x\n----\n----\n:litmus-dir: d\n")).expectDiag(4, "C8");
    try (try run(a, .asciidoc, ":litmus-dir: d\n:litmus-dir: e\n")).expectDiag(2, "C8");
    try (try run(a, .markdown, "<!-- :litmus-dir: d -->\n<!-- :litmus-dir: e -->\n")).expectDiag(2, "C8");
    // A directory inside a block is code, not an entry.
    try (try run(a, .asciidoc, "… :file: x\n----\n:litmus-dir: d\n----\n:litmus-dir: e\n")).expectDiag(5, "C8");
    try (try run(a, .asciidoc, "----\n:litmus-dir: d\n----\n:litmus-dir: e\n")).expectNoDiags();
}

test "C7: paths" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bad = [_][]const u8{ "/abs", "a/../b", "a//b", "a/", "", "..", "./", "a\tb" };
    for (bad) |path| {
        const text = try std.fmt.allocPrint(a, "… :file: {s}\n----\n----\n", .{path});
        try (try run(a, .asciidoc, text)).expectDiag(1, "C7");
    }
    try (try run(a, .asciidoc, ":litmus-dir: ../x\n")).expectDiag(1, "C7");
    try (try run(a, .asciidoc, ":litmus-dir:\n")).expectDiag(1, "C7");
    try t.expectEqualStrings("a/b", try normalizePath(a, "./a/./b/."));
    try t.expectEqualStrings("a/b", try normalizePath(a, "a/b"));
}

test "every problem is reported, not only the first" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const r = try run(arena_state.allocator(), .asciidoc, "… a\n\n… :file: /x\n----\n… :file: y\n");
    try t.expectEqual(3, r.diags.list.items.len);
}
