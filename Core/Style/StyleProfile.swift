import Foundation

enum AddressForm: String, Codable, Sendable {
    case ty
    case vy
}

enum StyleTraitKey: String, Codable, CaseIterable, Sendable {
    case address
    case brevity
    case slang
    case profanity
    case emoji
    case punctuation
    case directness
    case humor
}

enum StyleMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case neutral
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Авто"
        case .neutral: "Нейтрально"
        case .manual: "Вручную"
        }
    }

    var hint: String {
        switch self {
        case .auto: "Подстраиваться под манеру речи"
        case .neutral: "Держать базовый тон, профиль сохраняется"
        case .manual: "Использовать только мою карточку стиля"
        }
    }
}

/// One axis of the user's communication style. Form only — never content or opinions.
struct StyleTrait: Codable, Sendable, Equatable {
    var key: StyleTraitKey
    var value: Double = 0
    var observations: Int = 0
    var hitMessages: Int = 0
    var dayKeys: [Int] = []
    var lastSeenAt: Int64 = 0
    var lastHitAt: Int64 = 0
}

/// Persistent cross-chat style profile. Counters plus a short card, never raw messages.
struct StyleProfile: Codable, Sendable, Equatable {
    var version: Int = 1
    var samples: Int = 0
    var sessions: Int = 0
    var firstDay: Int?
    var lastDay: Int?
    var lastMessageAt: Int64 = 0
    var mode: StyleMode = .auto
    var profanityEnabled: Bool = true
    var traits: [StyleTrait] = []
    var card: String?
    var cardUpdatedAt: Int64 = 0
    var manualCard: String?

    func trait(_ key: StyleTraitKey) -> StyleTrait? {
        traits.first { $0.key == key }
    }

    func withTrait(_ trait: StyleTrait) -> StyleProfile {
        var copy = self
        if let index = copy.traits.firstIndex(where: { $0.key == trait.key }) {
            copy.traits[index] = trait
        } else {
            copy.traits.append(trait)
        }
        return copy
    }
}

/// Per-message measurements. Pure and cheap enough to run on every user message.
struct StyleSignal: Sendable {
    var hasContent = false
    var length = 0
    var address: AddressForm?
    var hasEmoji = false
    var hasSlang = false
    var profanityHits = 0
    var informalPunctuation = false
    var isDirective = false
}

enum StyleAnalyzer {
    static let shortMessageChars = 60
    static let noFinalPunctuationMinChars = 25
    static let lowercaseStartMinChars = 12

    private static let tyPronouns: Set<String> = [
        "ты", "тебя", "тебе", "тобой", "тобою", "твой", "твоя", "твоё", "твое", "твои",
        "твоих", "твоим", "твоими", "твоему", "твоей", "твоего", "твою"
    ]

    private static let vyPronouns: Set<String> = [
        "вы", "вас", "вам", "вами", "ваш", "ваша", "ваше", "ваши", "ваших", "вашим",
        "вашими", "вашему", "вашей", "вашего", "вашу"
    ]

    private static let slang: Set<String> = [
        "норм", "короче", "хз", "имхо", "лол", "кек", "зашквар", "жиза", "кринж", "топ",
        "база", "чел", "чувак", "бро", "ок", "оки", "ага", "ясно", "понял", "поняла",
        "походу", "вроде", "тип", "типо"
    ]

    private static let directiveVerbs: Set<String> = [
        "сделай", "сделайте", "дай", "дайте", "открой", "откройте", "покажи", "покажите",
        "включи", "включите", "выключи", "выключите", "поставь", "поставьте", "найди",
        "напиши", "напишите", "позвони", "позвоните", "отправь", "отправьте", "удали",
        "удалите", "создай", "создайте", "переключи", "переключите", "скачай", "скачайте",
        "проверь", "проверьте", "запусти", "запустите", "закрой", "закройте", "почини",
        "исправь", "добавь", "перепиши", "отрефактори", "собери"
    ]

    private static let softImperatives: Set<String> = ["давай", "давайте"]
    private static let terminalPunctuation: Set<Character> = [".", "!", "?", "…"]

