import SwiftUI
import CloudKit

// MARK: - Root Split View (Landmarks-style)

struct ContentView: View {
    @EnvironmentObject private var model: AppViewModel
    
    @State private var preferredColumn: NavigationSplitViewColumn = .detail
    @State private var selectedCategoryID: CKRecord.ID?
    @State private var isShowingHome = true
    @State private var showingAddCategory = false
    @State private var editingCategory: Category? = nil
    @State private var collectionType: RecipeCollectionType? = .home
    @State private var lastCollectionType: RecipeCollectionType = .home
    @State private var navPath = NavigationPath()
    @State private var navStackKey = UUID().uuidString
    @State private var didRestoreLastViewed = false
    @State private var suppressResetOnSourceChange = false
    
    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            VStack(spacing: 0) {
                // iCloud status banner
                if !model.cloudKitManager.isCloudKitAvailable {
                    HStack {
                        Image(systemName: "exclamationmark.icloud")
                            .foregroundStyle(.orange)
                        Text("Using local storage only. Sign in to iCloud to enable cloud sync.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.1))
                }
                
                // Category list
                CategoryList(
                    selection: $selectedCategoryID,
                    editingCategory: $editingCategory,
                    isShowingHome: $isShowingHome,
                    showingAddCategory: $showingAddCategory,
                    collectionType: $collectionType
                )
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 250, max: 400)
            .navigationTitle("iCook") //sidebar title on iOS
        } detail: {
            // Single NavigationStack for the detail view
            NavigationStack(path: $navPath) {
                RecipeCollectionView(collectionType: collectionType ?? lastCollectionType)
            }
            .id(navStackKey)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .navigationDestination(for: Recipe.self) { recipe in
                RecipeDetailView(recipe: recipe)
            }
        }
        .task {
            await model.loadSources()
            if !didRestoreLastViewed,
               let saved = model.loadLastViewedRecipeID(),
               let source = model.sources.first(where: { $0.id == saved.sourceID }) {
                suppressResetOnSourceChange = true
                await model.selectSource(source)
                if let catID = saved.categoryID,
                   let category = model.categories.first(where: { $0.id == catID }) {
                    collectionType = .category(category)
                    await model.loadRecipesForCategory(catID, skipCache: true)
                } else {
                    collectionType = .home
                    await model.loadRandomRecipes(skipCache: true)
                }
                if let recipe = model.recipes.first(where: { $0.id == saved.recipeID }) ??
                    model.randomRecipes.first(where: { $0.id == saved.recipeID }) {
                    navPath.append(recipe)
                    didRestoreLastViewed = true
                }
            } else if model.currentSource != nil {
                await model.loadCategories()
                await model.loadRandomRecipes()
            }
        }
        .onChange(of: model.currentSource?.id) {
            // Pop to root when switching collections unless we just restored
            if suppressResetOnSourceChange {
                suppressResetOnSourceChange = false
            } else {
                navPath = NavigationPath()
                navStackKey = UUID().uuidString
                collectionType = .home
                selectedCategoryID = nil
                isShowingHome = true
                model.clearLastViewedRecipe()
            }
        }
        .onChange(of: model.sourceSelectionStamp) { _, _ in
            if suppressResetOnSourceChange {
                suppressResetOnSourceChange = false
                return
            }
            navPath = NavigationPath()
            navStackKey = UUID().uuidString
            collectionType = .home
            selectedCategoryID = nil
            isShowingHome = true
            model.clearLastViewedRecipe()
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
        .onChange(of: collectionType) { _, newValue in
            if let newValue {
                lastCollectionType = newValue
            }
        }
        .onAppear {
            // Try to restore immediately from cached data to avoid visible jumps
            guard !didRestoreLastViewed,
                  let saved = model.loadLastViewedRecipeID(),
                  model.currentSource?.id == saved.sourceID else { return }
            
            if let catID = saved.categoryID,
               let category = model.categories.first(where: { $0.id == catID }) {
                collectionType = .category(category)
            } else {
                collectionType = .home
            }
            
            if let recipe = model.recipes.first(where: { $0.id == saved.recipeID }) ??
                model.randomRecipes.first(where: { $0.id == saved.recipeID }) {
                suppressResetOnSourceChange = true
                navPath.append(recipe)
                didRestoreLastViewed = true
            }
        }
    }
}

extension Recipe {
    var imageURL: URL? {
        if let cachedImagePath = cachedImagePath {
            let url = URL(fileURLWithPath: cachedImagePath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        guard let asset = imageAsset else { return nil }
        return asset.fileURL
    }
}
