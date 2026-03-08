import SwiftUI

struct ImportPreviewSheet: View {
    let preview: AppViewModel.ImportPreview
    @Binding var selectedIndices: Set<Int>
    let isImporting: Bool
    let importProgress: AppViewModel.ImportProgress?
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
                Button("Cancel", action: onCancel)
                    .disabled(isImporting)
                Spacer()
                if isImporting, let importProgress {
                    ImportProgressStatusView(progress: importProgress)
                        .frame(maxWidth: 320, alignment: .trailing)
                } else {
                    Button(action: onImport) {
                        Text("Import Selected")
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedIndices.isEmpty || isImporting)
                }
            }
        }
        .padding(20)
        .overlay {
            if isImporting {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
            }
        }
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
