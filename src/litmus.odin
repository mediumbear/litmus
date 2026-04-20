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

    ## A named export with source file - only applies to this command.
        > ... the imports :file: doit.odin
        > ```
        > import something
        > ```

    ## Doc excerpt - these don't go into the source code - this is code that is documentation. 
        > ... :doc:
*/

// Most col = 1 (1 indexed). But there can be whitespace in front of a code excerpt for tabbing. Important when tangling.
ScannerTokenType :: enum {
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
ScannerToken :: struct {
    type: ScannerTokenType,
    line, col, length: int,
    text: string,
}

ASTNodeType :: enum {
    // A bunch of document lines
    DocBlock,
    // The fenced code
    CodeExerpt,
    // A reference to some code
    CodeRef,
}

AST :: struct {
    type: ASTNodeType
}

CodeLine :: struct {
}

CodeExerpt :: struct {
    using base: AST,
    fenceStart: ScannerToken,
    fenceEnd: ScannerToken,
    // Lines of code or code references
    codeLines: []ScannerToken,
}

DocBlock :: struct {
    using base: AST,
    docLines: []ScannerToken
}

// HERE - not sure I fully understand things - I need to go back to paper some more and check the results of the scanne.
// Get some big picture stuff going, diagrams. It is not fully clear how this work and also how 2 way editing will work.
CodeRef :: struct {
}

CodeExerpt :: struct {
}

main :: proc() {
    fmt.println(sample)
    tokens, error := scan(&sample)
    if error != "" {
        fmt.eprintln("Error scanning input file")
        return
    }
    defer delete(tokens)

    ast := parse(tokens[:])

    for token in tokens {
        fmt.println(token.type)
    }
}

scan :: proc(text: ^string) -> ( [dynamic]ScannerToken, string ) {
    fmt.println(sample)
    // Need to emit tokens:
    // fenceStart - the first ``` (markdown) or ----\n (asciidoc)
    // fenceArgs - anything after the first ```, normally means the programming language
    // fenceEnd - the "closing" ``` or ----\n
    // excerpt - a `…` in a doc area
    // reference - a `…` in a code fence
    // docLine - a line of text outside of fences
    // codeLine - a line of text inside of fences

    // exerptIdent - the text following `…` until some parameters are found
    // paramName - an identifier surrounded by `:` e.g. :file:
    // paramValue - the text after the paramName

    // With the above we will create an AST. Lines will become code and doc chunks. code chunks become a code block.
    // This should be enough!

    tokens: [dynamic]ScannerToken

    // The token that shows the start of a Litmus command.
    command := "… "
    fence := "----\n"
    commandLen := len(command)
    inFence := false
    lineNum := 0
    for line in str.split_lines_iterator(text) {
        lineNum += 1
        if str.starts_with(line, fence) {
            inFence = !inFence
            if inFence {
                fmt.println(lineNum, "Fence start")
                token := ScannerToken{ type = .FenceStart, line = lineNum, col = 1, length = len(line), text = line[0:] }
                append(&tokens, token)
            } else {
                fmt.println(lineNum, "Fence end")
                trimmed := str.trim_space(line)
                if len(trimmed) != 3 {
                    return tokens, "Ending fence should only be the ``` characters, surrounding whitespace is ok, but nothing else"
                }
                token := ScannerToken{ type = .FenceEnd, line = lineNum, col = 1, length = len(line), text = line[0:] }
                append(&tokens, token)
            }

            continue
        }

        if str.starts_with(str.trim(line, " \t"), command) {
            index := str.index(line, command)
            if inFence {
                fmt.println(lineNum, "Code Reference = ", line)
                token := ScannerToken{ type = .CodeReferenceCommand, line = lineNum, col = 1, length = index + commandLen, text = line[0:index + commandLen] }
                append(&tokens, token)
                refToken := ScannerToken{ type = .CodeReference, line = lineNum, col = index + commandLen, length = len(line) - index - commandLen, text = line[index + commandLen:] }
                append(&tokens, refToken)
            } else {
                fmt.println(lineNum, "Code Excerpt = ", line)
                token := ScannerToken{ type = .CodeExcerptCommand, line = lineNum, col = 1, length = index + commandLen, text = line[0:index + commandLen] }
                append(&tokens, token)
                refToken := ScannerToken{ type = .CodeExcerpt, line = lineNum, col = index + commandLen, length = len(line) - index - 1, text = line[index + commandLen:] }
                append(&tokens, refToken)
            }
        } else {
            if inFence {
                fmt.println(lineNum, "Code line = ", line)
                token := ScannerToken{ type = .CodeLine, line = lineNum, col = 1, length = len(line), text = line }
                append(&tokens, token)
            } else {
                fmt.println(lineNum, "Doc line = ", line)
                token := ScannerToken{ type = .DocLine, line = lineNum, col = 1, length = len(line), text = line }
                append(&tokens, token)
            }
        }
    }

    for token in tokens {
        fmt.println(token)
    }

    fmt.println("\n---\n")

    fmt.println(sample)

    return tokens, "" 
}

parse :: proc([]ScannerToken) -> AST {
    return AST{}
}

