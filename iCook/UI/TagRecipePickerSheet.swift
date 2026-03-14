import SwiftUI
import CloudKit

struct TagRecipePickerSheet: View {
    let tagName: String
    let candidates: [Recipe]
    let categoryName: (Recipe) -> String?
    let onSave: @MainActor ([CKRecord.ID]) async -> String?

#if os(macOS)
    private let initialSelection: Set<CKRecord.ID>
#endif

    @Environment(\.dismiss) private var dismiss

    @State private var draftSelection: Set<CKRecord.ID>
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    init(
        tagName: String,
        candidates: [Recipe],
        selectedIDs: Set<CKRecord.ID>,
        categoryName: @escaping (Recipe) -> String?,
        onSave: @escaping @MainActor ([CKRecord.ID]) async -> String?
    ) {
        self.tagName = tagName
        self.candidates = candidates
        self.categoryName = categoryName
        self.onSave = onSave
#if os(macOS)
        self.initialSelection = selectedIDs
#endif
        _draftSelection = State(initialValue: selectedIDs)
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

    private var filteredCandidates: [Recipe] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingCandidates: [Recipe]

        if trimmed.isEmpty {
            matchingCandidates = candidates
        } else {
            matchingCandidates = candidates.filter { recipe in
                recipe.name.localizedCaseInsensitiveContains(trimmed) ||
                (categoryName(recipe)?.localizedCaseInsensitiveContains(trimmed) ?? false)
            }
        }

        return matchingCandidates.sorted { lhs, rhs in
            let lhsSelected = draftSelection.contains(lhs.id)
            let rhsSelected = draftSelection.contains(rhs.id)
            if lhsSelected != rhsSelected {
                return lhsSelected && !rhsSelected
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

#if os(macOS)
    private var macOSView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "tag")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Tagged Recipes")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Choose which recipes belong to \(tagName).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await save() }
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
                .disabled(isSaving)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Find Recipes")
                            .font(.headline)

                        TextField("Search by recipe or category", text: $searchText)
                            .iOSModernInputFieldStyle()

                        HStack(spacing: 10) {
                            selectionPill(
                                title: draftSelection.count == 1 ? "1 selected" : "\(draftSelection.count) selected",
                                systemImage: "checkmark.circle.fill",
                                tint: .accentColor
                            )
                            selectionPill(
                                title: filteredCandidates.count == 1 ? "1 result" : "\(filteredCandidates.count) results",
                                systemImage: "magnifyingglass",
                                tint: .secondary,
                                useSecondaryForeground: true
                            )
                            if draftSelection != initialSelection {
                                selectionPill(
                                    title: "Unsaved changes",
                                    systemImage: "circle.badge.fill",
                                    tint: .orange
                                )
                            }
                        }
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if candidates.isEmpty {
                        macOSEmptyStateCard(
                            title: "No Recipes Yet",
                            subtitle: "Create a recipe before assigning one to \(tagName).",
                            systemImage: "fork.knife.circle"
                        )
                    } else if filteredCandidates.isEmpty {
                        macOSEmptyStateCard(
                            title: "No Matches",
                            subtitle: "Try a different search term.",
                            systemImage: "magnifyingglass"
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Available Recipes")
                                .font(.headline)

                            ForEach(filteredCandidates) { recipe in
                                Button {
                                    toggle(recipe.id)
                                } label: {
                                    macOSRecipeCard(for: recipe)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if let errorMessage {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Couldn’t save tagged recipes", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundStyle(.orange)
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(16)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 560, minHeight: 420)
    }
#endif

#if os(iOS)
    private var iOSView: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tagName)
                            .font(.headline)
                        Text("Choose which recipes belong to this tag.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                if candidates.isEmpty {
                    ContentUnavailableView(
                        "No Recipes Yet",
                        systemImage: "fork.knife.circle",
                        description: Text("Create a recipe before assigning one to \(tagName).")
                    )
                } else if filteredCandidates.isEmpty {
                    ContentUnavailableView(
                        "No Matches",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different search term.")
                    )
                } else {
                    ForEach(filteredCandidates) { recipe in
                        Button {
                            toggle(recipe.id)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(recipe.name)
                                        .foregroundStyle(.primary)
                                    HStack(spacing: 8) {
                                        if let categoryName = categoryName(recipe) {
                                            Text(categoryName)
                                        }
                                        Text("\(recipe.recipeTime) min")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: draftSelection.contains(recipe.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(draftSelection.contains(recipe.id) ? Color.accentColor : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Tag")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search recipes")
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
#endif

    private func toggle(_ recipeID: CKRecord.ID) {
        if draftSelection.contains(recipeID) {
            draftSelection.remove(recipeID)
        } else {
            draftSelection.insert(recipeID)
        }
    }

#if os(macOS)
    private func selectionPill(
        title: String,
        systemImage: String,
        tint: Color,
        useSecondaryForeground: Bool = false
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(useSecondaryForeground ? .secondary : tint)
    }

    @ViewBuilder
    private func macOSEmptyStateCard(title: String, subtitle: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func macOSRecipeCard(for recipe: Recipe) -> some View {
        let isSelected = draftSelection.contains(recipe.id)

        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill((isSelected ? Color.accentColor : Color.secondary).opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "fork.knife")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(recipe.name)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    if isSelected {
                        Text("Tagged")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }

                HStack(spacing: 8) {
                    if let categoryName = categoryName(recipe) {
                        Text(categoryName)
                    }
                    Text("\(recipe.recipeTime) min")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: isSelected ? "minus.circle" : "plus.circle")
                .font(.title3)
                .foregroundStyle(isSelected ? .secondary : Color.accentColor)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }
#endif

    @MainActor
    private func save() async {
        isSaving = true
        errorMessage = nil
        let orderedIDs = candidates
            .filter { draftSelection.contains($0.id) }
            .map(\.id)

        if let error = await onSave(orderedIDs) {
            errorMessage = error
            isSaving = false
            return
        }

        isSaving = false
        dismiss()
    }
}
