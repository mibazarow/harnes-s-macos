import Foundation

struct SkillManifest: Sendable, Equatable {
    var name: String
    var summary: String
    var version: String?
    var triggers: [String]
    var allowedTools: [String]
    var body: String

    static func parse(_ text: String, fallbackName: String) throws -> SkillManifest {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var metadata: [String: String] = [:]
        var listValues: [String: [String]] = [:]
        var bodyLines: [String] = lines

        if let first = lines.first?.trimmingCharacters(in: .whitespaces),
           first == "---",
           let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            let frontmatter = Array(lines[1..<closing])
            bodyLines = Array(lines[(closing + 1)...])
            parseFrontmatter(frontmatter, into: &metadata, lists: &listValues)
        } else {
            bodyLines = lines
        }

        let name = metadata["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallbackName
        guard !name.isEmpty else {
            throw ConfigurationError.invalidManifest("не указано имя скилла")
        }

        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw ConfigurationError.invalidManifest("пустое тело скилла")
        }

        return SkillManifest(
            name: name,
            summary: metadata["description"] ?? metadata["summary"] ?? "",
            version: metadata["version"],
            triggers: listValues["triggers"] ?? [],
            allowedTools: listValues["allowed-tools"] ?? listValues["allowed_tools"] ?? [],
            body: body
        )
    }

    private static func parseFrontmatter(
        _ lines: [String],
        into metadata: inout [String: String],
        lists: inout [String: [String]]
    ) {
        var currentListKey: String?
        var blockKey: String?
        var blockLines: [String] = []

        func flushBlock() {
            guard let key = blockKey else { return }
            let joined = blockLines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !joined.isEmpty {
                metadata[key] = joined
            }
            blockKey = nil
            blockLines = []
        }

        for rawLine in lines {
            if blockKey != nil,
               rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t") || rawLine.isEmpty {
                blockLines.append(rawLine)
                continue
            }
            flushBlock()

            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("- ") {
                guard let key = currentListKey else { continue }
                lists[key, default: []].append(unquote(String(trimmed.dropFirst(2))))
                continue
            }

            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            currentListKey = nil

            if value == ">" || value == "|" || value == ">-" || value == "|-" {
                blockKey = key
                blockLines = []
                continue
            }

            if value.isEmpty {
                currentListKey = key
                continue
            }

            if value.hasPrefix("["), value.hasSuffix("]") {
                let inner = String(value.dropFirst().dropLast())
                let items = inner
                    .split(separator: ",")
                    .map { unquote(String($0).trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty }
                lists[key] = items
            } else {
                value = unquote(value)
                metadata[key] = value
            }
        }

        flushBlock()
    }

    private static func unquote(_ value: String) -> String {
        var value = value
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}

enum SkillScope: String, Sendable {
    case builtin
    case user
}

struct SkillRecord: Identifiable, Sendable, Equatable {
    let name: String
    let summary: String
    let scope: SkillScope
    let directory: URL
    let enabled: Bool

    var id: String { "\(scope.rawValue):\(name)" }
}