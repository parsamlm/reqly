import Foundation
import Security

/// Where Reqly keeps passwords and private keys: the Keychain, or a file in debug builds given
/// `-secretsFile path`, so trying things out leaves the Keychain alone.
nonisolated protocol SecretStore: Sendable {
    func load(service: String, account: String) -> Data?
    /// `label` is how Keychain Access lists the item.
    func save(_ data: Data, service: String, account: String, label: String) throws
    func delete(service: String, account: String)
}

enum SecretStores {
    static var standard: any SecretStore {
        #if DEBUG
            if let path = UserDefaults.standard.string(forKey: DefaultsKey.secretsFile) {
                return FileSecrets(url: URL(filePath: path))
            }
        #endif
        return KeychainSecrets()
    }
}

/// Generic password items in the login keychain, as Reqly keeps its root certificate's key.
nonisolated struct KeychainSecrets: SecretStore {
    struct Failure: Error, LocalizedError {
        var status: OSStatus
        var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "The Keychain answered \(status)."
        }
    }

    func load(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func save(_ data: Data, service: String, account: String, label: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var status = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data, kSecAttrLabel as String: label] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = label
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func delete(service: String, account: String) {
        SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
    }
}

#if DEBUG
    /// Secrets in a JSON file, for test copies of Reqly.
    nonisolated struct FileSecrets: SecretStore {
        let url: URL

        private func read() -> [String: Data] {
            guard let data = try? Data(contentsOf: url) else { return [:] }
            return (try? JSONDecoder().decode([String: Data].self, from: data)) ?? [:]
        }

        func load(service: String, account: String) -> Data? {
            read()["\(service)/\(account)"]
        }

        func save(_ data: Data, service: String, account: String, label: String) throws {
            var all = read()
            all["\(service)/\(account)"] = data
            try JSONEncoder().encode(all).write(to: url, options: .atomic)
        }

        func delete(service: String, account: String) {
            var all = read()
            all["\(service)/\(account)"] = nil
            try? JSONEncoder().encode(all).write(to: url, options: .atomic)
        }
    }
#endif
