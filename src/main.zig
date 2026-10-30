//! The Litmus command line. See doc/litmus.adoc for the rules.

const std = @import("std");
const types = @import("types.zig");
const docset = @import("docset.zig");
const resolve = @import("resolve.zig");
const tangle = @import("tangle.zig");
const map = @import("map.zig");
const output = @import("output.zig");
const compare = @import("compare.zig");
const init_command = @import("init.zig");
const untangle = @import("untangle.zig");
const sync = @import("sync.zig");
const watch = @import("watch.zig");
const adopt = @import("adopt.zig");
const marks = @import("marks.zig");
const assemble = @import("assemble.zig");
const setup = @import("setup.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const usage =
    \\Usage: litmus tangle [-o DIR] [--force] DOCUMENT...
    \\       litmus check [-o DIR] DOCUMENT...
    \\       litmus where [-o DIR] [DOCUMENT] FILE:LINE
    \\       litmus guide
    \\       litmus init [-o DIR] DOCUMENT...
    \\       litmus untangle [-o DIR] [-f FILE]... [--force] DOCUMENT...
    \\       litmus sync [-o DIR] DOCUMENT...
    \\       litmus watch [-o DIR] [--interval MS] DOCUMENT...
    \\       litmus style DOCUMENT...
    \\       litmus blocks [--changed] DOCUMENT...
    \\       litmus assemble SKELETON TEMPLATE OUTPUT
    \\       litmus setup
    \\       litmus adopt [-o DIR] [--companion] [--style FILE] [--diff FILE] DOCUMENT PATH...
    \\
;

const guide_text = @embedFile("guide.txt");

const Context = struct {
    io: Io,
    arena: Allocator,
    out: *Io.Writer,
    err: *Io.Writer,
};

const Options = struct {
    out_dir: []const u8 = ".",
    force: bool = false,
    /// The files named with `-f` (U8).
    files: []const []const u8 = &.{},
    /// How often watch looks at the files, in milliseconds (W3).
    interval_ms: u64 = 200,
    /// For adopt: the document is a companion (L11), and names this style file (L10).
    companion: bool = false,
    style: ?[]const u8 = null,
    /// For adopt: the diff whose changes are marked (A9).
    diff: ?[]const u8 = null,
    /// For blocks: only the blocks that mark changes (B1).
    changed: bool = false,
    positional: []const []const u8 = &.{},
};

/// Which options a command takes besides `-o DIR`.
const Allowed = struct { force: bool = false, files: bool = false, interval: bool = false, adopt: bool = false, changed: bool = false };

/// Reads `-o DIR`, and `--force` and `-f FILE` when allowed. Prints the problem and returns
/// null on a usage error.
fn parseOptions(ctx: Context, args: []const []const u8, allowed: Allowed) !?Options {
    var options: Options = .{};
    var positional: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i == args.len) {
                try ctx.err.writeAll("litmus: -o needs a directory\n");
                return null;
            }
            options.out_dir = args[i];
        } else if (allowed.force and std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (allowed.changed and std.mem.eql(u8, arg, "--changed")) {
            options.changed = true;
        } else if (allowed.adopt and std.mem.eql(u8, arg, "--companion")) {
            options.companion = true;
        } else if (allowed.adopt and std.mem.eql(u8, arg, "--style")) {
            i += 1;
            if (i == args.len) {
                try ctx.err.writeAll("litmus: --style needs a file\n");
                return null;
            }
            options.style = args[i];
        } else if (allowed.adopt and std.mem.eql(u8, arg, "--diff")) {
            i += 1;
            if (i == args.len) {
                try ctx.err.writeAll("litmus: --diff needs a file\n");
                return null;
            }
            options.diff = args[i];
        } else if (allowed.interval and std.mem.eql(u8, arg, "--interval")) {
            i += 1;
            const milliseconds = if (i < args.len) std.fmt.parseInt(u64, args[i], 10) catch 0 else 0;
            if (milliseconds == 0) {
                try ctx.err.writeAll("litmus: --interval needs a number of milliseconds\n");
                return null;
            }
            options.interval_ms = milliseconds;
        } else if (allowed.files and std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i == args.len) {
                try ctx.err.writeAll("litmus: -f needs a file\n");
                return null;
            }
            try files.append(ctx.arena, args[i]);
        } else if (arg.len > 1 and arg[0] == '-') {
            try ctx.err.print("litmus: unknown option {s}\n", .{arg});
            return null;
        } else {
            try positional.append(ctx.arena, arg);
        }
    }
    options.positional = positional.items;
    options.files = files.items;
    return options;
}

/// Reads documents from the current directory.
const DiskFs = struct {
    io: Io,

    pub fn read(self: *DiskFs, arena: Allocator, path: []const u8) ?[]const u8 {
        return Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(1 << 30)) catch null;
    }
};

const Built = struct {
    docs: []const types.Document,
    files: []const tangle.Tangled,
    /// Whether the set is a companion of the code (R1).
    companion: bool = false,
};

/// N1: the line that tells an agent what to do next.
fn next(ctx: Context, comptime fmt: []const u8, args: anytype) !void {
    try ctx.out.print("next: " ++ fmt ++ "\n", args);
}

/// The map is rewritten when the documents moved without their code changing, such as when prose
/// was written: it holds document lines (R2). Writes nothing if it is already right.
fn refreshMap(ctx: Context, built: Built, map_dir: Io.Dir, old_text: ?[]const u8) !bool {
    const new_map = try map.render(ctx.arena, built.docs, built.files);
    if (old_text) |old| if (std.mem.eql(u8, old, new_map)) return false;
    try output.writeAtomic(ctx.io, map_dir, output.map_path, new_map, false);
    return true;
}

