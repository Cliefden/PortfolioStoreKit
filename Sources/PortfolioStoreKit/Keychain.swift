import Foundation
import Security

/// When a Keychain item may be read. Mirrors the two `kSecAttrAccessible`
/// values the portfolio uses (kept as an enum so it's `Sendable`).
enum KeychainAccessibility: Sendable {
    /// Readable after the first unlock since boot; migrates via encrypted
    /// backups. Used for the trial start (should follow the user).
    case afterFirstUnlock
    /// Same, but never leaves this device. Used for the cache sealing key.
    case afterFirstUnlockThisDeviceOnly

    var secValue: CFString {
        switch self {
        case .afterFirstUnlock: return kSecAttrAccessibleAfterFirstUnlock
        case .afterFirstUnlockThisDeviceOnly: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }
}

/// Address of one generic-password item. `service` is optional because
/// Equinox's legacy trial item was written with an account only.
struct KeychainItem: Sendable, Hashable {
    var service: String?
    var account: String
    var accessGroup: String?
}

/// A Keychain read that failed for a reason other than "not found"
/// (e.g. `errSecInteractionNotAllowed` before first unlock).
struct KeychainStatusError: Error, Equatable {
    var status: OSStatus
}

/// The tiny slice of the Keychain the package needs. Internal so tests can
/// substitute `InMemoryKeychain` without touching the real Keychain.
protocol KeychainBackend: Sendable {
    /// The item's data, `nil` when it doesn't exist. Throws on any other failure.
    func read(_ item: KeychainItem) throws -> Data?
    /// Creates or replaces the item. Returns the `OSStatus` (`errSecSuccess` on success).
    @discardableResult
    func write(_ data: Data, to item: KeychainItem, accessibility: KeychainAccessibility) -> OSStatus
}

/// The real Keychain (`SecItem*`).
struct SystemKeychain: KeychainBackend {
    private func baseQuery(_ item: KeychainItem) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: item.account,
        ]
        if let service = item.service { query[kSecAttrService as String] = service }
        if let group = item.accessGroup { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    func read(_ item: KeychainItem) throws -> Data? {
        var query = baseQuery(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStatusError(status: status) }
        return out as? Data
    }

    func write(_ data: Data, to item: KeychainItem, accessibility: KeychainAccessibility) -> OSStatus {
        let query = baseQuery(item)
        // Update in place first (no delete/add window where the item is missing).
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility.secValue,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = accessibility.secValue
        return SecItemAdd(add as CFDictionary, nil)
    }
}

/// In-memory stand-in for tests. `failReads` / `failWrites` simulate a locked
/// device or a full Keychain.
final class InMemoryKeychain: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [KeychainItem: Data] = [:]
    private var _failReads: OSStatus?
    private var _failWrites: OSStatus?

    init() {}

    var failReads: OSStatus? {
        get { lock.withLock { _failReads } }
        set { lock.withLock { _failReads = newValue } }
    }

    var failWrites: OSStatus? {
        get { lock.withLock { _failWrites } }
        set { lock.withLock { _failWrites = newValue } }
    }

    subscript(item: KeychainItem) -> Data? {
        get { lock.withLock { items[item] } }
        set { lock.withLock { items[item] = newValue } }
    }

    func read(_ item: KeychainItem) throws -> Data? {
        try lock.withLock {
            if let status = _failReads { throw KeychainStatusError(status: status) }
            return items[item]
        }
    }

    func write(_ data: Data, to item: KeychainItem, accessibility: KeychainAccessibility) -> OSStatus {
        lock.withLock {
            if let status = _failWrites { return status }
            items[item] = data
            return errSecSuccess
        }
    }
}