    private static let tokenRegex = try! NSRegularExpression(pattern: "[\\p{L}]+")

    static func analyze(_ text: String, profanityHits: Int = 0) -> StyleSignal {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return StyleSignal() }

        let tokens = self.tokens(trimmed)

        var signal = StyleSignal()
        signal.hasContent = true
        signal.length = trimmed.count
        signal.address = address(tokens)
        signal.hasEmoji = hasEmoji(trimmed)
        signal.hasSlang = tokens.contains { slang.contains($0) }
        signal.profanityHits = max(profanityHits, 0)
        signal.informalPunctuation = informalPunctuation(trimmed)
        signal.isDirective = isDirective(tokens)
        return signal
    }

    private static func tokens(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return tokenRegex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]).lowercased() }
        }
    }

    private static func address(_ tokens: [String]) -> AddressForm? {
        let ty = tokens.contains { tyPronouns.contains($0) }
        let vy = tokens.contains { vyPronouns.contains($0) }
        if ty && !vy { return .ty }
        if vy && !ty { return .vy }
        return nil
    }

    private static func hasEmoji(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 0x00A9 || value == 0x00AE || value == 0x2122 { continue }
            if value == 0xFE0F { return true }
            if (0x1F300...0x1FAFF).contains(value) || (0x1F1E6...0x1F1FF).contains(value) { return true }
            if (0x2600...0x27BF).contains(value) || (0x2B00...0x2BFF).contains(value) { return true }
        }
        return false
    }

    private static func informalPunctuation(_ text: String) -> Bool {
        if text.contains("!!") { return true }
        if text.contains("...") || text.contains("…") { return true }

        if let first = text.first, first.isLowercase, text.count >= lowercaseStartMinChars,
           first.isLetter {
            return true
        }

        let endsWithPunctuation = text.last.map { terminalPunctuation.contains($0) } ?? false
        return !endsWithPunctuation && text.count >= noFinalPunctuationMinChars
    }

    private static func isDirective(_ tokens: [String]) -> Bool {
        if tokens.contains(where: { softImperatives.contains($0) }) { return true }
        return tokens.prefix(3).contains { directiveVerbs.contains($0) }
    }
}

enum StyleActivation {
    static let minObservations = 8
    static let minDays = 2
    static let addressMinShare = 0.65
    static let brevityMinShare = 0.6
    static let brevityMinObservations = 10
    static let slangMinShare = 0.15
    static let slangMinDays = 3
    static let profanityMinShare = 0.08
    static let profanityMinHitMessages = 5
    static let profanityMinDays = 4
    static let emojiMinShare = 0.25
    static let punctuationMinShare = 0.3
    static let punctuationMinObservations = 10
    static let directnessMinShare = 0.4
    static let humorMinValue = 0.5

    static func isActive(_ trait: StyleTrait) -> Bool {
        switch trait.key {
        case .address:
            return max(trait.value, 1 - trait.value) >= addressMinShare
                && trait.observations >= minObservations
                && trait.dayKeys.count >= minDays
        case .brevity:
            return trait.value >= brevityMinShare
                && trait.observations >= brevityMinObservations
                && trait.dayKeys.count >= minDays
        case .slang:
            return trait.value >= slangMinShare
                && trait.observations >= minObservations
                && trait.dayKeys.count >= slangMinDays
        case .profanity:
            return trait.value >= profanityMinShare
                && trait.hitMessages >= profanityMinHitMessages
                && trait.dayKeys.count >= profanityMinDays
        case .emoji:
            return trait.value >= emojiMinShare
                && trait.observations >= minObservations
                && trait.dayKeys.count >= minDays
        case .punctuation:
            return trait.value >= punctuationMinShare
                && trait.observations >= punctuationMinObservations
                && trait.dayKeys.count >= minDays
        case .directness:
            return trait.value >= directnessMinShare
                && trait.observations >= minObservations
                && trait.dayKeys.count >= minDays
        case .humor:
            return trait.value >= humorMinValue && trait.observations >= 1
        }
    }

