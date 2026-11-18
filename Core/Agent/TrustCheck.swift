import Foundation

/// R30.7: "did the user actually ask for this?"
///
/// `confirm: true` answers "the model says a person agreed". This answers a different
/// question: whether the action is covered by something the user really wrote. The model
/// only picks the source and quotes it; the quote is verified here, against the text in
/// the transcript, so a hallucinated citation is a refusal.
enum TrustBasis: String, Sendable {
    case read
    case message
    case rule
    case approved
    case autopilot
}

struct TrustCandidate: Equatable, Sendable {
    /// `current` for this turn's message, `m1`… for earlier user messages.
    let id: String
    let text: String
}

struct TrustCheckRequest: Sendable {
    let action: String
    let summary: String
    let candidates: [TrustCandidate]
    let instructions: [String]
}

enum TrustAnswer: Equatable, Sendable {
    case yes(sourceID: String?, quote: String)
    case no
    case other
}

/// One answer from the checker. `nil` from `ask` means "no opinion", which the interceptor
/// treats as a refusal: a broken checker must fail closed.
protocol TrustAsking: Sendable {
    func ask(_ request: TrustCheckRequest) async throws -> TrustAnswer?
}

enum TrustCheck {
    /// NFKD, diacritics dropped, typographic quotes straightened, whitespace collapsed,
    /// lowercased. Ported from `plain()` in the reference implementation on purpose:
    /// two normalisations that disagree are worse than one imperfect one.
    static func plain(_ text: String) -> String {
        var value = text.decomposedStringWithCompatibilityMapping
        value = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let map: [Character: Character] = [
            "“": "\"", "”": "\"", "«": "\"", "»": "\"", "„": "\"",
            "‘": "'", "’": "'", "‚": "'", "—": "-", "–": "-"
        ]
        value = String(value.map { map[$0] ?? $0 })
        return value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func verify(quote: String, in text: String) -> Bool {
        let needle = plain(quote)
        guard needle.count >= 2 else { return false }
        return plain(text).contains(needle)
    }

    /// The quote the journal stores: short enough to read, long enough to identify.
    static func clamp(_ quote: String) -> String {
        String(quote.prefix(300))
    }
}

/// What a mutating call needs before it runs.
enum TrustRequirement: Equatable, Sendable {
    /// Checked against the conversation; the model picks the source.
    case standard
    /// Must always be backed by the user's own words, whatever the budget says.
    case quote
}

enum TrustPolicy {
    /// Which calls are consequential. GUI input (`ui`, `mouse`, `keyboard`) is left out on
    /// purpose: R18 already guards it, and clicking a button in the app the user named is
    /// the job, not a side effect. `bash` is checked only for `sudo`: every command would
    /// burn the turn's budget in a few steps.
    static func requirement(tool: String, args: [String: Any], workspace: URL) -> TrustRequirement? {
        let action = (args["action"] as? String)?.lowercased() ?? ""
        switch tool {
        // R30.7: `memory_add` and `secret_save` are direct commands, not guesses the
        // agent made up. The quote requirement belongs to `bash`/writes, not to
        // "remember this": checking them rejected the very request that asked for them.
        case "schedule_add", "schedule_remove", "settings":
            return .quote
        case "secret_get":
            return (args["reveal"] as? Bool) == true ? .quote : nil
        case "workspace":
            return action == "set" ? .quote : nil
        case "bash":
            let command = (args["command"] as? String) ?? ""
            return command.range(of: #"(^|[\s;&|])sudo\s"#, options: .regularExpression) != nil
                ? .quote : nil
        case "fs_write", "edit_file", "apply_patch", "fs_copy", "fs_move", "fs_mkdir":
            let path = (args["path"] as? String) ?? (args["target"] as? String) ?? ""
            return path.isEmpty || isOutside(path, workspace: workspace) ? .quote : nil
        case "git":
            return ["push", "merge", "reset", "rebase"].contains(action) ? .standard : nil
        case "process":
            return action == "run" ? .standard : nil
        case "power":
            return action == "status" ? nil : .standard
        case "display":
            return action == "list" ? nil : .standard
        case "calendar":
            return ["create_event", "update_event", "delete_event",
                    "create_reminder", "complete_reminder"].contains(action) ? .standard : nil
        case "contacts":
            return ["create", "update"].contains(action) ? .standard : nil
        case "share":
            return action == "send" ? .standard : nil
        case "launchd":
            return action == "tm_start" ? .standard : nil
        case "network":
            if action == "proxy", args["value"] != nil { return .standard }
            if action == "vpn", (args["value"] as? String)?.lowercased() == "restart" {
                return .standard
            }
            if action == "wifi", args["ssid"] != nil || args["value"] != nil { return .standard }
            return nil
        case "files":
            return ["eject", "dmg_mount", "dmg_unmount", "dmg_eject"].contains(action)
                ? .standard : nil
        case "apps":
            return action == "quit" ? .standard : nil
        case "observe":
            return action == "replay" ? .standard : nil
        case "skill_learn":
            return ["save", "patch"].contains(action) ? .standard : nil
        default:
            return nil
        }
    }

    /// A path outside the workspace is a write into somebody else's folder: that always
    /// needs the user's words, not just a conversation check.
    static func isOutside(_ raw: String, workspace: URL) -> Bool {
        let expanded = (raw as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded).standardizedFileURL
            : workspace.appendingPathComponent(expanded).standardizedFileURL
        let root = workspace.standardizedFileURL.path
        return !(url.path == root || url.path.hasPrefix(root + "/"))
    }
}

/// Turn-scoped bookkeeping: one model call per action, twenty per turn, and the decision
/// the journal reads afterwards.
final class TrustCheckSession: @unchecked Sendable {
    struct Decision: Equatable, Sendable {
        let basis: TrustBasis
        let quote: String
    }

