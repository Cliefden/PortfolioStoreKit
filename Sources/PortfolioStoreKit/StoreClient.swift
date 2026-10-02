import StoreKit
import Observation

/// The shared StoreKit 2 engine. Loads products, runs purchases (stamping the
/// verifier's `appAccountToken`), restores, listens to `Transaction.updates`,
/// routes each verified transaction through the `PurchaseVerifier`, and finishes
/// transactions per the returned `VerificationDecision`. Observe `entitlements`
/// for the client-side signal; server-authoritative apps keep their backend as
/// the source of truth and feed the final state into their UI.
@MainActor
@Observable
public final class StoreClient {
    /// Loaded products for the configured IDs (empty until `loadProducts()`).
    public private(set) var products: [Product] = []
    /// Active entitlements derived from `Transaction.currentEntitlements`.
    public private(set) var entitlements: EntitlementSnapshot = .none
    public private(set) var isLoadingProducts = false

    @ObservationIgnored private let productIDs: [String]
    @ObservationIgnored private let verifier: PurchaseVerifier
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    public init(productIDs: [String], verifier: PurchaseVerifier = LocalVerifier()) {
        self.productIDs = productIDs
        self.verifier = verifier
        // Catch renewals, refunds, Ask-to-Buy approvals, and cross-device /
        // re-download transactions that arrive outside a direct purchase.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.process(update, verify: true)
            }
        }
        // Prime the snapshot without re-posting to any backend on launch.
        Task { [weak self] in await self?.recomputeSnapshot() }
    }

    deinit { updatesTask?.cancel() }

    /// Fetch `Product`s for the configured IDs from the App Store.
    public func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        products = (try? await Product.products(for: productIDs)) ?? []
    }

    /// Start a purchase. Stamps the verifier's `appAccountToken` when present.
    @discardableResult
    public func purchase(_ product: Product) async throws -> PurchaseOutcome {
        var options: Set<Product.PurchaseOption> = []
        if let token = await verifier.appAccountToken {
            options.insert(.appAccountToken(token))
        }
        switch try await product.purchase(options: options) {
        case .success(let verification):
            await process(verification, verify: true)
            return .success
        case .pending:
            return .pending
        case .userCancelled:
            return .userCancelled
        @unknown default:
            return .pending
        }
    }

    /// Restore purchases: sync with the App Store, re-submit current entitlements
    /// through the verifier (self-heal for server apps), then recompute.
    public func restore() async throws {
        try await AppStore.sync()
        for await result in Transaction.currentEntitlements {
            if case .verified(let txn) = result {
                _ = await verifier.verify(txn, jws: result.jwsRepresentation)
            }
        }
        await recomputeSnapshot()
    }

    // MARK: - Internals

    /// Verify one transaction and finish it per the decision, then refresh the
    /// snapshot. `verify: false` would skip the backend round-trip (unused today).
    private func process(_ result: VerificationResult<Transaction>, verify: Bool) async {
        guard case .verified(let txn) = result else { return }
        let decision = verify ? await verifier.verify(txn, jws: result.jwsRepresentation) : .grant
        switch decision {
        case .grant, .reject:
            await txn.finish()      // consume so Apple stops redelivering
        case .deferFinish:
            break                   // leave unfinished — redeliver until the backend grants
        }
        await recomputeSnapshot()
    }

    /// Rebuild `entitlements` from StoreKit's current entitlements. Pure — no
    /// verifier/backend calls (so launches and UI refreshes don't post).
    private func recomputeSnapshot() async {
        var active: Set<String> = []
        var soonest: Date?
        var lifetime = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let txn) = result, txn.revocationDate == nil else { continue }
            if let expiry = txn.expirationDate {
                guard expiry > .now else { continue }
                active.insert(txn.productID)
                soonest = Swift.min(soonest ?? expiry, expiry)
            } else {
                active.insert(txn.productID)
                if txn.productType == .nonConsumable { lifetime = true }
            }
        }
        entitlements = EntitlementSnapshot(activeProductIDs: active, expiry: soonest, isLifetime: lifetime)
    }
}
