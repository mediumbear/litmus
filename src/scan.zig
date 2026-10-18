//! Classifies the lines of one document, asciidoc or Markdown. It follows the
//! block structure (L5, M1, M3) but knows nothing of labels: the parser decides
//! what a command or a block means. No IO.

const std = @import("std");

pub const Format = enum { asciidoc, markdown };

pub const Kind = enum {
    /// Text outside any block.
    prose,
    /// A Litmus command outside code blocks: a document command.
    command,
    /// A block attribute line such as `[source,zig]` (asciidoc only).
    attribute,
    /// A block title line such as `.The loop` (asciidoc only).
    title,
    /// An `include::` line outside any block (asciidoc only).
    include,
    /// A `:litmus-dir:` entry (L8, M5).
    dir,
    /// A `:litmus-style:` entry (L10).
    style,
    /// A `:litmus-companion:` entry (L11).
    companion,
    /// The line that opens a code block.
    open,
    /// The line that closes a code block.
    close,
    /// A line inside a code block. It may hold a Litmus command, and the parser
    /// decides what that means.
    code,
    /// A line that Litmus never reads (L5, M3): comment lines and blocks, literal
    /// and passthrough blocks, HTML comments.
    skip,
};

const State = enum { prose, listing, fenced, literal, comment, passthrough, html_comment };

/// A Litmus command line: the bytes before the ellipsis, and the text after it.
pub const Command = struct { indent: []const u8, text: []const u8 };

const ellipsis = "\u{2026} ";

/// The Litmus command a line holds, if it is one: after any spaces and tabs, the
/// ellipsis and a space.
pub fn commandOf(line: []const u8) ?Command {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (!std.mem.startsWith(u8, line[i..], ellipsis)) return null;
    return .{ .indent = line[0..i], .text = line[i + ellipsis.len ..] };
}

/// Splits a document into lines at `\n` (L7). A final line without `\n` is a line.
/// A final `\n` does not start another.
pub fn splitLines(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    const count = std.mem.countScalar(u8, text, '\n') + @intFromBool(text.len > 0 and text[text.len - 1] != '\n');
    const lines = try arena.alloc([]const u8, count);
    var start: usize = 0;
    for (lines) |*line| {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        line.* = text[start..end];
        start = end + 1;
    }
    return lines;
}