    enum Reservation: Equatable, Sendable {
        case call
        case reuse(Decision)
        case exhausted
    }

    static let maxCallsPerTurn = 20

    private let lock = NSLock()
    /// Verdicts keyed by tool + arguments: `settings appearance` twice is one question,
    /// two `memory_add` calls about different records are two.
    private var decisions: [String: Decision] = [:]
    /// Last verdict per tool, for the journal which reads by tool name.
    private var lastByTool: [String: Decision] = [:]

    func beginTurn() {
        lock.lock(); defer { lock.unlock() }
        decisions.removeAll()
        lastByTool.removeAll()
    }

    /// R30.7: an attempt is not a verdict. The old `calls[tool]` counter made the second
    /// call after one refusal look like an exhausted quota; now a missing verdict simply
    /// asks again, and the quota counts unique verdicts.
    func reserve(tool: String, key: String) -> Reservation {
        lock.lock(); defer { lock.unlock() }
        if let decision = decisions[key] { return .reuse(decision) }
        guard decisions.count < Self.maxCallsPerTurn else { return .exhausted }
        return .call
    }

    func record(tool: String, key: String, basis: TrustBasis, quote: String) {
        lock.lock(); defer { lock.unlock() }
        let decision = Decision(basis: basis, quote: TrustCheck.clamp(quote))
        decisions[key] = decision
        lastByTool[tool] = decision
    }

    func decision(tool: String) -> Decision? {
        lock.lock(); defer { lock.unlock() }
        return lastByTool[tool]
    }

    func callsUsed() -> Int {
        lock.lock(); defer { lock.unlock() }
        return decisions.count
    }

    /// Stable key for the turn cache: sorted arguments, so the same call is the same key.
    static func cacheKey(tool: String, args: [String: Any]) -> String {
        let body = args.keys.sorted().map { key in
            "\(key)=\(describe(args[key]))"
        }.joined(separator: "&")
        return "\(tool)|\(body)"
    }

    private static func describe(_ value: Any?) -> String {
        switch value {
        case let string as String: return string
        case let bool as Bool: return bool ? "true" : "false"
        case let number as NSNumber: return number.stringValue
        case let array as [Any]: return array.map { describe($0) }.joined(separator: ",")
        default: return String(describing: value ?? "")
        }
    }
}

/// The gate. It runs after the existing `confirm` arguments, never instead of them.
struct TrustCheckInterceptor: ToolInterceptor {
    let name = "trust_check"
    /// A model call does not fit the chain's 2 s default; the chain still fails closed.
    var timeoutOverride: Duration? { .seconds(10) }

    let session: TrustCheckSession
    let candidates: [TrustCandidate]
    let instructions: [String]
    let autopilot: Bool
    let asker: any TrustAsking

    func beforeCall(_ call: ToolCall, context: ToolCallContext) async throws -> ToolVerdict {
        let args = ToolRegistry.decodeArguments(call.arguments) ?? [:]
        guard TrustPolicy.requirement(
            tool: call.name, args: args, workspace: context.workspace
        ) != nil else { return .allow }

        let confirmed = (args["confirm"] as? Bool) == true
        let key = TrustCheckSession.cacheKey(tool: call.name, args: args)

        // R30.7: autopilot is the user's standing "go ahead". Asking a second model on
        // every action added latency and produced refusals the user had already allowed.
        if autopilot {
            session.record(tool: call.name, key: key, basis: .autopilot, quote: "")
            return .allow
        }

        switch session.reserve(tool: call.name, key: key) {
        case .reuse:
            // One verdict per action per turn: the first answer stands, and it was only
            // recorded when it passed.
            return .allow
        case .exhausted:
            return Self.refuse(.quota, confirmed: confirmed)
        case .call:
            break
        }

        let request = TrustCheckRequest(
            action: call.name,
            summary: Self.summary(tool: call.name, args: args),
            candidates: candidates,
            instructions: instructions
        )
        guard let answer = try await asker.ask(request) else {
            return Self.refuse(.unanswered, confirmed: confirmed)
        }

        switch answer {
        case .no, .other:
            return Self.refuse(.notCovered, confirmed: confirmed)
        case .yes(let sourceID, let quote):
            guard let source = Self.source(id: sourceID, quote: quote, in: candidates),
                  TrustCheck.verify(quote: quote, in: source.text) else {
                return Self.refuse(
                    .notCovered, confirmed: confirmed,
                    detail: "цитата не найдена в словах пользователя"
                )
            }
            let basis: TrustBasis = source.id == "current" ? .message : .rule
            session.record(tool: call.name, key: key, basis: basis, quote: quote)
            return .allow
        }
    }

