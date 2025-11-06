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
        let controller = UICloudSharingController(share: share, container: container)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion, onFailure: onFailure)
    }

    class Coordinator: NSObject, UICloudSharingControllerDelegate {
        var onCompletion: (Bool) -> Void
        var onFailure: (Error) -> Void

        init(onCompletion: @escaping (Bool) -> Void, onFailure: @escaping (Error) -> Void) {
            self.onCompletion = onCompletion
            self.onFailure = onFailure
        }

        func cloudSharingController(
            _ csc: UICloudSharingController,
            failedToSaveShareWithError error: Error
        ) {
            printD("Failed to save share: \(error.localizedDescription)")
            onFailure(error)
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            "Share Recipe Source"
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            printD("Share saved successfully")
            onCompletion(true)
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            printD("Share stopped")
            onCompletion(false)
        }
    }
}
#endif

/// Wrapper to present CloudSharingController in a sheet
struct CloudSharingSheet<Content: View>: View {
    @Binding var isPresented: Bool
    let container: CKContainer
    let share: CKShare
    let record: CKRecord
    let content: Content
    var onCompletion: (Bool) -> Void = { _ in }

    init(
        isPresented: Binding<Bool>,
        container: CKContainer,
        share: CKShare,
        record: CKRecord,
        @ViewBuilder content: () -> Content,
        onCompletion: @escaping (Bool) -> Void = { _ in }
    ) {
        self._isPresented = isPresented
        self.container = container
        self.share = share
        self.record = record
        self.content = content()
        self.onCompletion = onCompletion
    }

    var body: some View {
        #if os(iOS)
        ZStack {
            content

            if isPresented {
                CloudSharingController(
                    container: container,
                    share: share,
                    record: record,
                    onCompletion: { success in
                        onCompletion(success)
                        isPresented = false
                    }
                )
                .ignoresSafeArea()
            }
        }
        #else
        content
        #endif
    }
}
