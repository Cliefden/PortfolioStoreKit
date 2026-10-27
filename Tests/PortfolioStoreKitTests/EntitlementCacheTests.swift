import Testing
import Foundation
import CryptoKit
import Security
@testable import PortfolioStoreKit

private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
private let day: TimeInterval = 86_400
private let pro = "com.app.pro"
private let monthly = "com.app.monthly"
private let keyItem = KeychainItem(service: "com.app.entitlements-hint", account: "hmac-key")

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "PortfolioStoreKitTests.\(UUID().uuidString)")!
}

private func sealed(_ defaults: UserDefaults, keychain: InMemoryKeychain,
                    bundleID: String = "com.app", now: Date = t0,
                    maxAge: TimeInterval = SealedEntitlementCache.defaultMaxAge) -> SealedEntitlementCache {
    SealedEntitlementCache(keychain: keychain, keyItem: keyItem, defaults: defaults,
                           bundleID: bundleID, maxAge: maxAge, now: { now })
}

@Suite struct CachedEntitlementsRecord {
    @Test func nonConsumablesAlwaysActiveSubscriptionsUntilExpiry() {
        let record = CachedEntitlements(productIDs: [monthly], nonConsumableIDs: [pro],
                                        expiry: t0.addingTimeInterval(day), verifiedAt: t0)
        #expect(record.productIDs == [pro, monthly])
        #expect(record.isActive(pro, now: t0.addingTimeInterval(365 * day)))
        #expect(record.isActive(monthly, now: t0))
        #expect(!record.isActive(monthly, now: t0.addingTimeInterval(2 * day)))
        #expect(record.activeProductIDs(now: t0.addingTimeInterval(2 * day)) == [pro])
    }

    @Test func snapshotSeedFiltersToConfiguredProducts() {
        let record = CachedEntitlements(productIDs: ["com.other"], nonConsumableIDs: [pro], verifiedAt: t0)
        let seed = EntitlementSnapshot(cached: record, productIDs: [pro], now: t0)
        #expect(seed.activeProductIDs == [pro])
        #expect(seed.isLifetime)
        #expect(seed.expiry == nil)
    }
}

@Suite struct UserDefaultsCache {
    @Test func roundTrip() {
        let cache = UserDefaultsEntitlementCache(defaults: freshDefaults())
        #expect(cache.load() == nil)
        let record = CachedEntitlements(productIDs: [pro], nonConsumableIDs: [pro], verifiedAt: t0)
        cache.save(record)
        #expect(cache.load() == record)
        cache.clear()
        #expect(cache.load() == nil)
    }

    @Test func emptySaveClears() {
        let cache = UserDefaultsEntitlementCache(defaults: freshDefaults())
        cache.save(CachedEntitlements(productIDs: [pro], nonConsumableIDs: [pro], verifiedAt: t0))
        cache.save(CachedEntitlements(productIDs: [], verifiedAt: t0))
        #expect(cache.load() == nil)
    }

    @Test func appGroupSuiteIsShared() {
        let suite = "PortfolioStoreKitTests.group.\(UUID().uuidString)"
        let app = UserDefaultsEntitlementCache(suiteName: suite)
        let widget = UserDefaultsEntitlementCache(suiteName: suite)
        app.save(CachedEntitlements(productIDs: [pro], nonConsumableIDs: [pro], verifiedAt: t0))
        #expect(widget.load()?.isActive(pro) == true)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    @Test func legacyFlagSeedsAndIsMirrored() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "isProUser")   // written by the pre-package app
        let cache = UserDefaultsEntitlementCache(defaults: defaults, legacyFlags: ["isProUser": pro])
        let seeded = cache.load()
        #expect(seeded?.nonConsumableIDs == [pro])
        #expect(seeded?.verifiedAt == .distantPast)

        cache.save(CachedEntitlements(productIDs: [monthly], expiry: t0.addingTimeInterval(day), verifiedAt: t0))
        #expect(defaults.bool(forKey: "isProUser") == false)
        cache.save(CachedEntitlements(productIDs: [pro], nonConsumableIDs: [pro], verifiedAt: t0))
        #expect(defaults.bool(forKey: "isProUser") == true)
        cache.clear()
        #expect(defaults.bool(forKey: "isProUser") == false)
        #expect(cache.load() == nil)
    }
}

@Suite struct SealedCache {
    let record = CachedEntitlements(productIDs: [monthly], nonConsumableIDs: [pro],
                                    expiry: t0.addingTimeInterval(30 * day), verifiedAt: t0)

    @Test func roundTripAndKeyPersisted() {
        let defaults = freshDefaults()
        let keychain = InMemoryKeychain()
        sealed(defaults, keychain: keychain).save(record)
        #expect(keychain[keyItem]?.count == 32)
        // A new instance (next launch) reads it back with the stored key.
        #expect(sealed(defaults, keychain: keychain).load() == record)
    }

