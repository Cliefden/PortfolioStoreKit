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

### Sticky entitlement cache (0.2)

`currentEntitlements` is empty both when a purchase was **revoked** and when the device simply
can't vouch for it (signed out of the App Store, history not synced). Local-verification apps
must not lock out a payer in the second case. Pass a cache and opt in:

```swift
let store = StoreClient(
    productIDs: ["com.equinox.pro"],
    cache: UserDefaultsEntitlementCache(suiteName: "group.com.equinox.shared",
                                        legacyFlags: ["isProUser": "com.equinox.pro"]),
    stickyNonConsumables: true
)
store.entitlements.isActive("com.equinox.pro")   // seeded from the cache on the first frame
store.isProvisional                              // true while unlocked on the cache's word only
```

Rules (`StickyEntitlementPolicy.resolve`, pure + unit-tested): a cached **non-consumable**
missing from `currentEntitlements` is kept *provisionally* until StoreKit gives a definitive
answer — a transaction for it with a `revocationDate` (via `Transaction.updates` or
`Transaction.all`), or a `Transaction.all` scan that **proves absence** (history is readable:
it contains other transactions, or `restore()`'s `AppStore.sync()` just succeeded). An empty,
unauthoritative history keeps the unlock (Equinox's "keep cached when empty" safeguard). A
product found unrevoked in `Transaction.all` is confirmed. Subscriptions are never sticky.

While anything is provisional the cache's `verifiedAt` is not refreshed, so a
`SealedEntitlementCache` `maxAge` still runs out on a device that never reconfirms.

Without `stickyNonConsumables`, a cache is a **launch hint** only (Enigma): it seeds
`entitlements` (`isProvisional == true`) and StoreKit's first answer replaces it.

| Cache | Use |
|---|---|
| `UserDefaultsEntitlementCache(suiteName:key:legacyFlags:)` | App Group capable — widgets / watch / background launches read it (`load()?.isActive(id)`). `legacyFlags` keep writing the app's old Bool key and seed from it on first run. |
| `SealedEntitlementCache(keyService:keyAccount:defaults:defaultsKey:bundleID:maxAge:)` | HMAC-SHA256 sealed with a random 256-bit key in this device's Keychain (`ThisDeviceOnly`). Hand-edited / restored-to-another-device / other-bundle / older-than-`maxAge` (60 d default) records read as no cache. Reads Enigma's v1 record format. |

Custom stores conform to `EntitlementCache` (`load` / `save` / `clear`, synchronous).

### App-managed trial (0.2)

For non-consumables (no StoreKit intro offers). One per install lifetime; the Keychain copy
survives delete + reinstall; **earliest recorded date wins**.

```swift
let trial = Trial(duration: Trial.fourteenDays,
                  store: KeychainTrialStore(service: "com.lunker.premium", account: "trialStart"))
try trial.start()                         // no-op if ever started; throws if it couldn't persist
switch try trial.state() {                // throws while the Keychain is locked = unknown
case .notStarted: …
case .active(let endsAt): …
case .expired: …
}
let unlocked = store.entitlements.isActive(id) || ((try? trial.state())?.isActive ?? false)
```

- `TrialPersistence` protocol; `KeychainTrialStore(service:account:accessGroup:mirror:)`;
  `UserDefaultsTrialStore(suiteName:key:)` for tests/dev or as the Keychain store's `mirror`
  (an App Group copy widgets can read; loads combine both, earliest wins, and repair whichever
  side is missing).
- A corrupt record counts as "trial used" (`.expired`), never a fresh trial.
- A start in the future (clock rolled back) counts as `.expired`.
- `TrialClock` (`.system`, `.fixed(date)`) for tests; `Trial.state(startedAt:duration:now:)` is pure.
- `TrialState.analyticsLabel` = `"none"` / `"active"` / `"expired"`.
- Reads both Keychain formats in the wild: Lunker/Sextant's UTF-8 timestamp string and
  Equinox's raw `Double` bytes (writes the string form).

### Purchase failure reasons (0.2)

```swift
} catch {
    let reason = PurchaseFailure.reason(for: error)      // low-cardinality, analytics-safe
    if !reason.isUserCancellation { Analytics.signal("purchase.failed", ["reason": reason.rawValue]) }
}
```

Raw values follow Equinox (`userCancelled`, `network`, `systemError`, `notAvailableInStorefront`,
`notEntitled`, `unknown`, `storeKitOther`, `productUnavailable`, `purchaseNotAllowed`, …, `other`).
Contrarian's dashboards used `system` / `storeKit` — map those two if continuity matters.

### visionOS

`Product.purchase(options:)` is unavailable on visionOS, so `StoreClient.purchase(_:)` is too.
Use `purchase(_:confirmIn: scene)` (iOS + visionOS) or SwiftUI's `PurchaseAction` with
`await store.purchaseOptions()`, then `await store.handle(result)`.

## What's in / out
- **In:** `StoreClient` (@Observable @MainActor), `PurchaseVerifier` (+ `LocalVerifier`,
  `ServerVerifier`), `EntitlementSnapshot`, `VerificationDecision`, `PurchaseOutcome`;
  0.2: `EntitlementCache` (+ `UserDefaultsEntitlementCache`, `SealedEntitlementCache`,
  `CachedEntitlements`), `StickyEntitlementPolicy` / `StickyResolution` /
  `TransactionHistoryScan`, `Trial` / `TrialState` / `TrialClock` / `TrialPersistence`
  (+ `KeychainTrialStore`, `UserDefaultsTrialStore`), `PurchaseFailure`.
- **Out (stay in the app):** product IDs, backend verify endpoint, feature gates / credit
  balances, consumable grant logic, trial opt-in UI + analytics, paywall UI.

## Migration guide

| App | Today | Move to |
|---|---|---|
| **Enigma** | `Store.swift` + `EntitlementsCache` | `StoreClient(productIDs:, cache: SealedEntitlementCache(keyService: "se.enigma.app.entitlements-hint", defaultsKey: "entitlements.hint.v1"))`. `Store.entitlements.owned` ≈ `entitlements.activeProductIDs`, `isProvisional` maps 1:1, `phase` stays app-side (drive it from `PurchaseOutcome`). Existing sealed hints stay valid. Keep the `-premium` DEBUG override app-side. |
| **Jeroboam** | `StoreService` (annual sub + lifetime) | `StoreClient(productIDs: ProductID.all)` with the default `LocalVerifier`; `hasPremium` = `entitlements.isActive`, `purchasedProductIDs` = `entitlements.activeProductIDs`. |
| **Nassau** | `PremiumService` (`ObservableObject`, sub + lifetime) | `StoreClient` + `LocalVerifier`; keep `PremiumEntitlement.compute` as an adapter over `EntitlementSnapshot` (`isLifetime`, `expiry`); move to `@Observable`; keep the Supabase mirror as an `onChange(of: store.entitlements)` hook. Call `refreshEntitlements()` at subscription expiry (its `scheduleExpiryCheck`). |
| **Carpe Vitem** | `StoreKitManager.verifyWithServer` (credits + sub) | `ServerVerifier(appAccountToken: { supabase.currentUser?.id }, submit: { await verifyWithServer(jws: $0) ? .grant : .deferFinish })`; credit balance stays in `AICreditsService`. Note: `StoreClient` does not re-post subscriptions on every refresh — only on `restore()`. visionOS target: use `purchase(_:confirmIn:)`. |
| **Lunker, Sextant** | `TrialPersistence` / `KeychainTrialStore` / `trialIsActive` + `currentEntitlements` | Delete the local trial types; `Trial(store: KeychainTrialStore(service: "com.lunker.premium" / "com.sextant.premium", account: "trialStart"))` (same item, same format). `isTrialStateUnknown` = `trial.state()` throwing. Keep `trialStateRevision` / expiry wake-up app-side (use `trial.endDate()`). Add `cache: UserDefaultsEntitlementCache()` + `stickyNonConsumables: true`. In-memory test stores must now be `Sendable`. |
| **Equinox** | `ProStore` (Keychain+App Group trial, `Transaction.all` refresh, `isProUser` cache) | `Trial(store: KeychainTrialStore(service: nil, account: "com.equinox.pro.trialStart", mirror: UserDefaultsTrialStore(suiteName: "group.com.equinox.shared", key: "proTrialStartDate")))` reads the existing items. `StoreClient(productIDs: ["com.equinox.pro"], cache: UserDefaultsEntitlementCache(suiteName: "group.com.equinox.shared", legacyFlags: ["isProUser": "com.equinox.pro"]), stickyNonConsumables: true)` replaces `refreshEntitlements` + `setPro`. `cachedHasProAccess` / `cachedAccess` → cache `load()` + `Trial.state`. `purchaseFailureReason` → `PurchaseFailure.reason(for:)`. Trial length was 14 *calendar* days; `Trial` uses 14 × 86 400 s (±1 h across a DST change). |
| **Otta** | `StoreManager` (`currentEntitlements`, App Group `proStateKey`) | `StoreClient` + `UserDefaultsEntitlementCache(suiteName: Config.Store.appGroupID, legacyFlags: [Config.Store.proStateKey: Config.Store.proProductID])`, `stickyNonConsumables: true` if Pro is a non-consumable. Its `purchaseGeneration` lag guard is built in: `StoreClient` counts a non-consumable it granted this session as current even while `currentEntitlements` lags. Keep `forcePro` app-side. |
| **ThenCam** | Adopted 0.1.1 | No change needed; 0.2 is source-compatible. |

## Build / test

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
# platforms (from the package dir):
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -scheme PortfolioStoreKit \
  -destination generic/platform=iOS -destination generic/platform=watchOS \
  -destination generic/platform=visionOS build
```

(Plain Command Line Tools can't link the SPM manifest — point at a full Xcode.)

## Versioning
Tagged releases; apps depend on it by URL + version (CI-safe — resolvable in Xcode Cloud).

## Changelog

### 0.2.0 (2026-10-27)
- **App-managed trial:** `Trial`, `TrialState`, `TrialClock`, `TrialPersistence`,
  `KeychainTrialStore` (earliest-wins, survives reinstall, optional `UserDefaults` mirror, reads
  Lunker/Sextant and Equinox formats), `UserDefaultsTrialStore`, `TrialPersistenceError`.
- **Entitlement cache:** `EntitlementCache`, `CachedEntitlements`,
  `UserDefaultsEntitlementCache` (App Group, legacy Bool flags), `SealedEntitlementCache`
  (HMAC-SHA256, Keychain key, max age, Enigma-compatible).
- **Sticky non-consumables:** `StoreClient(productIDs:verifier:cache:stickyNonConsumables:)`,
  `isProvisional`, `provisionalProductIDs`, `hasLoadedEntitlements`; revocation-aware
  `Transaction.all` scan; pure `StickyEntitlementPolicy` (`resolve`, `cacheUpdate`).
  Unblocks Equinox / Lunker / Sextant / Otta.
- **`PurchaseFailure.reason(for:)`** — analytics-safe failure reasons.
- `StoreClient.refreshEntitlements()`; refreshes are now serialized (an older, slower scan can't
  overwrite a newer one).
- A non-consumable granted this session counts as active even while `currentEntitlements` lags
  the purchase (until revoked). Applies with or without a cache.
- **visionOS fix:** 0.1.x didn't compile for visionOS (`Product.purchase(options:)` is
  unavailable there). `purchase(_:)` is now `@available(visionOS, unavailable)`; added
  `purchase(_:confirmIn:)`, `purchaseOptions()` and `handle(_:)` (for SwiftUI `PurchaseAction`).
- Source-compatible with 0.1.x call sites (all new init parameters are defaulted).

### 0.1.1
- Revoked transactions are finished up front, never routed to the verifier.

### 0.1.0
- `StoreClient`, `PurchaseVerifier` (`LocalVerifier`, `ServerVerifier`), `EntitlementSnapshot`,
  `VerificationDecision`, `PurchaseOutcome`.
