---
name: litmus-review
description: Explain a code change that an AI made (a pull request, the uncommitted work in a checkout, or the commits of the current branch) as a Litmus document with step-through visuals, in the order that explains it best, with the risky parts marked. Use when the user asks to review, understand or walk through a PR, a diff, a branch or AI-written changes, or says /litmus-review.
---

# Reviewing a change with Litmus

You make a document that explains one change to one reader: what changed, why, in the
order that explains it best, and what is risky. Litmus holds the code and proves the
document matches it; the widget kit makes the pictures the reader can drive.

Arguments: `pr NUMBER|URL`, `wip`, or `branch`. If none is given, ask which.

## 0. Start fresh

If this conversation has turns before this skill was invoked, stop and say:

> A review reads a lot of code, and every step re-reads the whole conversation. Last time,
> about half the cost of a session came from writing the document at its end. Start a new
> session with `/litmus-review <same arguments>`, or say "continue here".

Go on only if the user says to continue here.

## The rules

- **Never build or run the project.** No `xcodebuild`, `swift build`, `swift test`,
  `zig build`, `npm`, `yarn`, `pod`, `gradle`, `cargo`, `make`, linters, formatters or
  package managers, not even to check a guess. What you cannot confirm by reading, you
  mark **Unverified**.
- **The only commands you run** are: `git` to read (`diff`, `show`, `log`, `merge-base`,
  `ls-files`, `cat-file`, `rev-parse`, `symbolic-ref`, and `fetch` for a pull request);
  `gh pr view` and `gh pr diff`; `litmus`; `~/.litmus/render.sh`; and `mkdir`, `cp`,
  `ls`, `wc`, `sed -n` and `head` inside the review folder.
- **Never write to the repository.** Everything goes in the review folder. `git fetch`
  only adds objects; say so when you run it.
- **Keep output small.** Send long output to a file in the review folder and print a
  count or the last lines. Never print a whole file to the user; give its path. Read
  blocks by their line ranges, not whole files.
- Use `litmus` from the PATH. If it is missing, ask the user where it is.
- If `~/.litmus/render.sh` is missing, run `litmus setup` first.

## 1. The reader

Read `~/.litmus/reader.md` (or `$LITMUS_HOME/reader.md`). If it does not exist, ask these
in one message, offering the answers in brackets as defaults, then write the file and show
its path:

1. How do you take in new code best? [visual: pictures first, then a little prose]
2. Which visuals help most, best first? [step-throughs with Back / Play / Step and one
   sentence per step; scrubbable timelines; sandboxes where you press actions; diagrams]
3. How much prose? [short and plain]
4. Default level of detail: overview, walkthrough or deep? [walkthrough]

```markdown
# Reader

## How I take in ideas
...

## Visuals, best first
1. ...

## Prose
...

## Detail
default: walkthrough

## Settings
mermaid-theme: neutral
```

If the repository has `.litmus/review.md`, read it too: what the code base is, its words,
its risky parts. It adds to `reader.md` and never overrides it: on how to present, the
reader's file wins. Never write to it.

## 2. Ask how much detail

Every time, offer the three levels with the reader's default first:

- **overview**: one screen. What changed and why, the risks, two or three pictures. Only
  the few most important changed blocks are shown; the rest is in the appendix.
- **walkthrough**: a chapter per idea, a visual for each, every changed block with prose.
- **deep**: a walkthrough, plus every changed block explained line by line where it
  matters, edge cases, and a chapter mapping tests to behaviour, with changed code that
  no test covers.

## 3. The change

`REPO` is the name of the repository's top folder. The review folder `R` is
`~/.litmus/reviews/REPO/SLUG/`, where SLUG is `pr-123`, `branch-NAME` or
`wip-NAME-YYYYMMDD-HHMM`, with `/` in a branch name made `-`. If `R` exists, ask whether
to replace it or to add `-2`. Then make `R/code/`.

Each case writes `R/change.diff`, `R/files.txt` (the changed files that still exist, one
per line) and a snapshot of those files under `R/code/`, as they are after the change.
Quote paths: they may hold spaces.

**pr N** (a number or a URL):

```bash
gh pr view N --json number,title,body,url,baseRefName,headRefOid,commits > R/pr.json
gh pr diff N > R/change.diff
git fetch --no-tags origin "pull/N/head"          # adds objects only
SHA=$(gh pr view N --json headRefOid -q .headRefOid)
gh pr diff N --name-only | while IFS= read -r f; do
  git cat-file -e "$SHA:$f" 2> /dev/null && echo "$f"; done > R/files.txt
while IFS= read -r f; do mkdir -p "R/code/$(dirname "$f")"; git show "$SHA:$f" > "R/code/$f"; done < R/files.txt
```