pub const Scanner = struct {
    format: Format,
    state: State = .prose,
    /// The line that opened the current asciidoc block, which only an equal line closes.
    delim: []const u8 = "",
    /// The character and length of a Markdown fence.
    fence_char: u8 = 0,
    fence_len: usize = 0,

    pub fn init(format: Format) Scanner {
        return .{ .format = format };
    }

    /// True while a code block is open: at the end of a document, that is C6.
    pub fn inCodeBlock(self: *const Scanner) bool {
        return self.state == .listing or self.state == .fenced;
    }

    pub fn next(self: *Scanner, line: []const u8) Kind {
        return switch (self.format) {
            .asciidoc => self.nextAsciidoc(line),
            .markdown => self.nextMarkdown(line),
        };
    }

    fn nextAsciidoc(self: *Scanner, line: []const u8) Kind {
        switch (self.state) {
            .prose => {},
            .listing, .literal, .comment, .passthrough => {
                if (std.mem.eql(u8, line, self.delim)) {
                    const was_code = self.state == .listing;
                    self.state = .prose;
                    return if (was_code) .close else .skip;
                }
                return if (self.state == .listing) .code else .skip;
            },
            .fenced => {
                if (std.mem.eql(u8, line, "```")) {
                    self.state = .prose;
                    return .close;
                }
                return .code;
            },
            .html_comment => unreachable,
        }
        if (std.mem.startsWith(u8, line, "//")) {
            if (isDelimiter(line, '/')) {
                self.enter(.comment, line);
            }
            return .skip;
        }
        if (isDelimiter(line, '-')) {
            self.enter(.listing, line);
            return .open;
        }
        if (isDelimiter(line, '.')) {
            self.enter(.literal, line);
            return .skip;
        }
        if (isDelimiter(line, '+')) {
            self.enter(.passthrough, line);
            return .skip;
        }
        if (std.mem.startsWith(u8, line, "```") and std.mem.indexOfScalar(u8, line[3..], '`') == null) {
            self.state = .fenced;
            return .open;
        }
        if (commandOf(line) != null) return .command;
        if (std.mem.startsWith(u8, line, "include::")) return .include;
        if (std.mem.startsWith(u8, line, ":litmus-dir:")) return .dir;
        if (std.mem.startsWith(u8, line, ":litmus-style:")) return .style;
        if (std.mem.startsWith(u8, line, ":litmus-companion:")) return .companion;
        if (line.len >= 2 and line[0] == '[' and line[line.len - 1] == ']') return .attribute;
        if (line.len >= 2 and line[0] == '.' and line[1] != '.' and line[1] != ' ' and line[1] != '\t') return .title;
        return .prose;
    }

    fn enter(self: *Scanner, state: State, line: []const u8) void {
        self.state = state;
        self.delim = line;
    }

    fn nextMarkdown(self: *Scanner, line: []const u8) Kind {
        switch (self.state) {
            .prose => {},
            .fenced => {
                if (isFence(line)) |fence| {
                    if (fence.char == self.fence_char and fence.len >= self.fence_len and fence.rest.len == 0) {
                        self.state = .prose;
                        return .close;
                    }
                }
                return .code;
            },
            .html_comment => {
                if (std.mem.indexOf(u8, line, "-->") != null) self.state = .prose;
                return .skip;
            },
            else => unreachable,
        }
        if (isFence(line)) |fence| {
            const backtick_in_info = fence.char == '`' and std.mem.indexOfScalar(u8, fence.rest, '`') != null;
            if (!backtick_in_info) {
                self.state = .fenced;
                self.fence_char = fence.char;
                self.fence_len = fence.len;
                return .open;
            }
        }
        if (commandOf(line) != null) return .command;
        if (markdownDir(line) != null) return .dir;
        if (markdownEntry(line, ":litmus-style:") != null) return .style;
        if (markdownEntry(line, ":litmus-companion:") != null) return .companion;
        if (std.mem.indexOf(u8, line, "<!--")) |at| {
            const rest = line[at + 4 ..];
            if (std.mem.indexOf(u8, rest, "-->") == null) self.state = .html_comment;
            if (std.mem.trim(u8, line[0..at], " \t").len == 0) return .skip;
        }
        return .prose;
    }
};

/// A line of at least four of `char` and nothing else.
fn isDelimiter(line: []const u8, char: u8) bool {
    if (line.len < 4) return false;
    for (line) |c| if (c != char) return false;
    return true;
}

const Fence = struct { char: u8, len: usize, rest: []const u8 };

/// A Markdown fence line: up to three spaces, then three or more backticks or tildes.
fn isFence(line: []const u8) ?Fence {
    var i: usize = 0;
    while (i < line.len and i < 3 and line[i] == ' ') i += 1;
    if (i >= line.len or (line[i] != '`' and line[i] != '~')) return null;
    const char = line[i];
    var j = i;
    while (j < line.len and line[j] == char) j += 1;
    if (j - i < 3) return null;
    return .{ .char = char, .len = j - i, .rest = std.mem.trim(u8, line[j..], " \t") };
}

/// The directory in a line `<!-- :litmus-dir: src/core -->` (M5).
pub fn markdownDir(line: []const u8) ?[]const u8 {
    return markdownEntry(line, ":litmus-dir:");
}

/// The value of an entry such as `<!-- :litmus-style: style.md -->` in Markdown.
pub fn markdownEntry(line: []const u8, name: []const u8) ?[]const u8 {
    const body = std.mem.trim(u8, line, " \t");
    if (!std.mem.startsWith(u8, body, "<!--") or !std.mem.endsWith(u8, body, "-->")) return null;
    const inner = std.mem.trim(u8, body[4 .. body.len - 3], " \t");
    if (!std.mem.startsWith(u8, inner, name)) return null;
    return std.mem.trim(u8, inner[name.len..], " \t");
}

