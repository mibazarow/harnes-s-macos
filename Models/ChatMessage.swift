import Foundation
import AppKit

struct ChatAttachment: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable {
        case image
        case text
        case folder
        case other
    }

    let id: UUID
    let name: String
    let path: String
    let kind: Kind
    let byteCount: Int
    let data: Data
    let thumbnail: Data?

    private init(id: UUID, name: String, path: String, kind: Kind, byteCount: Int, data: Data, thumbnail: Data?) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.byteCount = byteCount
        self.data = data
        self.thumbnail = thumbnail
    }

    /// Drops the payload but keeps the name, path and thumbnail. Used once the turn is
    /// over: the bytes were only needed to build that one request, and holding them
    /// keeps whole files in memory for the lifetime of the session.
    func released() -> ChatAttachment {
        ChatAttachment(id: id, name: name, path: path, kind: kind, byteCount: byteCount, data: Data(), thumbnail: thumbnail)
    }

    init?(url: URL) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let size = values?.fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }

        let ext = url.pathExtension.lowercased()
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
        let textExtensions: Set<String> = [
            "txt", "md", "swift", "js", "ts", "tsx", "jsx", "json", "yml", "yaml",
            "py", "rb", "go", "rs", "c", "h", "cpp", "hpp", "css", "html", "xml",
            "sh", "zsh", "sql", "toml", "ini", "cfg", "log", "csv"
        ]

        let kind: Kind
        if imageExtensions.contains(ext) {
            kind = .image
        } else if textExtensions.contains(ext) {
            kind = .text
        } else {
            kind = .other
        }

        self.id = UUID()
        self.name = url.lastPathComponent
        self.path = url.path
        self.kind = kind
        self.byteCount = data.count
        self.data = data
        self.thumbnail = kind == .image ? Self.thumbnail(from: data) : nil
    }

    /// A directory the user picked as the context for this turn.
    init(folder url: URL) {
        self.id = UUID()
        self.name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        self.path = url.path
        self.kind = .folder
        self.byteCount = 0
        self.data = Data()
        self.thumbnail = nil
    }

    init(name: String, path: String, kind: Kind, data: Data, thumbnail: Data?) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.kind = kind
        self.byteCount = data.count
        self.data = data
        self.thumbnail = thumbnail
    }

    var text: String? {
        guard kind == .text else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var summary: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(name) · \(formatter.string(fromByteCount: Int64(byteCount)))"
    }

    private static func thumbnail(from data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let maxSide: CGFloat = 320
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(maxSide / size.width, maxSide / size.height, 1)
        let target = NSSize(width: size.width * scale, height: size.height * scale)

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

struct ToolTrace: Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    /// Canonical result value as the tool reported it. Written once when the call
    /// finishes; the line on screen is derived from this and `arguments`, so a live
    /// frame and a replayed one render identically.
    var summary: String
    var isError: Bool
    var isRunning: Bool
    var imagePath: String?
    /// Provider call id, when known. Lets a replayed trace line up with its exchange.
    var callID: String
    /// Truncated JSON the model sent, when known. Not shown by default.
    var arguments: String
    /// Result length before the history cut, when known.
    var originalLength: Int?

    init(
        name: String,
        summary: String,
        isError: Bool = false,
        isRunning: Bool = true,
        imagePath: String? = nil,
        callID: String = "",
        arguments: String = "",
        originalLength: Int? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.summary = summary
        self.isError = isError
        self.isRunning = isRunning
        self.imagePath = imagePath
        self.callID = callID
        self.arguments = arguments
        self.originalLength = originalLength
    }

    /// Pure: depends only on the trace data, never on store state or wall-clock.
    static func summaryText(for trace: ToolTrace) -> String {
        let value = trace.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { return value }
        // S8: a `task` call carries the child's whole brief in `prompt`. The user wants
        // the result, not the brief: show the title only.
        if trace.name == "task" {
            return taskLine(from: trace.arguments)
        }
        let call = preview(of: trace.arguments)
        return call.isEmpty ? "…" : call
    }

    /// `Подагент · <title>`, never the prompt body.
    static func taskLine(from arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Подагент"
        }
        if let target = object["interrupt"] as? String, !target.isEmpty {
            return "Подагент · остановка \(target)"
        }
        let title = (object["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Подагент" : "Подагент · \(title)"
    }

    /// One short line of the arguments, for the frame before the result arrives.
    static func preview(of arguments: String) -> String {
        let flat = arguments
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty, flat != "{}" else { return "" }
        return flat.count > 80 ? String(flat.prefix(80)) + "…" : flat
    }
}

/// One completed tool call, as the provider needs to see it on the next request.
struct ToolExchange: Sendable, Equatable {
    let callID: String
    let name: String
    /// Truncated, but still valid JSON.
    ///
    /// Arguments replay inside `assistant(tool_calls)` on every later turn, so a
    /// 200 KB `apply_patch` payload would otherwise be a permanent tax on the request.
    /// Cutting the raw string would leave invalid JSON and make the provider reject the
    /// replayed turn, so long string values are replaced in place and the object is
    /// re-encoded.
    let arguments: String
    /// Truncated: history needs the gist, not the whole file. The current turn already
    /// sends up to 30 000 characters; older turns get less.
    let output: String
    let isError: Bool
    /// Length before the 4 000-character cut, so a stub can say how much was really
    /// there. Nil on rows written before the field existed.
    let originalLength: Int
    /// A status line ("готово", "ok") with no data in it: safe to leave out of the
    /// request first, because nothing refers to its content.
    let isTrivial: Bool

    static let historyOutputLimit = 4_000
    /// A string value longer than this is a payload, not a parameter, and gets replaced.
    private static let argumentValueLimit = 2_000

    init(
        callID: String,
        name: String,
        arguments: String,
        output: String,
        isError: Bool,
        originalLength: Int? = nil,
        isTrivial: Bool? = nil
    ) {
        self.callID = callID
        self.name = name
        self.arguments = Self.sanitizedArguments(arguments)
        self.originalLength = originalLength ?? output.count
        self.output = output.count > Self.historyOutputLimit
            ? String(output.prefix(Self.historyOutputLimit))
                + "\n" + TruncationGuard.placeholder(length: output.count - Self.historyOutputLimit)
            : output
        self.isError = isError
        self.isTrivial = isTrivial ?? Self.looksTrivial(output)
    }

    /// One short line that only reports success carries no content worth replaying.
    static func looksTrivial(_ output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 200 else { return false }
        guard !trimmed.contains("\n"), !trimmed.contains("/") else { return false }
        guard trimmed.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        let lower = trimmed.lowercased()
        return ["готово", "ok", "done", "success", "успешно", "записано", "выполнено", "вывода нет"]
            .contains { lower.contains($0) }
    }

    static func sanitizedArguments(_ raw: String) -> String {
        guard raw.count > argumentValueLimit else { return raw }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let shortened = truncatePayloads(in: object) as? [String: Any],
              let out = try? JSONSerialization.data(withJSONObject: shortened, options: [.sortedKeys]),
              let text = String(data: out, encoding: .utf8) else {
            // Unparseable: leave it alone rather than replace valid arguments with
            // something the provider would reject.
            return raw
        }
        return text.count < raw.count ? text : raw
    }

    private static func truncatePayloads(in value: Any) -> Any {
        switch value {
        case let string as String:
            guard string.count > argumentValueLimit else { return string }
            // Unmistakable on purpose: this string is replayed inside tool_calls on
            // every later turn, and a plausible-looking "[обрезано: N]" was copied back
            // into a later fs_write, which wrote the placeholder into the file.
            return TruncationGuard.placeholder(length: string.count)
        case let array as [Any]:
            return array.map(truncatePayloads(in:))
        case let dictionary as [String: Any]:
            return dictionary.mapValues(truncatePayloads(in:))
        default:
            return value
        }
    }
}

struct ChatMessage: Identifiable, Sendable, Equatable {
    enum Role: String, Sendable {
        case user
        case assistant
        case system

        var label: String {
            switch self {
            case .user: "вы"
            case .assistant: "HARNES-S"
            case .system: "система"
            }
        }
    }

    enum State: String, Sendable {
        /// Waiting for the current turn to finish. Not sent to the model yet.
        case queued
        /// Removed from the queue by Esc. Kept on screen so the text is not lost.
        case cancelled
        case streaming
        case complete
    }

    let id: UUID
    let role: Role
    var text: String
    var reasoning: String?
    var attachments: [ChatAttachment]
    var tools: [ToolTrace]
    /// Tool calls and their results, kept so the next request can replay them.
    ///
    /// Without this the model saw only its own prose on the next turn: no record of
    /// what it read, what it changed, or what failed. That is the main reason it kept
    /// redoing work it had already done, which reads as looping.
    var exchanges: [ToolExchange] = []
    /// Honesty warning shown under the answer. Deliberately not part of `text`: it
    /// must not be sent back to the model as if the assistant had said it.
    var warning: String?
    let date: Date
    var state: State

    init(
        role: Role,
        text: String,
        reasoning: String? = nil,
        attachments: [ChatAttachment] = [],
        tools: [ToolTrace] = [],
        exchanges: [ToolExchange] = [],
        warning: String? = nil,
        date: Date = .now,
        state: State = .complete
    ) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.attachments = attachments
        self.tools = tools
        self.exchanges = exchanges
        self.warning = warning
        self.date = date
        self.state = state
    }
}

