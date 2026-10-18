# Implementing Litmus

This plan builds the first half of Litmus, as specified in `doc/litmus.adoc`: tangle, check, where, the map, and the guide and init commands for agents. It is written in Zig.

It ends with Litmus written as a literate document. Tangling that document must recreate Litmus's own sources byte for byte, and a Litmus built from the tangled sources must tangle the document again to the same bytes.

Untangle, watch and weave come after, each with its own plan.

## Ground Rules

- **The spec is the source of truth.** Every behaviour traces to a rule in the spec: L1–L9, T1–T6, C1–C11, M1–M5, I1–I4. Each test names the rule it checks. When the implementation finds a gap in the spec, change the spec first, then the code.
- **Zig 0.17.0, the same version as Hop,** installed into `tools/zig` by `scripts/get-zig.sh`. No dependencies beyond the standard library.
- **Fast by construction.** Read each document once. Keep lines as slices into the document's buffer. No regular expressions. One arena per run. Target: tangling 100,000 document lines takes well under 50 ms in a release build.
- **Report everything.** Errors are printed as `document:line: message`, all of them, in the order of the document set, not just the first. Exit codes: 0 for success, 1 for errors or differences, 2 for wrong usage.
- **The usual loop.** Write code and tests in `src/`, and run `zig build test` after every step. Commit at the end of each phase.
- **Plans and notes are Markdown.** The spec and the literate documents are asciidoc.

## Source Layout

| File | Responsibility |
|---|---|
| `src/main.zig` | The command line: arguments, the commands, printing errors. |
| `src/types.zig` | The types the stages share: documents, labels, blocks, runs, diagnostics. |
| `src/scan.zig` | Classifies the lines of one document, asciidoc or Markdown. The block state machine. No IO. |
| `src/parse.zig` | From classified lines to labels, blocks, excerpt commands, includes and `:litmus-dir:`. No IO. |
| `src/docset.zig` | Reads documents and follows `include::`, giving the document set in reading order. |
| `src/resolve.zig` | Groups blocks into files, file roots and excerpts, and runs the checks. |
| `src/tangle.zig` | Expands each file into its text and its runs. No IO. |
| `src/map.zig` | Writes and reads the map. |
| `src/output.zig` | Writes files: only when changed, whole, executable when asked. Reports stale files. |
| `src/compare.zig` | The `check` command's comparison of tangled text with files on disk. |
| `src/guide.txt` | The guide's text, built into the binary with `@embedFile`. |
| `src/init.zig` | The `init` command. |
| `src/tests.zig` | Imports every file, so `zig build test` runs all unit tests. |

The main types, all allocated in the run's arena (they live in `src/types.zig`):

```zig
const Document = struct { path: []const u8, format: enum { asciidoc, markdown }, lines: []const []const u8, dir: []const u8 };
const Label = struct { doc: u32, line: u32, name: ?[]const u8, file: []const u8, executable: bool };
const Block = struct { label: Label, first_line: u32, lines: []const []const u8, commands: []const Command };
const Command = struct { index: u32, indent: []const u8, name: []const u8 }; // index of the line in the block
const Run = struct { line: u32, count: u32, doc: u32, doc_line: u32, indent: u32, excerpt: []const u8 };
const Diagnostic = struct { doc: u32, line: u32, message: []const u8 };
```

## Phase 0: Set Up

1. **Archive the Odin attempt.** `src/litmus_test.odin` is not in git yet. Commit it with the other Odin files as "Archive the Odin attempt", then remove `src/*.odin` in the next commit. The user agreed to clearing the folder, and this keeps the attempt in history.
2. **Copy Hop's `scripts/get-zig.sh`.** Extend `.gitignore` with `tools/`, `zig-out/`, `.zig-cache/` and `.litmus/`.
3. **Write `build.zig`** with Hop's check for Zig 0.17. It has:
   - the `litmus` executable,
   - `zig build test` for unit tests,
   - `zig build cases` for the golden tests (Phase 7),
   - `zig build self` for the self-hosting test (Phase 8).
4. **Write `build.zig.zon`** with the name, version and minimum Zig version, so Hop can later depend on Litmus with a local path.
5. **Write `doc/build.sh`** to render the asciidoc documents with asciidoctor, like Hop's `docs/book/build.sh`, into `doc/build/`.
6. **Set up IO like Hop's `src/core/main.zig`:** `main(init: std.process.Init)`, with `std.Io.File.Writer` for stdout and stderr.

**Done when:** `zig build` makes `zig-out/bin/litmus`, which prints its usage and exits with 2, and `zig build test` runs.

## Phase 1: Scanning

`scan.zig` gives each line of a document a kind:

- prose,
- a Litmus command, with its indent and text,
- a block attribute line (`[...]`) or a block title line (`.Title`, but not `..`),
- an `include::` line,
- a `:litmus-dir:` entry,
- a block opening or closing,
- code in a block,
- a line to ignore.

