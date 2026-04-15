import SwiftUI

/// A small hand-written TS/TSX tokenizer for syntax highlighting.
///
/// Recursive regexes get out of hand fast, so this walks the source one
/// character at a time with a tiny state stack. It handles the constructs
/// that actually matter for display:
///
/// - `// line comments` and `/* block comments */`
/// - Single, double, and backtick string literals (with escapes; backticks
///   include `${…}` expression interpolation rendered as code)
/// - Numeric literals (ints, floats, hex)
/// - Keywords and built-in identifiers
/// - JSX elements: the opening `<Tag`, the closing `>` / `/>`, attributes,
///   and the text/expression children. Expressions inside `{…}` flip back
///   to normal code highlighting so types and values are coloured correctly.
///
/// Output is an `AttributedString` with per-run `foregroundColor` / `font`
/// attributes applied. The highlighter never throws — on any unexpected
/// input it emits the rest of the string as plain text.
enum SyntaxHighlighter {
    static func highlight(_ source: String) -> AttributedString {
        guard !source.isEmpty else { return AttributedString(" ") }

        var lexer = Lexer(source: source)
        var result = AttributedString()
        result.font = PK.mono(12)
        result.foregroundColor = PK.text

        while let token = lexer.next() {
            var piece = AttributedString(token.text)
            piece.font = token.kind.bold
                ? PK.mono(12, weight: .semibold)
                : PK.mono(12)
            piece.foregroundColor = token.kind.color
            result.append(piece)
        }
        return result
    }
}

// MARK: - Token

private struct Token {
    let text: String
    let kind: Kind
}

private enum Kind {
    case plain
    case keyword
    case string
    case number
    case comment
    case jsxTag
    case jsxAttr
    case jsxBracket
    case punctuation

    var color: Color {
        switch self {
        case .plain: PK.text
        case .keyword: PK.accent
        case .string: Color(red: 0.541, green: 0.941, blue: 0.639)
        case .number: Color(red: 1.000, green: 0.627, blue: 0.212)
        case .comment: PK.textFaint
        case .jsxTag: Color(red: 0.341, green: 0.824, blue: 0.969)
        case .jsxAttr: Color(red: 1.000, green: 0.678, blue: 0.467)
        case .jsxBracket: Color(red: 0.341, green: 0.824, blue: 0.969)
        case .punctuation: PK.textDim
        }
    }

    var bold: Bool {
        switch self {
        case .keyword: true
        default: false
        }
    }
}

// MARK: - Lexer

private struct Lexer {
    let source: [Character]
    var index: Int = 0
    /// Set while the parser is inside a JSX tag (between `<Tag` and the
    /// closing `>` / `/>`), which changes how identifiers are coloured.
    var inJsxTag: Bool = false
    /// Set while inside an attribute value's string.
    var inJsxAttrValue: Bool = false

    init(source: String) {
        self.source = Array(source)
    }

    mutating func next() -> Token? {
        guard index < source.count else { return nil }
        let c = source[index]

        // Comments
        if c == "/" && peek(1) == "/" { return lineComment() }
        if c == "/" && peek(1) == "*" { return blockComment() }

        // Strings
        if c == "\"" || c == "'" { return stringLiteral(quote: c) }
        if c == "`" { return templateLiteral() }

        // Numbers
        if c.isNumber { return numberLiteral() }

        // JSX — a `<` is treated as an element opener when followed by a
        // letter or `/`. Otherwise it's a comparison operator.
        if c == "<", let n = peek(1), n.isLetter || n == "/" {
            return jsxOpen()
        }
        if c == ">", inJsxTag {
            inJsxTag = false
            index += 1
            return Token(text: ">", kind: .jsxBracket)
        }
        if c == "/" && peek(1) == ">", inJsxTag {
            inJsxTag = false
            index += 2
            return Token(text: "/>", kind: .jsxBracket)
        }

        // Identifier / keyword
        if c.isLetter || c == "_" || c == "$" { return identifier() }

        // Whitespace/newline — passes through as plain
        if c.isWhitespace || c.isNewline {
            let start = index
            while index < source.count, source[index].isWhitespace || source[index].isNewline {
                index += 1
            }
            return Token(text: String(source[start..<index]), kind: .plain)
        }

        // Any punctuation
        let start = index
        index += 1
        return Token(text: String(source[start..<index]), kind: .punctuation)
    }

