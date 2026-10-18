const std = @import("std");

comptime {
    const v = @import("builtin").zig_version;
    if (v.major == 0 and v.minor < 17) @compileError("Litmus needs Zig 0.17 or later; scripts/get-zig.sh installs it into tools/zig");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const litmus = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{ .name = "litmus", .root_module = litmus });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run litmus").dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_module });
    const test_step = b.step("test", "Run the unit tests, and check that the book still tangles to the sources");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // The book, where there is one, must tangle to the files that are here. The
    // sources tangled from it into a temporary directory do not have it.
    const book = "doc/implementation.adoc";
    if (std.Io.Dir.cwd().access(b.graph.io, book, .{})) |_| {
        const check_book = b.addRunArtifact(exe);
        check_book.addArgs(&.{ "check", "-o", ".", book });
        check_book.setCwd(b.path("."));
        // It reads files that the build does not know about, so it must always run.
        check_book.has_side_effects = true;
        test_step.dependOn(&check_book.step);
    } else |_| {}

    const cases = b.addSystemCommand(&.{ "bash", "test/run.sh", "cases" });
    cases.addArtifactArg(exe);
    b.step("cases", "Run the golden tests").dependOn(&cases.step);

    const self = b.addSystemCommand(&.{ "bash", "test/run.sh", "self" });
    self.addArtifactArg(exe);
    b.step("self", "Tangle the book, build Litmus from the result, and tangle again").dependOn(&self.step);
}
