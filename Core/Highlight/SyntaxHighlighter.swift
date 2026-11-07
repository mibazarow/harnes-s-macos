import SwiftUI

enum CodeLanguage: String, Hashable, Sendable {
    case swift
    case javascript
    case typescript
    case python
    case json
    case bash
    case sql
    case html
    case css
    case yaml
    case diff
    case plain

    static func detect(_ raw: String?) -> CodeLanguage {
        guard let raw, !raw.isEmpty else { return .plain }
        let name = raw.lowercased()
        switch name {
        case "swift": return .swift
        case "js", "javascript", "jsx": return .javascript
        case "ts", "typescript", "tsx": return .typescript
        case "py", "python": return .python
        case "json": return .json
        case "sh", "bash", "zsh", "shell", "console": return .bash
        case "sql", "sqlite": return .sql
        case "html", "xml", "svg": return .html
        case "css", "scss": return .css
        case "yaml", "yml": return .yaml
        case "diff", "patch", "udiff": return .diff
        default: return .plain
        }
    }

    var keywords: [String] {
        switch self {
        case .diff:
            return []
        case .swift:
            return [
                "actor", "any", "as", "associatedtype", "async", "await", "break", "case",
                "catch", "class", "continue", "convenience", "defer", "deinit", "do", "else",
                "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for",
                "func", "guard", "if", "import", "in", "indirect", "init", "inout", "internal",
                "is", "isolated", "lazy", "let", "mutating", "nonisolated", "nil", "open",
                "operator", "override", "private", "protocol", "public", "repeat", "required",
                "rethrows", "return", "self", "Self", "some", "static", "struct", "subscript",
                "super", "switch", "throws", "throw", "true", "try", "typealias", "var", "where",
                "while", "willSet", "didSet", "get", "set", "consume", "borrowing", "sending"
            ]
        case .javascript, .typescript:
            return [
                "async", "await", "break", "case", "catch", "class", "const", "continue",
                "debugger", "default", "delete", "do", "else", "export", "extends", "false",
                "finally", "for", "from", "function", "get", "if", "import", "in", "instanceof",
                "interface", "let", "new", "null", "of", "return", "set", "static", "super",
                "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var",
                "void", "while", "yield", "enum", "implements", "private", "protected", "public",
                "readonly", "declare", "namespace", "as", "satisfies"
            ]
        case .python:
            return [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
                "del", "elif", "else", "except", "False", "finally", "for", "from", "global",
                "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass",
                "raise", "return", "True", "try", "while", "with", "yield", "match", "case"
            ]
        case .json:
            return ["true", "false", "null"]
        case .bash:
            return [
                "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
                "case", "esac", "function", "in", "select", "time", "export", "local",
                "readonly", "declare", "alias", "unalias", "unset", "source", "return",
                "exit", "break", "continue", "shift", "trap", "set", "eval", "exec"
            ]
        case .sql:
            return [
                "select", "from", "where", "insert", "into", "values", "update", "set",
                "delete", "create", "table", "alter", "drop", "index", "view", "join",
                "left", "right", "inner", "outer", "on", "group", "by", "order", "having",
                "limit", "offset", "as", "and", "or", "not", "null", "is", "in", "exists",
                "between", "like", "primary", "key", "foreign", "references", "unique",
                "default", "check", "constraint", "pragma", "begin", "commit", "rollback",
                "with", "union", "all", "distinct", "case", "when", "then", "else", "end"
            ]
        case .html, .css:
            return ["true", "false", "none", "inherit", "initial", "unset", "important"]
        case .yaml:
            return ["true", "false", "null", "yes", "no", "on", "off"]
        case .plain:
            return []
        }
    }

    var commentPattern: String? {
        switch self {
        case .swift, .javascript, .typescript, .css:
            return #"//[^\n]*|/\*[\s\S]*?\*/"#
        case .python, .bash, .yaml:
            return #"#[^\n]*"#
        case .sql:
            return #"--[^\n]*|/\*[\s\S]*?\*/"#
        case .html:
            return #"<!--[\s\S]*?-->"#
        case .json, .plain, .diff:
            return nil
        }
    }

    var stringPattern: String? {
        switch self {
        case .json:
            return #""(?:\\.|[^"\\\n])*""#
        case .python:
            return #"'''[\s\S]*?'''|"""[\s\S]*?"""|'(?:\\.|[^'\\\n])*'|"(?:\\.|[^"\\\n])*""#
        case .javascript, .typescript:
            return #"`(?:\\.|[^`\\])*`|'(?:\\.|[^'\\\n])*'|"(?:\\.|[^"\\\n])*""#
        case .html:
            return #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#
        case .plain, .diff:
            return nil
        default:
            return #"'(?:\\.|[^'\\\n])*'|"(?:\\.|[^"\\\n])*""#
        }
    }
}

