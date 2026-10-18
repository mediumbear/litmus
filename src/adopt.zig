//! `litmus adopt` (A1 to A8): a new document that holds the code of existing files, split
//! into excerpts at their declarations, as the start of a literate document. This file
//! makes the text of the document. No IO.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// A file to adopt: its path, relative to the output directory, and its text.
pub const Source = struct { path: []const u8, text: []const u8 };

pub const Options = struct {
    /// The document's title.
    title: []const u8,
    /// The style file, as the document names it (L10).
    style: ?[]const u8 = null,
    companion: bool = false,
};

/// A file that cannot go into a document (A2), and why.
pub const Refusal = struct { path: []const u8, line: u32, reason: []const u8 };

pub const Result = struct {
    /// The text of the document, or empty if anything was refused.
    text: []const u8,
    refusals: []const Refusal,
    /// How many excerpts the document has.
    excerpts: u32,
};

/// How long a top-level excerpt can be before its members become excerpts of their own (A5).
pub const split_above: usize = 40;

const ellipsis = "\u{2026}";

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r").len == 0;
}

fn indentOf(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return line[0..i];
}

fn isComment(line: []const u8) bool {
    const body = std.mem.trimStart(u8, line, " \t");
    return std.mem.startsWith(u8, body, "//") or std.mem.startsWith(u8, body, "/*") or
        std.mem.startsWith(u8, body, "*") or std.mem.startsWith(u8, body, "#!");
}

/// The title of a `// MARK: - Title` or `// MARK: Title` line (A3), or null.
fn markTitle(line: []const u8) ?[]const u8 {
    const body = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, body, "// MARK:")) return null;
    var rest = std.mem.trim(u8, body["// MARK:".len..], " \t");
    if (std.mem.startsWith(u8, rest, "-")) rest = std.mem.trim(u8, rest[1..], " \t");
    return rest;
}

/// A stretch of lines, `[first, last]`, that becomes one excerpt, or stays in its parent block
/// when it holds only comments.
const Item = struct { first: usize, last: usize };

/// Splits lines into items (A4, A5): an item starts at a line with no indent beyond `indent`,
/// that is not a closing brace, and follows a blank line. The first item starts at the first
/// non-blank line. Each item ends at its last non-blank line.
fn items(arena: Allocator, lines: []const []const u8, from: usize, to: usize, indent: []const u8) ![]const Item {
    var result: std.ArrayList(Item) = .empty;
    var start: ?usize = null;
    var last_text: usize = from;
    var after_blank = true;
    for (from..to) |i| {
        const line = lines[i];
        if (isBlank(line)) {
            after_blank = true;
            continue;
        }
        const starts = after_blank and std.mem.startsWith(u8, line, indent) and line.len > indent.len and
            line[indent.len] != ' ' and line[indent.len] != '\t' and line[indent.len] != '}' and line[indent.len] != ')';
        if (starts or start == null) {
            if (start) |s| try result.append(arena, .{ .first = s, .last = last_text });
            start = i;
        }
        last_text = i;
        after_blank = false;
    }
    if (start) |s| try result.append(arena, .{ .first = s, .last = last_text });
    return result.items;
}

const keywords = [_][]const u8{
    "pub",     "fn",          "const",    "var",       "let",       "func",     "struct",   "class",
    "actor",   "enum",        "protocol", "public",    "private",   "fileprivate", "internal", "open",
    "static",  "final",       "override", "mutating",  "nonmutating", "nonisolated", "export", "extern",
    "inline",  "noinline",    "comptime", "threadlocal", "async",   "throws",   "lazy",     "weak",
    "unowned", "convenience", "required", "indirect",  "typealias", "union",    "opaque",   "usingnamespace",
    "case",    "dynamic",     "package",  "consuming", "borrowing", "distributed", "import",
};

