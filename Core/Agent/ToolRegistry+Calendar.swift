import EventKit
import Foundation

extension ToolRegistry {
    /// R26.1: events and reminders. Read needs full access; write-only is reported as
    /// exactly that and never promised as reading. Deleting only touches events this
    /// tool created.
    func calendarTool(_ args: [String: Any]) async -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? "events"
        let store = EKEventStore()

        if action == "calendars" {
            let eventCalendars = store.calendars(for: .event).map {
                "\($0.title) id=\($0.calendarIdentifier) source=\($0.source.title)"
            }
            let reminderCalendars = store.calendars(for: .reminder).map {
                "\($0.title) id=\($0.calendarIdentifier) source=\($0.source.title)"
            }
            return .ok("События (\(CalendarControl.authorization(.event))):\n"
                + (eventCalendars.isEmpty ? "  нет" : eventCalendars.joined(separator: "\n"))
                + "\nНапоминания (\(CalendarControl.authorization(.reminder))):\n"
                + (reminderCalendars.isEmpty ? "  нет" : reminderCalendars.joined(separator: "\n")))
        }

        switch action {
        case "events":
            guard CalendarControl.authorization(.event) == "full" else {
                return .fail("Нет полного доступа к календарю (сейчас "
                    + "\(CalendarControl.authorization(.event))). Запись без чтения "
                    + "не позволяет показать события; выдай полный доступ в панели.")
            }
            let now = Date()
            let from = CalendarDates.parse(args["from"] as? String)
                ?? now.addingTimeInterval(-86_400)
            let to = CalendarDates.parse(args["to"] as? String)
                ?? now.addingTimeInterval(7 * 86_400)
            let calendars = Self.calendarFilter(store, names: args["calendar"] as? String, entity: .event)
            let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
            let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
            let limit = min(max(Self.int(args, "limit") ?? 50, 1), 500)
            let lines = CalendarControl.eventLines(events, limit: limit)
            return .ok(lines.isEmpty
                ? "Событий с \(CalendarDates.text(from)) по \(CalendarDates.text(to)) нет."
                : "\(events.count) событий:\n" + lines.joined(separator: "\n"))

        case "create_event":
            guard CalendarControl.authorization(.event) != "denied",
                  CalendarControl.authorization(.event) != "restricted" else {
                return .fail("Календарь запрещён TCC. Выдай доступ в панели Календари.")
            }
            guard let title = args["title"] as? String, !title.isEmpty else {
                return .fail("title обязателен")
            }
            guard let start = CalendarDates.parse(args["start"] as? String) else {
                return .fail("start обязателен в ISO-8601, например 2026-11-19T10:00:00+03:00")
            }
            let duration = Double(Self.int(args, "duration") ?? 60) * 60
            let end = CalendarDates.parse(args["end"] as? String)
                ?? start.addingTimeInterval(duration)
            guard end > start else { return .fail("end должен быть позже start.") }

            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = start
            event.endDate = end
            event.isAllDay = Self.bool(args, "all_day") ?? false
            event.location = args["location"] as? String
            event.notes = args["notes"] as? String
            event.calendar = Self.calendarFilter(store, names: args["calendar"] as? String, entity: .event)?.first
                ?? store.defaultCalendarForNewEvents
            if let minutes = Self.int(args, "alarm_minutes") {
                event.addAlarm(EKAlarm(relativeOffset: -Double(minutes) * 60))
            }
            if let rule = Self.recurrence(args["recurrence"] as? String) {
                event.addRecurrenceRule(rule)
            }
            do {
                try store.save(event, span: .thisEvent)
            } catch {
                return .fail("Событие не сохранено: \(error.localizedDescription). "
                    + "Проверь доступ к календарю (сейчас \(CalendarControl.authorization(.event))).")
            }
            if let id = event.eventIdentifier { CreatedEvents.remember(id) }
            return .ok("Событие создано: \(event.eventIdentifier ?? "-") "
                + "\(CalendarDates.text(start))–\(CalendarDates.text(end)) «\(title)»")

        case "update_event":
            guard let id = args["id"] as? String, !id.isEmpty else { return .fail("id обязателен") }
            guard let event = store.event(withIdentifier: id) else {
                return .fail("Событие \(id) не найдено.")
            }
            if let title = args["title"] as? String { event.title = title }
            if let start = CalendarDates.parse(args["start"] as? String) { event.startDate = start }
            if let end = CalendarDates.parse(args["end"] as? String) { event.endDate = end }
            if let location = args["location"] as? String { event.location = location }
            if let notes = args["notes"] as? String { event.notes = notes }
            do {
                try store.save(event, span: .thisEvent)
            } catch {
                return .fail("Событие не обновлено: \(error.localizedDescription)")
            }
            return .ok("Событие \(id) обновлено.")

        case "delete_event":
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("delete_event требует confirm: true: удаление не отменяется.")
            }
            guard let id = args["id"] as? String, !id.isEmpty else { return .fail("id обязателен") }
            guard CreatedEvents.contains(id) else {
                return .fail("Событие \(id) создано не этим инструментом — не удаляю. "
                    + "Удалить можно только то, что агент создал сам.")
            }
            guard let event = store.event(withIdentifier: id) else {
                CreatedEvents.forget(id)
                return .fail("Событие \(id) уже удалено.")
            }
            do {
                try store.remove(event, span: .thisEvent)
                CreatedEvents.forget(id)
            } catch {
                return .fail("Событие не удалено: \(error.localizedDescription)")
            }
            return .ok("Событие \(id) удалено.")

