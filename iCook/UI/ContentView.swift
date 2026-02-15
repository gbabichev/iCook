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
    @State private var showingAddTag = false
    @State private var editingCategory: Category? = nil
    @State private var editingTag: Tag? = nil
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

    @ViewBuilder
    private var splitViewContent: some View {
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
                    editingTag: $editingTag,
                    showingAddCategory: $showingAddCategory,
                    showingAddTag: $showingAddTag,
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
    }
    
    var body: some View {
        splitViewContent
        .task {
            await handleInitialLoadTask()
        }
        .onChange(of: model.currentSource?.id) {
            handleCurrentSourceIDChange()
        }
        .onChange(of: model.sourceSelectionStamp) { _, _ in
            handleSourceSelectionStampChange()
        }
        .onChange(of: model.tags) { _, newTags in
            handleTagsChange(newTags)
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
        .sheet(isPresented: $showingAddTag) {
            AddTagView()
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
        .sheet(item: $editingTag) { tag in
            AddTagView(editingTag: tag)
                .environmentObject(model)
        }
        .sheet(isPresented: $showingAddRecipe) {
            AddEditRecipeView(preselectedCategoryId: addRecipePreselectedCategoryId)
                .environmentObject(model)
        }
        .onChange(of: collectionType) { _, newValue in
            handleCollectionTypeChange(newValue)
        }
        .onChange(of: navPath.count) { oldCount, newCount in
            handleNavPathCountChange(oldCount: oldCount, newCount: newCount)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTutorial)) { _ in
            handleShowTutorialRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestAddRecipe)) { _ in
            handleAddRecipeRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestFeelingLucky)) { notification in
            handleFeelingLuckyRequest(notification)
        }
        .onAppear {
            handleOnAppear()
        }
    }

    @MainActor
    private func handleInitialLoadTask() async {
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

            case .tag(let tagID):
                if let tag = model.tags.first(where: { $0.id == tagID }) {
                    collectionType = .tag(tag)
                    didRestoreLastViewed = true
                }

            case .recipe(let recipeID, let categoryID):
                if let catID = categoryID,
                   let category = model.categories.first(where: { $0.id == catID }) {
                    collectionType = .category(category)
                } else {
                    collectionType = .home
                }

#if os(iOS)
                try? await Task.sleep(nanoseconds: 100_000_000)
#endif

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

    private func handleCurrentSourceIDChange() {
        if suppressResetOnSourceChange {
            suppressResetOnSourceChange = false
        } else {
            navPath = NavigationPath()
            navStackKey = UUID().uuidString
            collectionType = .home
            model.clearLastViewedRecipe()
        }
    }

    private func handleSourceSelectionStampChange() {
        if suppressResetOnSourceChange {
            suppressResetOnSourceChange = false
            return
        }
        navPath = NavigationPath()
        navStackKey = UUID().uuidString
        collectionType = .home
        model.clearLastViewedRecipe()
    }

    private func handleTagsChange(_ newTags: [Tag]) {
        guard case .tag(let selectedTag) = collectionType else { return }
        let stillExists = newTags.contains(where: { $0.id == selectedTag.id })
        guard !stillExists else { return }

        navPath = NavigationPath()
        navStackKey = UUID().uuidString
        collectionType = .home
        lastCollectionType = .home
        model.clearLastViewedRecipe()
        model.saveAppLocation(.allRecipes)
    }

    private func handleCollectionTypeChange(_ newValue: RecipeCollectionType?) {
        if let newValue {
            lastCollectionType = newValue
            switch newValue {
            case .home:
                model.saveAppLocation(.allRecipes)
            case .category(let category):
                model.saveAppLocation(.category(categoryID: category.id))
            case .tag(let tag):
                model.saveAppLocation(.tag(tagID: tag.id))
            }
        }
    }

    private func handleNavPathCountChange(oldCount: Int, newCount: Int) {
        if newCount == 0 && oldCount > 0 {
            switch collectionType {
            case .home:
                model.saveAppLocation(.allRecipes)
            case .category(let category):
                model.saveAppLocation(.category(categoryID: category.id))
            case .tag(let tag):
                model.saveAppLocation(.tag(tagID: tag.id))
            case .none:
                model.saveAppLocation(.allRecipes)
            }
        }
    }

    private func handleShowTutorialRequest() {
        showingTutorial = true
    }

    private func handleAddRecipeRequest() {
        guard !model.isOfflineMode, model.currentSource != nil, !model.categories.isEmpty else { return }
        showingAddRecipe = true
    }

    private func handleFeelingLuckyRequest(_ notification: Notification) {
        guard let recipe = notification.object as? Recipe else { return }

        if navPath.count > 0 {
            navPath = NavigationPath()
        }

        model.saveLastViewedRecipe(recipe)
        switch collectionType ?? lastCollectionType {
        case .home:
            model.saveAppLocation(.recipe(recipeID: recipe.id, categoryID: recipe.categoryID))
        case .category(let category):
            model.saveAppLocation(.recipe(recipeID: recipe.id, categoryID: category.id))
        case .tag:
            model.saveAppLocation(.recipe(recipeID: recipe.id, categoryID: recipe.categoryID))
        }

        navPath.append(recipe)
    }

    private func handleOnAppear() {
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

        case .tag(let tagID):
            if let tag = model.tags.first(where: { $0.id == tagID }) {
                collectionType = .tag(tag)
                didRestoreLastViewed = true
            }

        case .recipe(let recipeID, let categoryID):
            if let catID = categoryID,
               let category = model.categories.first(where: { $0.id == catID }) {
                collectionType = .category(category)
            } else {
                collectionType = .home
            }

            if let recipe = model.recipes.first(where: { $0.id == recipeID }) ??
                model.randomRecipes.first(where: { $0.id == recipeID }) {
#if os(iOS)
                Task {
                    try? await Task.sleep(nanoseconds: 100_000_000)
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
