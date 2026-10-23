# Litmus

**Two-way literate programming for codebases written with AI.**

Litmus keeps a readable document and the source code it explains in exact agreement, in both directions. Changes made to the code flow into the document; changes made to the document flow into the code. The source files carry no annotations of any kind, so a document can be written for code that already exists, including code that nobody on the team wrote by hand. An AI agent produces the explanation; Litmus guarantees that it stays true.

> **Status: work in progress.** Litmus is functional, and its own implementation is maintained as a Litmus document, but it is young software. It is best suited today to documenting a well-defined part of a codebase, such as a module, a feature, or the code touched by a series of commits, rather than an entire system.

## Introduction

Literate programming, introduced by Knuth with WEB in 1984, presents a program as an essay: prose that explains, with the code arranged in the order that best serves the reader rather than the order the compiler requires. A tool _tangles_ the essay into compilable source. The idea has been admired for four decades and adopted rarely, for a practical reason. Tangling runs in one direction only. Once the generated source is edited, by a programmer under deadline, an automated refactoring, or a formatter, the document is out of date, and nothing brings it back. Documentation generators avoid this by reading comments embedded in the source, but they inherit the file's order and require the code itself to carry the explanation.

Two developments change the trade-off. First, much new code is now written or modified by AI agents, which work in source files with a compiler and tests in the loop and would gain nothing from editing a document instead. Second, the same agents are capable writers of explanatory prose, given the code and a description of the intended reader. What remains missing is a mechanism that lets code and document evolve independently while remaining provably consistent.

Litmus provides that mechanism. It records, for every line of every generated file, the document line it came from, and it uses that record to carry edits in the code back into the document (_untangle_) as readily as it carries the document into the code (_tangle_). Every operation ends with a check that the document reproduces the source files byte for byte; an edit that cannot be placed exactly is reported rather than guessed. The record lives in a separate file, so the source files remain ordinary code that any tool, editor, or reviewer can work with unchanged.

This design supports a workflow in which the roles are divided by strength. Agents write and test code where they work best, in the source files. Litmus carries each change into the document and lists the blocks that now need prose. Agents, or people, write that prose, guided by a style file that states who the reader is and how ideas should be presented. People read the result.

Litmus makes the following contributions:

- **Exact two-way synchronisation.** `tangle` and `untangle` are inverses for every change that can be placed unambiguously, and every result is verified against the source files before it is written. `sync` determines the direction automatically, and `watch` applies it on every save.
- **No annotations in the code.** Provenance is kept in a sidecar map, never in the source. Litmus can therefore document any existing codebase, in any language, without asking anyone to change how they write code.
- **Documents for code that already exists.** `adopt` turns a set of files into a skeleton document, split into named excerpts at their declarations and verified to reproduce the files exactly. An agent then reorders the excerpts into an explanation and writes the prose. _Companion_ documents follow a codebase without ever writing to it, which suits teams that want to understand a feature rather than adopt a new way of working.
- **Built for agents.** `untangle`, `sync`, `watch` and `adopt` end their output with a `next:` line that states the next action. `litmus guide` explains the workflow to any agent, `litmus init` wires it into `AGENTS.md` and `CLAUDE.md`, and a Claude Code skill takes an agent from a list of files to a finished, rendered document.

The [specification](doc/litmus.adoc) defines every behaviour as a numbered rule. Litmus's own source is maintained as a literate document, [Litmus, Implemented](doc/implementation.adoc), which also serves as the largest worked example. GitHub displays both as plain AsciiDoc; `doc/build.sh` renders them with cross-linked excerpts, diagrams, and step-through animations, starting at `doc/build/index.html`.

## What it looks like

A Litmus document is ordinary AsciiDoc with a single addition. A line beginning with `…` either labels the code block that follows with the file it belongs to, or, inside a block, stands for a named excerpt defined elsewhere in the document. The source files themselves contain nothing Litmus-specific.

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

`litmus tangle hello.adoc` assembles `hello.zig` from its excerpts. If `hello.zig` is then edited, `litmus untangle hello.adoc` places each changed, added, or removed line in the block it belongs to, and reports which blocks grew and therefore need prose. The document renders with Asciidoctor, with every excerpt linked to the place it is used.

## Commands at a glance

| Command | Purpose |
|---|---|
| `tangle` | Write the source files from the documents. A file is rewritten only when its content changes, and a file edited since the last tangle is never overwritten. |
| `untangle` | Carry edits in the source files back into the documents, and list the blocks that need prose. |
| `sync`, `watch` | Choose the direction automatically; `watch` does so on every save. |
| `adopt` | Create a document from existing files, split at their declarations. |
| `check` | Verify that the documents reproduce the source files, and name the first line that differs. |
| `where` | Map a line of a source file, such as one in a compiler error, to its line in the document. |
| `init`, `guide`, `style` | Prepare a project for agents, explain the workflow, and name a document's style file. |

## Getting started

Litmus is a single executable with no dependencies beyond the Zig standard library. Building it requires macOS or Linux, with `curl` and `python3` for the Zig installer. Rendering documents to HTML additionally requires Ruby.