/// The directory that holds the map: `DIR`, or for a companion the directory of the first
/// document (R2).
fn mapDirPath(options: Options, companion: bool) []const u8 {
    if (!companion) return options.out_dir;
    return std.fs.path.dirname(options.positional[0]) orelse ".";
}

fn printDiagnostics(ctx: Context, diags: *types.Diagnostics, docs: []const types.Document) !void {
    diags.sort();
    for (diags.list.items) |d| {
        const path = docs[d.doc].path;
        if (d.line == 0) {
            try ctx.err.print("{s}: {s}\n", .{ path, d.message });
        } else {
            try ctx.err.print("{s}:{d}: {s}\n", .{ path, d.line, d.message });
        }
    }
}

/// Loads, checks and tangles the document set. On errors it prints them and returns null.
fn build(ctx: Context, documents: []const []const u8) !?Built {
    return buildInto(ctx, documents, null);
}

/// Like `build`, and gives the documents that were found even when there are errors, which
/// watch needs to know what to watch.
fn buildInto(ctx: Context, documents: []const []const u8, found: ?*[]const types.Document) !?Built {
    var diags = types.Diagnostics.init(ctx.arena);
    var fs: DiskFs = .{ .io = ctx.io };
    const set = try docset.load(ctx.arena, &fs, documents, &diags);
    if (found) |out| out.* = set.docs;
    // Mistakes in the structure make the checks of the whole set misleading.
    if (diags.list.items.len == 0) {
        const resolved = try resolve.resolve(ctx.arena, set.docs, set.blocks, &diags);
        if (diags.list.items.len == 0) {
            return .{ .docs = set.docs, .files = try tangle.tangleAll(ctx.arena, resolved), .companion = set.companion };
        }
    }
    try printDiagnostics(ctx, &diags, set.docs);
    return null;
}

/// Checks that each document has a kind that Litmus reads.
fn documentsOk(ctx: Context, documents: []const []const u8) !bool {
    if (documents.len == 0) {
        try ctx.err.writeAll(usage);
        return false;
    }
    for (documents) |path| {
        if (docset.formatOf(path) == null) {
            try ctx.err.print("litmus: {s} is not a .adoc, .asciidoc, .asc or .md document\n", .{path});
            return false;
        }
    }
    return true;
}

fn tangleCommand(ctx: Context, args: []const []const u8) !u8 {
    const options = (try parseOptions(ctx, args, .{ .force = true })) orelse return 2;
    if (!try documentsOk(ctx, options.positional)) return 2;
    const built = (try build(ctx, options.positional)) orelse return 1;
    if (built.companion) {
        try ctx.err.writeAll("R3: the documents are a companion of the code, and never write to it\n");
        try next(ctx, "use litmus check to compare, and litmus untangle to take changes from the code", .{});
        return 1;
    }

    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(ctx.io, options.out_dir);
    var dir = try cwd.openDir(ctx.io, options.out_dir, .{});
    defer dir.close(ctx.io);
    const map_text = try map.render(ctx.arena, built.docs, built.files);
    const outcome = try output.write(ctx.io, ctx.arena, dir, built.files, map_text, options.force);

    if (outcome.bad_map) |problem| {
        try ctx.err.print("{s}: {s}; delete it, or tangle with --force\n", .{ output.map_path, problem });
        return 1;
    }
    for (outcome.conflicts) |path| {
        try ctx.err.print("{s}: changed since tangle wrote it (T6); carry the change into the documents, or tangle with --force\n", .{path});
    }
    for (outcome.written) |path| try ctx.out.print("wrote {s}\n", .{path});
    for (outcome.orphans) |path| try ctx.err.print("{s}: no longer tangled (T5); left in place\n", .{path});
    return if (outcome.conflicts.len > 0) 1 else 0;
}

fn checkCommand(ctx: Context, args: []const []const u8) !u8 {
    const options = (try parseOptions(ctx, args, .{})) orelse return 2;
    if (!try documentsOk(ctx, options.positional)) return 2;
    const built = (try build(ctx, options.positional)) orelse return 1;

    var dir = Io.Dir.cwd().openDir(ctx.io, options.out_dir, .{}) catch |e| {
        try ctx.err.print("{s}: {s}\n", .{ options.out_dir, @errorName(e) });
        return 1;
    };
    defer dir.close(ctx.io);
    const differences = try compare.compare(ctx.io, ctx.arena, dir, built.docs, built.files);
    for (differences) |difference| try difference.print(ctx.err);
    return if (differences.len > 0) 1 else 0;
}

