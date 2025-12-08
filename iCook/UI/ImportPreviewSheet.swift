import SwiftUI

struct ImportPreviewSheet: View {
    let preview: AppViewModel.ImportPreview
    @Binding var selectedIndices: Set<Int>
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    let onCancel: () -> Void
    let onImport: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Recipes")
                    .font(.title2).bold()
                Text("Choose which recipes to import from \(preview.url.lastPathComponent).")
                    .foregroundStyle(.secondary)
            }
            
            HStack {
                Button("Select All", action: onSelectAll)
                Button("Deselect All", action: onDeselectAll)
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
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Import Selected", action: onImport)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedIndices.isEmpty)
            }
        }
        .padding(20)
#if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
#endif
    }
    
    private var groupedByCategory: [String: [(offset: Int, element: ExportedRecipe)]] {
        Dictionary(grouping: Array(preview.package.recipes.enumerated()), by: { $0.element.categoryName })
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
