import Testing
import Foundation
import StoreKit
@testable import PortfolioStoreKit

private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
private let pro = "com.app.pro"
private let pack = "com.app.pack"

@Suite struct StickyResolutionRules {
    @Test func currentEntitlementConfirms() {
        let r = StickyEntitlementPolicy.resolve(current: [pro], cached: [pro], history: nil)
        #expect(r == StickyResolution(confirmed: [pro]))
    }

    @Test func emptyCurrentKeepsCachedProvisionallyBeforeScan() {
        let r = StickyEntitlementPolicy.resolve(current: [], cached: [pro], history: nil)
        #expect(r.provisional == [pro])
        #expect(r.owned == [pro])
    }

    @Test func emptyUnauthoritativeHistoryKeepsCached() {
        // Signed out of the App Store: Transaction.all is empty too (Equinox safeguard).
        let r = StickyEntitlementPolicy.resolve(current: [], cached: [pro], history: TransactionHistoryScan())
        #expect(r.provisional == [pro])
        #expect(r.dropped.isEmpty)
    }

    @Test func emptyHistoryAfterSuccessfulSyncProvesAbsence() {
        let r = StickyEntitlementPolicy.resolve(current: [], cached: [pro],
                                                history: TransactionHistoryScan(isAuthoritative: true))
        #expect(r.dropped == [pro])
        #expect(r.owned.isEmpty)
    }

    @Test func readableHistoryWithoutProductProvesAbsence() {
        let history = TransactionHistoryScan(owned: [pack], transactionCount: 3)
        let r = StickyEntitlementPolicy.resolve(current: [pack], cached: [pro, pack], history: history)
        #expect(r.confirmed == [pack])
        #expect(r.dropped == [pro])
    }

    @Test func unrevokedHistoryConfirms() {
        // currentEntitlements lagging, but Transaction.all has it.
        let history = TransactionHistoryScan(owned: [pro], transactionCount: 1)
        let r = StickyEntitlementPolicy.resolve(current: [], cached: [pro], history: history)
        #expect(r.confirmed == [pro])
        #expect(r.provisional.isEmpty)
    }

    @Test func revocationInHistoryDrops() {
        let history = TransactionHistoryScan(revoked: [pro], transactionCount: 1)
        let r = StickyEntitlementPolicy.resolve(current: [], cached: [pro], history: history)
        #expect(r.dropped == [pro])
    }

    @Test func repurchaseAfterRefundIsOwned() {
        let history = TransactionHistoryScan(owned: [pro], revoked: [pro], transactionCount: 2)
        #expect(history.revoked.isEmpty)
        #expect(StickyEntitlementPolicy.resolve(current: [], cached: [pro], history: history).confirmed == [pro])
    }

    @Test func sessionRevocationEventDropsEvenWithoutHistory() {
        let r = StickyEntitlementPolicy.resolve(current: [], cached: [pro], revoked: [pro], history: nil)
        #expect(r.dropped == [pro])
        #expect(r.owned.isEmpty)
    }

    @Test func uncachedProductsAreIgnored() {
        let r = StickyEntitlementPolicy.resolve(current: [], cached: [], history: TransactionHistoryScan())
        #expect(r == StickyResolution())
    }
}

@Suite struct StickyCacheUpdate {
    let earlier = t0.addingTimeInterval(-10 * 86_400)

    @Test func confirmedReadingIsWrittenFresh() {
        let observed = CachedEntitlements(productIDs: [pro], nonConsumableIDs: [pro], verifiedAt: t0)
        let previous = CachedEntitlements(productIDs: [pro], nonConsumableIDs: [pro], verifiedAt: earlier)
        let update = StickyEntitlementPolicy.cacheUpdate(observed: observed,
                                                         resolution: StickyResolution(confirmed: [pro]),
                                                         previous: previous)
        #expect(update?.verifiedAt == t0)
        #expect(update?.nonConsumableIDs == [pro])
    }

    @Test func provisionalKeepsPreviousTimestamp() {
        let observed = CachedEntitlements(productIDs: [], verifiedAt: t0)
        let previous = CachedEntitlements(productIDs: [pro], nonConsumableIDs: [pro], verifiedAt: earlier)
        let update = StickyEntitlementPolicy.cacheUpdate(observed: observed,
                                                         resolution: StickyResolution(provisional: [pro]),
                                                         previous: previous)
        // Nothing changed — leave the cache (and its age) alone.
        #expect(update == nil)
    }

    @Test func provisionalWithOtherChangesPreservesAge() {
        let observed = CachedEntitlements(productIDs: [], verifiedAt: t0)
        let previous = CachedEntitlements(productIDs: [pro, pack], nonConsumableIDs: [pro, pack], verifiedAt: earlier)
        let update = StickyEntitlementPolicy.cacheUpdate(observed: observed,
                                                         resolution: StickyResolution(provisional: [pro], dropped: [pack]),
                                                         previous: previous)
        #expect(update == CachedEntitlements(productIDs: [pro], nonConsumableIDs: [pro], verifiedAt: earlier))
    }

    @Test func droppedProductIsRemoved() {
        let observed = CachedEntitlements(productIDs: [], verifiedAt: t0)
        let previous = CachedEntitlements(productIDs: [pro], nonConsumableIDs: [pro], verifiedAt: earlier)
        let update = StickyEntitlementPolicy.cacheUpdate(observed: observed,
                                                         resolution: StickyResolution(dropped: [pro]),
                                                         previous: previous)
        #expect(update?.isEmpty == true)   // empty save → cache cleared
    }

    @Test func provisionalSnapshotIsLifetime() {
        let snap = EntitlementSnapshot.none.adding(provisional: [pro])
        #expect(snap.isActive(pro))
        #expect(snap.isLifetime)
        #expect(EntitlementSnapshot.none.adding(provisional: []) == .none)
    }
}

@Suite struct PurchaseFailureMapping {
    @Test func storeKitErrors() {
        #expect(PurchaseFailure.reason(for: StoreKitError.userCancelled) == .userCancelled)
        #expect(PurchaseFailure.reason(for: StoreKitError.userCancelled).isUserCancellation)
        #expect(PurchaseFailure.reason(for: StoreKitError.networkError(URLError(.notConnectedToInternet))) == .network)
        #expect(PurchaseFailure.reason(for: StoreKitError.notAvailableInStorefront) == .notAvailableInStorefront)
        #expect(PurchaseFailure.reason(for: StoreKitError.notEntitled) == .notEntitled)
        #expect(PurchaseFailure.reason(for: StoreKitError.unknown) == .unknown)
    }

    @Test func purchaseErrors() {
        #expect(PurchaseFailure.reason(for: Product.PurchaseError.productUnavailable) == .productUnavailable)
        #expect(PurchaseFailure.reason(for: Product.PurchaseError.purchaseNotAllowed) == .purchaseNotAllowed)
        #expect(PurchaseFailure.reason(for: Product.PurchaseError.invalidOfferSignature) == .invalidOffer)
        #expect(PurchaseFailure.reason(for: Product.PurchaseError.ineligibleForOffer) == .ineligibleForOffer)
    }

    @Test func otherErrors() {
        struct Boom: Error {}
        #expect(PurchaseFailure.reason(for: URLError(.timedOut)) == .network)
        #expect(PurchaseFailure.reason(for: CancellationError()) == .cancelled)
        #expect(PurchaseFailure.reason(for: Boom()) == .other)
        #expect(PurchaseFailure.reason(for: Boom()).rawValue == "other")
        #expect(PurchaseFailure.userCancelled.rawValue == "userCancelled")
    }
}
