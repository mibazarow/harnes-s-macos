import Contacts
import Foundation

/// R26.2: people. Search is read-only and cheap; create/update need an explicit
/// confirmation and never touch a group the caller did not name.
enum ContactControl {
    static var keys: [CNKeyDescriptor] {
        [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactNoteKey,
            CNContactIdentifierKey
        ] as [CNKeyDescriptor]
    }

    static func authorization() -> String {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }

    static func canRead() -> Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    /// Name first (the system predicate), then a local match over phone and e-mail:
    /// `predicateForContacts(matchingName:)` does not look at either.
    static func search(_ query: String, limit: Int, store: CNContactStore = CNContactStore()) -> [CNContact] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        if let found = try? store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: trimmed),
            keysToFetch: keys
        ), !found.isEmpty {
            return Array(found.prefix(limit))
        }
        let digits = trimmed.filter(\.isNumber)
        var matches: [CNContact] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { contact, stop in
            let phones = contact.phoneNumbers.map { $0.value.stringValue.filter(\.isNumber) }
            let emails = contact.emailAddresses.map { ($0.value as String).lowercased() }
            let hit = phones.contains { digits.count >= 5 && $0.contains(digits) }
                || emails.contains { $0.contains(trimmed.lowercased()) }
            if hit { matches.append(contact) }
            if matches.count >= limit { stop.pointee = true }
        }
        return matches
    }

    static func summary(_ contact: CNContact) -> String {
        var line = "\(contact.identifier) "
        let name = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }.joined(separator: " ")
        line += name.isEmpty ? (contact.organizationName.isEmpty ? "(без имени)" : contact.organizationName) : name
        if !contact.organizationName.isEmpty, !name.isEmpty { line += " org=\(contact.organizationName)" }
        if !contact.phoneNumbers.isEmpty {
            line += " phones=" + contact.phoneNumbers.map { $0.value.stringValue }.joined(separator: ",")
        }
        if !contact.emailAddresses.isEmpty {
            line += " emails=" + contact.emailAddresses.map { $0.value as String }.joined(separator: ",")
        }
        return line
    }

    static func makeContact(
        givenName: String?, familyName: String?, organization: String?,
        phones: [String], emails: [String], note: String?
    ) -> CNMutableContact {
        let contact = CNMutableContact()
        contact.givenName = givenName ?? ""
        contact.familyName = familyName ?? ""
        contact.organizationName = organization ?? ""
        contact.phoneNumbers = phones.map {
            CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: $0))
        }
        contact.emailAddresses = emails.map {
            CNLabeledValue(label: CNLabelHome, value: $0 as NSString)
        }
        if let note, !note.isEmpty { contact.note = note }
        return contact
    }

    static func save(_ contact: CNMutableContact, store: CNContactStore = CNContactStore()) throws {
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        try store.execute(request)
    }

    static func update(
        id: String, givenName: String?, familyName: String?, organization: String?,
        phones: [String]?, emails: [String]?, note: String?,
        store: CNContactStore = CNContactStore()
    ) throws {
        guard let existing = try store.unifiedContact(withIdentifier: id, keysToFetch: keys)
            .mutableCopy() as? CNMutableContact else {
            throw NSError(domain: "HarnessContacts", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Контакт \(id) не найден."])
        }
        if let givenName { existing.givenName = givenName }
        if let familyName { existing.familyName = familyName }
        if let organization { existing.organizationName = organization }
        if let note { existing.note = note }
        if let phones {
            existing.phoneNumbers = phones.map {
                CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: $0))
            }
        }
        if let emails {
            existing.emailAddresses = emails.map {
                CNLabeledValue(label: CNLabelHome, value: $0 as NSString)
            }
        }
        let request = CNSaveRequest()
        request.update(existing)
        try store.execute(request)
    }
}
