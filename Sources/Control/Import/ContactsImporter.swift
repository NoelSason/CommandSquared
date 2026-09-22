import Contacts
import ControlKit
import Foundation

/// Reads your own card from Contacts.
///
/// Rather than mapping `CNContact` field by field, this serialises the contact to
/// vCard and hands it to the parser that already has twenty tests against it.
/// One format to get right instead of two.
enum ContactsImporter {
    enum ImportError: Error, LocalizedError {
        case accessDenied
        case noMeCard
        case serialisationFailed(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                "Control doesn't have permission to read Contacts."
            case .noMeCard:
                "No card is set as yours in Contacts. Open Contacts, select your card, then Card → Make This My Card."
            case let .serialisationFailed(message):
                "Couldn't read your contact card: \(message)"
            }
        }
    }

    static var isAuthorized: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    static func requestAccess() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    static func readMeCard() async throws -> [ImportedValue] {
        if !isAuthorized {
            guard await requestAccess() else { throw ImportError.accessDenied }
        }

        let store = CNContactStore()
        let contact: CNContact
        do {
            contact = try store.unifiedMeContactWithKeys(
                toFetch: [CNContactVCardSerialization.descriptorForRequiredKeys()]
            )
        } catch {
            throw ImportError.noMeCard
        }

        let data: Data
        do {
            data = try CNContactVCardSerialization.data(with: [contact])
        } catch {
            throw ImportError.serialisationFailed(error.localizedDescription)
        }

        return VaultImporter.parseVCard(String(decoding: data, as: UTF8.self), source: .contacts)
    }

    static func readVCardFile(at url: URL) throws -> [ImportedValue] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return VaultImporter.parseVCard(text, source: .vCard)
    }
}
