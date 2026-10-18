# Implementing Watch

This plan adds `litmus watch`, the last piece of the loop: the writer saves a tangled file or a document, and Litmus brings the other side up to date within a moment. It builds on `sync` (U7), which already knows which way to go. Watch only decides _when_.

The ground rules of `doc/plan.md` apply: the spec first, Zig 0.17 with only the standard library, no regular expressions, `zig build test` after every step, a commit at the end of each phase. As with untangle, once a phase works, its changes go into the book with `litmus untangle`, and the prose it asks for gets written.

## The Idea

```
start ─► sync ─► remember the stat of every watched file ─┐
                                                           │
   ┌───────────── sleep one interval ◄─────────────────────┘
   │
   ▼
 stat every watched file ─► same as remembered? ─ yes ─► sleep again
                                   │ no
                                   ▼
                     wait until it stops changing (debounce)
                                   │
                                   ▼
                    sync ─► remember the stats again ─► sleep
```

Two points carry the design:

- **Our own writes are not changes.** After every sync the stats are taken again, so what Litmus wrote is the new baseline, and watch never wakes itself up.
- **A failure is not retried.** If sync stops, because both sides changed or a document has an error, watch prints the report and waits for the next change. It never loops, and it never uses `--force`.

## Decisions

These need the user's agreement before the spec changes. Each has a recommendation.

1. **How changes are noticed.** The standard library has no file watcher, and the native ones differ on every system (FSEvents or kqueue on macOS, inotify on Linux, a directory handle on Windows). **Recommend polling:** every interval (200 ms by default), `stat` each watched file and compare its size, modification time and existence with what was seen last. It is the same on every system and needs no new code per system. A project of a few hundred files costs well under a millisecond per poll. A native watcher can replace the poll later behind the same interface.
2. **What is watched.** The documents of the set (found again after every run, since an include can be added or removed) and the tangled files. Nothing else, so editing an unrelated file never runs anything. The map is not watched.
3. **Debounce.** A change starts a countdown of one interval, and every further change restarts it. Sync runs when the files have been quiet for that long. An editor that saves in several steps, or a formatter that rewrites many files, then causes one run.
4. **Output.** One block per run: a time, what changed, and then sync's own output (the report of untangle with its _needs prose_ lines, the report of tangle, or why it stopped). Nothing is printed on polls that find no change. No screen clearing.
5. **Stopping.** Control-C. Watch has no daemon mode and no pid file.

## Source Layout

| File | Responsibility |
|---|---|
| `src/watch.zig` | The snapshot of a set of files, and the comparison of two snapshots. The debounce as a small state machine. No IO except the stat function it is given. |
| `src/main.zig` | `sync` is split into a function that does one run and gives its result, so `sync` and `watch` share it. The `watch` command and its loop. |

## Phase 0: The Spec

Replace the "Later" in the Watch section with rules, and add the command:

- **W1.** Watch runs sync once at the start, then again whenever a watched file has changed and stayed unchanged for one interval.
- **W2.** The watched files are the documents of the set and the tangled files. The set is worked out again after every run.
- **W3.** A change is a difference in existence, size or modification time from what was seen last.
- **W4.** What Litmus writes during a run is not a change: the files are looked at again when the run is over.
- **W5.** If a run stops, watch reports why and waits for the next change. It does not retry, and it never forces.

Add `litmus watch [-o DIR] [--interval MS] DOCUMENT...` to the list of commands.

**Done when:** the spec has W1–W5 and the command, and the user has read them.

## Phase 1: Snapshots

`watch.zig` holds a `Snapshot`: for each path, whether it exists, its size and its modification time. Functions:

- `take(io, arena, dir, paths)` stats each path, and gives a snapshot.
- `changed(old, new)` returns the paths that differ, including paths in only one of them.
- A `Debounce` value with `observe(changed: bool, now) -> ready`: it becomes ready one interval after the last change, and not before.

The stat function is passed in, so the tests use a table of fake files.

Tests: no change; a file changed, added, removed; two changes in a row restart the countdown; a change after a quiet interval starts a new one.

**Done when:** the tests pass, one for each of W1, W3, W4 as far as they concern this file.

## Phase 2: One Run of Sync

`syncCommand` in `main.zig` becomes `syncOnce(ctx, options) !Outcome`, with the same work and printing, and an outcome that says which way it went and whether it succeeded. `litmus sync` calls it once. It also gives watch the list of files to watch: the documents of the set, and the tangled files, which sync already has in hand.

**Done when:** the sync cases and the self test pass unchanged.

## Phase 3: The Loop

`litmus watch [-o DIR] [--interval MS] DOCUMENT...`:

1. Run `syncOnce`. Take a snapshot of the files it reports.
2. Sleep one interval (`Io.sleep`).
3. Take a snapshot. If nothing differs, go back to 2. Otherwise start the debounce, and keep taking snapshots until it is ready.
4. Print the time and the files that changed, run `syncOnce`, take a snapshot again as the new baseline (W4), and go back to 2.

A failed run is printed and not retried (W5). Printing is flushed after each block, so a pipe or a log sees it at once. If a document cannot be read at some moment, because an editor is in the middle of replacing it, that shows up as a failed run, and the next save repairs it.

**Done when:** a run of the command in the terminal tangles after a document is saved, and untangles after a tangled file is saved, and prints nothing in between.

## Phase 4: Tests

- Unit tests for Phase 1 and 2.
- A watch case in the golden test runner: start `litmus watch` in the background in a sandbox, with a short interval; wait for its first block; change a tangled file; wait for the report of an untangle; change a document; wait for the tangle; check the files and documents; kill it. The waits poll for the expected output with a timeout, and fail with what was seen, so a slow machine is slow, not wrong. Cases: a change in each direction, both sides changed (watch reports, does nothing, and waits), a document with an error followed by a fix, and an include added while watching.
- A quiet check: after a run, with no change, the output does not grow for ten intervals (W4).

**Done when:** `zig build test`, `cases` and `self` pass.

## Phase 5: The Book

A chapter on watch, with a picture. The flow above is a good first one: a diagram of the loop, and a small animation of the stat, compare and debounce, in the style of the diff chapter. The guide and the paragraph that `init` writes get a line: an agent that works in a watched project does not need to run untangle by hand, but still has to write the prose and run `check`.

**Done when:** `zig build self` passes, and the user has read the chapter.

## Risks

- **Clock and file system resolution.** Modification times can have a resolution of a second on some file systems, and two saves in one second would look like one. Size is compared too, and a save that changes neither is read again at the next change. A later version can compare hashes of small files.
- **Editors that replace files.** A save by rename changes the inode and briefly removes the file. Existence is part of a snapshot, and the debounce hides the gap.
- **Many files.** Polling thousands of files every 200 ms is not free. The default can be raised, and a native watcher is the real fix. It is outside this plan.
- **Loops between tools.** A formatter that runs on save, and rewrites a tangled file, makes watch untangle, which changes a document, which makes watch tangle: files equal at the end, so it settles, but it is two runs. The report shows them.
- **Windows.** Not a target yet, as before.