fn isKeyword(word: []const u8) bool {
    for (keywords) |k| if (std.mem.eql(u8, k, word)) return true;
    return false;
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// The name of an excerpt, from its first line that is not a comment or an attribute (A6).
fn nameOf(arena: Allocator, lines: []const []const u8, item: Item) ![]const u8 {
    for (lines[item.first .. item.last + 1]) |raw| {
        if (isBlank(raw) or isComment(raw)) continue;
        const line = std.mem.trim(u8, raw, " \t\r");
        // A test is named after its string.
        if (std.mem.startsWith(u8, line, "test \"")) {
            const end = std.mem.indexOfScalarPos(u8, line, 6, '"') orelse line.len;
            return try std.fmt.allocPrint(arena, "test {s}", .{line[6..end]});
        }
        var extension = false;
        var after_func = false;
        var i: usize = 0;
        while (i < line.len) {
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
            if (i >= line.len) break;
            // An attribute such as `@MainActor` or `@available(iOS 17, *)` is skipped whole.
            if (line[i] == '@') {
                i += 1;
                while (i < line.len and isNameChar(line[i])) i += 1;
                if (i < line.len and line[i] == '(') {
                    var depth: usize = 0;
                    while (i < line.len) : (i += 1) {
                        if (line[i] == '(') depth += 1;
                        if (line[i] == ')') {
                            depth -= 1;
                            if (depth == 0) {
                                i += 1;
                                break;
                            }
                        }
                    }
                }
                continue;
            }
            const start = i;
            if (isNameChar(line[i])) {
                while (i < line.len and isNameChar(line[i])) i += 1;
            } else if (after_func) {
                // An operator, such as `==` in `static func ==`.
                while (i < line.len and line[i] != ' ' and line[i] != '(' and line[i] != '\t') i += 1;
            } else break;
            const word = line[start..i];
            after_func = std.mem.eql(u8, word, "func");
            // Words such as `private(set)` carry their parentheses.
            if (i < line.len and line[i] == '(' and isKeyword(word)) {
                while (i < line.len and line[i] != ')') i += 1;
                i += 1;
            }
            if (std.mem.eql(u8, word, "extension")) {
                extension = true;
                continue;
            }
            if (isKeyword(word)) continue;
            if (word.len == 0) {
                i += 1;
                continue;
            }
            return if (extension) try std.fmt.allocPrint(arena, "extension {s}", .{word}) else word;
        }
        // A line of only attributes, such as `@MainActor`, is followed by the declaration.
        if (line.len > 0 and line[0] == '@') continue;
        break;
    }
    return "block";
}

/// A name that is not taken yet in the file: the name, or the name with a number.
fn unique(arena: Allocator, taken: *std.StringHashMapUnmanaged(void), name: []const u8) ![]const u8 {
    var candidate = name;
    var n: usize = 2;
    while (taken.contains(candidate)) : (n += 1) {
        candidate = try std.fmt.allocPrint(arena, "{s} {d}", .{ name, n });
    }
    try taken.put(arena, candidate, {});
    return candidate;
}

/// The asciidoc language of a file, from its extension, or null.
fn languageOf(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    const table = [_][2][]const u8{
        .{ ".zig", "zig" },  .{ ".swift", "swift" }, .{ ".c", "c" },         .{ ".h", "c" },
        .{ ".m", "objc" },   .{ ".cpp", "cpp" },     .{ ".hpp", "cpp" },     .{ ".rs", "rust" },
        .{ ".go", "go" },    .{ ".py", "python" },   .{ ".js", "javascript" }, .{ ".ts", "typescript" },
        .{ ".sh", "bash" },  .{ ".rb", "ruby" },     .{ ".java", "java" },   .{ ".kt", "kotlin" },
        .{ ".json", "json" }, .{ ".yml", "yaml" },   .{ ".yaml", "yaml" },   .{ ".toml", "toml" },
    };
    for (table) |entry| if (std.mem.eql(u8, ext, entry[0])) return entry[1];
    return null;
}

/// A7: a line of hyphens one longer than the longest line of only hyphens in the code.
fn delimiter(arena: Allocator, lines: []const []const u8) ![]const u8 {
    var longest: usize = 3;
    for (lines) |line| {
        const body = std.mem.trimEnd(u8, line, "\r");
        if (body.len == 0) continue;
        for (body) |c| {
            if (c != '-') break;
        } else longest = @max(longest, body.len);
    }
    const result = try arena.alloc(u8, longest + 1);
    @memset(result, '-');
    return result;
}

/// The output being built, with the blocks of one file that are still to be written.
const Writer = struct {
    arena: Allocator,
    out: std.ArrayList(u8) = .empty,
    excerpts: u32 = 0,

    fn print(self: *Writer, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(self.arena, fmt, args);
    }

    /// Writes a labeled block (A7).
    fn block(self: *Writer, name: ?[]const u8, path: []const u8, language: ?[]const u8, lines: []const []const u8) !void {
        if (name) |n| {
            try self.print("{s} {s} :file: {s}\n", .{ ellipsis, n, path });
            self.excerpts += 1;
        } else {
            try self.print("{s} :file: {s}\n", .{ ellipsis, path });
        }
        if (language) |l| try self.print("[source,{s}]\n", .{l});
        const delim = try delimiter(self.arena, lines);
        try self.print("{s}\n", .{delim});
        for (lines) |line| try self.print("{s}\n", .{line});
        try self.print("{s}\n\n", .{delim});
    }
};

/// A block to write after the file root, in order: a heading or an excerpt.
const Part = union(enum) {
    heading: []const u8,
    excerpt: struct { name: []const u8, lines: []const []const u8 },
};

/// A2: why a file cannot go into a document, or null.
fn problemOf(text: []const u8, lines: []const []const u8) ?struct { line: u32, reason: []const u8 } {
    if (text.len > 0 and text[text.len - 1] != '\n') {
        return .{ .line = @intCast(lines.len), .reason = "A2: the file does not end with a newline, and a tangled file always does (T3)" };
    }
    for (lines, 1..) |line, n| {
        const body = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, body, ellipsis ++ " ")) return .{ .line = @intCast(n), .reason = "A2: the line starts with an ellipsis, and would be read as an excerpt command (L4)" };
        if (std.mem.startsWith(u8, line, "include::")) return .{ .line = @intCast(n), .reason = "A2: the line starts with include::, which is not allowed in a labeled block (L6)" };
    }
    return null;
}

