import SwiftUI

struct RecipeDetailView: View {
    let recipe: Recipe
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var editingRecipe: Recipe?
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false
    @State private var checkedIngredients: Set<Int> = []
    @State private var showCopiedHUD = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AsyncImage(url: recipe.imageURL) { phase in
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
                        Text(recipe.name)
                            .font(.largeTitle)
                            .bold()
                        
                        HStack {
                            Image(systemName: "clock")
                                .foregroundStyle(.secondary)
                            Text("\(recipe.recipe_time) minutes")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    // Ingredients Section
                    if let ingredients = recipe.ingredients, !ingredients.isEmpty {
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
                                ForEach(Array(ingredients.enumerated()), id: \.offset) { index, ingredient in
                                    HStack(alignment: .top, spacing: 12) {
                                        Button {
                                            if checkedIngredients.contains(index) {
                                                checkedIngredients.remove(index)
                                            } else {
                                                checkedIngredients.insert(index)
                                            }
                                        } label: {
                                            Image(systemName: checkedIngredients.contains(index) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(checkedIngredients.contains(index) ? .green : .secondary)
                                                .font(.title3)
                                        }
                                        .buttonStyle(.plain)
                                        
                                        Text(ingredient)
                                            .textSelection(.enabled)
                                            .font(.body)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .strikethrough(checkedIngredients.contains(index))
                                            .foregroundStyle(checkedIngredients.contains(index) ? .secondary : .primary)
                                        
                                        Spacer()
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    
                    // Instructions Section
                    if let details = recipe.details, !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "text.alignleft")
                                    .foregroundStyle(.secondary)
                                Text("Instructions")
                                    .font(.title2)
                                    .bold()
                            }
                            
                            Text("No recipe instructions available.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .italic()
                        }
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal)
                
                Spacer()
            }
        }
        .navigationTitle(recipe.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .ignoresSafeArea(edges: .top)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        editingRecipe = recipe
                    } label: {
                        Label("Edit Recipe", systemImage: "pencil")
                    }
                    
                    Button(role: .destructive) {
                        showingDeleteAlert = true
                    } label: {
                        Label("Delete Recipe", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editingRecipe) { recipe in
            AddEditRecipeView(editingRecipe: recipe)
                .environmentObject(model)
        }
        .alert("Delete Recipe", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                Task {
                    await deleteRecipe()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete '\(recipe.name)'? This action cannot be undone.")
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
        isDeleting = true
        let success = await model.deleteRecipeWithUIFeedback(id: recipe.id)
        isDeleting = false
        
        if success {
            dismiss()
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

}