**wip** (staged, unstaged, and new files that git does not ignore):

```bash
git diff HEAD --diff-filter=d --no-color --no-ext-diff > R/change.diff
git ls-files --others --exclude-standard > R/new.txt
while IFS= read -r f; do git diff --no-index --no-color -- /dev/null "$f" >> R/change.diff; done < R/new.txt
{ git diff HEAD --name-only --diff-filter=d; cat R/new.txt; } > R/files.txt
while IFS= read -r f; do mkdir -p "R/code/$(dirname "$f")"; cp "$f" "R/code/$f"; done < R/files.txt
```

(`git diff --no-index` exits with 1 when files differ; that is expected.)

**branch** (only this branch's own commits):

1. Find the base: `gh pr view --json baseRefName -q .baseRefName` if the branch has a pull
   request, else the default branch, `git symbolic-ref --short refs/remotes/origin/HEAD`.
   **Tell the user the base and wait for them to confirm it.**
2. Then, with `BASE` as confirmed (`origin/BASE` if it is a remote branch):

```bash
MB=$(git merge-base BASE HEAD)
git diff "$MB..HEAD" --diff-filter=d --no-color --no-ext-diff > R/change.diff
git diff "$MB..HEAD" --diff-filter=d --name-only > R/files.txt
git log --format='%h %s%n%n%b' "$MB..HEAD" > R/commits.txt
while IFS= read -r f; do mkdir -p "R/code/$(dirname "$f")"; git show "HEAD:$f" > "R/code/$f"; done < R/files.txt
```

Print only `wc -l < R/files.txt` and the diff's size (`wc -l < R/change.diff`). If the
change has more than about 40 files or 3000 changed lines, say so and ask whether to
narrow it to some folders first.

## 4. The brief and the skeleton

Write `R/brief.md`, the document's style file:

```markdown
# Brief: <the change, in a few words>

## Goal
Understand <PR #N "title" | the uncommitted work on BRANCH | the commits of BRANCH since BASE>,
made by an AI: what changed, why, and what is risky. Level: <overview|walkthrough|deep>.

## Reader and style
<the sections of reader.md, copied>
<the repository's notes from .litmus/review.md, if any, marked as additions>

## Settings
<the Settings of reader.md>
```

Then, from `R`:

```bash
cd R
litmus adopt -o code --companion --style brief.md --diff change.diff skeleton.adoc $(cat files.txt)
litmus blocks --changed skeleton.adoc > changed.txt
wc -l < changed.txt
```

If a file name has spaces, pass the files without `$(...)`, quoted one by one. Adopt skips
files that are not text. It refuses, and writes nothing, when a file does not end with a
newline or has a line that starts with `…` or `include::`: leave such files out of
`files.txt`, run adopt again, and name them in the brief as not shown. `changed.txt` has one line per changed block: where it is, its
file, its name, its size, and the changed lines counted from its first line.

## 5. Read, then propose an outline

Read, in this order, and no more than you need:

1. The intent: `pr.json` (title, body, commit messages) or `commits.txt`. This is what
   the author claims; the document checks it against the code.
2. `change.diff`, in pieces if it is long.
3. The changed blocks, by the line ranges in `changed.txt`: `sed -n 'A,Bp' skeleton.adoc`.
   Read unchanged blocks only when a changed one cannot be understood without them.

Look for what is risky in AI-written code: behaviour that changed without a word in the
description; errors swallowed, widened, or turned into defaults; concurrency, ordering and
re-entrancy; stored data that must migrate; security-sensitive calls; deleted checks;
tests that assert little or mock the thing under test; code that nothing calls; comments
that disagree with the code; APIs you cannot confirm exist. Anything you could not
confirm by reading is **Unverified**.

For **walkthrough** and **deep**, write the outline in the conversation and stop until the
user agrees: the chapters in the order that explains the change (usually: the problem,
the core change, how data moves, edge cases, migration, tests), which blocks go in each,
and one picture per chapter, chosen by the reader's order of visuals. For **overview**,
go straight on.

## 6. Write the template

Write `R/template.adoc`: prose, pictures, and a **placeholder** where each block goes. A
placeholder is the block's label alone on its line, with a blank line after it:

```asciidoc
… KeychainStore.write :file: KeychainStore.swift
```

Use the names from `changed.txt`. The path may be shortened to its end if only one file
ends that way. `litmus assemble` copies each block exactly, so **never write code into the
template**. The template's shape:

```asciidoc
= <Title>
:toc: left
:toclevels: 2
:sectanchors:

<Two or three sentences: what changed and why.>

== Risks

. <<risk-locked,A locked keychain must not sign the user out>>: one sentence on why.
. *Unverified:* <what could not be confirmed by reading>.

== <First idea>

<The picture first, then a paragraph or two, then the blocks.>

[[risk-locked]]
[WARNING]
====
<The risk, where its code is.>
====

… <name> :file: <path>

== The rest of the code

… :rest:
```

Keep `… :rest:` at the end from the start, so that every assemble passes while chapters
are still missing. Write one chapter at a time, and after each:

```bash
litmus assemble skeleton.adoc template.adoc review.adoc && litmus check -o code review.adoc
```

Fix what they report. They print a few lines; do not print the document.

## 7. Pictures

Choose by the reader's order of visuals, and give each its job:

| Picture | For |
|---|---|
| `stepper` | a sequence: a call that goes through layers, a request, a lookup |
| `flow` | data that moves between parts, and where it is dropped or fails |
| `timeline` | state that changes over time, and what works at each moment |
| `sandbox` | "what if": actions in any order, and the state they leave |
| `layers3d` | a lookup that falls through layers, when depth helps |
| Mermaid | structure that does not move: types, a state machine, a call graph |

Every step has one sentence of narration (`say`), and may light the lines it talks
about: `code: 'NAME 3..7'`, counted from the block's first line, as in `changed.txt`. Put
each widget in a passthrough block. Load `kit.js` once, before the first widget; the
other scripts before the widget that needs them:

```asciidoc
++++
<div id="read-path"></div>
<script src="assets/kit/kit.js"></script>
<script src="assets/kit/stepper.js"></script>
<script>
LitmusKit.stepper('#read-path', {
  boxes: [{ id: 'cache', label: 'Memory cache', value: 'empty' }, { id: 'keychain', label: 'Keychain' }],
  arrows: [{ from: 'cache', to: 'keychain', label: 'miss' }],
  token: 'read',
  steps: [
    { say: 'The read starts at the cache.', at: 'cache', code: 'TokenService.value 2' },
    { say: 'Empty, so it asks the keychain.', at: 'keychain', arrow: 'cache>keychain' },
    { say: 'The keychain answers.', set: { cache: 'token' }, good: ['keychain'], token: 'token' },
  ],
});
</script>
++++
```

The other widgets, with the scripts each needs:

- `flow` (`assets/vendor/dagre.min.js`, `assets/kit/flow.js`): `{ direction: 'LR', nodes:
  [{ id, label, kind: 'process'|'store'|'external'|'decision', value }], edges: [{ from,
  to, label }], steps: [{ say, send: { from, to, value } or a list, set: { id: value },
  fail: [ids], drop: [ids], good: [ids], code }] }`
- `timeline` (`assets/kit/timeline.js`): `{ states: { KEY: { label, color } }, events:
  [{ title, state, say, code }], lanes: [{ id, label, values: ['ok'|'fail'|'warn'|'idle',
  ...one per event], note }], focus: laneId }`
- `sandbox` (`assets/kit/sandbox.js`): `{ state, boxes: [{ id, label, items: s => [...] }],
  actions: [{ label, when: s => bool, run: s => 'what happened', code }], switches: [{ key,
  label, value }], result: s => ({ text, tone: 'good'|'bad'|'neutral' }), presets: [{
  label, actions: [labels] }], drop: (s, item, from, to) => 'what happened' }`
- `layers3d` (`assets/vendor/three.min.js`, `assets/vendor/OrbitControls.js`,
  `assets/kit/layers3d.js`): `{ layers: [{ id, label, color }], token, steps: [{ say, at:
  layerId|null, pass, good, bad, token, code }] }`
- Mermaid: `<pre class="mermaid">` in a passthrough block. Flowchart edges can move:
  `a e1@--> b` and then `e1@{ animate: true }`.

Give every widget a different `id`. Do not split the review into pages (`litmus-split`).

## 8. Render and hand over

```bash
~/.litmus/render.sh R/review.adoc
```

It prints the path of the page, which opens from `file://` with no network. Tell the user,
in at most five lines: the path, the chapters, and the top risks. Offer to open it.

## Never

- build, run or test the project, or install anything into it;
- write anything in the repository, or change `R/code/`;
- write code into the template, or change a line of a block;
- edit a `.litmus/map`;
- use `--force`.
