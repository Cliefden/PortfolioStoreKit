import Foundation
import Security

// App-managed free trial for non-consumable unlocks (StoreKit introductory
// offers only exist for subscriptions). Lifted from Lunker/Sextant's
// `TrialPersistence`/`KeychainTrialStore`/`trialIsActive` and Equinox's
// `persistTrialStart`/`loadTrialStart`/`trialState(startedAt:now:)`.
// Feature gates ("isPro || trial active"), analytics and the opt-in UI stay
// in the app.

// MARK: - Persistence

/// Where the trial start date lives.
public protocol TrialPersistence: Sendable {
    /// The persisted trial start, or `nil` when no trial was ever started.
    /// Throws when the store can't be read right now (e.g. the Keychain is
    /// locked) so an unreadable store is never mistaken for "no trial".
    func loadTrialStart() throws -> Date?
    /// Persists the start. Implementations keep the **earliest** date ever
    /// recorded. Returns false when nothing could be persisted.
    @discardableResult
    func saveTrialStart(_ date: Date) -> Bool
}

/// Why the trial start couldn't be read.
public enum TrialPersistenceError: Error, Equatable, Sendable {
    /// The Keychain lookup failed with something other than "not found".
    case keychain(OSStatus)
    /// A record exists but its contents couldn't be decoded. `Trial` treats
    /// this as "a trial was used" (never a fresh trial, never stuck unknown).
    case corruptData
    /// `Trial.start` couldn't persist the start date.
    case saveFailed
}

/// Keychain-backed trial store: survives delete-and-reinstall, the obvious
/// loophole for a client-side trial. Earliest recorded date wins.
///
/// Reads both formats in the wild: Lunker/Sextant's UTF-8 timestamp string and
/// Equinox's raw 8-byte `Double`. Writes the string form.
///
/// `mirror` optionally keeps a `UserDefaults` copy (e.g. App Group defaults a
/// widget or background task reads without Keychain access). Loads combine the
/// two (earliest wins) and repair whichever side is missing, like Equinox did.
public struct KeychainTrialStore: TrialPersistence {
    let item: KeychainItem
    let backend: any KeychainBackend
    let mirror: UserDefaultsTrialStore?

    /// - Parameters:
    ///   - service: `kSecAttrService`. Pass `nil` only to read a legacy item
    ///     written without one (Equinox: account `com.equinox.pro.trialStart`).
    ///   - account: `kSecAttrAccount`.
    ///   - accessGroup: optional Keychain access group to share with extensions.
    ///   - mirror: optional `UserDefaults` copy kept in sync.
    public init(
        service: String?,
        account: String,
        accessGroup: String? = nil,
        mirror: UserDefaultsTrialStore? = nil
    ) {
        self.init(item: KeychainItem(service: service, account: account, accessGroup: accessGroup),
                  backend: SystemKeychain(), mirror: mirror)
    }

    init(item: KeychainItem, backend: any KeychainBackend, mirror: UserDefaultsTrialStore? = nil) {
        self.item = item
        self.backend = backend
        self.mirror = mirror
    }

    public func loadTrialStart() throws -> Date? {
        let fromMirror = mirror?.storedDate
        let fromKeychain: Date?
        do {
            fromKeychain = try readKeychain()
        } catch TrialPersistenceError.corruptData {
            // A real date in the mirror beats an unreadable record: repair it.
            guard let fromMirror else { throw TrialPersistenceError.corruptData }
            writeKeychain(fromMirror)
            return fromMirror
        } catch {
            // Locked/unavailable: a mirrored date is still a known start.
            if let fromMirror { return fromMirror }
            throw error
        }

        switch (fromKeychain, fromMirror) {
        case let (k?, m?):
            let earliest = min(k, m)
            if k != earliest { writeKeychain(earliest) }
            if m != earliest { mirror?.write(earliest) }
            return earliest
        case let (k?, nil):
            // Fresh install with a surviving Keychain record: restore the mirror.
            mirror?.write(k)
            return k
        case let (nil, m?):
            // Keychain entry lost (device restore): re-seed it.
            writeKeychain(m)
            return m
        case (nil, nil):
            return nil
        }
    }

    @discardableResult
    public func saveTrialStart(_ date: Date) -> Bool {
        let existing: Date?
        do {
            existing = try loadTrialStart()
        } catch {
            // Unknown state (locked, or a corrupt record = trial already used):
            // never write over it.
            return false
        }
        if let existing, existing <= date { return true }
        let ok = writeKeychain(date)
        mirror?.write(date)
        return ok
    }

    // MARK: Encoding

    private func readKeychain() throws -> Date? {
        let data: Data?
        do {
            data = try backend.read(item)
        } catch let error as KeychainStatusError {
            throw TrialPersistenceError.keychain(error.status)
        }
        guard let data else { return nil }
        guard let date = Self.decode(data) else { throw TrialPersistenceError.corruptData }
        return date
    }

    @discardableResult
    private func writeKeychain(_ date: Date) -> Bool {
        backend.write(Self.encode(date), to: item, accessibility: .afterFirstUnlock) == errSecSuccess
    }