extension ChatMessage {
    /// A step that only called tools: nothing the user reads, only traces.
    var isToolOnly: Bool {
        role == .assistant
            && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !tools.isEmpty
            && state != .queued
    }

    var isClosingAnswer: Bool {
        role == .assistant && state == .complete && tools.isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A system row the user never sees: the note the store leaves after it pruned
    /// finished tool output at a task boundary.
    ///
    /// It is still a `.system` message in storage, so the reason for a shrunken request
    /// stays recoverable. What changed is the display: the note showed up after almost
    /// every task, always said the same thing, and carried nothing but the word count of
    /// a housekeeping step. Pruning itself still happens — only the line is filtered out.
    var isPruneNotice: Bool {
        role == .system
            && text.hasPrefix("Результаты инструментов убраны из запроса:")
    }

    /// S1: a background child's report is a `.system` row that starts with this marker.
    /// `.system` never reaches the provider, so the report cannot leak into the parent's
    /// context; the model reads it through `subagent_status`.
    static func subagentReportMarker(_ id: String) -> String {
        "subagentReport(\(id))"
    }

    var subagentReportID: String? {
        guard role == .system, text.hasPrefix("subagentReport("),
              let close = text.firstIndex(of: ")") else { return nil }
        let start = text.index(text.startIndex, offsetBy: "subagentReport(".count)
        return String(text[start..<close])
    }

    /// Collapses runs of tool-only steps into one message for display.
    ///
    /// Every model step gets its own message, so ten sequential `bash` calls arrived as
    /// ten bubbles with a single trace each — the run read as ten unrelated answers.
    /// They belong together: one run, one list of traces, one timestamp.
    ///
    /// This is display only. Storage and the replay sent to the model are untouched:
    /// the model still sees each step separately, with its own result in between. Merging
    /// in storage would have turned sequential, dependent calls into one parallel batch,
    /// which is a different and misleading shape.
    static func groupedForDisplay(_ messages: [ChatMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        var run: ChatMessage?

        for message in messages {
            guard message.isToolOnly else {
                if message.isClosingAnswer, let accumulated = run,
                   accumulated.state == .complete {
                    var answer = message
                    answer.tools = accumulated.tools
                    answer.reasoning = [accumulated.reasoning, message.reasoning]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                    answer.warning = message.warning ?? accumulated.warning
                    result.append(answer)
                    run = nil
                    continue
                }
                if let run { result.append(run) }
                run = nil
                result.append(message)
                continue
            }

            guard var accumulating = run else {
                run = message
                continue
            }

            accumulating.tools += message.tools
            if let extra = message.reasoning, !extra.isEmpty {
                let existing = accumulating.reasoning ?? ""
                accumulating.reasoning = existing.isEmpty ? extra : existing + "\n\n" + extra
            }
            accumulating.warning = accumulating.warning ?? message.warning
            // The newest state wins: a run still streaming must keep showing as such.
            accumulating.state = message.state
            run = accumulating
        }

        if let run { result.append(run) }
        return result
    }

    /// Number of leading messages to drop so the grouped view keeps at most `limit`
    /// bubbles.
    ///
    /// A long run produces one message per step, so trimming by raw count pushed a
    /// normal conversation out of the window after two tasks. The user sees groups, so
    /// the window should be counted in groups; runs are dropped whole.
    /// `slack` makes the trim hysteretic. Trimming to exactly the cap on every turn
    /// removed the first bubble almost every time, which shifted every `ForEach` id and
    /// made SwiftUI rebuild the whole transcript right after a tool batch — the second
    /// jank source from the UI analysis. Now the window may grow `slack` groups past the
    /// cap before it is cut back to the cap, so the rebuild happens once per ~`slack`
    /// turns instead of every turn.
    static func trimToDisplayLimit(_ messages: [ChatMessage], limit: Int, slack: Int = 0) -> Int {
        guard limit > 0, messages.count > limit else { return 0 }
        let slack = max(slack, 0)
        if cutIndex(messages, keepGroups: limit + slack) == 0 { return 0 }
        return cutIndex(messages, keepGroups: limit)
    }

    /// Leading messages to drop so at most `keepGroups` display bubbles remain;
    /// `0` when they already fit.
    static func cutIndex(_ messages: [ChatMessage], keepGroups: Int) -> Int {
        guard keepGroups > 0 else { return messages.count }
        var groups = 0
        var index = messages.count - 1
        while index >= 0 {
            let start: Int
            if messages[index].isClosingAnswer, index > 0,
               messages[index - 1].isToolOnly, messages[index - 1].state == .complete {
                var beginning = index - 1
                while beginning > 0, messages[beginning - 1].isToolOnly { beginning -= 1 }
                start = beginning
            } else if messages[index].isToolOnly {
                var beginning = index
                while beginning > 0, messages[beginning - 1].isToolOnly { beginning -= 1 }
                start = beginning
            } else {
                start = index
            }
            groups += 1
            if groups > keepGroups { return index + 1 }
            index = start - 1
        }
        return 0
    }
}