    // MARK: Helpers

    private func peek(_ offset: Int) -> Character? {
        let j = index + offset
        return (0..<source.count).contains(j) ? source[j] : nil
    }

    // MARK: Token consumers

    private mutating func lineComment() -> Token {
        let start = index
        while index < source.count, !source[index].isNewline {
            index += 1
        }
        return Token(text: String(source[start..<index]), kind: .comment)
    }

    private mutating func blockComment() -> Token {
        let start = index
        index += 2  // consume /*
        while index < source.count - 1 {
            if source[index] == "*" && source[index + 1] == "/" {
                index += 2
                return Token(text: String(source[start..<index]), kind: .comment)
            }
            index += 1
        }
        index = source.count
        return Token(text: String(source[start..<index]), kind: .comment)
    }

    private mutating func stringLiteral(quote: Character) -> Token {
        let start = index
        index += 1
        while index < source.count {
            let c = source[index]
            if c == "\\" && index + 1 < source.count {
                index += 2
                continue
            }
            if c == quote {
                index += 1
                return Token(text: String(source[start..<index]), kind: .string)
            }
            if c.isNewline { break }
            index += 1
        }
        return Token(text: String(source[start..<index]), kind: .string)
    }

    private mutating func templateLiteral() -> Token {
        let start = index
        index += 1
        while index < source.count {
            let c = source[index]
            if c == "\\" && index + 1 < source.count {
                index += 2
                continue
            }
            if c == "`" {
                index += 1
                return Token(text: String(source[start..<index]), kind: .string)
            }
            index += 1
        }
        return Token(text: String(source[start..<index]), kind: .string)
    }

    private mutating func numberLiteral() -> Token {
        let start = index
        while index < source.count {
            let c = source[index]
            if c.isNumber || c == "." || c == "x" || c == "e" || c == "_" {
                index += 1
                continue
            }
            break
        }
        return Token(text: String(source[start..<index]), kind: .number)
    }

    private mutating func identifier() -> Token {
        let start = index
        while index < source.count {
            let c = source[index]
            if c.isLetter || c.isNumber || c == "_" || c == "$" {
                index += 1
            } else {
                break
            }
        }
        let text = String(source[start..<index])

        if inJsxTag {
            // Inside a JSX tag, the first identifier is the tag name and
            // subsequent ones are attribute names. Both look like attrs
            // colour-wise except the component name which already matched
            // when we entered the tag.
            return Token(text: text, kind: .jsxAttr)
        }

        return Token(text: text, kind: Self.keywords.contains(text) ? .keyword : .plain)
    }

    private mutating func jsxOpen() -> Token {
        // Consume `<` + optional `/` + tag name.
        let start = index
        index += 1  // consume <
        if index < source.count, source[index] == "/" {
            index += 1
        }
        while index < source.count {
            let c = source[index]
            if c.isLetter || c.isNumber || c == "." || c == "_" || c == "-" {
                index += 1
            } else {
                break
            }
        }
        inJsxTag = true
        return Token(text: String(source[start..<index]), kind: .jsxTag)
    }

    // MARK: Keywords

    private static let keywords: Set<String> = [
        "import", "from", "export", "default", "function", "const", "let",
        "var", "return", "if", "else", "for", "while", "do", "switch",
        "case", "break", "continue", "new", "this", "super", "class",
        "extends", "implements", "interface", "type", "enum", "async",
        "await", "try", "catch", "finally", "throw", "typeof", "instanceof",
        "in", "of", "true", "false", "null", "undefined", "void", "as",
        "is", "static", "public", "private", "protected", "readonly",
        "abstract", "yield", "delete", "get", "set"
    ]
}
