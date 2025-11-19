package litmus

import "core:odin/tokenizer"
import "core:fmt"
import str "core:strings"

sample := `Here is a sample to parse. The litmus command starts with …
Here is some code:
… main.odin
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

// Most col = 1 (1 indexed). But there can be whitespace in front of a code excerpt for tabbing. Important when tangling.
Token_Kind :: enum {
    FenceStart,
    FenceEnd,
    CodeReferenceCommand,
    CodeReference,
    CodeExcerptCommand,
    CodeExcerpt,
    DocLine,
    CodeLine,
}

Token :: struct {
    kind: Token_Kind,
    line, col, length: int,
    text: string,
}

tokens: [dynamic]Token

main :: proc() {
    fmt.println(sample)
    // Need to emit tokens:
    // fenceStart - the first ```
    // fenceEnd - the "closing" ```
    // excerpt - a … in a doc area
    // reference - a … in a code fence
    // docLine - a line of text outside of fences
    // codeLine - a line of text inside of fences

    // With the above we will create an AST. Lines will become code and doc chunks. code chunks become a code block.
    // This should be enough!




    // The current document or code blocks
    inFence := false

    // lines := str.split(sample, "\n")


    lineNum := 0
    for line in str.split_lines_iterator(&sample) {
        lineNum += 1
        if str.starts_with(line, "```") {
            inFence = !inFence
            if inFence {
                fmt.println(lineNum, "Fence start")
                token := Token{ kind = .FenceStart, line = lineNum, col = 0, length = 3, text = line[0:3] }
                append(&tokens, token)
            } else {
                fmt.println(lineNum, "Fence end")
                token := Token{ kind = .FenceEnd, line = lineNum, col = 0, length = 3, text = line[0:3] }
                append(&tokens, token)
            }

            continue
        }

        if str.starts_with(str.trim(line, " \t"), "…") {
            // TODO: will need to deal with leading whitespace.
            index := str.index(line, "…")
            if inFence {
                fmt.println(lineNum, "Code Reference = ", line)
                token := Token{ kind = .CodeReferenceCommand, line = lineNum, col = 0, length = index + 1, text = line[0:index + 1] }
                append(&tokens, token)
                // TODO: Should be a single space! Want the spaces, they can be ignored for parsing, but needed later.
                refToken := Token{ kind = .CodeReference, line = lineNum, col = index + 1, length = len(line) - index - 1, text = line[index + 1:] }
                append(&tokens, refToken)
            } else {
                fmt.println(lineNum, "Code Excerpt = ", line)
                token := Token{ kind = .CodeExcerptCommand, line = lineNum, col = 0, length = 3, text = line[0:index + 1] }
                append(&tokens, token)
                refToken := Token{ kind = .CodeExcerpt, line = lineNum, col = index + 1, length = len(line) - index - 1, text = line[index + 1:] }
                append(&tokens, refToken)
            }
        } else {
            if inFence {
                fmt.println(lineNum, "Code line = ", line)
                token := Token{ kind = .CodeLine, line = lineNum, col = 0, length = len(line), text = line }
                append(&tokens, token)
            } else {
                fmt.println(lineNum, "Doc line = ", line)
                token := Token{ kind = .DocLine, line = lineNum, col = 0, length = len(line), text = line }
                append(&tokens, token)
            }
        }
    }

    fmt.println(tokens)

    fmt.println("\n---\n")

    fmt.println(sample)
}
