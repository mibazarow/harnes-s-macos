import CryptoKit
import Foundation

/// Stops the third identical tool call that already returned the same result twice.
///
/// `LoopGuard` in the agent loop compares whole batches and can only see a cycle after
/// the batch has run. This guard sits at the tool boundary: the same name and arguments
/// with the same output twice means the next call cannot change anything, so it is
/// refused before it costs time or touches the machine. If the second result differs,
/// the run is making progress and the call is allowed (I34).
final class ToolRepeatGuard: @unchecked Sendable {
    private struct Entry {
        let key: String
        let resultHash: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    /// Enough to cover a small cycle; the loop itself is `LoopGuard`'s job.
    private let limit = 12

    func shouldRefuse(name: String, arguments: String) -> Bool {
        let key = Self.key(name: name, arguments: arguments)
        lock.lock()
        defer { lock.unlock() }
        let matches = entries.filter { $0.key == key }
        let pair = Array(matches.suffix(2))
        guard pair.count == 2 else { return false }
        return pair[0].resultHash == pair[1].resultHash
    }

    func record(name: String, arguments: String, output: String) {
        let entry = Entry(
            key: Self.key(name: name, arguments: arguments),
            resultHash: Self.hash(output)
        )
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    static let refusal = "Тот же вызов с теми же аргументами уже дважды вернул тот же "
        + "результат. Повтор ничего не изменит — поменяй подход или аргументы."

    private static func key(name: String, arguments: String) -> String {
        hash(name + "\u{0}" + arguments)
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
