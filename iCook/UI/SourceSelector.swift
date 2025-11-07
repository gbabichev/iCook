import SwiftUI
import CloudKit
#if os(iOS)
import UIKit
#endif

struct SourceSelector: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var showNewSourceSheet = false
    @State private var newSourceName = ""
    @State private var isPreparingShare = false

#if os(iOS)
    @State private var shareData: ShareData?
    @State private var showShareSuccess = false
    @State private var sharingController: UICloudSharingController?
    @State private var sharingCoordinator: SharingControllerWrapper.Coordinator?

    struct ShareData: Identifiable {
        let id = UUID()
        let controller: UICloudSharingController
        let source: Source
    }
#endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Show any errors
                if let error = viewModel.cloudKitManager.error {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                    }
                    .padding()
                    .background(.orange.opacity(0.1))
                    .frame(maxWidth: .infinity)
                }

                if viewModel.sources.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "fork.knife")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)

                        Text("No Sources")
                            .font(.headline)

                        Text("Create a new source to get started")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.gray.opacity(0.05))
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(viewModel.sources, id: \.id) { source in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(source.name)
                                            .font(.headline)
                                            .fontWeight(viewModel.currentSource?.id == source.id ? .semibold : .regular)

                                        Text(source.isPersonal ? "Personal" : "Shared")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

#if os(iOS)
                                    // Share button for personal sources
                                    if source.isPersonal {
                                        Button(action: {
                                            Task {
                                                await prepareShare(for: source)
                                            }
                                        }) {
                                            Image(systemName: "square.and.arrow.up")
                                                .font(.system(size: 16))
                                                .foregroundColor(.blue)
                                                .padding(8)
                                        }
                                    }
#endif

                                    // Selection indicator
                                    if viewModel.currentSource?.id == source.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundColor(.blue)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Task {
                                        await viewModel.selectSource(source)
                                    }
                                }
                                .padding()
                                .background(.gray.opacity(0.05))
                                .cornerRadius(8)
                            }
                            .padding()
                        }
                    }
                }

                Divider()

                // New source button
                Button(action: { showNewSourceSheet = true }) {
                    Label("New Source", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .foregroundColor(.blue)
                }
                .buttonStyle(.bordered)
                .padding()
            }
            .navigationTitle("Sources")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .task {
                // Refresh sources when overlay opens
                await viewModel.loadSources()
            }
        }
        .sheet(isPresented: $showNewSourceSheet) {
            NewSourceSheet(
                isPresented: $showNewSourceSheet,
                sourceName: $newSourceName
            )
            .environmentObject(viewModel)
        }
#if os(iOS)
        // Show success alert when sharing completes
        .alert("Share Completed!", isPresented: $showShareSuccess) {
            Button("OK") { }
        } message: {
            Text("The share link has been copied to your clipboard. Paste it in Messages, Email, or any other app to share!")
        }
#endif
    }

#if os(iOS)
    private func prepareShare(for source: Source) async {
        isPreparingShare = true
        defer { isPreparingShare = false }

        printD("Preparing share for source: \(source.name)")

        // Use the new prepareSharingController method which follows CloudKit best practices
        await MainActor.run {
            viewModel.cloudKitManager.prepareSharingController(for: source) { controller in
                if let controller = controller {
                    printD("Sharing controller prepared successfully")
                    // Present the controller directly via UIKit to ensure proper lifecycle
                    presentUICloudSharingController(controller)
                } else {
                    printD("Failed to prepare sharing controller")
                    printD("Error from CloudKitManager: \(viewModel.cloudKitManager.error ?? "No error message")")
                }
            }
        }
    }

    /// Present UICloudSharingController directly via UIKit
    private func presentUICloudSharingController(_ controller: UICloudSharingController) {
        printD("Presenting UICloudSharingController via UIKit")

        // Get the top view controller
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              var topController = window.rootViewController else {
            printD("Cannot find window or root view controller")
            return
        }

        // Find the topmost view controller
        while let presented = topController.presentedViewController {
            topController = presented
        }

        // Present modally
        DispatchQueue.main.async {
            topController.present(controller, animated: true) {
                printD("UICloudSharingController presented successfully")
            }
        }
    }
#else
    private func prepareShare(for source: Source) async {
        printD("Sharing not available on macOS")
    }
#endif
}

