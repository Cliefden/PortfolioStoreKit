import StoreKit
import Observation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// The shared StoreKit 2 engine. Loads products, runs purchases (stamping the
/// verifier's `appAccountToken`), restores, listens to `Transaction.updates`,
/// routes each verified transaction through the `PurchaseVerifier`, and finishes
/// transactions per the returned `VerificationDecision`. Observe `entitlements`
/// for the client-side signal; server-authoritative apps keep their backend as
/// the source of truth and feed the final state into their UI.
///
/// Optional (0.2): an `EntitlementCache` seeds `entitlements` at launch and is
/// rewritten after every refresh; `stickyNonConsumables` additionally keeps a
/// previously-owned non-consumable unlocked (provisionally) while StoreKit
/// can't vouch for it — see `StickyEntitlementPolicy`.
@MainActor
@Observable
public final class StoreClient {
    /// Loaded products for the configured IDs (empty until `loadProducts()`).
    public private(set) var products: [Product] = []
    /// Active entitlements derived from `Transaction.currentEntitlements`
    /// (plus cached / provisional products when a cache is configured).
    public private(set) var entitlements: EntitlementSnapshot = .none
    public private(set) var isLoadingProducts = false
    /// True while `entitlements` includes products StoreKit hasn't confirmed:
    /// the cache seed before the first refresh, or sticky non-consumables kept
    /// through an empty `currentEntitlements`.
    public private(set) var isProvisional = false
    /// The products currently granted without StoreKit confirmation.
    public private(set) var provisionalProductIDs: Set<String> = []
    /// StoreKit has answered at least once this launch.
    public private(set) var hasLoadedEntitlements = false

