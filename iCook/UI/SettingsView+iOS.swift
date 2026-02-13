#if os(iOS)
import SwiftUI
import CloudKit
import UIKit


extension SourceSelector {
    var iOSView: some View {
        NavigationStack {
            ZStack {
                sourcesListView

                if isPreparingShare {
                    Color.black.opacity(0.2)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Preparing share…")
                            .font(.headline)
                    }
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                if showShareSuccess {
                    Color.clear
                        .alert("Share Link", isPresented: $showShareSuccess) {
                            Button("OK") { }
                        } message: {
                            Text(shareSuccessMessage)
                        }
                }

                if showDeleteConfirmation {
                    Color.clear
                        .alert("Delete Source", isPresented: $showDeleteConfirmation) {
                            Button("Cancel", role: .cancel) { }
                            Button("Delete", role: .destructive) {
                                if let source = sourceToDelete {
                                    Task {
                                        await deleteSource(source)
                                    }
                                }
                            }
                        } message: {
                            if let source = sourceToDelete {
                                Text("Delete '\(source.name)' and all its recipes and categories?")
                            }
                        }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Text("Done")
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showNewSourceSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .onAppear {
            if viewModel.sources.isEmpty {
                Task {
                    await viewModel.loadSources()
                }
            }
        }
        .sheet(isPresented: $showNewSourceSheet) {
            NewSourceSheet(
                isPresented: $showNewSourceSheet,
                sourceName: $newSourceName
            )
            .environmentObject(viewModel)
        }
    }

    func shareSource(for source: Source) async {
        isPreparingShare = true

        printD("Getting share URL for source: \(source.name)")

        if !viewModel.isSharedOwner(source), viewModel.cloudKitManager.isSharedSource(source),
           let controller = await viewModel.cloudKitManager.participantSharingController(for: source) {
            await MainActor.run {
                presentUICloudSharingController(controller, source: source)
                isPreparingShare = false
            }
            return
        }

        if viewModel.isSharedOwner(source) {
            if let shareController = await viewModel.cloudKitManager.existingSharingController(for: source) {
                await MainActor.run {
                    presentUICloudSharingController(shareController, source: source)
                    isPreparingShare = false
                }
                return
            }

            await MainActor.run {
                presentCloudKitInviteActivityController(for: source)
                isPreparingShare = false
            }
            return
        }

        viewModel.cloudKitManager.prepareSharingController(for: source) { controller in
            Task { @MainActor in
                isPreparingShare = false
                if let controller {
                    presentUICloudSharingController(controller, source: source)
                } else {
                    printD("Failed to prepare sharing controller")
                    shareSuccessMessage = viewModel.cloudKitManager.error ?? "Failed to start sharing"
                    showShareSuccess = true
                }
            }
        }
    }

    private func presentCloudKitInviteActivityController(for source: Source) {
        printD("Presenting CloudKit invite activity sheet for source: \(source.name)")

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              var topController = window.rootViewController else {
            printD("Cannot find window or root view controller for activity controller")
            return
        }

        while let presented = topController.presentedViewController {
            topController = presented
        }

        let itemProvider = NSItemProvider()
        let container = viewModel.cloudKitManager.container
        let sourceID = source.id
        let sourceName = source.name
        let allowedOptions = CKAllowedSharingOptions(
            allowedParticipantPermissionOptions: .any,
            allowedParticipantAccessOptions: .specifiedRecipientsOnly
        )
        itemProvider.registerCKShare(container: container, allowedSharingOptions: allowedOptions) {
            try await CloudKitManager.shared.preparedShareForActivitySheet(sourceID: sourceID, sourceName: sourceName)
        }

        let configuration = UIActivityItemsConfiguration(itemProviders: [itemProvider])
        let activityController = UIActivityViewController(activityItemsConfiguration: configuration)
        activityController.completionWithItemsHandler = { _, _, _, _ in
            Task {
                await self.viewModel.loadSources()
            }
        }
        if let popover = activityController.popoverPresentationController {
            popover.sourceView = topController.view
            popover.sourceRect = CGRect(
                x: topController.view.bounds.midX,
                y: topController.view.bounds.midY,
                width: 1,
                height: 1
            )
        }

        DispatchQueue.main.async {
            topController.present(activityController, animated: true)
        }
    }

    private func presentUICloudSharingController(_ controller: UICloudSharingController, source: Source) {
        printD("Presenting UICloudSharingController via UIKit")

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              var topController = window.rootViewController else {
            printD("Cannot find window or root view controller")
            return
        }

        while let presented = topController.presentedViewController {
            topController = presented
        }

        let isOwner = viewModel.isSharedOwner(source) || source.isPersonal
        let proxy = SharingDelegateProxy(
            sourceTitle: source.name,
            onSave: {
                viewModel.markSourceSharedLocally(source)
                Task {
                    await viewModel.loadSources()
                }
            },
            onStop: {
                Task {
                    if isOwner {
                        await viewModel.loadSources()
                    } else {
                        await viewModel.cloudKitManager.removeSharedSourceLocally(source)
                    }
                }
            }
        )
        controller.delegate = proxy
        sharingDelegateProxy = proxy

        DispatchQueue.main.async {
            topController.present(controller, animated: true) {
                printD("UICloudSharingController presented successfully")
            }
        }
    }

    final class SharingDelegateProxy: NSObject, UICloudSharingControllerDelegate, UIAdaptivePresentationControllerDelegate {
        let sourceTitle: String
        let onSave: () -> Void
        let onStop: () -> Void
        private var didStopSharing = false

        init(sourceTitle: String, onSave: @escaping () -> Void, onStop: @escaping () -> Void) {
            self.sourceTitle = sourceTitle
            self.onSave = onSave
            self.onStop = onStop
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            // no-op
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            printD("SharingDelegateProxy: cloudSharingControllerDidSaveShare")
            onSave()
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            printD("SharingDelegateProxy: cloudSharingControllerDidStopSharing")
            didStopSharing = true
            onStop()
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            printD("SharingDelegateProxy: presentationControllerDidDismiss - refreshing sources")
            if !didStopSharing {
                onSave()
            }
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            sourceTitle
        }
    }
}
#endif