/// The directory in an asciidoc line `:litmus-dir: src/core` (L8).
pub fn asciidocDir(line: []const u8) []const u8 {
    return asciidocEntry(line, ":litmus-dir:");
}

/// The value of an asciidoc entry such as `:litmus-style: style.md`.
pub fn asciidocEntry(line: []const u8, name: []const u8) []const u8 {
    return std.mem.trim(u8, line[name.len..], " \t");
}

fn expectKinds(format: Format, text: []const u8, expected: []const Kind) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const lines = try splitLines(arena_state.allocator(), text);
    try std.testing.expectEqual(expected.len, lines.len);
    var scanner = Scanner.init(format);
    for (lines, expected, 0..) |line, want, i| {
        const got = scanner.next(line);
        std.testing.expectEqual(want, got) catch |err| {
            std.debug.print("line {d} {s}: wanted {s}, got {s}\n", .{ i + 1, line, @tagName(want), @tagName(got) });
            return err;
        };
    }
}

test "splitLines (L7): \\r stays in the line, a final \\n starts no line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const lines = try splitLines(arena_state.allocator(), "a\r\nb\n\nc");
    try std.testing.expectEqual(4, lines.len);
    try std.testing.expectEqualStrings("a\r", lines[0]);
    try std.testing.expectEqualStrings("", lines[2]);
    try std.testing.expectEqualStrings("c", lines[3]);
    try std.testing.expectEqual(0, (try splitLines(arena_state.allocator(), "")).len);
    try std.testing.expectEqual(1, (try splitLines(arena_state.allocator(), "x\n")).len);
}

test "commandOf (Terms): indent, ellipsis, space" {
    const c = commandOf("\t  \u{2026} name :file: a.zig").?;
    try std.testing.expectEqualStrings("\t  ", c.indent);
    try std.testing.expectEqualStrings("name :file: a.zig", c.text);
    try std.testing.expect(commandOf("\u{2026}name") == null);
    try std.testing.expect(commandOf("\u{2026}") == null);
    try std.testing.expect(commandOf("... name") == null);
    try std.testing.expect(commandOf("x \u{2026} name") == null);
}

test "L2: attribute and title lines sit between a label and its block" {
    try expectKinds(.asciidoc,
        \\… :file: a.zig
        \\.The loop
        \\[source,zig]
        \\----
        \\code
        \\----
        \\.. not a title
        \\. nor this
    , &.{ .command, .title, .attribute, .open, .code, .close, .prose, .prose });
}

test "L4: a command in a block is code to the scanner, and a command outside is a command" {
    try expectKinds(.asciidoc,
        \\… :file: a.zig
        \\----
        \\  … body
        \\----
    , &.{ .command, .open, .code, .close });
}

test "L5: commands are ignored in literal, comment and passthrough blocks and on comment lines" {
    try expectKinds(.asciidoc,
        \\....
        \\… a :file: x
        \\....
        \\////
        \\… a :file: x
        \\////
        \\++++
        \\… a :file: x
        \\++++
        \\// … a :file: x
        \\… a :file: x
    , &.{ .skip, .skip, .skip, .skip, .skip, .skip, .skip, .skip, .skip, .skip, .command });
}

test "L5: a longer delimiter holds a shorter one, and only an equal line closes" {
    try expectKinds(.asciidoc,
        \\-----
        \\----
        \\… x
        \\-----
        \\… y
    , &.{ .open, .code, .code, .close, .command });
    try expectKinds(.asciidoc,
        \\....
        \\----
        \\.....
        \\....
        \\----
    , &.{ .skip, .skip, .skip, .skip, .open });
}

