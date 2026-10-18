# Implementing Untangle

This plan adds untangle to Litmus, as specified by rules U1–U8 in `doc/litmus.adoc`. Untangle carries changes made in the tangled source files back into the document blocks they came from. After it, a person or an agent edits and tests the code as usual, runs one command, and the documents hold the change. The prose still has to be written; untangle reports where.

Watch and weave come after, each with its own plan. The ground rules of `doc/plan.md` apply unchanged: the spec is the source of truth, Zig 0.17 with only the standard library, no regular expressions, report everything, run `zig build test` after every step, commit at the end of each phase.

## The Idea

Tangle is a function from documents to files. Untangle is not its inverse in general, but it is one for the cases that matter, because every excerpt is used exactly once (C2, C3): each line of a tangled file comes from exactly one line of the document set, and the map says which.

So the algorithm is short:

1. Tangle the documents in memory. This is the _base_ (U1).
2. Compare each base file with the file on disk, line by line (U2).
3. Turn each difference into an edit of a document line, using the runs (U3, U4).
4. Apply the edits, tangle the new documents in memory, and require the result to equal the files on disk, byte for byte. If it does not, write nothing.

Step 4 is what makes untangle exact. The rest of the plan is about getting step 3 right and making step 4 pass for every edit that can be placed.

## Decisions

These need the user's agreement before the spec changes. Each has a recommendation.

1. **What decides the direction (U7).** The spec says git does: if only the source files differ from `HEAD`, untangle. The map already holds the answer without git: it records the hash of what tangle last wrote. Source files changed means their hash differs from the map's. Documents changed means the documents tangled in memory differ from the map's hash. This works before the first commit and with uncommitted work, needs no child process, and is the same test that T6 uses. **Recommend the map.** Without a map (a fresh clone), a file that equals its tangled text is unchanged; one that differs is reported, because the direction cannot be known.
2. **Command names.** `litmus untangle [-o DIR] DOCUMENT...` does U1 to U6 and U8, and refuses if the documents changed too. `litmus sync [-o DIR] DOCUMENT...` does U7: it picks tangle or untangle, and stops with a report if both sides changed. **Recommend these two.**
3. **All or nothing.** If any edit cannot be placed (U5), untangle writes no document and exits with 1. A partial untangle would leave documents and files that do not agree, and the writer would not know which edits went in. **Recommend all or nothing.**
4. **Where a new line goes (U4).** The spec puts a line added where two runs meet "into the outer block, next to the command", but does not say on which side of the command, or which block when excerpts are nested several deep. **Recommend choosing by indent:** consider the levels at the boundary, innermost first, and take the first level whose accumulated indent the new line starts with. An empty line goes to the outermost level. The line goes after the command when the boundary is the end of the expansion, and before it when the boundary is its start. The report lists every line placed this way, since the writer may want it elsewhere.
5. **U8, files that are not in the map.** Untangle looks only at the files the map lists. `-f FILE` names a file the caller believes is source, and untangle reports it if it is not in the map. A watcher (later) passes the files that changed. **Recommend this,** since scanning a directory cannot tell source from anything else.
6. **Deleted and new files.** A mapped file that is missing on disk is reported and left alone; its lines are not deleted from the documents. A new file is U8.

## Source Layout

| File | Responsibility |
|---|---|
| `src/diff.zig` | A line diff of two texts. No IO. |
| `src/untangle.zig` | From a base file and a changed file to edits of document lines, the growth report, and the edited documents. No IO. |
| `src/sync.zig` | The direction (U7): compares the map's hashes with the files and with the documents. |
| `src/tangle.zig` | Also records the expansions and the indent bytes, in memory (Phase 1). |
| `src/main.zig` | The `untangle` and `sync` commands. |

## Phase 0: The Spec

Change the spec first, as the ground rules demand. Add the decisions above: U4 with the placement rule, U7 on the map's hashes, U8 and the `-f` option, the two commands in the list of commands, all-or-nothing in U5, and the check at the end of untangle as a rule of its own (U9: untangle writes only when the edited documents tangle to the files on disk). Write the spec's example of an untangle, with a before and an after.

**Done when:** the spec has U1–U9 and the command list, and the user has read the changes.

## Phase 1: What Untangle Needs From Earlier Stages

- **Expansions.** Tangle records, in memory only, every excerpt command it expands: the first and last output line, the block, the command's index, the depth, and the accumulated indent bytes. The map does not change. This is how a boundary between runs finds its levels (decision 4), and how an empty line learns its indent.
- **Document ends.** `splitLines` forgets whether the text ended with `\n`. A `Document` keeps that flag, so a document can be written back as it was.
- **A shared pipeline.** `build` in `main.zig` becomes a function that other commands call, so `untangle` and `sync` load, resolve and tangle the same way.

**Done when:** the existing tests, cases and self test pass unchanged, and new tests check the expansions of the spec's example and of nested indents.

## Phase 2: The Diff

`diff.zig` compares two lists of lines and gives hunks: base lines `[a, b)` replaced by changed lines `[c, d)`.

- Trim the common start and end first. Most edits are small.
- Run Myers' O(ND) algorithm on what is left. Compare lines by their slices.
- Put a limit on D. Past it, report one hunk for the whole middle. The result is still exact, only coarser. A formatter that rewrites a whole file lands here.
- Pair lines inside a hunk by position: the first `min(k, m)` base lines become changes, extra base lines become deletions, extra new lines become insertions after the last pair.

Tests: no change; one line changed, added, removed; two edits far apart; repeated lines (blank lines, `}`); the empty file on either side; the limit.

**Done when:** a seeded random test applies every diff to the base and gets the changed text back.

