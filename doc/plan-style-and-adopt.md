# Style Files, and Documents for Code Litmus Did Not Write

This plan collects two ideas from a side chat, so they are not lost. Neither part is built yet.

1. **A style file.** A document names, with `:litmus-style:`, a file that says who the reader is and how prose and pictures should be done. Agents read it before they write prose.
2. **Reading a feature you did not write.** Litmus makes a skeleton document from existing source files (`adopt`), an agent writes the explanation, and the weave shows the lines a range of commits changed. The document is a read-only companion: `check` proves it matches the code, and nobody's workflow changes.

The ground rules of `doc/plan.md` apply: the spec first, Zig 0.17 with only the standard library, `zig build test`, `cases` and `self` before each commit, one commit per phase, and changes to Litmus carried into the book with `litmus untangle`.

## Part 1: The Style File

### What it is

A style file is Markdown, written for agents. It has free prose under any headings, and one section, `## Settings`, whose `key: value` lines the weave reads.

```markdown
# Style for the Litmus book

## The reader
A working programmer who thinks in Pascal, C and Swift, not Lisp or Haskell.
Visual. Comfortable with second-year university maths, but prefers pictures to notation.

## Prose
- Plain, direct sentences. Say what the code does, then why.
- Introduce an algorithm with a small worked example before the code.
- No proofs. A test that shows a property beats an argument for it.

## Visuals
- Any flow with more than three steps gets a Mermaid flowchart.
- Any algorithm that walks through data gets a canvas animation you can step through
  (see doc/visuals/myers.js), with one sentence of explanation per frame.
- Data structures get a box-and-arrow diagram.

## Settings
mermaid-theme: neutral
visual-style: light, rounded, one accent colour per round or phase
```

### Decisions

1. **Where it is named.** `:litmus-style: style.md` in asciidoc, `<!-- :litmus-style: style.md -->` in Markdown, on a line of its own before the first document command, like `:litmus-dir:`. The path is relative to the document, like an include.
2. **Inheritance.** Unlike `:litmus-dir:`, a style is inherited: an included document uses the style of the document that includes it, unless it names its own. A book shares one voice; a file's location is a per-document fact.
3. **Style never changes code.** Tangle ignores it, so it cannot break the round trip. A missing style file is a check (C12), so a typo does not silently drop the rules.
4. **Committed with the documents,** not in `.litmus/`.

### Phases

- **S0, spec.** Rule L10 for the attribute and its inheritance, check C12 for a missing file, the command `litmus style DOCUMENT...`.
- **S1, parse.** The attribute in `scan.zig` and `parse.zig`, inheritance in `docset.zig`, C12. Tests per rule.
- **S2, commands.** `litmus style DOCUMENT...` prints the style file of each document, following includes. `litmus guide` gets a line: before writing prose for a document, run `litmus style` on it and follow what it says. Untangle's _needs prose_ report ends with the style file to follow. `litmus init` can create a starter style file with the headings above.
- **S3, weave.** `doc/litmus-weave.rb` reads `## Settings` and applies the Mermaid theme and the colours of the visuals.
- **S4, the pilot.** A style file for the book, and an agent rewrite of the Untangle chapter's prose in it. The user compares the two versions.

Size: small. The pilot is the interesting part.

## Part 2: Reading Code You Did Not Write

The use case: twelve commits of a complex feature, written by someone else, and the wish to understand them through a document with prose and pictures.

### The pieces

| Piece | What it does | Size |
|---|---|---|
| Filters | `--only PATH` and `--exclude GLOB` on tangle, check and untangle | small |
| `adopt` | A skeleton document from existing source files | medium |
| Companion workflow | `check` as the only command run against the real code | none: it exists |
| Changed-only weave | The weave marks the blocks a range of commits changed, and folds the rest | small to medium |

### Filters

A filter applies after tangling, before anything is compared or written. The subtle part is the map: a filtered tangle keeps the previous map's entries for the files it skipped, or they would lose their hashes (T6) and be reported as no longer tangled (T5). Globs are `*` and `**` only, matched by hand, with no regular expressions.

### adopt

`litmus adopt [-o DIR] NEW.adoc FILE...` writes a new document. Each file becomes a root block split into excerpts at its top-level declarations: a blank line, then a line at column 0. That is the heuristic the book was first built with, and it works for Zig, C, Swift and Pascal-like code. Excerpt names come from the first identifier on the declaration's line, made unique. The document passes `check` by construction, and the test is exactly that: adopt, then check, for a variety of files.

Choosing the files from git needs no git in Litmus: `litmus adopt feature.adoc $(git diff --name-only A..HEAD)`.

An agent then reorders the excerpts into the order that explains the feature, writes the prose in the document's style, and adds pictures.

### The companion workflow

For a teammate's feature the document does not own the files. It is never tangled into the real tree. `litmus check` proves it still matches the code, and when the code moves on, check names the stale lines. To refresh, copy the current files into a scratch directory and `litmus untangle -o scratch`, or re-adopt the changed files.

This needs documentation in the spec and the guide, not code.

### The changed-only weave

The weave extension is Ruby and can run git itself, so Litmus stays out of it. Rendered with `-a litmus-since=COMMIT`, the extension runs `git diff -U0 COMMIT -- FILES` for the tangled files, maps the changed line ranges onto blocks through `.litmus/map`, marks the changed lines inside each block, and folds the blocks with no change behind a "show" control. The table of contents marks the sections that hold changes.

### Phases

- **A0, spec.** Rules for filters, the `adopt` command, and a section on companion documents.
- **A1, filters,** with the map kept for skipped files.
- **A2, adopt,** with golden cases: adopt, then check, for Zig, C and shell files, and files with no blank lines.
- **A3, changed-only weave.**
- **A4, a trial** on a real range of commits, chosen by the user.

## Order

Part 1 first: it is small, and its pilot shapes how prose is written in everything after, including the documents that Part 2 produces. Then A2 (adopt) and the companion workflow, since that is what lets the user read a feature they did not write. The filters and the changed-only weave come after.
