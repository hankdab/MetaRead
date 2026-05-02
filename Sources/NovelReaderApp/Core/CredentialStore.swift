import Foundation
import Security

protocol NASCredentialStore {
    func password(for connection: NASConnection) -> String?
    func savePassword(_ password: String, for connection: NASConnection) throws
    func deletePassword(for connection: NASConnection)
}

enum CredentialStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status): "Keychain 操作失败：\(status)"
        }
    }
}

struct KeychainNASCredentialStore: NASCredentialStore {
    private let service = "NovelReaderApp.NAS"

    func password(for connection: NASConnection) -> String? {
        var query = baseQuery(for: connection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    func savePassword(_ password: String, for connection: NASConnection) throws {
        guard !password.isEmpty else {
            deletePassword(for: connection)
            return
        }

        let data = Data(password.utf8)
        var query = baseQuery(for: connection)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychain(updateStatus)
        }

        query[kSecValueData as String] = data
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(addStatus)
        }
    }

    func deletePassword(for connection: NASConnection) {
        SecItemDelete(baseQuery(for: connection) as CFDictionary)
    }

    private func baseQuery(for connection: NASConnection) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connection.id.uuidString,
            kSecAttrLabel as String: connection.name
        ]
    }
}
