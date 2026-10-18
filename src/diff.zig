//! A line diff of two texts, for untangle (U2). No IO.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Base lines `[a, a_end)` were replaced by changed lines `[b, b_end)`. Either range
/// may be empty: a pure deletion, or a pure insertion.
pub const Hunk = struct { a: u32, a_end: u32, b: u32, b_end: u32 };

/// How many edits Myers' search tries before it gives up and reports the whole
/// middle of the texts as one hunk. The result is then coarser, but still exact.
pub const max_edits: usize = 1000;

fn same(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

/// The hunks that turn `base` into `changed`, in order. The common start and end
/// are trimmed first, since most edits are small, and Myers' O(ND) algorithm runs
/// on what is left.
pub fn diff(arena: Allocator, base: []const []const u8, changed: []const []const u8) Allocator.Error![]const Hunk {
    var start: usize = 0;
    while (start < base.len and start < changed.len and same(base[start], changed[start])) start += 1;
    var end: usize = 0;
    while (end < base.len - start and end < changed.len - start and
        same(base[base.len - 1 - end], changed[changed.len - 1 - end])) end += 1;
    const a = base[start .. base.len - end];
    const b = changed[start .. changed.len - end];

    var hunks: std.ArrayList(Hunk) = .empty;
    if (a.len == 0 and b.len == 0) return hunks.items;
    if (a.len == 0 or b.len == 0) {
        try hunks.append(arena, .{ .a = @intCast(start), .a_end = @intCast(start + a.len), .b = @intCast(start), .b_end = @intCast(start + b.len) });
        return hunks.items;
    }

    const deleted = try arena.alloc(bool, a.len);
    const inserted = try arena.alloc(bool, b.len);
    @memset(deleted, false);
    @memset(inserted, false);
    if (!try myers(arena, a, b, deleted, inserted)) {
        @memset(deleted, true);
        @memset(inserted, true);
    }

    // Lines that were neither deleted nor inserted pair up in order. What lies between
    // two such pairs is one hunk.
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len or j < b.len) {
        if (i < a.len and !deleted[i] and j < b.len and !inserted[j]) {
            i += 1;
            j += 1;
            continue;
        }
        const first_i = i;
        const first_j = j;
        while (i < a.len and deleted[i]) i += 1;
        while (j < b.len and inserted[j]) j += 1;
        try hunks.append(arena, .{
            .a = @intCast(start + first_i),
            .a_end = @intCast(start + i),
            .b = @intCast(start + first_j),
            .b_end = @intCast(start + j),
        });
    }
    return hunks.items;
}

