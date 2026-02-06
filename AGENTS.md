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
- Some devices report a 2.0 switch‑over without a true telephoto.
- Current behavior:
  - Use `virtualDeviceSwitchOverVideoZoomFactors` from virtual back camera.
  - Only allow “digital 2x” for allowlisted models (iPhone 17+), explicitly deny iPhone 13.
  - If `currentCamera` is removed by dedup, reset to a valid back camera.
  - Tap targets: camera close “X” uses 44x44 frame.
- Debug log printed: `Camera model identifier: ...`

UI notes:
- Tutorial is first‑launch only (debug menu can show it).
- Share button on iOS Collections shows “Preparing share…” overlay while loading.
- `.toolbarBackground(.hidden, for: .windowToolbar)` applied on macOS toolbars.
- iPhone sidebar title only (no title on iPad).

Docs updated:
- `Documentation/PrivacyPolicy.html` and `Documentation/Support.html` reflect iCook.
- README updated to iCook (App Store link still old—replace when known).
