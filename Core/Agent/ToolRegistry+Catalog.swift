import Foundation

extension ToolRegistry {
    /// Full schema text for one definition: description plus its JSON parameters.
    static func schemaText(_ definition: ToolDefinition) -> String {
        let object = definition.parameters.mapValues { $0.value }
        let json = (try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .prettyPrinted]
        )).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "\(definition.name): \(definition.description)\n\(json)"
    }

    /// Deferred tools travel as a name and one line; this is how the model asks for the
    /// rest. Loading lasts for the session, so the schema does not have to be re-fetched
    /// on every step.
    func toolLoad(_ args: [String: Any]) -> ToolResult {
        let names: [String]
        if let list = args["names"] as? [String] {
            names = list
        } else if let single = args["names"] as? String {
            names = [single]
        } else {
            return .fail("names обязателен: список имён инструментов")
        }

        var found: [ToolDefinition] = []
        var unknown: [String] = []
        for name in names {
            if let definition = Self.definitions.first(where: { $0.name == name }) {
                found.append(definition)
            } else {
                unknown.append(name)
            }
        }
        catalog.load(found.map(\.name))

        var text = found.map(Self.schemaText).joined(separator: "\n\n")
        if !unknown.isEmpty {
            text += (text.isEmpty ? "" : "\n\n") + "Неизвестные: \(unknown.joined(separator: ", "))"
        }
        return .ok(text.isEmpty ? "Ничего не найдено." : text)
    }

    /// A deferred tool called before its schema was loaded: the model guessed the
    /// arguments wrong, so answer with the schema itself instead of "invalid JSON".
    func deferredSchemaHint(_ name: String) -> String? {
        guard let definition = Self.definitions.first(where: {
            $0.name == name && $0.exposure == .deferred
        }), !catalog.isLoaded(name) else { return nil }
        catalog.load([name])
        return "Схема \(name) не была загружена. Вот она:\n" + Self.schemaText(definition)
    }
}
