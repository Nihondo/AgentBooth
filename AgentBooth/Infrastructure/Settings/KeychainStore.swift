import Foundation
import Security

enum KeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain error: \(status)"
        case .invalidData:
            return "Keychain returned invalid data."
        }
    }
}

/// A small helper for storing secrets in the macOS Keychain.
final class KeychainStore {
    private let serviceName: String

    init(serviceName: String) {
        self.serviceName = serviceName
    }

    func readSecret(accountName: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: accountName,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return ""
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidData
        }
        return value
    }

    func writeSecret(_ secretText: String, accountName: String) throws {
        let data = Data(secretText.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: accountName,
        ]

        let updateAttributes: [CFString: Any] = [
            kSecValueData: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        var addAttributes = query
        addAttributes[kSecValueData] = data
        let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }
}