        case "free_busy":
            let now = Date()
            let from = CalendarDates.parse(args["from"] as? String) ?? now
            let to = CalendarDates.parse(args["to"] as? String) ?? now.addingTimeInterval(7 * 86_400)
            let minutes = Self.int(args, "duration") ?? 60
            let calendars = Self.calendarFilter(store, names: args["calendar"] as? String, entity: .event)
            let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
            let busy = store.events(matching: predicate).map {
                FreeBusy.Interval(start: $0.startDate, end: $0.endDate)
            }
            let slots = FreeBusy.freeSlots(
                busy: busy,
                within: FreeBusy.Interval(start: from, end: to),
                duration: Double(minutes) * 60
            )
            let limit = min(max(Self.int(args, "limit") ?? 10, 1), 50)
            let lines = slots.prefix(limit).map {
                "\(CalendarDates.text($0.start)) – \(CalendarDates.text($0.end))"
            }
            return .ok(lines.isEmpty
                ? "Свободного окна на \(minutes) мин нет."
                : "Свободно (\(minutes) мин):\n" + lines.joined(separator: "\n"))

        case "reminders":
            guard CalendarControl.authorization(.reminder) == "full" else {
                return .fail("Нет полного доступа к напоминаниям (сейчас "
                    + "\(CalendarControl.authorization(.reminder))).")
            }
            let calendars = Self.calendarFilter(store, names: args["calendar"] as? String, entity: .reminder)
            let reminders = await CalendarControl.reminders(store, calendars: calendars)
            let limit = min(max(Self.int(args, "limit") ?? 50, 1), 200)
            let lines = reminders
                .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                .prefix(limit)
                .map { reminder -> String in
                    var line = "\(reminder.id) \(reminder.title)"
                    if let due = reminder.due {
                        line += " due=\(CalendarDates.text(due))"
                    }
                    if reminder.completed { line += " done" }
                    return line
                }
            return .ok(lines.isEmpty ? "Напоминаний нет." : lines.joined(separator: "\n"))

        case "create_reminder":
            guard let title = args["title"] as? String, !title.isEmpty else {
                return .fail("title обязателен")
            }
            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.calendar = Self.calendarFilter(store, names: args["calendar"] as? String, entity: .reminder)?.first
                ?? store.defaultCalendarForNewReminders()
            reminder.notes = args["notes"] as? String
            if let due = CalendarDates.parse(args["due"] as? String) {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: due
                )
            }
            do {
                try store.save(reminder, commit: true)
            } catch {
                return .fail("Напоминание не создано: \(error.localizedDescription)")
            }
            return .ok("Напоминание создано: \(reminder.calendarItemIdentifier) «\(title)»")

        case "complete_reminder":
            guard let id = args["id"] as? String, !id.isEmpty else { return .fail("id обязателен") }
            guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
                return .fail("Напоминание \(id) не найдено.")
            }
            item.isCompleted = true
            do {
                try store.save(item, commit: true)
            } catch {
                return .fail("Не удалось закрыть напоминание: \(error.localizedDescription)")
            }
            return .ok("Напоминание \(id) закрыто.")

        default:
            return .fail("action: calendars | events | create_event | update_event | delete_event "
                + "| free_busy | reminders | create_reminder | complete_reminder")
        }
    }

    /// Calendar by title substring, or all calendars when the name is absent.
    static func calendarFilter(_ store: EKEventStore, names: String?, entity: EKEntityType) -> [EKCalendar]? {
        let all = store.calendars(for: entity)
        guard let names, !names.isEmpty else { return nil }
        let wanted = names.lowercased()
        let matched = all.filter { $0.title.lowercased().contains(wanted) }
        return matched.isEmpty ? nil : matched
    }

    static func recurrence(_ raw: String?) -> EKRecurrenceRule? {
        switch raw?.lowercased() {
        case "daily": return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case "weekly": return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case "monthly": return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        default: return nil
        }
    }
}
