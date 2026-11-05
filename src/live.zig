//! Live pages (E1-E7): the small web server that `litmus watch --live` runs beside its loop.
//! It serves the woven pages, writes down what the reader selected, and opens tangled files.

const std = @import("std");
const builtin = @import("builtin");
const map = @import("map.zig");
const output = @import("output.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const default_port: u16 = 7357;

/// Where E4 keeps the selection, under `DIR`.
pub const selection_path = ".litmus/selection";

/// Whether a line opens or closes a delimited block: four or more of one of `-.=*_+/`,
/// the open block `--`, or a table's `|===`.
pub fn isDelimiter(line: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, line, " \t\r");
    if (std.mem.eql(u8, trimmed, "--") or std.mem.eql(u8, trimmed, "|===")) return true;
    if (trimmed.len < 4) return false;
    const c = trimmed[0];
    if (std.mem.indexOfScalar(u8, "-.=*_+/", c) == null) return false;
    for (trimmed) |d| if (d != c) return false;
    return true;
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r").len == 0;
}

/// An attribute line, `[source,zig]`, or a block title, `.Title`, which come before a block.
fn isBlockHead(line: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, line, " \t\r");
    if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') return true;
    return trimmed.len >= 2 and trimmed[0] == '.' and trimmed[1] != '.' and trimmed[1] != ' ';
}

/// The first line of a block's own content: past blank lines, attribute lines and block titles.
fn blockOpening(lines: []const []const u8, start: usize) usize {
    var i = start;
    while (i < lines.len and isBlank(lines[i])) i += 1;
    while (i + 1 < lines.len and isBlockHead(lines[i])) i += 1;
    return @min(i, lines.len -| 1);
}

/// E4: the last line of the block that starts at `start`, counted from 0. A block ends at its
/// closing delimiter if it opens with one, a section title is one line, and anything else ends
/// before the next blank line.
pub fn blockEnd(lines: []const []const u8, start: usize) usize {
    if (lines.len == 0) return 0;
    const i = blockOpening(lines, start);
    const line = lines[i];
    if (isDelimiter(line)) {
        const fence = std.mem.trimEnd(u8, line, " \t\r");
        var j = i + 1;
        while (j < lines.len) : (j += 1) {
            if (std.mem.eql(u8, std.mem.trimEnd(u8, lines[j], " \t\r"), fence)) return j;
        }
        return lines.len - 1;
    }
    if (line.len > 1 and line[0] == '=' and std.mem.indexOfScalar(u8, line, ' ') != null) {
        const marks = std.mem.indexOfNone(u8, line, "=") orelse line.len;
        if (marks < line.len and line[marks] == ' ') return i;
    }
    var j = i;
    while (j + 1 < lines.len and !isBlank(lines[j + 1])) j += 1;
    return j;
}

/// The lines of a document, without their newlines.
pub fn splitLines(arena: Allocator, text: []const u8) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try result.append(arena, line);
    if (result.items.len > 0 and result.items[result.items.len - 1].len == 0) _ = result.pop();
    return result.items;
}

/// What a live page sends when the reader selects something (E3). Lines count from 1, the
/// lines of code from 0.
pub const Selection = struct {
    doc: []const u8,
    line: u32,
    last_doc: []const u8,
    last_line: u32,
    code_first: ?u32 = null,
    code_last: ?u32 = null,
    sections: []const []const u8 = &.{},
    excerpt: ?[]const u8 = null,
    file: ?[]const u8 = null,
    text: []const u8 = "",
};

/// A stretch of a tangled file.
pub const Tangled = struct { file: []const u8, first: u32, last: u32 };

