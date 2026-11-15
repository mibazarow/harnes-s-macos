import Foundation

/// Guards around the web tools (R16.6).
///
/// Two jobs, both cheap and local:
/// - refuse the browser for system pages (`chrome://`, extensions, the Web Store), which
///   no task needs and which can expose the host;
/// - after a browser result, say that the same site already answered `webfetch` in this
///   session, so the next visit goes down the cheaper rung. A reminder, not a refusal:
///   there are pages only a real browser can render.
final class BrowserGuardInterceptor: ToolInterceptor, @unchecked Sendable {
    let name = "browser_guard"

    private struct State {
        var textHosts: Set<String> = []
        var forbiddenHosts: Set<String> = []
    }

    private let lock = NSLock()
    private var state = State()

    static let blockedPrefixes = [
        "chrome://", "chrome-extension://", "devtools://", "edge://", "about:"
    ]
    static let blockedHosts = ["chromewebstore.google.com", "chrome.google.com"]

    func beforeCall(_ call: ToolCall, context: ToolCallContext) async throws -> ToolVerdict {
        guard call.name == "browser" else { return .allow }
        guard let url = Self.urlArgument(call.arguments) else { return .allow }
        let lower = url.lowercased()
        if Self.blockedPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return .deny(
                reason: "системная вкладка браузера",
                guidance: "Открывай только http(s)-адреса задачи; служебные страницы браузера недоступны."
            )
        }
        if let host = Self.host(of: url), Self.blockedHosts.contains(host) {
            return .deny(
                reason: "магазин расширений",
                guidance: "Установка расширений в этом приложении не поддерживается."
            )
        }
        return .allow
    }

    func afterResult(
        _ call: ToolCall, result: ToolResult, context: ToolCallContext
    ) async -> ToolResult {
        guard let url = Self.urlArgument(call.arguments), let host = Self.host(of: url) else {
            return result
        }
        switch call.name {
        case "webfetch":
            record(host: host, result: result)
            return result
        case "browser":
            let (alreadyText, forbidden) = ladderNote(for: host)
            if alreadyText {
                return ToolResult(
                    output: result.output + "\n[Ладдер: \(host) уже отдавался webfetch текстом "
                        + "в этой сессии — дальше дешевле webfetch, браузер оставь для JS-страниц.]",
                    isError: result.isError
                )
            }
            if forbidden {
                return ToolResult(
                    output: result.output + "\n[Ладдер: webfetch по \(host) получил 403 — "
                        + "браузер здесь оправдан.]",
                    isError: result.isError
                )
            }
            return result
        default:
            return result
        }
    }

    private func record(host: String, result: ToolResult) {
        lock.lock()
        defer { lock.unlock() }
        if result.isError, result.output.contains("HTTP 403") {
            state.forbiddenHosts.insert(host)
        } else if !result.isError {
            state.textHosts.insert(host)
        }
    }

    private func ladderNote(for host: String) -> (alreadyText: Bool, forbidden: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (state.textHosts.contains(host), state.forbiddenHosts.contains(host))
    }

    static func urlArgument(_ arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["url"] as? String
    }

    static func host(of url: String) -> String? {
        URL(string: url)?.host?.lowercased()
    }
}