fn whereCommand(ctx: Context, args: []const []const u8) !u8 {
    var options = (try parseOptions(ctx, args, .{})) orelse return 2;
    if (options.positional.len < 1 or options.positional.len > 2) {
        try ctx.err.writeAll(usage);
        return 2;
    }
    const target = options.positional[options.positional.len - 1];
    // With a document, the map is wherever that document's set keeps it (R2).
    var map_dir_path: []const u8 = options.out_dir;
    if (options.positional.len == 2) {
        options.positional = options.positional[0..1];
        if (!try documentsOk(ctx, options.positional)) return 2;
        var diags = types.Diagnostics.init(ctx.arena);
        var fs: DiskFs = .{ .io = ctx.io };
        const set = try docset.load(ctx.arena, &fs, options.positional, &diags);
        map_dir_path = mapDirPath(options, set.companion);
    }
    const colon = std.mem.lastIndexOfScalar(u8, target, ':') orelse {
        try ctx.err.writeAll(usage);
        return 2;
    };
    const line = std.fmt.parseInt(u32, target[colon + 1 ..], 10) catch {
        try ctx.err.writeAll(usage);
        return 2;
    };
    const path = target[0..colon];

    var dir = Io.Dir.cwd().openDir(ctx.io, map_dir_path, .{}) catch |e| {
        try ctx.err.print("{s}: {s}\n", .{ map_dir_path, @errorName(e) });
        return 1;
    };
    defer dir.close(ctx.io);
    const map_text = try output.readOrNull(ctx.io, ctx.arena, dir, output.map_path) orelse {
        try ctx.err.print("{s}/{s} does not exist; run litmus tangle first\n", .{ map_dir_path, output.map_path });
        return 1;
    };
    const parsed = map.read(ctx.arena, map_text) catch {
        try ctx.err.print("{s}/{s} cannot be read; run litmus tangle first\n", .{ map_dir_path, output.map_path });
        return 1;
    };
    const file = parsed.find(path) orelse {
        try ctx.err.print("{s}: not a tangled file; the map lists the files on its \"file\" lines\n", .{path});
        return 1;
    };
    const at = map.findRun(file.runs, line) orelse {
        try ctx.err.print("{s}:{d}: no such line\n", .{ path, line });
        return 1;
    };
    const run = file.runs[at];
    const excerpt = if (std.mem.eql(u8, run.excerpt, ":file:")) "file root" else run.excerpt;
    try ctx.out.print("{s}:{d} ({s})\n", .{ run.doc, run.doc_line + (line - run.line), excerpt });
    return 0;
}

fn lines(n: u32) []const u8 {
    return if (n == 1) "line" else "lines";
}

fn untangleCommand(ctx: Context, args: []const []const u8) !u8 {
    const options = (try parseOptions(ctx, args, .{ .force = true, .files = true })) orelse return 2;
    if (!try documentsOk(ctx, options.positional)) return 2;
    const built = (try build(ctx, options.positional)) orelse return 1;

    var dir = Io.Dir.cwd().openDir(ctx.io, options.out_dir, .{}) catch |e| {
        try ctx.err.print("{s}: {s}\n", .{ options.out_dir, @errorName(e) });
        return 1;
    };
    defer dir.close(ctx.io);

    // R2: a companion keeps its map beside its first document.
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(ctx.io, mapDirPath(options, built.companion));
    var map_dir = try cwd.openDir(ctx.io, mapDirPath(options, built.companion), .{});
    defer map_dir.close(ctx.io);

    // U1, U7: the documents must not have changed since tangle wrote the files.
    const map_text = try output.readOrNull(ctx.io, ctx.arena, map_dir, output.map_path);
    const previous: ?map.Map = if (map_text) |text| map.read(ctx.arena, text) catch {
        try ctx.err.print("the map ({s}) cannot be read; tangle first, or untangle with --force\n", .{output.map_path});
        try next(ctx, "run litmus tangle, or litmus untangle --force if the documents did not change", .{});
        return 1;
    } else null;
    if (!options.force) {
        if (previous == null) {
            try ctx.err.print("there is no map ({s}), so it is not known whether the documents or the files changed; run litmus tangle, or untangle with --force\n", .{output.map_path});
            try next(ctx, "run litmus tangle, or litmus untangle --force if the documents did not change", .{});
            return 1;
        }
        var stale = false;
        for (built.files) |file| {
            const recorded = previous.?.find(file.path);
            if (recorded == null or !std.mem.eql(u8, recorded.?.hash, &map.hashHex(file.text))) {
                try ctx.err.print("{s}: the documents tangle to something else than when it was last tangled (U1)\n", .{file.path});
                stale = true;
            }
        }
        if (stale) {
            try ctx.err.writeAll("the documents changed too; run litmus sync, or untangle with --force\n");
            try next(ctx, "run litmus sync, which says what changed on each side", .{});
            return 1;
        }
    }

    // U2, U3, U4, U5, U6: plan the edits file by file.
    var plan = untangle.Plan.init(ctx.arena, built.docs);
    var on_disk: std.ArrayList(untangle.FileText) = .empty;
    for (built.files) |file| {
        const text = try output.readOrNull(ctx.io, ctx.arena, dir, file.path) orelse {
            try ctx.err.print("{s}: missing; left alone\n", .{file.path});
            continue;
        };
        try on_disk.append(ctx.arena, .{ .path = file.path, .text = text });
        if (!std.mem.eql(u8, text, file.text)) try untangle.planFile(&plan, file, text);
    }
    // U8
    var unknown = false;
    for (options.files) |path| {
        if (previous == null or previous.?.find(path) == null) {
            try ctx.err.print("{s}: not in the map; Litmus has no document for it (U8)\n", .{path});
            unknown = true;
        }
    }
    for (plan.problems.items) |problem| try ctx.err.print("{s}:{d}: {s}\n", .{ problem.file, problem.line, problem.message });
    if (plan.problems.items.len > 0) {
        try next(ctx, "fix the lines above in the tangled files, so that each keeps the indent of its excerpt, then run untangle again; nothing was written", .{});
        return 1;
    }
    if (unknown) {
        try next(ctx, "add the files above to a document by hand, or with litmus adopt, if they should have one", .{});
        return 1;
    }
    if (plan.edits.items.len == 0) {
        try ctx.out.writeAll("nothing to untangle\n");
        if (try refreshMap(ctx, built, map_dir, map_text)) try ctx.out.writeAll("updated the map\n");
        try next(ctx, "nothing", .{});
        return 0;
    }

    // U9: only edits that tangle back to the files are written.
    const edited = try untangle.applyEdits(ctx.arena, built.docs, plan.edits.items);
    if (try untangle.verify(ctx.arena, edited, options.positional, on_disk.items)) |message| {
        try ctx.err.print("U9: {s}; no document was written\n", .{message});
        try next(ctx, "look at the line above: a changed line probably reads as a block delimiter or an excerpt command; change it in the tangled file and run untangle again", .{});
        return 1;
    }
    var touched: u32 = 0;
    for (edited, built.docs) |new, old| {
        if (new.lines.ptr == old.lines.ptr) continue;
        try output.writeAtomic(ctx.io, Io.Dir.cwd(), old.path, try untangle.render(ctx.arena, new), false);
        touched += 1;
    }

    // The documents moved, so the map is made again. The files are equal to what the
    // documents tangle to now, so none of them is written.
    const after = (try build(ctx, options.positional)) orelse return 1;
    const new_map = try map.render(ctx.arena, after.docs, after.files);
    if (built.companion) {
        // R2: a companion writes its map, and nothing under DIR.
        try output.writeAtomic(ctx.io, map_dir, output.map_path, new_map, false);
    } else {
        const outcome = try output.write(ctx.io, ctx.arena, dir, after.files, new_map, options.force);
        if (outcome.conflicts.len > 0 or outcome.bad_map != null) {
            try ctx.err.writeAll("litmus: the map could not be updated\n");
            return 1;
        }
    }

    // The report: what was done, and what is left for the writer.
    const sorted = try untangle.sortedEdits(ctx.arena, plan.edits.items);
    try ctx.out.print("changed {d} {s}, removed {d} {s}, added {d} {s}, in {d} {s}\n", .{
        plan.changed, lines(plan.changed), plan.removed, lines(plan.removed), plan.added, lines(plan.added), touched, if (touched == 1) "document" else "documents",
    });
    for (plan.growth.items) |g| {
        const label = g.block.label;
        try ctx.out.print("needs prose: {s}:{d} ({s} of {s}) grew by {d} {s}\n", .{
            built.docs[label.doc].path,
            untangle.shifted(sorted, label.doc, label.line),
            label.name orelse "file root",
            label.file,
            g.added,
            lines(g.added),
        });
    }
    for (plan.placements.items) |p| {
        const doc = built.docs[p.doc].path;
        const where = untangle.shifted(sorted, p.doc, p.doc_line);
        switch (p.kind) {
            .after_command => try ctx.out.print("placed at a boundary: {s}:{d} went after \"… {s}\" at {s}:{d}\n", .{ p.file, p.line, p.name, doc, where }),
            .before_command => try ctx.out.print("placed at a boundary: {s}:{d} went before \"… {s}\" at {s}:{d}\n", .{ p.file, p.line, p.name, doc, where }),
            .block_start => try ctx.out.print("placed at a boundary: {s}:{d} went to the start of the block at {s}:{d}\n", .{ p.file, p.line, doc, untangle.shifted(sorted, p.doc, p.block.label.line) }),
            .block_end => try ctx.out.print("placed at a boundary: {s}:{d} went to the end of the block at {s}:{d}\n", .{ p.file, p.line, doc, untangle.shifted(sorted, p.doc, p.block.label.line) }),
        }
    }
    // N1: the prose is the writer's work, in the style of the document it goes in.
    const grown = plan.growth.items.len;
    if (grown == 0) {
        try next(ctx, "run litmus check", .{});
    } else if (built.docs[plan.growth.items[0].block.label.doc].style) |style| {
        try next(ctx, "write prose for the {d} {s} listed above, following the style in {s}, then run litmus check", .{ grown, if (grown == 1) "block" else "blocks", style });
    } else {
        try next(ctx, "write prose for the {d} {s} listed above, then run litmus check", .{ grown, if (grown == 1) "block" else "blocks" });
    }
    return 0;
}

