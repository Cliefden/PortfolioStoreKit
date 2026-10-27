import Foundation
import StoreKit

/// A fixed, low-cardinality reason for a thrown purchase / restore error —
/// safe for analytics (no associated values or localized text, which can
/// carry account details). From Equinox `purchaseFailureReason` and
/// Contrarian `PaywallView.failureReason`; raw values follow Equinox.
///
/// ```swift
/// } catch {
///     let reason = PurchaseFailure.reason(for: error)
///     if !reason.isUserCancellation {
///         Analytics.signal("purchase.failed", parameters: ["reason": reason.rawValue])
///     }
/// }
/// ```
public enum PurchaseFailure: String, Sendable, CaseIterable {
    // StoreKitError
    case userCancelled
    case network
    case systemError
    case notAvailableInStorefront
    case notEntitled
    case unknown
    case storeKitOther
    // Product.PurchaseError
    case productUnavailable
    case purchaseNotAllowed
    case ineligibleForOffer
    case invalidOffer
    case invalidQuantity
    case purchaseErrorOther
    // Anything else
    case cancelled
    case other

    public static func reason(for error: Error) -> PurchaseFailure {
        if let storeKitError = error as? StoreKitError {
            switch storeKitError {
            case .userCancelled: return .userCancelled
            case .networkError: return .network
            case .systemError: return .systemError
            case .notAvailableInStorefront: return .notAvailableInStorefront
            case .notEntitled: return .notEntitled
            case .unknown: return .unknown
            default: return .storeKitOther
            }
        }
        if let purchaseError = error as? Product.PurchaseError {
            switch purchaseError {
            case .productUnavailable: return .productUnavailable
            case .purchaseNotAllowed: return .purchaseNotAllowed
            case .ineligibleForOffer: return .ineligibleForOffer
            case .invalidOfferIdentifier, .invalidOfferPrice, .invalidOfferSignature, .missingOfferParameters:
                return .invalidOffer
            case .invalidQuantity: return .invalidQuantity
            default: return .purchaseErrorOther
            }
        }
        if error is CancellationError { return .cancelled }
        if error is URLError || (error as NSError).domain == NSURLErrorDomain { return .network }
        return .other
    }

    /// The user backed out (not a failure worth surfacing or counting as one).
    public var isUserCancellation: Bool { self == .userCancelled }
}
