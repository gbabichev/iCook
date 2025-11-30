import SwiftUI
import CloudKit

struct RecipeDetailView: View {
    let recipe: Recipe
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var editingRecipe: Recipe?
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false
    @State private var checkedIngredients: Set<String> = []
    @State private var checkedSteps: Set<Int> = []
    @State private var checkedStepIngredients: Set<String> = [] // Format: "stepNumber-ingredientIndex"
    @State private var showCopiedHUD = false
    @State private var displayedRecipe: Recipe

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
                    }
                    
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
//                                                Text("Step \(step.stepNumber)")
//                                                    .font(.headline)
//                                                    .strikethrough(checkedSteps.contains(step.stepNumber))
//                                                    .foregroundStyle(checkedSteps.contains(step.stepNumber) ? .secondary : .primary)
                                                
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
//                                                Text("Ingredients for this step:")
//                                                    .font(.subheadline)
//                                                    .foregroundStyle(.secondary)
//                                                    .padding(.leading, 44) // Align with step content
                                                
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
                    
                    // Instructions Section (kept for backward compatibility)
                    if let details = displayedRecipe.details, !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "text.alignleft")
                                    .foregroundStyle(.secondary)
                                Text("Instructions")
                                    .font(.title2)
                                    .bold()
                            }
                            
                            Text(details)
                                .font(.body)
                                .lineSpacing(4)
                        }
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
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
                Menu {
                    Button {
                        editingRecipe = displayedRecipe
                    } label: {
                        Label("Edit Recipe", systemImage: "pencil")
                    }
                    .disabled(model.isOfflineMode)
                    
                    Button(role: .destructive) {
                        showingDeleteAlert = true
                    } label: {
                        Label("Delete Recipe", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(model.isOfflineMode)
            }
        }
        .sheet(item: $editingRecipe) { recipe in
            AddEditRecipeView(editingRecipe: recipe)
                .environmentObject(model)
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
        .alert("Delete Recipe", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                Task {
                    await deleteRecipe()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete '\(displayedRecipe.name)'? This action cannot be undone.")
        }
        .overlay(alignment: .top) {
            if showCopiedHUD {
                CopiedHUD()
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 60) // Adjust positioning as needed
            }
        }
        .overlay {
            if isDeleting {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Deleting recipe...")
                            .font(.headline)
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
    
    @MainActor
    private func deleteRecipe() async {
        printD("deleteRecipe: Starting deletion for recipe '\(recipe.name)' with ID: \(recipe.id.recordName)")
        isDeleting = true
        let success = await model.deleteRecipeWithUIFeedback(id: recipe.id)
        isDeleting = false
        printD("deleteRecipe: Deletion completed. Success: \(success)")

        if success {
            printD("deleteRecipe: Dismissing view after successful deletion")
            dismiss()
        } else {
            printD("deleteRecipe: Deletion failed, not dismissing view")
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

extension Notification.Name {
    static let recipeDeleted = Notification.Name("recipeDeleted")
    static let recipeUpdated = Notification.Name("recipeUpdated")
    static let refreshRequested = Notification.Name("refreshRequested")
    static let recipesRefreshed = Notification.Name("recipesRefreshed")
    static let shareURLCopied = Notification.Name("shareURLCopied")

}
