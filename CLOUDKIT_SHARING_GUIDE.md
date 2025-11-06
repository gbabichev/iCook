# CloudKit Sharing Guide for iCook

This document explains how to implement and use CloudKit sharing for Sources in the iCook app.

## Overview

Sources can be shared with other iCloud users. Each user can:
- **Create personal sources** - stored in their private CloudKit database
- **Share sources** - move sources to the shared database and send invitations to other users
- **Accept shared sources** - receive and access sources shared by other users
- **Read-only access** - users accessing shared sources cannot modify them

## Architecture

### Database Separation

The app uses two CloudKit databases:

1. **Private Database** (`container.privateCloudDatabase`)
   - Stores personal sources owned by the user
   - Only accessible to the owner
   - Categories and recipes tied to personal sources

2. **Shared Database** (`container.sharedCloudDatabase`)
   - Stores sources shared with other users
   - Can be accessed by users who've accepted the share invitation
   - Maintains read-only access for shared participants

### Source Model

```swift
struct Source: Identifiable {
    var id: CKRecord.ID
    var name: String
    var isPersonal: Bool          // true = private DB, false = shared DB
    var owner: String             // iCloud user identifier
    var lastModified: Date
}
```

**Key Property:** `isPersonal`
- `true` = Personal source (stored in private database)
- `false` = Shared source (stored in shared database)

## Sharing Flow

### 1. Prepare Source for Sharing

When a user taps the share button on a personal source:

```swift
// In SourceSelector.swift
func prepareShare(for source: Source) async {
    if let (share, record) = await viewModel.cloudKitManager.prepareShareForSource(source) {
        pendingShare = share
        pendingRecord = record
        showShareSheet = true
    }
}
```

This method:
1. Saves the source record to the **shared database**
2. Creates a `CKShare` object with read-only permissions
3. Returns the share and record for presentation to the user

### 2. Present UICloudSharingController

The app uses a custom `CloudSharingController` wrapper to present Apple's native share UI:

```swift
CloudSharingSheet(
    isPresented: $showShareSheet,
    container: viewModel.cloudKitManager.container,
    share: share,
    record: record,
    onCompletion: { success in
        if success {
            _ = await viewModel.cloudKitManager.saveShare(share, for: record)
        }
    }
)
```

**UICloudSharingController Benefits:**
- Native Apple interface for managing shares
- Handles invitation delivery automatically
- Shows current participants and their permissions
- Allows changing permissions or stopping the share
- Follows iOS/macOS design guidelines

### 3. Save the Share

After the user confirms sharing in UICloudSharingController:

```swift
func saveShare(_ share: CKShare, for record: CKRecord) async -> Bool {
    do {
        let database = sharedDatabase
        _ = try await database.save(share)
        printD("Share saved successfully")
        return true
    } catch {
        printD("Error saving share: \(error)")
        return false
    }
}
```

## Accepting Shares

### Check for Invitations

Periodically check for incoming share invitations:

```swift
func checkForIncomingShareInvitations() async {
    do {
        let shareMetadatas = try await container.acceptableShareMetadatas()
        // Process invitations...
    } catch {
        printD("Error checking for invitations: \(error)")
    }
}
```

### Accept a Share

When a user accepts a share invitation:

```swift
func acceptSharedSource(_ metadata: CKShare.Metadata) async {
    do {
        // CloudKit framework automatically handles the acceptance
        // Reload sources to display the newly available shared source
        await loadSources()
    } catch {
        printD("Error accepting share: \(error)")
    }
}
```

## Read-Only Access Control

Shared sources are read-only. The app enforces this by:

### 1. Model-Level Check

```swift
func canEditSource(_ source: Source) -> Bool {
    // Users can edit personal sources they own
    // Users cannot edit shared sources (read-only)
    return source.isPersonal
}
```

### 2. UI-Level Enforcement

#### In ModifyCategory.swift:
```swift
if let source = model.currentSource, !model.canEditSource(source) {
    Section {
        HStack {
            Image(systemName: "lock.fill")
            Text("This source is read-only")
        }
    }
}

Section("Category Information") {
    TextField("Category Name", text: $categoryName)
        .disabled(!canEdit)  // Disable input
}

// Disable save button
.disabled(!canEdit || ...)
```

#### In AddEditRecipeView.swift:
```swift
if let source = model.currentSource, !model.canEditSource(source) {
    // Show read-only warning
}

// Disable all input fields
TextField("Recipe Name", text: $recipeName)
    .disabled(!canEdit)

// Disable buttons
Button("Add Step") { ... }
    .disabled(!canEdit)

// Disable save
.disabled(!isFormValid || !canEdit)
```

