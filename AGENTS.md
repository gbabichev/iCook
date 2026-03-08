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
  - Keep the implementation intentionally simple: back `1x`, optional back `0.5x` when ultra-wide hardware exists, and one front camera.
  - Do not re-introduce virtual-camera zoom presets (`2x/4x/8x`) or field-of-view heuristic enumeration without an explicit redesign.
  - Do not force `activeFormat` to “widest” formats; that caused bad `1x` quality / framing.
- Implementation location: `iCook/UI/AddEditRecipeCamera+iOS.swift` (kept out of cross-platform `AddEditRecipeView.swift`).
- Tap targets: camera close “X” uses 44x44 frame.

UI notes:
- Tutorial is first‑launch only (debug menu can show it).
- Share button on iOS Collections shows “Preparing share…” overlay while loading.
- `.toolbarBackground(.hidden, for: .windowToolbar)` applied on macOS toolbars.
- iPhone sidebar title only (no title on iPad).
- DEBUG builds show `BetaTag()` overlay in bottom trailing app window.
- Recipe detail / collection hero headers now follow the Apple `Landmarks`-style flexible header pattern on both iOS and macOS.
- On macOS, title-in-content is preferred for hero-header screens; using `navigationTitle` in the toolbar/titlebar can reintroduce scroll jitter.
- `Inline Navigation Titles` is a shared user setting that can opt back into toolbar/navigation titles.
- Collection refresh should reconcile sources and current-source content together; use the shared `AppViewModel.refreshSourcesAndCurrentContent(...)` path instead of refreshing recipes alone.
- macOS collection/settings lists should render from the same `visibleSources` filtering as iOS to avoid stale rows during CloudKit propagation.

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

Linked recipes:
- Recipes support optional one-way links to other recipes via `linkedRecipeIDs`.
- Linked recipes are managed from the bottom of recipe detail view.
- Import/export supports linked recipes and uses stable export IDs first, with unique-name fallback only for older exports.

Import / export:
- Export/import now preserves tags and linked recipes.
- Import preview supports selecting a destination collection before import.
- Import preview also supports creating a new collection inline from the sheet.
- Import shows determinate progress with phase text, percentage, recipe count, elapsed time, ETA, and current item name.
- Import cancellation is cooperative: `Cancel Import` requests cancellation and the batch stops at the next safe checkpoint; already imported recipes remain imported.

Recent code optimization / cleanup:
- Legacy navigation glue was simplified in favor of native SwiftUI navigation flows.
- Removed stale/unused debug logging and periphery-reported dead paths where safe.
- Kept platform-specific camera and sharing behavior isolated (e.g., `AddEditRecipeCamera+iOS.swift`) to reduce cross-platform conditionals.
- iOS settings/source deletion uses local hiding plus source-refresh filtering to avoid the “delete, reappear, delete again” bounce while CloudKit catches up.


## CloudKit Sharing

Detailed, reusable implementation guidance has been moved to:
- `Documentation/CloudKitSharingPlaybook.md`

Project-specific anchors:
- Entitlements: `iCook/iCook.entitlements`
- App entry and share acceptance routing: `iCook/iCookApp.swift`
- CloudKit sharing logic: `iCook/Logic/CloudKitManager.swift`
- Share UI flows (iOS + macOS): `iCook/UI/SourceSelector.swift`
- App-level accept/loading orchestration: `iCook/Logic/AppViewModel.swift`
