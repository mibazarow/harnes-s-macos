import CryptoKit
import Foundation

/// R30.4: procedures the agent writes for itself, kept apart from the human-authored
/// skills. A learned skill is a file with a YAML header; the body hash in the header is
/// what tells "written by the tool" from "edited by hand".
struct LearnedSkill: Equatable, Sendable {
    let name: String
    let description: String
    let created: String
    let updated: String
    let source: String
    let bodyHash: String
    let body: String

    static let maxBody = 6_000
    static let maxDescription = 200
    static let maxSkills = 50

    var fileName: String { "\(name).md" }

    func rendered() -> String {
        """
        ---
        name: \(name)
        description: \(description)
        created: \(created)
        updated: \(updated)
        source: \(source)
        body_hash: \(bodyHash)
        ---
        \(body)
        """
    }

    static func parse(_ text: String) -> LearnedSkill? {
        guard text.hasPrefix("---\n") else { return nil }
        guard let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex)
        else { return nil }
        let header = String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound])
        let body = String(text[end.upperBound...])
        var fields: [String: String] = [:]
        for line in header.split(separator: "\n") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard let name = fields["name"], let description = fields["description"],
              let created = fields["created"], let updated = fields["updated"],
              let source = fields["source"], let hash = fields["body_hash"] else { return nil }
        return LearnedSkill(
            name: name, description: description, created: created, updated: updated,
            source: source, bodyHash: hash, body: body
        )
    }
}

/// R30.4: the sanitiser runs before anything reaches disk, in a fixed order: known
/// secrets first, then hard refusals, then masking. A refusal never writes a partial file.
enum LearnedSkillSanitizer {
    enum Verdict: Equatable {
        case ok(String)
        case refused(String)
    }

    /// `secrets` are the real values; their prefixes are masked too, so a truncated key
    /// does not survive. A value shorter than 8 characters is skipped: masking every
    /// "yes" would destroy ordinary text.
    static func clean(_ body: String, secrets: [String]) -> Verdict {
        var text = body
        for secret in secrets where secret.count >= 8 {
            text = text.replacingOccurrences(of: secret, with: "<secret>")
            let prefix = String(secret.prefix(8))
            text = text.replacingOccurrences(of: prefix, with: "<secret>")
        }

        if text.range(of: #"\b\d{13,19}\b"#, options: .regularExpression) != nil {
            return .refused("Похоже на номер карты (13–19 цифр подряд). Навык не сохранён.")
        }
        if text.range(
            of: #"(?i)(api[_-]?key|token|password)\s*[:=]"#, options: .regularExpression
        ) != nil {
            return .refused("В теле есть строка вида key/token/password =. Секреты в навык не пишутся.")
        }
        if text.range(of: #"https?://[^ ]*:[^ ]*@"#, options: .regularExpression) != nil {
            return .refused("Ссылка содержит логин и пароль в URL. Навык не сохранён.")
        }

        text = text.replacingOccurrences(
            of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            with: "<email>", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\+?\d[\d ()-]{6,}\d"#, with: "<number>", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\b\d{6,}\b"#, with: "<number>", options: .regularExpression
        )
        return .ok(text)
    }
}

/// Files in `config/learned-skills`. One skill per file, never rewritten silently.
enum LearnedSkillStore {
    private final class Lock: @unchecked Sendable {
        let lock = NSLock()
        var override: URL?
    }
    private static let state = Lock()

    static var directory: URL {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.override ?? AppPaths.configDirectory.appendingPathComponent("learned-skills")
    }

    static func setDirectoryOverride(_ url: URL?) {
        state.lock.lock(); state.override = url; state.lock.unlock()
    }

    static func names() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }
            .sorted() ?? []
    }

    static func read(_ name: String) -> LearnedSkill? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(name).md")),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return LearnedSkill.parse(text)
    }

    static func list() -> [LearnedSkill] {
        names().compactMap(read)
    }

    static func bodyHash(_ body: String) -> String {
        let digest = SHA256.hash(data: Data(body.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    enum SaveError: Error, LocalizedError {
        case tooMany(Int)
        case tooLong(String)
        case editedByHand(String)
        case io(String)

        var errorDescription: String? {
            switch self {
            case .tooMany(let count):
                return "Уже \(count) навыков (лимит \(LearnedSkill.maxSkills)). Удали старые."
            case .tooLong(let what): return "\(what) длиннее лимита."
            case .editedByHand(let name):
                return "Навык «\(name)» правили руками (хеш тела не совпадает). "
                    + "Перезапись запрещена: попроси пользователя."
            case .io(let detail): return detail
            }
        }
    }

    static func save(_ skill: LearnedSkill) throws {
        let existing = names()
        if existing.contains(skill.name) {
            if let current = read(skill.name), current.bodyHash != bodyHash(current.body) {
                throw SaveError.editedByHand(skill.name)
            }
        } else if existing.count >= LearnedSkill.maxSkills {
            throw SaveError.tooMany(existing.count)
        }
        guard skill.body.count <= LearnedSkill.maxBody else {
            throw SaveError.tooLong("Тело")
        }
        guard skill.description.count <= LearnedSkill.maxDescription else {
            throw SaveError.tooLong("Описание")
        }
        do {
            try AppPaths.ensureDirectory(directory)
            try skill.rendered().write(
                to: directory.appendingPathComponent(skill.fileName),
                atomically: true, encoding: .utf8
            )
        } catch {
            throw SaveError.io(error.localizedDescription)
        }
    }
}
