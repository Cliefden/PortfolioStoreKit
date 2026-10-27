import Foundation
import CryptoKit
import Security

/// The last entitlement reading StoreKit verified, persisted between launches.
/// Used by `StoreClient` as a launch hint (owned features don't flash locked)
/// and, with `stickyNonConsumables`, to keep a paid one-time unlock while
/// StoreKit can't vouch for it (signed out of the App Store, empty history).
public struct CachedEntitlements: Sendable, Equatable, Codable {
    /// Every product active at `verifiedAt` (non-consumables and subscriptions).
    public var productIDs: Set<String>
    /// The subset that are non-consumables (one-time / lifetime unlocks) —
    /// the only products `stickyNonConsumables` keeps.
    public var nonConsumableIDs: Set<String>
    /// Soonest subscription expiry at `verifiedAt` (nil if none).
    public var expiry: Date?
    /// When StoreKit last confirmed this reading.
    public var verifiedAt: Date

    public init(productIDs: Set<String>, nonConsumableIDs: Set<String> = [], expiry: Date? = nil, verifiedAt: Date) {
        self.productIDs = productIDs.union(nonConsumableIDs)
        self.nonConsumableIDs = nonConsumableIDs
        self.expiry = expiry
        self.verifiedAt = verifiedAt
    }

    public var isEmpty: Bool { productIDs.isEmpty }

    /// Whether `productID` should read as owned from this cache at `now`:
    /// non-consumables always; subscriptions until the recorded (soonest) expiry.
    public func isActive(_ productID: String, now: Date = Date()) -> Bool {
        if nonConsumableIDs.contains(productID) { return true }
        guard productIDs.contains(productID) else { return false }
        return (expiry ?? .distantFuture) > now
    }

    /// Products still believed active at `now`.
    public func activeProductIDs(now: Date = Date()) -> Set<String> {
        productIDs.filter { isActive($0, now: now) }
    }
}

/// Persists `CachedEntitlements`. Implementations must be cheap and
/// synchronous — `StoreClient` reads one at init to seed its first frame.
public protocol EntitlementCache: Sendable {
    func load() -> CachedEntitlements?
    /// Stores the reading. An empty reading may clear the cache.
    func save(_ entitlements: CachedEntitlements)
    func clear()
}

// MARK: - UserDefaults (App Group capable)

/// Plain `UserDefaults` cache. Point `suiteName` at an App Group so widgets /
/// watch / background launches read Pro without StoreKit (Otta, Equinox).
///
/// `legacyFlags` maps old boolean keys to the product they meant (e.g.
/// `["isProUser": "com.equinox.pro"]`): they're written on every save (so
/// existing widget code keeps working) and seed the cache — as non-consumables —
/// when no record exists yet (so updating the app never locks out a payer).
public struct UserDefaultsEntitlementCache: EntitlementCache, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let legacyFlags: [String: String]

    public init(suiteName: String? = nil,
                key: String = "portfolio.entitlements.v1",
                legacyFlags: [String: String] = [:]) {
        self.init(defaults: suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard,
                  key: key, legacyFlags: legacyFlags)
    }

    public init(defaults: UserDefaults,
                key: String = "portfolio.entitlements.v1",
                legacyFlags: [String: String] = [:]) {
        self.defaults = defaults
        self.key = key
        self.legacyFlags = legacyFlags
    }

    public func load() -> CachedEntitlements? {
        if let data = defaults.data(forKey: key),
           let record = try? JSONDecoder().decode(CachedEntitlements.self, from: data) {
            return record
        }
        let flagged = Set(legacyFlags.compactMap { flag, product in defaults.bool(forKey: flag) ? product : nil })
        guard !flagged.isEmpty else { return nil }
        return CachedEntitlements(productIDs: flagged, nonConsumableIDs: flagged, verifiedAt: .distantPast)
    }

    public func save(_ entitlements: CachedEntitlements) {
        for (flag, product) in legacyFlags {
            defaults.set(entitlements.isActive(product, now: Date()), forKey: flag)
        }
        guard !entitlements.isEmpty else { defaults.removeObject(forKey: key); return }
        if let data = try? JSONEncoder().encode(entitlements) {
            defaults.set(data, forKey: key)
        }
    }

    public func clear() {
        defaults.removeObject(forKey: key)
        for flag in legacyFlags.keys { defaults.set(false, forKey: flag) }
    }
}

// MARK: - Sealed (HMAC-SHA256)

/// Enigma's "signed-ish" cache: the record is HMAC-SHA256 sealed with 256
/// random bits kept in this device's Keychain (`ThisDeviceOnly`, never synced),
/// so a hand-edited preferences file — or one restored onto another phone —
/// reads as no cache at all. Records older than `maxAge` (or dated more than
/// an hour in the future) are ignored. Not DRM: tamper-evident only.
///
/// The record layout is Enigma's (`owned` / `verifiedAt` / `bundleID`) plus
/// two optional fields, so pass Enigma's `keyService` / `defaultsKey` to keep
/// existing hints valid.
public struct SealedEntitlementCache: EntitlementCache, @unchecked Sendable {
    public static let defaultMaxAge: TimeInterval = 60 * 86_400
    /// Tolerated clock skew for records dated in the future.
    static let futureSkew: TimeInterval = 60 * 60