## UI Components

### CloudSharingController.swift

A SwiftUI wrapper around UIKit's `UICloudSharingController`:

```swift
struct CloudSharingController: UIViewControllerRepresentable {
    let container: CKContainer
    let share: CKShare
    let record: CKRecord
    var onCompletion: (Bool) -> Void = { _ in }
    var onFailure: (Error) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UICloudSharingController { ... }
}
```

**Features:**
- Handles native share UI presentation
- Reports success/failure via callbacks
- Implements `UICloudSharingControllerDelegate`
- Properly manages controller lifecycle

### SourceRow UI

The source list shows a share button for personal sources:

```swift
if source.isPersonal {
    Button(action: onShare) {
        Image(systemName: "square.and.arrow.up")
            .foregroundColor(.blue)
    }
}
```

Only personal sources can be shared, so the button only appears for those.

## Implementation Details

### File: CloudKitManager.swift

**New Published Properties:**
```swift
@Published var shareControllerPresented = false
@Published var pendingShare: CKShare?
@Published var pendingRecord: CKRecord?
```

**New Methods:**

1. **prepareShareForSource()**
   - Saves source to shared database
   - Creates read-only share
   - Returns share and record

2. **saveShare()**
   - Persists the share to CloudKit
   - Called after user confirms in UICloudSharingController

3. **acceptSharedSource()**
   - Processes share acceptance
   - Reloads sources

4. **checkForIncomingShareInvitations()**
   - Queries for available shares
   - Called periodically or on app launch

5. **fetchAllShares()**
   - Retrieves all shares user has created or received
   - Queries the shared database

6. **stopSharingSource()**
   - Removes a share
   - Prevents further access for participants

### File: AppViewModel.swift

**New Methods:**

```swift
func isSourceShared(_ source: Source) -> Bool
func canEditSource(_ source: Source) -> Bool
func acceptShareInvitation(_ metadata: CKShare.Metadata) async
func checkForSharedSourceInvitations() async
```

### File: SourceSelector.swift

**Share Flow:**
1. User taps share icon on personal source
2. `prepareShare()` fetches/creates share
3. `CloudSharingSheet` presents UICloudSharingController
4. User confirms in native UI
5. Share is saved to CloudKit

## Testing the Feature

### Testing Sharing Between Accounts

1. **Create a test source** on Account A
2. **Tap the share button** (cloud icon)
3. **Enter Account B's email** in the share sheet
4. **Accept the invitation** on Account B
5. **Verify the source appears** in Account B's shared sources
6. **Try to edit** - should be read-only

### Edge Cases to Test

- Sharing multiple sources
- Modifying shared source permissions in UICloudSharingController
- Stopping a share and verifying access is removed
- Syncing across multiple devices
- Offline scenarios

## Best Practices

### 1. Database Selection

Always select the correct database based on the source:
```swift
let database = source.isPersonal ? privateDatabase : sharedDatabase
```

### 2. Permission Checks

Always verify edit permissions before allowing modifications:
```swift
guard model.canEditSource(currentSource) else {
    showError("Cannot edit shared sources")
    return
}
```

### 3. User Feedback

Clearly indicate when a source is shared:
- Show "Shared" status in source list
- Display lock icon in read-only warning
- Disable edit controls appropriately

### 4. Error Handling

Gracefully handle CloudKit errors:
```swift
do {
    // CloudKit operation
} catch {
    printD("Error: \(error.localizedDescription)")
    self.error = "Failed to complete operation"
}
```

## Limitations & Workarounds

### SharedDB Zone-Wide Queries

CloudKit's shared database doesn't support zone-wide queries. The app works around this by:
1. Catching the specific error
2. Falling back to cached data
3. Using targeted queries with predicates

### Record Indexing Delay

Newly created records may not appear in queries immediately. The app handles this by:
1. Adding new items directly to local arrays
2. Updating UI immediately
3. Letting CloudKit sync in the background

## Future Enhancements

1. **Permission Levels** - Allow read-write access for trusted users
2. **Share Groups** - Share a source with multiple users at once
3. **Share Analytics** - Track who's accessing shared sources
4. **Expiring Shares** - Set expiration dates on shares
5. **Notification Integration** - Notify users when shares are accepted
6. **Conflict Resolution** - Handle simultaneous edits by multiple users
