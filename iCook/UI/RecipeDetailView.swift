import SwiftUI
import CloudKit

struct RecipeDetailView: View {
    let recipe: Recipe
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var editingRecipe: Recipe?
    @State private var checkedIngredients: Set<String> = []
    @State private var checkedSteps: Set<Int> = []
    @State private var checkedStepIngredients: Set<String> = [] // Format: "stepNumber-ingredientIndex"
    @State private var showCopiedHUD = false
    @State private var displayedRecipe: Recipe
    @State private var isUpdatingTags = false
    @State private var tagUpdateErrorMessage: String?
    @State private var isShowingLinkedRecipePicker = false
    @State private var isUpdatingLinkedRecipes = false
    @State private var linkedRecipeUpdateErrorMessage: String?
    
    init(recipe: Recipe) {
        self.recipe = recipe
        _displayedRecipe = State(initialValue: recipe)
    }
    
    private func refreshDisplayedRecipe() {
        if let updated = model.recipes.first(where: { $0.id == recipe.id }) {
            displayedRecipe = updated
        } else if let updated = model.randomRecipes.first(where: { $0.id == recipe.id }) {
            displayedRecipe = updated
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AsyncImage(url: displayedRecipe.imageURL) { phase in
                    switch phase {
                    case .empty:
                        Image(systemName: "fork.knife.circle")
                            .font(.system(size: 80))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .frame(height: 200)
                    case .success(let image):
                        GeometryReader { geometry in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geometry.size.width, height: 350)
                                .clipped()
                        }
                        .frame(height: 350)
                        .backgroundExtensionEffect()
                    case .failure:
                        ZStack {
                            Rectangle().opacity(0.08)
                            Image(systemName: "photo")
                        }
                        .frame(height: 350)
                        .backgroundExtensionEffect()
                    @unknown default:
                        EmptyView()
                    }
                }
                
                VStack(alignment: .leading, spacing: 20) {
                    // Recipe Title and Time
                    VStack(alignment: .leading, spacing: 8) {
                        Text(displayedRecipe.name)
                            .font(.largeTitle)
                            .bold()
                        
                        HStack {
                            Image(systemName: "clock")
                                .foregroundStyle(.secondary)
                            Text("\(displayedRecipe.recipeTime) minutes")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }

                        recipeTagManagerContent
                    }

                    detailsSection
                    
                    // Recipe Steps Section (NEW)
                    if !displayedRecipe.recipeSteps.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "list.number")
                                    .foregroundStyle(.secondary)
                                Text("Steps")
                                    .font(.title2)
                                    .bold()
                            }
                            