/// Marks the lines of `a` that are deleted and the lines of `b` that are inserted.
/// Returns false if more than `max_edits` edits would be needed.
fn myers(arena: Allocator, a: []const []const u8, b: []const []const u8, deleted: []bool, inserted: []bool) Allocator.Error!bool {
    const n: i64 = @intCast(a.len);
    const m: i64 = @intCast(b.len);
    const limit: i64 = @intCast(@min(max_edits, a.len + b.len));
    const width: usize = @intCast(2 * limit + 3);
    const offset: i64 = limit + 1;
    var v = try arena.alloc(i64, width);
    @memset(v, 0);
    // The state before each round of edits, kept to walk back from the end.
    var trace: std.ArrayList([]i64) = .empty;

    var d: i64 = 0;
    const found = search: while (d <= limit) : (d += 1) {
        try trace.append(arena, try arena.dupe(i64, v));
        var k = -d;
        while (k <= d) : (k += 2) {
            const down = k == -d or (k != d and v[@intCast(offset + k - 1)] < v[@intCast(offset + k + 1)]);
            var x: i64 = if (down) v[@intCast(offset + k + 1)] else v[@intCast(offset + k - 1)] + 1;
            var y = x - k;
            while (x < n and y < m and same(a[@intCast(x)], b[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            v[@intCast(offset + k)] = x;
            if (x >= n and y >= m) break :search true;
        }
    } else false;
    if (!found) return false;

    var x = n;
    var y = m;
    var round = d;
    while (round > 0) : (round -= 1) {
        const before = trace.items[@intCast(round)];
        const k = x - y;
        const down = k == -round or (k != round and before[@intCast(offset + k - 1)] < before[@intCast(offset + k + 1)]);
        const prev_k = if (down) k + 1 else k - 1;
        const prev_x = before[@intCast(offset + prev_k)];
        const prev_y = prev_x - prev_k;
        if (down) {
            inserted[@intCast(prev_y)] = true;
        } else {
            deleted[@intCast(prev_x)] = true;
        }
        x = prev_x;
        y = prev_y;
    }
    return true;
}

// Tests ----------------------------------------------------------------------

const t = std.testing;

fn lines(arena: Allocator, text: []const u8) ![]const []const u8 {
    return @import("scan.zig").splitLines(arena, text);
}

/// Applies the hunks to `base`: unchanged lines are copied, and each hunk's range is
/// replaced by the changed lines. The result must be `changed`.
fn expectApplies(base: []const []const u8, changed: []const []const u8, hunks: []const Hunk) !void {
    var at: u32 = 0;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(t.allocator);
    for (hunks) |h| {
        try t.expect(h.a >= at);
        for (base[at..h.a]) |line| try out.append(t.allocator, line);
        for (changed[h.b..h.b_end]) |line| try out.append(t.allocator, line);
        at = h.a_end;
    }
    for (base[at..]) |line| try out.append(t.allocator, line);
    try t.expectEqual(changed.len, out.items.len);
    for (changed, out.items) |want, got| try t.expectEqualStrings(want, got);
}

fn expectHunks(base: []const u8, changed: []const u8, want: []const Hunk) !void {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const x = try lines(a, base);
    const y = try lines(a, changed);
    const got = try diff(a, x, y);
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqual(w, g);
    try expectApplies(x, y, got);
}

test "U2: no change gives no hunks" {
    try expectHunks("a\nb\nc\n", "a\nb\nc\n", &.{});
    try expectHunks("", "", &.{});
}

test "U2: one line changed, added, removed" {
    try expectHunks("a\nb\nc\n", "a\nX\nc\n", &.{.{ .a = 1, .a_end = 2, .b = 1, .b_end = 2 }});
    try expectHunks("a\nb\nc\n", "a\nb\nX\nc\n", &.{.{ .a = 2, .a_end = 2, .b = 2, .b_end = 3 }});
    try expectHunks("a\nb\nc\n", "a\nc\n", &.{.{ .a = 1, .a_end = 2, .b = 1, .b_end = 1 }});
    try expectHunks("a\nb\nc\n", "X\na\nb\nc\n", &.{.{ .a = 0, .a_end = 0, .b = 0, .b_end = 1 }});
    try expectHunks("a\nb\nc\n", "a\nb\nc\nX\n", &.{.{ .a = 3, .a_end = 3, .b = 3, .b_end = 4 }});
}

test "U2: two edits far apart are two hunks" {
    try expectHunks("a\nb\nc\nd\ne\nf\ng\n", "a\nB\nc\nd\ne\nf\nG\nh\n", &.{
        .{ .a = 1, .a_end = 2, .b = 1, .b_end = 2 },
        .{ .a = 6, .a_end = 7, .b = 6, .b_end = 8 },
    });
}

test "U2: the empty text on either side" {
    try expectHunks("", "a\nb\n", &.{.{ .a = 0, .a_end = 0, .b = 0, .b_end = 2 }});
    try expectHunks("a\nb\n", "", &.{.{ .a = 0, .a_end = 2, .b = 0, .b_end = 0 }});
}

test "U2: repeated lines still give a diff that applies" {
    try expectHunks("}\n\n}\n\n}\n", "}\n\n}\n\nx\n\n}\n", &.{.{ .a = 4, .a_end = 4, .b = 4, .b_end = 6 }});
    try expectHunks("\n\n\n", "\n\n\n\n\n", &.{.{ .a = 3, .a_end = 3, .b = 3, .b_end = 5 }});
}

test "U2: a change in the middle of a long text is found" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var base: std.ArrayList([]const u8) = .empty;
    var changed: std.ArrayList([]const u8) = .empty;
    for (0..5000) |i| {
        const line = try std.fmt.allocPrint(a, "line {d}", .{i});
        try base.append(a, line);
        try changed.append(a, if (i == 2500) "different" else line);
    }
    const hunks = try diff(a, base.items, changed.items);
    try t.expectEqual(1, hunks.len);
    try t.expectEqual(Hunk{ .a = 2500, .a_end = 2501, .b = 2500, .b_end = 2501 }, hunks[0]);
}

test "U2: past the limit the whole middle is one hunk, and the result still applies" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var base: std.ArrayList([]const u8) = .empty;
    var changed: std.ArrayList([]const u8) = .empty;
    try base.append(a, "first");
    try changed.append(a, "first");
    for (0..3 * max_edits) |i| {
        try base.append(a, try std.fmt.allocPrint(a, "old {d}", .{i}));
        try changed.append(a, try std.fmt.allocPrint(a, "new {d}", .{i}));
    }
    try base.append(a, "last");
    try changed.append(a, "last");
    const hunks = try diff(a, base.items, changed.items);
    try t.expectEqual(1, hunks.len);
    try t.expectEqual(1, hunks[0].a);
    try expectApplies(base.items, changed.items, hunks);
}

test "U2: random edits always give hunks that apply" {
    var prng = std.Random.DefaultPrng.init(0x11d1f);
    const random = prng.random();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    for (0..300) |_| {
        const a = arena_state.allocator();
        const words = [_][]const u8{ "", "}", "x", "y", "  z", "{" };
        const n = random.uintLessThan(usize, 40);
        const base = try a.alloc([]const u8, n);
        for (base) |*line| line.* = words[random.uintLessThan(usize, words.len)];
        var changed: std.ArrayList([]const u8) = .empty;
        for (base) |line| {
            switch (random.uintLessThan(u8, 8)) {
                0 => {},
                1 => try changed.append(a, words[random.uintLessThan(usize, words.len)]),
                2 => {
                    try changed.append(a, line);
                    try changed.append(a, words[random.uintLessThan(usize, words.len)]);
                },
                else => try changed.append(a, line),
            }
        }
        const hunks = try diff(a, base, changed.items);
        try expectApplies(base, changed.items, hunks);
    }
}
