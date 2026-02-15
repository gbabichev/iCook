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