**Asciidoc states:** prose, listing (remember its delimiter: four or more hyphens, closed by the same line), fenced (` ``` ` with an optional language), literal (`....`), comment (`////`), passthrough (`++++`). A line starting with `//` but not `////` is a comment line.

**Markdown states:** prose, fenced (remember the character and the length; closed by the same character, at least as long), HTML comment.

A Litmus command is the bytes `E2 80 A6` (`…`) followed by a space, after any spaces and tabs. Three full stops (`...`) are not a command.

Tests, one or more per rule:

- L2: attribute and title lines between a label and its block.
- L4: a command in a labeled block.
- L5: commands ignored in each kind of block, and on comment lines.
- L7: a `\r` stays part of its line.
- M1, M3: Markdown fences and comments.
- A five-hyphen block holding a four-hyphen line.
- Tabs as indent.
- `…` with no space after it is not a command.

**Done when:** the scanning tests pass.

## Phase 2: Parsing

`parse.zig` turns one scanned document into labels, blocks and commands.

- **Labels (L1, L9, C11).** Split the command text at `:file:` and `:executable:`, recognised only as whole words. The name is the text before `:file:`, trimmed. Any other `:word:` attribute, or no `:file:`, is C11.
- **Labels and blocks (L2, C5).** After a label, skip attribute and title lines (asciidoc) or nothing (Markdown, M2). The next line must open a block, or report C5.
- **Excerpt commands (L3, L4).** In a labeled block, every command line records its index, its indent bytes, and its name with trailing whitespace trimmed.
- **Open blocks (C6).** A block still open at the end of the document is C6.
- **Includes (L6).** `include::path[...]` outside blocks is recorded for the document set. Inside a labeled block it is C7. Inside an illustration it is ignored.
- **Directories (L8, M5, C8).** Accept `:litmus-dir:` only before the first document command, and only once. Join it to every `:file:` path of that document.
- **Paths (L1, C7).** Relative, `/`-separated, no empty or `..` parts, no leading `/`, no tab. Normalise away `./`.

Report all problems as diagnostics. Do not stop at the first.

**Done when:** the parsing tests pass, one per rule above.

## Phase 3: The Document Set

`docset.zig` reads documents and orders them.

- Read the documents named on the command line, in order. Follow each `include::` at its position, depth first, relative to the including document's directory (L6).
- `.adoc`, `.asciidoc` and `.asc` are asciidoc, and `.md` is Markdown. Any other extension is a usage error.
- C10: a document that includes itself, a document in the set twice, a missing document.
- Record document paths as they were given, joined with include directories, and normalised.

**Done when:** tests with nested includes, cycles and missing files pass.

## Phase 4: Resolving and Checking

`resolve.zig` builds files and excerpts across the whole set.

- **Files.** Each file is keyed by its full path, in order of first appearance. A file has its root blocks, its excerpts by name with their blocks in document order, and whether it is executable.
- **C1.** An excerpt command names nothing in its file. If an excerpt of that name exists in another file, the message says where.
- **C2.** An excerpt nobody uses, reported at its first label.
- **C3.** An excerpt used twice, reported at the second use, with the line of the first.
- **C4.** Cycles, searched over all excerpts, not only those reachable from a root. Two excerpts that use only each other are a cycle, and C2 would not see them.
- **C9.** `:executable:` on an excerpt.
- Sort diagnostics by document-set order, then line.

**Done when:** each check has a test that triggers it, and a test that just misses it.

## Phase 5: Tangling

`tangle.zig` expands each file.

- **T1, T2.** Expand from the root. Indents accumulate: the command's indent goes in front of every line of the expansion, including lines that came from deeper excerpts. Only lines of length zero get no indent. A line of spaces is not empty.
- **T3.** Every line ends with `\n`.
- **Runs.** While expanding, record runs. A run is consecutive output lines from consecutive lines of one block, with the same indent.
- **The spec's example is a test.** `hello.adoc` must tangle to exactly the `hello.zig` and the map shown in the spec.

**Done when:** the tests pass for the spec's example, nested indents, tabs, empty lines and `\r`.

## Phase 6: The Map and Writing Files

`map.zig` and `output.zig` put results on disk.

- **The map.** Write and read the format from the spec. Reading rejects any version other than `litmus map 1`. The map is itself written only when it changed.
- **T4.** Create directories with `Dir.createDirPath`. Read the existing file and skip the write if its text is equal. Otherwise write it whole with `Dir.createFileAtomic` (`std/Io/File/Atomic.zig`).
- **L9.** Set `File.Permissions.executable_file` on executable files. If only the permission changed, change only that.
- **T5.** Read the previous map before writing the new one. Report any file it lists that is no longer tangled. Never delete it.
- **The hash.** Each `file` line of the map records the SHA-256 of the text written, using `std.crypto.hash.sha2.Sha256`.
- **T6.** Before writing anything, check every existing file against its hash in the previous map. A file whose hash differs, or a file the map does not list that differs from its tangled text, stops the whole tangle: report each one, write nothing. `--force` skips this check.

**Done when:** a second tangle of unchanged documents writes nothing, which the tests check by modification times, and these T6 tests pass:

- An edited tangled file stops the tangle, and nothing is written.
- With `--force`, the same tangle overwrites it.
- With no map (a fresh clone), files equal to their tangled text are accepted, and a file that differs stops the tangle.

## Phase 7: Commands and Golden Tests

`main.zig`, `compare.zig` and `init.zig` implement the commands.

- **`tangle [-o DIR] [--force] DOCUMENT...`** runs Phases 3 to 6.
- **`check [-o DIR] DOCUMENT...`** tangles in memory, then compares each file with the one on disk.
  - A missing file is reported as missing.
  - For a file that differs, report its first differing line, and where that line is in the document, found through the runs. A difference past the end of the tangled text is reported at the file's last run.
  - A difference in the executable permission is reported too.
  - It exits with 1 if anything differs.
- **`where [-o DIR] FILE:LINE`** reads the map, finds the run, and prints `document:line (excerpt)`. If there is no map, it says to run tangle first.
- **`guide`** prints `src/guide.txt`. Move the guide's text from the spec into `src/guide.txt`, and replace the spec's block with `include::../src/guide.txt[]`, so the text exists once.
- **`init [-o DIR] DOCUMENT...`** follows I1–I4. Write each changed file whole, like tangle.

The golden tests live in `test/cases/<name>/`. Each case has:

- its documents,
- `args`, the options and documents that follow `tangle -o OUT`,
- `before/`, if the output directory starts with files in it (for T5 and T6),
- `expected/`, the tree the output directory should hold afterwards, map included,
- `expected.err`, what stderr should say,
- `exit`, the exit code, if it is not 0.

`test/run.sh`, run by `zig build cases`, does this for every case:

1. Tangle into a temporary directory, and compare the tree, the map and stderr with the expected ones.
2. Run `check` on the result. It must pass.
3. Change one byte in one output file. `check` must fail, naming the expected document line.
4. Run `where` for a few lines, and compare.

Init has its own cases, each with a `cmd` file, a `before/` tree and the `expected/` tree after the command. Each runs in a sandbox:

- a project with none of the three files;
- an `AGENTS.md` without the paragraph, and one with an old paragraph to replace;
- a `CLAUDE.md` that already imports `AGENTS.md`, and one that does not;
- init run with a path such as `tools/litmus`, so the paragraph names that path;
- init run twice, where the second run changes nothing.

There is at least one case for every rule and check in the spec. A generated case of 100,000 lines prints its time. The time is reported, not asserted.

**Done when:** `zig build test` and `zig build cases` both pass.

## Phase 8: Litmus as a Literate Document

The goal: `doc/` holds Litmus's own source as a literate book. Tangling it recreates `src/` (including `src/guide.txt`), `build.zig`, `build.zig.zon` and `test/run.sh` byte for byte. The golden cases stay plain files: they are data, not code to explain.

**The book.** `doc/implementation.adoc` includes one chapter per part:

1. an overview and the main types,
2. scanning,
3. parsing,
4. the document set,
5. resolving and checking,
6. tangling,
7. the map and writing files,
8. the commands,
9. building and testing.

Each chapter sets its own `:litmus-dir:`. The spec, `doc/litmus.adoc`, stays a separate document for users of Litmus. It is not part of the book.

**Writing it.** Untangle does not exist yet, so the book is written by hand. Code moves into blocks in the order that explains it best. Long functions are split into excerpts wherever a name helps the reader. Run `litmus check -o . doc/implementation.adoc` until it passes.

**Litmus as a user of Litmus.** Run `litmus init -o . doc/implementation.adoc` in the repository. Its `AGENTS.md` then has the Litmus paragraph after the notes for developing Litmus.

**The fixed point: `zig build self`.**

1. Tangle the book into an empty temporary directory.
2. Build Litmus from that directory, and run its unit tests there.
3. With that Litmus, tangle the book again into a second empty directory.
4. Both directories must equal the repository's files, byte for byte.

**Guarding against drift.** From then on, `zig build test` also runs `litmus check` on the book. Code and book cannot drift apart unnoticed. Until untangle exists, a change to the code means a matching change to its block, and `check` names the line.

**Done when:** `zig build self` passes, and the user has read the rendered book and is happy with it.

## After This Plan

- **Untangle,** rules U1–U8. The book from Phase 8 is its first user: every change to Litmus from then on goes through untangle.
- **Watch.**
- **Weave:** an asciidoctor extension for anchors, links between excerpt commands and excerpts, and a note of each block's file.
- **Hop:** a `build.zig.zon` path dependency on Litmus, and converting Hop's `docs/literate` VM chapters as the first outside test.

## Risks

- **`std.Io` is new in Zig 0.17.** Follow Hop's code for anything not shown here, and check the standard library's source in `tools/zig/lib/std` rather than older documentation.
- **Asciidoctor hides blank lines** at the start and end of a listing block. Tangle keeps them, so the page and the file can differ there. That is accepted.
- **A line of code cannot start with `…` (L4).** If a real file ever needs one, the spec changes first.
- **Windows is not a target yet.** Executable permissions and atomic renames are only tested on macOS and Linux.
