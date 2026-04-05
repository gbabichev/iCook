import SwiftUI
import CloudKit

struct ExportPreviewSheet: View {
    @EnvironmentObject private var model: AppViewModel

    let source: Source
    let snapshot: SourceExportSnapshot
    @Binding var selectedRecipeIDs: Set<CKRecord.ID>
    @Binding var includeTags: Bool
    @Binding var includeFavorites: Bool
    @Binding var includeLinkedRecipes: Bool
    let isPreparingExport: Bool
    let onCancel: () -> Void
    let onExport: () -> Void

    var body: some View {
        Group {
#if os(iOS)
            iOSView
#else
            macOSView
#endif
        }
    }

#if os(iOS)
    private var iOSView: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Choose what to include in the export for \(source.name).")
                            .foregroundStyle(.secondary)
                        Text(selectionSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Options") {
                    Toggle("Include tags", isOn: $includeTags)
                        .disabled(isPreparingExport)
                    Toggle("Include favorites", isOn: $includeFavorites)
                        .disabled(isPreparingExport)
                    Toggle("Include linked recipes", isOn: $includeLinkedRecipes)
                        .disabled(isPreparingExport)
                }

                ForEach(groupedRecipes.keys.sorted(), id: \.self) { categoryName in
                    if let items = groupedRecipes[categoryName] {
                        Section {
                            ForEach(items, id: \.offset) { item in
                                Toggle(isOn: binding(for: item.element.id)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.element.name)
                                            .font(.body)
                                        Text("Time: \(item.element.recipeTime) min")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .disabled(isPreparingExport)
                            }
                        } header: {
                            HStack {
                                Text("\(categoryName) (\(items.count))")
                                Spacer()
                                Button("Select All") {
                                    selectAll(in: items.map(\.element.id))
                                }
                                .disabled(isPreparingExport)
                                Button("None") {
                                    deselectAll(in: items.map(\.element.id))
                                }
                                .disabled(isPreparingExport)
                            }
                        }
                    }
                }

                Section("Summary") {
                    LabeledContent("Categories", value: "\(summary.categoryCount)")
                    LabeledContent("Recipes", value: "\(summary.recipeCount)")
                    if includeTags {
                        LabeledContent("Tags", value: "\(summary.tagCount)")
                    }
                    if includeFavorites {
                        LabeledContent("Favorites", value: "\(summary.favoriteCount)")
                    }
                }
            }
            .navigationTitle("Export Recipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                        .disabled(isPreparingExport)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onExport) {
                        if isPreparingExport {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Export")
                        }
                    }
                    .disabled(isPreparingExport || summary.recipeCount == 0)
                    .fontWeight(.semibold)
                }
            }
            .overlay {
                if isPreparingExport {
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
        }
        .interactiveDismissDisabled(isPreparingExport)
    }
#endif

    private var macOSView: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export Recipes")
                    .font(.title2).bold()
                Text("Choose what to include in the export for \(source.name).")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Select All", action: selectAll)
                    .disabled(isPreparingExport || sortedRecipes.isEmpty)
                Button("Deselect All", action: deselectAll)
                    .disabled(isPreparingExport || sortedRecipes.isEmpty)
                Spacer()
                Text(selectionSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            List {
                Section("Options") {
                    Toggle("Include tags", isOn: $includeTags)
                        .disabled(isPreparingExport)
                    Toggle("Include favorites", isOn: $includeFavorites)
                        .disabled(isPreparingExport)
                    Toggle("Include linked recipes", isOn: $includeLinkedRecipes)
                        .disabled(isPreparingExport)
                }

                ForEach(groupedRecipes.keys.sorted(), id: \.self) { categoryName in
                    if let items = groupedRecipes[categoryName] {
                        Section(header: Text("\(categoryName) (\(items.count))")) {
                            ForEach(items, id: \.offset) { item in
                                Toggle(isOn: binding(for: item.element.id)) {
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
                                .disabled(isPreparingExport)
                            }
                        }
                    }
                }

                Section("Summary") {
                    LabeledContent("Categories", value: "\(summary.categoryCount)")
                    LabeledContent("Recipes", value: "\(summary.recipeCount)")
                    if includeTags {
                        LabeledContent("Tags", value: "\(summary.tagCount)")
                    }
                    if includeFavorites {
                        LabeledContent("Favorites", value: "\(summary.favoriteCount)")
                    }
                }
            }
            .frame(minHeight: 320)

            HStack {
                Button("Cancel", action: onCancel)
                    .disabled(isPreparingExport)
                Spacer()
                Button(action: onExport) {
                    if isPreparingExport {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Export Selected")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPreparingExport || summary.recipeCount == 0)
            }
        }
        .padding(20)
        .overlay {
            if isPreparingExport {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .interactiveDismissDisabled(isPreparingExport)
        .frame(minWidth: 560, minHeight: 520)
    }

    private var sortedRecipes: [Recipe] {
        snapshot.recipes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var groupedRecipes: [String: [(offset: Int, element: Recipe)]] {
        let categoryNameByID = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0.name) })
        return Dictionary(
            grouping: Array(sortedRecipes.enumerated()),
            by: { categoryNameByID[$0.element.categoryID] ?? "Uncategorized" }
        )
    }

    private var options: AppViewModel.ExportOptions {
        AppViewModel.ExportOptions(
            selectedRecipeIDs: selectedRecipeIDs,
            includeTags: includeTags,
            includeFavorites: includeFavorites,
            includeLinkedRecipes: includeLinkedRecipes
        )
    }

    private var summary: AppViewModel.ExportSelectionSummary {
        model.exportSelectionSummary(for: snapshot, options: options)
    }

    private var selectionSummary: String {
        "\(selectedRecipeIDs.count) of \(snapshot.recipes.count) recipes selected"
    }

    private func binding(for recipeID: CKRecord.ID) -> Binding<Bool> {
        Binding(
            get: { selectedRecipeIDs.contains(recipeID) },
            set: { isSelected in
                if isSelected {
                    selectedRecipeIDs.insert(recipeID)
                } else {
                    selectedRecipeIDs.remove(recipeID)
                }
            }
        )
    }

    private func selectAll() {
        selectedRecipeIDs = Set(snapshot.recipes.map(\.id))
    }

    private func deselectAll() {
        selectedRecipeIDs.removeAll()
    }

    private func selectAll(in recipeIDs: [CKRecord.ID]) {
        selectedRecipeIDs.formUnion(recipeIDs)
    }

    private func deselectAll(in recipeIDs: [CKRecord.ID]) {
        selectedRecipeIDs.subtract(recipeIDs)
    }
}
