import SwiftUI
import CloudKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ImportPreviewSheet: View {
    @EnvironmentObject private var model: AppViewModel

    let preview: AppViewModel.ImportPreview
    @Binding var selectedIndices: Set<Int>
    @Binding var destinationSourceID: CKRecord.ID?
    let isImporting: Bool
    let importProgress: AppViewModel.ImportProgress?
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    let onCancel: () -> Void
    let onImport: () -> Void
    let onCancelImport: () -> Void

    @State private var showNewCollectionSheet = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Recipes")
                    .font(.title2).bold()
                Text("Choose which recipes to import from \(preview.url.lastPathComponent).")
                    .foregroundStyle(.secondary)
            }

            destinationCollectionSection
            
            HStack {
                Button("Select All", action: onSelectAll)
                    .disabled(isImporting)
                Button("Deselect All", action: onDeselectAll)
                    .disabled(isImporting)
                Spacer()
                Text(selectionSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            List {
                ForEach(groupedByCategory.keys.sorted(), id: \.self) { category in
                    if let items = groupedByCategory[category] {
                        Section(header: Text("\(category) (\(items.count))")) {
                            ForEach(items, id: \.offset) { item in
                                Toggle(isOn: binding(for: item.offset)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.element.name)
                                            .font(.body)
                                        Text("Time: \(item.element.recipeTime) min")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
#if os(macOS)
                                .toggleStyle(.checkbox)
#endif
                                .disabled(isImporting)
                            }
                        }
                    }
                }
            }
#if os(iOS)
            .listStyle(.insetGrouped)
#endif
#if os(macOS)
            .frame(minHeight: 320)
#endif
            
            HStack {
                if isImporting, let importProgress {
                    Button("Cancel Import", action: onCancelImport)
                    Spacer()
                    ImportProgressStatusView(progress: importProgress)
                        .frame(maxWidth: 320, alignment: .trailing)
                } else {
                    Button("Cancel", action: onCancel)
                    Spacer()
                    Button(action: onImport) {
                        Text("Import Selected")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedIndices.isEmpty || isImporting || !hasDestinationCollection)
                }
            }
        }
        .padding(20)
        .overlay {
            if isImporting {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showNewCollectionSheet) {
            ImportCollectionQuickAddSheet { sourceID in
                destinationSourceID = sourceID
            }
            .environmentObject(model)
        }
        .interactiveDismissDisabled(isImporting)
#if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
#endif
    }

    @ViewBuilder
    private var destinationCollectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Destination Collection")
                .font(.headline)

            HStack(spacing: 12) {
                Menu {
                    if !sortedSources.isEmpty {
                        ForEach(sortedSources, id: \.id) { source in
                            Button(source.name) {
                                destinationSourceID = source.id
                            }
                        }

                        Divider()
                    }
                    Button("New Collection…") {
                        showNewCollectionSheet = true
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedCollectionTitle)
                                .foregroundStyle(.primary)
                            Text(selectedCollectionSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isImporting)
            }
        }
    }
    
    private var groupedByCategory: [String: [(offset: Int, element: ExportedRecipe)]] {
        Dictionary(grouping: Array(preview.package.recipes.enumerated()), by: { $0.element.categoryName })
    }

    private var sortedSources: [Source] {
        model.sources.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedCollectionTitle: String {
        guard let destinationSourceID,
              let source = model.sources.first(where: { $0.id == destinationSourceID }) else {
            return model.currentSource?.name ?? "Choose a Collection"
        }
        return source.name
    }

    private var selectedCollectionSubtitle: String {
        hasDestinationCollection
            ? "Recipes will import into this collection."
            : "Choose or create a collection before importing."
    }

    private var hasDestinationCollection: Bool {
        destinationSourceID != nil || model.currentSource != nil
    }
    
    private var selectionSummary: String {
        let total = preview.package.recipes.count
        let selected = selectedIndices.count
        return "\(selected) of \(total) selected"
    }

    private func binding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { selectedIndices.contains(index) },
            set: { isSelected in
                if isSelected {
                    selectedIndices.insert(index)
                } else {
                    selectedIndices.remove(index)
                }
            }
        )
    }
}

private struct ImportCollectionQuickAddSheet: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss

    let onCreate: (CKRecord.ID) -> Void

    @State private var collectionName = ""
    @State private var isSaving = false

    private var trimmedCollectionName: String {
        collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasDuplicateName: Bool {
        model.sources.contains {
            $0.name.compare(trimmedCollectionName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private var canSave: Bool {
        !trimmedCollectionName.isEmpty && !hasDuplicateName && !isSaving
    }

    var body: some View {
        Group {
#if os(macOS)
            macOSView
#else
            iOSView
#endif
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { model.error != nil },
                set: { if !$0 { model.error = nil } }
            ),
            actions: {
                Button("OK") {
                    model.error = nil
                }
            },
            message: {
                Text(model.error ?? "")
            }
        )
    }

    #if os(iOS)
    private var iOSView: some View {
        NavigationStack {
            Form {
                Section("Collection Name") {
                    TextField("e.g., Family Recipes", text: $collectionName)
                        .iOSModernInputFieldStyle()
                        .textInputAutocapitalization(.words)
                        .labelsHidden()
                }

                Section {
                    Text("Collections are stored in iCloud, synced across your devices, and can be shared with others.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if hasDuplicateName {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("A collection with this name already exists.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await createCollection()
                        }
                    }
                    .disabled(!canSave)
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
    #endif

    #if os(macOS)
    private var macOSView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("New Collection")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Create a collection and import into it immediately")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    Task {
                        await createCollection()
                    }
                } label: {
                    if isSaving {
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
                .disabled(!canSave)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Collection Information")
                            .font(.headline)

                        TextField("e.g., Family Recipes", text: $collectionName)
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
                        Label("Imported recipes keep their exported categories.", systemImage: "tray.full")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if hasDuplicateName {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("A collection with this name already exists.")
                                .font(.callout)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    #endif

    @MainActor
    private func createCollection() async {
        isSaving = true
        let success = await model.createSource(name: trimmedCollectionName)
        if success,
           let createdSource = model.sources.first(where: {
               $0.name.compare(trimmedCollectionName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
           }) {
            onCreate(createdSource.id)
            dismiss()
            return
        }
        isSaving = false
    }

#if os(iOS)
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
#endif
}

struct ImportProgressStatusView: View {
    let progress: AppViewModel.ImportProgress

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(context.date.timeIntervalSince(progress.startedAt), 0)
            let remaining = estimatedRemaining(elapsed: elapsed)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(progress.phase)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int(progress.fractionCompleted * 100))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: progress.fractionCompleted)

                HStack {
                    Text("\(progress.importedRecipes) of \(progress.totalRecipes) recipes")
                    Spacer()
                    Text("Elapsed \(formattedDuration(elapsed))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let remaining {
                    Text("ETA \(formattedDuration(remaining))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let currentItemName = progress.currentItemName, !currentItemName.isEmpty {
                    Text(currentItemName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        Self.durationFormatter.string(from: duration) ?? "0:00"
    }

    private func estimatedRemaining(elapsed: TimeInterval) -> TimeInterval? {
        guard progress.completedUnits > 0, progress.completedUnits < progress.totalUnits else { return nil }
        let averagePerUnit = elapsed / Double(progress.completedUnits)
        return averagePerUnit * Double(progress.totalUnits - progress.completedUnits)
    }
}
