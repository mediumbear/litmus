# Reviewing Changes Made by AI

This plan is about one job: **a change in, a document that explains it out.** The change is one an AI made: a pull request, the uncommitted work in a checkout, or the commits of the current branch. The document says what changed and why, in the order that explains it best, points at the risky parts, and shows each idea in the way its reader takes ideas in best: for the first user, step-through visuals they can drive.

It grows out of a document made by hand for VRFY-25925, in which session tokens moved from `UserDefaults` to the keychain. That document worked. Making it taught five things, and this plan is built around them:

- `adopt` put every line of every touched file into the document, so an unrelated half of `AppDelegate.swift` ended up in it. The document needs to know which blocks hold changed lines.
- Moving blocks by hand was error-prone. A small assembler, which copied the skeleton's blocks verbatim into a template of prose and failed on a missing or duplicate block, worked well, and was cheap: the agent never wrote code back out.
- three.js as an ES module needed an import map, and module scripts do not run from `file://`, so the page had to be served over HTTP.
- Rendering needed Asciidoctor and Rouge, installed into a scratch `GEM_HOME`.
- About 55% of the session's cost came from writing the document at the end of a long session: every step re-read everything before it.

The ground rules of `doc/plan.md` apply: the spec first, Zig 0.17 with only the standard library, no regular expressions, `zig build test`, `cases` and `self` before each commit, one commit per phase, and changes to Litmus carried into the book with `litmus untangle`.

## The Flow

```
/litmus-review [pr 123 | wip | branch]
   ──► recommend a fresh session, if this one has history
   ──► read ~/.litmus/reader.md, or ask and write it the first time
   ──► ask: what to review (if not given), how much detail
   ──► git / gh: the diff, and a snapshot of the changed files
   ──► litmus adopt --diff ──► skeleton, with the changed lines marked
   ──► litmus blocks --changed ──► a short list of what changed, by block
   ──► agent reads the diff and the changed blocks, proposes an outline ──► user agrees
   ──► agent writes a template: prose, visuals, and one placeholder line per block
   ──► litmus assemble ──► the document, checked
   ──► render.sh ──► HTML that opens from file://, no network
```

Everything is written under `~/.litmus/reviews/`. Nothing is written to the repository under review, and nothing in it is built or run.

## Decisions

### A skill, a setup command, and four small additions to Litmus

The feature is a Claude Code skill, `litmus-review`, next to `litmus-document`. Its text ships with Litmus, like the other skill. What the hand-made document did with throwaway scripts becomes part of Litmus:

| Need | Where it goes |
|---|---|
| Which blocks hold changed lines | `adopt --diff FILE` (A9), shown by the weave (V3) |
| A cheap list of the blocks | `litmus blocks [--changed] DOCUMENT` |
| Placing blocks without copying code | `litmus assemble SKELETON TEMPLATE OUTPUT` |
| Libraries, widgets and the weave, offline | `litmus setup`, and `render.sh` in `~/.litmus/` |
| Pages that open from `file://` | classic scripts only (V4) |

### The skill is installed for the user, not the project

`litmus init` does not install `litmus-review`. A review never writes to the repository it reviews, and the skill is useful in every repository the user opens, so it belongs in `~/.claude/skills/litmus-review/`. A new command, `litmus setup`, installs it there, with everything else that lives in `~/.litmus/`. `init` and its expected cases under `test/cases/init-*` stay as they are.

`litmus setup` writes only files that ship with Litmus, and replaces older copies of them, like I5. It never touches `reader.md` or `reviews/`, and it does not use the network.

### The home directory

`~/.litmus/`, or `$LITMUS_HOME` when it is set:

```
~/.litmus/
  reader.md                  how the reader takes in ideas; written by the skill, with the user
  render.sh                  renders a review to HTML                    (from setup)
  weave/litmus-weave.rb      the weave                                   (from setup)
  kit/                       the widget kit: stepper, flow, timeline, sandbox, layers3d (from setup)
  cache/
    vendor/                  mermaid, dagre, konva, three.js, pinned     (downloaded once)
    gems/                    asciidoctor and rouge                       (installed once)
  reviews/<repo>/<slug>/     one folder per review
```

