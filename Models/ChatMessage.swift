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
    var summary: String
    var isError: Bool
    var isRunning: Bool
    var imagePath: String?

    init(name: String, summary: String, isError: Bool = false, isRunning: Bool = true, imagePath: String? = nil) {
        self.id = UUID()
        self.name = name
        self.summary = summary
        self.isError = isError
        self.isRunning = isRunning
        self.imagePath = imagePath
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

    static let historyOutputLimit = 4_000
    static let historyArgumentLimit = 8_000
    /// A string value longer than this is a payload, not a parameter, and gets replaced.
    private static let argumentValueLimit = 2_000

    init(callID: String, name: String, arguments: String, output: String, isError: Bool) {
        self.callID = callID
        self.name = name
        self.arguments = Self.sanitizedArguments(arguments)
        self.output = output.count > Self.historyOutputLimit
            ? String(output.prefix(Self.historyOutputLimit))
                + "\n…[обрезано \(output.count - Self.historyOutputLimit) символов при сохранении]"
            : output
        self.isError = isError
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
            return "[обрезано при сохранении: \(string.count) символов]"
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
    static func trimToDisplayLimit(_ messages: [ChatMessage], limit: Int) -> Int {
        guard limit > 0, messages.count > limit else { return 0 }
        var groups = 0
        var index = messages.count - 1
        while index >= 0 {
            let start: Int
            if messages[index].isToolOnly {
                var beginning = index
                while beginning > 0, messages[beginning - 1].isToolOnly { beginning -= 1 }
                start = beginning
            } else {
                start = index
            }
            groups += 1
            if groups > limit { return index + 1 }
            index = start - 1
        }
        return 0
    }
}