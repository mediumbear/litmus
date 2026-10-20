# Litmus

**Literate programming for the age of coding agents.** Litmus keeps a readable document and the source code it explains in step, both ways. You, or an agent, write and test code as usual. Litmus carries each change into the document and says where prose is needed. The document always tangles back to the code byte for byte, and Litmus checks that it does.

> **Work in progress.** Litmus works, and its own source is written with it, but it is young. It is at its best today for **documenting a subset of a codebase**: one module, one feature, the code a set of commits touched. Use it to understand a large feature that you did not write, or that an agent wrote for you. Expect rough edges, and expect things to change.

- **The spec**: [what Litmus does](doc/litmus.adoc), rule by rule.
- **The book**: [Litmus, implemented](doc/implementation.adoc), Litmus's own source as a literate document. It is the largest example there is.

GitHub shows the asciidoc files as they are. For the full pages, with links between the blocks, diagrams and animations, run `doc/build.sh` and open `doc/build/index.html`.

## What it looks like

A Litmus document is asciidoc (or Markdown) with one addition: a line that starts with `…` labels a block of code with the file it belongs to, or stands for a named piece of code inside another block.

````asciidoc
The program prints a greeting from its main function.

… :file: hello.zig
[source,zig]
----
… imports

pub fn main() void {
    … greet
}
----

The greeting goes to standard error, which needs no setup:

… greet :file: hello.zig
[source,zig]
----
std.debug.print("Hello, Litmus!\n", .{});
----

… imports :file: hello.zig
[source,zig]
----
const std = @import("std");
----
````

`litmus tangle hello.adoc` writes `hello.zig`, with every piece in its place. Change `hello.zig`, run `litmus untangle hello.adoc`, and the change lands in the right block of the document. The page renders with Asciidoctor, and the pieces link to each other.

## What it does

- **tangle**: documents to source files. A file is written only when it changed, and a file someone edited since the last tangle is never overwritten.
- **untangle**: changes in the source files back into the documents. It reports every block that grew as _needs prose_, which is the writer's work.
- **sync** and **watch**: pick the direction by themselves. `watch` runs `sync` whenever a file is saved.
- **adopt**: a new document from existing code, split into excerpts at its declarations. It understands the shape of Zig and Swift code, and of most brace languages.
- **companion documents**: a document that explains code without ever writing to it. Code changes flow into the document, and the code is never touched.
- **check**: proves that the documents and the code agree, and names the first line that does not.
- **where**: turns a line of a source file, such as the one in a compiler error, into a line of the document.
- **For agents**: `litmus guide` tells an agent how to work in a Litmus project, `litmus init` wires that into `AGENTS.md` and `CLAUDE.md`, and every command ends with a `next:` line that says what to do next. A Claude Code skill, `litmus-document`, walks an agent from a list of files to a finished document.

## Getting started

You need macOS or Linux, `curl` and `python3` for the Zig installer, and Ruby if you want to render documents to HTML.

```bash
git clone https://github.com/YOUR-USER/litmus.git
cd litmus
scripts/get-zig.sh                                # installs Zig 0.17 into tools/zig
tools/zig/zig build -Doptimize=ReleaseFast        # builds zig-out/bin/litmus
```

Put `zig-out/bin/litmus` on your `PATH`, or call it by its full path. `litmus guide` prints the short guide that agents read, and is a good first look.

## Using it on your code

The common case: you want to understand one part of a codebase. Make a **companion document**, which reads the code and never writes to it.

1. **Choose the code.** List the files or folders. For a feature, the files a range of commits touched work well:
   ```bash
   git diff --name-only abc123..HEAD
   ```
2. **Make the skeleton.** From your project's root:
   ```bash
   litmus adopt -o . --companion docs/payments.adoc Sources/Payments
   litmus check -o . docs/payments.adoc
   ```
   Paths after the document are relative to `-o`. The new document holds every line of those files, split into named excerpts, and its map is kept beside it in `docs/.litmus/`.
