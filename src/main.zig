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

const Allocator = std.mem.Allocator;
const Io = std.Io;

const usage =
    \\Usage: litmus tangle [-o DIR] [--force] DOCUMENT...
    \\       litmus check [-o DIR] DOCUMENT...
    \\       litmus where [-o DIR] FILE:LINE
    \\       litmus guide
    \\       litmus init [-o DIR] DOCUMENT...
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
    positional: []const []const u8 = &.{},
};

/// Reads `-o DIR`, and `--force` when allowed. Prints the problem and returns null on a usage error.
fn parseOptions(ctx: Context, args: []const []const u8, allow_force: bool) !?Options {
    var options: Options = .{};
    var positional: std.ArrayList([]const u8) = .empty;
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
        } else if (allow_force and std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (arg.len > 1 and arg[0] == '-') {
            try ctx.err.print("litmus: unknown option {s}\n", .{arg});
            return null;
        } else {
            try positional.append(ctx.arena, arg);
        }
    }
    options.positional = positional.items;
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
};

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
    var diags = types.Diagnostics.init(ctx.arena);
    var fs: DiskFs = .{ .io = ctx.io };
    const set = try docset.load(ctx.arena, &fs, documents, &diags);
    // Mistakes in the structure make the checks of the whole set misleading.
    if (diags.list.items.len == 0) {
        const resolved = try resolve.resolve(ctx.arena, set.docs, set.blocks, &diags);
        if (diags.list.items.len == 0) {
            return .{ .docs = set.docs, .files = try tangle.tangleAll(ctx.arena, resolved) };
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
    const options = (try parseOptions(ctx, args, true)) orelse return 2;
    if (!try documentsOk(ctx, options.positional)) return 2;
    const built = (try build(ctx, options.positional)) orelse return 1;

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
    const options = (try parseOptions(ctx, args, false)) orelse return 2;
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
    const options = (try parseOptions(ctx, args, false)) orelse return 2;
    if (options.positional.len != 1) {
        try ctx.err.writeAll(usage);
        return 2;
    }
    const target = options.positional[0];
    const colon = std.mem.lastIndexOfScalar(u8, target, ':') orelse {
        try ctx.err.writeAll(usage);
        return 2;
    };
    const line = std.fmt.parseInt(u32, target[colon + 1 ..], 10) catch {
        try ctx.err.writeAll(usage);
        return 2;
    };
    const path = target[0..colon];

    var dir = Io.Dir.cwd().openDir(ctx.io, options.out_dir, .{}) catch |e| {
        try ctx.err.print("{s}: {s}\n", .{ options.out_dir, @errorName(e) });
        return 1;
    };
    defer dir.close(ctx.io);
    const map_text = try output.readOrNull(ctx.io, ctx.arena, dir, output.map_path) orelse {
        try ctx.err.print("{s}/{s} does not exist; run litmus tangle first\n", .{ options.out_dir, output.map_path });
        return 1;
    };
    const parsed = map.read(ctx.arena, map_text) catch {
        try ctx.err.print("{s}/{s} cannot be read; run litmus tangle first\n", .{ options.out_dir, output.map_path });
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

fn initCommand(ctx: Context, exe: []const u8, args: []const []const u8) !u8 {
    const options = (try parseOptions(ctx, args, false)) orelse return 2;
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
