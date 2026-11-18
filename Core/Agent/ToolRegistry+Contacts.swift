import Contacts
import Foundation

extension ToolRegistry {
    /// R26.2: search, read, create and update. Limited access is reported as "only the
    /// chosen contacts are visible", not as a refusal.
    func contactsTool(_ args: [String: Any]) async -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? "search"
        let store = CNContactStore()
        let state = ContactControl.authorization()

        switch action {
        case "search":
            guard let query = args["query"] as? String, !query.isEmpty else {
                return .fail("query обязателен")
            }
            guard ContactControl.canRead() else {
                return .fail("Контакты недоступны (\(state)). Выдай доступ в панели Контакты; "
                    + "без него поиск невозможен.")
            }
            let limit = min(max(Self.int(args, "limit") ?? 10, 1), 100)
            let found = ContactControl.search(query, limit: limit, store: store)
            guard !found.isEmpty else { return .ok("Контактов по «\(query)» нет.") }
            return .ok("\(found.count) контактов (\(state)):\n"
                + found.map(ContactControl.summary).joined(separator: "\n"))

        case "get":
            guard let id = args["id"] as? String, !id.isEmpty else { return .fail("id обязателен") }
            guard ContactControl.canRead() else {
                return .fail("Контакты недоступны (\(state)).")
            }
            do {
                let contact = try store.unifiedContact(
                    withIdentifier: id, keysToFetch: ContactControl.keys
                )
                var text = ContactControl.summary(contact)
                if !contact.note.isEmpty { text += "\nnote: \(contact.note)" }
                return .ok(text)
            } catch {
                return .fail("Контакт \(id) не найден: \(error.localizedDescription)")
            }

        case "create":
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("contacts create требует confirm: true: это запись в адресную книгу.")
            }
            let contact = ContactControl.makeContact(
                givenName: args["given_name"] as? String,
                familyName: args["family_name"] as? String,
                organization: args["organization"] as? String,
                phones: Self.stringList(args["phones"]),
                emails: Self.stringList(args["emails"]),
                note: args["note"] as? String
            )
            do {
                try ContactControl.save(contact, store: store)
            } catch {
                return .fail("Контакт не создан: \(error.localizedDescription) "
                    + "(доступ: \(state)).")
            }
            return .ok("Контакт создан: \(contact.identifier)")

        case "update":
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("contacts update требует confirm: true.")
            }
            guard let id = args["id"] as? String, !id.isEmpty else { return .fail("id обязателен") }
            let phones = args["phones"].map { Self.stringList($0) }
            let emails = args["emails"].map { Self.stringList($0) }
            do {
                try ContactControl.update(
                    id: id,
                    givenName: args["given_name"] as? String,
                    familyName: args["family_name"] as? String,
                    organization: args["organization"] as? String,
                    phones: phones, emails: emails,
                    note: args["note"] as? String,
                    store: store
                )
            } catch {
                return .fail("Контакт не обновлён: \(error.localizedDescription)")
            }
            return .ok("Контакт \(id) обновлён.")

        default:
            return .fail("action: search | get | create | update")
        }
    }

    static func stringList(_ raw: Any?) -> [String] {
        if let list = raw as? [String] { return list.filter { !$0.isEmpty } }
        if let single = raw as? String, !single.isEmpty { return [single] }
        return []
    }
}