/// The lines of the first tangled file that the document lines `from` to `to` became, from the map.
pub fn tangledRange(m: map.Map, doc: []const u8, from: u32, to: u32) ?Tangled {
    for (m.files) |file| {
        var found: ?Tangled = null;
        for (file.runs) |run| {
            if (!std.mem.eql(u8, run.doc, doc)) continue;
            const lo = @max(from, run.doc_line);
            const hi = @min(to, run.doc_line + run.count - 1);
            if (lo > hi) continue;
            const first = run.line + (lo - run.doc_line);
            const last = run.line + (hi - run.doc_line);
            if (found) |*f| {
                f.first = @min(f.first, first);
                f.last = @max(f.last, last);
            } else found = .{ .file = file.path, .first = first, .last = last };
        }
        if (found) |f| return f;
    }
    return null;
}

fn printRange(w: *Io.Writer, path: []const u8, first: u32, last: u32) !void {
    if (first == last) try w.print("{s}:{d}", .{ path, first }) else try w.print("{s}:{d}-{d}", .{ path, first, last });
}

/// The code lines of the block whose delimiter, or whose head, is at `line` (from 1), as
/// document lines from 1: from the line after the opening delimiter to the line before the
/// closing one.
pub fn codeLines(lines: []const []const u8, line: u32) struct { first: u32, last: u32 } {
    const start = blockOpening(lines, line -| 1);
    const end = blockEnd(lines, line -| 1);
    const first: u32 = @intCast(start + 2);
    const last: u32 = @intCast(@max(end, start + 1));
    return .{ .first = first, .last = last };
}

/// E4: the text of `.litmus/selection`. `first_doc` and `last_doc` are the documents' texts,
/// null when they cannot be read, and `m` is the map, if there is one.
pub fn describe(arena: Allocator, s: Selection, first_doc: ?[]const u8, last_doc: ?[]const u8, m: ?map.Map) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("The reader selected this in the woven pages (litmus watch --live).\n");
    try w.writeAll("Where: ");
    try where(arena, w, s, first_doc, last_doc, m);
    try w.writeAll("\n");
    if (s.sections.len > 0) {
        try w.writeAll("Section: ");
        for (s.sections, 0..) |title, i| {
            if (i > 0) try w.writeAll(" > ");
            try w.writeAll(title);
        }
        try w.writeAll("\n");
    }
    try w.writeAll("Text:\n");
    try w.writeAll(s.text);
    if (s.text.len == 0 or s.text[s.text.len - 1] != '\n') try w.writeAll("\n");
    return out.written();
}

/// The `Where:` line of E4, also printed by watch and given back to the page.
pub fn where(arena: Allocator, w: *Io.Writer, s: Selection, first_doc: ?[]const u8, last_doc: ?[]const u8, m: ?map.Map) !void {
    const same = std.mem.eql(u8, s.doc, s.last_doc) and s.line == s.last_line;
    if (same and s.code_first != null and first_doc != null) {
        // Inside one code block: the selected lines of code.
        const lines = try splitLines(arena, first_doc.?);
        const code = codeLines(lines, s.line);
        const first = @min(code.first + s.code_first.?, code.last);
        const last = @min(code.first + (s.code_last orelse s.code_first.?), code.last);
        try printRange(w, s.doc, first, last);
        if (s.excerpt != null or s.file != null) {
            try w.writeAll(", in ");
            if (s.excerpt) |name| try w.print("the excerpt `{s}`", .{name}) else try w.writeAll("the root");
            if (s.file) |file| try w.print(" of {s}", .{file});
        }
        if (m) |mm| if (tangledRange(mm, s.doc, first, last)) |span| {
            try w.writeAll(", which became ");
            try printRange(w, span.file, span.first, span.last);
        };
        return;
    }
    const end: ?u32 = if (last_doc) |text| blk: {
        const lines = try splitLines(arena, text);
        if (s.last_line == 0 or s.last_line > lines.len) break :blk null;
        break :blk @intCast(blockEnd(lines, s.last_line - 1) + 1);
    } else null;
    if (std.mem.eql(u8, s.doc, s.last_doc)) {
        try printRange(w, s.doc, s.line, @max(s.line, end orelse s.last_line));
    } else {
        try w.print("{s}:{d} to ", .{ s.doc, s.line });
        try w.print("{s}:{d}", .{ s.last_doc, end orelse s.last_line });
    }
}

