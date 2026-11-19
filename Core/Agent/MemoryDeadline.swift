import Foundation

/// R33.4: a deadline written as "until 19.10" cannot be compared with another deadline.
///
/// Two records about the same certificate are only mechanically comparable when both
/// carry a full date. Record #83 held a wrong certificate date for two months precisely
/// because nothing forced the date to be complete.
enum MemoryDeadline {
    private static let fullDate = try! NSRegularExpression(
        pattern: "\\b\\d{2}\\.\\d{2}\\.\\d{4}\\b"
    )
    private static let year = try! NSRegularExpression(pattern: "\\b(19|20)\\d{2}\\b")
    /// A deadline word within 20 characters of a day.month without a year.
    private static let shortDeadline = try! NSRegularExpression(
        pattern: "(?i)(до|после|истекает|истекают|действует|действителен|срок|until|expires)\\D{0,20}\\d{1,2}\\.\\d{1,2}(?!\\.\\d)"
    )

    static func needsFullDate(text: String, area: String) -> Bool {
        guard area == "fact" || area == "decision" else { return false }
        let range = NSRange(text.startIndex..., in: text)
        if fullDate.firstMatch(in: text, range: range) != nil { return false }
        return year.firstMatch(in: text, range: range) != nil
            || shortDeadline.firstMatch(in: text, range: range) != nil
    }

    static let refusal = "Для area fact и decision с годом или сроком нужна полная дата "
        + "дд.мм.гггг: «до 19.10» нельзя сравнить с другой записью о том же сроке. "
        + "Перепиши текст с полной датой."
}
