import Foundation

/// Argument coercion for tool calls and JSON-shaped tool payloads.
///
/// Models routinely emit numbers as strings (`"limit": "50"`), floats (`50.0`), and
/// booleans as `"true"`. JSONSerialization also turns every number into `NSNumber`,
/// and `NSNumber(1)` bridges to `Bool` — so a plain `as? Int` / `as? Bool` pair cannot
/// tell `1` from `true`. `CFBooleanGetTypeID` is the only reliable discriminator, which
/// is why every reader goes through here.
enum Coerce {
    static func int(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if isJSONBool(value) { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if isJSONBool(value) { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            // A real JSON number is not a boolean: `{"replace_all": 1}` is a mistake
            // worth ignoring rather than guessing.
            return isJSONBool(value) ? number.boolValue : nil
        }
        if let text = value as? String {
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func isJSONBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

extension ToolRegistry {
    static func int(_ args: [String: Any], _ key: String) -> Int? { Coerce.int(args[key]) }
    static func double(_ args: [String: Any], _ key: String) -> Double? { Coerce.double(args[key]) }
    static func bool(_ args: [String: Any], _ key: String) -> Bool? { Coerce.bool(args[key]) }
    static func string(_ args: [String: Any], _ key: String) -> String? { Coerce.string(args[key]) }
}
