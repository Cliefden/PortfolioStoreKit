import Testing
import Foundation
import Security
@testable import PortfolioStoreKit

private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
private let day: TimeInterval = 86_400

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "PortfolioStoreKitTests.\(UUID().uuidString)")!
}

private let lunkerItem = KeychainItem(service: "com.lunker.premium", account: "trialStart")

@Suite struct TrialStateDerivation {
    @Test func notStartedWithoutDate() {
        #expect(Trial.state(startedAt: nil, duration: Trial.fourteenDays, now: t0) == .notStarted)
    }

    @Test func activeUntilDurationElapses() {
        let state = Trial.state(startedAt: t0, duration: Trial.fourteenDays, now: t0.addingTimeInterval(13 * day))
        #expect(state == .active(endsAt: t0.addingTimeInterval(14 * day)))
        #expect(state.isActive)
        #expect(state.endsAt == t0.addingTimeInterval(14 * day))
        #expect(state.analyticsLabel == "active")
    }

    @Test func expiredExactlyAtEnd() {
        let state = Trial.state(startedAt: t0, duration: Trial.fourteenDays, now: t0.addingTimeInterval(14 * day))
        #expect(state == .expired)
        #expect(state.analyticsLabel == "expired")
    }

    @Test func futureStartCountsAsExpired() {
        // Clock rolled back past the recorded start (Lunker/Sextant rule).
        #expect(Trial.state(startedAt: t0, duration: Trial.fourteenDays, now: t0.addingTimeInterval(-1)) == .expired)
    }
}

@Suite struct TrialLifecycle {
    @Test func startPersistsAndIsIdempotent() throws {
        let trial = Trial(store: UserDefaultsTrialStore(defaults: freshDefaults()), clock: .fixed(t0))
        #expect(try trial.state() == .notStarted)
        #expect(try trial.start() == .active(endsAt: t0.addingTimeInterval(14 * day)))
        // A second start later never moves the date.
        let later = t0.addingTimeInterval(20 * day)
        #expect(try trial.start(now: later) == .expired)
        #expect(try trial.startDate() == t0)
        #expect(try trial.endDate() == t0.addingTimeInterval(14 * day))
    }

    @Test func clockDrivesState() throws {
        let store = UserDefaultsTrialStore(defaults: freshDefaults())
        try Trial(store: store, clock: .fixed(t0)).start()
        let later = Trial(store: store, clock: .fixed(t0.addingTimeInterval(15 * day)))
        #expect(try later.state() == .expired)
        #expect(try later.state(now: t0.addingTimeInterval(day)).isActive)
    }

    @Test func customDuration() throws {
        let trial = Trial(duration: 7 * day, store: UserDefaultsTrialStore(defaults: freshDefaults()), clock: .fixed(t0))
        try trial.start()
        #expect(try trial.state(now: t0.addingTimeInterval(8 * day)) == .expired)
    }

    @Test func lockedKeychainIsUnknownNotFresh() {
        let keychain = InMemoryKeychain()
        keychain.failReads = errSecInteractionNotAllowed
        let trial = Trial(store: KeychainTrialStore(item: lunkerItem, backend: keychain), clock: .fixed(t0))
        #expect(throws: TrialPersistenceError.keychain(errSecInteractionNotAllowed)) { try trial.state() }
        #expect(throws: TrialPersistenceError.keychain(errSecInteractionNotAllowed)) { try trial.start() }
        keychain.failReads = nil
        #expect(keychain[lunkerItem] == nil)   // nothing written while unknown
    }

    @Test func corruptRecordCountsAsUsed() throws {
        let keychain = InMemoryKeychain()
        keychain[lunkerItem] = Data("garbage".utf8)
        let trial = Trial(store: KeychainTrialStore(item: lunkerItem, backend: keychain), clock: .fixed(t0))
        #expect(try trial.state() == .expired)
        #expect(try trial.start() == .expired)   // never a fresh trial
        #expect(keychain[lunkerItem] == Data("garbage".utf8))
    }

    @Test func failedSaveThrows() {
        let keychain = InMemoryKeychain()
        keychain.failWrites = errSecNotAvailable
        let trial = Trial(store: KeychainTrialStore(item: lunkerItem, backend: keychain), clock: .fixed(t0))
        #expect(throws: TrialPersistenceError.saveFailed) { try trial.start() }
    }
}

