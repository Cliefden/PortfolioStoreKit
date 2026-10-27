import Foundation

// The "keep cached when empty" safeguard from Equinox's `refreshEntitlements`,
// as pure functions so the rules are testable without StoreKit.
//
// `Transaction.currentEntitlements` is empty both when a purchase was revoked
// *and* when the device simply can't vouch for it (signed out of the App
// Store, history not yet synced). A paying user must not be locked out by
// the latter, so a non-consumable we have previously seen owned stays
// unlocked — provisionally — until StoreKit gives a definitive answer:
//   • a transaction for it carries a `revocationDate` (refund / Family Sharing
//     removal), or
//   • a `Transaction.all` scan proves absence: the history is readable (it
//     contains other transactions, or an `AppStore.sync()` just succeeded)
//     and holds no unrevoked transaction for the product.

/// What a `Transaction.all` sweep found, restricted to verified transactions.
public struct TransactionHistoryScan: Sendable, Equatable {
    /// Products with at least one unrevoked transaction.
    public var owned: Set<String>
    /// Products whose only transactions are revoked.
    public var revoked: Set<String>
    /// Number of verified transactions seen (any product).
    public var transactionCount: Int
    /// True when the scan follows a successful `AppStore.sync()` — the user
    /// is signed in and history is current, so even an empty history is proof.
    public var isAuthoritative: Bool

    public init(owned: Set<String> = [], revoked: Set<String> = [], transactionCount: Int = 0, isAuthoritative: Bool = false) {
        self.owned = owned
        self.revoked = revoked.subtracting(owned)
        self.transactionCount = transactionCount
        self.isAuthoritative = isAuthoritative
    }

    /// Whether the absence of a product from this history means it isn't owned.
    public var provesAbsence: Bool { isAuthoritative || transactionCount > 0 }
}

/// Outcome for the non-consumables of one refresh.
public struct StickyResolution: Sendable, Equatable {
    /// Owned per StoreKit (current entitlements, or unrevoked history).
    public var confirmed: Set<String>
    /// Kept from the cache without StoreKit confirmation (the safeguard).
    public var provisional: Set<String>
    /// Cached but definitively gone (revoked, or absence proven).
    public var dropped: Set<String>

    public init(confirmed: Set<String> = [], provisional: Set<String> = [], dropped: Set<String> = []) {
        self.confirmed = confirmed
        self.provisional = provisional
        self.dropped = dropped
    }

    /// Non-consumables to treat as owned right now.
    public var owned: Set<String> { confirmed.union(provisional) }
}

public enum StickyEntitlementPolicy {
    /// Decide each cached non-consumable.
    ///
    /// - Parameters:
    ///   - current: non-consumables in `Transaction.currentEntitlements` (verified, unrevoked).
    ///   - cached: non-consumables in the entitlement cache.
    ///   - revoked: products seen with a `revocationDate` this session
    ///     (e.g. via `Transaction.updates`).
    ///   - history: the `Transaction.all` sweep, or `nil` if it hasn't run.
    public static func resolve(current: Set<String>,
                               cached: Set<String>,
                               revoked: Set<String> = [],
                               history: TransactionHistoryScan?) -> StickyResolution {
        var result = StickyResolution(confirmed: current)
        for product in cached.subtracting(current) {
            if revoked.contains(product) || history?.revoked.contains(product) == true {
                result.dropped.insert(product)
            } else if let history, history.owned.contains(product) {
                result.confirmed.insert(product)
            } else if let history, history.provesAbsence {
                result.dropped.insert(product)
            } else {
                // No history yet, or an empty unauthoritative history
                // (signed out): keep the payer unlocked.
                result.provisional.insert(product)
            }
        }
        return result
    }

    /// What to write back to the cache after a refresh, or `nil` to leave it.
    ///
    /// A fully-confirmed reading is written fresh (`verifiedAt = now`). While
    /// anything is provisional the previous `verifiedAt` is preserved, so a
    /// `SealedEntitlementCache` max age still runs out for a device that
    /// never reconfirms.
    public static func cacheUpdate(observed: CachedEntitlements,
                                   resolution: StickyResolution,
                                   previous: CachedEntitlements?) -> CachedEntitlements? {
        var next = observed
        next.nonConsumableIDs = resolution.owned
        next.productIDs.formUnion(resolution.owned)
        next.productIDs.subtract(resolution.dropped)
        guard !resolution.provisional.isEmpty else { return next }
        next.verifiedAt = previous?.verifiedAt ?? observed.verifiedAt
        return next == previous ? nil : next
    }
}

extension EntitlementSnapshot {
    /// Build a snapshot from a cache reading (launch hint), limited to the
    /// client's configured products.
    init(cached: CachedEntitlements, productIDs: Set<String>, now: Date) {
        let active = cached.activeProductIDs(now: now).intersection(productIDs)
        let lifetime = !cached.nonConsumableIDs.intersection(active).isEmpty
        let hasSubscription = !active.subtracting(cached.nonConsumableIDs).isEmpty
        self.init(activeProductIDs: active,
                  expiry: hasSubscription ? cached.expiry : nil,
                  isLifetime: lifetime)
    }

    /// This snapshot plus products kept provisionally (always non-consumables).
    func adding(provisional: Set<String>) -> EntitlementSnapshot {
        guard !provisional.isEmpty else { return self }
        return EntitlementSnapshot(activeProductIDs: activeProductIDs.union(provisional),
                                   expiry: expiry, isLifetime: true)
    }
}
