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
#if DEBUG
    @Environment(\.openURL) private var openURL
#endif
    @State private var showNewSourceSheet = false
    @State private var newSourceName = ""
    @State private var isPreparingShare = false
    @State private var showShareSuccess = false
    @State private var shareSuccessMessage = ""
    @State private var sourceToDelete: Source?
    @State private var showDeleteConfirmation = false
    @State private var showShareCopiedToast = false
    @State private var shareToastMessage = ""

#if os(iOS)
    @State private var shareData: ShareData?
    @State private var sharingController: UICloudSharingController?
    @State private var sharingCoordinator: SharingControllerWrapper.Coordinator?
    @State private var sharingDelegateProxy: SharingDelegateProxy?

    struct ShareData: Identifiable {
        let id = UUID()
        let controller: UICloudSharingController
        let source: Source
    }
#endif

#if DEBUG
    @State private var debugShareURLString = ""
    @State private var showDebugShareAlert = false
    @State private var debugShareAlertMessage = ""
    @State private var isProcessingDebugShare = false
#endif

#if os(macOS)
private struct MacToolbarIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    let shortcut: KeyboardShortcut?

    init(systemImage: String, help: String, shortcut: KeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Group {
            if let shortcut {
                Button(action: action) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .keyboardShortcut(shortcut)
            } else {
                Button(action: action) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
            }
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
            .navigationTitle("Collections")
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
                Text("Collections")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                MacToolbarIconButton(systemImage: "plus", help: "Add new collection") {
                    showNewSourceSheet = true
                }

                MacToolbarIconButton(
                    systemImage: "arrow.clockwise",
                    help: "Refresh collections",
                    shortcut: KeyboardShortcut(.init("r"), modifiers: .command)
                ) {
                    Task {
                        await viewModel.loadSources()
                    }
                }

                MacToolbarIconButton(systemImage: "xmark", help: "Close") {
                    dismiss()
                }
            }
            .padding(12)


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
        .onReceive(NotificationCenter.default.publisher(for: .shareURLCopied)) { _ in
            withAnimation {
                shareToastMessage = "Share URL copied to clipboard"
                showShareCopiedToast = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation {
                    showShareCopiedToast = false
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

            if showShareCopiedToast {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Label(shareToastMessage.isEmpty ? "Preparing to share..." : shareToastMessage, systemImage: "doc.on.clipboard")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                            .shadow(radius: 6)
                        Spacer()
                    }
                    .padding(.bottom, 16)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
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
                    Text("Create recipe collections for different themes or occasions. Share any collection with friends!")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    if viewModel.sources.isEmpty {
                        Text("No Collections yet")
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
                                },
                                onRemoveShare: {
                                    Task {
                                        await viewModel.forceRemoveSource(source)
                                        // Update list immediately
                                        viewModel.removeSourceFromList(source)
                                    }
                                }
                            )
                        }
                    }
                }

#if DEBUG
                Section("Debug: Accept Shared Link") {
                    TextField("Paste shared iCloud URL", text: $debugShareURLString)
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                        .autocorrectionDisabled()

                    Button("Open Shared URL") {
                        openDebugShareURL()
                    }
                    .disabled(debugShareURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessingDebugShare)
                }
#endif
            }
            .listStyle(.automatic)
#if DEBUG
            .alert("Debug Share URL", isPresented: $showDebugShareAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(debugShareAlertMessage)
            }
#endif
#if os(iOS)
            .refreshable {
                await viewModel.loadSources()
                // Force-refresh recipes for the current source so images reflect latest changes
                await viewModel.loadRandomRecipes(skipCache: true)
            }
#endif
        }
        .onAppear {
            viewModel.clearErrors()
        }
    }


#if DEBUG
    private func openDebugShareURL() {
        let trimmed = debugShareURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), !trimmed.isEmpty else {
            debugShareAlertMessage = "Please enter a valid iCloud share URL."
            showDebugShareAlert = true
            return
        }

        debugShareAlertMessage = "Processing shared link…"
        showDebugShareAlert = true
        isProcessingDebugShare = true

        Task {
            let success = await viewModel.acceptShareURL(url)
            await MainActor.run {
                isProcessingDebugShare = false
                if success {
                    debugShareAlertMessage = "Share accepted. If the collection does not appear, pull to refresh or reopen Collections."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        showDebugShareAlert = false
                    }
                } else {
                    debugShareAlertMessage = viewModel.cloudKitManager.error ?? "Failed to accept the share."
                }
            }
        }
    }
