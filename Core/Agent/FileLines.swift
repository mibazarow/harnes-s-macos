import Foundation

/// Windowed line reading that never loads a whole file into memory.
///
/// `fs_read` used to call `String(contentsOf:)` and split every line, then hand the
/// whole thing to the model. Large files cost memory and, worse, the run-output budget
/// could later replace the result with a bare stub — the model saw "вывод убран"
/// instead of the file it had just read. Reading only the requested window and saying
/// exactly what was cut keeps every reply small and honest.
enum FileLines {
    struct Window {
        /// 1-based line numbers with their text.
        let lines: [(number: Int, text: String)]
        /// `nil` when counting the whole file was skipped on purpose (very large files).
        let total: Int?
        let first: Int
        let last: Int
        /// True when at least one line was shortened because it was enormous.
        let longLineCut: Bool

        var isEmpty: Bool { lines.isEmpty }
    }

    /// A single line longer than this is a payload (minified JS, base64 blob). The line
    /// is kept short; counting the rest of the file still happens.
    static let maxLineChars = 4_000

    /// Files above this size are not counted line by line: the reply says "из N" only
    /// when counting is cheap enough to stay in milliseconds.
    static let countingLimit = 16 * 1024 * 1024

    /// Hard refusal: above this reading is not a tool call, it is an incident.
    static let maxFileSize = 512 * 1024 * 1024

    static func isBinary(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let probe = (try? handle.read(upToCount: 8_192)) ?? Data()
        return probe.contains(0)
    }

    static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }

    /// Reads lines `[offset, offset+limit)` when `offset > 0`, or the last `|offset|`
    /// lines when `offset < 0`. One pass over the file, bounded memory.
    static func read(_ url: URL, offset: Int, limit: Int) throws -> Window {
        let size = fileSize(url)
        guard size <= maxFileSize else {
            throw NSError(domain: "Harness", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Файл слишком большой (\(size) байт): читай частями через bash (sed -n) или doc_read."
            ])
        }

        let countTotal = size <= countingLimit
        // Negative offset means "the last N lines"; `limit` does not extend that.
        let wanted = offset < 0 ? min(-offset, 2_000) : 0
        var ring: [(Int, String)] = []

        var collected: [(number: Int, text: String)] = []
        var lineNo = 0
        var longLineCut = false
        var pending = Data()
        pending.reserveCapacity(4_096)

        let start = offset > 0 ? offset : 1
        let end = offset > 0 ? offset + limit - 1 : Int.max

        func emit(_ bytes: Data) {
            lineNo += 1
            var text = String(decoding: bytes, as: UTF8.self)
            if text.count > maxLineChars {
                text = String(text.prefix(maxLineChars)) + "…[строка обрезана]"
                longLineCut = true
            }
            if offset < 0 {
                ring.append((lineNo, text))
                if ring.count > wanted {
                    ring.removeFirst(ring.count - wanted)
                }
            } else if lineNo >= start, lineNo <= end {
                collected.append((lineNo, text))
            }
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        while true {
            let chunk = try handle.read(upToCount: 262_144) ?? Data()
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { raw in
                var lineStart = 0
                for index in raw.indices where raw[index] == 0x0A {
                    pending.append(contentsOf: raw[lineStart..<index])
                    emit(pending)
                    pending.removeAll(keepingCapacity: true)
                    lineStart = index + 1
                }
                if lineStart < raw.count {
                    pending.append(contentsOf: raw[lineStart..<raw.count])
                }
            }
            // Nothing after the window is needed when the total is unknown and the
            // window is already collected: stop instead of scanning a 400 MB log.
            if !countTotal, offset > 0, lineNo > end { break }
        }
        if !pending.isEmpty {
            emit(pending)
        }

        if offset < 0 {
            collected = ring
        }

        let first = collected.first?.0 ?? max(offset, 0)
        let last = collected.last?.0 ?? first
        return Window(
            lines: collected,
            total: countTotal ? lineNo : nil,
            first: first,
            last: last,
            longLineCut: longLineCut
        )
    }
}