const SyncResult = struct {
    code: u8,
    /// The files that a watcher should look at (W2): the documents of the set, and the tangled files.
    watched: []const []const u8 = &.{},
};

/// One run of sync (U7). `args` are the arguments of the command, which tangle and untangle read again.
fn syncOnce(ctx: Context, options: Options, args: []const []const u8) !SyncResult {
    var found: []const types.Document = &.{};
    const built = (try buildInto(ctx, options.positional, &found)) orelse {
        return .{ .code = 1, .watched = try watchedPaths(ctx, options, found, &.{}) };
    };
    const watched = try watchedPaths(ctx, options, built.docs, built.files);

    var dir = Io.Dir.cwd().openDir(ctx.io, options.out_dir, .{}) catch |e| {
        try ctx.err.print("{s}: {s}\n", .{ options.out_dir, @errorName(e) });
        return .{ .code = 1, .watched = watched };
    };
    defer dir.close(ctx.io);
    var map_dir = Io.Dir.cwd().openDir(ctx.io, mapDirPath(options, built.companion), .{}) catch |e| {
        try ctx.err.print("{s}: {s}\n", .{ mapDirPath(options, built.companion), @errorName(e) });
        return .{ .code = 1, .watched = watched };
    };
    defer map_dir.close(ctx.io);
    const map_text = try output.readOrNull(ctx.io, ctx.arena, map_dir, output.map_path);
    const previous: ?map.Map = if (map_text) |text| map.read(ctx.arena, text) catch null else null;

    const states = try ctx.arena.alloc(sync.FileState, built.files.len);
    for (built.files, states) |file, *state| {
        const text = try output.readOrNull(ctx.io, ctx.arena, dir, file.path);
        const recorded = if (previous) |p| (if (p.find(file.path)) |entry| entry.hash else null) else null;
        const disk_hash: ?[]const u8 = if (text) |bytes| &map.hashHex(bytes) else null;
        state.* = sync.stateOf(recorded, &map.hashHex(file.text), disk_hash);
    }
    switch (sync.direction(states)) {
        .in_sync => {
            try ctx.out.writeAll("in sync\n");
            if (try refreshMap(ctx, built, map_dir, map_text)) try ctx.out.writeAll("updated the map\n");
            try next(ctx, "nothing", .{});
            return .{ .code = 0, .watched = watched };
        },
        .untangle => {
            try ctx.out.writeAll("the files changed: untangling\n");
            return .{ .code = try untangleCommand(ctx, args), .watched = watched };
        },
        .tangle => {
            if (built.companion) {
                // R5: a companion never writes to the code.
                try ctx.err.writeAll("R5: the code in the documents changed, and the documents are a companion of the code, so it is not tangled\n");
                const differences = try compare.compare(ctx.io, ctx.arena, dir, built.docs, built.files);
                for (differences) |difference| try difference.print(ctx.err);
                try next(ctx, "undo the change in the document, or run litmus untangle --force to take the code's version", .{});
                return .{ .code = 1, .watched = watched };
            }
            try ctx.out.writeAll("the documents changed: tangling\n");
            const code = try tangleCommand(ctx, args);
            if (code == 0) try next(ctx, "nothing; the files follow the documents", .{});
            return .{ .code = code, .watched = watched };
        },
        .stop => {
            try ctx.err.writeAll("both sides changed, or it is not known which did; nothing was done\n");
            for (built.files, states) |file, state| {
                const what = switch (state) {
                    .in_sync => continue,
                    .files_changed => "the file changed",
                    .documents_changed => "the documents changed",
                    .both_changed => "the file and the documents changed",
                    .unknown => "there is no map entry, and the file differs from its tangled text",
                };
                try ctx.err.print("{s}: {s}\n", .{ file.path, what });
            }
            const differences = try compare.compare(ctx.io, ctx.arena, dir, built.docs, built.files);
            for (differences) |difference| try difference.print(ctx.err);
            try next(ctx, "decide which side is right for each file above: undo the change on the other side, or carry it over by hand, then run litmus sync again", .{});
            return .{ .code = 1, .watched = watched };
        },
    }
}