#endif


    private func shareSource(for source: Source) async {
        isPreparingShare = true
        defer { isPreparingShare = false }

        printD("Getting share URL for source: \(source.name)")

#if os(iOS)
        // Always use UICloudSharingController so we can manage invites/participants
        if viewModel.isSharedOwner(source),
           let shareController = await viewModel.cloudKitManager.existingSharingController(for: source) {
            await MainActor.run {
                presentUICloudSharingController(shareController, source: source)
            }
            return
        }

        // If collaborator, present sharing controller to allow "Leave Share"
        if !viewModel.isSharedOwner(source), viewModel.cloudKitManager.isSharedSource(source),
           let controller = await viewModel.cloudKitManager.participantSharingController(for: source) {
            await MainActor.run {
                presentUICloudSharingController(controller, source: source)
            }
            return
        }

        viewModel.cloudKitManager.prepareSharingController(for: source) { controller in
            Task { @MainActor in
                if let controller {
                    presentUICloudSharingController(controller, source: source)
                } else {
                    printD("Failed to prepare sharing controller")
                    shareSuccessMessage = viewModel.cloudKitManager.error ?? "Failed to start sharing"
                    showShareSuccess = true
                }
            }
        }
#else
        // If collaborator, leave the share directly
        if !viewModel.isSharedOwner(source), viewModel.cloudKitManager.isSharedSource(source) {
            printD("macOS collaborator leave flow for source: \(source.name)")
            await viewModel.leaveSharedSource(source)
            return
        }

        await MainActor.run {
            withAnimation {
                shareToastMessage = "Preparing to share..."
                showShareCopiedToast = true
            }
        }

        if let shareURL = await viewModel.cloudKitManager.getShareURL(for: source) {
            printD("Got share URL: \(shareURL.absoluteString)")

            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(shareURL.absoluteString, forType: .string)
                withAnimation {
                    shareToastMessage = "Share URL copied to clipboard"
                    showShareCopiedToast = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation {
                        showShareCopiedToast = false
                    }
                }
                printD("Share URL ready for sharing")
                Task {
                    await viewModel.loadSources()
                }
            }
        } else {
            await MainActor.run {
                printD("Failed to get share URL")
                shareSuccessMessage = "Failed to get share URL: \(viewModel.cloudKitManager.error ?? "Unknown error")"
                showShareSuccess = true
            }
        }
#endif
    }

#if os(iOS)
    @MainActor
    private func presentShareSheet(with url: URL) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }),
              var topController = window.rootViewController else {
            printD("Cannot find window to present share sheet")
            return
        }

        while let presented = topController.presentedViewController {
            topController = presented
        }

        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topController.view
            popover.sourceRect = CGRect(x: topController.view.bounds.midX, y: topController.view.bounds.midY, width: 0, height: 0)
        }

        topController.present(activityVC, animated: true)
    }
#endif

#if os(iOS)
    /// Present UICloudSharingController directly via UIKit
    private func presentUICloudSharingController(_ controller: UICloudSharingController, source: Source) {
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

        // Install delegate proxy so we can detect stop-sharing and update state
        let isOwner = viewModel.isSharedOwner(source)
        let proxy = SharingDelegateProxy(
            onStopSharing: {
                Task {
                    if isOwner {
                        await viewModel.stopSharingSource(source)
                    } else {
                        await viewModel.removeSharedSourceLocally(source)
                    }
                }
            },
            onSave: {
                Task {
                    await viewModel.loadSources()
                }
            }
        )
        controller.delegate = proxy
        sharingDelegateProxy = proxy

        // Present modally
        DispatchQueue.main.async {
            topController.present(controller, animated: true) {
                printD("UICloudSharingController presented successfully")
            }
        }
    }
#else
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

#if os(iOS)
/// Delegate proxy to observe stop sharing events.
private final class SharingDelegateProxy: NSObject, UICloudSharingControllerDelegate {
    let onStopSharing: () -> Void
    let onSave: () -> Void

    init(onStopSharing: @escaping () -> Void, onSave: @escaping () -> Void) {
        self.onStopSharing = onStopSharing
        self.onSave = onSave
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
        onStopSharing()
    }

    func itemTitle(for csc: UICloudSharingController) -> String? {
        nil
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

struct NewSourceSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var sourceName: String
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Collection Name") {
                    TextField("e.g., Family Recipes", text: $sourceName)
                }

                Section {
                    Text("Collections are stored in iCloud, and can be shared with others.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Collection")
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
    let onRemoveShare: () -> Void
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .fontWeight(isSelected ? .semibold : .regular)

                if viewModel.isSourceShared(source) {
                    HStack(spacing: 6) {
                        if viewModel.isSharedOwner(source) {
                            Label("Owner", systemImage: "crown.fill")
                        } else {
                            Label("Collaborator", systemImage: "person.2.fill")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
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

            // Share / manage sharing
            if source.isPersonal {
                Button(action: onShare) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 14))
                }
                .buttonStyle(.bordered)

            } else {
                // Collaborators use the share action to open UICloudSharingController (for "Remove Me")
                Button(action: onShare) {
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .font(.system(size: 14))
                }
                .buttonStyle(.bordered)
            }

#if os(macOS)
            if viewModel.isSharedOwner(source) || source.isPersonal {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
#endif
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
#if os(iOS)
        .swipeActions(edge: .trailing) {
            if source.isPersonal {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            } else {
                Button(role: .destructive, action: onShare) {
                    Label("Manage", systemImage: "person.crop.circle.badge.xmark")
                }
            }
        }
#endif
    }
}
