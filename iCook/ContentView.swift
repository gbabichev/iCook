import SwiftUI

// MARK: - Root Split View (Landmarks-style)

struct ContentView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var preferredColumn: NavigationSplitViewColumn = .detail
    @State private var selectedCategoryID: Category.ID? = -1 // Use -1 as sentinel for "Home"
    @State private var showingAddCategory = false
    @State private var editingCategory: Category? = nil
    
    // New state for recipe search
    @State private var searchResults: [Recipe] = []
    @State private var isSearching = false
    @State private var showingSearchResults = false
    
    // Recipe management state
    @State private var showingAddRecipe = false

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            
            if horizontalSizeClass == .compact && showingSearchResults {
                   NavigationStack {
                       RecipeSearchResultsView(
                           searchText: searchText,
                           searchResults: searchResults,
                           isSearching: isSearching
                       )
                       .navigationDestination(for: Recipe.self) { recipe in
                           RecipeDetailView(recipe: recipe)
                       }
                   }
            } else {
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
            }

        } detail: {
            // Single NavigationStack for the detail view
            NavigationStack {
                if showingSearchResults {
                    // Show search results view
                    RecipeSearchResultsView(
                        searchText: searchText,
                        searchResults: searchResults,
                        isSearching: isSearching
                    )
                } else if let id = selectedCategoryID, id != -1,
                   let cat = model.categories.first(where: { $0.id == id }) {
                    RecipeCollectionView(category: cat)
                } else {
                    // Show home view when selectedCategoryID is nil or -1
                    RecipeCollectionView()
                }
            }
#if os(macOS)
            .toolbar(removing: .title)
#else
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
        .searchable(text: $searchText, placement: .automatic, prompt: "Search recipes")
        .onSubmit(of: .search) {
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                performSearch()
            }
        }
        .onChange(of: searchText) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmed.isEmpty {
                // Clear search when text is empty
                showingSearchResults = false
                searchResults = []
                searchTask?.cancel()
            } else {
                // Debounced search
                searchTask?.cancel()
                searchTask = Task { [trimmed] in
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms debounce
                    if !Task.isCancelled && trimmed == searchText.trimmingCharacters(in: .whitespacesAndNewlines) {
                        await performSearch(with: trimmed)
                    }
                }
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
    
    private func performSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            Task {
                await performSearch(with: trimmed)
            }
        }
    }
    
    @MainActor
    private func performSearch(with query: String) async {
        guard !query.isEmpty else { return }
        
        isSearching = true
        showingSearchResults = true
        
        defer { isSearching = false }
        
        do {
            let results = try await APIClient.searchRecipes(query: query)
            searchResults = results
        } catch {
            print("Search error: \(error)")
            model.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            searchResults = []
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