struct SyntaxHighlighter {
    let language: CodeLanguage
    let palette: Palette
    let fontSize: CGFloat

    func highlight(_ code: String) -> AttributedString {
        let baseFont = AppFont.mono(fontSize)
        var plain = AttributedString(code)
        plain.font = baseFont
        plain.foregroundColor = palette.assistantText

        // Diffs are colored by line, not by token: `-`/`+` only mean anything at the
        // start of a line, and a token pass would paint the code inside them anyway.
        if language == .diff { return highlightDiff(code, font: baseFont) }

        guard let regex = compiledRegex() else { return plain }

        var result = AttributedString()
        var cursor = code.startIndex
        let full = code as NSString
        let matches = regex.matches(in: code, range: NSRange(location: 0, length: full.length))

        for match in matches {
            guard let matchRange = Range(match.range, in: code) else { continue }
            if cursor < matchRange.lowerBound {
                var chunk = AttributedString(String(code[cursor..<matchRange.lowerBound]))
                chunk.font = baseFont
                chunk.foregroundColor = palette.assistantText
                result.append(chunk)
            }

            var token = AttributedString(String(code[matchRange]))
            token.font = baseFont
            token.foregroundColor = color(for: match)
            result.append(token)
            cursor = matchRange.upperBound
        }

        if cursor < code.endIndex {
            var tail = AttributedString(String(code[cursor...]))
            tail.font = baseFont
            tail.foregroundColor = palette.assistantText
            result.append(tail)
        }

        return result
    }

    private func highlightDiff(_ code: String, font: Font) -> AttributedString {
        var result = AttributedString()
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let ending = index == lines.count - 1 ? "" : "\n"
            var chunk = AttributedString(String(line) + ending)
            chunk.font = font
            let text = String(line)
            if text.hasPrefix("+++") || text.hasPrefix("---") {
                chunk.foregroundColor = palette.type
            } else if text.hasPrefix("+") {
                chunk.foregroundColor = palette.accent
            } else if text.hasPrefix("-") {
                chunk.foregroundColor = palette.dim
            } else if text.hasPrefix("@@") {
                chunk.foregroundColor = palette.keyword
            } else {
                chunk.foregroundColor = palette.assistantText
            }
            result.append(chunk)
        }
        return result
    }

    private func color(for match: NSTextCheckingResult) -> Color {
        func has(_ name: String) -> Bool {
            match.range(withName: name).location != NSNotFound
        }
        if has("comment") { return palette.comment }
        if has("string") { return palette.string }
        if has("number") { return palette.number }
        if has("keyword") { return palette.keyword }
        if has("type") { return palette.type }
        if has("call") { return palette.call }
        return palette.assistantText
    }

    private func compiledRegex() -> NSRegularExpression? {
        var parts: [String] = []

        if let comment = language.commentPattern {
            parts.append("(?<comment>\(comment))")
        }
        if let string = language.stringPattern {
            parts.append("(?<string>\(string))")
        }
        parts.append(#"(?<number>\b\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?\b)"#)

        let keywords = language.keywords
        if !keywords.isEmpty {
            let alternation = keywords
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            if language == .sql {
                parts.append("(?<keyword>(?i:\\b(?:\(alternation))\\b))")
            } else {
                parts.append("(?<keyword>\\b(?:\(alternation))\\b)")
            }
        }

        parts.append(#"(?<type>\b[A-Z][A-Za-z0-9_]{1,}\b)"#)
        parts.append(#"(?<call>\b[a-zA-Z_][A-Za-z0-9_]*(?=\s*\())"#)

        let pattern = parts.joined(separator: "|")
        return try? NSRegularExpression(pattern: pattern, options: [])
    }
}

/// Memoizes highlighted code. A transcript holds the same code blocks for a long time
/// and re-renders them on every layout pass, so the regex pass is worth caching by
/// content. Small LRU: code blocks are the largest things in a message.
@MainActor
enum HighlightCache {
    private struct Key: Hashable {
        let language: CodeLanguage
        let fontSize: CGFloat
        let code: String
    }

    private static var storage: [Key: AttributedString] = [:]
    private static var order: [Key] = []
    private static let limit = 120

    static func render(
        language: CodeLanguage,
        palette: Palette,
        fontSize: CGFloat,
        code: String
    ) -> AttributedString {
        let key = Key(language: language, fontSize: fontSize, code: code)
        if let hit = storage[key] { return hit }

        let value = SyntaxHighlighter(language: language, palette: palette, fontSize: fontSize)
            .highlight(code)
        storage[key] = value
        order.append(key)

        if order.count > limit {
            let dropped = order.removeFirst()
            storage[dropped] = nil
        }
        return value
    }
}
