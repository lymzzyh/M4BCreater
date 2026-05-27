import Foundation
import Security

final class CredentialStore {
    private let service = "M4BCreater.WebDAV"
    private var credentials: [WebDAVCredential] = []

    func allCredentials() -> [WebDAVCredential] {
        credentials
    }

    func credential(id: UUID) -> WebDAVCredential? {
        credentials.first { $0.id == id }
    }

    func upsert(_ credential: WebDAVCredential, password: String?) {
        if let index = credentials.firstIndex(where: { $0.id == credential.id }) {
            credentials[index] = credential
        } else {
            credentials.append(credential)
        }
        if let password {
            savePassword(password, reference: credential.passwordReference)
        }
    }

    func remove(id: UUID) {
        guard let credential = credential(id: id) else { return }
        deletePassword(reference: credential.passwordReference)
        credentials.removeAll { $0.id == id }
    }

    func password(for reference: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func savePassword(_ password: String, reference: String) {
        deletePassword(reference: reference)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecValueData as String: Data(password.utf8)
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func deletePassword(reference: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference
        ]
        SecItemDelete(query as CFDictionary)
    }
}
