#if os(macOS)
import SwiftUI
import CloudKit
import AppKit


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

private final class MacSharingDelegateProxy: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate, NSCloudSharingServiceDelegate {
    let onDidShare: () -> Void
    let onDidFail: (Error) -> Void

    init(onDidShare: @escaping () -> Void, onDidFail: @escaping (Error) -> Void) {
        self.onDidShare = onDidShare
        self.onDidFail = onDidFail
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        self
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        onDidShare()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        if isUserCancellation(error) {
            printD("macOS CloudKit sharing dismissed by user")
            return
        }
        onDidFail(error)
    }

    private func isUserCancellation(_ error: Error) -> Bool {
        if let ckError = error as? CKError, ckError.code == .operationCancelled {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
            return true
        }
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        return false
    }
}

extension SourceSelector {
    var macOSView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.2.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Collections and app preferences")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                MacToolbarIconButton(systemImage: "plus", help: "Add new collection") {
                    showNewSourceSheet = true
                }

                if isRefreshingCollections {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                        .padding(4)
                        .help("Refreshing collections")
                } else {
                    MacToolbarIconButton(
                        systemImage: "arrow.clockwise",
                        help: "Refresh collections",
                        shortcut: KeyboardShortcut(.init("r"), modifiers: .command)
                    ) {
                        Task {
                            await refreshCollectionsAndRecipes()
                        }
                    }
                }

                MacToolbarIconButton(systemImage: "xmark", help: "Close") {
                    dismiss()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            macOSListContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
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

    var macOSListContent: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = viewModel.cloudKitManager.error {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(12)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Collections")
                                .font(.headline)
                            Spacer()
                            Text("\(viewModel.sources.count)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Text("Organize recipes into collections by theme or occasion, and share collections with others.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if viewModel.sources.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "square.stack")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                Text("No collections yet")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Button("Create Collection") {
                                    showNewSourceSheet = true
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(viewModel.sources, id: \.id) { source in
                                    let isSelected = viewModel.currentSource?.id == source.id
                                    let isHovered = hoveredSourceID == source.id
                                    sourceRow(for: source)
                                        .padding(10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(
                                                    isSelected
                                                        ? Color.accentColor.opacity(isHovered ? 0.20 : 0.14)
                                                        : Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.75 : 0.45)
                                                )
                                        )
                                        .onHover { hovering in
                                            if hovering {
                                                hoveredSourceID = source.id
                                            } else if hoveredSourceID == source.id {
                                                hoveredSourceID = nil
                                            }
                                        }
                                }
                            }
                            .animation(.easeInOut(duration: 0.12), value: hoveredSourceID)
                        }
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("App")
                            .font(.headline)

                        SettingsRow(
                            "Feeling Lucky",
                            systemImage: "die.face.5",
                            subtitle: "Enable a button to pick random recipes."
                        ) {
                            Toggle("", isOn: $enableFeelingLucky)
                            .toggleStyle(.switch)
                        }
                        
                        Divider()

                        HStack {
                            Text("Total Recipes")
                            Spacer()
                            Text("\(totalRecipeCountAllCollections)")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        .font(.callout)

                        HStack {
                            Text("Version")
                            Spacer()
                            Text(appVersionString)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        .font(.callout)

                        Divider()

                        SettingsRow(
                            "Help",
                            systemImage: "questionmark.circle",
                            subtitle: "Open the tutorial again."
                        ) {
                            Button("Open") {
                                Task { @MainActor in
                                    reopenTutorialFromSettings()
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(16)
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

    func shareSource(for source: Source) async {
        isPreparingShare = true

        printD("Getting share URL for source: \(source.name)")

        if !viewModel.isSharedOwner(source), viewModel.cloudKitManager.isSharedSource(source) {
            printD("macOS collaborator leave flow for source: \(source.name)")
            await viewModel.leaveSharedSource(source)
            isPreparingShare = false
            return
        }

        if viewModel.isSharedOwner(source), viewModel.isSourceShared(source) {
            let didPresentManagement = await presentMacCloudSharingManagement(for: source)
            if didPresentManagement {
                isPreparingShare = false
                return
            }
        }

        await MainActor.run {
            withAnimation {
                shareToastMessage = "Preparing to share..."
                showShareCopiedToast = true
            }
        }

        _ = await presentMacCloudKitSharingPicker(for: source)
        isPreparingShare = false
    }

    @MainActor
    private func presentMacCloudSharingManagement(for source: Source) async -> Bool {
        do {
            let share = try await viewModel.cloudKitManager.preparedShareForActivitySheet(
                sourceID: source.id,
                sourceName: source.name
            )
            let itemProvider = NSItemProvider()
            itemProvider.registerCloudKitShare(
                share,
                container: viewModel.cloudKitManager.container
            )
            let items: [Any] = [itemProvider]

            guard let cloudSharingService = NSSharingService(named: .cloudSharing) else {
                return false
            }
            guard cloudSharingService.canPerform(withItems: items) else {
                printD("macOS CloudKit management service cannot perform with registered CloudKit share provider")
                return false
            }

            let delegate = MacSharingDelegateProxy(
                onDidShare: {
                    Task {
                        await MainActor.run {
                            self.viewModel.markSourceSharedLocally(source)
                        }
                        await self.viewModel.loadSources()
                    }
                },
                onDidFail: { error in
                    Task { @MainActor in
                        self.shareSuccessMessage = "Failed to share: \(error.localizedDescription)"
                        self.showShareSuccess = true
                    }
                }
            )
            cloudSharingService.delegate = delegate
            activeMacSharingService = cloudSharingService
            macSharingDelegateProxy = delegate

            withAnimation {
                showShareCopiedToast = false
            }

            cloudSharingService.perform(withItems: items)
            printD("Presented macOS CloudKit management UI")
            return true
        } catch {
            shareSuccessMessage = "Failed to open sharing options: \(error.localizedDescription)"
            showShareSuccess = true
            return false
        }
    }

    @MainActor
    private func presentMacCloudKitSharingPicker(for source: Source) async -> Bool {
        guard let anchorView = NSApp.keyWindow?.contentView
            ?? NSApp.mainWindow?.contentView
            ?? NSApp.windows.first(where: { $0.isVisible })?.contentView else {
            return await copyShareURLToClipboard(for: source)
        }

        withAnimation {
            showShareCopiedToast = false
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

        let appIcon = NSApp.applicationIconImage
        let previewItem = NSPreviewRepresentingActivityItem(
            item: itemProvider,
            title: source.name,
            image: appIcon,
            icon: appIcon
        )
        let picker = NSSharingServicePicker(items: [previewItem])
        let delegate = MacSharingDelegateProxy(
            onDidShare: {
                Task {
                    await MainActor.run {
                        self.viewModel.markSourceSharedLocally(source)
                    }
                    await self.viewModel.loadSources()
                }
            },
            onDidFail: { error in
                Task { @MainActor in
                    self.shareSuccessMessage = "Failed to share: \(error.localizedDescription)"
                    self.showShareSuccess = true
                }
            }
        )
        picker.delegate = delegate
        activeMacSharePicker = picker
        macSharingDelegateProxy = delegate
        let anchorRect = NSRect(
            x: anchorView.bounds.midX,
            y: anchorView.bounds.midY,
            width: 1,
            height: 1
        )
        picker.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .minY)
        printD("Presented macOS CloudKit sharing picker")
        return true
    }

    @MainActor
    private func copyShareURLToClipboard(for source: Source) async -> Bool {
        if let shareURL = await viewModel.cloudKitManager.getShareURL(for: source) {
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
            Task {
                await viewModel.loadSources()
            }
            return true
        } else {
            shareSuccessMessage = "Failed to get share URL: \(viewModel.cloudKitManager.error ?? "Unknown error")"
            showShareSuccess = true
            return false
        }
    }
}
#endif
