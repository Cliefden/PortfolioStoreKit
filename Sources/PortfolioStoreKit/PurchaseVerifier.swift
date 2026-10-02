import StoreKit

/// The app-specific seam. `StoreClient` routes every StoreKit-verified
/// transaction through this to decide whether to grant + finish it, and asks it
/// for the `appAccountToken` to stamp on purchases. Two built-ins cover the
/// portfolio's two shapes; apps rarely need a custom one.
public protocol PurchaseVerifier: Sendable {
    /// The Supabase/user UUID to stamp on purchases so a backend webhook can map
    /// the transaction to the user. `nil` for local-only apps.
    var appAccountToken: UUID? { get async }

    /// Decide a transaction that StoreKit already cryptographically verified.
    func verify(_ transaction: Transaction, jws: String) async -> VerificationDecision
}

/// Trusts StoreKit's on-device verification — no backend. Always grants.
/// For one-time / local-entitlement apps (Equinox, Lunker, Nassau).
public struct LocalVerifier: PurchaseVerifier {
    public init() {}
    public var appAccountToken: UUID? { get async { nil } }
    public func verify(_ transaction: Transaction, jws: String) async -> VerificationDecision { .grant }
}

/// Posts the signed transaction (JWS) to the app's backend, which does the
/// authoritative JWS-chain verification and returns the decision. For
/// server-entitlement apps (Contrarian, Stokked, ThenCam, Carpe Vitem). Return
/// `.deferFinish` from `submit` while the grant is still pending so Apple
/// redelivers until the backend confirms.
public struct ServerVerifier: PurchaseVerifier {
    private let tokenProvider: @Sendable () async -> UUID?
    private let submit: @Sendable (_ jws: String) async -> VerificationDecision

    public init(
        appAccountToken: @escaping @Sendable () async -> UUID? = { nil },
        submit: @escaping @Sendable (_ jws: String) async -> VerificationDecision
    ) {
        self.tokenProvider = appAccountToken
        self.submit = submit
    }

    public var appAccountToken: UUID? { get async { await tokenProvider() } }

    public func verify(_ transaction: Transaction, jws: String) async -> VerificationDecision {
        await submit(jws)
    }
}
