import Foundation

enum ConfigurationError: LocalizedError, Sendable {
    case invalidManifest(String)
    case alreadyExists(String)
    case notFound(String)
    case builtinReadOnly(String)
    case unsupportedSource(String)
    case downloadFailed(String)
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason):
            "Некорректный SKILL.md: \(reason)"
        case .alreadyExists(let name):
            "«\(name)» уже существует. Для замены добавь --force."
        case .notFound(let name):
            "«\(name)» не найдено."
        case .builtinReadOnly(let name):
            "«\(name)» — встроенный скилл, его нельзя удалить или изменить."
        case .unsupportedSource(let reason):
            "Источник не поддерживается: \(reason)"
        case .downloadFailed(let reason):
            "Не удалось скачать: \(reason)"
        case .invalidArguments(let reason):
            reason
        }
    }
}