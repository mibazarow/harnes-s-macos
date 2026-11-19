import Foundation

/// B11: the cheap filter that keeps chatter out of memory.
///
/// Ported from the Oborbot rules that were checked on real data: a dictionary of
/// acknowledgements, a minimum length, and the paraphrase prefixes that mark a retelling
/// of a retelling rather than a fact. No model, no network — this runs on every write.
///
/// Two levels on purpose:
/// - every source gets the dictionary and the three-letter floor, so "ок" never becomes
///   a memory;
/// - `compaction` gets the stricter fact rules, because that is where the junk came
///   from: "Пользователь также получил что-то из Apple ID вчера" was extracted, not
///   written by the user.
enum MemoryQuality {
    /// Acknowledgements and filler. Compared after lowercasing and stripping
    /// punctuation, as whole strings only.
    static let junk: Set<String> = [
        "ку", "ок", "окей", "ага", "угу", "спс", "спасибо", "норм", "нормально",
        "ахаха", "ахах", "хаха", "лол", "кек", "это", "вот", "да", "нет", "не",
        "привет", "здравствуй", "понял", "поняла", "ясно", "хорошо", "ладно"
    ]

    /// A retelling starts like this, not like a fact.
    static let paraphrasePrefixes: [String] = [
        "говорящ", "упомянут", "автор сообщения", "пользователь,", "пользователь также",
        "зритель,", "участник чата", "написал сообщение", "в сообщении", "было сказано",
        "из переписки", "из контекста"
    ]

    /// Tails that mark a retelling.
    static let paraphraseTails: [String] = [
        ", упомянутый говорящим", ", упомянутая говорящим", ", упомянутое говорящим"
    ]

    static let minimumLetters = 3
    static let minimumFactLetters = 12

    /// Letters only: digits, emoji and punctuation do not make a memory.
    static func letterCount(_ text: String) -> Int {
        text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
    }

    static func normalized(_ text: String) -> String {
        let lowered = text.lowercased()
        let kept = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " "
                ? Character(scalar)
                : " "
        }
        return String(kept)
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Nil means the text may be written. A string is the reason it may not.
    static func rejection(for text: String, source: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard letterCount(trimmed) >= minimumLetters else {
            return "Слишком коротко для памяти: \(trimmed.prefix(40))."
        }
        if junk.contains(normalized(trimmed)) {
            return "Это подтверждение, а не факт: \(trimmed.prefix(40))."
        }
        guard source == "compaction" else { return nil }
        return factRejection(trimmed)
    }

    /// The stricter rules, applied only to facts extracted from a folded conversation.
    static func factRejection(_ text: String) -> String? {
        let lower = text.lowercased()
        guard letterCount(text) >= minimumFactLetters else {
            return "Извлечённый факт короче \(minimumFactLetters) букв — это шум."
        }
        if let prefix = paraphrasePrefixes.first(where: { lower.hasPrefix($0) }) {
            return "Пересказ, а не факт (начало «\(prefix)»): \(text.prefix(60))."
        }
        if paraphraseTails.contains(where: { lower.hasSuffix($0) }) {
            return "Пересказ, а не факт (хвост «упомянутый говорящим»): \(text.prefix(60))."
        }
        // "вчера", "сегодня", "что-то", "возможно" — true today, false tomorrow.
        let unstable = ["вчера", "сегодня", "завтра", "что-то", "возможно",
                        "наверное", "кажется", "как-то", "недавно"]
        if let word = unstable.first(where: { lower.contains($0) }) {
            return "Факт привязан ко времени или к догадке («\(word)») и станет ложью: "
                + "\(text.prefix(60))."
        }
        return nil
    }
}
