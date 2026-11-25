import AppKit
import ApplicationServices
import Foundation

/// R18.11: one turn's worth of GUI budget, plus the stop flag that the global hotkey
/// and the Stop button raise. Pure state so the limits are testable without a window
/// server; the interceptor and `ChatStore` do the acting.
struct GUIControlLimits: Equatable, Sendable {
    /// Clicks per turn.
    var maxClicks = 40
    /// Posted CGEvent events per turn.
    var maxEvents = 300
    /// Clicks in a row that leave the AX tree unchanged before we call it stuck.
    var maxClicksWithoutProgress = 20
}

/// What one tool call is about to spend.
struct GUIControlCost: Equatable, Sendable {
    let clicks: Int
    let events: Int

    static func of(tool: String, args: [String: Any]) -> GUIControlCost {
        let action = (args["action"] as? String)?.lowercased() ?? ""
        switch tool {
        case "ui":
            switch action {
            case "click": return GUIControlCost(clicks: 1, events: 2)
            case "focus", "set_value", "menu_click": return GUIControlCost(clicks: 0, events: 1)
            default: return GUIControlCost(clicks: 0, events: 0)
            }
        case "mouse":
            switch action {
            case "click", "right_click": return GUIControlCost(clicks: 1, events: 2)
            case "double_click": return GUIControlCost(clicks: 2, events: 4)
            case "move", "drag", "scroll": return GUIControlCost(clicks: 0, events: 2)
            default: return GUIControlCost(clicks: 0, events: 0)
            }
        case "keyboard":
            switch action {
            case "type": return GUIControlCost(clicks: 0, events: (args["text"] as? String)?.count ?? 1)
            default: return GUIControlCost(clicks: 0, events: 1)
            }
        case "windows", "apps":
            return GUIControlCost(clicks: 0, events: 1)
        default:
            return GUIControlCost(clicks: 0, events: 0)
        }
    }
}

enum GUIControlOutcome: Equatable, Sendable {
    case allowed
    case denied(String)
}

/// Turn-scoped counters and focus bookkeeping.
final class GUIControlSession: @unchecked Sendable {
    private let lock = NSLock()
    private let limits: GUIControlLimits
    private var clicks = 0
    private var events = 0
    private var unchangedClicks = 0
    private var lastTreeSignature: String?
    private var lastTreeText = ""
    private var originalFrontmost: pid_t?
    private var stoleFocus = false
    private var abortedReason: String?

    init(limits: GUIControlLimits = GUIControlLimits()) {
        self.limits = limits
    }

    func beginTurn(originalFrontmost: pid_t?) {
        lock.lock(); defer { lock.unlock() }
        clicks = 0
        events = 0
        unchangedClicks = 0
        lastTreeSignature = nil
        lastTreeText = ""
        self.originalFrontmost = originalFrontmost
        stoleFocus = false
        abortedReason = nil
    }

    /// Atomic check-and-count: two parallel calls cannot both slip under the ceiling.
    func consume(_ cost: GUIControlCost) -> GUIControlOutcome {
        lock.lock(); defer { lock.unlock() }
        if let reason = abortedReason {
            return .denied("аварийный стоп: \(reason). Ничего не повторяй, ход остановлен.")
        }
        if unchangedClicks >= limits.maxClicksWithoutProgress {
            var text = "no_progress: \(unchangedClicks) кликов подряд не изменили AX-дерево. "
                + "Пиксельный путь или координаты неверны; останови цикл."
            if !lastTreeText.isEmpty { text += "\nПоследнее дерево:\n" + lastTreeText }
            return .denied(text)
        }
        guard clicks + cost.clicks <= limits.maxClicks else {
            return .denied("Потолок кликов на ход: \(limits.maxClicks). "
                + "Ход остановлен, чтобы не разошёлся цикл.")
        }
        guard events + cost.events <= limits.maxEvents else {
            return .denied("Потолок событий CGEvent на ход: \(limits.maxEvents). "
                + "Ход остановлен, чтобы не разошёлся цикл.")
        }
        clicks += cost.clicks
        events += cost.events
        return .allowed
    }