struct SourceRow: View {
    let source: Source
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onShare: () -> Void

    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            // Source info
            VStack(alignment: .leading, spacing: 4) {
                Text(source.name)
                    .font(.headline)
                    .fontWeight(isSelected ? .semibold : .regular)

                Text(source.isPersonal ? "Personal" : "Shared")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Share button for personal sources
            if source.isPersonal {
                Button(action: onShare) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16))
                        .foregroundColor(.blue)
                        .padding(8)
                }
            }

            // Selection indicator
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.blue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .alert("Delete Source", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("Are you sure you want to delete '\(source.name)'? This will also delete all recipes in this source.")
        }
    }
}

struct NewSourceSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var sourceName: String
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Source Name") {
                    TextField("e.g., Family Recipes", text: $sourceName)
                }

                Section {
                    Text("Personal sources are stored in your private iCloud space and can be shared with others.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("New Source")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                        sourceName = ""
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        isCreating = true
                        Task {
                            _ = await viewModel.createSource(name: sourceName)
                            isPresented = false
                            sourceName = ""
                            isCreating = false
                        }
                    }
                    .disabled(sourceName.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                }
            }
        }
    }
}

#if os(iOS)
/// Wrapper to present a UICloudSharingController in SwiftUI
struct SharingControllerWrapper: UIViewControllerRepresentable {
    let controller: UICloudSharingController
    var onCompletion: (Bool) -> Void = { _ in }
    var onFailure: (Error) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        printD("========== SharingControllerWrapper.makeUIViewController called ==========")
        printD("Controller: \(controller)")
        printD("Coordinator: \(context.coordinator)")

        // Set delegate to handle callbacks
        controller.delegate = context.coordinator
        printD("Delegate set on controller")
        printD("Controller.delegate: \(String(describing: controller.delegate))")

        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {
        // No update needed
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator(onCompletion: onCompletion, onFailure: onFailure)
    }

    class Coordinator: NSObject, UICloudSharingControllerDelegate {
        var onCompletion: (Bool) -> Void
        var onFailure: (Error) -> Void

        init(onCompletion: @escaping (Bool) -> Void, onFailure: @escaping (Error) -> Void) {
            self.onCompletion = onCompletion
            self.onFailure = onFailure
            DispatchQueue.main.async {
                printD("Coordinator initialized")
            }
        }

        deinit {
            DispatchQueue.main.async {
                printD("Coordinator deinitialized")
            }
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            DispatchQueue.main.async {
                printD("========== cloudSharingControllerDidSaveShare called ==========")
                if let share = csc.share {
                    printD("Share ID: \(share.recordID.recordName)")
                    printD("Share has URL: \(share.url?.absoluteString ?? "nil")")
                    if let url = share.url {
                        printD("Copying share URL to pasteboard: \(url.absoluteString)")
                        UIPasteboard.general.url = url
                        printD("URL copied to pasteboard successfully")
                    } else {
                        printD("WARNING: Share URL is still nil!")
                    }
                } else {
                    printD("WARNING: Share object is nil!")
                }
                printD("========== Calling onCompletion ==========")
                self.onCompletion(true)
            }
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            DispatchQueue.main.async {
                printD("========== cloudSharingControllerDidStopSharing called ==========")
                self.onCompletion(false)
            }
        }

        func cloudSharingController(
            _ csc: UICloudSharingController,
            failedToSaveShareWithError error: Error
        ) {
            DispatchQueue.main.async {
                printD("========== failedToSaveShareWithError called ==========")
                printD("Error: \(error.localizedDescription)")
                self.onFailure(error)
            }
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            DispatchQueue.main.async {
                printD("itemTitle called")
            }
            return "Share Recipe Source"
        }

        // Additional delegate methods to track all calls
        func cloudSharingController(_ csc: UICloudSharingController, shouldStopSharingAfterSaving saveSuccess: Bool) -> Bool {
            DispatchQueue.main.async {
                printD("shouldStopSharingAfterSaving called: saveSuccess=\(saveSuccess)")
            }
            return true
        }

        func cloudSharingControllerDidStopSharingBecauseOfAccountChange(_ csc: UICloudSharingController) {
            DispatchQueue.main.async {
                printD("cloudSharingControllerDidStopSharingBecauseOfAccountChange called")
                self.onCompletion(false)
            }
        }
    }
}
#endif

#Preview {
    SourceSelector()
        .environmentObject(AppViewModel())
}
