import XCTest
@testable import Harness

final class EmbeddingInstallerTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("embedding-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Sparse files: a 300 MB name with no 300 MB of disk writes.
    private func touch(_ file: EmbeddingModelDownload.RemoteFile, size: Int64, in directory: URL) throws {
        let url = directory.appendingPathComponent(file.local)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
    }

    func testInstalledOnlyWhenEveryFileIsPlausible() throws {
        let directory = try makeDirectory()
        XCTAssertFalse(EmbeddingModelDownload.isInstalled(in: directory))

        for file in EmbeddingModelDownload.files {
            try touch(file, size: file.minimumSize, in: directory)
        }
        XCTAssertTrue(EmbeddingModelDownload.isInstalled(in: directory))

        // A truncated weights file must not count as installed.
        let weights = try XCTUnwrap(EmbeddingModelDownload.files.last)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(weights.local))
        XCTAssertFalse(EmbeddingModelDownload.isInstalled(in: directory))
    }

    func testOlderSmallerExportStillCountsAsInstalled() throws {
        let directory = try makeDirectory()
        for file in EmbeddingModelDownload.files {
            // The previously shipped export is a few megabytes smaller but valid.
            try touch(file, size: file.minimumSize, in: directory)
        }
        XCTAssertTrue(EmbeddingModelDownload.isInstalled(in: directory))
    }

    func testBytesOnDiskCapsAtExpectedSize() throws {
        let directory = try makeDirectory()
        let tokenizer = try XCTUnwrap(EmbeddingModelDownload.files.first)
        try touch(tokenizer, size: tokenizer.expectedSize * 2, in: directory)
        XCTAssertEqual(EmbeddingModelDownload.bytesOnDisk(in: directory), tokenizer.expectedSize)
    }

    @MainActor
    func testInstallerReportsReadyForCompleteDirectory() throws {
        let directory = try makeDirectory()
        let installer = EmbeddingModelInstaller(directory: directory)
        XCTAssertEqual(installer.phase, .checking)

        for file in EmbeddingModelDownload.files {
            try touch(file, size: file.minimumSize, in: directory)
        }
        let installed = EmbeddingModelInstaller(directory: directory)
        XCTAssertEqual(installed.phase, .ready)
        XCTAssertTrue(installed.isReady)
    }

    func testPinnedFilesCoverTheFourModelArtifacts() {
        let names = Set(EmbeddingModelDownload.files.map(\.local))
        XCTAssertEqual(
            names,
            ["model_quantized.onnx", "model_quantized.onnx_data", "tokenizer.json", "tokenizer_config.json"]
        )
        XCTAssertGreaterThan(EmbeddingModelDownload.totalBytes, 300_000_000)
    }

    /// Real download from Hugging Face. Off by default: it moves ~330 MB.
    func testLiveDownloadProducesEmbeddings() async throws {
        guard ProcessInfo.processInfo.environment["HARNESS_LIVE_MODEL_DOWNLOAD"] == "1" else {
            throw XCTSkip("задай HARNESS_LIVE_MODEL_DOWNLOAD=1, чтобы скачать модель из сети")
        }

        let directory = try makeDirectory()
        try await EmbeddingModelDownload.install(into: directory) { _ in }

        let embedder = LocalEmbedder(modelDirectory: directory)
        XCTAssertTrue(embedder.isAvailableOnDisk)
        let vector = try await embedder.embed("пароль от почтового ящика")
        XCTAssertEqual(vector.count, 768)
    }
}