    private let defaults: UserDefaults
    private let defaultsKey: String
    private let bundleID: String
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    private let keyStore: SealingKeyStore

    /// - Parameters:
    ///   - keyService / keyAccount: Keychain address of the sealing key
    ///     (Enigma: `se.enigma.app.entitlements-hint` / `hmac-key`).
    ///   - defaults / defaultsKey: where the sealed record lives
    ///     (Enigma: `.standard` / `entitlements.hint.v1`).
    ///   - bundleID: bound into the record; a mismatch reads as no cache.
    ///   - maxAge: how long a reading is believed without StoreKit re-confirming it.
    public init(keyService: String,
                keyAccount: String = "hmac-key",
                defaults: UserDefaults = .standard,
                defaultsKey: String = "portfolio.entitlements.sealed.v1",
                bundleID: String = Bundle.main.bundleIdentifier ?? "",
                maxAge: TimeInterval = SealedEntitlementCache.defaultMaxAge) {
        self.init(keychain: SystemKeychain(),
                  keyItem: KeychainItem(service: keyService, account: keyAccount),
                  defaults: defaults, defaultsKey: defaultsKey, bundleID: bundleID,
                  maxAge: maxAge, now: { Date() })
    }

    init(keychain: any KeychainBackend,
         keyItem: KeychainItem,
         defaults: UserDefaults,
         defaultsKey: String = "portfolio.entitlements.sealed.v1",
         bundleID: String,
         maxAge: TimeInterval = SealedEntitlementCache.defaultMaxAge,
         now: @escaping @Sendable () -> Date) {
        self.keyStore = SealingKeyStore(keychain: keychain, item: keyItem)
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.bundleID = bundleID
        self.maxAge = maxAge
        self.now = now
    }

    struct Record: Codable, Equatable {
        var owned: [String]             // sorted
        var verifiedAt: Double          // seconds since 1970
        var bundleID: String
        var nonConsumable: [String]?    // sorted; absent in Enigma's v1 records
        var expiry: Double?
    }

    struct Sealed: Codable {
        var record: Data
        var mac: Data
    }

    public func load() -> CachedEntitlements? {
        guard let key = keyStore.key(),
              let data = defaults.data(forKey: defaultsKey),
              let sealed = try? JSONDecoder().decode(Sealed.self, from: data),
              HMAC<SHA256>.isValidAuthenticationCode(sealed.mac, authenticating: sealed.record, using: key),
              let record = try? JSONDecoder().decode(Record.self, from: sealed.record),
              record.bundleID == bundleID
        else { return nil }
        let age = now().timeIntervalSince1970 - record.verifiedAt
        guard age >= -Self.futureSkew, age <= maxAge else { return nil }
        return CachedEntitlements(
            productIDs: Set(record.owned),
            nonConsumableIDs: Set(record.nonConsumable ?? []),
            expiry: record.expiry.map(Date.init(timeIntervalSince1970:)),
            verifiedAt: Date(timeIntervalSince1970: record.verifiedAt)
        )
    }

    public func save(_ entitlements: CachedEntitlements) {
        guard !entitlements.isEmpty else { clear(); return }
        guard let key = keyStore.key() else { return }
        let record = Record(owned: entitlements.productIDs.sorted(),
                            verifiedAt: entitlements.verifiedAt.timeIntervalSince1970,
                            bundleID: bundleID,
                            nonConsumable: entitlements.nonConsumableIDs.sorted(),
                            expiry: entitlements.expiry?.timeIntervalSince1970)
        guard let body = try? JSONEncoder().encode(record) else { return }
        let mac = Data(HMAC<SHA256>.authenticationCode(for: body, using: key))
        if let data = try? JSONEncoder().encode(Sealed(record: body, mac: mac)) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    public func clear() {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// Loads (or on first use creates) the 256-bit sealing key. A transient
/// Keychain failure (locked device during a prewarmed launch) yields no key
/// *this time* — never a fresh key that would orphan the existing one.
final class SealingKeyStore: @unchecked Sendable {
    private let keychain: any KeychainBackend
    private let item: KeychainItem
    private let lock = NSLock()
    private var cached: SymmetricKey?

    init(keychain: any KeychainBackend, item: KeychainItem) {
        self.keychain = keychain
        self.item = item
    }

    func key() -> SymmetricKey? {
        lock.withLock {
            if let cached { return cached }
            let data: Data?
            do {
                data = try keychain.read(item)
            } catch {
                return nil
            }
            if let data {
                guard data.count == 32 else { return nil }
                cached = SymmetricKey(data: data)
                return cached
            }
            let fresh = SymmetricKey(size: .bits256)
            let bytes = fresh.withUnsafeBytes { Data($0) }
            guard keychain.write(bytes, to: item, accessibility: .afterFirstUnlockThisDeviceOnly) == errSecSuccess else {
                return nil
            }
            cached = fresh
            return fresh
        }
    }
}
