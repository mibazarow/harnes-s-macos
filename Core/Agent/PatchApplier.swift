import Foundation

/// Applies a unified diff without shelling out. Supports the subset the agent
/// actually emits: `@@ -a,b +c,d @@` hunks with context, add and remove lines.
struct PatchApplier: Sendable {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func apply(_ patch: String, to original: String) throws -> String {
        let originalLines = original.components(separatedBy: "\n")
        var result: [String] = []
        var cursor = 0

        let hunks = parseHunks(patch)
        guard !hunks.isEmpty else {
            throw Failure(message: "В патче нет ни одного хунка @@.")
        }

        for hunk in hunks {
            let start = max(hunk.oldStart - 1, 0)
            guard start >= cursor, start <= originalLines.count else {
                throw Failure(message: "Хунк @@ -\(hunk.oldStart) выходит за пределы файла (\(originalLines.count) строк).")
            }

            while cursor < start {
                result.append(originalLines[cursor])
                cursor += 1
            }

            for line in hunk.lines {
                switch line.kind {
                case .context:
                    guard cursor < originalLines.count else {
                        throw Failure(message: "Контекст хунка закончился раньше файла.")
                    }
                    guard originalLines[cursor] == line.text else {
                        throw Failure(message: "Не совпадает контекст на строке \(cursor + 1):\n  ожидалось: \(line.text)\n  в файле:   \(originalLines[cursor])")
                    }
                    result.append(originalLines[cursor])
                    cursor += 1
                case .remove:
                    guard cursor < originalLines.count else {
                        throw Failure(message: "Удаление за пределами файла на строке \(cursor + 1).")
                    }
                    guard originalLines[cursor] == line.text else {
                        throw Failure(message: "Не совпадает удаляемая строка \(cursor + 1):\n  ожидалось: \(line.text)\n  в файле:   \(originalLines[cursor])")
                    }
                    cursor += 1
                case .add:
                    result.append(line.text)
                }
            }
        }

        while cursor < originalLines.count {
            result.append(originalLines[cursor])
            cursor += 1
        }

        return result.joined(separator: "\n")
    }

    private enum Kind { case context, add, remove }

    private struct Line {
        let kind: Kind
        let text: String
    }

    private struct Hunk {
        let oldStart: Int
        var lines: [Line]
    }

    private static func parseHunks(_ patch: String) -> [Hunk] {
        var hunks: [Hunk] = []
        var current: Hunk?

        for raw in patch.components(separatedBy: "\n") {
            if raw.hasPrefix("@@") {
                if let current { hunks.append(current) }
                let start = parseOldStart(raw)
                current = Hunk(oldStart: start, lines: [])
                continue
            }

            if raw.hasPrefix("---") || raw.hasPrefix("+++") || raw.hasPrefix("diff ") || raw.hasPrefix("index ") {
                continue
            }

            guard current != nil else { continue }

            if raw.hasPrefix("+") {
                current?.lines.append(Line(kind: .add, text: String(raw.dropFirst())))
            } else if raw.hasPrefix("-") {
                current?.lines.append(Line(kind: .remove, text: String(raw.dropFirst())))
            } else if raw.hasPrefix(" ") {
                current?.lines.append(Line(kind: .context, text: String(raw.dropFirst())))
            } else if raw.isEmpty {
                continue
            } else {
                current?.lines.append(Line(kind: .context, text: raw))
            }
        }

        if let current { hunks.append(current) }
        return hunks
    }

    private static func parseOldStart(_ header: String) -> Int {
        // @@ -12,7 +12,9 @@
        guard let minus = header.range(of: "-") else { return 1 }
        let rest = header[minus.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        return Int(digits) ?? 1
    }
}