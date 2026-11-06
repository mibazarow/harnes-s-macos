import Foundation

/// Runs the provider/tool loop. Emits UI-level events; owns no presentation state.
struct AgentLoop: Sendable {
    let provider: ProviderModel
    let model: String
    let registry: ToolRegistry
    let client = ProviderClient()

    /// Unbounded by default: the loop runs until the model stops calling tools
    /// or the user cancels with Esc. No artificial step ceiling.
    var maxSteps: Int? = nil

    enum Event: Sendable {
        case delta(String)
        case reasoning(String)
        case toolStarted(name: String, summary: String)
        case toolFinished(name: String, summary: String, isError: Bool, imagePath: String?)
        case completed
    }

    func run(history: [ProviderMessage]) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var messages = history
                    let schemas = await registry.schemas()

                    var step = 0
                    var loopGuard = LoopGuard()
                    while true {
                        if Task.isCancelled { break }

                        var streamedText = ""
                        var streamedReasoning = ""
                        var calls: [ToolCall] = []

                        let stream = client.stream(
                            provider: provider,
                            model: model,
                            messages: messages,
                            tools: schemas
                        )

                        for try await event in stream {
                            if Task.isCancelled { break }
                            switch event {
                            case .delta(let text):
                                streamedText += text
                                continuation.yield(.delta(text))
                            case .reasoning(let text):
                                streamedReasoning += text
                                continuation.yield(.reasoning(text))
                            case .toolCall(let call):
                                calls.append(call)
                            case .finished:
                                break
                            }
                        }

                        if Task.isCancelled { break }

                        if calls.isEmpty {
                            continuation.yield(.completed)
                            continuation.finish()
                            return
                        }

                        var assistant = ProviderMessage(
                            role: .assistant,
                            content: streamedText,
                            toolCalls: calls
                        )
                        messages.append(assistant)

                        if !streamedText.isEmpty {
                            continuation.yield(.delta("\n\n"))
                        }

                        var outcome: [(name: String, isError: Bool, output: String)] = []

                        for call in calls {
                            if Task.isCancelled { break }
                            let summary = Self.summary(for: call)
                            continuation.yield(.toolStarted(name: call.name, summary: summary))

                            let result = await registry.execute(call)
                            outcome.append((call.name, result.isError, result.output))
                            let imagePath = Self.imagePath(from: result.output)

                            continuation.yield(.toolFinished(
                                name: call.name,
                                summary: result.isError ? Self.firstLine(result.output) : summary,
                                isError: result.isError,
                                imagePath: imagePath
                            ))

                            let toolMessage = ProviderMessage(
                                role: .tool,
                                content: String(result.output.prefix(30_000)),
                                toolCallID: call.id
                            )
                            messages.append(toolMessage)
                        }

                        // Progress-aware anti-loop: same calls returning the same
                        // results means we are stuck, not that we are working.
                        let stuck = loopGuard.record(
                            callSignature: LoopGuard.callSignature(calls),
                            progressSignature: LoopGuard.progressSignature(outcome)
                        )
                        if stuck {
                            continuation.yield(.delta(
                                "\n\n_Остановился: одни и те же вызовы дают тот же результат — дальше без изменений не продвинусь._"
                            ))
                            break
                        }

                        if let maxSteps, step >= maxSteps - 1 {
                            continuation.yield(.delta("\n\n_Остановлено: достигнут явный лимит шагов._"))
                            break
                        }
                        assistant.content = streamedText
                        step += 1
                    }

                    continuation.yield(.completed)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func summary(for call: ToolCall) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        switch call.name {
        case "bash":
            return String((args["command"] as? String ?? "").prefix(90))
        case "fs_read", "fs_write", "edit_file", "ocr":
            return (args["path"] as? String) ?? call.name
        case "fs_list", "fs_glob", "fs_grep":
            return (args["path"] as? String) ?? (args["pattern"] as? String) ?? call.name
        case "webfetch", "browser":
            return (args["url"] as? String) ?? (args["action"] as? String) ?? call.name
        case "websearch":
            return (args["query"] as? String) ?? call.name
        case "memory_search", "secret_search":
            return (args["query"] as? String) ?? call.name
        case "secret_get", "secret_save":
            return (args["alias"] as? String) ?? call.name
        case "skill_install":
            return (args["source"] as? String) ?? call.name
        default:
            return call.name
        }
    }

    private static func imagePath(from output: String) -> String? {
        guard let range = output.range(of: "Скриншот: ") else { return nil }
        let path = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasSuffix(".png") ? path : nil
    }

    private static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n").first ?? "")
    }
}