`setup` ships `render.sh`, the weave and the kit inside the binary, as it does the skills, so they always match the Litmus that installed them. Downloads happen only in `render.sh`, with `curl`, the first time they are needed. Each file is pinned to a version and its SHA-256, and the script refuses a file whose hash differs. Zig stays off the network.

### The reader's file: `~/.litmus/reader.md`

The user suggested `pr-plan.md`. I propose `reader.md`: the file describes the reader, not a plan, and the same file serves any Litmus document, not only reviews. `litmus-document` can read it too, as a base for a brief's `## Reader and style`.

```markdown
# Reader

## How I take in ideas
Extremely visual and kinesthetic. I understand what I can drive.

## Visuals, best first
1. Step-throughs: Back / Play / Step, one sentence of narration per step.
2. Scrubbable timelines.
3. Sandboxes: I press actions and watch the state change.
4. Mermaid diagrams for flows and state machines.

## Prose
Short and plain. The picture first, then a paragraph or two, then the code.

## Detail
default: walkthrough

## Settings
mermaid-theme: neutral
```

The skill reads it at the start. If it is missing, the skill asks the user four short questions (how they take in ideas, which visuals help, how much prose, which level of detail by default), writes the file, and shows it.

A repository may have its own notes for reviews in `.litmus/review.md`: what the code base is, its vocabulary, the parts that are risky. They **add** to `reader.md` and never override it: where they disagree about how to present things, `reader.md` wins. The skill reads that file but never writes it.

Each review gets its own `brief.md`, written by the skill: the goal (the change and where it came from), the level of detail, then `reader.md` and the repository's notes copied in. It is the document's style file (L10), so the review stays readable and self-contained after `reader.md` changes.

### Choosing the change