    static func addressForm(_ trait: StyleTrait) -> AddressForm {
        trait.value >= 0.5 ? .ty : .vy
    }

    /// Active traits in render priority; address and brevity shape the persona most.
    static func activeTraits(_ profile: StyleProfile, limit: Int = 3) -> [StyleTrait] {
        guard limit > 0 else { return [] }
        let order: [StyleTraitKey] = [
            .address, .brevity, .profanity, .slang, .emoji, .punctuation, .directness, .humor
        ]
        return order
            .compactMap { key in profile.traits.first { $0.key == key } }
            .filter { isActive($0) }
            .prefix(limit)
            .map { $0 }
    }
}

enum StyleReducer {
    /// Distinct days retained per trait; enough for every activation gate.
    static let maxDayKeys = 14
    /// Smoothing factor after warm-up.
    static let emaAlpha = 0.15
    static let warmupObservations = 10
    static let decayPerWeek = 0.95
    static let decayMinValue = 0.2
    static let dropAfterWeeks = 2.0
    static let sessionGapMillis: Int64 = 2 * 60 * 60 * 1000

    static func apply(
        _ profile: StyleProfile,
        signal: StyleSignal,
        now: Int64,
        day: Int
    ) -> StyleProfile {
        guard signal.hasContent else { return profile }

        var updated = decay(profile, now: now)
        let newSession = updated.lastMessageAt == 0 || now - updated.lastMessageAt > sessionGapMillis
        updated.samples += 1
        if newSession { updated.sessions += 1 }
        if updated.firstDay == nil { updated.firstDay = day }
        updated.lastDay = day
        updated.lastMessageAt = now

        func observe(_ key: StyleTraitKey, applicable: Bool, hit: Bool) {
            guard applicable else { return }
            let current = updated.trait(key) ?? StyleTrait(key: key)
            let observations = current.observations + 1
            let alpha = observations <= warmupObservations ? 1.0 / Double(observations) : emaAlpha
            let value = min(max(current.value + alpha * ((hit ? 1.0 : 0.0) - current.value), 0), 1)

            var days = (current.dayKeys + [day]).sorted()
            var uniqueDays: [Int] = []
            for key in days where uniqueDays.last != key { uniqueDays.append(key) }
            days = Array(uniqueDays.suffix(maxDayKeys))

            updated = updated.withTrait(StyleTrait(
                key: key,
                value: value,
                observations: observations,
                hitMessages: current.hitMessages + (hit ? 1 : 0),
                dayKeys: days,
                lastSeenAt: now,
                lastHitAt: hit ? now : current.lastHitAt
            ))
        }

        observe(.address, applicable: signal.address != nil, hit: signal.address == .ty)
        observe(.brevity, applicable: true, hit: signal.length <= StyleAnalyzer.shortMessageChars)
        observe(.slang, applicable: true, hit: signal.hasSlang)
        observe(.profanity, applicable: true, hit: signal.profanityHits > 0)
        observe(.emoji, applicable: true, hit: signal.hasEmoji)
        observe(.punctuation, applicable: true, hit: signal.informalPunctuation)
        observe(.directness, applicable: true, hit: signal.isDirective)

        return updated
    }

    static func decay(_ profile: StyleProfile, now: Int64) -> StyleProfile {
        guard !profile.traits.isEmpty else { return profile }

        var changed = false
        var kept: [StyleTrait] = []

        for trait in profile.traits {
            let reference = trait.key == .address ? trait.lastSeenAt : trait.lastHitAt
            guard reference > 0, now > reference else {
                kept.append(trait)
                continue
            }

            let weeks = Double(now - reference) / Double(7 * 24 * 60 * 60 * 1000)
            guard weeks >= 1 else {
                kept.append(trait)
                continue
            }

            let value = trait.value * pow(decayPerWeek, weeks)
            changed = true
            if value < decayMinValue && weeks >= dropAfterWeeks { continue }

            var updated = trait
            updated.value = value
            kept.append(updated)
        }

        var result = profile
        result.traits = kept
        return changed ? result : profile
    }
}