/// Adopts one file: its root block, and the parts that follow it.
fn adoptFile(w: *Writer, source: Source) !void {
    const arena = w.arena;
    const lines = try @import("scan.zig").splitLines(arena, source.text);
    const language = languageOf(source.path);
    var taken: std.StringHashMapUnmanaged(void) = .empty;
    var root: std.ArrayList([]const u8) = .empty;
    var parts: std.ArrayList(Part) = .empty;

    const top = try items(arena, lines, 0, lines.len, "");
    var at: usize = 0;
    for (top) |item| {
        // The blank lines between items stay in the root.
        while (at < item.first) : (at += 1) try root.append(arena, lines[at]);
        at = item.last + 1;
        const body = lines[item.first .. item.last + 1];

        // An item of only comments stays in the root, and a MARK line is a heading (A3).
        var only_comments = true;
        for (body) |line| if (!isBlank(line) and !isComment(line)) {
            only_comments = false;
        };
        if (only_comments) {
            for (body) |line| {
                try root.append(arena, line);
                if (markTitle(line)) |title| try parts.append(arena, .{ .heading = title });
            }
            continue;
        }
        if (markTitle(body[0])) |title| try parts.append(arena, .{ .heading = title });

        const name = try unique(arena, &taken, try nameOf(arena, lines, item));
        try root.append(arena, try std.fmt.allocPrint(arena, "{s} {s}", .{ ellipsis, name }));
        try splitItem(arena, &parts, &taken, lines, item, name);
    }
    while (at < lines.len) : (at += 1) try root.append(arena, lines[at]);

    try w.print("== {s}\n\n", .{source.path});
    try w.block(null, source.path, language, root.items);
    for (parts.items) |part| switch (part) {
        .heading => |title| try w.print("=== {s}\n\n", .{title}),
        .excerpt => |e| try w.block(e.name, source.path, language, e.lines),
    };
}