    @Test func tamperedRecordReadsAsNoCache() throws {
        let defaults = freshDefaults()
        let keychain = InMemoryKeychain()
        let cache = sealed(defaults, keychain: keychain)
        cache.save(CachedEntitlements(productIDs: [], nonConsumableIDs: ["com.app.cheap"], verifiedAt: t0))

        // Hand-edit the stored record to claim a different product.
        let key = "portfolio.entitlements.sealed.v1"
        var envelope = try JSONDecoder().decode(SealedEntitlementCache.Sealed.self, from: defaults.data(forKey: key)!)
        var body = try JSONDecoder().decode(SealedEntitlementCache.Record.self, from: envelope.record)
        body.owned = [pro]
        body.nonConsumable = [pro]
        envelope.record = try JSONEncoder().encode(body)
        defaults.set(try JSONEncoder().encode(envelope), forKey: key)
        #expect(cache.load() == nil)

        // Garbage bytes too.
        defaults.set(Data("not json".utf8), forKey: key)
        #expect(cache.load() == nil)
    }

    @Test func recordFromAnotherDeviceReadsAsNoCache() {
        let defaults = freshDefaults()
        sealed(defaults, keychain: InMemoryKeychain()).save(record)
        // Same preferences restored onto a device with a different key.
        #expect(sealed(defaults, keychain: InMemoryKeychain()).load() == nil)
    }

    @Test func bundleMismatchReadsAsNoCache() {
        let defaults = freshDefaults()
        let keychain = InMemoryKeychain()
        sealed(defaults, keychain: keychain, bundleID: "com.app").save(record)
        #expect(sealed(defaults, keychain: keychain, bundleID: "com.other").load() == nil)
    }

    @Test func expiresAfterMaxAge() {
        let defaults = freshDefaults()
        let keychain = InMemoryKeychain()
        sealed(defaults, keychain: keychain).save(record)
        #expect(sealed(defaults, keychain: keychain, now: t0.addingTimeInterval(60 * day)).load() == record)
        #expect(sealed(defaults, keychain: keychain, now: t0.addingTimeInterval(60 * day + 1)).load() == nil)
        #expect(sealed(defaults, keychain: keychain, now: t0.addingTimeInterval(2 * day), maxAge: day).load() == nil)
    }

    @Test func futureDatedBeyondSkewReadsAsNoCache() {
        let defaults = freshDefaults()
        let keychain = InMemoryKeychain()
        sealed(defaults, keychain: keychain).save(record)
        #expect(sealed(defaults, keychain: keychain, now: t0.addingTimeInterval(-30 * 60)).load() == record)
        #expect(sealed(defaults, keychain: keychain, now: t0.addingTimeInterval(-2 * 60 * 60)).load() == nil)
    }

    @Test func emptySaveClears() {
        let defaults = freshDefaults()
        let cache = sealed(defaults, keychain: InMemoryKeychain())
        cache.save(record)
        cache.save(CachedEntitlements(productIDs: [], verifiedAt: t0))
        #expect(cache.load() == nil)
    }

    @Test func lockedKeychainMeansNoCacheAndNoNewKey() {
        let defaults = freshDefaults()
        let keychain = InMemoryKeychain()
        keychain.failReads = errSecInteractionNotAllowed
        let cache = sealed(defaults, keychain: keychain)
        cache.save(record)
        #expect(cache.load() == nil)
        #expect(keychain[keyItem] == nil)   // never mint a key that would orphan the real one
    }

    @Test func readsEnigmaV1Records() throws {
        // Enigma's record has no nonConsumable / expiry fields.
        let defaults = freshDefaults()
        let keychain = InMemoryKeychain()
        let keyBytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        keychain[keyItem] = keyBytes
        let body = try JSONEncoder().encode(EnigmaRecord(owned: [pro], verifiedAt: t0.timeIntervalSince1970, bundleID: "com.app"))
        let mac = Data(HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: keyBytes)))
        defaults.set(try JSONEncoder().encode(SealedEntitlementCache.Sealed(record: body, mac: mac)),
                     forKey: "entitlements.hint.v1")
        let cache = SealedEntitlementCache(keychain: keychain, keyItem: keyItem, defaults: defaults,
                                           defaultsKey: "entitlements.hint.v1", bundleID: "com.app", now: { t0 })
        let loaded = try #require(cache.load())
        #expect(loaded.productIDs == [pro])
        #expect(loaded.nonConsumableIDs.isEmpty)
    }

    private struct EnigmaRecord: Codable {
        var owned: [String]
        var verifiedAt: Double
        var bundleID: String
    }
}
