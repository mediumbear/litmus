package litmus

import "core:testing"

@(test)
test_empty_source :: proc(t: ^testing.T) {
    tokens := tokenize("")
    defer delete(tokens)
    testing.expect_value(t, len(tokens), 0)
}

@(test)
test_single_doc_line :: proc(t: ^testing.T) {
    tokens := tokenize("Just some prose.")
    defer delete(tokens)
    testing.expect_value(t, len(tokens), 1)
    testing.expect_value(t, tokens[0].kind, Token_Kind.DocLine)
    testing.expect_value(t, tokens[0].line, 1)
    testing.expect_value(t, tokens[0].col, 1)
    testing.expect_value(t, tokens[0].text, "Just some prose.")
}

@(test)
test_fence_open_and_close :: proc(t: ^testing.T) {
    src := "```odin\nfoo\n```"
    tokens := tokenize(src)
    defer delete(tokens)

    testing.expect_value(t, len(tokens), 3)
    testing.expect_value(t, tokens[0].kind, Token_Kind.FenceStart)
    testing.expect_value(t, tokens[0].text, "```odin")
    testing.expect_value(t, tokens[1].kind, Token_Kind.CodeLine)
    testing.expect_value(t, tokens[1].text, "foo")
    testing.expect_value(t, tokens[2].kind, Token_Kind.FenceEnd)
    testing.expect_value(t, tokens[2].text, "```")
}

@(test)
test_code_excerpt_outside_fence :: proc(t: ^testing.T) {
    tokens := tokenize("… the imports")
    defer delete(tokens)

    testing.expect_value(t, len(tokens), 2)
    testing.expect_value(t, tokens[0].kind, Token_Kind.CodeExcerptCommand)
    testing.expect_value(t, tokens[0].col, 1)
    testing.expect_value(t, tokens[0].length, len(COMMAND))
    testing.expect_value(t, tokens[0].text, "… ")
    testing.expect_value(t, tokens[1].kind, Token_Kind.CodeExcerpt)
    testing.expect_value(t, tokens[1].col, 1 + len(COMMAND))
    testing.expect_value(t, tokens[1].length, len("the imports"))
    testing.expect_value(t, tokens[1].text, "the imports")
}

@(test)
test_code_reference_inside_fence_preserves_indent :: proc(t: ^testing.T) {
    // Indent on the reference line matters: tangle will re-indent the
    // expanded excerpt by this amount.
    src := "```\n    … the rest\n```"
    tokens := tokenize(src)
    defer delete(tokens)

    testing.expect_value(t, len(tokens), 4)
    testing.expect_value(t, tokens[0].kind, Token_Kind.FenceStart)
    testing.expect_value(t, tokens[1].kind, Token_Kind.CodeReferenceCommand)
    testing.expect_value(t, tokens[1].col, 5) // 4 spaces of indent + 1
    testing.expect_value(t, tokens[2].kind, Token_Kind.CodeReference)
    testing.expect_value(t, tokens[2].col, 5 + len(COMMAND))
    testing.expect_value(t, tokens[2].text, "the rest")
    testing.expect_value(t, tokens[3].kind, Token_Kind.FenceEnd)
}

@(test)
test_doc_line_with_ellipsis_mid_text_is_not_a_command :: proc(t: ^testing.T) {
    // The command marker must appear after only whitespace.
    tokens := tokenize("starts with … but not a command")
    defer delete(tokens)
    testing.expect_value(t, len(tokens), 1)
    testing.expect_value(t, tokens[0].kind, Token_Kind.DocLine)
}

@(test)
test_full_sample_kinds :: proc(t: ^testing.T) {
    src :=
`intro
… :file: main.odin
` + "```" + `odin
… imports
main :: proc() {
    … the rest
}
` + "```" + `
tail`
    tokens := tokenize(src)
    defer delete(tokens)

    expected := []Token_Kind{
        .DocLine,                    // intro
        .CodeExcerptCommand, .CodeExcerpt, // … :file: main.odin
        .FenceStart,                 // ```odin
        .CodeReferenceCommand, .CodeReference, // … imports
        .CodeLine,                   // main :: proc() {
        .CodeReferenceCommand, .CodeReference, //     … the rest
        .CodeLine,                   // }
        .FenceEnd,                   // ```
        .DocLine,                    // tail
    }
    testing.expect_value(t, len(tokens), len(expected))
    for kind, i in expected {
        testing.expect_value(t, tokens[i].kind, kind)
    }
}
