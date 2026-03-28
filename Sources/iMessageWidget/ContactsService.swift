import Foundation
import Contacts

/// Resolves iMessage handles (phone numbers, Apple IDs) to display names using CNContactStore.
class ContactsService {
    static let shared = ContactsService()

    private let store = CNContactStore()
    private var cache: [String: String] = [:]  // handle → display name
    private var authStatus: CNAuthorizationStatus = .notDetermined

    private init() {
        authStatus = CNContactStore.authorizationStatus(for: .contacts)
    }

    var isAuthorized: Bool { authStatus == .authorized }

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestAccess(for: .contacts)
            authStatus = granted ? .authorized : .denied
            return granted
        } catch {
            return false
        }
    }

    /// Returns the display name for a handle, or nil if not found.
    func displayName(for handle: String) -> String? {
        if let cached = cache[handle] { return cached }
        guard authStatus == .authorized else { return nil }

        let cleaned = normalize(handle)
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                    CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]

        // Try phone number lookup
        if cleaned.hasPrefix("+") || cleaned.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "(" || $0 == ")" || $0 == " " }) {
            let digits = cleaned.filter { $0.isNumber }
            let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: cleaned))
            if let contact = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys))?.first {
                let name = fullName(contact)
                cache[handle] = name
                return name
            }
            // Retry with last 10 digits
            if digits.count >= 10 {
                let last10 = String(digits.suffix(10))
                let pred2 = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: last10))
                if let contact = (try? store.unifiedContacts(matching: pred2, keysToFetch: keys))?.first {
                    let name = fullName(contact)
                    cache[handle] = name
                    return name
                }
            }
        }

        // Try email lookup (Apple ID)
        if handle.contains("@") {
            let predicate = CNContact.predicateForContacts(matchingEmailAddress: handle)
            if let contact = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys))?.first {
                let name = fullName(contact)
                cache[handle] = name
                return name
            }
        }

        return nil
    }

    private func fullName(_ contact: CNContact) -> String {
        let given  = contact.givenName
        let family = contact.familyName
        let full   = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        return full.isEmpty ? "Unknown" : full
    }

    private func normalize(_ handle: String) -> String {
        handle.trimmingCharacters(in: .whitespaces)
    }
}