/// E6: the command that opens `file` at `line`, from the template in `LITMUS_OPEN`, or the
/// system's own opener.
pub fn openArgv(arena: Allocator, template: ?[]const u8, os: std.Target.Os.Tag, file: []const u8, line: u32) ![]const []const u8 {
    const text = template orelse if (os == .macos) "open {file}" else "xdg-open {file}";
    const line_text = try std.fmt.allocPrint(arena, "{d}", .{line});
    var argv: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeAny(u8, text, " \t");
    while (words.next()) |word| {
        const with_file = try std.mem.replaceOwned(u8, arena, word, "{file}", file);
        try argv.append(arena, try std.mem.replaceOwned(u8, arena, with_file, "{line}", line_text));
    }
    return argv.items;
}

/// E7: a request comes from a live page if it has no `Origin`, or the origin is watch's own.
pub fn originAllowed(origin: ?[]const u8, port: u16) bool {
    const o = origin orelse return true;
    var buf: [64]u8 = undefined;
    for ([_][]const u8{ "127.0.0.1", "localhost" }) |host| {
        const own = std.fmt.bufPrint(&buf, "http://{s}:{d}", .{ host, port }) catch return false;
        if (std.mem.eql(u8, o, own)) return true;
    }
    return false;
}

/// A path from the page that names a document: relative, and never above the current directory.
pub fn safeRelative(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, 0) != null or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

/// E1: the file under `PAGES` that a request's target names, or null if it names none. The
/// query and fragment are dropped, `%XX` is decoded, and a folder stands for its `index.html`.
pub fn pagePath(arena: Allocator, target: []const u8) !?[]const u8 {
    var end = target.len;
    if (std.mem.indexOfAny(u8, target, "?#")) |i| end = i;
    const raw = target[0..end];
    if (raw.len == 0 or raw[0] != '/') return null;
    var decoded: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '%' and i + 2 < raw.len) {
            const byte = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch return null;
            try decoded.append(arena, byte);
            i += 2;
        } else try decoded.append(arena, raw[i]);
    }
    var path = decoded.items;
    if (path.len == 0 or path[path.len - 1] == '/') path = try std.mem.concat(arena, u8, &.{ path, "index.html" });
    if (!safeRelative(path)) return null;
    return path;
}

fn contentType(path: []const u8) []const u8 {
    const types = [_][2][]const u8{
        .{ ".html", "text/html; charset=utf-8" },  .{ ".css", "text/css; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" }, .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".json", "application/json" },           .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },                   .{ ".jpg", "image/jpeg" },
        .{ ".gif", "image/gif" },                   .{ ".woff2", "font/woff2" },
    };
    for (types) |entry| if (std.mem.endsWith(u8, path, entry[0])) return entry[1];
    return "application/octet-stream";
}

/// What the server shares with watch's loop.
pub const State = struct {
    io: Io,
    port: u16,
    /// The folder of the pages (E1), `DIR` (E4), and the folder that holds the map.
    pages: []const u8,
    out_dir: []const u8,
    map_dir: []const u8,
    /// `LITMUS_OPEN` (E6).
    open_template: ?[]const u8,
    /// Goes up after each run, and the pages reload when it does (E2).
    version: std.atomic.Value(u64) = .init(1),
};

pub fn listen(io: Io, port: u16) !Io.net.Server {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    return address.listen(io, .{ .reuse_address = true });
}

/// Answers requests, one connection at a time, until watch stops.
pub fn serve(state: *State, server: *Io.net.Server) void {
    var out_buf: [4096]u8 = undefined;
    var out_writer: Io.File.Writer = .initStreaming(.stdout(), state.io, &out_buf);
    while (true) {
        const stream = server.accept(state.io) catch |e| switch (e) {
            error.Canceled => return,
            else => continue,
        };
        defer stream.close(state.io);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        handle(state, arena.allocator(), stream, &out_writer.interface) catch {};
        out_writer.interface.flush() catch {};
    }
}

