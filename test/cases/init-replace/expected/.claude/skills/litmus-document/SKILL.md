---
name: litmus-document
description: Make a literate document for existing code with Litmus, from a brief that lists the files, the goal and the reader. Use when the user asks for a literate document, a readable explanation of a module, or names a Litmus brief.
---

# Making a literate document with Litmus

A literate document explains code in prose, with the code in the order that explains it
best. Litmus keeps the document and the code equal: tangling the document gives the code
byte for byte. Run `litmus guide` first if you have not; it says how a Litmus project works.
Use the Litmus command that AGENTS.md names, or `litmus`.

## The brief

The user gives a brief: a Markdown file with these sections.

- `## Files`: files and folders, relative to the code's directory, one per line. Or a
  command that lists them, such as `git diff --name-only A..HEAD`.
- `## Goal`: why the user wants the document. Aim the explanation at it.
- `## Reader and style`: who reads the document, and how prose and pictures are done.
- `## Settings`: optional `key: value` lines for the weave, such as `mermaid-theme: neutral`.
- `## Output`: `document:` the path of the new document; `code:` the code's directory;
  `kind:` `owned` (the document lives with the code and owns it) or `companion` (the
  document is for reading, lives anywhere, and never writes to the code).

If the brief is missing something, ask the user before you start.

## Steps

1. Read the brief. Expand its folders, or run its command, to get the list of files.
   If the list is long, show it to the user.
2. Make the skeleton:
   `litmus adopt -o CODE [--companion] --style BRIEF DOCUMENT FILES...`
   where BRIEF is the brief's path relative to the document. Then run
   `litmus check -o CODE DOCUMENT`. It must pass.
3. Read the code. Propose an outline: the chapters, the order that explains the code
   best, and the pictures each chapter needs. Write it in the conversation, and stop.
   Do not write prose until the user agrees.
4. For each chapter, in the style of the brief:
   - Move the excerpt blocks into the order of the outline. A block moves with its
     label, the `… name :file: path` line above it. Never change a line of code, and
     never change a label.
   - Write prose before each block: what it does, then why. Lead with the idea, then the
     detail. Use the names the code uses.
   - Add pictures where the style asks: Mermaid diagrams in `++++` passthrough blocks
     as `<pre class="mermaid">`, and animations as small scripts.
   - Code that only illustrates goes in a block with no label. It is shown, never tangled.
   - Run `litmus check -o CODE DOCUMENT` after each chapter. It must pass.
5. Render the document with the project's build for documents, or `asciidoctor`, and ask
   the user to read it.

## While the code moves

For a document that stays in use, run `litmus watch -o CODE DOCUMENT` in the background
and read what it prints. Every block of its output ends with a `next:` line that says what
to do: usually, write prose for the blocks that grew, in the style of the brief.

## Never

- change the code of a companion document's code directory;
- edit `.litmus/map`;
- start a line of code with `…` (U+2026);
- use `--force` unless the user asks.