The skill takes `pr NUMBER|URL`, `wip`, or `branch`, or asks. In every case it produces two things: `change.diff`, and `code/`, a snapshot of the changed files as they are after the change. The document is a companion of `code/`, not of the repository. That keeps the review exact (the diff's line numbers match the adopted code), stable while the user keeps working, and outside the repository.

| | Diff | Snapshot of each changed file |
|---|---|---|
| `pr N` | `gh pr diff N` | `git fetch origin pull/N/head`, then `git show SHA:PATH` |
| `wip` | `git diff HEAD --diff-filter=d`, plus `git diff --no-index /dev/null FILE` for each file in `git ls-files --others --exclude-standard` | the working tree's file |
| `branch` | `git diff --diff-filter=d $(git merge-base BASE HEAD)..HEAD` | `git show HEAD:PATH` |

- The list of files comes from `--name-only --diff-filter=d` with the same range, so deleted files are left out. For a pull request it is `gh pr view N --json files` without the files the diff shows as deleted.
- For `branch`, the base is `gh pr view --json baseRefName` when the branch has a pull request, else the default branch, from `git symbolic-ref refs/remotes/origin/HEAD`. The skill states it and waits for the user to confirm.
- For `pr`, `gh pr view N --json title,body,url,baseRefName,headRefOid,commits` gives the intent; the description and the commit messages are the "why" the author claimed, which the document checks against the code.
- `git fetch` adds objects to the repository's object store and touches nothing else. It is the one write the skill makes to `.git`, and it says so.

The review's folder is `~/.litmus/reviews/<repo>/<slug>/`, where `<repo>` is the name of the top-level folder and `<slug>` is `pr-123`, `branch-<branch>`, or `wip-<branch>-<YYYYMMDD-HHMM>`, with `/` in a branch name made `-`. If the folder exists, the skill asks whether to replace it or to add `-2`.

### Which lines changed: `adopt --diff`

`litmus adopt --diff FILE` reads a unified diff, with or without context lines, as `git` and `gh` write it. For each adopted file it finds the file's hunks (by the `+++ b/path` line) and the lines of the new side that are added (`+`). Each block that holds such lines gets them on its source line, as ranges counted from the block's first line:

```
… KeychainStore.write :file: Sources/KeychainStore.swift
[source,swift,litmus-changed="3..7;12"]
-----
```

A block whose lines were removed at a place, with nothing added, gets `litmus-removed="N"`, N being how many. A file the diff shows as new gets every block marked. Files the diff names that are not adopted are ignored.

Block attributes were chosen over a separate file because they travel with the block: through `assemble`, through reordering by hand, through Asciidoctor. Litmus ignores them, so `check` and `untangle` are unaffected (L2). The ranges are a snapshot of the review: untangle does not update them when the code moves on. The spec says so.

### `litmus blocks`

```
litmus blocks [--changed] DOCUMENT...
```

One line per labeled block, in document order:

```
review.adoc:212  Sources/KeychainStore.swift  KeychainStore.write  18 lines  changed 3..7;12
review.adoc:240  Sources/KeychainStore.swift  KeychainStore.read   31 lines
```

With `--changed`, only the blocks with `litmus-changed` or `litmus-removed`. It is how the agent learns the names it needs for the template without reading the skeleton, and how it finds which blocks to read.

### `litmus assemble`

```
litmus assemble SKELETON TEMPLATE OUTPUT
```

The template is a document of prose with placeholders. A **placeholder** is a document command with no code block after it, alone on its line:

```asciidoc
Writing is where the accessibility class is set.

… KeychainStore.write :file: KeychainStore.swift

The read has three answers, not two.
```

The placeholder becomes the skeleton's block: its label, its source line, any title, and its code, verbatim. Its path is the block's file, or the end of that path after a `/`, if only one file of the skeleton ends that way; the long paths need not be written out. The placeholder's name is the block's name, as with any label; the file root is `… :file: path`.

A line `… :rest:` puts every block not yet placed there, file by file. Each file's blocks go under a level-3 heading with its path, inside a collapsible block (`[%collapsible]`, an asciidoc example block), so the unrelated half of `AppDelegate.swift` is there for `check`, and out of the reader's way.

Assemble copies the skeleton's `:litmus-style:` and `:litmus-companion:` into the output's header when the template has not got them. It reports, and writes nothing, when a placeholder names no block of the skeleton, a block is placed twice, or a block is not placed and there is no `:rest:`. Before writing, it tangles the output in memory and requires the skeleton's files back, byte for byte, as adopt does (A2). It overwrites OUTPUT, which is generated, and never SKELETON or TEMPLATE.

### The weave

- **V3, changed lines.** A listing with `litmus-changed` has those lines highlighted, and its label gets a small badge, `changed 6`, or `removed 2`. A section that holds such a listing gets a dot in the table of contents. A button beside the existing *sync* button shows only those sections in the table of contents.
- **V5, lines a picture points at.** Each line of a labeled listing gets an anchor the kit can find by the block's name and the line's number in the block, so a step of a widget can light lines of the code on the same page.
- **V4, local assets.** With the attribute `litmus-assets` (a folder, relative to the HTML), the weave loads Mermaid from `ASSETS/mermaid.min.js` with a classic script, instead of the module from jsdelivr. Without it, it does as today, so `doc/build.sh` is unchanged.

### Pages that open from `file://`

Module scripts do not run from `file://`; classic scripts do. So everything a review loads is a classic script:

- Mermaid ships one: `dist/mermaid.min.js`. dagre and Konva do too (`dist/dagre.min.js`, `konva.min.js`).
- three.js stopped shipping classic builds after r159, and its classic `OrbitControls` after r147. The kit pins **r147**: `build/three.min.js` and `examples/js/controls/OrbitControls.js`. That release is from 2022, but the kit uses only scenes, boxes, lights, text sprites and orbiting, which have not changed. No import map, no `docinfo.html`.
- The kit's widgets are classic scripts, as `lockday.js` and `sandbox.js` were.

I considered `litmus serve`, a small static server, and rejected it: it is one more thing to start and stop each time a document is opened, and a review should open with a double click, or be sent to a colleague as a folder. If a later visual needs a library that only exists as a module, `serve` can come then.

### The widget kit

The hand-made widgets were 165 to 253 lines each, nearly all of it controls, layout and styles. The kit keeps those once, so that a document only describes its model. Each widget is a classic script that defines a function on `window.LitmusKit`, mounted from a passthrough block:

```html
<div id="read-path"></div>
<script src="assets/kit/stepper.js"></script>
<script>
LitmusKit.stepper('#read-path', {
  boxes: [{ id: 'cache', label: 'Memory cache' }, { id: 'keychain', label: 'Keychain' }, ...],
  steps: [
    { say: 'The read starts at the cache.', at: 'cache' },
    { say: 'The cache is empty, so it falls through to the keychain.', at: 'keychain', set: { cache: 'empty' } },
    ...
  ],
});
</script>
```

- **stepper**: boxes and arrows in lanes, a token that moves between them, values in boxes; Back / Play / Step, the arrow keys, and one sentence of narration per step. The first choice for this reader.
- **timeline**: events along a scrubbable axis, lanes whose state at each event is shown (the generalised `lockday.js`), a choice of lane to focus on.
- **sandbox**: a state, actions with a condition and an effect (plain JavaScript functions), a view of the state, a log, presets (the generalised `sandbox.js`).
- **flow**: dataflow. Nodes and edges laid out by dagre, drawn in SVG. Values travel along the edges as small labelled packets, nodes show the values they hold, and a node that drops, transforms or fails a value shows it. Stepped like the stepper, and scrubbable. Where a Mermaid flowchart shows the paths, `flow` shows what moves along them, one step at a time; it is the first choice for any change that alters how data moves.
- **layers3d**: a stack of plates in three.js, a token falling through them, stepped like the stepper (the generalised `readpath3d.js`). Optional; used when depth helps.

They share one step engine: Back / Play / Step, the arrow keys, a scrubber, and one sentence of narration per step. A step may also name a block and its lines, `code: 'KeychainStore.write 3..7'`, and the weave lights those lines in the listing on the page while the step is shown, so stepping the picture steps the code with it. The widgets share one look (a light frame, the same buttons, the narration line) and work at phone width.

### Which libraries

The kit draws with a few libraries, chosen for what each does best. All of them ship a classic build, so all work from `file://`:

| Library | Size | For | Why |
|---|---|---|---|
| Mermaid | 5.5 MB | static diagrams written as text | Cheapest for the agent to write; already in the weave. Recent versions animate edges (`e1@{ animate: true }`), a cheap kind of dataflow inside an ordinary flowchart; to confirm in P4, with the pin moved to the current 12.x. |
| @dagrejs/dagre | 49 KB, MIT | laying out `flow` | The layered layout Mermaid uses itself. The kit lays out with it and draws and animates the SVG itself, so packets, values and highlights are its own. |
| Konva | 196 KB, MIT | `sandbox` when the reader drags things | A canvas scene graph with hit testing, dragging and tweens. Lets a sandbox be touched directly: drag a token into the keychain, drag the clock past midnight. |
| three.js r147 | 600 KB, MIT | `layers3d` only | Depth, when depth explains something. |

The animation itself uses the browser's Web Animations API, which can pause, reverse and seek to any time, and so needs no library for stepping and scrubbing.

Considered and left out:

- **Two.js**: a good drawing API, but it covers what Konva does with weaker hit testing and no dragging of its own. One 2D library is enough, and Konva's interaction is the part this reader uses.
- **GSAP**: the best timeline library, but its licence is free of charge, not open source, and the Web Animations API does what the step engine needs.
- **D3**: excellent for charts of data, which reviews rarely need, and its layout and transitions overlap with dagre and the step engine. It can come when a review needs a chart.
- **ELK.js**: better layouts than dagre for large graphs, but 1.5 MB and EPL or GPL. Changes are small graphs.
- **Cytoscape.js**: for exploring large graphs. A later candidate for a map of the files a change touches and how they call each other.
- **React Flow, Motion Canvas, Excalidraw**: need a bundler or a framework.

### Detail, asked every time

The skill always asks, offering the default from `reader.md`:

- **overview**: one screen. What changed and why, the risks, two or three diagrams. No outline approval: it is short enough to redo.
- **walkthrough**: a chapter per idea, a visual for each, the changed blocks with prose. The outline is shown and approved first.
- **deep**: walkthrough, plus every changed excerpt explained, edge cases, and a chapter mapping tests to the behaviour they cover, with the changed code that no test covers.

### Pointing at the risky parts

Every review opens with a short **Risks** list, each item linking to the block it is about, which carries a `WARNING` admonition. The skill tells the agent what to look for in AI-written code: behaviour that changed without a mention in the description, errors swallowed or widened, concurrency and ordering, migrations of stored data, security-sensitive calls, tests that assert little, code that is never called, comments that disagree with the code, and APIs the agent cannot confirm exist. Since nothing is built, anything the agent could not confirm is marked **unverified**, not guessed.

### Never building, and keeping the session small

The skill states the commands it may run: `git` (read-only, plus the one `fetch`), `gh pr view` and `gh pr diff`, `litmus`, `~/.litmus/render.sh`, and `mkdir`, `cp`, `ls` inside the review's folder. It never builds, tests, lints, formats, or resolves packages in the reviewed project (`xcodebuild`, `swift build`, `zig build`, `npm`, `pod`, and the like), even to check a guess.

It opens with a check: if the conversation has turns before the skill was invoked, it recommends starting a new session with the same `/litmus-review` command, explains that in the last run the late start cost about half the session, and stops unless the user says to continue here.

While it works, it keeps tool output small:

- Commands that can print a lot write to a file in the review folder and print a summary or the last lines (`render.sh` prints one line per page, or the first error).
- It reads the diff and `litmus blocks --changed`, then only the blocks it needs, with line ranges; never the whole skeleton.
- It writes the template once per chapter and never writes code, since `assemble` places it.
- It never prints whole files to the user; it gives paths.

### render.sh

`~/.litmus/render.sh DOCUMENT` does what `doc/build.sh` does, for any document:

1. Installs Asciidoctor and Rouge into `~/.litmus/cache/gems` on first use, with Ruby's own gems kept on the path.
2. Downloads the pinned libraries into `~/.litmus/cache/vendor` if they are missing, and checks their hashes.
3. Renders with `~/.litmus/weave/litmus-weave.rb`, `-a litmus-assets=assets`, into `build/` beside the document.
4. Copies the kit and the libraries the pages use into `build/assets/`, so the folder works on its own.
5. Prints the path of the HTML.

## Spec Changes

- **A9.** `adopt --diff FILE`: the attributes `litmus-changed` and `litmus-removed`, as above, and that Litmus does not keep them up to date.
- **L12.** A block's source line may carry `litmus-changed` and `litmus-removed`. They are for the weave; tangle, untangle and check ignore them.
- **A new section, Assemble,** with rules **S1** (placeholders, and paths by their end), **S2** (`… :rest:`), **S3** (the errors), and **S4** (the check before writing, and what it overwrites).
- **`litmus blocks`** in Commands, with its output format.
- **V3** (changed lines in the weave), **V4** (`litmus-assets`) and **V5** (lines a picture can point at).
- **A new section, Setup,** with rules **H1** (the home directory and `LITMUS_HOME`), **H2** (what `setup` writes: the review skill to `~/.claude/skills/litmus-review/SKILL.md`, and `render.sh`, the weave and the kit to the home directory), and **H3** (it replaces older copies, never touches `reader.md`, `cache/` or `reviews/`, prints each change, and changes nothing the second time).
- The guide gains a paragraph naming `litmus-review` and `litmus setup`.

## Phases

- **P0, spec.** The rules above, in `doc/litmus.adoc`.
- **P1, `adopt --diff` and `litmus blocks`.** A unified diff reader with no regular expressions; the attributes on the source line; golden cases for a diff with context, without context, a new file, a removal only, a rename, and a file the diff does not name.
- **P2, `litmus assemble`.** Golden cases for placeholders with full and shortened paths, an ambiguous path, `:rest:`, a missing block, a block placed twice, and a block left over.
- **P3, the weave.** V3, V4 and V5. Checked by rendering the book, unchanged, and a small case with changed blocks.
- **P4, the kit and `render.sh`.** The step engine, then the five widgets: `stepper` and `flow` first, then `timeline`, `sandbox` and `layers3d`, ported from the hand-made ones and generalised. Pin each library at its current classic build, with its hash, and confirm Mermaid's animated edges. A test page in `share/kit/demo.adoc` with one of each, rendered and opened from `file://` in the browser.
- **P5, `litmus setup` and the skill.** The skill's text, embedded, and `setup` writing the home directory. The kit, `render.sh` and the weave live in `share/` and `doc/` and are embedded through `build.zig`. Golden cases for `setup` with an empty home, an older copy, and a second run.
- **P6, the book.** The new Zig code is written into `doc/implementation.adoc` with `untangle`, with its prose; `zig build self` passes.
- **P7, a demo** on a small real diff: this repository's pull request 1 (the split weave, V2), at the walkthrough level, from a fresh session. What it teaches goes back into the skill.

## Decided

The user agreed: `reader.md`; three.js pinned at r147 rather than `litmus serve`; a snapshot of the changed files rather than the live repository; and `litmus setup` as a command of its own, with `init` left as it is.
