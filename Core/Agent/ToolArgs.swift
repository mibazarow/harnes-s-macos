import Foundation

/// Argument coercion for tool calls.
///
/// Models routinely emit numbers as strings (`"limit": "50"`) or as floats (`50.0`),
/// and booleans as `"true"`. Reading `args["x"] as? Int` silently turned all of those
/// into `nil`, so the tool quietly used its default and the model could not see why the
/// call behaved differently from what it asked for.
extension ToolRegistry {
    static func int(_ args: [String: Any], _ key: String) -> Int? {
        switch args[key] {
        // Checked first: JSON booleans bridge to NSNumber, and `as? Int` accepts them.
        case is Bool:
            return nil
        case let value as Int:
            return value
        case let value as Double:
            return Int(value)
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    static func double(_ args: [String: Any], _ key: String) -> Double? {
        switch args[key] {
        case is Bool:
            return nil
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    static func bool(_ args: [String: Any], _ key: String) -> Bool? {
        switch args[key] {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            switch value.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    static func string(_ args: [String: Any], _ key: String) -> String? {
        args[key] as? String
    }
}
