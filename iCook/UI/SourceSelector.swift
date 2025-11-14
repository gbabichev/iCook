import SwiftUI
import CloudKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SourceSelector: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) var dismiss
    @State private var showNewSourceSheet = false
    @State private var newSourceName = ""
    @State private var isPreparingShare = false
    @State private var showShareSuccess = false
    @State private var shareSuccessMessage = ""
    @State private var sourceToDelete: Source?
    @State private var showDeleteConfirmation = false

#if os(iOS)
    @State private var shareData: ShareData?
    @State private var sharingController: UICloudSharingController?
    @State private var sharingCoordinator: SharingControllerWrapper.Coordinator?

    struct ShareData: Identifiable {
        let id = UUID()
        let controller: UICloudSharingController
        let source: Source
    }
#endif

#if os(macOS)
private struct MacToolbarIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .padding(4)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(help)
    }
}
#endif

    var body: some View {
#if os(iOS)
        iOSView
#elseif os(macOS)
        macOSView
#endif
    }

#if os(iOS)
    private var iOSView: some View {
        NavigationStack {
            ZStack {
                sourcesListView

                // Alerts and sheets
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
            .navigationTitle("Sources")
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
#elseif os(macOS)
    private var macOSView: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack(spacing: 8) {
                Text("Sources")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                MacToolbarIconButton(systemImage: "plus", help: "Add new source") {
                    showNewSourceSheet = true
                }

                MacToolbarIconButton(systemImage: "xmark", help: "Close") {
                    dismiss()
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .border(Color(nsColor: .separatorColor), width: 1)

            // Content area
            macOSListContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var macOSListContent: some View {
        ZStack {
            sourcesListView

            // Alerts
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
    }
#endif

    private var sourcesListView: some View {
        VStack(spacing: 0) {
            if let error = viewModel.cloudKitManager.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                }
                .padding(8)
                .background(.orange.opacity(0.1))
                .frame(maxWidth: .infinity)
            }

            List {
                Section {
                    if viewModel.sources.isEmpty {
                        Text("No sources yet")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.sources, id: \.id) { source in
                            SourceRowWrapper(
                                source: source,
                                isSelected: viewModel.currentSource?.id == source.id,
                                onSelect: {
                                    Task {
                                        await viewModel.selectSource(source)
                                    }
                                },
                                onShare: {
                                    Task {
                                        await shareSource(for: source)
                                    }
                                },
                                onDelete: {
                                    sourceToDelete = source
                                    showDeleteConfirmation = true
                                }
                            )
                        }
                    }
                }
            }
            .listStyle(.automatic)
        }
    }


    private func shareSource(for source: Source) async {
        isPreparingShare = true
        defer { isPreparingShare = false }

        printD("Getting share URL for source: \(source.name)")

        if let shareURL = await viewModel.cloudKitManager.getShareURL(for: source) {
            printD("Got share URL: \(shareURL.absoluteString)")

            // Copy to clipboard
            await MainActor.run {
#if os(iOS)
                UIPasteboard.general.url = shareURL
#elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(shareURL.absoluteString, forType: .string)
#endif
                shareSuccessMessage = "Link copied to clipboard"
                showShareSuccess = true
                printD("Share URL copied to clipboard")
            }
        } else {
            await MainActor.run {
                printD("Failed to get share URL")
                shareSuccessMessage = "Failed to get share URL: \(viewModel.cloudKitManager.error ?? "Unknown error")"
                showShareSuccess = true
            }
        }
    }

#if os(iOS)
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
#elseif os(macOS)
    /// Present NSSharingServicePicker on macOS
    private func presentSharingServices(with url: URL, sourceTitle: String) {
        printD("Presenting NSSharingServicePicker with URL: \(url.absoluteString)")

        let servicePicker = NSSharingServicePicker(items: [url])

        // Find the share button view and present from there
        if let window = NSApplication.shared.mainWindow,
           let contentView = window.contentViewController?.view {
            // Present the picker from the center of the window
            servicePicker.show(relativeTo: NSZeroRect, of: contentView, preferredEdge: .minY)

            printD("NSSharingServicePicker presented successfully")
        } else {
            printD("Could not find window to present from")
        }
    }
#endif

    private func deleteSource(_ source: Source) async {
        printD("Deleting source: \(source.name)")

        // Delete all categories in this source
        let categoriesToDelete = viewModel.categories.filter { $0.sourceID == source.id }
        for category in categoriesToDelete {
            await viewModel.deleteCategory(id: category.id)
            printD("Deleted category: \(category.name)")
        }

        // Delete all recipes in this source
        let recipesToDelete = viewModel.recipes.filter { $0.sourceID == source.id }
        for recipe in recipesToDelete {
            _ = await viewModel.deleteRecipe(id: recipe.id)
            printD("Deleted recipe: \(recipe.name)")
        }

        // Delete the source itself
        _ = await viewModel.deleteSource(source)
        printD("Deleted source: \(source.name)")

        // Clear the deletion state
        sourceToDelete = nil

        // Reload sources
        await viewModel.loadSources()
    }
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

struct SourceRowWrapper: View {
    let source: Source
    let isSelected: Bool
    let onSelect: () -> Void
    let onShare: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .fontWeight(isSelected ? .semibold : .regular)

                Text(source.isPersonal ? "Personal" : "Shared")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Selection checkbox (always takes space)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.blue)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.clear)
            }

            // Share button
            if source.isPersonal {
                Button(action: onShare) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14))
                }
                .buttonStyle(.bordered)
#if os(macOS)
                .controlSize(.small)
#endif
            } else {
                Color.clear
                    .frame(width: 32, height: 32)
            }

#if os(macOS)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
#endif
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
#if os(iOS)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
#endif
    }
}

#Preview {
    SourceSelector()
        .environmentObject(AppViewModel())
}