const Reply = struct { status: std.http.Status = .ok, body: []const u8, kind: []const u8 = "text/plain; charset=utf-8" };

fn handle(state: *State, arena: Allocator, stream: Io.net.Stream, log: *Io.Writer) !void {
    var in_buf: [16 * 1024]u8 = undefined;
    var send_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(state.io, &in_buf);
    var writer = stream.writer(state.io, &send_buf);
    var http: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = try http.receiveHead();

    const reply: Reply = reply: {
        const target = try arena.dupe(u8, request.head.target);
        if (request.head.method == .POST) {
            // E7: only from the pages themselves, and only JSON.
            var origin: ?[]const u8 = null;
            var headers = request.iterateHeaders();
            while (headers.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "origin")) origin = try arena.dupe(u8, h.value);
            }
            const json = if (request.head.content_type) |kind| std.mem.startsWith(u8, kind, "application/json") else false;
            if (!originAllowed(origin, state.port) or !json) break :reply .{ .status = .forbidden, .body = "refused\n" };
            var body_buf: [4096]u8 = undefined;
            const body_reader = try request.readerExpectContinue(&body_buf);
            const body = body_reader.allocRemaining(arena, .limited(1 << 20)) catch break :reply .{ .status = .bad_request, .body = "too big\n" };
            if (std.mem.eql(u8, target, "/litmus/selection")) break :reply try select(state, arena, body, log);
            if (std.mem.eql(u8, target, "/litmus/open")) break :reply try open(state, arena, body, log);
            break :reply .{ .status = .not_found, .body = "not found\n" };
        }
        if (request.head.method != .GET and request.head.method != .HEAD) break :reply .{ .status = .method_not_allowed, .body = "no\n" };
        if (std.mem.eql(u8, target, "/litmus/version")) {
            break :reply .{ .body = try std.fmt.allocPrint(arena, "{d}", .{state.version.load(.monotonic)}) };
        }
        const path = (try pagePath(arena, target)) orelse break :reply .{ .status = .not_found, .body = "not found\n" };
        var dir = Io.Dir.cwd().openDir(state.io, state.pages, .{}) catch break :reply .{ .status = .not_found, .body = "no pages\n" };
        defer dir.close(state.io);
        const bytes = (output.readOrNull(state.io, arena, dir, path) catch null) orelse break :reply .{ .status = .not_found, .body = "not found\n" };
        break :reply .{ .body = bytes, .kind = contentType(path) };
    };
    try request.respond(reply.body, .{
        .status = reply.status,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = reply.kind },
            .{ .name = "cache-control", .value = "no-store" },
        },
    });
}

fn readDoc(state: *State, arena: Allocator, path: []const u8) ?[]const u8 {
    if (!safeRelative(path)) return null;
    return output.readOrNull(state.io, arena, Io.Dir.cwd(), path) catch null;
}

fn readMap(state: *State, arena: Allocator) ?map.Map {
    var dir = Io.Dir.cwd().openDir(state.io, state.map_dir, .{}) catch return null;
    defer dir.close(state.io);
    const text = (output.readOrNull(state.io, arena, dir, output.map_path) catch null) orelse return null;
    return map.read(arena, text) catch null;
}

/// E4: writes the selection down, and says where it is.
fn select(state: *State, arena: Allocator, body: []const u8, log: *Io.Writer) !Reply {
    const s = std.json.parseFromSliceLeaky(Selection, arena, body, .{ .ignore_unknown_fields = true }) catch {
        return .{ .status = .bad_request, .body = "not a selection\n" };
    };
    if (!safeRelative(s.doc) or !safeRelative(s.last_doc)) return .{ .status = .bad_request, .body = "bad document\n" };
    const first_doc = readDoc(state, arena, s.doc);
    const last_doc = readDoc(state, arena, s.last_doc);
    const m = readMap(state, arena);
    const text = try describe(arena, s, first_doc, last_doc, m);
    var dir = try Io.Dir.cwd().openDir(state.io, state.out_dir, .{});
    defer dir.close(state.io);
    try output.writeAtomic(state.io, dir, selection_path, text, false);
    var place: Io.Writer.Allocating = .init(arena);
    try where(arena, &place.writer, s, first_doc, last_doc, m);
    try log.print("selected: {s}\n", .{place.written()});
    return .{ .body = place.written() };
}