                            LazyVStack(alignment: .leading, spacing: 16) {
                                ForEach(displayedRecipe.recipeSteps, id: \.stepNumber) { step in
                                    VStack(alignment: .leading, spacing: 12) {
                                        // Step header with checkbox
                                        HStack(alignment: .top, spacing: 12) {
                                            Button {
                                                if checkedSteps.contains(step.stepNumber) {
                                                    checkedSteps.remove(step.stepNumber)
                                                } else {
                                                    checkedSteps.insert(step.stepNumber)
                                                }
                                            } label: {
                                                Image(systemName: checkedSteps.contains(step.stepNumber) ? "checkmark.circle.fill" : "circle")
                                                    .foregroundStyle(checkedSteps.contains(step.stepNumber) ? .green : .secondary)
                                                    .font(.title3)
                                            }
                                            .buttonStyle(.plain)
                                            
                                            VStack(alignment: .leading, spacing: 8) {
                                                Text(step.instruction)
                                                    .font(.body)
                                                    .textSelection(.enabled)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                    .strikethrough(checkedSteps.contains(step.stepNumber))
                                                    .foregroundStyle(checkedSteps.contains(step.stepNumber) ? .secondary : .primary)
                                            }
                                            
                                            Spacer()
                                        }
                                        
                                        // Step ingredients with sub-checkboxes
                                        if !step.ingredients.isEmpty {
                                            VStack(alignment: .leading, spacing: 8) {
                                                ForEach(Array(step.ingredients.enumerated()), id: \.offset) { ingredientIndex, ingredient in
                                                    let checkboxKey = "\(step.stepNumber)-\(ingredientIndex)"
                                                    
                                                    HStack(alignment: .top, spacing: 12) {
                                                        Spacer()
                                                            .frame(width: 32) // Space for step checkbox alignment
                                                        
                                                        Button {
                                                            if checkedStepIngredients.contains(checkboxKey) {
                                                                checkedStepIngredients.remove(checkboxKey)
                                                            } else {
                                                                checkedStepIngredients.insert(checkboxKey)
                                                            }
                                                        } label: {
                                                            Image(systemName: checkedStepIngredients.contains(checkboxKey) ? "checkmark.square.fill" : "square")
                                                                .foregroundStyle(checkedStepIngredients.contains(checkboxKey) ? .blue : .secondary)
                                                                .font(.body)
                                                        }
                                                        .buttonStyle(.plain)
                                                        
                                                        Text("• \(ingredient)")
                                                            .font(.body)
                                                            .textSelection(.enabled)
                                                            .fixedSize(horizontal: false, vertical: true)
                                                            .strikethrough(checkedStepIngredients.contains(checkboxKey))
                                                            .foregroundStyle(checkedStepIngredients.contains(checkboxKey) ? .secondary : .primary)
                                                        
                                                        Spacer()
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .padding(.vertical, 8)
                                    
                                    if step.stepNumber < displayedRecipe.recipeSteps.count {
                                        Divider()
                                            .padding(.horizontal)
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    
                    // Ingredients Section (UNCHANGED - keeping existing functionality)
                    if let ingredients = displayedRecipe.ingredients, !ingredients.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "list.bullet")
                                    .foregroundStyle(.secondary)
                                Text("Ingredients")
                                    .font(.title2)
                                    .bold()
                                
                                Button {
                                    copyToReminders(ingredients)
                                    // Add the HUD animation
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        showCopiedHUD = true
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            showCopiedHUD = false
                                        }
                                    }
                                } label: {
                                    Image(systemName: "doc.on.clipboard")
                                }
                                .buttonStyle(.plain)
                                
                            }
                            
                            LazyVGrid(columns: [
                                GridItem(.flexible(), alignment: .leading)
                            ], alignment: .leading, spacing: 8) {
                                ForEach(ingredients, id: \.self) { ingredient in
                                    HStack(alignment: .top, spacing: 12) {
                                        Button {
                                            if checkedIngredients.contains(ingredient) {
                                                checkedIngredients.remove(ingredient)
                                            } else {
                                                checkedIngredients.insert(ingredient)
                                            }
                                        } label: {
                                            Image(systemName: checkedIngredients.contains(ingredient) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(checkedIngredients.contains(ingredient) ? .green : .secondary)
                                                .font(.title3)
                                        }
                                        .buttonStyle(.plain)
                                        
                                        Text(ingredient)
                                            .textSelection(.enabled)
                                            .font(.body)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .strikethrough(checkedIngredients.contains(ingredient))
                                            .foregroundStyle(checkedIngredients.contains(ingredient) ? .secondary : .primary)
                                        
                                        Spacer()
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }

                    linkedRecipesSection
                }
                .padding(.horizontal)
                
                Spacer()
            }
        }
        .navigationTitle(displayedRecipe.name)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .ignoresSafeArea(edges: .top)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editingRecipe = displayedRecipe
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Edit Recipe")
                .disabled(model.isOfflineMode)
            }
        }
        .sheet(item: $editingRecipe) { recipe in
            AddEditRecipeView(editingRecipe: recipe)
                .environmentObject(model)
        }
        .sheet(isPresented: $isShowingLinkedRecipePicker) {
            LinkedRecipePickerSheet(
                recipeName: displayedRecipe.name,
                candidates: availableLinkedRecipeCandidates,
                selectedIDs: Set(displayedRecipe.linkedRecipeIDs),
                categoryName: categoryName(for:),
                onSave: { ids in
                    await updateLinkedRecipes(ids)
                }
            )
        }
        .onChange(of: editingRecipe) { oldValue, newValue in
            // When the edit sheet closes (newValue becomes nil), refresh the displayed recipe
            if newValue == nil, oldValue != nil {
                refreshDisplayedRecipe()
            }
        }
        .onChange(of: model.recipes) { _, _ in
            refreshDisplayedRecipe()
        }
        .onChange(of: model.randomRecipes) { _, _ in
            refreshDisplayedRecipe()
        }
        .onAppear {
            refreshDisplayedRecipe()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recipeDeleted)) { notification in
            guard let deletedID = notification.object as? CKRecord.ID else { return }
            if deletedID == recipe.id {
                dismiss()
            }
        }
        .overlay(alignment: .top) {
            if showCopiedHUD {
                CopiedHUD()
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 60) // Adjust positioning as needed
            }
        }
    }

    private var canEditTags: Bool {
        guard let source = model.currentSource else { return false }
        return model.canEditSource(source) && !model.isOfflineMode
    }

    private var canEditLinkedRecipes: Bool {
        guard let source = model.currentSource else { return false }
        return model.canEditSource(source) && !model.isOfflineMode
    }

    private var availableLinkedRecipeCandidates: [Recipe] {
        sourceRecipePool
            .filter { $0.sourceID == displayedRecipe.sourceID && $0.id != displayedRecipe.id }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var resolvedLinkedRecipes: [Recipe] {
        displayedRecipe.linkedRecipeIDs.compactMap(resolveRecipe(with:))
    }

    private var sourceRecipePool: [Recipe] {
        var ordered: [Recipe] = []
        var seen = Set<CKRecord.ID>()
        for recipe in model.recipes + model.randomRecipes + model.cloudKitManager.recipes {
            if seen.insert(recipe.id).inserted {
                ordered.append(recipe)
            }
        }
        return ordered
    }

    @ViewBuilder
    private var detailsSection: some View {
        if let details = displayedRecipe.details, !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "text.alignleft")
                        .foregroundStyle(.secondary)
                    Text("Details")
                        .font(.title2)
                        .bold()
                }

                Text(details)
                    .font(.body)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var recipeTagManagerContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "tag")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if model.tags.isEmpty {
                    Text("No tags yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    WrappingTagLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(model.tags) { tag in
                            let isSelected = displayedRecipe.tagIDs.contains(tag.id)
                            Button {
                                Task {
                                    await toggleTag(tag)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    let marker = isSelected ? "checkmark.circle.fill" : "circle"
                                    Image(systemName: marker)
                                        .font(.caption)
                                    Text(tag.name)
                                        .lineLimit(1)
                                    Image(systemName: marker)
                                        .font(.caption)
                                        .opacity(0)
                                }
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                                    in: Capsule()
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(!canEditTags || isUpdatingTags)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if isUpdatingTags {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating tags...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let tagUpdateErrorMessage {
                Text(tagUpdateErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var linkedRecipesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                    Text("Linked Recipes")
                        .font(.title2)
                        .bold()
                }

                Spacer()

                if canEditLinkedRecipes, !availableLinkedRecipeCandidates.isEmpty {
                    Button(resolvedLinkedRecipes.isEmpty ? "Add" : "Manage") {
                        isShowingLinkedRecipePicker = true
                    }
                    .disabled(isUpdatingLinkedRecipes)
                }
            }

            if resolvedLinkedRecipes.isEmpty {
                Text(availableLinkedRecipeCandidates.isEmpty ? "Create another recipe to start linking recipes together." : "No linked recipes yet.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(resolvedLinkedRecipes) { linkedRecipe in
                    NavigationLink(value: linkedRecipe) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(linkedRecipe.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                HStack(spacing: 8) {
                                    if let categoryName = categoryName(for: linkedRecipe) {
                                        Text(categoryName)
                                    }
                                    Text("\(linkedRecipe.recipeTime) min")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        rememberNavigation(to: linkedRecipe)
                    })
                    .buttonStyle(.plain)
                }
            }

            if displayedRecipe.linkedRecipeIDs.count != resolvedLinkedRecipes.count {
                Text("Some linked recipes are no longer available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isUpdatingLinkedRecipes {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating linked recipes...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let linkedRecipeUpdateErrorMessage {
                Text(linkedRecipeUpdateErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @MainActor
    private func toggleTag(_ tag: Tag) async {
        guard canEditTags else { return }
        isUpdatingTags = true
        tagUpdateErrorMessage = nil

        var next = Set(displayedRecipe.tagIDs)
        if next.contains(tag.id) {
            next.remove(tag.id)
        } else {
            next.insert(tag.id)
        }
        let nextIDs = Array(next).sorted { $0.recordName.localizedStandardCompare($1.recordName) == .orderedAscending }

        let success = await model.updateRecipeWithSteps(
            id: displayedRecipe.id,
            categoryId: nil,
            name: nil,
            recipeTime: nil,
            details: nil,
            image: nil,
            recipeSteps: nil,
            tagIDs: nextIDs
        )

        if success {
            displayedRecipe.tagIDs = nextIDs
            refreshDisplayedRecipe()
        } else {
            tagUpdateErrorMessage = model.error ?? "Failed to update tags."
        }

        isUpdatingTags = false
    }

    private func resolveRecipe(with id: CKRecord.ID) -> Recipe? {
        model.recipes.first(where: { $0.id == id }) ?? model.randomRecipes.first(where: { $0.id == id })
    }

    private func categoryName(for recipe: Recipe) -> String? {
        model.categories.first(where: { $0.id == recipe.categoryID })?.name
    }

    private func rememberNavigation(to recipe: Recipe) {
        model.saveLastViewedRecipe(recipe)
        model.saveAppLocation(.recipe(recipeID: recipe.id, categoryID: recipe.categoryID))
    }

    @MainActor
    private func updateLinkedRecipes(_ nextIDs: [CKRecord.ID]) async -> String? {
        guard canEditLinkedRecipes else {
            let message = "Linked recipes can’t be edited right now."
            linkedRecipeUpdateErrorMessage = message
            return message
        }

        isUpdatingLinkedRecipes = true
        linkedRecipeUpdateErrorMessage = nil

        let success = await model.updateRecipeWithSteps(
            id: displayedRecipe.id,
            categoryId: nil,
            name: nil,
            recipeTime: nil,
            details: nil,
            image: nil,
            recipeSteps: nil,
            linkedRecipeIDs: nextIDs
        )

        if success {
            displayedRecipe.linkedRecipeIDs = nextIDs
            refreshDisplayedRecipe()
            isUpdatingLinkedRecipes = false
            return nil
        } else {
            let message = model.error ?? "Failed to update linked recipes."
            linkedRecipeUpdateErrorMessage = message
            isUpdatingLinkedRecipes = false
            return message
        }
    }
    
    // Drop this helper anywhere in your file (outside the view body)
    private func copyToReminders(_ lines: [String]) {
        // 1) Normalize (strip "- [ ] " if present)
        let items = lines.map {
            $0.replacingOccurrences(of: #"^\s*-\s*\[\s*\]\s*"#,
                                    with: "",
                                    options: .regularExpression)
        }
        
        // 2) Plain-text fallback: TAB + ◦ + TAB + text
        let plain = items.map { "\t◦\t\($0)" }.joined(separator: "\n")
        
        // 3) Build RTF with a bullet list
        let attr = NSMutableAttributedString()
        let list = NSTextList(markerFormat: .disc, options: 0)
        for s in items {
            let style = NSMutableParagraphStyle()
            style.textLists = [list]
            attr.append(NSAttributedString(string: s + "\n",
                                           attributes: [.paragraphStyle: style]))
        }
        let rtfData = try? attr.data(
            from: NSRange(location: 0, length: attr.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        
#if os(iOS)
        // Put RTF and plain text into a *single* pasteboard item so iOS sees both
        if let rtfData {
            UIPasteboard.general.setItems([
                [
                    "public.rtf": rtfData,
                    // Add multiple plain-text UTIs for best compatibility
                    "public.utf8-plain-text": plain,
                    "public.plain-text": plain,
                    "public.text": plain
                ]
            ])
        } else {
            // Fallback to plain text only
            UIPasteboard.general.string = plain
        }
#elseif os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        if let rtfData { item.setData(rtfData, forType: .rtf) }
        item.setString(plain, forType: .string)
        pb.writeObjects([item])
#endif
    }
    
}

private struct LinkedRecipePickerSheet: View {
    let recipeName: String
    let candidates: [Recipe]
    let categoryName: (Recipe) -> String?
    let onSave: @MainActor ([CKRecord.ID]) async -> String?
    let initialSelection: Set<CKRecord.ID>

    @Environment(\.dismiss) private var dismiss

    @State private var draftSelection: Set<CKRecord.ID>
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    init(
        recipeName: String,
        candidates: [Recipe],
        selectedIDs: Set<CKRecord.ID>,
        categoryName: @escaping (Recipe) -> String?,
        onSave: @escaping @MainActor ([CKRecord.ID]) async -> String?
    ) {
        self.recipeName = recipeName
        self.candidates = candidates
        self.categoryName = categoryName
        self.onSave = onSave
        self.initialSelection = selectedIDs
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
        guard !trimmed.isEmpty else { return candidates }

        return candidates.filter { recipe in
            recipe.name.localizedCaseInsensitiveContains(trimmed) ||
            (categoryName(recipe)?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

#if os(macOS)
    private var macOSView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Linked Recipes")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Connect \(recipeName) to side dishes, sauces, and companion recipes.")
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
                            title: "No Other Recipes",
                            subtitle: "Create another recipe before linking one to \(recipeName).",
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
                            Label("Couldn’t save linked recipes", systemImage: "exclamationmark.triangle.fill")
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
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "No Other Recipes",
                        systemImage: "fork.knife.circle",
                        description: Text("Create another recipe before linking one to \(recipeName).")
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
            .navigationTitle("Linked Recipes")
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
                        Text("Linked")
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

private struct WrappingTagLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0, currentX + size.width > maxWidth {
                usedWidth = max(usedWidth, currentX - horizontalSpacing)
                currentX = 0
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }

            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        usedWidth = max(usedWidth, currentX > 0 ? currentX - horizontalSpacing : 0)
        let totalHeight = currentY + rowHeight
        let fittedWidth = proposal.width ?? usedWidth

        return CGSize(width: fittedWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var originX = bounds.minX
        var originY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if originX > bounds.minX, originX + size.width > bounds.minX + maxWidth {
                originX = bounds.minX
                originY += rowHeight + verticalSpacing
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: originX, y: originY),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            originX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension Notification.Name {
    static let recipeDeleted = Notification.Name("recipeDeleted")
    static let recipeUpdated = Notification.Name("recipeUpdated")
#if os(macOS)
    static let refreshRequested = Notification.Name("refreshRequested")
    static let shareURLCopied = Notification.Name("shareURLCopied")
#endif
    static let recipesRefreshed = Notification.Name("recipesRefreshed")
    static let sourcesRefreshed = Notification.Name("sourcesRefreshed")
    static let shareRevokedToast = Notification.Name("shareRevokedToast")
    static let showTutorial = Notification.Name("showTutorial")
    static let requestAddRecipe = Notification.Name("requestAddRecipe")
    static let requestFeelingLucky = Notification.Name("requestFeelingLucky")
#if os(iOS)
    static let cloudKitShareAccepted = Notification.Name("cloudKitShareAccepted")
    static let cloudKitShareURLReceived = Notification.Name("cloudKitShareURLReceived")
    static let cameraDeviceChanged = Notification.Name("cameraDeviceChanged")
#endif
}
