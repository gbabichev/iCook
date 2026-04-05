import SwiftUI
import CloudKit

struct ExportPreviewSheet: View {
    @EnvironmentObject private var model: AppViewModel

    let source: Source
    let snapshot: SourceExportSnapshot
    @Binding var selectedCategoryIDs: Set<CKRecord.ID>
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

                Section {
                    ForEach(sortedCategories, id: \.id) { category in
                        Toggle(isOn: binding(for: category.id)) {
                            HStack(spacing: 10) {
                                Text(category.icon)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.name)
                                    Text("\(recipeCount(for: category)) recipe\(recipeCount(for: category) == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(isPreparingExport)
                    }
                } header: {
                    HStack {
                        Text("Categories")
                        Spacer()
                        Button("Select All", action: selectAll)
                            .disabled(isPreparingExport || sortedCategories.isEmpty)
                        Button("Deselect All", action: deselectAll)
                            .disabled(isPreparingExport || sortedCategories.isEmpty)
                    }
                }

                Section("Options") {
                    Toggle("Include tags", isOn: $includeTags)
                        .disabled(isPreparingExport)
                    Toggle("Include favorites", isOn: $includeFavorites)
                        .disabled(isPreparingExport)
                    Toggle("Include linked recipes", isOn: $includeLinkedRecipes)
                        .disabled(isPreparingExport)
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
                    .disabled(isPreparingExport || sortedCategories.isEmpty)
                Button("Deselect All", action: deselectAll)
                    .disabled(isPreparingExport || sortedCategories.isEmpty)
                Spacer()
                Text(selectionSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            List {
                Section("Categories") {
                    ForEach(sortedCategories, id: \.id) { category in
                        Toggle(isOn: binding(for: category.id)) {
                            HStack(spacing: 10) {
                                Text(category.icon)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.name)
                                    Text("\(recipeCount(for: category)) recipe\(recipeCount(for: category) == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
#if os(macOS)
                        .toggleStyle(.checkbox)
#endif
                        .disabled(isPreparingExport)
                    }
                }

                Section("Options") {
                    Toggle("Include tags", isOn: $includeTags)
                        .disabled(isPreparingExport)
                    Toggle("Include favorites", isOn: $includeFavorites)
                        .disabled(isPreparingExport)
                    Toggle("Include linked recipes", isOn: $includeLinkedRecipes)
                        .disabled(isPreparingExport)
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

    private var sortedCategories: [Category] {
        snapshot.categories.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var options: AppViewModel.ExportOptions {
        AppViewModel.ExportOptions(
            selectedCategoryIDs: selectedCategoryIDs,
            includeTags: includeTags,
            includeFavorites: includeFavorites,
            includeLinkedRecipes: includeLinkedRecipes
        )
    }

    private var summary: AppViewModel.ExportSelectionSummary {
        model.exportSelectionSummary(for: snapshot, options: options)
    }

    private var selectionSummary: String {
        "\(selectedCategoryIDs.count) of \(snapshot.categories.count) categories selected"
    }

    private func recipeCount(for category: Category) -> Int {
        snapshot.recipes.filter { $0.categoryID == category.id }.count
    }

    private func binding(for categoryID: CKRecord.ID) -> Binding<Bool> {
        Binding(
            get: { selectedCategoryIDs.contains(categoryID) },
            set: { isSelected in
                if isSelected {
                    selectedCategoryIDs.insert(categoryID)
                } else {
                    selectedCategoryIDs.remove(categoryID)
                }
            }
        )
    }

    private func selectAll() {
        selectedCategoryIDs = Set(snapshot.categories.map(\.id))
    }

    private func deselectAll() {
        selectedCategoryIDs.removeAll()
    }
}