fn syncCommand(ctx: Context, args: []const []const u8) !u8 {
    const options = (try parseOptions(ctx, args, .{})) orelse return 2;
    if (!try documentsOk(ctx, options.positional)) return 2;
    return (try syncOnce(ctx, options, args)).code;
}

/// What watch remembers between looks: the files it watches and what it saw of them. It
/// owns an arena, which is replaced as a whole.
const Seen = struct {
    arena: std.heap.ArenaAllocator,
    paths: []const []const u8,
    snapshot: watch.Snapshot,

    fn take(io: Io, paths: []const []const u8) !Seen {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const copies = try arena.allocator().alloc([]const u8, paths.len);
        for (paths, copies) |path, *copy| copy.* = try arena.allocator().dupe(u8, path);
        return .{ .arena = arena, .paths = copies, .snapshot = try watch.take(io, arena.allocator(), copies) };
    }

    fn deinit(self: *Seen) void {
        self.arena.deinit();
    }
};

fn seconds(io: Io, since: Io.Timestamp) f64 {
    const ns = since.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
    return @as(f64, @floatFromInt(ns)) / 1e9;
}

fn watchCommand(ctx: Context, args: []const []const u8) !u8 {
    const options = (try parseOptions(ctx, args, .{ .interval = true })) orelse return 2;
    if (!try documentsOk(ctx, options.positional)) return 2;
    // Tangle and untangle read the arguments again, and do not know `--interval`.
    var inner: std.ArrayList([]const u8) = .empty;
    var skip = false;
    for (args) |arg| {
        if (skip) {
            skip = false;
        } else if (std.mem.eql(u8, arg, "--interval")) {
            skip = true;
        } else try inner.append(ctx.arena, arg);
    }
    const started = Io.Timestamp.now(ctx.io, .awake);
    const interval = Io.Duration.fromMilliseconds(@intCast(options.interval_ms));
    var debounce: watch.Debounce = .{ .quiet = @intCast(options.interval_ms * std.time.ns_per_ms) };

    var reason: []const u8 = "start";
    var seen: Seen = undefined;
    var first = true;
    while (true) {
        // W1, W4: run sync, and look at the files again when it is over.
        {
            var run_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer run_arena.deinit();
            var run_ctx = ctx;
            run_ctx.arena = run_arena.allocator();
            try ctx.out.print("[{d:.1}s] {s}\n", .{ seconds(ctx.io, started), reason });
            const result = syncOnce(run_ctx, options, inner.items) catch |e| blk: {
                try ctx.err.print("litmus: {s}\n", .{@errorName(e)});
                break :blk SyncResult{ .code = 1 };
            };
            const fresh = try Seen.take(ctx.io, result.watched);
            if (!first) seen.deinit();
            seen = fresh;
            first = false;
            try ctx.out.flush();
            try ctx.err.flush();
        }

        // W1, W3: look every interval, until something changed and then stayed quiet.
        var last: ?Seen = null;
        defer if (last) |*l| l.deinit();
        while (true) {
            try ctx.io.sleep(interval, .awake);
            const now = try Seen.take(ctx.io, seen.paths);
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            const before = if (last) |l| l.snapshot else seen.snapshot;
            const moved = (try watch.changed(scratch.allocator(), before, now.snapshot)).len > 0;
            if (last) |*l| l.deinit();
            last = now;
            const t_now: i64 = @intCast(Io.Timestamp.now(ctx.io, .awake).nanoseconds);
            if (!debounce.observe(moved, t_now)) continue;
            // What changed since the run, named for the heading (W3).
            const names = try watch.changed(scratch.allocator(), seen.snapshot, last.?.snapshot);
            reason = try std.fmt.allocPrint(ctx.arena, "changed: {s}", .{try std.mem.join(scratch.allocator(), ", ", names)});
            break;
        }
    }
}

