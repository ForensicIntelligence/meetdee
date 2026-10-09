import Foundation
import Security

/// Where a secret lives. The Keychain in the app; memory in tests.
public protocol SecretStorage: Sendable {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func remove(account: String) throws
}

public enum KeyStoreError: Error, Sendable, Equatable {
    /// `OSStatus` from the Security framework.
    case keychain(Int32)
    /// The text does not look like an OpenAI API key.
    case invalidKey
}

/// Dee's OpenAI project key, in the Keychain.
///
/// Stored as a generic password, `WhenUnlockedThisDeviceOnly`, never synchronised
/// to iCloud and never compiled into the binary or Info.plist. Entered once in the
/// key sheet. A dedicated, restricted project key with a hard spend limit is
/// strongly recommended (a sideloaded app's key can be extracted from the device).
public struct KeyStore: Sendable {
    public static let defaultAccount = "openai.api-key"

    public let account: String
    private let storage: any SecretStorage

    public init(account: String = KeyStore.defaultAccount, storage: any SecretStorage = KeychainStorage()) {
        self.account = account
        self.storage = storage
    }

    /// The stored key, or nil.
    public func load() throws -> String? { try storage.read(account: account) }

    /// Validates (see `normalize`) and stores the key, replacing any previous one.
    @discardableResult
    public func save(_ key: String) throws -> String {
        guard let clean = Self.normalize(key) else { throw KeyStoreError.invalidKey }
        try storage.write(clean, account: account)
        return clean
    }

    public func delete() throws { try storage.remove(account: account) }

    public var hasKey: Bool { ((try? load()) ?? nil) != nil }

    /// Trims whitespace, newlines and quotes picked up by copy-paste; nil if the
    /// result cannot be an OpenAI key (`sk-…`, no inner whitespace, sane length).
    public static func normalize(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
        guard trimmed.hasPrefix("sk-"), (20...400).contains(trimmed.count),
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return trimmed
    }

    /// "sk-…abcd" for display.
    public static func redacted(_ key: String) -> String {
        key.count <= 8 ? "sk-…" : "sk-…" + key.suffix(4)
    }
}

/// Keychain generic-password storage.
public struct KeychainStorage: SecretStorage {
    public let service: String

    public init(service: String = "com.dee.realtime") { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    public func read(account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeyStoreError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add.merge(attributes) { _, b in b }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
    }

    public func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyStoreError.keychain(status) }
    }
}

/// In-memory storage for tests and previews.
public final class MemorySecretStorage: SecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init(_ initial: [String: String] = [:]) { values = initial }

    public func read(account: String) throws -> String? { lock.withLock { values[account] } }
    public func write(_ value: String, account: String) throws { lock.withLock { values[account] = value } }
    public func remove(account: String) throws { lock.withLock { _ = values.removeValue(forKey: account) } }
}