3. **Write it.** Reorder the excerpt blocks into the order that explains the code, and write prose between them. A block always moves together with its label line, the `… name :file: path` line above it. Run `litmus check` as you go.
4. **Keep it fresh.** When the code changes, `litmus sync -o . docs/payments.adoc`, or leave `litmus watch -o . docs/payments.adoc` running, carries the change into the document and lists what needs prose.

### With an agent

```bash
litmus init -o . docs/payments.adoc
```

This adds a paragraph to `AGENTS.md` (and creates it if needed), makes `CLAUDE.md` import it, ignores the map in `.gitignore`, and installs the `litmus-document` skill into `.claude/skills/`. Then write a short brief, for example `docs/payments.brief.md`:

```markdown
# Brief: the payments module

## Files
Sources/Payments/

## Goal
I need to change how refunds are retried. Explain the module with that in mind.

## Reader and style
A programmer new to this codebase. Plain prose. A flowchart for any flow of more than
three steps, and a step-through animation for anything that walks through data.

## Output
document: docs/payments.adoc
code: .
kind: companion
```

In Claude Code, run `/litmus-document docs/payments.brief.md`. The agent makes the skeleton, proposes an outline of chapters, waits for you to agree, then writes the document in the style of the brief, checking as it goes. The brief is also the document's style file: `litmus style docs/payments.adoc` names it for any agent that writes prose later.

### Owning the code

A document can also own its code, as Litmus's own book does: the document is the source, and the files are tangled from it. Start with `litmus adopt` without `--companion`, or write the document by hand, and use `tangle`, `untangle`, `sync` and `watch` as you work.

### Rendering

Documents are asciidoc, so any Asciidoctor setup renders them. For the links between blocks, the small labels, Mermaid diagrams and the table of contents that follows you, add Litmus's extension:

```bash
gem install asciidoctor rouge
asciidoctor -r /path/to/litmus/doc/litmus-weave.rb docs/payments.adoc
```

If a document uses the step-through animations from Litmus's `doc/visuals/`, copy that folder next to the HTML.

## Commands

```
litmus tangle   [-o DIR] [--force] DOCUMENT...
litmus check    [-o DIR] DOCUMENT...
litmus untangle [-o DIR] [-f FILE]... [--force] DOCUMENT...
litmus sync     [-o DIR] DOCUMENT...
litmus watch    [-o DIR] [--interval MS] DOCUMENT...
litmus adopt    [-o DIR] [--companion] [--style FILE] DOCUMENT PATH...
litmus where    [-o DIR] [DOCUMENT] FILE:LINE
litmus style    DOCUMENT...
litmus init     [-o DIR] DOCUMENT...
litmus guide
```

`-o DIR` is where the code lives, the current directory by default. The [spec](doc/litmus.adoc) has every rule.

## Status and limits

- Developed and tested on macOS. Linux should work, but is not tested yet. Windows is not a target yet.
- `watch` polls the files every 200 milliseconds. That is fine for hundreds of files. A native file watcher is planned.
- `adopt` splits code by its layout: declarations at the left margin, and the members of long types. It suits Zig, Swift and other brace languages. Python and other languages that use indentation for blocks are split less well.
- Markdown documents work, and are tested, but nothing large has been written in them yet.
- The rendering extension lives in this repository and is used by path.

## Working on Litmus

Litmus is developed with Litmus. `doc/implementation.adoc` is the source, and the files in `src/` are tangled from it.

```bash
tools/zig/zig build test     # unit tests, and a check that the book matches src/
tools/zig/zig build cases    # golden tests in test/cases
tools/zig/zig build self     # tangle the book, build Litmus from it, tangle again
doc/build.sh                 # render the spec and the book to doc/build/
```

`AGENTS.md` has the working rules, and `doc/plan*.md` the plans each part was built from.

## License

BSD 2-Clause. See [LICENSE](LICENSE).