    @ObservationIgnored private let productIDs: [String]
    @ObservationIgnored private let verifier: PurchaseVerifier
    @ObservationIgnored private let cache: (any EntitlementCache)?
    @ObservationIgnored private let stickyNonConsumables: Bool
    /// Non-consumables seen revoked this session (definitive downgrade).
    @ObservationIgnored private var revokedProductIDs: Set<String> = []
    /// Non-consumables granted this session. `currentEntitlements` can lag a
    /// just-verified purchase (Otta's `purchaseGeneration` guard); these count
    /// as current until revoked.
    @ObservationIgnored private var grantedProductIDs: Set<String> = []
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    /// The most recent refresh; each new one waits for it so results apply in order.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// - Parameters:
    ///   - productIDs: the products this client loads and reports.
    ///   - verifier: `LocalVerifier()` (default) or a `ServerVerifier`.
    ///   - cache: persists the last verified reading (launch hint, App Group
    ///     for widgets). `nil` = 0.1 behaviour.
    ///   - stickyNonConsumables: keep cached non-consumables through an empty
    ///     `currentEntitlements` until revocation / proven absence (Equinox's
    ///     safeguard). Requires `cache`.
    public init(productIDs: [String],
                verifier: PurchaseVerifier = LocalVerifier(),
                cache: (any EntitlementCache)? = nil,
                stickyNonConsumables: Bool = false) {
        self.productIDs = productIDs
        self.verifier = verifier
        self.cache = cache
        self.stickyNonConsumables = stickyNonConsumables && cache != nil

        // Last launch's reading, so owned features open from the first frame.
        if let cached = cache?.load() {
            let seed = EntitlementSnapshot(cached: cached, productIDs: Set(productIDs), now: .now)
            if seed.isActive {
                entitlements = seed
                provisionalProductIDs = seed.activeProductIDs
                isProvisional = true
            }
        }

        // Catch renewals, refunds, Ask-to-Buy approvals, and cross-device /
        // re-download transactions that arrive outside a direct purchase.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.process(update, verify: true)
            }
        }
        // Prime the snapshot without re-posting to any backend on launch.
        Task { [weak self] in await self?.refreshEntitlements() }
    }

    deinit { updatesTask?.cancel() }

    /// Fetch `Product`s for the configured IDs from the App Store.
    public func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        products = (try? await Product.products(for: productIDs)) ?? []
    }

    /// Start a purchase. Stamps the verifier's `appAccountToken` when present.
    /// (visionOS requires a confirmation scene: use `purchase(_:confirmIn:)` or
    /// SwiftUI's `PurchaseAction` + `handle(_:)`.)
    @available(visionOS, unavailable)
    @discardableResult
    public func purchase(_ product: Product) async throws -> PurchaseOutcome {
        let result = try await product.purchase(options: await purchaseOptions())
        return await handle(result)
    }

    #if canImport(UIKit) && !os(watchOS)
    /// Start a purchase confirmed in `scene` (required on visionOS; optional on iOS).
    @discardableResult
    public func purchase(_ product: Product, confirmIn scene: UIScene) async throws -> PurchaseOutcome {
        let result = try await product.purchase(confirmIn: scene, options: await purchaseOptions())
        return await handle(result)
    }
    #endif

    /// The options `StoreClient` stamps on a purchase (the verifier's
    /// `appAccountToken`). Pass them to SwiftUI's `PurchaseAction` when you
    /// purchase through the environment, then route the result to `handle(_:)`.
    public func purchaseOptions() async -> Set<Product.PurchaseOption> {
        var options: Set<Product.PurchaseOption> = []
        if let token = await verifier.appAccountToken {
            options.insert(.appAccountToken(token))
        }
        return options
    }

    /// Process a purchase result obtained elsewhere (SwiftUI `PurchaseAction`,
    /// `purchase(confirmIn:)`): verify, finish per the verifier, refresh.
    @discardableResult
    public func handle(_ result: Product.PurchaseResult) async -> PurchaseOutcome {
        switch result {
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
    /// through the verifier (self-heal for server apps), then recompute. A
    /// successful sync makes the history authoritative, so sticky products
    /// missing from it are dropped.
    public func restore() async throws {
        try await AppStore.sync()
        for await result in Transaction.currentEntitlements {
            if case .verified(let txn) = result {
                _ = await verifier.verify(txn, jws: result.jwsRepresentation)
            }
        }
        await refresh(authoritative: true)
    }

    /// Re-read entitlements from StoreKit (no verifier/backend calls). Call when
    /// the app becomes active; `StoreClient` already refreshes at launch and
    /// after every transaction.
    public func refreshEntitlements() async {
        await refresh(authoritative: false)
    }

    // MARK: - Internals

    /// Verify one transaction and finish it per the decision, then refresh the
    /// snapshot. `verify: false` would skip the backend round-trip (unused today).
    private func process(_ result: VerificationResult<Transaction>, verify: Bool) async {
        guard case .verified(let txn) = result else { return }
        // Revoked (refund / chargeback / family-sharing removal): consume it and never
        // route to the verifier. A backend "not entitled" reply would otherwise read as
        // `.deferFinish` and Apple would redeliver the revoked transaction forever.
        if txn.revocationDate != nil {
            revokedProductIDs.insert(txn.productID)
            grantedProductIDs.remove(txn.productID)
            await txn.finish()
            await refreshEntitlements()
            return
        }
        revokedProductIDs.remove(txn.productID)
        let decision = verify ? await verifier.verify(txn, jws: result.jwsRepresentation) : .grant
        if decision == .grant, txn.productType == .nonConsumable, productIDs.contains(txn.productID) {
            grantedProductIDs.insert(txn.productID)
        }
        switch decision {
        case .grant, .reject:
            await txn.finish()      // consume so Apple stops redelivering
        case .deferFinish:
            break                   // leave unfinished — redeliver until the backend grants
        }
        await refreshEntitlements()
    }

    /// Serialized: a refresh started while another runs applies after it.
    private func refresh(authoritative: Bool) async {
        let previous = refreshTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.recomputeSnapshot(authoritative: authoritative)
        }
        refreshTask = task
        await task.value
    }

    /// Rebuild `entitlements` from StoreKit's current entitlements. Pure — no
    /// verifier/backend calls (so launches and UI refreshes don't post).
    private func recomputeSnapshot(authoritative: Bool) async {
        var active: Set<String> = []
        var nonConsumables: Set<String> = []
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
                if txn.productType == .nonConsumable {
                    lifetime = true
                    nonConsumables.insert(txn.productID)
                }
            }
        }
        let justGranted = grantedProductIDs.subtracting(nonConsumables)
        if !justGranted.isEmpty {
            active.formUnion(justGranted)
            nonConsumables.formUnion(justGranted)
            lifetime = true
        }
        let observed = EntitlementSnapshot(activeProductIDs: active, expiry: soonest, isLifetime: lifetime)
        let observedRecord = CachedEntitlements(productIDs: active, nonConsumableIDs: nonConsumables,
                                                expiry: soonest, verifiedAt: .now)
        hasLoadedEntitlements = true

        guard let cache else {
            apply(observed, provisional: [])
            return
        }
        guard stickyNonConsumables else {
            // Launch hint only (Enigma): StoreKit's answer replaces the cache.
            cache.save(observedRecord)
            apply(observed, provisional: [])
            return
        }

        let previous = cache.load()
        let cachedNonConsumables = (previous?.nonConsumableIDs ?? []).intersection(productIDs)
        let candidates = cachedNonConsumables.subtracting(nonConsumables)
        let history = candidates.isEmpty ? nil : await scanHistory(authoritative: authoritative)
        let resolution = StickyEntitlementPolicy.resolve(current: nonConsumables,
                                                         cached: cachedNonConsumables,
                                                         revoked: revokedProductIDs,
                                                         history: history)
        if let update = StickyEntitlementPolicy.cacheUpdate(observed: observedRecord,
                                                            resolution: resolution,
                                                            previous: previous) {
            cache.save(update)
        }
        // History-confirmed products are owned, just missing from currentEntitlements.
        let confirmedExtra = resolution.confirmed.subtracting(nonConsumables)
        apply(observed.adding(provisional: confirmedExtra), provisional: resolution.provisional)
    }

    private func apply(_ snapshot: EntitlementSnapshot, provisional: Set<String>) {
        entitlements = snapshot.adding(provisional: provisional)
        provisionalProductIDs = provisional
        isProvisional = !provisional.isEmpty
    }

    /// Sweep `Transaction.all` for the configured products (Equinox's
    /// revocation-aware refresh).
    private func scanHistory(authoritative: Bool) async -> TransactionHistoryScan {
        var owned: Set<String> = []
        var revoked: Set<String> = []
        var count = 0
        for await result in Transaction.all {
            guard case .verified(let txn) = result else { continue }
            count += 1
            guard productIDs.contains(txn.productID) else { continue }
            if txn.revocationDate == nil {
                owned.insert(txn.productID)
            } else {
                revoked.insert(txn.productID)
            }
        }
        return TransactionHistoryScan(owned: owned, revoked: revoked,
                                      transactionCount: count, isAuthoritative: authoritative)
    }
}
