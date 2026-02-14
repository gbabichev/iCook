import SwiftUI
import CloudKit

// MARK: - Root Split View (Landmarks-style)

struct ContentView: View {
    @EnvironmentObject private var model: AppViewModel
    #if os(iOS)
    private let isPhone = UIDevice.current.userInterfaceIdiom == .phone
    #endif
    @AppStorage("HasSeenTutorial") private var hasSeenTutorial = false
    
    @State private var preferredColumn: NavigationSplitViewColumn = .detail
    @State private var showingAddCategory = false
    @State private var editingCategory: Category? = nil
    @State private var collectionType: RecipeCollectionType? = .home
    @State private var lastCollectionType: RecipeCollectionType = .home
    @State private var navPath = NavigationPath()
    @State private var navStackKey = UUID().uuidString
    @State private var didRestoreLastViewed = false
    @State private var suppressResetOnSourceChange = false
    @State private var showingTutorial = false
    @State private var showingAddRecipe = false

    private var addRecipePreselectedCategoryId: CKRecord.ID? {
        if case .category(let category) = (collectionType ?? lastCollectionType) {
            return category.id
        }
        return nil
    }
    
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
                    editingCategory: $editingCategory,
                    showingAddCategory: $showingAddCategory,
                    collectionType: $collectionType
                )
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 250, max: 400)
#if os(iOS)
            .navigationTitle(isPhone ? "iCook" : "")
#endif
        } detail: {
            // Single NavigationStack for the detail view
            NavigationStack(path: $navPath) {
                RecipeCollectionView(collectionType: collectionType ?? lastCollectionType)
            }
            .id(navStackKey)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
        .task {
            await model.loadSources()
            if !didRestoreLastViewed,
               let saved = model.loadAppLocation(),
               let source = model.sources.first(where: { $0.id == saved.sourceID }) {
                suppressResetOnSourceChange = true
                await model.selectSource(source)
                await model.loadRandomRecipes(skipCache: true)

                switch saved.location {
                case .allRecipes:
                    collectionType = .home
                    didRestoreLastViewed = true

                case .category(let categoryID):
                    if let category = model.categories.first(where: { $0.id == categoryID }) {
                        collectionType = .category(category)
                        didRestoreLastViewed = true
                    }

                case .recipe(let recipeID, let categoryID):
                    // Set the collection type first
                    if let catID = categoryID,
                       let category = model.categories.first(where: { $0.id == catID }) {
                        collectionType = .category(category)
                    } else {
                        collectionType = .home
                    }

                    #if os(iOS)
                    // On iOS, give NavigationStack time to initialize after collectionType changes
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
                    #endif

                    // Then navigate to the recipe
                    if let recipe = model.recipes.first(where: { $0.id == recipeID }) ??
                        model.randomRecipes.first(where: { $0.id == recipeID }) {
                        navPath.append(recipe)
                        didRestoreLastViewed = true
                    }
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
        .sheet(isPresented: $showingTutorial) {
            TutorialView {
                hasSeenTutorial = true
                showingTutorial = false
            }
            .interactiveDismissDisabled(true)
        }
        .sheet(item: $editingCategory) { category in
            AddCategoryView(editingCategory: category)
                .environmentObject(model)
        }
        .sheet(isPresented: $showingAddRecipe) {
            AddEditRecipeView(preselectedCategoryId: addRecipePreselectedCategoryId)
                .environmentObject(model)
        }
        .onChange(of: collectionType) { _, newValue in
            if let newValue {
                lastCollectionType = newValue
                // Save location when collectionType changes
                switch newValue {
                case .home:
                    model.saveAppLocation(.allRecipes)
                case .category(let category):
                    model.saveAppLocation(.category(categoryID: category.id))
                }
            }
        }
        .onChange(of: navPath.count) { oldCount, newCount in
            // When navigating back from a recipe (path becomes empty)
            // save the current collection type location
            if newCount == 0 && oldCount > 0 {
                switch collectionType {
                case .home:
                    model.saveAppLocation(.allRecipes)
                case .category(let category):
                    model.saveAppLocation(.category(categoryID: category.id))
                case .none:
                    model.saveAppLocation(.allRecipes)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTutorial)) { _ in
            showingTutorial = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestAddRecipe)) { _ in
            guard !model.isOfflineMode, model.currentSource != nil, !model.categories.isEmpty else { return }
            showingAddRecipe = true
        }
        .onAppear {
            // Try to restore immediately from cached data to avoid visible jumps
            if !hasSeenTutorial {
                showingTutorial = true
            }
            guard !didRestoreLastViewed,
                  let saved = model.loadAppLocation(),
                  model.currentSource?.id == saved.sourceID else { return }

            switch saved.location {
            case .allRecipes:
                collectionType = .home
                didRestoreLastViewed = true

            case .category(let categoryID):
                if let category = model.categories.first(where: { $0.id == categoryID }) {
                    collectionType = .category(category)
                    didRestoreLastViewed = true
                }

            case .recipe(let recipeID, let categoryID):
                // Set the collection type first
                if let catID = categoryID,
                   let category = model.categories.first(where: { $0.id == catID }) {
                    collectionType = .category(category)
                } else {
                    collectionType = .home
                }

                // Then navigate to the recipe
                if let recipe = model.recipes.first(where: { $0.id == recipeID }) ??
                    model.randomRecipes.first(where: { $0.id == recipeID }) {
                    #if os(iOS)
                    // On iOS, delay navigation to allow NavigationStack to initialize
                    Task {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
                        suppressResetOnSourceChange = true
                        navPath.append(recipe)
                        didRestoreLastViewed = true
                    }
                    #else
                    suppressResetOnSourceChange = true
                    navPath.append(recipe)
                    didRestoreLastViewed = true
                    #endif
                }
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
