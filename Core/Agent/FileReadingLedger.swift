import Foundation

/// Remembers which files the agent has actually read, and when.
///
/// Mirrors the file contract of the reference agents: a file must be read before it is
/// rewritten, and a file that changed on disk after that read must be read again.
/// Without this, `edit_file` by marker is a blind write — the exact failure mode that
/// silently corrupts files — and two agents editing the same workspace overwrite each
/// other. `fs_write append` is exempt: appending cannot destroy content.
actor FileReadingLedger {
    struct Stamp: Sendable, Equatable {
        let modified: Date
        let size: Int
    }

    enum Status: Sendable, Equatable {
        case fresh
        case neverRead
        case changed
    }

    private var stamps: [String: Stamp] = [:]

    func note(_ url: URL) {
        stamps[url.standardizedFileURL.path] = Self.stamp(of: url)
    }

    func forget(_ url: URL) {
        stamps.removeValue(forKey: url.standardizedFileURL.path)
    }

    func status(of url: URL) -> Status {
        let key = url.standardizedFileURL.path
        guard let stamp = stamps[key] else { return .neverRead }
        guard let current = Self.stamp(of: url) else { return .changed }
        return current == stamp ? .fresh : .changed
    }

    func reset() {
        stamps.removeAll()
    }

    private static func stamp(of url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else { return nil }
        return Stamp(modified: modified, size: size.intValue)
    }
}
