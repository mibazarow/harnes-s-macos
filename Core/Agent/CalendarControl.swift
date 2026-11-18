import EventKit
import Foundation

/// R26.1: calendar and reminders through EventKit. Dates are ISO-8601 only — natural
/// language belongs to the model, and a second date parser with a locale is a bug farm.
enum CalendarDates {
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    static func text(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// R26.1: free windows are computed here, not by the model. An event ending exactly when
/// another starts is not a conflict, and that edge is the one models get wrong.
enum FreeBusy {
    struct Window: Equatable, Sendable {
        let start: Date
        let end: Date
    }

    struct Interval: Equatable, Sendable {
        let start: Date
        let end: Date
    }

    static func freeSlots(
        busy: [Interval], within range: Interval, duration: TimeInterval
    ) -> [Window] {
        guard duration > 0, range.end > range.start else { return [] }
        let sorted = busy
            .filter { $0.end > range.start && $0.start < range.end }
            .sorted { $0.start < $1.start }
        var windows: [Window] = []
        var cursor = range.start
        for interval in sorted {
            if interval.start.timeIntervalSince(cursor) >= duration {
                windows.append(Window(start: cursor, end: interval.start))
            }
            if interval.end > cursor { cursor = interval.end }
        }
        if range.end.timeIntervalSince(cursor) >= duration {
            windows.append(Window(start: cursor, end: range.end))
        }
        return windows
    }
}

/// Events this app created, so `delete_event` can never touch somebody else's entry.
enum CreatedEvents {
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<String>?
        var override: URL?

        func url() -> URL {
            lock.lock(); defer { lock.unlock() }
            return override ?? AppPaths.configDirectory.appendingPathComponent("created-events.json")
        }

        func load() -> Set<String> {
            lock.lock()
            if let ids { lock.unlock(); return ids }
            lock.unlock()
            let url = self.url()
            let decoded = (try? Data(contentsOf: url))
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            let set = Set(decoded)
            lock.lock(); ids = set; lock.unlock()
            return set
        }

        func add(_ id: String) {
            var all = load()
            all.insert(id)
            persist(all)
        }

        func remove(_ id: String) {
            var all = load()
            all.remove(id)
            persist(all)
        }

        func contains(_ id: String) -> Bool { load().contains(id) }

        private func persist(_ ids: Set<String>) {
            lock.lock(); self.ids = ids; lock.unlock()
            let url = self.url()
            try? AppPaths.ensureDirectory(url.deletingLastPathComponent())
            guard let data = try? JSONEncoder().encode(ids.sorted()) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private static let store = Store()

    static func setStorageOverride(_ url: URL?) { store.override = url }
    static func remember(_ id: String) { store.add(id) }
    static func forget(_ id: String) { store.remove(id) }
    static func contains(_ id: String) -> Bool { store.contains(id) }
}

/// One EventKit store per call: the app has no long-lived calendar state, and a store
/// built per call never keeps a stale authorization.
enum CalendarControl {
    static func authorization(_ entity: EKEntityType) -> String {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess: return "full"
        case .writeOnly: return "write_only"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }

    static func requestAccess(_ entity: EKEntityType) async -> Bool {
        let store = EKEventStore()
        if entity == .event {
            return (try? await store.requestFullAccessToEvents()) ?? false
        }
        return (try? await store.requestFullAccessToReminders()) ?? false
    }

    static func eventLines(_ events: [EKEvent], limit: Int) -> [String] {
        events.prefix(limit).map { event in
            var line = "\(event.eventIdentifier ?? "-") \(CalendarDates.text(event.startDate))"
            line += "–\(CalendarDates.text(event.endDate)) \(event.title ?? "(без названия)")"
            line += " calendar=\(event.calendar?.title ?? "?")"
            if event.isAllDay { line += " all_day" }
            if let location = event.location, !location.isEmpty { line += " at=\(location)" }
            if let notes = event.notes, !notes.isEmpty {
                line += " notes=\(notes.prefix(500))"
            }
            return line
        }
    }

    /// Reminders cross the continuation as plain values: `EKReminder` is not Sendable.
    struct ReminderInfo: Sendable {
        let id: String
        let title: String
        let due: Date?
        let completed: Bool
    }

    static func reminders(_ store: EKEventStore, calendars: [EKCalendar]?) async -> [ReminderInfo] {
        let predicate = store.predicateForReminders(in: calendars)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let infos = (reminders ?? []).map {
                    ReminderInfo(
                        id: $0.calendarItemIdentifier,
                        title: $0.title ?? "(без названия)",
                        due: $0.dueDateComponents?.date,
                        completed: $0.isCompleted
                    )
                }
                continuation.resume(returning: infos)
            }
        }
    }
}
