import Foundation

/// The call as an interceptor sees it.
struct ToolCallContext: Sendable {
    let workspace: URL
    let readOnly: Bool
    /// R32.3: the stop token. Long calls subscribe to it; every call is checked against
    /// it before it starts, so a stop from the hotkey, the Stop button or the link
    /// channel reaches tools that have no UI of their own.
    let cancel: AgentAbortSignal

    init(workspace: URL, readOnly: Bool, cancel: AgentAbortSignal = .shared) {
        self.workspace = workspace
        self.readOnly = readOnly
        self.cancel = cancel
    }
}

/// What a guard decided about a call.
///
/// There is no "allow" outcome on purpose: a guard can only refuse or say "not my
/// business". A later `.pass` therefore cannot undo an earlier `.deny`, and the order
/// of listeners can never turn a refusal back into permission. `autopilot` is a policy
/// flag applied when the chain is assembled, not a verdict a guard can return.
enum GuardVerdict: Sendable, Equatable {
    /// Not this guard's business. Not an approval.
    case pass
    /// Do not run it; the model gets `reason` and `guidance` as the tool result.
    case deny(reason: String, guidance: String?)
    /// Run a different call instead. The replacement is schema-checked before it runs
    /// and still faces the guards after this one.
    case rewrite(ToolCall)
}

/// A gate in front of tool execution, and a hook on its result.
///
/// Before this existed, every check lived inside `AgentLoop` or at the top of
/// `ToolRegistry.execute`: adding one meant editing the loop and rebuilding, and a
/// misbehaving check was invisible unless someone read `latency.log`. Interceptors are
/// plain values in an explicitly ordered list (R16.1).
protocol ToolInterceptor: Sendable {
    var name: String { get }
    /// `throws`: a broken check must fail closed. Before R16.2 an exception (or a hang)
    /// meant "run the call anyway", which is the wrong default for a gate.
    func beforeCall(_ call: ToolCall, context: ToolCallContext) async throws -> GuardVerdict
    func afterResult(_ call: ToolCall, result: ToolResult, context: ToolCallContext) async -> ToolResult
    /// A gate that calls a model needs more than the chain default. `nil` keeps it.
    var timeoutOverride: Duration? { get }
}

extension ToolInterceptor {
    var timeoutOverride: Duration? { nil }

    func beforeCall(_ call: ToolCall, context: ToolCallContext) async throws -> GuardVerdict { .pass }

    func afterResult(
        _ call: ToolCall, result: ToolResult, context: ToolCallContext
    ) async -> ToolResult { result }
}

/// Ordered interceptors. The order is the array the caller passes — one place, not
/// registration order — and the first `deny` wins.
struct ToolInterceptorChain: Sendable {
    enum Outcome: Sendable {
        case allowed(ToolCall)
        case denied(ToolResult)
    }

    let interceptors: [ToolInterceptor]
    /// How long one interceptor may take. A gate that hangs is the same failure as a
    /// gate that throws: the call does not run.
    let timeout: Duration
    /// Where a refusal is recorded. Injected so the chain stays independent of the chat
    /// layer; production wires it to `latency.log`.
    let log: @Sendable (String) -> Void

    init(
        _ interceptors: [ToolInterceptor] = [],
        log: @escaping @Sendable (String) -> Void = { _ in },
        timeout: Duration = .milliseconds(2_000)
    ) {
        self.interceptors = interceptors
        self.log = log
        self.timeout = timeout
    }

    func before(_ call: ToolCall, context: ToolCallContext) async -> Outcome {
        var current = call
        for interceptor in interceptors {
            switch await verdict(from: interceptor, call: current, context: context) {
            case .pass:
                continue
            case .deny(let reason, let guidance):
                return .denied(Self.denial(call: current, reason: reason, guidance: guidance))
            case .rewrite(let rewritten):
                if let problem = Self.schemaProblem(in: rewritten) {
                    return .denied(Self.denial(
                        call: current,
                        reason: "перехватчик \(interceptor.name) вернул аргументы, не проходящие схему: \(problem)",
                        guidance: nil
                    ))
                }
                current = rewritten
            }
        }
        return .allowed(current)
    }

    /// One interceptor, bounded by `timeout`. A thrown error or a missed deadline is a
    /// refusal with the interceptor's name in the log — never a pass.
    private func verdict(
        from interceptor: ToolInterceptor,
        call: ToolCall,
        context: ToolCallContext
    ) async -> GuardVerdict {
        let started = ContinuousClock.now
        do {
            return try await withThrowingTaskGroup(of: GuardVerdict.self) { group in
                group.addTask { try await interceptor.beforeCall(call, context: context) }
                let deadline = interceptor.timeoutOverride ?? self.timeout
                group.addTask {
                    try await Task.sleep(for: deadline)
                    throw InterceptorTimeout()
                }
                guard let first = try await group.next() else { throw InterceptorTimeout() }
                group.cancelAll()
                return first
            }
        } catch is InterceptorTimeout {
            log("interceptor_failed name=\(interceptor.name) \(Self.millis(since: started))ms reason=timeout")
            return .deny(reason: "перехватчик \(interceptor.name) не ответил за "
                + "\(Self.plainMillis(interceptor.timeoutOverride ?? timeout)) мс", guidance: nil)
        } catch {
            log("interceptor_failed name=\(interceptor.name) \(Self.millis(since: started))ms "
                + "reason=\(error)")
            return .deny(reason: "перехватчик \(interceptor.name) упал: \(error)", guidance: nil)
        }
    }

    private struct InterceptorTimeout: Error {}

    private static func millis(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1_000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func plainMillis(_ timeout: Duration) -> Int {
        let components = timeout.components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }

    func after(_ call: ToolCall, result: ToolResult, context: ToolCallContext) async -> ToolResult {
        var current = result
        for interceptor in interceptors {
            current = await interceptor.afterResult(call, result: current, context: context)
        }
        return current
    }

    /// A refusal must reach the model as a tool result, not as a silently skipped turn:
    /// the model has to know why and what to do instead.
    static func denial(call: ToolCall, reason: String, guidance: String?) -> ToolResult {
        var text = "Вызов \(call.name) отклонён: \(reason)."
        if let guidance, !guidance.isEmpty {
            text += "\n" + guidance
        }
        return .fail(text)
    }

    /// `nil` when the call can run. Only what the catalog declares is checked: the JSON
    /// object shape and required fields. Unknown tools (MCP) are left to the registry,
    /// which rejects names it cannot dispatch.
    static func schemaProblem(in call: ToolCall) -> String? {
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "аргументы не JSON-объект"
        }
        guard let definition = ToolRegistry.definitions.first(where: { $0.name == call.name }) else {
            return nil
        }
        guard let required = definition.parameters["required"]?.value as? [String] else {
            return nil
        }
        let missing = required.filter { object[$0] == nil }
        return missing.isEmpty ? nil : "нет обязательных полей: \(missing.joined(separator: ", "))"
    }
}
