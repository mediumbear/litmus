//! The `init` command (I1 to I4): prepares a project so that agents find the guide.

const std = @import("std");
const output = @import("output.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Args = struct {
    /// How Litmus was run: argv[0].
    exe: []const u8,
    /// The `-o` directory, "." by default.
    dir: []const u8,
    documents: []const []const u8,
};

/// I5: the skill for making documents, as it comes with Litmus, and where init puts it.
pub const skill_text = @embedFile("skill.md");
pub const skill_path = ".claude/skills/litmus-document/SKILL.md";

const start_marker = "<!-- litmus -->";
const end_marker = "<!-- /litmus -->";

/// The directory without a trailing slash, or null for the current directory.
fn outputDir(dir: []const u8) ?[]const u8 {
    var d = dir;
    while (std.mem.endsWith(u8, d, "/")) d = d[0 .. d.len - 1];
    while (std.mem.startsWith(u8, d, "./")) d = d[2..];
    if (d.len == 0 or std.mem.eql(u8, d, ".")) return null;
    return d;
}

/// The paragraph of I1, with its two comment lines and a `\n` at the end.
pub fn paragraph(arena: Allocator, args: Args) ![]const u8 {
    const exe = if (std.mem.indexOfScalar(u8, args.exe, '/') != null) args.exe else "litmus";
    const dir = outputDir(args.dir);
    const flag = if (dir) |d| try std.fmt.allocPrint(arena, " -o {s}", .{d}) else "";
    const map_dir = if (dir) |d| try std.fmt.allocPrint(arena, "{s}/", .{d}) else "";
    const documents = try std.mem.join(arena, " ", args.documents);
    return std.fmt.allocPrint(arena,
        \\{s}
        \\This project uses Litmus: some source files are tangled from documents that
        \\explain them. Run `{s} guide` before changing any file listed in
        \\{s}.litmus/map. After editing a tangled file, carry the change into the
        \\documents with `{s} untangle{s} {s}`, and write the prose it asks for.
        \\Tangle with `{s} tangle{s} {s}`, and make sure
        \\`{s} check{s} {s}` passes before finishing.
        \\{s}
        \\
    , .{ start_marker, exe, map_dir, exe, flag, documents, exe, flag, documents, exe, flag, documents, end_marker });
}

/// The text with a final `\n`, and `addition` after it.
fn appended(arena: Allocator, existing: []const u8, addition: []const u8) ![]const u8 {
    const newline: []const u8 = if (existing.len > 0 and existing[existing.len - 1] != '\n') "\n" else "";
    return std.mem.concat(arena, u8, &.{ existing, newline, addition });
}

/// Finds a line of `text` that equals `marker` once trimmed: the offset of its start and of its end, past the `\n`.
fn findLine(text: []const u8, marker: []const u8, from: usize) ?struct { start: usize, end: usize } {
    var start = from;
    while (start < text.len) {
        const newline = std.mem.indexOfScalarPos(u8, text, start, '\n');
        const end = if (newline) |n| n + 1 else text.len;
        const line = std.mem.trim(u8, text[start..end], " \t\r\n");
        if (std.mem.eql(u8, line, marker)) return .{ .start = start, .end = end };
        start = end;
    }
    return null;
}

pub const AgentsError = error{UnclosedParagraph} || Allocator.Error;

/// The new text of AGENTS.md (I1), or null when it stays as it is.
pub fn applyAgents(arena: Allocator, existing: ?[]const u8, para: []const u8) AgentsError!?[]const u8 {
    const text = existing orelse return para;
    var result: []const u8 = undefined;
    if (findLine(text, start_marker, 0)) |start| {
        const end = findLine(text, end_marker, start.end) orelse return error.UnclosedParagraph;
        result = try std.mem.concat(arena, u8, &.{ text[0..start.start], para, text[end.end..] });
    } else {
        result = try appended(arena, text, if (text.len > 0) try std.mem.concat(arena, u8, &.{ "\n", para }) else para);
    }
    return if (std.mem.eql(u8, result, text)) null else result;
}

fn hasLine(text: []const u8, wanted: []const []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        for (wanted) |w| if (std.mem.eql(u8, trimmed, w)) return true;
    }
    return false;
}

/// The new text of CLAUDE.md (I2), or null when it stays as it is.
pub fn applyClaude(arena: Allocator, existing: ?[]const u8) !?[]const u8 {
    const text = existing orelse return "@AGENTS.md\n";
    if (hasLine(text, &.{"@AGENTS.md"})) return null;
    return try appended(arena, text, "@AGENTS.md\n");
}

/// The entry I3 adds to .gitignore.
pub fn ignoreEntry(arena: Allocator, dir: []const u8) ![]const u8 {
    const d = outputDir(dir) orelse return ".litmus/";
    return std.fmt.allocPrint(arena, "{s}/.litmus/", .{d});
}

/// The new text of .gitignore (I3), or null when it stays as it is.
pub fn applyGitignore(arena: Allocator, existing: ?[]const u8, entry: []const u8) !?[]const u8 {
    const line = try std.mem.concat(arena, u8, &.{ entry, "\n" });
    const text = existing orelse return line;
    const bare = std.mem.trimEnd(u8, entry, "/");
    const rooted = try std.mem.concat(arena, u8, &.{ "/", entry });
    const rooted_bare = try std.mem.concat(arena, u8, &.{ "/", bare });
    if (hasLine(text, &.{ entry, bare, rooted, rooted_bare })) return null;
    return try appended(arena, text, line);
}