const OpenRequest = struct { doc: []const u8, line: u32 };

/// E6: opens the tangled file that a labeled block became, at its first line.
fn open(state: *State, arena: Allocator, body: []const u8, log: *Io.Writer) !Reply {
    const r = std.json.parseFromSliceLeaky(OpenRequest, arena, body, .{ .ignore_unknown_fields = true }) catch {
        return .{ .status = .bad_request, .body = "not a request to open a file\n" };
    };
    const text = readDoc(state, arena, r.doc) orelse return .{ .status = .not_found, .body = "no such document\n" };
    const m = readMap(state, arena) orelse return .{ .status = .not_found, .body = "no map; run litmus tangle\n" };
    const code = codeLines(try splitLines(arena, text), r.line);
    const span = tangledRange(m, r.doc, code.first, code.last) orelse return .{ .status = .not_found, .body = "this block is not in the map\n" };
    const argv = try openArgv(arena, state.open_template, builtin.os.tag, span.file, span.first);
    if (argv.len == 0) return .{ .status = .internal_server_error, .body = "LITMUS_OPEN is empty\n" };
    var child = std.process.spawn(state.io, .{ .argv = argv, .stdin = .ignore }) catch |e| {
        try log.print("open: {s}: {s}\n", .{ argv[0], @errorName(e) });
        return .{ .status = .internal_server_error, .body = try std.fmt.allocPrint(arena, "{s}: {s}\n", .{ argv[0], @errorName(e) }) };
    };
    _ = child.wait(state.io) catch {};
    try log.print("opened: {s}:{d}\n", .{ span.file, span.first });
    return .{ .body = try std.fmt.allocPrint(arena, "{s}:{d}", .{ span.file, span.first }) };
}

// Tests ----------------------------------------------------------------------

const t = std.testing;

const doc_text =
    \\= Title
    \\
    \\== Section
    \\
    \\First paragraph,
    \\on two lines.
    \\
    \\.A title
    \\… step :file: src/a.zig
    \\[source,zig]
    \\----
    \\fn a() void {}
    \\… inner
    \\fn b() void {}
    \\----
    \\
    \\Last.
    \\
;

test "E4: a paragraph ends before the next blank line, a section title is one line" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const lines = try splitLines(arena_state.allocator(), doc_text);
    try t.expectEqual(5, blockEnd(lines, 4));
    try t.expectEqual(2, blockEnd(lines, 2));
    try t.expectEqual(16, blockEnd(lines, 16));
}

test "E4: a delimited block ends at its closing delimiter, past its title and attributes" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const lines = try splitLines(arena_state.allocator(), doc_text);
    try t.expectEqual(14, blockEnd(lines, 10));
    try t.expectEqual(14, blockEnd(lines, 9));
    const code = codeLines(lines, 11);
    try t.expectEqual(12, code.first);
    try t.expectEqual(14, code.last);
    try t.expect(isDelimiter("----"));
    try t.expect(isDelimiter("--"));
    try t.expect(!isDelimiter("---"));
    try t.expect(!isDelimiter("-- x"));
}

fn testMap() map.Map {
    const runs = &[_]map.MapRun{
        .{ .line = 1, .count = 1, .doc = "d.adoc", .doc_line = 12, .indent = 0, .excerpt = "step" },
        .{ .line = 2, .count = 3, .doc = "d.adoc", .doc_line = 40, .indent = 4, .excerpt = "inner" },
        .{ .line = 5, .count = 1, .doc = "d.adoc", .doc_line = 14, .indent = 0, .excerpt = "step" },
    };
    return .{ .files = &.{.{ .path = "src/a.zig", .hash = "", .runs = runs }} };
}

