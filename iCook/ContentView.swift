import SwiftUI

// MARK: - Root Split View (Landmarks-style)

struct ContentView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var preferredColumn: NavigationSplitViewColumn = .detail
    @State private var selectedCategoryID: Category.ID? = -1 // Use -1 as sentinel for "Home"
    @State private var showingAddCategory = false
    @State private var editingCategory: Category? = nil
    
    // Recipe management state
    @State private var showingAddRecipe = false

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            CategoryList(
                selection: $selectedCategoryID,
                editingCategory: $editingCategory
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddCategory = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Category")
                }
            }
        } detail: {
            // Single NavigationStack for the detail view
            NavigationStack {
                if let id = selectedCategoryID, id != -1,
                   let cat = model.categories.first(where: { $0.id == id }) {
                    RecipeCollectionView(category: cat)
                } else {
                    // Show home view when selectedCategoryID is nil or -1
                    RecipeCollectionView()
                }
            }
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar{
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddRecipe = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("Add Recipe")
                }
                ToolbarSpacer(.flexible)
            }
            .ignoresSafeArea(edges: .top)
            .navigationDestination(for: Recipe.self) { recipe in
                RecipeDetailView(recipe: recipe)
            }
        }
        .task {
            if model.categories.isEmpty {
                await model.loadCategories()
            }
        }
        .alert("Error",
               isPresented: .init(
                   get: { model.error != nil },
                   set: { if !$0 { model.error = nil } }
               ),
               actions: { Button("OK") { model.error = nil } },
               message: { Text(model.error ?? "") }
        )
        .sheet(isPresented: $showingAddCategory) {
            AddCategoryView()
                .environmentObject(model)
        }
        .sheet(item: $editingCategory) { category in
            AddCategoryView(editingCategory: category)
                .environmentObject(model)
        }
        .sheet(isPresented: $showingAddRecipe) {
            AddEditRecipeView(preselectedCategoryId: selectedCategoryID == -1 ? nil : selectedCategoryID)
                .environmentObject(model)
        }
    }
}

extension Recipe {
    var imageURL: URL? {
        guard let path = image, !path.isEmpty else { return nil }
        var comps = URLComponents(url: APIConfig.base, resolvingAgainstBaseURL: false)
        comps?.query = nil
        comps?.path = path.hasPrefix("/") ? path : "/" + path
        return comps?.url
    }
}
