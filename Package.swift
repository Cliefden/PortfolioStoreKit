// swift-tools-version: 5.9
import PackageDescription

// Shared StoreKit 2 purchase engine for the Apps-AppStore family. Owns the
// mechanics every app re-implements (load / purchase / restore / Transaction
// updates / verify / finish); apps supply product IDs, a verifier (local or
// server), and their own feature gates + paywall UI. Companion to PortfolioKit
// (UI-only). See Celiador/_standard/PORTFOLIOSTOREKIT_SCOPING.md.
let package = Package(
    name: "PortfolioStoreKit",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "PortfolioStoreKit", targets: ["PortfolioStoreKit"]),
    ],
    targets: [
        .target(name: "PortfolioStoreKit"),
        .testTarget(name: "PortfolioStoreKitTests", dependencies: ["PortfolioStoreKit"]),
    ]
)
