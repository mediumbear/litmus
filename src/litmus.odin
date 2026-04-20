package litmus

import "core:fmt"
import str "core:strings"

/*
    # Litmus document structure

    A Litmus document is Markdown-ish prose interleaved with fenced code
    blocks. The marker `… ` (horizontal ellipsis + space) introduces a
    Litmus command.

    ## Code excerpts (outside a fence)

        … the imports
        ```
        import something
        ```

    ## Source file excerpt

        … :file: doit.odin

    Everything that follows (until the next file excerpt) tangles into
    this file.

    ## Named excerpt bound to a source file

        … the imports :file: doit.odin
        ```
        import something
        ```

    ## Doc-only excerpt (not tangled)

        … :doc:

    ## Code references (inside a fence)

        main :: proc() {
            … the rest
        }

    At tangle time the reference `… the rest` is replaced with the body
    of that excerpt, indented by the reference's own leading whitespace.
    The excerpt itself is stored without its own indentation.
*/

Token_Kind :: enum {
    FenceStart,           // ``` or ```odin etc.
    FenceEnd,             // closing ```
    CodeExcerptCommand,   // the "… " outside a fence
    CodeExcerpt,          // the text after "… " outside a fence
    CodeReferenceCommand, // the "… " inside a fence
    CodeReference,        // the text after "… " inside a fence
    DocLine,              // any line outside a fence
    CodeLine,             // any line inside a fence
}

Token :: struct {
    kind:   Token_Kind,
    line:   int, // 1-indexed
    col:    int, // 1-indexed, byte column
    length: int, // byte length
    text:   string,
}

COMMAND :: "… "

tokenize :: proc(source: string, allocator := context.allocator) -> [dynamic]Token {
    tokens := make([dynamic]Token, allocator)
    in_fence := false
    line_num := 0
    src := source
    for line in str.split_lines_iterator(&src) {
        line_num += 1

        if str.starts_with(line, "```") {
            kind: Token_Kind = .FenceEnd if in_fence else .FenceStart
            in_fence = !in_fence
            append(&tokens, Token{kind, line_num, 1, len(line), line})
            continue
        }

        trimmed := str.trim_left(line, " \t")
        if str.starts_with(trimmed, COMMAND) {
            indent := len(line) - len(trimmed)
            cmd_col := indent + 1
            ref_start := indent + len(COMMAND)
            ref_text := line[ref_start:]

            cmd_kind: Token_Kind = .CodeReferenceCommand if in_fence else .CodeExcerptCommand
            ref_kind: Token_Kind = .CodeReference if in_fence else .CodeExcerpt

            append(&tokens, Token{cmd_kind, line_num, cmd_col, len(COMMAND), line[indent:ref_start]})
            append(&tokens, Token{ref_kind, line_num, ref_start + 1, len(ref_text), ref_text})
            continue
        }

        kind: Token_Kind = .CodeLine if in_fence else .DocLine
        append(&tokens, Token{kind, line_num, 1, len(line), line})
    }
    return tokens
}

sample := `Here is a sample to parse. The litmus command starts with …
Here is some code:
… :file: main.odin
` + "```" + `odin
… imports

main :: proc() {
    … the rest
}
` + "```" + `

And here is the rest:
… the rest
` + "```" + `odin
fmt.println("Hello")
` + "```" + `

along with the imports:
… imports
` + "```" + `
import "core.fmt"
` + "```"

main :: proc() {
    tokens := tokenize(sample)
    defer delete(tokens)

    for tok in tokens {
        fmt.println(tok)
    }
}
