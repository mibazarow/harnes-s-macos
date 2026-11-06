import Foundation
import GRDB

/// Persists the style profile and folds new user messages into it.
actor StyleStore {
    private let database: AppDatabase
    private static let key = "style.profile"
    private static let minSamplesForCard = 20
    private static let cardCooldownMillis: Int64 = 6 * 60 * 60 * 1000

    private var cached: StyleProfile?

    init(database: AppDatabase) {
        self.database = database
    }

    func current() -> StyleProfile {
        if let cached { return cached }
        let profile = (try? load()) ?? StyleProfile()
        cached = profile
        return profile
    }

    func load() throws -> StyleProfile {
        try database.queue.read { db in
            guard let raw = try String.fetchOne(
                db,
                sql: "SELECT value FROM app_state WHERE key = ?",
                arguments: [Self.key]
            ), let data = raw.data(using: .utf8),
               let profile = try? JSONDecoder().decode(StyleProfile.self, from: data) else {
                return StyleProfile()
            }
            return profile
        }
    }

    func save(_ profile: StyleProfile) {
        cached = profile
        guard let data = try? JSONEncoder().encode(profile),
              let raw = String(data: data, encoding: .utf8) else { return }

        try? database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO app_state (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [Self.key, raw])
        }
    }

    /// Learns from one user message. Returns the updated profile.
    @discardableResult
    func observe(_ text: String, now: Date = .now, day: Int? = nil) -> StyleProfile {
        let profile = current()
        let profanity = ProfanityLexicon.scan(text)
        let signal = StyleAnalyzer.analyze(text, profanityHits: profile.profanityEnabled ? profanity.styleHits : 0)
        let epochDay = day ?? Int(now.timeIntervalSince1970 / 86_400)

        let updated = StyleReducer.apply(
            profile,
            signal: signal,
            now: Int64(now.timeIntervalSince1970 * 1000),
            day: epochDay
        )
        save(updated)
        return updated
    }

    func setMode(_ mode: StyleMode) {
        var profile = current()
        profile.mode = mode
        save(profile)
    }

    func setManualCard(_ card: String?) {
        var profile = current()
        let clean = card?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let clean, clean.count > 400 {
            profile.manualCard = String(clean.prefix(400))
        } else {
            profile.manualCard = clean?.isEmpty == true ? nil : clean
        }
        save(profile)
    }

    func setProfanityEnabled(_ enabled: Bool) {
        var profile = current()
        profile.profanityEnabled = enabled
        save(profile)
    }

    func setCard(_ card: String?) {
        var profile = current()
        profile.card = card
        profile.cardUpdatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        save(profile)
    }

    func reset() {
        save(StyleProfile())
    }

    /// Whether an LLM style-card pass is due. Mirrors Mecha's gates: enough
    /// samples, not neutral, outside the cooldown.
    func shouldExtractCard(now: Date = .now) -> Bool {
        let profile = current()
        if profile.mode == .neutral { return false }
        if profile.samples < Self.minSamplesForCard { return false }
        guard profile.card != nil else { return true }
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        return nowMillis - profile.cardUpdatedAt >= Self.cardCooldownMillis
    }

    /// Prompt block for the volatile tail. Empty when the style is neutral.
    func promptBlock() -> String {
        StyleBlockBuilder.render(current())
    }

    /// Human-readable summary for the settings screen.
    func summary() -> String {
        let profile = current()
        let active = StyleActivation.activeTraits(profile, limit: 5)
        var lines = [
            "Режим: \(profile.mode.title)",
            "Сообщений изучено: \(profile.samples)",
            "Активных черт: \(active.count)"
        ]
        for trait in active {
            let value = Int((trait.value * 100).rounded())
            lines.append("- \(trait.key.rawValue) · \(value)%")
        }
        if let card = profile.card, !card.isEmpty {
            lines.append("Тон: \(card)")
        }
        return lines.joined(separator: "\n")
    }
}