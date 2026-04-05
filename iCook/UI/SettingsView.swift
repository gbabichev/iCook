import SwiftUI
import CloudKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SourceSelector: View {
    struct ExportPreviewPayload: Identifiable {
        let source: Source
        let snapshot: SourceExportSnapshot

        var id: CKRecord.ID { source.id }
    }

    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) var dismiss
    @AppStorage("EnableFeelingLucky") var enableFeelingLucky = true
    @AppStorage("ShowInlineTitles") var showInlineTitles = true
    @AppStorage("ShowRecipeDetailTags") var showRecipeDetailTags = true
    @AppStorage("AutoCheckStepsFromIngredients") var autoCheckStepsFromIngredients = false
    @AppStorage("AutoScrollToNextStep") var autoScrollToNextStep = true
    @AppStorage("KeepScreenOn") var keepScreenOn = false

    @State var showNewSourceSheet = false
    @State var newSourceName = ""
    @State var isPreparingShare = false
    @State var showShareSuccess = false
    @State var shareSuccessMessage = ""
    @State var editingSource: Source?
    @State var sourceToDelete: Source?
    @State var showDeleteConfirmation = false
    @State var recipeTotalsBySource: [CKRecord.ID: Int] = [:]
    @State var isExporting = false
    @State var exportDocument = RecipeExportDocument()
    @State var exportFilename = "RecipesExport.icookexport"
    @State var exportingSourceID: CKRecord.ID?
    @State private var exportPreview: ExportPreviewPayload?
    @State private var exportSelectedCategoryIDs: Set<CKRecord.ID> = []
    @State private var exportIncludeTags = true
    @State private var exportIncludeFavorites = true
    @State private var exportIncludeLinkedRecipes = true
    @State private var isPreparingExportDocument = false
    @State private var deletingSourceID: CKRecord.ID?
#if os(macOS)
    @State var showShareCopiedToast = false
    @State var shareToastMessage = ""
    @State var activeMacSharePicker: NSSharingServicePicker?
    @State var activeMacSharingService: NSSharingService?
    @State var macSharingDelegateProxy: AnyObject?
    @State var hoveredSourceID: CKRecord.ID?
    @State var isRefreshingCollections = false
    @State var exportStatusSourceName: String?
#endif
#if os(iOS)
    @State var sharingDelegateProxy: AnyObject?
    @State private var isRefreshingSettings = false
    @State private var frozenLastSyncedSummary: String?
#endif

    var appVersionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return version == build ? version : "\(version) (\(build))"
    }

    var totalRecipeCountAllCollections: Int {
        recipeTotalsBySource.values.reduce(0, +)
    }

    var lastSyncedSummary: String? {
        guard let date = viewModel.lastSuccessfulCloudSyncAt else { return nil }
        return "Last synced \(date.formatted(.relative(presentation: .named)))"
    }

#if os(iOS)
    var displayedLastSyncedSummary: String? {
        if isRefreshingSettings {
            return frozenLastSyncedSummary ?? lastSyncedSummary
        }
        return lastSyncedSummary
    }
#endif

    var visibleSources: [Source] {
        viewModel.sources
    }

    var sourceTotalsRefreshKey: String {
        visibleSources
            .map { "\($0.id.zoneID.ownerName)|\($0.id.zoneID.zoneName)|\($0.id.recordName)" }
            .sorted()
            .joined(separator: ",")
    }

#if os(iOS)
    var keepScreenOnSystemImage: String {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return "iphone"
        case .pad:
            return "ipad"
        default:
            return "display"
        }
    }
