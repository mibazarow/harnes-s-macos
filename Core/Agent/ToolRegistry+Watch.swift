import CoreServices
import Foundation

/// R25.12: wait for the file system instead of polling it.
///
/// "Build finished?" is currently a loop of `fs_list` calls, each one a round trip and a
/// guess about the right sleep. FSEvents is the kernel-side answer: subscribe, wait for
/// the window, return what actually changed.
enum FileWatcher {
    struct Event {
        let path: String
        let flags: FSEventStreamEventFlags
    }

    /// Collects events for `duration` and returns them. Runs the stream on the calling
    /// thread's run loop: the whole point is to block until something happens or the
    /// window closes, and a background loop would need its own coordination for nothing.
    static func collect(
        paths: [String],
        duration: TimeInterval,
        since: FSEventStreamEventId,
        shouldStop: @Sendable () -> Bool = { false }
    ) -> [Event] {
        guard !paths.isEmpty else { return [] }

        let box = EventBox()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // The C callback hands the paths over as a raw pointer to an array of C strings.
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<EventBox>.fromOpaque(info).takeUnretainedValue()
            let pointers = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let flagValues = UnsafeBufferPointer(start: flags, count: count)
            for index in 0..<count {
                let path = String(cString: pointers[index])
                box.append(Event(path: path, flags: flagValues[index]))
            }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            since,
            0.2,                       // latency: batching window, not a poll interval
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return [] }

        defer {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        guard FSEventStreamStart(stream) else { return [] }

        // R32.3: a five-minute watch must not outlive a stop. The run loop is entered in
        // short slices so the token is read while waiting, not after the window closes.
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            if shouldStop() { break }
            CFRunLoopRunInMode(.defaultMode, min(0.2, deadline.timeIntervalSinceNow), false)
        }
        return box.snapshot()
    }

    /// FSEvents flags are a bitmask; the model needs the verbs, not the numbers.
    static func describe(_ flags: FSEventStreamEventFlags) -> [String] {
        var words: [String] = []
        if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 { words.append("создан") }
        if flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 { words.append("удалён") }
        if flags & UInt32(kFSEventStreamEventFlagItemModified) != 0 { words.append("изменён") }
        if flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 { words.append("переименован") }
        if flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 { words.append("каталог") }
        if flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 { words.append("файл") }
        return words.isEmpty ? ["событие"] : words
    }

    /// FSEvents reports the same path repeatedly inside one batch (metadata plus content).
    /// Keeping only the first occurrence of each path keeps the answer readable.
    static func dedupe(_ events: [Event]) -> [Event] {
        var seen = Set<String>()
        var result: [Event] = []
        for event in events where !seen.contains(event.path) {
            seen.insert(event.path)
            result.append(event)
        }
        return result
    }

    final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [Event] = []

        func append(_ event: Event) {
            lock.lock(); defer { lock.unlock() }
            // A build touches thousands of files; the answer is an example, not a ledger.
            if events.count < 500 { events.append(event) }
        }

        func snapshot() -> [Event] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
    }
}

extension ToolRegistry {
    func watchTool(_ args: [String: Any]) -> ToolResult {
        let raw = args["path"] as? String ?? "."
        let candidates = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let paths = candidates.filter { !$0.isEmpty }.map { resolve($0).path }
        guard !paths.isEmpty else { return .fail("path обязателен") }

        for path in paths where !FileManager.default.fileExists(atPath: path) {
            return .fail("Путь не существует: \(path)")
        }

        let duration = Double(min(max(Self.int(args, "duration_ms") ?? 5_000, 500), 120_000)) / 1_000
        let limit = min(max(Self.int(args, "limit") ?? 30, 1), 500)
        let started = Date()
        let signal = cancel
        let events = FileWatcher.dedupe(
            FileWatcher.collect(
                paths: paths,
                duration: duration,
                since: FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                shouldStop: { signal.current != nil }
            )
        )
        if signal.current != nil {
            return .fail("Наблюдение прервано стопом.")
        }

        guard !events.isEmpty else {
            return .ok("За \(Int(duration)) с в \(paths.joined(separator: ", ")) ничего не изменилось.")
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        let lines = events.prefix(limit).map { event in
            FileWatcher.describe(event.flags).joined(separator: " ") + ": " + event.path
        }
        var header = "\(events.count) изменений за \(elapsed) мс"
        if events.count > limit { header += ", показано \(limit)" }
        return .ok(header + "\n" + lines.joined(separator: "\n"))
    }
}