    /// `expect_frontmost`: the model names the app it believes is in front. A different
    /// frontmost app means the click would land in a stranger's window, so nothing is
    /// sent at all.
    func checkFrontmost(expected: pid_t?, actual: pid_t?) -> GUIControlOutcome {
        guard let expected else { return .allowed }
        guard expected == actual else {
            return .denied("frontmost_changed: ожидался pid \(expected), сейчас "
                + "\(actual.map(String.init) ?? "nil"). Ни одно событие не отправлено; "
                + "перечитай windows/apps и повтори с актуальным expect_frontmost.")
        }
        return .allowed
    }

    /// Called after a click with the digest of the AX tree it was supposed to change.
    /// Twenty unchanged trees in a row mean the click misses, not that the app is slow.
    func noteTree(signature: String, text: String) -> GUIControlOutcome {
        lock.lock(); defer { lock.unlock() }
        lastTreeText = text
        if signature == lastTreeSignature {
            unchangedClicks += 1
        } else {
            unchangedClicks = 0
            lastTreeSignature = signature
        }
        if unchangedClicks >= limits.maxClicksWithoutProgress {
            var message = "no_progress: \(unchangedClicks) кликов подряд не изменили AX-дерево."
            if !text.isEmpty { message += "\nПоследнее дерево:\n" + text }
            return .denied(message)
        }
        return .allowed
    }

    /// The agent moved activation away from the app the user was in.
    func noteFocus(current: pid_t?) {
        lock.lock(); defer { lock.unlock() }
        guard let originalFrontmost, let current, current != originalFrontmost else { return }
        stoleFocus = true
    }

    /// The pid to reactivate at the end of the turn, or nil when focus was never moved.
    func restoreTarget(current: pid_t?) -> pid_t? {
        lock.lock(); defer { lock.unlock() }
        guard stoleFocus, let originalFrontmost, originalFrontmost != current else { return nil }
        return originalFrontmost
    }

    func abort(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        if abortedReason == nil { abortedReason = reason }
    }

    var aborted: String? {
        lock.lock(); defer { lock.unlock() }
        return abortedReason
    }

    func counters() -> (clicks: Int, events: Int, unchanged: Int) {
        lock.lock(); defer { lock.unlock() }
        return (clicks, events, unchangedClicks)
    }
}

/// Process-wide stop signal: the hotkey and the Stop button set it, the guard reads it.
/// Separate from the session because the hotkey can fire before a turn exists.
final class AgentAbortSignal: @unchecked Sendable {
    static let shared = AgentAbortSignal()

    private let lock = NSLock()
    private var reason: String?
    /// R32.3: a long call cannot be asked between steps, so it subscribes instead. The
    /// stop hotkey sets the flag without cancelling the turn task; this is how a running
    /// `bash` or `process wait` learns about it.
    private var handlers: [UUID: @Sendable () -> Void] = [:]

    func abort(_ reason: String) {
        lock.lock()
        // Only the transition into "stopped" wakes subscribers. A second stop while the
        // turn is already unwinding must not cancel the child a second time.
        let first = self.reason == nil
        if first { self.reason = reason }
        let callbacks = first ? Array(handlers.values) : []
        if first { handlers.removeAll() }
        lock.unlock()
        // Outside the lock: a handler may take its own lock.
        for callback in callbacks { callback() }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        reason = nil
        handlers.removeAll()
    }

    var current: String? {
        lock.lock(); defer { lock.unlock() }
        return reason
    }

    /// Registers a one-shot reaction to the next abort. Returns a token for removal.
    @discardableResult
    func onAbort(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        let alreadyAborted = reason != nil
        if !alreadyAborted { handlers[token] = handler }
        lock.unlock()
        if alreadyAborted { handler() }
        return token
    }

