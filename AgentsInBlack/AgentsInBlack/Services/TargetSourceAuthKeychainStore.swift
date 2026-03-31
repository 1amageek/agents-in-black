import Foundation
import Security

enum TargetSourceAuthKeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidSecretData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return message
            }
            return "Keychain operation failed (\(status))."
        case .invalidSecretData:
            return "Stored Keychain value could not be decoded."
        }
    }
}

@MainActor
final class TargetSourceAuthKeychainStore {
    private let service = "team.stamp.AgentsInBlack.target-source-auth"

    func passphrase(for reference: String) throws -> String? {
        var query = baseQuery(reference: reference)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw TargetSourceAuthKeychainStoreError.invalidSecretData
            }
            guard let value = String(data: data, encoding: .utf8) else {
                throw TargetSourceAuthKeychainStoreError.invalidSecretData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw TargetSourceAuthKeychainStoreError.unexpectedStatus(status)
        }
    }

    func containsPassphrase(for reference: String) throws -> Bool {
        var query = baseQuery(reference: reference)
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw TargetSourceAuthKeychainStoreError.unexpectedStatus(status)
        }
    }

    func setPassphrase(_ passphrase: String, for reference: String) throws {
        let encoded = Data(passphrase.utf8)
        let query = baseQuery(reference: reference)
        let attributes = [
            kSecValueData as String: encoded,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = encoded
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw TargetSourceAuthKeychainStoreError.unexpectedStatus(addStatus)
            }
        default:
            throw TargetSourceAuthKeychainStoreError.unexpectedStatus(updateStatus)
        }
    }

    func removePassphrase(for reference: String) throws {
        let status = SecItemDelete(baseQuery(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TargetSourceAuthKeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
    }
}
