import Foundation

/// Argument coercion for tool calls.
///
/// Models routinely emit numbers as strings (`"limit": "50"`) or as floats (`50.0`),
/// and booleans as `"true"`. Reading `args["x"] as? Int` silently turned all of those
/// into `nil`, so the tool quietly used its default and the model could not see why the
/// call behaved differently from what it asked for.
extension ToolRegistry {
    /// JSON numbers arrive as `NSNumber`, and an `NSNumber(1)` bridges to `Bool` as
    /// well — so a plain `as? Int`/`as? Bool` pair cannot tell `1` from `true`.
    /// `CFBooleanGetTypeID` is the only reliable discriminator.
    private static func isJSONBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func int(_ args: [String: Any], _ key: String) -> Int? {
        guard let value = args[key] else { return nil }
        if isJSONBool(value) { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func double(_ args: [String: Any], _ key: String) -> Double? {
        guard let value = args[key] else { return nil }
        if isJSONBool(value) { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func bool(_ args: [String: Any], _ key: String) -> Bool? {
        guard let value = args[key] else { return nil }
        if let number = value as? NSNumber {
            // A real JSON number is not a boolean: `{"replace_all": 1}` is a mistake
            // worth ignoring rather than guessing.
            return isJSONBool(value) ? number.boolValue : nil
        }
        if let value = value as? Bool { return value }
        if let text = value as? String {
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    static func string(_ args: [String: Any], _ key: String) -> String? {
        args[key] as? String
    }
}