    static func encode(_ date: Date) -> Data {
        Data(String(date.timeIntervalSince1970).utf8)
    }

    static func decode(_ data: Data) -> Date? {
        if let string = String(data: data, encoding: .utf8),
           let interval = TimeInterval(string), interval > 0 {
            return Date(timeIntervalSince1970: interval)
        }
        // Equinox ≤ 0.1-era format: the raw bytes of a Double.
        if data.count == MemoryLayout<Double>.size {
            let interval = data.withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
            if interval.isFinite, interval > 0 { return Date(timeIntervalSince1970: interval) }
        }
        return nil
    }
}

/// `UserDefaults`-backed trial store (seconds since 1970 as a `Double`, the
/// format Equinox used). Does **not** survive reinstall — use it for tests,
/// development, or as the `mirror` of a `KeychainTrialStore`.
public struct UserDefaultsTrialStore: TrialPersistence, @unchecked Sendable {
    // UserDefaults is thread-safe; `@unchecked` covers SDKs that don't mark it Sendable.
    private let defaults: UserDefaults
    private let key: String

    /// - Parameters:
    ///   - suiteName: App Group / suite, `nil` for `.standard`. Falls back to
    ///     `.standard` when the suite can't be opened.
    ///   - key: defaults key (Equinox: `proTrialStartDate`).
    public init(suiteName: String? = nil, key: String = "portfolio.trialStart") {
        self.defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.key = key
    }

    public init(defaults: UserDefaults, key: String = "portfolio.trialStart") {
        self.defaults = defaults
        self.key = key
    }

    var storedDate: Date? {
        let t = defaults.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    func write(_ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: key)
    }

    public func loadTrialStart() throws -> Date? { storedDate }

    @discardableResult
    public func saveTrialStart(_ date: Date) -> Bool {
        if let existing = storedDate, existing <= date { return true }
        write(date)
        return true
    }
}

// MARK: - Clock + state

/// Source of "now" for trial math; inject `.fixed` in tests.
public struct TrialClock: Sendable {
    public var now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date) { self.now = now }

    public static let system = TrialClock { Date() }
    public static func fixed(_ date: Date) -> TrialClock { TrialClock { date } }
}

public enum TrialState: Sendable, Equatable {
    case notStarted
    case active(endsAt: Date)
    case expired

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    public var endsAt: Date? {
        if case .active(let end) = self { return end }
        return nil
    }

    /// "none" / "active" / "expired" — the low-cardinality label Equinox and
    /// Lunker send as purchase-signal trial context.
    public var analyticsLabel: String {
        switch self {
        case .notStarted: return "none"
        case .active: return "active"
        case .expired: return "expired"
        }
    }
}

/// An app-managed, one-per-install-lifetime trial.
///
/// ```swift
/// let trial = Trial(duration: Trial.fourteenDays,
///                   store: KeychainTrialStore(service: "com.lunker.premium", account: "trialStart"))
/// let unlocked = isPremium || ((try? trial.state())?.isActive ?? false)
/// ```
public struct Trial: Sendable {
    public static let fourteenDays: TimeInterval = 14 * 86_400

    public let duration: TimeInterval
    public let store: any TrialPersistence
    public let clock: TrialClock

    public init(duration: TimeInterval = Trial.fourteenDays,
                store: any TrialPersistence,
                clock: TrialClock = .system) {
        self.duration = duration
        self.store = store
        self.clock = clock
    }

    /// The persisted start. A corrupt record reads as `.distantPast` (trial
    /// used). Throws `TrialPersistenceError.keychain` while unreadable — the
    /// state is unknown, so don't offer or start a trial.
    public func startDate() throws -> Date? {
        do {
            return try store.loadTrialStart()
        } catch TrialPersistenceError.corruptData {
            return .distantPast
        }
    }

    /// Current state. Throws while the store is unreadable (see `startDate()`).
    public func state(now: Date? = nil) throws -> TrialState {
        Self.state(startedAt: try startDate(), duration: duration, now: now ?? clock.now())
    }

    /// The trial's end, if it was ever started.
    public func endDate() throws -> Date? {
        try startDate().map { $0.addingTimeInterval(duration) }
    }

    /// Starts the trial if it was never started; otherwise a no-op that
    /// returns the existing state (a trial never restarts). Throws when the
    /// store is unreadable or the start couldn't be persisted — only unlock
    /// once this returns, so a relaunch can't silently lose the trial.
    @discardableResult
    public func start(now: Date? = nil) throws -> TrialState {
        let now = now ?? clock.now()
        if let existing = try startDate() {
            return Self.state(startedAt: existing, duration: duration, now: now)
        }
        guard store.saveTrialStart(now) else { throw TrialPersistenceError.saveFailed }
        return Self.state(startedAt: now, duration: duration, now: now)
    }

    /// Pure derivation. A start in the future (clock rolled back) counts as
    /// expired, matching Lunker/Sextant.
    public static func state(startedAt start: Date?, duration: TimeInterval, now: Date) -> TrialState {
        guard let start else { return .notStarted }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= 0, elapsed < duration else { return .expired }
        return .active(endsAt: start.addingTimeInterval(duration))
    }
}
