import SwiftUI
import CloudKit
#if os(iOS)
import UIKit
#endif

/// SwiftUI wrapper for UICloudSharingController to handle share sheets
#if os(iOS)
struct CloudSharingController: UIViewControllerRepresentable {
    let container: CKContainer
    let share: CKShare
    let record: CKRecord
    var onCompletion: (Bool) -> Void = { _ in }
    var onFailure: (Error) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        printD("========== CLOUD SHARING CONTROLLER ==========")
        printD("Creating UICloudSharingController")
        printD("Share ID: \(share.recordID.recordName)")
        printD("Container ID: \(container.containerIdentifier)")
        printD("Record ID: \(record.recordID.recordName)")

        let controller = UICloudSharingController(share: share, container: container)
        printD("UICloudSharingController instance created")

        controller.delegate = context.coordinator
        printD("Delegate set")

        // Print share URL info if available
        if let shareURL = share.url {
            printD("Share URL is available: \(shareURL.absoluteString)")
        } else {
            printD("Share URL is not yet available (will be generated after save)")
        }

        printD("========== CONTROLLER CREATED ==========")
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {
        printD("updateUIViewController called")
    }

    func makeCoordinator() -> Coordinator {
        printD("makeCoordinator called")
        return Coordinator(onCompletion: onCompletion, onFailure: onFailure)
    }

    class Coordinator: NSObject, UICloudSharingControllerDelegate {
        var onCompletion: (Bool) -> Void
        var onFailure: (Error) -> Void

        init(onCompletion: @escaping (Bool) -> Void, onFailure: @escaping (Error) -> Void) {
            self.onCompletion = onCompletion
            self.onFailure = onFailure
            super.init()
            printD("Coordinator initialized")
        }

        func cloudSharingController(
            _ csc: UICloudSharingController,
            failedToSaveShareWithError error: Error
        ) {
            printD("UICloudSharingController failed to save share: \(error.localizedDescription)")
            onFailure(error)
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            printD("UICloudSharingController itemTitle called")
            return "Share Recipe Source"
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            printD("UICloudSharingController: Share saved successfully")

            // The share is now saved - try to get the URL
            if let share = csc.share, let shareURL = share.url {
                printD("Share URL now available: \(shareURL.absoluteString)")
                // Copy it to pasteboard automatically after save
                #if os(iOS)
                UIPasteboard.general.url = shareURL
                printD("Share URL automatically copied to pasteboard")
                #endif
            } else {
                printD("Share URL still not available after save (this should not happen)")
            }

            onCompletion(true)
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            printD("UICloudSharingController: Share stopped by user")
            onCompletion(false)
        }

        // Called when the user interacts with the controller
        func cloudSharingController(_ csc: UICloudSharingController, shouldStopSharingAfterSaving saveSuccess: Bool) -> Bool {
            printD("shouldStopSharingAfterSaving called with saveSuccess: \(saveSuccess)")
            return true
        }

        // Called to allow customization
        func cloudSharingControllerDidStopSharingBecauseOfAccountChange(_ csc: UICloudSharingController) {
            printD("Share stopped because of account change")
            onCompletion(false)
        }

        // This delegate method is called when share participants change
        func cloudSharingController(_ csc: UICloudSharingController, didCompleteWithError error: Error?) {
            printD("cloudSharingController didCompleteWithError called")
            if let error = error {
                printD("Error: \(error.localizedDescription)")
                onFailure(error)
            } else {
                printD("Completed without error")

                // Try to get the share URL here too
                if let share = csc.share, let shareURL = share.url {
                    printD("Share URL available in didComplete: \(shareURL.absoluteString)")
                }
            }
        }
    }
}
#endif
