import Testing
import Foundation
import StoreKit
@testable import PortfolioStoreKit

@Test func entitlementSnapshotActivity() {
    #expect(EntitlementSnapshot.none.isActive == false)
    let s = EntitlementSnapshot(activeProductIDs: ["com.app.pro"], isLifetime: true)
    #expect(s.isActive)
    #expect(s.isActive("com.app.pro"))
    #expect(s.isActive("com.app.other") == false)
    #expect(s.isLifetime)
}

@Test func localVerifierGrantsAndHasNoToken() async {
    let v = LocalVerifier()
    #expect(await v.appAccountToken == nil)
}

@Test func serverVerifierPassesTokenAndDecision() async {
    let uid = UUID()
    let v = ServerVerifier(
        appAccountToken: { uid },
        submit: { _ in .deferFinish }
    )
    #expect(await v.appAccountToken == uid)
    // `verify` needs a real Transaction, which a unit test can't construct;
    // StoreClient integration is verified by building a host app against the package.
}

/// Compile-only: the 0.1.x call shapes ThenCam's StoreManager uses must keep
/// type-checking (never executed — constructing a StoreClient starts a
/// Transaction.updates listener).
@MainActor
private func zeroOneSourceCompatibility(_ product: Product) async throws {
    let store = StoreClient(
        productIDs: ["ios.thencam.bernini.pro"],
        verifier: ServerVerifier(appAccountToken: { nil }, submit: { _ in .deferFinish })
    )
    _ = StoreClient(productIDs: ["com.equinox.pro"])
    await store.loadProducts()
    _ = store.products.first
    switch try await store.purchase(product) {
    case .success, .pending, .userCancelled: break
    }
    try await store.restore()
    _ = store.entitlements.isActive("ios.thencam.bernini.pro")
}

@Test func verificationDecisionIsEquatable() {
    #expect(VerificationDecision.grant == .grant)
    #expect(VerificationDecision.grant != .deferFinish)
}
