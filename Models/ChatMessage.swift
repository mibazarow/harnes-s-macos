import Foundation
import AppKit

struct ChatAttachment: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable {
        case image
        case text
        case other
    }

    let id: UUID
    let name: String
    let path: String
    let kind: Kind
    let byteCount: Int
    let data: Data
    let thumbnail: Data?

    var isImage: Bool { kind == .image }

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

struct ChatMessage: Identifiable, Sendable {
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
        case streaming
        case complete
    }

    let id: UUID
    let role: Role
    var text: String
    var reasoning: String?
    var attachments: [ChatAttachment]
    var tools: [ToolTrace]
    let date: Date
    var state: State

    init(
        role: Role,
        text: String,
        reasoning: String? = nil,
        attachments: [ChatAttachment] = [],
        tools: [ToolTrace] = [],
        date: Date = .now,
        state: State = .complete
    ) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.attachments = attachments
        self.tools = tools
        self.date = date
        self.state = state
    }
}