/// A5: a long item in braces is split one level deeper. Otherwise it is one excerpt.
fn splitItem(arena: Allocator, parts: *std.ArrayList(Part), taken: *std.StringHashMapUnmanaged(void), lines: []const []const u8, item: Item, name: []const u8) !void {
    const whole = lines[item.first .. item.last + 1];
    // The declaration's first line, past the comments and attributes above it.
    var open = item.first;
    while (open < item.last and (isComment(lines[open]) or std.mem.startsWith(u8, std.mem.trim(u8, lines[open], " \t\r"), "@"))) open += 1;
    const opens = std.mem.endsWith(u8, std.mem.trimEnd(u8, lines[open], " \t\r"), "{");
    const close = std.mem.trimEnd(u8, lines[item.last], " \t\r");
    const closes = std.mem.eql(u8, close, "}") or std.mem.eql(u8, close, "};");
    if (whole.len <= split_above or !opens or !closes or open + 1 >= item.last) {
        try parts.append(arena, .{ .excerpt = .{ .name = name, .lines = whole } });
        return;
    }
    var first_text = open + 1;
    while (first_text < item.last and isBlank(lines[first_text])) first_text += 1;
    const indent = indentOf(lines[first_text]);
    // Every line of the body must have the indent, or be blank, or the split is not safe.
    for (lines[open + 1 .. item.last]) |line| {
        if (!isBlank(line) and !std.mem.startsWith(u8, line, indent)) {
            try parts.append(arena, .{ .excerpt = .{ .name = name, .lines = whole } });
            return;
        }
    }
    if (indent.len == 0) {
        try parts.append(arena, .{ .excerpt = .{ .name = name, .lines = whole } });
        return;
    }

    const type_name = if (std.mem.startsWith(u8, name, "extension ")) name["extension ".len..] else name;
    const members = try items(arena, lines, open + 1, item.last, indent);
    var parent: std.ArrayList([]const u8) = .empty;
    var children: std.ArrayList(Part) = .empty;
    for (lines[item.first .. open + 1]) |line| try parent.append(arena, line);
    var at = open + 1;
    for (members) |member| {
        while (at < member.first) : (at += 1) try parent.append(arena, lines[at]);
        at = member.last + 1;
        const body = lines[member.first .. member.last + 1];
        var only_comments = true;
        for (body) |line| if (!isBlank(line) and !isComment(line)) {
            only_comments = false;
        };
        if (only_comments) {
            for (body) |line| {
                try parent.append(arena, line);
                if (markTitle(line)) |title| try children.append(arena, .{ .heading = title });
            }
            continue;
        }
        if (markTitle(body[0])) |title| try children.append(arena, .{ .heading = title });
        const member_name = try unique(arena, taken, try std.fmt.allocPrint(arena, "{s}.{s}", .{ type_name, try nameOf(arena, lines, member) }));
        try parent.append(arena, try std.fmt.allocPrint(arena, "{s}{s} {s}", .{ indent, ellipsis, member_name }));
        const dedented = try arena.alloc([]const u8, body.len);
        for (body, dedented) |line, *d| d.* = if (isBlank(line) and line.len < indent.len) line else line[indent.len..];
        try children.append(arena, .{ .excerpt = .{ .name = member_name, .lines = dedented } });
    }
    while (at <= item.last) : (at += 1) try parent.append(arena, lines[at]);
    try parts.append(arena, .{ .excerpt = .{ .name = name, .lines = parent.items } });
    try parts.appendSlice(arena, children.items);
}

/// The document for the given files (A3 to A8). Files that cannot be adopted are refused,
/// and then there is no document.
pub fn adopt(arena: Allocator, sources: []const Source, options: Options) !Result {
    var refusals: std.ArrayList(Refusal) = .empty;
    for (sources) |source| {
        const lines = try @import("scan.zig").splitLines(arena, source.text);
        if (problemOf(source.text, lines)) |p| try refusals.append(arena, .{ .path = source.path, .line = p.line, .reason = p.reason });
    }
    if (refusals.items.len > 0) return .{ .text = "", .refusals = refusals.items, .excerpts = 0 };

    var w: Writer = .{ .arena = arena };
    try w.print("= {s}\n", .{options.title});
    if (options.style) |style| try w.print(":litmus-style: {s}\n", .{style});
    if (options.companion) try w.print(":litmus-companion:\n", .{});
    try w.print(":toc: left\n:toclevels: 3\n:sectanchors:\n\n", .{});
    try w.print("This document was made by `litmus adopt` from {d} {s}. Each file is a section, with its code split into excerpts at its declarations. The excerpts can be moved into the order that explains the code best, and the prose goes between them.\n\n", .{ sources.len, if (sources.len == 1) "file" else "files" });
    for (sources) |source| try adoptFile(&w, source);
    return .{ .text = w.out.items, .refusals = &.{}, .excerpts = w.excerpts };
}

// Tests ----------------------------------------------------------------------

