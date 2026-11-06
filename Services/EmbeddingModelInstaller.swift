import Foundation
import Observation

/// Downloads the EmbeddingGemma 2 model into the data directory after a fresh
/// install. The weights are not shipped inside the `.app`: the bundle stays small,
/// and `~/HARNES_S_DATA` remains the single folder to move between machines.
///
/// The download starts at launch and is never on the critical path. Until it is
/// done semantic search degrades to FTS instead of blocking a tool call.
@MainActor
@Observable
final class EmbeddingModelInstaller {
    enum Phase: Equatable {
        case checking
        case downloading(received: Int64, total: Int64)
        case ready
        case failed(String)

        var isDownloading: Bool {
            if case .downloading = self { true } else { false }
        }
    }

    private(set) var phase: Phase
    private var running: Task<Void, Error>?
    private var lastReportedPercent = -1

    private let directory: URL

    init(directory: URL = AppPaths.embeddingModelDirectory) {
        self.directory = directory
        phase = EmbeddingModelDownload.isInstalled(in: directory) ? .ready : .checking
    }

    var isReady: Bool {
        if case .ready = phase { true } else { false }
    }

    /// Starts the download once, in the background. Safe to call on every launch.
    func startIfNeeded() {
        guard !isReady, running == nil else { return }
        Task { try? await ensureInstalled() }
    }

    /// Downloads anything missing. Concurrent callers share one task.
    func ensureInstalled() async throws {
        if let running {
            try await running.value
            return
        }
        if EmbeddingModelDownload.isInstalled(in: directory) {
            phase = .ready
            return
        }

        let directory = self.directory
        let alreadyOnDisk = EmbeddingModelDownload.bytesOnDisk(in: directory)
        lastReportedPercent = -1
        phase = .downloading(received: alreadyOnDisk, total: EmbeddingModelDownload.totalBytes)

        let task = Task.detached(priority: .utility) {
            try await EmbeddingModelDownload.install(into: directory) { received in
                Task { @MainActor in
                    self.report(received)
                }
            }
        }
        running = task

        do {
            try await task.value
            running = nil
            phase = .ready
        } catch {
            running = nil
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    private func report(_ received: Int64) {
        let total = EmbeddingModelDownload.totalBytes
        guard total > 0 else { return }
        let percent = Int(Double(min(received, total)) / Double(total) * 100)
        guard percent != lastReportedPercent else { return }
        lastReportedPercent = percent
        phase = .downloading(received: min(received, total), total: total)
    }
}

/// Pure file and network side of the install, kept off the main actor.
enum EmbeddingModelDownload {
    struct RemoteFile: Sendable {
        /// Path inside the Hugging Face repository.
        let remote: String
        /// File name inside `models/embeddinggemma-2/`.
        let local: String
        /// Size of the pinned revision; a fresh download must match it exactly.
        let expectedSize: Int64
        /// Anything at least this big counts as already installed, so an older but
        /// working export survives without a pointless 300 MB re-download.
        let minimumSize: Int64
    }

    /// Pinned so a future repository change cannot silently swap the weights.
    static let repository = "onnx-community/embeddinggemma-300m-ONNX"
    static let revision = "5090578d9565bb06545b4552f76e6bc2c93e4a66"

    /// Small files first, the big weights last: the model only counts as installed
    /// once the last file lands, so a half-finished download never looks ready.
    static let files: [RemoteFile] = [
        RemoteFile(
            remote: "tokenizer_config.json",
            local: "tokenizer_config.json",
            expectedSize: 1_156_830,
            minimumSize: 1_000
        ),
        RemoteFile(
            remote: "tokenizer.json",
            local: "tokenizer.json",
            expectedSize: 20_323_312,
            minimumSize: 10_000_000
        ),
        RemoteFile(
            remote: "onnx/model_quantized.onnx",
            local: "model_quantized.onnx",
            expectedSize: 567_874,
            minimumSize: 100_000
        ),
        RemoteFile(
            remote: "onnx/model_quantized.onnx_data",
            local: "model_quantized.onnx_data",
            expectedSize: 308_890_624,
            minimumSize: 100_000_000
        )
    ]

    static var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.expectedSize }
    }

    static func isInstalled(in directory: URL) -> Bool {
        files.allSatisfy { isPresent($0, in: directory) }
    }

    static func bytesOnDisk(in directory: URL) -> Int64 {
        files.reduce(0) { total, file in
            let path = directory.appendingPathComponent(file.local).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let size = attributes?[.size] as? Int64 ?? 0
            return total + min(size, file.expectedSize)
        }
    }

    private static func isPresent(_ file: RemoteFile, in directory: URL) -> Bool {
        let path = directory.appendingPathComponent(file.local).path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else {
            return false
        }
        return size >= file.minimumSize
    }

    /// Downloads every missing file. `alreadyOnDisk` seeds the progress counter.
    static func install(
        into directory: URL,
        alreadyOnDisk: Int64? = nil,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try AppPaths.ensureDirectory(directory)

        let counter = ByteCounter(alreadyOnDisk ?? bytesOnDisk(in: directory))
        onProgress(counter.value)

        for file in files where !isPresent(file, in: directory) {
            try await download(file, into: directory) { delta in
                onProgress(counter.add(delta))
            }
        }

        guard isInstalled(in: directory) else {
            throw InstallerError.incomplete
        }
    }

    private static func download(
        _ file: RemoteFile,
        into directory: URL,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        guard let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.remote)") else {
            throw InstallerError.badURL(file.remote)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        let (temporary, response) = try await URLSession.shared.download(for: request, delegate: delegate)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallerError.http(status: http.statusCode, file: file.local)
        }

        let destination = directory.appendingPathComponent(file.local)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let size = attributes[.size] as? Int64 ?? 0
        guard size == file.expectedSize else {
            try? FileManager.default.removeItem(at: destination)
            throw InstallerError.sizeMismatch(file: file.local, expected: file.expectedSize, got: size)
        }
    }
}

/// Running byte total shared by the download loop and the URLSession delegate.
private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64

    init(_ start: Int64) {
        total = start
    }

    var value: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    func add(_ delta: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        total += delta
        return total
    }
}

/// Reports bytes as they arrive. `URLSession` calls it on its own queue, so the
/// closure only forwards a number and never touches installer state directly.
private final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(bytesWritten)
    }
}

enum InstallerError: LocalizedError {
    case badURL(String)
    case http(status: Int, file: String)
    case sizeMismatch(file: String, expected: Int64, got: Int64)
    case incomplete

    var errorDescription: String? {
        switch self {
        case .badURL(let file):
            "Некорректный адрес загрузки \(file)."
        case .http(let status, let file):
            "Не удалось скачать \(file): HTTP \(status)."
        case .sizeMismatch(let file, let expected, let got):
            "Файл \(file) скачался не полностью: \(got) из \(expected) байт."
        case .incomplete:
            "Модель эмбеддингов скачана не полностью."
        }
    }
}
