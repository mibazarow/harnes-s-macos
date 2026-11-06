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
            indexWithoutVectors(files: files, progress: &progress)
            progress.finished = true
            return progress
        }

        for file in files {
            if Task.isCancelled { break }
            progress.current = file.path
            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                let chunks = Self.chunk(text, size: chunkSize)
                guard !chunks.isEmpty else {
                    progress.skipped += 1
                    continue
                }

                let vectors = try await embeddings.embed(chunks)

                for (index, chunk) in chunks.enumerated() {
                    let item = try await memory.add(
                        chunk,
                        kind: "code",
                        scope: "workspace",
                        tags: [file.lastPathComponent],
                        source: file.path
                    )

                    if index < vectors.count {
                        try await embeddings.store(
                            refKind: "memory",
                            refID: String(item.id),
                            vector: vectors[index]
                        )
                    }
                    progress.chunksIndexed += 1
                }

                progress.filesIndexed += 1
            } catch {
                progress.skipped += 1
            }
        }

        progress.finished = true
        progress.current = ""
        return progress
    }

    private func indexWithoutVectors(files: [URL], progress: inout Progress) {
        for file in files {
            if Task.isCancelled { break }
            progress.current = file.path
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                progress.skipped += 1
                continue
            }

            let chunks = Self.chunk(text, size: chunkSize)
            for chunk in chunks {
                _ = try? database.queue.write { db in
                    try db.execute(sql: """
                        INSERT INTO memory (scope, content, kind, tags, source, created_at, updated_at)
                        VALUES ('workspace', ?, 'code', '[]', ?, ?, ?)
                        """, arguments: [chunk, file.path, Timestamps.now(), Timestamps.now()])
                }
                progress.chunksIndexed += 1
            }
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

    static func chunk(_ text: String, size: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 20 else { return [] }
        guard trimmed.count > size else { return [trimmed] }

        var chunks: [String] = []
        var start = trimmed.startIndex

        while start < trimmed.endIndex {
            let end = trimmed.index(start, offsetBy: size, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            chunks.append(String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            start = end
        }

        return chunks.filter { $0.count > 20 }
    }
}