    func removeHandler(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        handlers[token] = nil
    }

    /// Sleeps in small slices so a caller stops promptly when the signal fires or the
    /// task is cancelled, without each tool inventing its own poll interval.
    func sleep(seconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if Task.isCancelled || current != nil { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Gate in front of the GUI tools: abort flag, frontmost expectation and the per-turn
/// ceilings. Lives in the same interceptor chain as the other guards so a new GUI tool
/// cannot forget it.
struct GUIControlGuardInterceptor: ToolInterceptor {
    let name = "gui_control"
    let session: GUIControlSession
    let abort: AgentAbortSignal
    let frontmost: @Sendable () -> pid_t?

    static let tools: Set<String> = [
        "ui", "mouse", "keyboard", "clipboard", "windows", "apps"
    ]

    init(
        session: GUIControlSession,
        abort: AgentAbortSignal = .shared,
        frontmost: @escaping @Sendable () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    ) {
        self.session = session
        self.abort = abort
        self.frontmost = frontmost
    }

    func beforeCall(_ call: ToolCall, context: ToolCallContext) async throws -> GuardVerdict {
        guard Self.tools.contains(call.name) else { return .pass }
        if let reason = abort.current {
            return .deny(reason: "аварийный стоп: \(reason)",
                         guidance: "Пользователь остановил ход. Не повторяй действие.")
        }
        let args = ToolRegistry.decodeArguments(call.arguments) ?? [:]
        if let expected = Self.expectedPID(args["expect_frontmost"]) {
            if case .denied(let reason) = session.checkFrontmost(expected: expected, actual: frontmost()) {
                return .deny(reason: reason, guidance: nil)
            }
        }
        let cost = GUIControlCost.of(tool: call.name, args: args)
        if case .denied(let reason) = session.consume(cost) {
            return .deny(reason: reason, guidance: nil)
        }
        return .pass
    }

    func afterResult(
        _ call: ToolCall, result: ToolResult, context: ToolCallContext
    ) async -> ToolResult {
        guard Self.tools.contains(call.name) else { return result }
        session.noteFocus(current: frontmost())
        let args = ToolRegistry.decodeArguments(call.arguments) ?? [:]
        let action = (args["action"] as? String)?.lowercased() ?? ""
        guard call.name == "ui" || call.name == "mouse",
              ["click", "double_click", "right_click"].contains(action) else { return result }
        guard let signature = AXTreeSignature.of(pid: frontmost()) else { return result }
        if case .denied(let warning) = session.noteTree(
            signature: signature.digest, text: signature.text
        ) {
            return .fail(result.output + "\n" + warning)
        }
        return result
    }

    static func expectedPID(_ raw: Any?) -> pid_t? {
        if let number = raw as? Int { return pid_t(number) }
        guard let name = raw as? String, !name.isEmpty else { return nil }
        let lower = name.lowercased()
        return NSWorkspace.shared.runningApplications.first {
            ($0.localizedName ?? "").lowercased().contains(lower)
                || ($0.bundleIdentifier ?? "").lowercased().contains(lower)
        }?.processIdentifier
    }
}

/// A cheap digest of the frontmost app's AX tree, used only to notice "nothing changed".
enum AXTreeSignature {
    struct Signature: Equatable, Sendable {
        let digest: String
        let text: String
    }

    static func of(pid: pid_t?, depth: Int = 3, budget: Int = 600) -> Signature? {
        guard let pid else { return nil }
        let root = AXUIElementCreateApplication(pid)
        var nodes = budget
        let node = AXBridge.snapshot(root, depth: 0, budget: &nodes)
        var lines = budget
        let rendered = node.lines(depth: 0, maxNodes: budget, budget: &lines)
        guard !rendered.isEmpty else { return nil }
        let text = rendered.joined(separator: "\n")
        return Signature(digest: String(text.hashValue), text: String(text.prefix(4_000)))
    }
}
