import Foundation

/// Renders the learned style into a compact prompt block.
/// Style changes FORM only; facts, tools and safety always win.
enum StyleBlockBuilder {
    /// Hard cap of the whole block (~90 tokens).
    static let maxBlockChars = 360

    private static let header = "СТИЛЬ (только форма; факты и безопасность выше):"
    private static let footer = "Другим людям пиши нейтрально; стиль не переноси в письма, коммиты и документы."
    private static let profanityLimits =
        "Мат: максимум 1 слово за ответ, только как усилитель, не в адрес людей; без оскорблений и агрессии."

    static func render(_ profile: StyleProfile, limit: Int = maxBlockChars) -> String {
        guard limit > 0 else { return "" }
        switch profile.mode {
        case .neutral:
            return ""
        case .manual:
            return renderManual(profile.manualCard, limit: limit)
        case .auto:
            return renderAuto(profile, limit: limit)
        }
    }

    private static func renderManual(_ card: String?, limit: Int) -> String {
        guard let clean = card?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty else {
            return ""
        }
        guard !ProfanityLexicon.containsHardLanguage(clean) else { return "" }
        return fit(optional: [clean], mandatory: [footer], limit: limit)
    }

    private static func renderAuto(_ profile: StyleProfile, limit: Int) -> String {
        var active = StyleActivation.activeTraits(profile, limit: 4)
        if !profile.profanityEnabled {
            active.removeAll { $0.key == .profanity }
        }
        active = Array(active.prefix(3))

        let card = profile.card?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            .flatMap { ProfanityLexicon.containsHardLanguage($0) ? nil : $0 }

        guard !active.isEmpty || card != nil else { return "" }

        var optional = active.compactMap(line)
        if let card { optional.append("Тон: \(card)") }

        var mandatory = [footer]
        if active.contains(where: { $0.key == .profanity }) {
            mandatory.append(profanityLimits)
        }

        return fit(optional: optional, mandatory: mandatory, limit: limit)
    }

    private static func line(_ trait: StyleTrait) -> String? {
        switch trait.key {
        case .address:
            switch StyleActivation.addressForm(trait) {
            case .ty: return "Обращайся на «ты», по-дружески, без официоза."
            case .vy: return "Обращайся на «вы», вежливо и без панибратства."
            }
        case .brevity:
            // Length is governed by sampling temperature, not by prompt instructions.
            return nil
        case .profanity:
            return "Пользователь сам крепко выражается — можно изредка и к месту."
        case .slang:
            return "Уместен лёгкий сленг, по-дружески, без переигрывания."
        case .emoji:
            return "Эмодзи — изредка и к месту."
        case .punctuation:
            return "Можно расслабленно: строчные буквы, без педантичной пунктуации."
        case .directness:
            return "Сразу по делу, без лишних предисловий."
        case .humor:
            return "Уместна лёгкая ирония, но никогда не над пользователем."
        }
    }

    /// Mandatory safety lines are reserved out of the cap first, so a long card
    /// can never push "no insults" out of the prompt.
    private static func fit(optional: [String], mandatory: [String], limit: Int) -> String {
        let mandatoryText = mandatory.map { "\n- \($0)" }.joined()
        var result = header
        let optionalBudget = max(limit - mandatoryText.count, 0)

        for line in optional {
            let candidate = "\n- \(line)"
            if result.count + candidate.count > optionalBudget { break }
            result += candidate
        }

        result += mandatoryText
        return result.count > limit ? String(result.prefix(limit)) : result
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

/// Minimal Russian profanity guard: decides whether learned language may be mirrored.
/// Counts mild swearing, never mirrors insults or slurs.
enum ProfanityLexicon {
    struct Signal: Sendable {
        var mild = false
        var insult = false
        var slur = false

        var isHostile: Bool { insult || slur }
        var styleHits: Int { mild && !isHostile ? 1 : 0 }
    }

    private static let falsePositives: Set<String> = [
        "хулиган", "хулиганы", "хулигана", "хулиганка", "хулиганить", "хулиганство",
        "бляха", "бляхи", "бляшка", "бляшки"
    ]

    private static let lookalikes: [Character: Character] = [
        "a": "а", "b": "б", "c": "с", "e": "е", "h": "н", "k": "к", "m": "м",
        "o": "о", "p": "р", "t": "т", "x": "х", "y": "у",
        "0": "о", "1": "и", "3": "з", "4": "ч", "6": "б"
    ]

    private static let mildRoots = [
        "хуй", "хуя", "хуе", "хуё", "хуи", "хуйн",
        "нахуй", "похуй", "нихуя", "охуе", "охуи",
        "пизд", "бля", "блят", "блядь",
        "ебат", "ебал", "ебуч", "ебет", "ебн"
    ]

    private static let insultRoots = [
        "дурак", "дура ", "идиот", "дебил", "кретин", "мразь", "ублюд", "тварь",
        "скотина", "придурок", "мудак", "козел", "козёл"
    ]

    private static let slurRoots = [
        "пидор", "пидар", "педик", "гомосек", "ниггер", "чурка", "хач ", "жид"
    ]

    private static let tokenRegex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")

    static func scan(_ text: String) -> Signal {
        var signal = Signal()
        let normalized = normalize(text)
        let range = NSRange(normalized.startIndex..., in: normalized)
        let tokens = tokenRegex.matches(in: normalized, range: range).compactMap { match in
            Range(match.range, in: normalized).map { String(normalized[$0]) }
        }

        for token in tokens {
            if falsePositives.contains(token) { continue }
            if slurRoots.contains(where: { token.contains($0) }) {
                signal.slur = true
                continue
            }
            if insultRoots.contains(where: { token.contains($0.trimmingCharacters(in: .whitespaces)) }) {
                signal.insult = true
                continue
            }
            if mildRoots.contains(where: { token.contains($0) }) {
                signal.mild = true
            }
        }

        // An insult or slur in the same message suppresses the mild count:
        // never learn swearing from an angry argument.
        if signal.isHostile { signal.mild = false }
        return signal
    }

    /// Lets the user's own manual style card be rejected if it contains slurs.
    static func containsHardLanguage(_ text: String) -> Bool {
        let signal = scan(text)
        return signal.isHostile
    }

    private static func normalize(_ text: String) -> String {
        var result = ""
        for character in text.lowercased() {
            let mapped = lookalikes[character] ?? character
            if mapped == "*" || mapped == "@" || mapped == "_" { continue }
            result.append(mapped)
        }
        return result
    }
}