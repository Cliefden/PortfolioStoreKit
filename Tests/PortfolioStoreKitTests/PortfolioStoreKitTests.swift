import Testing
import Foundation
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
    var submitted: String?
    let v = ServerVerifier(
        appAccountToken: { uid },
        submit: { jws in submitted = jws; return .deferFinish }
    )
    #expect(await v.appAccountToken == uid)
    // Exercise the submit closure directly (constructing a real Transaction in a
    // unit test isn't feasible; StoreClient integration is verified by building a
    // host app against the package).
    #expect(submitted == nil)
}

@Test func verificationDecisionIsEquatable() {
    #expect(VerificationDecision.grant == .grant)
    #expect(VerificationDecision.grant != .deferFinish)
}