```bash
git clone https://github.com/mediumbear/litmus.git
cd litmus
scripts/get-zig.sh                                # installs Zig 0.17 into tools/zig
tools/zig/zig build -Doptimize=ReleaseFast        # builds zig-out/bin/litmus
```

Place `zig-out/bin/litmus` on your `PATH`, or invoke it by its full path. `litmus guide` prints the short guide that agents read, and is a useful first orientation.

## Using it on your code

The most common use is to understand one part of an existing codebase. For this, create a **companion document**: it follows the code as the code changes, but never writes to it.

1. **Select the code.** List the relevant files or folders. For a feature, the files touched by a range of commits are a natural choice. `--diff-filter=d` leaves out files that the range deleted, since they no longer exist to be adopted:
   ```bash
   git diff --name-only --diff-filter=d abc123..HEAD
   ```
2. **Create the skeleton.** From the project's root, pass the selection to `adopt`, either as a list or straight from git:
   ```bash
   litmus adopt -o . --companion docs/payments.adoc Sources/Payments Sources/Shared/Money.swift
   litmus adopt -o . --companion docs/payments.adoc $(git diff --name-only --diff-filter=d abc123..HEAD)
   litmus check -o . docs/payments.adoc
   ```
   Paths after the document are relative to `-o`, which is why the command runs from the root, where git's paths start. A folder stands for every file in it. The new document contains every line of the selected files, split into named excerpts, and its map is stored beside it in `docs/.litmus/`. Binary files are skipped with a note, and a file that cannot be placed in a document, such as one without a final newline, is reported and nothing is written.
3. **Write the explanation.** Reorder the excerpt blocks into the sequence that best explains the code, and write prose between them. A block always moves together with its label, the `… name :file: path` line above it. Run `litmus check` after each change.
4. **Keep it current.** When the code changes, `litmus sync -o . docs/payments.adoc` carries the change into the document and lists what needs new prose. `litmus watch` does the same continuously.

### With an agent

```bash
litmus init -o . docs/payments.adoc
```

This adds a paragraph to `AGENTS.md`, creating the file if necessary, makes `CLAUDE.md` import it, excludes the map in `.gitignore`, and installs the `litmus-document` skill into `.claude/skills/`. The work is then described in a short brief, for example `docs/payments.brief.md`:

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

In Claude Code, run `/litmus-document docs/payments.brief.md`. The agent creates the skeleton, proposes an outline of chapters, and waits for approval before writing the document in the style the brief describes, verifying it after each chapter. The brief also serves as the document's style file, so any agent that later writes prose for it, for example after `untangle` reports new code, follows the same conventions. Other agents follow the same steps from `litmus guide`.

### Owning the code

A document can also own its code, as Litmus's own implementation does. The document is then the primary source and the files are tangled from it, while edits made directly to the files are still carried back by `untangle`. Start with `litmus adopt` without `--companion`, or write the document by hand.

### Rendering

Documents are standard AsciiDoc and render with any Asciidoctor installation. Litmus's extension adds links between excerpts and their uses, compact labels, Mermaid diagrams, and a table of contents that follows the reader:

```bash
gem install asciidoctor rouge
asciidoctor -r /path/to/litmus/doc/litmus-weave.rb docs/payments.adoc
```

Documents that use the step-through animations in `doc/visuals/` need that folder copied next to the generated HTML.

## Command synopsis

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

`-o DIR` names the directory that holds the code, the current directory by default. The [specification](doc/litmus.adoc) defines each command precisely.

## Status and limitations

- Developed and tested on macOS. Linux should work, but is not tested yet. Windows is not a target yet.
- `watch` polls files every 200 milliseconds, which is adequate for hundreds of files. A native file-system watcher is planned.
- `adopt` accepts files in any language, and splits them by layout: declarations at the left margin, and the members of long types. The results are best for Zig, Swift, and other brace-delimited languages; languages that delimit blocks by indentation, such as Python, are split more coarsely.
- AsciiDoc is the primary format. Litmus can also read Markdown documents, and `tangle`, `untangle`, `check`, `sync` and `watch` work on them, but `adopt` creates AsciiDoc only, and the HTML rendering with linked excerpts and diagrams is for AsciiDoc only. A Markdown document displays as ordinary Markdown, on GitHub or elsewhere, with its `…` lines shown as plain text.
- The rendering extension is referenced by path from this repository; it is not yet packaged.

## Working on Litmus

Litmus is developed with Litmus: `doc/implementation.adoc` is the source, and the files in `src/` are tangled from it. Changes may be made in either place.

```bash
tools/zig/zig build test     # unit tests, and a check that the book matches src/
tools/zig/zig build cases    # golden tests in test/cases
tools/zig/zig build self     # tangle the book, build Litmus from it, tangle again
doc/build.sh                 # render the spec and the book to doc/build/
```

`AGENTS.md` states the working rules, and `doc/plan*.md` the plans from which each part was built.

## License

BSD 2-Clause. See [LICENSE](LICENSE).
