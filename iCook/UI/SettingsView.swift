import SwiftUI
import CloudKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SourceSelector: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) var dismiss
    @AppStorage("EnableFeelingLucky") var enableFeelingLucky = true

    @State var showNewSourceSheet = false
    @State var newSourceName = ""
    @State var isPreparingShare = false
    @State var showShareSuccess = false
    @State var shareSuccessMessage = ""
    @State var editingSource: Source?
    @State var sourceToDelete: Source?
    @State var showDeleteConfirmation = false
    @State var recipeTotalsBySource: [CKRecord.ID: Int] = [:]
#if os(macOS)
    @State var showShareCopiedToast = false
    @State var shareToastMessage = ""
    @State var activeMacSharePicker: NSSharingServicePicker?
    @State var activeMacSharingService: NSSharingService?
    @State var macSharingDelegateProxy: AnyObject?
    @State var hoveredSourceID: CKRecord.ID?
    @State var isRefreshingCollections = false
#endif
#if os(iOS)
    @State var sharingDelegateProxy: AnyObject?
#endif

    var appVersionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return version == build ? version : "\(version) (\(build))"
    }

    var totalRecipeCountAllCollections: Int {
        recipeTotalsBySource.values.reduce(0, +)
    }

    var sourceTotalsRefreshKey: String {
        viewModel.sources
            .map { "\($0.id.zoneID.ownerName)|\($0.id.zoneID.zoneName)|\($0.id.recordName)" }
            .sorted()
            .joined(separator: ",")
    }

    var body: some View {
        Group {
#if os(iOS)
            iOSView
#elseif os(macOS)
            macOSView
#endif
        }
        .task(id: sourceTotalsRefreshKey) {
            await refreshRecipeTotals()
        }
    }

    @ViewBuilder
    func sourceRow(for source: Source) -> some View {
#if os(macOS)
        SourceRowWrapper(
            source: source,
            recipeCount: recipeTotalsBySource[source.id, default: 0],
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
            onStopSharing: {
                Task {
                    await viewModel.stopSharingSource(source)
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
            onRename: {
                beginRenaming(source)
            },
            onDelete: {
                sourceToDelete = source
                showDeleteConfirmation = true
            },
            onSwipeDelete: {
                Task {
                    await deleteSource(source)
                }
            }
        )
#endif
    }

    #if os(iOS)
    var sourcesListView: some View {
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
                Section("Collections") {
                    Text("Organize recipes into collections by theme or occasion, and share collections with others.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if viewModel.sources.isEmpty {
                        Text("No Collections yet")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.sources, id: \.id) { source in
                            sourceRow(for: source)
                        }
                    }
                }

                Section("Settings") {
                    Toggle(isOn: $enableFeelingLucky) {
                        Label("Feeling Lucky", systemImage: "die.face.5")
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }


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
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.automatic)
#if os(iOS)
            .refreshable {
                await viewModel.loadSources()
                await viewModel.loadRandomRecipes(skipCache: true)
            }
#endif
        }
        .onAppear {
            viewModel.clearErrors()
        }
        .sheet(item: $editingSource) { source in
            RenameSourceSheet(
                isPresented: Binding(
                    get: { editingSource != nil },
                    set: { if !$0 { editingSource = nil } }
                ),
                source: source
            )
            .environmentObject(viewModel)
        }
    }
    #endif

    func beginRenaming(_ source: Source) {
        guard viewModel.canRenameSource(source) else { return }
        editingSource = source
    }

    func refreshRecipeTotals() async {
        let sources = viewModel.sources
        guard !sources.isEmpty else {
            recipeTotalsBySource = [:]
            return
        }

        var totals: [CKRecord.ID: Int] = [:]
        for source in sources {
            let total = await viewModel.cloudKitManager.totalRecipeCount(for: source)
            totals[source.id] = total
        }
        recipeTotalsBySource = totals
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
        await viewModel.loadSources()
        await viewModel.loadRandomRecipes(skipCache: true)
        await refreshRecipeTotals()
    }
#endif

    func deleteSource(_ source: Source) async {
        printD("Deleting source: \(source.name)")

        let categoriesToDelete = viewModel.categories.filter { $0.sourceID == source.id }
        for category in categoriesToDelete {
            await viewModel.deleteCategory(id: category.id)
            printD("Deleted category: \(category.name)")
        }

        let recipesToDelete = viewModel.recipes.filter { $0.sourceID == source.id }
        for recipe in recipesToDelete {
            _ = await viewModel.deleteRecipe(id: recipe.id)
            printD("Deleted recipe: \(recipe.name)")
        }

        _ = await viewModel.deleteSource(source)
        printD("Deleted source: \(source.name)")

        sourceToDelete = nil
        await viewModel.loadSources()
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
    let onSelect: () -> Void
    let onShare: () -> Void
#if os(macOS)
    let onStopSharing: (() -> Void)?
#endif
    let onRename: () -> Void
    let onDelete: () -> Void
#if os(iOS)
    let onSwipeDelete: (() -> Void)?
#endif
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
        let shareState = shareUIState(isShared: isShared, isOwner: isOwner)
        let shareLabel = shareLabel(for: shareState)
        let shareSystemImage = shareSystemImage(for: shareState)

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
            Button(action: onShare) {
                Image(systemName: shareSystemImage)
                    .font(.system(size: 14))
            }
            .buttonStyle(.bordered)
            
#if os(macOS)
            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isOfflineMode)
            }
#endif
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(action: onSelect) {
                Label("Open", systemImage: "checkmark.circle")
            }
            
            if canRename {
                Button(action: onRename) {
                    Label("Rename", systemImage: "pencil")
                }
            }
            
#if os(macOS)
            if isOwner, isShared {
                Button(action: onShare) {
                    Label("Share With…", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive, action: onStopSharing ?? {}) {
                    Label("Stop Sharing", systemImage: "xmark.circle")
                }
            } else if isOwner {
                Button(action: onShare) {
                    Label("Start Sharing", systemImage: "square.and.arrow.up")
                }
            } else {
                Button(action: onShare) {
                    Label("Leave Share", systemImage: "person.crop.circle.badge.xmark")
                }
            }
#else
            Button(action: onShare) {
                Label(shareLabel, systemImage: shareSystemImage)
            }
#endif
            
            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(viewModel.isOfflineMode)
            }
        }
#if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if source.isPersonal {
                Button(role: .destructive, action: onSwipeDelete ?? onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(viewModel.isOfflineMode)
            } else {
                Button(action: onShare) {
                    Label(shareLabel, systemImage: shareSystemImage)
                }
                .tint(.blue)
            }
        }
#endif
    }
}

#if os(iOS)
struct RenameSourceSheet: View {
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
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Collection Name") {
                    TextField("Collection Name", text: $sourceName)
                        .iOSModernInputFieldStyle()
#if os(iOS)
                        .textInputAutocapitalization(.words)
#endif
                        .labelsHidden()
                }
            }
            .formStyle(.grouped)
#if os(iOS)
            .scrollDismissesKeyboard(.immediately)
#endif
            .navigationTitle("Rename Collection")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
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
                    .disabled(sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
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
    
    @MainActor
    private func save() async {
        let trimmed = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        let success = await viewModel.renameSource(source, newName: trimmed)
        isSaving = false
        if success {
            isPresented = false
        }
    }

#if os(iOS)
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
#endif
}
#endif
