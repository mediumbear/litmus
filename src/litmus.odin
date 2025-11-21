package litmus

import "core:odin/tokenizer"
import "core:fmt"
import str "core:strings"

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

/*
    # Code excerpts

    ## A named excerpt
        > ... the imports
        > ```
        > import something
        > ```

    ## Source file
        > ... :file: doit.odin
    When this appears, everything that follows is in this file.

    ## A named export with source file
        > ... the imports :file: doit.odin
        > ```
        > import something
        > ```

    ## Doc excerpt - these don't go into the source code - this is code that is documentation. 
        > ... :doc:
*/

// Most col = 1 (1 indexed). But there can be whitespace in front of a code excerpt for tabbing. Important when tangling.
Token_Kind :: enum {
    // e.g. ```, ```odin etc.
    FenceStart,
    // should only be ```.
    FenceEnd,
    // "… " inside a code fence, refers to some other code.
    CodeReferenceCommand,
    CodeReference,
    CodeExcerptCommand,
    // "… " in the document area, can designate a file, or a reference name.
    CodeExcerpt,
    // A line of documentation.
    DocLine,
    // A line of source code, inside code fences.
    CodeLine,
}

// Note that the "text" is always the entire line. These might have more info
// that is parsed later, e.g. the source code type in a code fence, like
// "```odin".
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

    // The token that shows the start of a Litmus command.
    command := "… "
    commandLen := len(command)
    inFence := false
    lineNum := 0
    for line in str.split_lines_iterator(&sample) {
        lineNum += 1
        if str.starts_with(line, "```") {
            inFence = !inFence
            if inFence {
                fmt.println(lineNum, "Fence start")
                token := Token{ kind = .FenceStart, line = lineNum, col = 1, length = len(line), text = line[0:] }
                append(&tokens, token)
            } else {
                fmt.println(lineNum, "Fence end")
                token := Token{ kind = .FenceEnd, line = lineNum, col = 1, length = len(line), text = line[0:] }
                append(&tokens, token)
            }

            continue
        }

        if str.starts_with(str.trim(line, " \t"), command) {
            index := str.index(line, command)
            if inFence {
                fmt.println(lineNum, "Code Reference = ", line)
                token := Token{ kind = .CodeReferenceCommand, line = lineNum, col = 1, length = index + commandLen, text = line[0:index + commandLen] }
                append(&tokens, token)
                refToken := Token{ kind = .CodeReference, line = lineNum, col = index + commandLen, length = len(line) - index - commandLen, text = line[index + commandLen:] }
                append(&tokens, refToken)
            } else {
                fmt.println(lineNum, "Code Excerpt = ", line)
                token := Token{ kind = .CodeExcerptCommand, line = lineNum, col = 1, length = index + commandLen, text = line[0:index + commandLen] }
                append(&tokens, token)
                refToken := Token{ kind = .CodeExcerpt, line = lineNum, col = index + commandLen, length = len(line) - index - 1, text = line[index + commandLen:] }
                append(&tokens, refToken)
            }
        } else {
            if inFence {
                fmt.println(lineNum, "Code line = ", line)
                token := Token{ kind = .CodeLine, line = lineNum, col = 1, length = len(line), text = line }
                append(&tokens, token)
            } else {
                fmt.println(lineNum, "Doc line = ", line)
                token := Token{ kind = .DocLine, line = lineNum, col = 1, length = len(line), text = line }
                append(&tokens, token)
            }
        }
    }

    for token in tokens {
        fmt.println(token)
    }

    fmt.println("\n---\n")

    fmt.println(sample)
}
