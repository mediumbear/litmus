//! The `setup` command (H1 to H3): installs what Litmus brings for the user rather than
//! for a project: the review skill, and the weave, the widget kit and the script that
//! renders a review without a network.

const std = @import("std");
const output = @import("output.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// A file that setup writes, relative to the directory it belongs in.
pub const File = struct { path: []const u8, text: []const u8, executable: bool = false };

/// H2: the files of the home of Litmus. `build.zig` makes them importable by these names.
pub const home_files = [_]File{
    .{ .path = "render.sh", .text = @embedFile("render.sh"), .executable = true },
    .{ .path = "weave/litmus-weave.rb", .text = @embedFile("litmus-weave.rb") },
    .{ .path = "kit/kit.js", .text = @embedFile("kit.js") },
    .{ .path = "kit/stepper.js", .text = @embedFile("stepper.js") },
    .{ .path = "kit/flow.js", .text = @embedFile("flow.js") },
    .{ .path = "kit/timeline.js", .text = @embedFile("timeline.js") },
    .{ .path = "kit/sandbox.js", .text = @embedFile("sandbox.js") },
    .{ .path = "kit/layers3d.js", .text = @embedFile("layers3d.js") },
};

/// H2: the skill, in Claude Code's directory.
pub const skill = File{ .path = "skills/litmus-review/SKILL.md", .text = @embedFile("review-skill.md") };

pub const Dirs = struct { home: []const u8, claude: []const u8 };

/// H1: the home of Litmus and Claude Code's directory, from the environment. Null when a
/// directory is not set and there is no `HOME` to put it in.
pub fn dirs(arena: Allocator, env: *const std.process.Environ.Map) !?Dirs {
    const home = env.get("HOME");
    const litmus = env.get("LITMUS_HOME") orelse if (home) |h| try std.fs.path.join(arena, &.{ h, ".litmus" }) else return null;
    const claude = env.get("CLAUDE_CONFIG_DIR") orelse if (home) |h| try std.fs.path.join(arena, &.{ h, ".claude" }) else return null;
    return .{ .home = litmus, .claude = claude };
}

/// H2, H3: writes each file that is missing or differs, and says so. Nothing else is touched.
pub fn run(io: Io, arena: Allocator, d: Dirs, out: *Io.Writer, err: *Io.Writer) !u8 {
    const cwd = Io.Dir.cwd();
    var failed = false;
    const Target = struct { dir: []const u8, file: File };
    var targets: [home_files.len + 1]Target = undefined;
    targets[0] = .{ .dir = d.claude, .file = skill };
    for (home_files, 1..) |file, i| targets[i] = .{ .dir = d.home, .file = file };
    for (targets) |target| {
        const path = try std.fs.path.join(arena, &.{ target.dir, target.file.path });
        const existing = output.readOrNull(io, arena, cwd, path) catch |e| {
            try err.print("{s}: {s}\n", .{ path, @errorName(e) });
            failed = true;
            continue;
        };
        if (existing) |text| if (std.mem.eql(u8, text, target.file.text)) continue;
        output.writeAtomic(io, cwd, path, target.file.text, target.file.executable) catch |e| {
            try err.print("{s}: {s}\n", .{ path, @errorName(e) });
            failed = true;
            continue;
        };
        try out.print("{s} {s}\n", .{ if (existing == null) "created" else "updated", path });
    }
    return if (failed) 1 else 0;
}

// Tests ----------------------------------------------------------------------

const t = std.testing;

test "H1: the directories come from the environment, or from HOME" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env = std.process.Environ.Map.init(a);
    try t.expect(try dirs(a, &env) == null);
    try env.put("HOME", "/Users/me");
    const plain = (try dirs(a, &env)).?;
    try t.expectEqualStrings("/Users/me/.litmus", plain.home);
    try t.expectEqualStrings("/Users/me/.claude", plain.claude);
    try env.put("LITMUS_HOME", "/opt/litmus");
    try env.put("CLAUDE_CONFIG_DIR", "/tmp/claude");
    const set = (try dirs(a, &env)).?;
    try t.expectEqualStrings("/opt/litmus", set.home);
    try t.expectEqualStrings("/tmp/claude", set.claude);
}

test "H2: the skill and the files of the home are there" {
    try t.expect(std.mem.startsWith(u8, skill.text, "---\nname: litmus-review\n"));
    try t.expect(std.mem.startsWith(u8, home_files[0].text, "#!/usr/bin/env bash\n"));
    for (home_files) |file| try t.expect(file.text.len > 0);
}