test "L1: fenced blocks in asciidoc" {
    try expectKinds(.asciidoc,
        \\```zig
        \\----
        \\… x
        \\```
        \\`code` and ```` more
    , &.{ .open, .code, .code, .close, .prose });
}

test "L7: a \\r stays part of the line, so it does not close a block" {
    try expectKinds(.asciidoc, "----\r\ncode\r\n----\r\n", &.{ .prose, .prose, .prose });
    try expectKinds(.asciidoc, "----\ncode\r\n----\n", &.{ .open, .code, .close });
}

test "include and dir lines" {
    try expectKinds(.asciidoc,
        \\:litmus-dir: src/core
        \\include::a.adoc[]
        \\----
        \\include::a.adoc[]
        \\:litmus-dir: x
        \\----
    , &.{ .dir, .include, .open, .code, .code, .close });
    try std.testing.expectEqualStrings("src/core", asciidocDir(":litmus-dir:  src/core "));
}

test "a command needs a space after the ellipsis" {
    try expectKinds(.asciidoc, "\u{2026}x\n\u{2026} x\n   \u{2026} x\n", &.{ .prose, .command, .command });
}

test "tabs as indent" {
    try expectKinds(.asciidoc, "\t\u{2026} x\n", &.{.command});
}

test "C6: a block still open at the end" {
    var scanner = Scanner.init(.asciidoc);
    _ = scanner.next("----");
    try std.testing.expect(scanner.inCodeBlock());
    _ = scanner.next("----");
    try std.testing.expect(!scanner.inCodeBlock());
    _ = scanner.next("....");
    try std.testing.expect(!scanner.inCodeBlock());
}

test "M1: Markdown fences" {
    try expectKinds(.markdown,
        \\… :file: a.zig
        \\```zig
        \\code
        \\```
        \\~~~~
        \\```
        \\~~~
        \\~~~~~
        \\  ```
        \\  inline ``` is not a fence
        \\  ```
    , &.{ .command, .open, .code, .close, .open, .code, .code, .close, .open, .code, .close });
}

test "M1: a closing fence is at least as long and has no info string" {
    try expectKinds(.markdown,
        \\````
        \\```
        \\```zig
        \\`````
    , &.{ .open, .code, .code, .close });
}

test "M1: indented code is not a code block, and a backtick fence has no backtick in its info" {
    try expectKinds(.markdown, "    code\n``` a`b\n", &.{ .prose, .prose });
}

test "M3: commands are ignored in HTML comments" {
    try expectKinds(.markdown,
        \\<!-- … a :file: x -->
        \\<!--
        \\… a :file: x
        \\-->
        \\text <!-- start
        \\… a :file: x
        \\end -->
        \\… a :file: x
    , &.{ .skip, .skip, .skip, .skip, .prose, .skip, .skip, .command });
}

test "M4: Markdown has no include" {
    try expectKinds(.markdown, "include::a.md[]\n:litmus-dir: x\n", &.{ .prose, .prose });
}

test "L10, L11: the style and companion entries" {
    try expectKinds(.asciidoc, ":litmus-style: style.md\n:litmus-companion:\n:litmus-other: x\n", &.{ .style, .companion, .prose });
    try expectKinds(.markdown, "<!-- :litmus-style: ../s.md -->\n<!-- :litmus-companion: -->\n", &.{ .style, .companion });
    try std.testing.expectEqualStrings("../s.md", markdownEntry("<!-- :litmus-style:  ../s.md -->", ":litmus-style:").?);
    try std.testing.expectEqualStrings("s.md", asciidocEntry(":litmus-style:  s.md ", ":litmus-style:"));
}

test "M5: the directory line" {
    try expectKinds(.markdown, "<!-- :litmus-dir: src/core -->\n<!-- other -->\n", &.{ .dir, .skip });
    try std.testing.expectEqualStrings("src/core", markdownDir("<!--   :litmus-dir:  src/core   -->").?);
    try std.testing.expect(markdownDir("<!-- x -->") == null);
}
