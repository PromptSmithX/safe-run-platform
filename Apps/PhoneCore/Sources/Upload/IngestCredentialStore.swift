import Foundation
import Security

public protocol IngestCredentialStoring: Sendable {
    func save(token: String, account: String) async throws
    func token(account: String) async throws -> String?
    func remove(account: String) async throws
    func removeAll() async throws
}

public actor KeychainIngestCredentialStore: IngestCredentialStoring {
    private let service: String
    public init(service: String = "com.saferun.mvp.ingest") { self.service = service }

    public func save(token: String, account: String) throws {
        try remove(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(token.utf8),
        ]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw CredentialStoreError.keychain }
    }

    public func token(account: String) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialStoreError.keychain }
        return String(data: data, encoding: .utf8)
    }

    public func remove(account: String) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychain }
    }

    public func removeAll() throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychain }
    }
}

public enum CredentialStoreError: Error { case keychain }
