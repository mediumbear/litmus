# Working on Litmus

Litmus is a literate programming tool: it tangles asciidoc and Markdown documents into source files, and records where each line came from.

- `doc/litmus.adoc` is the spec and the source of truth. Every behaviour traces to one of its rules (L, T, C, M, I), and each test names the rule it checks. If the code needs something the spec does not say, change the spec first.
- `doc/plan.md` is the implementation plan. Work through its phases in order, and commit at the end of each.
- Zig 0.17.0, installed into `tools/zig` by `scripts/get-zig.sh`. Zig 0.17's `std.Io` is new: read the standard library's source under `tools/zig/lib/std`, not older documentation.
- Only the standard library. No regular expressions. Speed matters: Litmus runs on every save.
- Run `zig build test` after every change. Before finishing, run `zig build cases` too, and `zig build self` once it exists.
- Plans and notes are Markdown. The spec and the literate documents are asciidoc, rendered by `doc/build.sh` into `doc/build/`. Write all of them in plain, direct prose.

<!-- litmus -->
This project uses Litmus: some source files are tangled from documents that
explain them. Run `zig-out/bin/litmus guide` before changing any file listed in
.litmus/map. After editing a tangled file, carry the change into the
documents with `zig-out/bin/litmus untangle doc/implementation.adoc`, and write the prose it asks for.
Tangle with `zig-out/bin/litmus tangle doc/implementation.adoc`, and make sure
`zig-out/bin/litmus check doc/implementation.adoc` passes before finishing.
<!-- /litmus -->