#endif

    var body: some View {
        Group {
#if os(iOS)
            iOSView
#elseif os(macOS)
            macOSView
#endif
        }
        .disabled(viewModel.isAcceptingShare)
        .interactiveDismissDisabled(viewModel.isAcceptingShare)
        .overlay {
            if viewModel.isAcceptingShare {
                ZStack {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()

                    shareAcceptanceStatusCard()
                        .padding(24)
                }
                .transition(.opacity)
            }
        }
        .task(id: sourceTotalsRefreshKey) {
            await refreshRecipeTotals()
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: RecipeExportConstants.contentType,
            defaultFilename: exportFilename
        ) { result in
            cleanupTemporaryExportArtifact(named: exportFilename)
            isExporting = false
            isPreparingExportDocument = false
            exportingSourceID = nil
        }
        .onChange(of: isExporting) { _, newValue in
#if os(macOS)
            if newValue {
                exportStatusSourceName = nil
            }
#endif
            if !newValue {
                exportingSourceID = nil
                isPreparingExportDocument = false
#if os(macOS)
                exportStatusSourceName = nil
#endif
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $exportPreview) { payload in
            ExportPreviewSheet(
                source: payload.source,
                snapshot: payload.snapshot,
                selectedCategoryIDs: $exportSelectedCategoryIDs,
                includeTags: $exportIncludeTags,
                includeFavorites: $exportIncludeFavorites,
                includeLinkedRecipes: $exportIncludeLinkedRecipes,
                isPreparingExport: isPreparingExportDocument,
                onCancel: {
                    guard !isPreparingExportDocument else { return }
                    exportPreview = nil
                },
                onExport: {
                    Task {
                        await confirmExport(using: payload)
                    }
                }
            )
            .environmentObject(viewModel)
        }
        #else
        .sheet(item: $exportPreview) { payload in
            ExportPreviewSheet(
                source: payload.source,
                snapshot: payload.snapshot,
                selectedCategoryIDs: $exportSelectedCategoryIDs,
                includeTags: $exportIncludeTags,
                includeFavorites: $exportIncludeFavorites,
                includeLinkedRecipes: $exportIncludeLinkedRecipes,
                isPreparingExport: isPreparingExportDocument,
                onCancel: {
                    guard !isPreparingExportDocument else { return }
                    exportPreview = nil
                },
                onExport: {
                    Task {
                        await confirmExport(using: payload)
                    }
                }
            )
            .environmentObject(viewModel)
        }
        #endif
        .sheet(item: $editingSource) { source in
            EditSourceSheet(
                isPresented: Binding(
                    get: { editingSource != nil },
                    set: { if !$0 { editingSource = nil } }
                ),
                source: source
            )
            .environmentObject(viewModel)
        }
    }

    @ViewBuilder
    private func shareAcceptanceStatusCard() -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)

            Text("Connecting to Shared Collection")
                .font(.headline)

            Text("Your collection is being added and synced. This can take a moment.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 320)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(radius: 12)
    }

    @ViewBuilder
    func sourceRow(for source: Source) -> some View {
#if os(macOS)
        SourceRowWrapper(
            source: source,
            recipeCount: recipeTotalsBySource[source.id, default: 0],
            isSelected: viewModel.currentSource?.id == source.id,
            isExporting: exportingSourceID == source.id,
            isDeleting: deletingSourceID == source.id,
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
            onExport: {
                Task {
                    await exportSource(source)
                }
            },
            onRename: {
                beginRenaming(source)
            },
            onDelete: {
                sourceToDelete = source
                showDeleteConfirmation = true
            }
        )
#else
        SourceRowWrapper(
            source: source,
            recipeCount: recipeTotalsBySource[source.id, default: 0],
            isSelected: viewModel.currentSource?.id == source.id,
            isExporting: exportingSourceID == source.id,
            isDeleting: deletingSourceID == source.id,
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
            onExport: {
                Task {
                    await exportSource(source)
                }
            },
            onRename: {
                beginRenaming(source)
            },
            onDelete: {
                sourceToDelete = source
                showDeleteConfirmation = true
            }
        )
#endif
    }

    #if os(iOS)
    var sourcesListView: some View {
        VStack(spacing: 0) {
            if let error = viewModel.cloudStatusBannerMessage ?? viewModel.cloudKitManager.error {
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
                Section("Collections") {
                    Text("Organize recipes into collections by theme or occasion, and share collections with others.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if visibleSources.isEmpty {
                        Text("No Collections yet")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(visibleSources, id: \.id) { source in
                            sourceRow(for: source)
                        }
                    }

                    if let displayedLastSyncedSummary {
                        Label(displayedLastSyncedSummary, systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Settings") {
                    Toggle(isOn: $enableFeelingLucky) {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "die.face.5")
                                .frame(width: 20)
                                .foregroundStyle(.primary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Feeling Lucky")
                                Text("Enable a button to pick random recipes.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                    Toggle(isOn: $showInlineTitles) {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "text.justify")
                                .frame(width: 20)
                                .foregroundStyle(.primary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Inline Navigation Titles")
                                Text("Show collection and recipe titles in the toolbar.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                    Toggle(isOn: $showRecipeDetailTags) {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "tag")
                                .frame(width: 20)
                                .foregroundStyle(.primary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show Recipe Tags")
                                Text("Show tags on recipe pages, or hide them and manage them while editing.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                    Toggle(isOn: $autoCheckStepsFromIngredients) {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "checklist")
                                .frame(width: 20)
                                .foregroundStyle(.primary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-Check Steps")
                                Text("Automatically mark a step complete when all of its step ingredients are checked.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                    Toggle(isOn: $autoScrollToNextStep) {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "arrow.down.to.line")
                                .frame(width: 20)
                                .foregroundStyle(.primary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-Scroll Steps")
                                Text("After checking a step, automatically move to the next one in recipe detail.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                    Toggle(isOn: $keepScreenOn) {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: keepScreenOnSystemImage)
                                .frame(width: 20)
                                .foregroundStyle(.primary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keep Screen On")
                                Text("Prevent Auto-Lock and keep the display awake while iCook is active.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }

                Section("Help") {
                    Button {
                        Task { @MainActor in
                            reopenTutorialFromSettings()
                        }
                    } label: {
                        HStack {
                            Label("Help", systemImage: "questionmark.circle")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    HStack {
                        Text("Total Recipes")
                        Spacer()
                        Text("\(totalRecipeCountAllCollections)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersionString)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .listStyle(.automatic)
#if os(iOS)
            .refreshable {
                isRefreshingSettings = true
                frozenLastSyncedSummary = lastSyncedSummary
                defer {
                    frozenLastSyncedSummary = nil
                    isRefreshingSettings = false
                }

                if viewModel.canRetryCloudConnection {
                    await viewModel.retryCloudConnectionAndRefresh(skipRecipeCache: true)
                } else {
                    await viewModel.refreshSourcesAndCurrentContent(skipRecipeCache: true, forceProbe: true)
                }
            }
#endif
        }
        .onAppear {
            viewModel.clearErrors()
        }
    }
    #endif

    func beginRenaming(_ source: Source) {
        guard viewModel.canRenameSource(source) else { return }
        editingSource = source
    }

    func refreshRecipeTotals() async {
        let sources = visibleSources
        guard !sources.isEmpty else {
            recipeTotalsBySource = [:]
            return
        }

        var totals: [CKRecord.ID: Int] = [:]
        for source in sources {
            totals[source.id] = viewModel.cloudKitManager.cachedTotalRecipeCount(for: source)
        }
        recipeTotalsBySource = totals

        guard viewModel.cloudKitManager.isCloudKitAvailable else { return }

        for source in sources {
            let total = await viewModel.cloudKitManager.totalRecipeCount(for: source)
            recipeTotalsBySource[source.id] = total
        }
    }

    @MainActor
    func exportSource(_ source: Source) async {
        exportingSourceID = source.id
#if os(macOS)
        withAnimation(.easeInOut(duration: 0.18)) {
            exportStatusSourceName = source.name
        }
#endif
        defer {
            if !isExporting {
                exportingSourceID = nil
#if os(macOS)
                withAnimation(.easeInOut(duration: 0.18)) {
                    exportStatusSourceName = nil
                }
#endif
            }
        }

        let snapshot = await viewModel.cloudKitManager.exportSnapshot(for: source)
        exportSelectedCategoryIDs = Set(snapshot.categories.map(\.id))
        exportIncludeTags = true
        exportIncludeFavorites = true
        exportIncludeLinkedRecipes = true
        exportPreview = ExportPreviewPayload(source: source, snapshot: snapshot)
        exportingSourceID = nil
#if os(macOS)
        withAnimation(.easeInOut(duration: 0.18)) {
            exportStatusSourceName = nil
        }
#endif
    }

    @MainActor
    private func confirmExport(using payload: ExportPreviewPayload) async {
        guard !isPreparingExportDocument else { return }

        isPreparingExportDocument = true
        exportingSourceID = payload.source.id
#if os(macOS)
        withAnimation(.easeInOut(duration: 0.18)) {
            exportStatusSourceName = payload.source.name
        }
#endif
        defer {
            if !isExporting {
                exportingSourceID = nil
                isPreparingExportDocument = false
#if os(macOS)
                withAnimation(.easeInOut(duration: 0.18)) {
                    exportStatusSourceName = nil
                }
#endif
            }
        }

        let options = AppViewModel.ExportOptions(
            selectedCategoryIDs: exportSelectedCategoryIDs,
            includeTags: exportIncludeTags,
            includeFavorites: exportIncludeFavorites,
            includeLinkedRecipes: exportIncludeLinkedRecipes
        )

        if let document = await viewModel.exportSourceDocument(
            for: payload.source,
            snapshot: payload.snapshot,
            options: options
        ) {
            exportPreview = nil

            if isExporting {
                isExporting = false
                await Task.yield()
            }

            exportDocument = document
            exportFilename = suggestedExportFilename(for: payload.source)
            cleanupTemporaryExportArtifact(named: exportFilename)
            isPreparingExportDocument = false
            await Task.yield()
            isExporting = true
        }
    }

    private func suggestedExportFilename(for source: Source) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleanedScalars = source.name.unicodeScalars.map { scalar in
            invalidCharacters.contains(scalar) ? "-" : Character(scalar)
        }
        let baseName = String(cleanedScalars).trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = baseName.isEmpty ? "RecipesExport" : baseName
        return "\(fallbackName).icookexport"
    }

    private func cleanupTemporaryExportArtifact(named filename: String) {
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename, isDirectory: true)
        guard FileManager.default.fileExists(atPath: temporaryURL.path) else { return }

        do {
            try FileManager.default.removeItem(at: temporaryURL)
        } catch {}
    }

    @MainActor
    func reopenTutorialFromSettings() {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(name: .showTutorial, object: nil)
        }
    }

#if os(macOS)
    func refreshCollectionsAndRecipes() async {
        guard !isRefreshingCollections else { return }
        isRefreshingCollections = true
        defer { isRefreshingCollections = false }
        if viewModel.canRetryCloudConnection {
            await viewModel.retryCloudConnectionAndRefresh(skipRecipeCache: true)
        } else {
            await viewModel.refreshSourcesAndCurrentContent(skipRecipeCache: true, forceProbe: true)
        }
        await refreshRecipeTotals()
    }
#endif

    func deleteSource(_ source: Source) async {
        printD("Deleting source: \(source.name)")
        deletingSourceID = source.id
        let deletedCurrentSource = viewModel.currentSource?.id == source.id
        let deleted = await viewModel.deleteSource(source)
        deletingSourceID = nil
        if deleted {
            printD("Deleted source: \(source.name)")
            sourceToDelete = nil
            if deletedCurrentSource, let fallbackSource = viewModel.currentSource {
                await viewModel.selectSource(fallbackSource, skipCacheOnLoad: false)
            }
            await refreshRecipeTotals()
        } else {
            printD("Failed to delete source: \(source.name)")
        }
    }
}
struct NewSourceSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var sourceName: String
    @State private var isCreating = false

    private var trimmedSourceName: String {
        sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isCreateDisabled: Bool {
        trimmedSourceName.isEmpty || isCreating
    }
    
    var body: some View {
        Group {
#if os(macOS)
            macOSView
#else
            iOSView
#endif
        }
    }

    #if os(iOS)
    private var iOSView: some View {
        NavigationStack {
            Form {
                Section("Collection Name") {
                    TextField("e.g., Family Recipes", text: $sourceName)
                        .iOSModernInputFieldStyle()
#if os(iOS)
                        .textInputAutocapitalization(.words)
#endif
                        .labelsHidden()
                }
                
                Section("About Collections") {
                    Label("Stored in iCloud and synced across your devices.", systemImage: "icloud")
                        .foregroundStyle(.secondary)
                    Label("Can be shared with family and friends.", systemImage: "person.2")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
#if os(iOS)
            .scrollDismissesKeyboard(.immediately)
#endif
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
                        Task {
                            await createCollection()
                        }
                    }
                    .disabled(isCreateDisabled)
                }
#if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        dismissKeyboard()
                    }
                }
#endif
            }
        }
    }
    #endif

#if os(macOS)
    private var macOSView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Collection")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Create a new iCloud-synced recipe collection")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    isPresented = false
                    sourceName = ""
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    Task {
                        await createCollection()
                    }
                } label: {
                    if isCreating {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Creating...")
                        }
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCreateDisabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Collection Information")
                            .font(.headline)

                        TextField("e.g., Family Recipes", text: $sourceName)
                            .iOSModernInputFieldStyle()
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("About Collections")
                            .font(.headline)

                        Label("Stored in iCloud and synced across your devices.", systemImage: "icloud")
                            .foregroundStyle(.secondary)
                        Label("Can be shared with family and friends.", systemImage: "person.2")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(16)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
#endif

    @MainActor
    private func createCollection() async {
        guard !isCreateDisabled else { return }
        isCreating = true
        defer { isCreating = false }

        let created = await viewModel.createSource(name: trimmedSourceName)
        if created {
            isPresented = false
            sourceName = ""
        }
    }

#if os(iOS)
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
#endif
}

struct SourceRowWrapper: View {
    let source: Source
    let recipeCount: Int
    let isSelected: Bool
    let isExporting: Bool
    let isDeleting: Bool
    let onSelect: () -> Void
    let onShare: () -> Void
    let onExport: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject private var viewModel: AppViewModel

    private enum ShareUIState {
        case ownerPrivate
        case ownerShared
        case collaborator
    }

    private func shareUIState(isShared: Bool, isOwner: Bool) -> ShareUIState {
        if isOwner {
            return isShared ? .ownerShared : .ownerPrivate
        }
        return .collaborator
    }
    
    #if os(iOS)
    private func shareLabel(for state: ShareUIState) -> String {
        switch state {
        case .ownerPrivate:
            return "Share"
        case .ownerShared:
            return "Manage Sharing"
        case .collaborator:
            return "Manage Access"
        }
    }
    #endif

    private func shareSystemImage(for state: ShareUIState) -> String {
        switch state {
        case .ownerPrivate:
            return "square.and.arrow.up"
        case .ownerShared:
            return "person.crop.circle.badge.checkmark"
        case .collaborator:
            return "person.crop.circle.fill.badge.minus"
        }
    }

    var body: some View {
        let isShared = viewModel.isSourceShared(source)
        let isOwner = viewModel.isSharedOwner(source) || source.isPersonal
        let canRename = isOwner
        let canDelete = isOwner
        let canExport = isSelected && !isExporting
        let shareState = shareUIState(isShared: isShared, isOwner: isOwner)
        let shareSystemImageName = shareSystemImage(for: shareState)
#if os(iOS)
        let shareActionTitle = shareLabel(for: shareState)
        IOSSourceRow(
            source: source,
            recipeCount: recipeCount,
            isSelected: isSelected,
            isExporting: isExporting,
            isDeleting: isDeleting,
            isShared: isShared,
            isOwner: isOwner,
            canRename: canRename,
            canDelete: canDelete,
            canExport: canExport,
            shareActionTitle: shareActionTitle,
            onSelect: onSelect,
            onShare: onShare,
            onExport: onExport,
            onRename: onRename,
            onDelete: onDelete
        )
#endif
#if os(macOS)
        MacSourceRow(
            source: source,
            recipeCount: recipeCount,
            isSelected: isSelected,
            isExporting: isExporting,
            isDeleting: isDeleting,
            isShared: isShared,
            isOwner: isOwner,
            canRename: canRename,
            canDelete: canDelete,
            canExport: canExport,
            shareSystemImageName: shareSystemImageName,
            onSelect: onSelect,
            onShare: onShare,
            onExport: onExport,
            onRename: onRename,
            onDelete: onDelete
        )
#endif
    }
}

private struct SourceRowContent<ActionView: View>: View {
    let source: Source
    let recipeCount: Int
    let isSelected: Bool
    let isShared: Bool
    let isOwner: Bool
    let actionView: ActionView

    init(
        source: Source,
        recipeCount: Int,
        isSelected: Bool,
        isShared: Bool,
        isOwner: Bool,
        @ViewBuilder actionView: () -> ActionView
    ) {
        self.source = source
        self.recipeCount = recipeCount
        self.isSelected = isSelected
        self.isShared = isShared
        self.isOwner = isOwner
        self.actionView = actionView()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .fontWeight(isSelected ? .semibold : .regular)

                HStack(spacing: 6) {
                    if isShared {
                        if isOwner {
                            Label("Shared - Owner", systemImage: "person.2.fill")
                        } else {
                            Label("Shared - Collaborator", systemImage: "person.2.fill")
                        }
                    } else {
                        Label("Private", systemImage: "person.fill")
                    }

                    Text("•")
                    Text("\(recipeCount) \(recipeCount == 1 ? "recipe" : "recipes")")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(isSelected ? .blue : .clear)

            actionView
        }
    }
}

#if os(iOS)
private struct IOSSourceRow: View {
    let source: Source
    let recipeCount: Int
    let isSelected: Bool
    let isExporting: Bool
    let isDeleting: Bool
    let isShared: Bool
    let isOwner: Bool
    let canRename: Bool
    let canDelete: Bool
    let canExport: Bool
    let shareActionTitle: String
    let onSelect: () -> Void
    let onShare: () -> Void
    let onExport: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @EnvironmentObject private var viewModel: AppViewModel
    @State private var showActionMenu = false

    var body: some View {
        SourceRowContent(
            source: source,
            recipeCount: recipeCount,
            isSelected: isSelected,
            isShared: isShared,
            isOwner: isOwner
        ) {
            Button {
                showActionMenu = true
            } label: {
                Group {
                    if isDeleting || isExporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .disabled(isDeleting)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isDeleting else { return }
            onSelect()
        }
        .contextMenu {
            if canRename {
                Button(action: onRename) {
                    Label("Rename", systemImage: "pencil")
                }
                .disabled(viewModel.isOfflineMode)
            }
        }
        .disabled(isDeleting)
        .confirmationDialog("Collection Actions", isPresented: $showActionMenu, titleVisibility: .hidden) {
            Button(shareActionTitle) {
                onShare()
            }

            Button("Export Recipes") {
                onExport()
            }
            .disabled(!canExport)

            if canDelete {
                Button("Delete", role: .destructive) {
                    onDelete()
                }
                .disabled(viewModel.isOfflineMode)
            }

            Button("Cancel", role: .cancel) { }
        }
    }
}
#endif

#if os(macOS)
private struct MacSourceRow: View {
    let source: Source
    let recipeCount: Int
    let isSelected: Bool
    let isExporting: Bool
    let isDeleting: Bool
    let isShared: Bool
    let isOwner: Bool
    let canRename: Bool
    let canDelete: Bool
    let canExport: Bool
    let shareSystemImageName: String
    let onSelect: () -> Void
    let onShare: () -> Void
    let onExport: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        SourceRowContent(
            source: source,
            recipeCount: recipeCount,
            isSelected: isSelected,
            isShared: isShared,
            isOwner: isOwner
        ) {
            Menu {
                Button(action: onShare) {
                    Label(isShared ? "Manage Sharing" : "Share", systemImage: shareSystemImageName)
                }

                Button(action: onExport) {
                    Label("Export Recipes", systemImage: "square.and.arrow.down")
                }
                .disabled(!canExport)

                if canDelete {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(viewModel.isOfflineMode)
                }
            } label: {
                Group {
                    if isDeleting || isExporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isDeleting)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isDeleting else { return }
            onSelect()
        }
        .contextMenu {
            if canRename {
                Button(action: onRename) {
                    Label("Rename", systemImage: "pencil")
                }
                .disabled(viewModel.isOfflineMode)
            }
        }
        .disabled(isDeleting)
    }
}
#endif

#if os(iOS)
private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
#endif

struct EditSourceSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var viewModel: AppViewModel
    let source: Source
    @State private var sourceName: String
    @State private var isSaving = false
    
    init(isPresented: Binding<Bool>, source: Source) {
        self._isPresented = isPresented
        self.source = source
        _sourceName = State(initialValue: source.name)
    }

    private var trimmedSourceName: String {
        sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSaveDisabled: Bool {
        trimmedSourceName.isEmpty || isSaving || !viewModel.canRenameSource(source)
    }
    
    var body: some View {
#if os(macOS)
        macOSView
#else
        iOSView
#endif
    }

#if os(iOS)
    private var iOSView: some View {
        NavigationStack {
            Form {
                Section("Collection Name") {
                    TextField("e.g., Family Recipes", text: $sourceName)
                        .iOSModernInputFieldStyle()
                        .textInputAutocapitalization(.words)
                        .labelsHidden()
                }

                Section("About Collections") {
                    Label("Stored in iCloud and synced across your devices.", systemImage: "icloud")
                        .foregroundStyle(.secondary)
                    Label("Can be shared with family and friends.", systemImage: "person.2")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Edit Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await save()
                        }
                    }
                    .disabled(isSaveDisabled)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        dismissKeyboard()
                    }
                }
            }
        }
    }

    #else
    private var macOSView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Collection")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Rename your iCloud-synced recipe collection")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    Task {
                        await save()
                    }
                } label: {
                    if isSaving {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Saving...")
                        }
                    } else {
                        Text("Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaveDisabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Collection Information")
                            .font(.headline)

                        TextField("e.g., Family Recipes", text: $sourceName)
                            .iOSModernInputFieldStyle()
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("About Collections")
                            .font(.headline)

                        Label("Stored in iCloud and synced across your devices.", systemImage: "icloud")
                            .foregroundStyle(.secondary)
                        Label("Can be shared with family and friends.", systemImage: "person.2")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(16)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    #endif

    @MainActor
    private func save() async {
        guard !trimmedSourceName.isEmpty else { return }
        isSaving = true
        let success = await viewModel.renameSource(source, newName: trimmedSourceName)
        isSaving = false
        if success {
            isPresented = false
        }
    }
}
