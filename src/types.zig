//! The types that the stages of Litmus pass to each other. Everything is
//! allocated in the run's arena, and lines are slices into the documents' text.

const std = @import("std");

pub const Format = @import("scan.zig").Format;

pub const Document = struct {
    /// The path as given on the command line, or as joined by an include (L6).
    path: []const u8,
    format: Format,
    lines: []const []const u8,
    /// The directory of `path`, without a trailing `/`; empty for the current directory.
    dir: []const u8,
    /// Whether the text ended with `\n`, so that the document can be written back as it was.
    final_newline: bool = true,
};

/// What a document command says (L1, L9). Lines count from 1.
pub const Label = struct {
    doc: u32,
    line: u32,
    /// Null for a file root.
    name: ?[]const u8,
    /// The full path, with the document's `:litmus-dir:` in front (L8).
    file: []const u8,
    executable: bool,
};

/// An excerpt command inside a labeled block (L3).
pub const Command = struct {
    /// The index of the line in the block.
    index: u32,
    indent: []const u8,
    name: []const u8,
};

pub const Block = struct {
    label: Label,
    /// The document line of the block's first line of code.
    first_line: u32,
    lines: []const []const u8,
    commands: []const Command,
};

/// A run of consecutive lines of a tangled file that come from consecutive lines of
/// one block, with the same indent (the map's lines).
pub const Run = struct {
    /// The first line in the file.
    line: u32,
    count: u32,
    doc: u32,
    doc_line: u32,
    indent: u32,
    /// The excerpt's name, or `:file:` for the file root.
    excerpt: []const u8,
    /// The expansion the run's lines are in, as an index into the file's expansions,
    /// or `no_expansion` for the file root. Untangle needs it; the map does not.
    expansion: u32 = no_expansion,
    /// The block the run's lines are lines of.
    block: ?*const Block = null,
};

pub const no_expansion = std.math.maxInt(u32);

/// One excerpt command, expanded while tangling a file.
pub const Expansion = struct {
    /// The output lines it produced, counting from 1. An excerpt with no lines has
    /// `last_line` one less than `first_line`.
    first_line: u32,
    last_line: u32,
    /// The block that holds the command, and the command's index in it.
    block: *const Block,
    command: u32,
    /// The indents of this command and all the commands around it, put together.
    prefix: []const u8,
    /// How many of those bytes belong to the commands around it, not to this one.
    outer_len: u32,
    /// How many expansions it is inside of.
    depth: u32,
};

pub const Diagnostic = struct {
    doc: u32,
    line: u32,
    message: []const u8,
};

pub const Diagnostics = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList(Diagnostic) = .empty,

    pub fn init(arena: std.mem.Allocator) Diagnostics {
        return .{ .arena = arena };
    }

    pub fn add(self: *Diagnostics, doc: u32, line: u32, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.arena, fmt, args);
        try self.list.append(self.arena, .{ .doc = doc, .line = line, .message = message });
    }

    /// Orders the diagnostics by document, then line, keeping the order of equal ones.
    pub fn sort(self: *Diagnostics) void {
        std.mem.sort(Diagnostic, self.list.items, {}, less);
    }

    fn less(_: void, a: Diagnostic, b: Diagnostic) bool {
        if (a.doc != b.doc) return a.doc < b.doc;
        return a.line < b.line;
    }
};