const t = std.testing;
const scan = @import("scan.zig");
const types = @import("types.zig");
const parse = @import("parse.zig");
const resolve = @import("resolve.zig");
const tangle = @import("tangle.zig");

/// Adopts the files, then tangles the document and requires every file back, byte for byte (A8).
fn expectRoundTrip(a: Allocator, sources: []const Source) ![]const u8 {
    const result = try adopt(a, sources, .{ .title = "Test" });
    try t.expectEqual(0, result.refusals.len);
    var diags = types.Diagnostics.init(a);
    const doc: types.Document = .{ .path = "d.adoc", .format = .asciidoc, .lines = try scan.splitLines(a, result.text), .dir = "" };
    const parsed = try parse.parse(a, 0, doc, &diags);
    const resolved = try resolve.resolve(a, try a.dupe(types.Document, &.{doc}), parsed.blocks, &diags);
    if (diags.list.items.len > 0) {
        for (diags.list.items) |d| std.debug.print("{d}: {s}\n", .{ d.line, d.message });
        std.debug.print("{s}\n", .{result.text});
        return error.Diagnostics;
    }
    const files = try tangle.tangleAll(a, resolved);
    for (sources) |source| {
        const file = for (files) |f| {
            if (std.mem.eql(u8, f.path, source.path)) break f;
        } else return error.FileMissing;
        try t.expectEqualStrings(source.text, file.text);
    }
    return result.text;
}

const swift_sample =
    \\// A refund service.
    \\import Foundation
    \\
    \\// MARK: - Errors
    \\
    \\enum RefundError: Error {
    \\    case declined
    \\}
    \\
    \\/// Retries refunds.
    \\@MainActor
    \\public final class RefundService {
    \\    private(set) var attempts = 0
    \\    let limit: Int
    \\
    \\    init(limit: Int) {
    \\        self.limit = limit
    \\        self.attempts = 0
    \\        self.attempts = 0
    \\        self.attempts = 0
    \\        self.attempts = 0
    \\        self.attempts = 0
    \\        self.attempts = 0
    \\        self.attempts = 0
    \\        self.attempts = 0
    \\        self.attempts = 0
    \\        self.attempts = 0
    \\    }
    \\
    \\    // MARK: Retrying
    \\
    \\    /// Tries again.
    \\    func retry(_ id: String) async throws -> Bool {
    \\        attempts += 1
    \\        if attempts > limit { throw RefundError.declined }
    \\        return true
    \\    }
    \\
    \\    static func == (a: RefundService, b: RefundService) -> Bool {
    \\        return a.limit == b.limit
    \\    }
    \\
    \\    func reset() {
    \\        attempts = 0
    \\    }
    \\
    \\    func reset(to n: Int) {
    \\        attempts = n
    \\    }
    \\
    \\}
    \\
    \\extension RefundService: CustomStringConvertible {
    \\    var description: String { "refunds" }
    \\}
    \\
    \\actor Ledger {
    \\    var entries: [String] = []
    \\}
    \\
;

test "A4, A5, A6: a Swift file is split at its declarations, and long types at their members" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = try expectRoundTrip(a, &.{.{ .path = "Sources/Refund.swift", .text = swift_sample }});
    const want = [_][]const u8{
        ellipsis ++ " RefundError :file: Sources/Refund.swift",
        ellipsis ++ " RefundService :file: Sources/Refund.swift",
        ellipsis ++ " RefundService.attempts :file: Sources/Refund.swift",
        ellipsis ++ " RefundService.init :file: Sources/Refund.swift",
        ellipsis ++ " RefundService.retry :file: Sources/Refund.swift",
        ellipsis ++ " RefundService.== :file: Sources/Refund.swift",
        ellipsis ++ " RefundService.reset :file: Sources/Refund.swift",
        ellipsis ++ " RefundService.reset 2 :file: Sources/Refund.swift",
        ellipsis ++ " extension RefundService :file: Sources/Refund.swift",
        ellipsis ++ " Ledger :file: Sources/Refund.swift",
        "    " ++ ellipsis ++ " RefundService.retry",
        "=== Errors",
        "=== Retrying",
        "[source,swift]",
    };
    for (want) |w| {
        if (std.mem.indexOf(u8, text, w) == null) {
            std.debug.print("missing: {s}\n{s}\n", .{ w, text });
            return error.Missing;
        }
    }
}