@Suite struct TrialStores {
    @Test func keychainEarliestDateWins() throws {
        let store = KeychainTrialStore(item: lunkerItem, backend: InMemoryKeychain())
        #expect(store.saveTrialStart(t0.addingTimeInterval(day)))
        #expect(store.saveTrialStart(t0))
        #expect(store.saveTrialStart(t0.addingTimeInterval(5 * day)))
        #expect(try store.loadTrialStart() == t0)
    }

    @Test func keychainSurvivesReinstall() throws {
        let keychain = InMemoryKeychain()   // Keychain outlives the app's defaults
        let firstInstall = KeychainTrialStore(item: lunkerItem, backend: keychain,
                                              mirror: UserDefaultsTrialStore(defaults: freshDefaults()))
        try Trial(store: firstInstall, clock: .fixed(t0)).start()

        let freshMirror = UserDefaultsTrialStore(defaults: freshDefaults())
        let reinstall = KeychainTrialStore(item: lunkerItem, backend: keychain, mirror: freshMirror)
        let trial = Trial(store: reinstall, clock: .fixed(t0.addingTimeInterval(20 * day)))
        #expect(try trial.state() == .expired)
        #expect(try trial.start() == .expired)          // no second trial
        #expect(try freshMirror.loadTrialStart() == t0)  // mirror restored
    }

    @Test func mirrorAndKeychainCombineEarliest() throws {
        let keychain = InMemoryKeychain()
        keychain[lunkerItem] = KeychainTrialStore.encode(t0.addingTimeInterval(3 * day))
        let mirror = UserDefaultsTrialStore(defaults: freshDefaults())
        mirror.write(t0)
        let store = KeychainTrialStore(item: lunkerItem, backend: keychain, mirror: mirror)
        #expect(try store.loadTrialStart() == t0)
        #expect(KeychainTrialStore.decode(keychain[lunkerItem]!) == t0)   // keychain repaired
    }

    @Test func mirrorCoversLockedKeychain() throws {
        let keychain = InMemoryKeychain()
        keychain.failReads = errSecInteractionNotAllowed
        let mirror = UserDefaultsTrialStore(defaults: freshDefaults())
        mirror.write(t0)
        let store = KeychainTrialStore(item: lunkerItem, backend: keychain, mirror: mirror)
        #expect(try store.loadTrialStart() == t0)
    }

    @Test func mirrorRepairsLostKeychain() throws {
        let keychain = InMemoryKeychain()
        let mirror = UserDefaultsTrialStore(defaults: freshDefaults())
        mirror.write(t0)
        let store = KeychainTrialStore(item: lunkerItem, backend: keychain, mirror: mirror)
        #expect(try store.loadTrialStart() == t0)
        #expect(KeychainTrialStore.decode(keychain[lunkerItem]!) == t0)
    }

    @Test func decodesBothLegacyFormats() {
        // Lunker/Sextant: UTF-8 timestamp string.
        #expect(KeychainTrialStore.decode(Data("1760000000.0".utf8)) == t0)
        // Equinox: raw Double bytes.
        var raw = t0.timeIntervalSince1970
        let equinox = Data(bytes: &raw, count: MemoryLayout<Double>.size)
        #expect(KeychainTrialStore.decode(equinox) == t0)
        #expect(KeychainTrialStore.decode(Data()) == nil)
        #expect(KeychainTrialStore.decode(Data("nope".utf8)) == nil)
    }

    @Test func equinoxLegacyItemWithoutService() throws {
        let keychain = InMemoryKeychain()
        let item = KeychainItem(service: nil, account: "com.equinox.pro.trialStart")
        var raw = t0.timeIntervalSince1970
        keychain[item] = Data(bytes: &raw, count: MemoryLayout<Double>.size)
        let store = KeychainTrialStore(item: item, backend: keychain)
        #expect(try store.loadTrialStart() == t0)
    }

    @Test func userDefaultsEarliestWins() throws {
        let store = UserDefaultsTrialStore(defaults: freshDefaults(), key: "proTrialStartDate")
        #expect(try store.loadTrialStart() == nil)
        store.saveTrialStart(t0.addingTimeInterval(day))
        store.saveTrialStart(t0)
        store.saveTrialStart(t0.addingTimeInterval(2 * day))
        #expect(try store.loadTrialStart() == t0)
    }
}
