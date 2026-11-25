import Foundation

/// D3: a tool that declares an output shape cannot return free-form text.
///
/// The check is deliberately small: the value must be an object, carry the declared
/// required keys, and each declared property must match its primitive type. That is
/// enough to catch "the tool returned a sentence where the caller expected a list"
/// without turning this into a second JSON Schema implementation.
enum ToolOutputContract {
    static func problem(value: Any, schema: [String: AnySendable]) -> String? {
        guard let root = schema["type"]?.value as? String, root == "object" else {
            return "схема выхода должна описывать object"
        }
        guard let object = value as? [String: Any] else {
            return "значение не объект: \(type(of: value))"
        }
        let properties = (schema["properties"]?.value as? [String: [String: Any]]) ?? [:]
        let required = (schema["required"]?.value as? [String]) ?? []
        let missing = required.filter { object[$0] == nil }
        guard missing.isEmpty else {
            return "нет обязательных полей: \(missing.joined(separator: ", "))"
        }
        for (key, definition) in properties {
            guard let expected = definition["type"] as? String, let actual = object[key] else { continue }
            if let problem = mismatch(expected: expected, actual: actual, key: key) {
                return problem
            }
        }
        return nil
    }

    private static func mismatch(expected: String, actual: Any, key: String) -> String? {
        switch expected {
        case "string":
            return actual is String ? nil : "\(key): ожидалась строка"
        case "boolean":
            return actual is Bool ? nil : "\(key): ожидалось true/false"
        case "integer":
            guard let number = actual as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(number.int64Value) else {
                return "\(key): ожидалось целое"
            }
            return nil
        case "number":
            guard let number = actual as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return "\(key): ожидалось число"
            }
            return nil
        case "array":
            return actual is [Any] ? nil : "\(key): ожидался массив"
        case "object":
            return actual is [String: Any] ? nil : "\(key): ожидался объект"
        default:
            return nil
        }
    }
}
