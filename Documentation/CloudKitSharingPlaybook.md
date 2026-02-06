# CloudKit Sharing Playbook (iOS + macOS)

This document is a reusable implementation guide for CloudKit record sharing in apps that need:
- owner/private collections
- owner/shared collections
- collaborator access
- consistent accept/share behavior across iOS and macOS

It captures practical patterns that work in production, plus failure modes that commonly waste time.

## 1. Requirements

### 1.1 Minimum setup
- A valid iCloud container.
- CloudKit enabled for the app target.
- Record model where each shareable object has a root record (for example: `Collection`).

### 1.2 Entitlements checklist
Add these to your app entitlements:
- `com.apple.developer.icloud-services` includes `CloudKit`
- `com.apple.developer.icloud-container-identifiers` includes your container, e.g. `iCloud.com.yourcompany.yourapp`

If owner identity in system share UIs appears as `(Owner)` or blank, add:
- `com.apple.developer.icloud-extended-share-access` with value:
  - `InProcessShareOwnerParticipantInfo`

## 2. Data and Zone Strategy

### 2.1 Use a custom private zone for shareable roots
- Store shareable root records in a custom private zone (not the default zone).
- Sharing records in default zone causes major limitations and user-facing errors.

### 2.2 Bootstrap the personal zone once
- On startup, ensure the custom zone exists.
- Deduplicate concurrent zone creation with an in-flight task guard.
- Retry/load-after-create once if first attempt hits `ZONE_NOT_FOUND`.

### 2.3 Share children intentionally
- If your root has child records, attach them to the share as needed (or ensure they are discoverable through references).
- Do not assume all related records become visible automatically unless your model guarantees it.

## 3. Share State Model (Recommended)

Use an explicit 3-state model per shared entity:
1. Owner + Private
2. Owner + Shared
3. Collaborator

This makes button behavior, icons, and available actions deterministic across platforms.

## 4. Incoming Share Acceptance (Critical)

CloudKit share acceptance can arrive through different paths. Handle all of them.

### 4.1 iOS entry points
- `application(_:userDidAcceptCloudKitShareWith:)`
- `windowScene(_:userDidAcceptCloudKitShareWith:)`
- `scene(_:openURLContexts:)`
- `scene(_:continue:)`
- SwiftUI `.onOpenURL` and `.onContinueUserActivity` (fallbacks)

### 4.2 macOS entry points
- `application(_:userDidAcceptCloudKitShareWith:)`
- `application(_:open:)` / URL open handlers

### 4.3 App-layer accept pipeline
Unify all entry points into:
- `acceptShareMetadata(_:)` (preferred when metadata is available)
- `acceptShareURL(_:)` (fallback)

After successful accept:
- reload sources/collections
- select the accepted source
- load dependent content immediately
- show a transient "accepting share" loading state in UI

## 5. Outgoing Sharing Flows

## 5.1 Core manager API (cross-platform)

Create a single share-prep method usable on both iOS and macOS:
- fetch root record
- return existing `CKShare` if present
- else create `CKShare(rootRecord:)`, set title/thumbnail/permissions, save
- mark local shared state cache

Recommended helper signatures:
- `preparedShareForActivitySheet(sourceID:sourceName:) async throws -> CKShare`
- `saveShare(for record: CKRecord, share: CKShare) async throws -> CKShare`
- `getShareURL(for:) async -> URL?` (only as fallback, not primary collaborative share path)

Important: do not hide these methods behind iOS-only compile flags if macOS uses them.

## 5.2 iOS flow

### First share (owner + private)
- Use `NSItemProvider.registerCKShare(container:allowedSharingOptions:preparationHandler:)`
- Present `UIActivityViewController(activityItemsConfiguration:)`

Why: this sends a true CloudKit collaboration payload (not just text URL).

### Existing share (owner + shared)
- Present `UICloudSharingController` with existing `CKShare`.

### Collaborator
- Present participant access management / leave flow for existing share.

### iOS deprecations
- Avoid deprecated `UIActivityViewController` preparation initializer paths.
- Prefer `activityItemsConfiguration`-based APIs.

## 5.3 macOS flow

