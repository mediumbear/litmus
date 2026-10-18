# Literate Documents for Existing Code

This plan is about one job: **a list of files in, a literate document out.** Two cases lead to it:

1. Someone new to a codebase wants one module made readable, for a task. They name files or folders, and an agent makes the document.
2. Someone has a large module that an AI wrote, and wants to understand it. They have a list of files.

Both start the same way: a short brief, then one prompt. An agent reads the brief, runs Litmus to make a skeleton, proposes an outline, and after the user agrees writes the prose and pictures. Litmus does the mechanical parts and proves the result is exact.

The first real use is a work project in Swift (structs, actors, some classes) and Zig. So `adopt` must split code inside types, not only at the top level.

The ground rules of `doc/plan.md` apply: the spec first, Zig 0.17 with only the standard library, no regular expressions, `zig build test`, `cases` and `self` before each commit, one commit per phase, and changes to Litmus carried into the book with `litmus untangle`.

## The Flow

```
brief.md ──► agent expands the file list (folders, a git range)
         ──► litmus adopt  ──► skeleton document, one chapter per file
         ──► litmus check  ──► passes at once, by construction
         ──► agent proposes an outline ──► the user approves or changes it
         ──► agent writes each chapter in the brief's style, check after each
         ──► render ──► the user reads it
```

## The Brief

A small Markdown file, wherever the user wants the document to live. It names the code, the goal, the reader, and where the output goes:

```markdown
# Brief: the payments module

## Files
Sources/Payments/
Sources/Shared/Money.swift
# or a command: git diff --name-only 3f2a1c..HEAD

## Goal
I need to change how refunds are retried. Explain the module with that in mind.

## Reader and style
A programmer new to this codebase. Thinks in C and Swift. Visual: a flowchart for
any flow of more than three steps, an animation for anything that walks through data.

## Settings
mermaid-theme: neutral

## Output
document: docs/payments.adoc
code: ../work-repo
kind: companion
```

The brief is also the document's style file. The generated document says `:litmus-style: brief.md`, so every later agent writing prose for it reads the same rules.

`## Output` says where the document goes, where the code is (the `-o` directory), and its kind:

- **owned**: the document lives in the repository and owns the code. Tangle, untangle, sync and watch all work as they do for the Litmus book. This is the case of the AI-written module the user keeps.
- **companion**: the document is for reading. It lives anywhere, often a scratch folder, and never writes to the code (see below).

## Companion Documents

A companion document is marked `:litmus-companion:`. Litmus then:

- keeps its map beside the document, in `.litmus/` next to it, and not in the code's directory;
- refuses to tangle into the code, and in sync and watch treats a change of the document's code as something to revert, with a message saying so;
- untangles normally: when the code moves on, untangle carries the change into the document, which is how the document is kept fresh;
- checks normally: `check` proves the document still matches the code.

So a companion can be watched while the user reads, and it follows the code without ever touching it.

## adopt

`litmus adopt [-o DIR] [--companion] DOCUMENT FILE_OR_FOLDER...` writes a new document, and refuses to overwrite one.

- Folders are expanded to the files in them, recursively, in sorted order. Files that are not text, and the usual noise (`.git`, build folders), are skipped.
- Each file becomes a chapter: a level-2 heading, its file root, and its excerpts.
- **Splitting.** At the top level, an excerpt starts at a line at column 0 that follows a blank line, as the book was first built. A top-level item longer than a threshold (about 40 lines) whose body is in braces is split one level deeper: its members, at the body's indent after a blank line, become excerpts of their own, inserted by commands at that indent. This handles Swift structs, actors, classes, enums, extensions and protocols, and Zig structs, without knowing either language. Doc comments stay with the declaration below them.
- **Names.** An excerpt is named after its declaration: the first identifier after the keywords and modifiers (`func`, `struct`, `actor`, `class`, `enum`, `extension`, `protocol`, `init`, `var`, `let`, `pub`, `fn`, `const`, `public`, `private`, `static`, `mutating`, `nonisolated`, attributes such as `@MainActor`, and the like). Members are named `Type.member`. Clashes get a number.
- **Sections.** A Swift `// MARK: - Title` line becomes a level-3 heading in the chapter, so the author's own structure shows.
- The document gets `:litmus-style:` and, for a companion, `:litmus-companion:`.

The document passes `check` by construction. The tests are exactly that: adopt, then check, for Swift and Zig samples with nested types, long types, doc comments, `MARK` lines, CRLF, a file with no blank lines, and an empty file.

## The Skill

A skill, `litmus-document`, that `litmus init` installs into `.claude/skills/`. Its text ships with Litmus, like the guide, and the same steps go into `litmus guide` for agents that have no skills. The steps:

1. Read the brief. Expand folders, run its git command if it has one, and show the user the file list if it is long.
2. Run `litmus adopt`, then `litmus check`, which must pass.
3. Read the code and propose an outline: chapters, their order, and the pictures each needs. Stop, and show it to the user.
4. When the user approves, write each chapter in the brief's style: reorder the excerpts, write prose before each block, add diagrams and animations. Run `check` after each chapter.
5. Render with `doc/build.sh` or the project's equivalent, and ask the user to read it.

An agent that keeps working on the document runs `litmus watch` in the background and reads its output.

## Watch Output for Agents

Watch's output is already rich: what changed, the edits, each block that needs prose, each line placed at a boundary, and the reason for a stop. One addition: every block ends with a `next:` line that says what to do, in words an agent can act on:

```
[12.4s] changed: Sources/Payments/Refund.swift
the files changed: untangling
changed 2 lines, removed 0 lines, added 6 lines, in 1 document
needs prose: docs/payments.adoc:212 (Refund.retry of Sources/Payments/Refund.swift) grew by 6 lines
next: write prose for 1 block in the style of docs/payments.brief.md, then run litmus check
```

The same `next:` line ends the output of untangle and sync when run by hand.

## Phases

- **P0, spec.** The style attribute and its inheritance (L10, a missing style file is C12); companion documents; `adopt`; the `next:` lines.
- **P1, style.** `:litmus-style:` parsed, inherited by included documents, and checked. `litmus style DOCUMENT` prints the style file that applies. Untangle's report names it.
- **P2, adopt,** with the splitting, naming and sections above, and its golden cases.
- **P3, companion documents:** the map beside the document, and the refusals in tangle, sync and watch.
- **P4, `next:` lines** in untangle, sync and watch.
- **P5, the skill and the guide,** installed by `init`.
- **P6, the weave:** the brief's `## Settings` applied to diagrams.
- **P7, a trial** on the work project, with the user. What it teaches goes back into the spec and the skill.

Later, as before: `--only` and `--exclude` filters, and a weave that highlights the lines a range of commits changed.
