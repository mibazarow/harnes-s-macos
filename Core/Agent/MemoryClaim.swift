import Foundation

/// R33.1: a sentence that claims a result is not a fact until something confirms it.
///
/// "Released", "deployed", "works", "checked" written in a chat is a claim about the
/// world, and memory used to store it exactly like a user preference. Record #94
/// ("the release is already published") passed as a fact while nothing had been
/// published. Such a record is still saved — the user did say it — but with
/// `importance = 0`, so the prompt skips it and garbage collection may collect it, and
/// only an explicit command turns it into a fact.
enum MemoryClaim {
    /// Words that assert an outcome. Russian forms are matched as substrings, so
    /// "выложен", "выложенa", "выложено" all hit the same stem.
    static let resultStems: [String] = [
        "выложен", "опубликован", "задеплоен", "залит", "работает", "проверен",
        "готово", "готов", "сделано", "сделан", "выпущен", "отправлен",
        "released", "deployed", "published", "verified", "already works", "is done"
    ]

    enum Verdict: Equatable, Sendable {
        case ok
        /// A result claim without a command that proves it.
        case unverified
    }

    static func check(text: String, area: String, verifiedCommand: String?) -> Verdict {
        // Corrections are the user's own rule, not a claim about the world.
        guard area != "lessons" else { return .ok }
        if let verifiedCommand,
           !verifiedCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .ok
        }
        let lower = text.lowercased()
        return resultStems.contains { lower.contains($0) } ? .unverified : .ok
    }

    /// The line shown instead of "Запомнил".
    static func note(for command: String?) -> String {
        if let command, !command.isEmpty {
            return "Записал как проверенное: `\(String(command.prefix(120)))`."
        }
        return "Записал, но с пометкой «не проверено»: это утверждение о результате без "
            + "команды, которая его подтверждает. Такая запись не идёт в промпт и может "
            + "быть собрана GC. Передай `verified_command`, когда проверишь."
    }

    static let unverifiedTag = "unverified"
}