/// Runs init in the current directory, printing each change to `out`. Returns the exit code.
pub fn run(io: Io, arena: Allocator, args: Args, out: *Io.Writer, err: *Io.Writer) !u8 {
    const cwd = Io.Dir.cwd();
    const entry = try ignoreEntry(arena, args.dir);
    const para = try paragraph(arena, args);
    var failed = false;

    const names = [_][]const u8{ "AGENTS.md", "CLAUDE.md", ".gitignore" };
    for (names) |name| {
        const existing = try output.readOrNull(io, arena, cwd, name);
        const updated: ?[]const u8 = if (std.mem.eql(u8, name, "AGENTS.md"))
            applyAgents(arena, existing, para) catch |e| switch (e) {
                error.UnclosedParagraph => {
                    try err.print("{s}: has \"{s}\" but no \"{s}\" after it\n", .{ name, start_marker, end_marker });
                    failed = true;
                    continue;
                },
                else => return e,
            }
        else if (std.mem.eql(u8, name, "CLAUDE.md"))
            try applyClaude(arena, existing)
        else
            try applyGitignore(arena, existing, entry);
        const text = updated orelse continue;
        try output.writeAtomic(io, cwd, name, text, false);
        try out.print("{s} {s}\n", .{ if (existing == null) "created" else "updated", name });
    }
    // I5: the skill is Litmus's own, so an older one is replaced.
    const existing_skill = try output.readOrNull(io, arena, cwd, skill_path);
    if (existing_skill == null or !std.mem.eql(u8, existing_skill.?, skill_text)) {
        try output.writeAtomic(io, cwd, skill_path, skill_text, false);
        try out.print("{s} {s}\n", .{ if (existing_skill == null) "created" else "updated", skill_path });
    }
    return if (failed) 1 else 0;
}

// Tests ----------------------------------------------------------------------

const t = std.testing;

fn testArgs(dir: []const u8, exe: []const u8) Args {
    return .{ .exe = exe, .dir = dir, .documents = &.{ "doc/a.adoc", "doc/b.md" } };
}

test "I1: the paragraph names the directory and the documents" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqualStrings(
        \\<!-- litmus -->
        \\This project uses Litmus: some source files are tangled from documents that
        \\explain them. Run `litmus guide` before changing any file listed in
        \\.litmus/map. After editing a tangled file, carry the change into the
        \\documents with `litmus untangle doc/a.adoc doc/b.md`, and write the prose it asks for.
        \\Tangle with `litmus tangle doc/a.adoc doc/b.md`, and make sure
        \\`litmus check doc/a.adoc doc/b.md` passes before finishing.
        \\<!-- /litmus -->
        \\
    , try paragraph(a, testArgs(".", "litmus")));
    const other = try paragraph(a, testArgs("out/", "tools/litmus"));
    try t.expect(std.mem.indexOf(u8, other, "Run `tools/litmus guide` before") != null);
    try t.expect(std.mem.indexOf(u8, other, "documents with `tools/litmus untangle -o out doc/a.adoc doc/b.md`") != null);
    try t.expect(std.mem.indexOf(u8, other, "Tangle with `tools/litmus tangle -o out doc/a.adoc doc/b.md`") != null);
    try t.expect(std.mem.indexOf(u8, other, "`tools/litmus check -o out doc/a.adoc doc/b.md` passes") != null);
}

test "I1: AGENTS.md is created, added to, and updated in place" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const para = try paragraph(a, testArgs(".", "litmus"));
    try t.expectEqualStrings(para, (try applyAgents(a, null, para)).?);
    const added = (try applyAgents(a, "# Notes\n\nSome text.", para)).?;
    try t.expectEqualStrings("# Notes\n\nSome text.\n\n", added[0 .. added.len - para.len]);
    try t.expectEqualStrings(para, added[added.len - para.len ..]);
    // Twice changes nothing.
    try t.expect(try applyAgents(a, added, para) == null);
    // An old paragraph is replaced, and what is around it stays.
    const old = "top\n<!-- litmus -->\nold words\n<!-- /litmus -->\nbottom\n";
    const new_para = try paragraph(a, testArgs("out", "litmus"));
    const replaced = (try applyAgents(a, old, new_para)).?;
    try t.expectEqualStrings(try std.mem.concat(a, u8, &.{ "top\n", new_para, "bottom\n" }), replaced);
    try t.expectError(error.UnclosedParagraph, applyAgents(a, "<!-- litmus -->\nx\n", para));
    try t.expectEqualStrings(para, (try applyAgents(a, "", para)).?);
}

test "I2: CLAUDE.md imports AGENTS.md once" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqualStrings("@AGENTS.md\n", (try applyClaude(a, null)).?);
    try t.expectEqualStrings("Hello\n@AGENTS.md\n", (try applyClaude(a, "Hello")).?);
    try t.expect(try applyClaude(a, "Hello\n  @AGENTS.md  \nmore\n") == null);
    try t.expect(try applyClaude(a, "@AGENTS.md") == null);
}

test "I3: .gitignore gets the directory once" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqualStrings(".litmus/", try ignoreEntry(a, "."));
    try t.expectEqualStrings("out/.litmus/", try ignoreEntry(a, "out/"));
    try t.expectEqualStrings(".litmus/\n", (try applyGitignore(a, null, ".litmus/")).?);
    try t.expectEqualStrings("zig-out\n.litmus/\n", (try applyGitignore(a, "zig-out", ".litmus/")).?);
    try t.expect(try applyGitignore(a, "x\n.litmus/\n", ".litmus/") == null);
    try t.expect(try applyGitignore(a, "x\n/.litmus\n", ".litmus/") == null);
    try t.expectEqualStrings(".litmus/\nout/.litmus/\n", (try applyGitignore(a, ".litmus/\n", "out/.litmus/")).?);
}
