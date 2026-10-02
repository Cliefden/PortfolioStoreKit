import Foundation

/// What the verifier decided about a transaction — drives whether `StoreClient`
/// finishes it.
public enum VerificationDecision: Sendable, Equatable {
    /// Entitlement confirmed. Finish the transaction.
    case grant
    /// Invalid / unauthorized (e.g. appAccountToken mismatch). Finish to consume
    /// it so Apple stops redelivering, but don't grant anything.
    case reject
    /// Not confirmed yet (server hasn't acknowledged). Do **not** finish — let
    /// Apple redeliver on the next launch/cycle until the grant lands.
    case deferFinish
}

/// Result of a user-initiated purchase.
public enum PurchaseOutcome: Sendable, Equatable {
    case success
    /// Deferred (e.g. Ask to Buy) — resolves later via the transaction listener.
    case pending
    case userCancelled
}

/// A canonical, client-side snapshot of active entitlements derived from
/// `Transaction.currentEntitlements`. For server-authoritative apps this is the
/// fast local signal + self-heal; the backend remains the source of truth.
/// Consumables never appear here (they're finished/consumed), so credit balances
/// stay app-side.
public struct EntitlementSnapshot: Sendable, Equatable {
    /// Product IDs with an active, non-revoked entitlement.
    public var activeProductIDs: Set<String>
    /// Soonest relevant renewal/expiry among active subscriptions (nil if none / lifetime only).
    public var expiry: Date?
    /// True when a non-consumable (one-time / lifetime) entitlement is active.
    public var isLifetime: Bool

    public init(activeProductIDs: Set<String> = [], expiry: Date? = nil, isLifetime: Bool = false) {
        self.activeProductIDs = activeProductIDs
        self.expiry = expiry
        self.isLifetime = isLifetime
    }

    /// Any active entitlement at all.
    public var isActive: Bool { !activeProductIDs.isEmpty }

    /// Whether a specific product is currently entitled.
    public func isActive(_ productID: String) -> Bool { activeProductIDs.contains(productID) }

    public static let none = EntitlementSnapshot()
}