test "E4, E6: document lines are found in the map, skipping excerpt commands" {
    const m = testMap();
    const all = tangledRange(m, "d.adoc", 12, 14).?;
    try t.expectEqualStrings("src/a.zig", all.file);
    try t.expectEqual(1, all.first);
    try t.expectEqual(5, all.last);
    const second = tangledRange(m, "d.adoc", 13, 14).?;
    try t.expectEqual(5, second.first);
    try t.expect(tangledRange(m, "d.adoc", 13, 13) == null);
    try t.expect(tangledRange(m, "other.adoc", 12, 14) == null);
}

test "E4: a selection in prose names the document lines of its blocks, and its text" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = try describe(a, .{
        .doc = "d.adoc",
        .line = 5,
        .last_doc = "d.adoc",
        .last_line = 5,
        .sections = &.{ "Title", "Section" },
        .text = "First paragraph, on two lines.",
    }, doc_text, doc_text, null);
    try t.expectEqualStrings(
        \\The reader selected this in the woven pages (litmus watch --live).
        \\Where: d.adoc:5-6
        \\Section: Title > Section
        \\Text:
        \\First paragraph, on two lines.
        \\
    , text);
    var w: Io.Writer.Allocating = .init(a);
    try where(a, &w.writer, .{ .doc = "d.adoc", .line = 3, .last_doc = "d.adoc", .last_line = 11 }, doc_text, doc_text, null);
    try t.expectEqualStrings("d.adoc:3-15", w.written());
}

test "E4: a selection in code names its lines, its excerpt, and the lines of the tangled file" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var w: Io.Writer.Allocating = .init(a);
    try where(a, &w.writer, .{
        .doc = "d.adoc",
        .line = 11,
        .last_doc = "d.adoc",
        .last_line = 11,
        .code_first = 0,
        .code_last = 2,
        .excerpt = "step",
        .file = "src/a.zig",
    }, doc_text, doc_text, testMap());
    try t.expectEqualStrings("d.adoc:12-14, in the excerpt `step` of src/a.zig, which became src/a.zig:1-5", w.written());
}

test "E6: the command that opens a file" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const mac = try openArgv(a, null, .macos, "src/My File.swift", 9);
    try t.expectEqual(2, mac.len);
    try t.expectEqualStrings("open", mac[0]);
    try t.expectEqualStrings("src/My File.swift", mac[1]);
    try t.expectEqualStrings("xdg-open", (try openArgv(a, null, .linux, "f", 1))[0]);
    const xed = try openArgv(a, "xed --line {line} {file}", .macos, "f.swift", 42);
    try t.expectEqual(4, xed.len);
    try t.expectEqualStrings("42", xed[2]);
    const code = try openArgv(a, "code -g {file}:{line}", .linux, "f.zig", 7);
    try t.expectEqualStrings("f.zig:7", code[2]);
}

test "E7: requests are taken only from watch's own pages" {
    try t.expect(originAllowed(null, 7357));
    try t.expect(originAllowed("http://127.0.0.1:7357", 7357));
    try t.expect(originAllowed("http://localhost:7357", 7357));
    try t.expect(!originAllowed("http://localhost:8000", 7357));
    try t.expect(!originAllowed("https://example.com", 7357));
}

test "E1: a request names a file under the pages, or none" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqualStrings("index.html", (try pagePath(a, "/")).?);
    try t.expectEqualStrings("a b.html", (try pagePath(a, "/a%20b.html?x=1#top")).?);
    try t.expectEqualStrings("visuals/index.html", (try pagePath(a, "/visuals/")).?);
    try t.expect((try pagePath(a, "/../secret")) == null);
    try t.expect((try pagePath(a, "/a/%2e%2e/%2e%2e/b")) == null);
    try t.expect((try pagePath(a, "//etc/passwd")) == null);
    try t.expect((try pagePath(a, "x")) == null);
}
