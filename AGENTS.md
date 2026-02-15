## iCook – Agent Notes

High‑level context:
- iCook is a recipes app with iCloud sync and sharing.
- CloudKit share acceptance must handle both URL and metadata flows.

Key flows / gotchas:
- iOS share links:
  - Use `application(_:userDidAcceptCloudKitShareWith:)` (UIKit delegate).
  - Also handle `scene(_:openURLContexts:)` and `scene(_:continue:)`.
  - URL‑based `onOpenURL` may not fire for CloudKit share links.
- macOS share links:
  - Use `application(_:userDidAcceptCloudKitShareWith:)` in the app delegate.
  - `application(_:open:)` should forward non‑export URLs to share handling.
- Accepting a share:
  - `AppViewModel.acceptShareURL` and `acceptShareMetadata` call CloudKitManager.
  - After success, call `selectSource` to load categories/recipes and update UI.
  - `iCookApp` shows a “Loading shared collection…” overlay via `isAcceptingShare`.

Offline behavior:
- When offline, disable editing and deleting.
- Pull‑to‑refresh should no‑op offline (no cache wipe).
- Removing a shared collection should clear categories/recipes/recipeCounts and refresh sidebar.

Camera lens selection (iOS):
- Physical lens discovery via AVCaptureDevice.
- Current behavior:
  - Compute per-lens zoom labels from field-of-view ratios (relative to the wide camera), instead of hardcoded telephoto=2x.
  - Use `virtualDeviceSwitchOverVideoZoomFactors` from virtual back camera and add boosted tele presets (e.g. 8x) when supported by quality zoom thresholds.
  - Include `.builtInTrueDepthCamera` in discovery.
  - If `currentCamera` is removed by dedup, reset to a valid back camera.
- Implementation location: `iCook/UI/AddEditRecipeCamera+iOS.swift` (kept out of cross-platform `AddEditRecipeView.swift`).
- Tap targets: camera close “X” uses 44x44 frame.
- Debug log printed: `Camera options finalized: back=[...] front=[...]`.

UI notes:
- Tutorial is first‑launch only (debug menu can show it).
- Share button on iOS Collections shows “Preparing share…” overlay while loading.
- `.toolbarBackground(.hidden, for: .windowToolbar)` applied on macOS toolbars.
- iPhone sidebar title only (no title on iPad).
- DEBUG builds show `BetaTag()` overlay in bottom trailing app window.

Navigation + window management:
- App now uses single-scene window behavior on macOS (`Window` style flow) to avoid duplicate import handling across multiple windows.
- Finder-opened `.icookexport` files are forwarded to an existing app window when possible.
- If a transient import window is created by the system open event, import handling is deferred/forwarded and that extra window closes.
- Import UI state is window-scoped to avoid duplicate dialogs.

Docs updated:
- `Documentation/PrivacyPolicy.html` and `Documentation/Support.html` reflect iCook.
- README updated to iCook (App Store link still old—replace when known).
- Generic cross-project sharing guide added: `Documentation/CloudKitSharingPlaybook.md`.

Tags + filtering:
- Tags are first-class sidebar items (clickable like categories) and support add/edit/delete.
- `RecipeCollectionType` includes `.tag(Tag)` and recipe lists can be filtered by selected tag.
- App location persistence supports tag destinations (`AppLocation.tag(tagID:)`) so restoring state works for tag views.
- If a currently selected tag is deleted, UI automatically exits that tag view and returns to Home.
- Tags are editable directly in recipe detail view (quick assignment/removal) without opening full edit flow.
- Duplicate-name prevention exists for both tags and categories with inline validation messaging.

Recent code optimization / cleanup:
- Legacy navigation glue was simplified in favor of native SwiftUI navigation flows.
- Removed stale/unused debug logging and periphery-reported dead paths where safe.
- Kept platform-specific camera and sharing behavior isolated (e.g., `AddEditRecipeCamera+iOS.swift`) to reduce cross-platform conditionals.


## CloudKit Sharing

Detailed, reusable implementation guidance has been moved to:
- `Documentation/CloudKitSharingPlaybook.md`

Project-specific anchors:
- Entitlements: `iCook/iCook.entitlements`
- App entry and share acceptance routing: `iCook/iCookApp.swift`
- CloudKit sharing logic: `iCook/Logic/CloudKitManager.swift`
- Share UI flows (iOS + macOS): `iCook/UI/SourceSelector.swift`
- App-level accept/loading orchestration: `iCook/Logic/AppViewModel.swift`