## Phase 3: Planning the Edits

`untangle.zig` turns hunks into edits of document lines, with no IO. For a file with base text, runs, expansions, and the text on disk:

- **A changed line (U3).** The base line comes from run `r`, at document line `r.doc_line + offset`. The new text must start with the run's indent bytes. Strip them, and the edit is: replace that document line. If it does not start with them, that is U5: report it and do not guess.
- **A removed line (U3).** Delete that document line.
- **An added line (U4).** Between two lines of one run, insert into that block at the matching place. At a boundary, choose the level by decision 4, strip that level's indent (U5 if the line does not start with it), and insert before or after the command. At the start of a file, insert at the start of the first root block, and at the end, at the end of the last.
- **Growth (U6).** Count the lines added to each block. Every block that grew goes in the report as _needs prose_, with its document line, excerpt and file.
- **U5 for an unindented edit.** A changed or added line that no longer starts with its excerpt's indent is reported with its file, line and document line.

Edits are kept per document and are not applied yet. Editing an excerpt command line is impossible, because those lines are not in the output.

Tests: each of the above, with indents of spaces and tabs, nested excerpts, a change in the last line of a run, an insert at each kind of boundary, an excerpt of several blocks, and a file whose first or last line changes.

**Done when:** the planning tests pass, one for each of U3, U4, U5, U6.

## Phase 4: Applying the Edits

Still no IO. Given a document's lines and its edits, produce the new lines in one forward pass: for each original line, emit what is inserted before it, the line itself (replaced, deleted, or kept), and what is inserted after it. Edits are anchored to original line numbers, so they never disturb each other.

Then the check of U9: parse and tangle the edited documents in memory, and compare with the files on disk. Any difference is an error that names the file and line, and nothing is written.

A random test does the work of a proof here: tangle a generated document set, change random lines of the output (change, delete, insert, at every depth), untangle in memory, and require the tangle of the result to equal the changed output. The seed is printed on failure.

**Done when:** the random test passes for many seeds, and the cases of Phase 3 pass through the full pipeline.

## Phase 5: The Command

`untangle [-o DIR] [-f FILE]... DOCUMENT...` in `main.zig`:

1. Load, resolve and tangle the document set. If the documents' tangle differs from the map's hashes, the documents changed too: refuse, and say to run `sync`.
2. Read each mapped file, and plan, apply and check as above.
3. Write each changed document, whole and atomically, as tangle writes files. Then tangle as usual, which finds every file equal and rewrites only the map, whose document lines have moved.
4. Print the report: the number of edits and documents, each block that needs prose (U6), each line placed at a boundary (U4), each file named with `-f` that is not in the map (U8). On U5 or U9, print the problems and write nothing; exit 1.

**Done when:** an end-to-end run on the spec's example, with one line changed, one added and one removed, leaves the documents right, the map current, and `check` passing.

## Phase 6: The Direction

`sync.zig` and the `sync` command (U7): compute the two signals of decision 1. Neither: print that all is in sync. Only the files: untangle. Only the documents: tangle. Both: print each file whose hash differs from the map, and the excerpts of the documents that changed it, then exit 1. Prose changes never count, since only code is hashed.

**Done when:** each of the four states has a test, and a fresh clone with no map is handled as decision 1 says.

## Phase 7: Golden Cases

Cases for untangle live next to the others. Each has its documents, an `edit/` tree with changed copies of tangled files, `expected/` with the documents afterwards, `expected.out` with the report, and `expected.err`. The runner tangles, copies the edits over, untangles, compares the documents with `expected/`, runs `check` (it must pass), and tangles again to see that nothing changes.

At least one case for each of U1–U9: a change, a removal, an addition inside a run, an addition at each kind of boundary, an unindented line (U5), growth in several blocks, a refused untangle because the documents changed, a file not in the map, and a document with CRLF or no final newline. And one with Markdown.

**Done when:** `zig build cases` passes with the new cases.

## Phase 8: The Book

Litmus's own book gets the new chapters: the diff, untangle, and sync, and changes to tangle, the document set and the commands. This is the first time Litmus is used on itself the way it was meant:

- Phases 1 to 5 are written code first. Their changes are carried into the book by hand, as before, until `untangle` works.
- From Phase 5 on, the changes go through `litmus untangle`. Each _needs prose_ item it reports gets its prose before the phase is done. The book's chapters for Phases 6 and 7 are the first ones written this way.
- `zig build self` still has to pass.

**Done when:** `zig build test`, `cases` and `self` pass, the book describes untangle, and the user has read the new chapters.

## Risks

- **Moved code looks like delete and add.** Untangle is exact, but a block of code moved to another excerpt lands as an insertion at the new place and a deletion at the old one. The documents then tangle right, but the prose may not fit. The report lists both. Detecting moves is not attempted.
- **Repeated lines.** A diff may align `}` or a blank line with the wrong twin. The result is still exact, because of the U9 check, but an edit may land in a neighbouring block. The report of boundary insertions is the writer's guard.
- **Formatters.** `zig fmt` over a whole file produces many small hunks, or past the limit one big one. Both work. Edits that change indentation of a whole excerpt are U5 and are refused with a clear message; the fix is to change the command's indent in the document.
- **The map as the base.** If someone edits the documents' code and the files, and the map has not been updated, `sync` stops. That is intended, and the message has to say why.
- **Windows line ends in documents.** A `\r` stays part of its line (L7), so it travels through untangle unchanged. A test makes sure.
- **Speed.** Untangle runs on every save once watch exists. Trimming the common start and end, and tangling once in memory, keep the cost near that of tangle plus a diff of what changed. The 100,000-line case gets an untangle timing, reported and not asserted.
