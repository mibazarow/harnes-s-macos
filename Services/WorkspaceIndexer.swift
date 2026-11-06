import Foundation
import GRDB

/// Walks a folder, chunks text files, and stores them as searchable memory
/// (FTS + embeddings when a backend is available).
actor WorkspaceIndexer {
    struct Progress: Sendable {
        var filesSeen = 0
        var filesIndexed = 0
        var chunksIndexed = 0
        var skipped = 0
        var current = ""
        var finished = false
        var error: String?
    }

    private let database: AppDatabase
    private let embeddings: EmbeddingsService?
    private let memory: MemoryService

    private let textExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cpp", "hpp", "js", "jsx", "ts", "tsx",
        "py", "rb", "go", "rs", "php", "java", "kt", "sql", "sh", "zsh",
        "md", "txt", "json", "yml", "yaml", "toml", "ini", "cfg", "css", "scss",
        "html", "xml", "vue", "svelte"
    ]

    private let skipDirectories: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", "vendor",
        ".venv", "venv", "Pods", "DerivedData", ".next", "target", "__pycache__"
    ]

    private let maxFileSize = 512 * 1024
    private let chunkSize = 1_200
    /// Overlap keeps a function or a sentence from being cut in half at the seam.
    private let chunkOverlap = 200

    init(database: AppDatabase, memory: MemoryService, embeddings: EmbeddingsService?) {
        self.database = database
        self.memory = memory
        self.embeddings = embeddings
    }

    func index(root: URL) async -> Progress {
        var progress = Progress()

        let files = collectFiles(root: root)
        progress.filesSeen = files.count

        let hasEmbeddings: Bool
        if let embeddings {
            if embeddings.hasLocalModel {
                hasEmbeddings = true
            } else {
                hasEmbeddings = (try? await embeddings.embed(["probe"])) != nil
            }
        } else {
            hasEmbeddings = false
        }

        guard hasEmbeddings, let embeddings else {
            progress.error = "эмбеддинги недоступны — индексирую только текст"
            await indexWithoutVectors(files: files, progress: &progress)
            progress.finished = true
            return progress
        }

        for file in files {
            if Task.isCancelled { break }
            progress.current = file.path

            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                let fileHash = MemoryService.hash(text)

                // A file that did not change since the last run is skipped whole.
                if try isUnchanged(path: file.path, hash: fileHash) {
                    progress.skipped += 1
                    continue
                }

                let chunks = Self.chunk(text, size: chunkSize, overlap: chunkOverlap)
                guard !chunks.isEmpty else {
                    progress.skipped += 1
                    continue
                }

                // Identical chunks reuse their existing vector; only new text costs a
                // model pass, and those go in one batch.
                var vectors: [EmbeddingsService.Vector?] = []
                var pending: [Int] = []
                var pendingTexts: [String] = []
                var hashes: [String] = []

                for (index, chunk) in chunks.enumerated() {
                    let hash = MemoryService.hash(chunk)
                    hashes.append(hash)
                    if let existing = try? await embeddings.vector(refKind: "memory", textHash: hash) {
                        vectors.append(existing)
                    } else {
                        vectors.append(nil)
                        pending.append(index)
                        pendingTexts.append(chunk)
                    }
                }

                if !pendingTexts.isEmpty {
                    let computed = try await embeddings.embed(pendingTexts)
                    for (offset, index) in pending.enumerated() where offset < computed.count {
                        vectors[index] = computed[offset]
                    }
                }

                for (index, chunk) in chunks.enumerated() {
                    let item = try await memory.add(
                        chunk,
                        kind: "code",
                        scope: "workspace",
                        tags: [file.lastPathComponent],
                        source: file.path,
                        contentHash: hashes[index]
                    )

                    if let vector = vectors[index] {
                        try? await embeddings.store(
                            refKind: "memory",
                            refID: String(item.id),
                            vector: vector,
                            textHash: hashes[index]
                        )
                    }
                    progress.chunksIndexed += 1
                }

                try record(path: file.path, hash: fileHash)
                progress.filesIndexed += 1
            } catch {
                progress.skipped += 1
            }
        }

        progress.finished = true
        progress.current = ""
        return progress
    }

    private func isUnchanged(path: String, hash: String) throws -> Bool {
        try database.queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT hash FROM indexed_files WHERE path = ?",
                arguments: [path]
            ) == hash
        }
    }

    private func record(path: String, hash: String) throws {
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO indexed_files (path, hash, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET hash = excluded.hash, updated_at = excluded.updated_at
                """, arguments: [path, hash, Timestamps.now()])
        }
    }

    private func indexWithoutVectors(files: [URL], progress: inout Progress) async {
        for file in files {
            if Task.isCancelled { break }
            progress.current = file.path
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                progress.skipped += 1
                continue
            }

            let fileHash = MemoryService.hash(text)
            if (try? isUnchanged(path: file.path, hash: fileHash)) == true {
                progress.skipped += 1
                continue
            }

            let chunks = Self.chunk(text, size: chunkSize, overlap: chunkOverlap)
            for chunk in chunks {
                // Same path as the embedding case: hash dedup keeps a re-index from
                // piling up copies of the same chunk.
                _ = try? await memory.add(
                    chunk,
                    kind: "code",
                    scope: "workspace",
                    tags: [file.lastPathComponent],
                    source: file.path,
                    contentHash: MemoryService.hash(chunk)
                )
                progress.chunksIndexed += 1
            }
            try? record(path: file.path, hash: fileHash)
            progress.filesIndexed += 1
        }
        progress.current = ""
    }

    private func collectFiles(root: URL) -> [URL] {
        var results: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }

            if values.isDirectory == true {
                if skipDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true else { continue }
            guard textExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard (values.fileSize ?? 0) <= maxFileSize else { continue }
            results.append(url)

            if results.count >= 3_000 { break }
        }

        return results
    }

    static func chunk(_ text: String, size: Int, overlap: Int = 0) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 20 else { return [] }
        guard trimmed.count > size else { return [trimmed] }

        var chunks: [String] = []
        var start = trimmed.startIndex

        while start < trimmed.endIndex {
            var end = trimmed.index(start, offsetBy: size, limitedBy: trimmed.endIndex) ?? trimmed.endIndex

            // Prefer a paragraph or line break, then a space, in the last fifth of the
            // window, so a chunk rarely ends mid-word or mid-statement.
            if end < trimmed.endIndex {
                let window = trimmed.index(start, offsetBy: size * 4 / 5, limitedBy: end) ?? start
                if let line = trimmed[window..<end].lastIndex(where: { $0 == "\n" }) {
                    end = trimmed.index(after: line)
                } else if let space = trimmed[window..<end].lastIndex(where: { $0 == " " }) {
                    end = space
                }
            }

            let piece = trimmed[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.count > 20 { chunks.append(piece) }
            guard end < trimmed.endIndex else { break }

            let next = trimmed.index(end, offsetBy: -min(overlap, size / 2), limitedBy: trimmed.startIndex) ?? end
            // Always advance, otherwise an odd boundary loops forever.
            start = next > start ? next : end
        }

        return chunks
    }
}