### First share (owner + private)
- Use `NSSharingServicePicker`.
- Pass `NSPreviewRepresentingActivityItem` wrapping an `NSItemProvider` registered via `registerCKShare(...)`.

### Existing share management (owner + shared)
- Use `NSSharingService(named: .cloudSharing)`.
- For items, pass `NSItemProvider` registered with:
  - `registerCloudKitShare(existingShare, container:)`

Notes:
- Passing raw `CKShare` to `.cloudSharing` may fail `canPerform(withItems:)` on some setups.
- If `canPerform` fails, fall back to generic share flow and log clearly.

### Collaborator
- Use explicit leave/remove access flow in app logic.

## 6. UX Patterns That Work

- Use different affordances per state:
  - owner/private: "Share" or "Start Sharing"
  - owner/shared: "Manage Sharing" / "Share With…" + "Stop Sharing"
  - collaborator: "Manage Access" / "Leave Share"
- Keep share button behavior stateful and predictable.
- After successful share actions, refresh local source list and current selection.

## 7. CloudKit Telemetry and Error Interpretation

These are often expected during setup or eventual consistency windows:
- `ZONE_NOT_FOUND`: common on fresh installs, wiped environments, or before zone creation completes.
- `NOT_FOUND`: common during propagation windows.
- `BAD_REQUEST`: often from unsupported query patterns.

Specific known unsupported behavior:
- Shared DB zone-wide queries can produce errors like:
  - "SharedDB does not support Zone Wide queries"

Do not spam logs for hot-path predicates (`isSharedOwner` / `isSharedSource`) in SwiftUI-heavy screens; it creates noise and hides real failures.

## 8. Common Failure Modes and Fixes

### 8.1 Owner shows as `(Owner)` / missing name
- Ensure `icloud-extended-share-access` entitlement includes `InProcessShareOwnerParticipantInfo`.

### 8.2 Invite sent as plain link, recipient gets permission/open errors
- Ensure first-share path sends CloudKit-registered provider items, not raw URL text.

### 8.3 macOS always opens generic share picker for already-shared owner
- Ensure manage path uses `.cloudSharing` with `registerCloudKitShare(existingShare, container:)`.

### 8.4 "Failed to create source" on new account
- Ensure custom zone creation/bootstrap happens before create flow, with one retry.

## 9. Testing Matrix (Do Not Skip)

Run with at least 3 accounts:
- Account A: owner
- Account B: collaborator (existing tester)
- Account C: fresh first-launch account

Validate:
1. First app launch creates/recovers personal zone cleanly.
2. Owner creates private collection successfully.
3. Owner shares first time; invite appears as CloudKit collaboration object.
4. Recipient accepts and sees shared data.
5. Owner reopens manage sharing UI and sees participants.
6. Owner stops sharing; collaborator loses access and local state updates.
7. Collaborator leave flow works.
8. Offline mode prevents destructive edits/deletes and avoids cache wipes on refresh.

## 10. Implementation Checklist (Copy/Paste)

- [ ] Add CloudKit entitlements and container IDs.
- [ ] Add extended share access entitlement for owner identity display.
- [ ] Create custom private record zone and deduped ensure-zone logic.
- [ ] Implement unified incoming share accept pipeline (metadata + URL).
- [ ] Implement shared state model (owner/private/shared/collaborator).
- [ ] Implement cross-platform `preparedShare...` and `saveShare`.
- [ ] iOS first-share via registered CKShare item provider + activity items configuration.
- [ ] iOS existing-share manage via `UICloudSharingController`.
- [ ] macOS first-share via `NSSharingServicePicker` + registered CKShare provider.
- [ ] macOS existing-share manage via `.cloudSharing` + `registerCloudKitShare`.
- [ ] Add explicit collaborator leave flow.
- [ ] Add targeted logs for failures only; avoid hot-path predicate logs.
- [ ] Verify with multi-account test matrix.

## 11. Security and Product Notes

- Keep `share.publicPermission = .none` unless intentional public sharing is a product requirement.
- Be explicit about participant permission options (`read-only` vs `read-write`).
- Surface user-facing errors with actionable text (zone/default-zone/permission issues).
- Keep local cache and UI state in sync immediately after successful share operations.
