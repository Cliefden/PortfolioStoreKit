# PortfolioStoreKit

Shared **StoreKit 2 purchase engine** for the Apps-AppStore family. Owns the mechanics the
apps re-implement (load / purchase / restore / `Transaction.updates` / verify / finish);
apps supply product IDs, a verifier, and their own feature gates + paywall UI. Companion to
`PortfolioKit` (UI-only — `SubscriptionStatusCard` renders the state this produces). Scoped in
`Celiador/_standard/PORTFOLIOSTOREKIT_SCOPING.md`.

## Use

**Local-entitlement app** (one-time unlock, trusts StoreKit — e.g. Equinox, Lunker):

```swift
let store = StoreClient(productIDs: ["com.equinox.pro"])   // LocalVerifier by default
await store.loadProducts()
try await store.purchase(store.products[0])
// gate features on:
store.entitlements.isActive("com.equinox.pro")
```

**Server-entitlement app** (backend JWS verification — e.g. ThenCam, Contrarian, Stokked):

```swift
let store = StoreClient(
    productIDs: ["ai_credits_unlimited2"],
    verifier: ServerVerifier(
        appAccountToken: { await supabase.currentUser?.id },
        submit: { jws in
            // POST jws to your edge function; map its result:
            await backend.verifyApplePurchase(jws) ? .grant : .deferFinish
        }
    )
)
```

Return `.deferFinish` while the backend hasn't confirmed, so the transaction stays unfinished
and Apple redelivers until the grant lands. The backend stays the source of truth; `entitlements`
is the fast local signal + self-heal.

## What's in / out
- **In:** `StoreClient` (@Observable @MainActor), `PurchaseVerifier` (+ `LocalVerifier`,
  `ServerVerifier`), `EntitlementSnapshot`, `VerificationDecision`, `PurchaseOutcome`.
- **Out (stay in the app):** product IDs, backend verify endpoint, feature gates / credit
  balances, consumable grant logic, app-managed trials, paywall UI.

## Build / test

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
```

(Plain Command Line Tools can't link the SPM manifest — point at a full Xcode.)

## Versioning
Tagged releases; apps depend on it by URL + version (CI-safe — resolvable in Xcode Cloud).