    /// Three different events used to share one sentence. Only "the user did not ask"
    /// gets the `confirm` hint; a timeout says "try again", and an exhausted quota says
    /// the check will not run again this turn.
    enum Refusal {
        case notCovered
        case unanswered
        case quota
    }

    /// `confirm` is the last resort, not a bypass: without it the call is refused with a
    /// reason the model can act on.
    static func refuse(_ kind: Refusal, confirmed: Bool, detail: String? = nil) -> ToolVerdict {
        if confirmed {
            return .allow
        }
        switch kind {
        case .notCovered:
            let head = detail ?? "действие не покрыто тем, что пользователь просил"
            return .deny(
                reason: "\(head); нужен confirm: true, если пользователь действительно просил",
                guidance: "Не повторяй действие вслепую. Сформулируй, что именно собираешься "
                    + "сделать, и повтори с confirm: true только после ясной просьбы пользователя."
            )
        case .unanswered:
            return .deny(
                reason: "проверка не ответила за 10 с, повтори",
                guidance: "Это не отказ по существу: повтори тот же вызов. Если проверка "
                    + "молчит снова, остановись и спроси пользователя."
            )
        case .quota:
            return .deny(
                reason: "проверка на этот инструмент в этом ходу уже не спрашивается: "
                    + "исчерпан лимит \(TrustCheckSession.maxCallsPerTurn) вердиктов",
                guidance: "Останови действие и переформулируй задачу: новый ход начнёт "
                    + "новый счёт проверок."
            )
        }
    }

    /// No source id: the server searches every candidate itself, so a model that stays
    /// silent about the source cannot dodge the quote check.
    static func source(id: String?, quote: String, in candidates: [TrustCandidate]) -> TrustCandidate? {
        if let id {
            return candidates.first { $0.id == id }
        }
        return candidates.first { TrustCheck.verify(quote: quote, in: $0.text) }
    }

    static func summary(tool: String, args: [String: Any]) -> String {
        var parts: [String] = []
        for key in ["action", "command", "path", "url", "title", "value", "text", "ssid"] {
            if let value = args[key] as? String, !value.isEmpty {
                parts.append("\(key)=\(String(value.prefix(120)))")
            }
        }
        return parts.isEmpty ? tool : "\(tool) \(parts.joined(separator: " "))"
    }
}

/// The model call. Kept small on purpose: the checker answers one yes/no question and
/// must not see the whole conversation.
struct TrustModelAsker: TrustAsking {
    let provider: ProviderModel
    let model: String
    var client = ProviderClient()

    static let systemPrompt = """
    You decide whether a proposed action is covered by what the user actually asked for.

    Rules:
    - Answer only about the given action and the given quotes from the user.
    - "yes" only for unconditional agreement that covers this exact action.
    - "other" for anything conditional ("yes, but only if..."), partial, or a question.
    - "no" when the user did not ask for it.
    - Quote the user's words verbatim, in the original language, without paraphrase.
    - Reply with one JSON object and nothing else:
      {"decision":"yes|no|other","source_id":"<id>","quote":"<verbatim>"}
    """

    static func userPrompt(_ request: TrustCheckRequest) -> String {
        var lines = ["ACTION: \(request.summary)", ""]
        if !request.instructions.isEmpty {
            lines.append("STANDING INSTRUCTIONS:")
            lines.append(contentsOf: request.instructions.prefix(10).map { "- \($0)" })
            lines.append("")
        }
        lines.append("USER MESSAGES:")
        for candidate in request.candidates {
            lines.append("[\(candidate.id)] \(String(candidate.text.prefix(2_000)))")
        }
        return lines.joined(separator: "\n")
    }

    func ask(_ request: TrustCheckRequest) async throws -> TrustAnswer? {
        let messages = [
            ProviderMessage(role: .system, content: Self.systemPrompt),
            ProviderMessage(role: .user, content: Self.userPrompt(request))
        ]
        let stream = client.stream(provider: provider, model: model, messages: messages)
        var text = ""
        for try await event in stream {
            if case .delta(let chunk) = event { text += chunk }
        }
        return TrustModelAsker.parse(text)
    }

    /// Tolerant on purpose: a model that wraps JSON in prose still gets read, and anything
    /// unparsable becomes `other`, which is a refusal.
    static func parse(_ raw: String) -> TrustAnswer? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let decision = (object["decision"] as? String)?.lowercased() else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .other
        }
        switch decision {
        case "yes":
            let quote = (object["quote"] as? String) ?? ""
            guard !quote.isEmpty else { return .other }
            return .yes(sourceID: object["source_id"] as? String, quote: quote)
        case "no":
            return .no
        default:
            return .other
        }
    }
}