test "A4, A5, A6: a Zig file, with a long struct, functions and tests" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "//! A counter.\n\nconst std = @import(\"std\");\n\npub const Counter = struct {\n    n: u32 = 0,\n\n");
    for (0..12) |i| try src.print(a, "    pub fn add{d}(self: *Counter) void {{\n        self.n += {d};\n    }}\n\n", .{ i, i });
    try src.appendSlice(a, "};\n\nfn helper() void {}\n\ntest \"counting works\" {\n    var c: Counter = .{};\n    c.add1();\n}\n");
    const text = try expectRoundTrip(a, &.{.{ .path = "src/counter.zig", .text = src.items }});
    const want = [_][]const u8{
        ellipsis ++ " Counter :file: src/counter.zig",
        ellipsis ++ " Counter.n :file: src/counter.zig",
        ellipsis ++ " Counter.add11 :file: src/counter.zig",
        ellipsis ++ " helper :file: src/counter.zig",
        ellipsis ++ " test counting works :file: src/counter.zig",
        ellipsis ++ " std :file: src/counter.zig",
    };
    for (want) |w| {
        if (std.mem.indexOf(u8, text, w) == null) {
            std.debug.print("missing: {s}\n{s}\n", .{ w, text });
            return error.Missing;
        }
    }
}

test "A8: odd files still come back byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    _ = try expectRoundTrip(a, &.{
        .{ .path = "empty.txt", .text = "" },
        .{ .path = "blank.txt", .text = "\n\n\n" },
        .{ .path = "no-blank-lines.c", .text = "int a;\nint b;\nint c;\n" },
        .{ .path = "crlf.c", .text = "int a;\r\n\r\nint b;\r\n" },
        .{ .path = "hyphens.lua", .text = "-- a\n----\n\n------\nx = 1\n" },
        .{ .path = "comments.swift", .text = "// only\n// comments\n\n// MARK: - Part\n\nlet x = 1\n" },
        .{ .path = "leading.swift", .text = "\n\nlet x = 1\n\n\n" },
        .{ .path = "dir/same.zig", .text = "fn a() void {}\n\nfn a() void {}\n" },
    });
}

test "A5: a long type whose body is not indented the same is not split" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "struct S {\n");
    for (0..45) |i| try src.print(a, "    var v{d} = 0\n\n", .{i});
    try src.appendSlice(a, "#if DEBUG\n    var debug = true\n#endif\n}\n");
    const text = try expectRoundTrip(a, &.{.{ .path = "S.swift", .text = src.items }});
    try t.expect(std.mem.indexOf(u8, text, "S.v0") == null);
}

test "A2: files that cannot go into a document are refused" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const result = try adopt(a, &.{
        .{ .path = "a.txt", .text = "no newline" },
        .{ .path = "b.txt", .text = "x\n  " ++ ellipsis ++ " y\n" },
        .{ .path = "c.adoc", .text = "include::x[]\n" },
        .{ .path = "fine.txt", .text = "fine\n" },
    }, .{ .title = "T" });
    try t.expectEqual(3, result.refusals.len);
    try t.expectEqual(2, result.refusals[1].line);
    try t.expectEqual(0, result.text.len);
}

test "A8: the style and the companion mark go in the header" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const result = try adopt(a, &.{.{ .path = "x.zig", .text = "const x = 1;\n" }}, .{ .title = "X", .style = "brief.md", .companion = true });
    try t.expect(std.mem.startsWith(u8, result.text, "= X\n:litmus-style: brief.md\n:litmus-companion:\n"));
}

test "A6: names" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_][2][]const u8{
        .{ "pub fn main() !void {", "main" },
        .{ "pub const Scanner = struct {", "Scanner" },
        .{ "@available(iOS 17, *) public struct View: Sendable {", "View" },
        .{ "nonisolated(unsafe) static var shared = X()", "shared" },
        .{ "private(set) var count = 0", "count" },
        .{ "extension Array where Element: Equatable {", "extension Array" },
        .{ "comptime {", "block" },
        .{ "/// doc\nfunc go() {}", "go" },
    };
    for (cases) |c| {
        const lines = try scan.splitLines(a, c[0]);
        try t.expectEqualStrings(c[1], try nameOf(a, lines, .{ .first = 0, .last = lines.len - 1 }));
    }
}