/// W2: the documents of the set and the tangled files, as paths from the current directory.
fn watchedPaths(ctx: Context, options: Options, docs: []const types.Document, files: []const tangle.Tangled) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    for (docs) |doc| try paths.append(ctx.arena, doc.path);
    for (files) |file| {
        const path = if (std.mem.eql(u8, options.out_dir, ".")) file.path else try std.fs.path.join(ctx.arena, &.{ options.out_dir, file.path });
        try paths.append(ctx.arena, path);
    }
    return paths.items;
}

/// The folders that adopt never looks in (A1).
const skipped_folders = [_][]const u8{ "zig-out", "build", "DerivedData", "node_modules", "Pods" };

/// A1: the files of a path under `dir`, a file itself or the files in a folder, in sorted order.
fn collectFiles(ctx: Context, dir: Io.Dir, path: []const u8, out: *std.ArrayList([]const u8)) !void {
    const stat = dir.statFile(ctx.io, path, .{}) catch |e| {
        try ctx.err.print("{s}: {s}\n", .{ path, @errorName(e) });
        return error.NotFound;
    };
    if (stat.kind != .directory) {
        try out.append(ctx.arena, path);
        return;
    }
    var sub = try dir.openDir(ctx.io, path, .{ .iterate = true });
    defer sub.close(ctx.io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = sub.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const skip = entry.kind == .directory and for (skipped_folders) |s| {
            if (std.mem.eql(u8, s, entry.name)) break true;
        } else false;
        if (!skip) try names.append(ctx.arena, try ctx.arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    for (names.items) |name| {
        const child = if (std.mem.eql(u8, path, ".")) name else try std.fs.path.join(ctx.arena, &.{ path, name });
        try collectFiles(ctx, dir, child, out);
    }
}

fn adoptCommand(ctx: Context, args: []const []const u8) !u8 {
    const options = (try parseOptions(ctx, args, .{ .adopt = true })) orelse return 2;
    if (options.positional.len < 2) {
        try ctx.err.writeAll(usage);
        return 2;
    }
    const document = options.positional[0];
    if (docset.formatOf(document) != .asciidoc) {
        try ctx.err.print("litmus: adopt writes asciidoc, so {s} must end in .adoc\n", .{document});
        return 2;
    }
    const cwd = Io.Dir.cwd();
    if (cwd.statFile(ctx.io, document, .{})) |_| {
        try ctx.err.print("{s}: exists; adopt only writes a new document (A2)\n", .{document});
        return 1;
    } else |_| {}
    if (options.style) |style| {
        const path = try docset.joinPath(ctx.arena, std.fs.path.dirname(document) orelse "", style);
        if (cwd.statFile(ctx.io, path, .{})) |_| {} else |_| {
            try ctx.err.print("{s}: the style file does not exist (C12)\n", .{path});
            return 1;
        }
    }
    // A9: the changes to mark, read before anything is written.
    var changes: []const marks.FileChange = &.{};
    if (options.diff) |diff_path| {
        const diff_text = cwd.readFileAlloc(ctx.io, diff_path, ctx.arena, .limited(1 << 30)) catch |e| {
            try ctx.err.print("{s}: {s}\n", .{ diff_path, @errorName(e) });
            return 1;
        };
        const parsed = try marks.parse(ctx.arena, diff_text);
        if (parsed.problem) |p| {
            try ctx.err.print("{s}:{d}: {s}; nothing was written\n", .{ diff_path, p.line, p.reason });
            return 1;
        }
        changes = parsed.files;
    }
    var dir = cwd.openDir(ctx.io, options.out_dir, .{}) catch |e| {
        try ctx.err.print("{s}: {s}\n", .{ options.out_dir, @errorName(e) });
        return 1;
    };
    defer dir.close(ctx.io);

    // A1: the files, and their text. Files that hold a zero byte are not text.
    var paths: std.ArrayList([]const u8) = .empty;
    for (options.positional[1..]) |path| {
        const joined = try docset.joinPath(ctx.arena, "", path);
        collectFiles(ctx, dir, if (joined.len == 0) "." else joined, &paths) catch return 1;
    }
    var sources: std.ArrayList(adopt.Source) = .empty;
    for (paths.items) |path| {
        const text = try dir.readFileAlloc(ctx.io, path, ctx.arena, .limited(1 << 30));
        if (std.mem.indexOfScalar(u8, text, 0) != null) {
            try ctx.out.print("skipped {s}: not text\n", .{path});
            continue;
        }
        try sources.append(ctx.arena, .{ .path = path, .text = text });
    }
    if (sources.items.len == 0) {
        try ctx.err.writeAll("litmus: no text files to adopt\n");
        return 1;
    }

    const stem = std.fs.path.stem(document);
    const result = try adopt.adopt(ctx.arena, sources.items, .{ .title = stem, .style = options.style, .companion = options.companion });
    for (result.refusals) |r| try ctx.err.print("{s}:{d}: {s}\n", .{ r.path, r.line, r.reason });
    if (result.refusals.len > 0) {
        try next(ctx, "leave the files above out, or change them, and run adopt again; nothing was written", .{});
        return 1;
    }
    var new_doc: types.Document = .{
        .path = document,
        .format = .asciidoc,
        .lines = try @import("scan.zig").splitLines(ctx.arena, result.text),
        .dir = std.fs.path.dirname(document) orelse "",
    };
    var text = result.text;
    var changed_blocks: u32 = 0;
    if (options.diff != null) {
        const marked = try marks.markDocument(ctx.arena, new_doc, changes);
        text = marked.text;
        changed_blocks = marked.blocks;
        new_doc.lines = try @import("scan.zig").splitLines(ctx.arena, text);
    }
    // A8: the document must tangle to the files before it is written.
    var originals: std.ArrayList(untangle.FileText) = .empty;
    for (sources.items) |source| try originals.append(ctx.arena, .{ .path = source.path, .text = source.text });
    if (try untangle.verify(ctx.arena, &.{new_doc}, &.{document}, originals.items)) |message| {
        try ctx.err.print("{s}; this is a fault in Litmus, and nothing was written\n", .{message});
        return 1;
    }
    try output.writeAtomic(ctx.io, cwd, document, text, false);

    // A8: the map, so that untangle, sync and watch work at once.
    const built = (try build(ctx, &.{document})) orelse return 1;
    const opts_for_map: Options = .{ .out_dir = options.out_dir, .positional = &.{document} };
    try cwd.createDirPath(ctx.io, mapDirPath(opts_for_map, built.companion));
    var map_dir = try cwd.openDir(ctx.io, mapDirPath(opts_for_map, built.companion), .{});
    defer map_dir.close(ctx.io);
    try output.writeAtomic(ctx.io, map_dir, output.map_path, try map.render(ctx.arena, built.docs, built.files), false);

    try ctx.out.print("wrote {s}: {d} {s}, {d} excerpts\n", .{ document, sources.items.len, if (sources.items.len == 1) "file" else "files", result.excerpts });
    if (options.diff) |diff_path| {
        try ctx.out.print("marked {d} {s} that {s} changed (A9); litmus blocks --changed lists them\n", .{ changed_blocks, if (changed_blocks == 1) "block" else "blocks", diff_path });
    }
    if (options.style) |style| {
        try next(ctx, "read the code, propose an outline of chapters and the order that explains it best, and after it is agreed write the prose following the style in {s}; run litmus check after each chapter", .{style});
    } else {
        try next(ctx, "read the code, propose an outline of chapters and the order that explains it best, and after it is agreed write the prose; run litmus check after each chapter", .{});
    }
    return 0;
}

/// L10: the style file of each document of the set.
fn styleCommand(ctx: Context, args: []const []const u8) !u8 {
    const options = (try parseOptions(ctx, args, .{})) orelse return 2;
    if (!try documentsOk(ctx, options.positional)) return 2;
    var diags = types.Diagnostics.init(ctx.arena);
    var fs: DiskFs = .{ .io = ctx.io };
    const set = try docset.load(ctx.arena, &fs, options.positional, &diags);
    for (set.docs) |doc| try ctx.out.print("{s}: {s}\n", .{ doc.path, doc.style orelse "none" });
    if (diags.list.items.len == 0) return 0;
    try printDiagnostics(ctx, &diags, set.docs);
    return 1;
}

/// B1, B2: one line per labeled block, for a writer who has not read the documents.
fn blocksCommand(ctx: Context, args: []const []const u8) !u8 {
    const options = (try parseOptions(ctx, args, .{ .changed = true })) orelse return 2;
    if (!try documentsOk(ctx, options.positional)) return 2;
    var diags = types.Diagnostics.init(ctx.arena);
    var fs: DiskFs = .{ .io = ctx.io };
    const set = try docset.load(ctx.arena, &fs, options.positional, &diags);
    if (diags.list.items.len > 0) {
        try printDiagnostics(ctx, &diags, set.docs);
        return 1;
    }
    for (set.blocks) |block| {
        const doc = set.docs[block.label.doc];
        const m = marks.blockMarks(doc, block);
        if (options.changed and m.changed == null and m.removed == null) continue;
        try ctx.out.print("{s}:{d}  {s}  {s}  {d} {s}", .{ doc.path, block.label.line, block.label.file, block.label.name orelse "(file root)", block.lines.len, if (block.lines.len == 1) "line" else "lines" });
        if (m.changed) |c| try ctx.out.print("  changed {s}", .{c});
        if (m.removed) |r| try ctx.out.print("  removed {s}", .{r});
        try ctx.out.writeAll("\n");
    }
    return 0;
}

/// S1 to S4: the output from the skeleton's blocks and the template's prose.
fn assembleCommand(ctx: Context, args: []const []const u8) !u8 {
    const options = (try parseOptions(ctx, args, .{})) orelse return 2;
    if (options.positional.len != 3) {
        try ctx.err.writeAll(usage);
        return 2;
    }
    const skeleton, const template, const output_path = options.positional[0..3].*;
    for (options.positional) |path| if (docset.formatOf(path) != .asciidoc) {
        try ctx.err.print("litmus: assemble reads and writes asciidoc, so {s} must end in .adoc\n", .{path});
        return 2;
    };
    const target = try docset.joinPath(ctx.arena, "", output_path);
    if (std.mem.eql(u8, target, try docset.joinPath(ctx.arena, "", skeleton)) or std.mem.eql(u8, target, try docset.joinPath(ctx.arena, "", template))) {
        try ctx.err.print("{s}: is the skeleton or the template, which assemble never overwrites (S4)\n", .{output_path});
        return 1;
    }

    // The skeleton must be a whole, checked document set.
    var diags = types.Diagnostics.init(ctx.arena);
    var fs: DiskFs = .{ .io = ctx.io };
    const set = try docset.load(ctx.arena, &fs, &.{skeleton}, &diags);
    if (diags.list.items.len == 0) {
        const resolved = try resolve.resolve(ctx.arena, set.docs, set.blocks, &diags);
        if (diags.list.items.len == 0) {
            const files = try tangle.tangleAll(ctx.arena, resolved);
            return assembleWith(ctx, set, files, template, output_path);
        }
    }
    try printDiagnostics(ctx, &diags, set.docs);
    return 1;
}

fn assembleWith(ctx: Context, set: docset.Set, files: []const tangle.Tangled, template: []const u8, output_path: []const u8) !u8 {
    const cwd = Io.Dir.cwd();
    const template_text = cwd.readFileAlloc(ctx.io, template, ctx.arena, .limited(1 << 30)) catch |e| {
        try ctx.err.print("{s}: {s}\n", .{ template, @errorName(e) });
        return 1;
    };
    const template_lines = try @import("scan.zig").splitLines(ctx.arena, template_text);
    const result = try assemble.assemble(ctx.arena, set.docs, set.blocks, template_lines);
    for (result.problems) |p| {
        try ctx.err.print("{s}:{d}: {s}\n", .{ if (p.in_skeleton) set.docs[0].path else template, p.line, p.message });
    }
    if (result.problems.len > 0) {
        try next(ctx, "fix the placeholders above in {s} and run assemble again; nothing was written", .{template});
        return 1;
    }

    // S4: the output must tangle to the skeleton's files.
    const out_doc: types.Document = .{
        .path = output_path,
        .format = .asciidoc,
        .lines = try @import("scan.zig").splitLines(ctx.arena, result.text),
        .dir = std.fs.path.dirname(output_path) orelse "",
    };
    var wanted: std.ArrayList(untangle.FileText) = .empty;
    for (files) |file| try wanted.append(ctx.arena, .{ .path = file.path, .text = file.text });
    if (try untangle.verify(ctx.arena, &.{out_doc}, &.{output_path}, wanted.items)) |message| {
        try ctx.err.print("{s}; nothing was written\n", .{message});
        try next(ctx, "the template's own labeled blocks change the code: make them illustrations, without a label", .{});
        return 1;
    }
    try output.writeAtomic(ctx.io, cwd, output_path, result.text, false);
    try ctx.out.print("wrote {s}: {d} {s} placed, {d} in the rest\n", .{ output_path, result.placed, if (result.placed == 1) "block" else "blocks", result.rest });
    try next(ctx, "run litmus check on {s} with the skeleton's -o, then render it", .{output_path});
    return 0;
}

/// H1 to H3: the review skill, and the home of Litmus.
fn setupCommand(ctx: Context, env: *const std.process.Environ.Map, args: []const []const u8) !u8 {
    const options = (try parseOptions(ctx, args, .{})) orelse return 2;
    if (options.positional.len > 0 or !std.mem.eql(u8, options.out_dir, ".")) {
        try ctx.err.writeAll(usage);
        return 2;
    }
    const dirs = (try setup.dirs(ctx.arena, env)) orelse {
        try ctx.err.writeAll("litmus: setup needs HOME, or LITMUS_HOME and CLAUDE_CONFIG_DIR (H1)\n");
        return 1;
    };
    return setup.run(ctx.io, ctx.arena, dirs, ctx.out, ctx.err);
}

fn initCommand(ctx: Context, exe: []const u8, args: []const []const u8) !u8 {
    const options = (try parseOptions(ctx, args, .{})) orelse return 2;
    if (!try documentsOk(ctx, options.positional)) return 2;
    return init_command.run(ctx.io, ctx.arena, .{ .exe = exe, .dir = options.out_dir, .documents = options.positional }, ctx.out, ctx.err);
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const out = &out_writer.interface;
    var err_buf: [4096]u8 = undefined;
    var err_writer: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    const err = &err_writer.interface;
    defer out.flush() catch {};
    defer err.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try err.writeAll(usage);
        return 2;
    }
    const ctx: Context = .{ .io = io, .arena = arena, .out = out, .err = err };
    const command = args[1];
    const rest = args[2..];
    const code = run: {
        if (std.mem.eql(u8, command, "tangle")) break :run tangleCommand(ctx, rest);
        if (std.mem.eql(u8, command, "check")) break :run checkCommand(ctx, rest);
        if (std.mem.eql(u8, command, "where")) break :run whereCommand(ctx, rest);
        if (std.mem.eql(u8, command, "init")) break :run initCommand(ctx, args[0], rest);
        if (std.mem.eql(u8, command, "untangle")) break :run untangleCommand(ctx, rest);
        if (std.mem.eql(u8, command, "sync")) break :run syncCommand(ctx, rest);
        if (std.mem.eql(u8, command, "watch")) break :run watchCommand(ctx, rest);
        if (std.mem.eql(u8, command, "style")) break :run styleCommand(ctx, rest);
        if (std.mem.eql(u8, command, "adopt")) break :run adoptCommand(ctx, rest);
        if (std.mem.eql(u8, command, "blocks")) break :run blocksCommand(ctx, rest);
        if (std.mem.eql(u8, command, "assemble")) break :run assembleCommand(ctx, rest);
        if (std.mem.eql(u8, command, "setup")) break :run setupCommand(ctx, init.environ_map, rest);
        if (std.mem.eql(u8, command, "guide")) {
            try out.writeAll(guide_text);
            break :run 0;
        }
        try err.print("litmus: unknown command {s}\n", .{command});
        try err.writeAll(usage);
        break :run 2;
    } catch |e| {
        try err.print("litmus: {s}\n", .{@errorName(e)});
        return 1;
    };
    return code;
}
