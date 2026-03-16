//
//  RecipeCollectionType.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI
import CloudKit

private enum RecipeSearchScope: String, CaseIterable, Hashable {
    case name
    case ingredient

    var title: String {
        switch self {
        case .name:
            return "Search Recipe Name"
        case .ingredient:
            return "Search Ingredient"
        }
    }
}

private enum RecipeSortOption: String, CaseIterable, Hashable {
    case alphabetical
    case recentlyUpdated
    case longestCook
    case shortestCook

    var title: String {
        switch self {
        case .alphabetical:
            return "Alphabetical"
        case .recentlyUpdated:
            return "Recently Updated"
        case .longestCook:
            return "Longest Cook"
        case .shortestCook:
            return "Shortest Cook"
        }
    }
}

enum RecipeCollectionType: Hashable {
    case home
    case favorites
    case category(Category)
    case tag(Tag)
    
    var navigationTitle: String {
        switch self {
        case .home:
            return "All Recipes"
        case .favorites:
            return "Favorites"
        case .category(let category):
            return category.name
        case .tag(let tag):
            return tag.name
        }
    }
    
    var loadingText: String {
        switch self {
        case .home:
            return "Loading featured recipe..."
        case .favorites:
            return "Loading favorite recipes..."
        case .category(let category):
            return "Loading \(category.name.lowercased()) recipes..."
        case .tag(let tag):
            return "Loading \(tag.name.lowercased()) recipes..."
        }
    }
    
    var emptyStateText: String {
        switch self {
        case .home:
            return "No recipes found"
        case .favorites:
            return "No favorite recipes yet"
        case .category(let category):
            return "No \(category.name.lowercased()) recipes found"
        case .tag(let tag):
            return "No recipes found for \(tag.name)"
        }
    }
    
    var emptyStateIcon: String {
        switch self {
        case .home:
            return "🍴"
        case .favorites:
            return "⭐"
        case .category(let category):
            return category.icon
        case .tag:
            return "🏷️"
        }
    }
    
    static func == (lhs: RecipeCollectionType, rhs: RecipeCollectionType) -> Bool {
        switch (lhs, rhs) {
        case (.home, .home):
            return true
        case (.favorites, .favorites):
            return true
        case (.category(let lhsCat), .category(let rhsCat)):
            return lhsCat.id == rhsCat.id
        case (.tag(let lhsTag), .tag(let rhsTag)):
            return lhsTag.id == rhsTag.id
        default:
            return false
        }
    }
    
    func hash(into hasher: inout Hasher) {
        switch self {
        case .home:
            hasher.combine("home")
        case .favorites:
            hasher.combine("favorites")
        case .category(let category):
            hasher.combine("category")
            hasher.combine(category.id)
        case .tag(let tag):
            hasher.combine("tag")
            hasher.combine(tag.id)
        }
    }
}

struct RecipeCollectionView: View {
    let collectionType: RecipeCollectionType
    @EnvironmentObject private var model: AppViewModel
    @AppStorage("EnableFeelingLucky") private var enableFeelingLucky = true
    @AppStorage("ShowInlineTitles") private var showInlineTitles = true
    @AppStorage("RecipeSortOption") private var recipeSortOptionRawValue = RecipeSortOption.alphabetical.rawValue
    
    // Toolbar state - passed from parent or locally managed
    @State private var showNewSourceSheet = false
    @State private var newSourceName = ""
    
    @State private var isLoading = false
    @State private var error: String?
    @State private var currentLoadTask: Task<Void, Never>?
    @State private var editingRecipe: Recipe?
    @State private var deletingRecipe: Recipe?
    @State private var showingDeleteAlert = false
    @State private var showingOfflineNotice = false
    @State private var isDeleting = false
    @State private var selectedFeaturedRecipe: Recipe?
    @State private var hasLoadedInitially = false
    @State private var isRefreshInFlight = false
    @State private var showRefreshSpinner = false
    
    // Search state
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var searchResults: [Recipe] = []
    @State private var isSearching = false
    @State private var showingSearchResults = false
    @State private var searchScope: RecipeSearchScope = .name
    @State private var searchActivationScrollResetToken = 0
    @State private var showRevokedToast = false
    @State private var revokedToastMessage = ""
    @State private var featuredHomeRecipe: Recipe?
    @State private var isShowingTagRecipePicker = false
    
    
    // Adaptive columns with consistent spacing - account for spacing in minimum width
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 15)]

    private var recipeSortOption: RecipeSortOption {
        get { RecipeSortOption(rawValue: recipeSortOptionRawValue) ?? .alphabetical }
        nonmutating set { recipeSortOptionRawValue = newValue.rawValue }
    }

    private func sortedRecipes(_ recipes: [Recipe]) -> [Recipe] {
        recipes.sorted { first, second in
            switch recipeSortOption {
            case .alphabetical:
                let nameComparison = first.name.localizedCaseInsensitiveCompare(second.name)
                if nameComparison != .orderedSame {
                    return nameComparison == .orderedAscending
                }
                return first.id.recordName.localizedStandardCompare(second.id.recordName) == .orderedAscending
            case .recentlyUpdated:
                if first.lastModified != second.lastModified {
                    return first.lastModified > second.lastModified
                }
                return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
            case .longestCook:
                if first.recipeTime != second.recipeTime {
                    return first.recipeTime > second.recipeTime
                }
                return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
            case .shortestCook:
                if first.recipeTime != second.recipeTime {
                    return first.recipeTime < second.recipeTime
                }
                return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
            }
        }
    }
    
    // Computed property to get the appropriate recipe list
    private var recipes: [Recipe] {
        if showingSearchResults {
            return filteredRecipes(for: searchText)
        }
        
        switch collectionType {
        case .home:
            return sortedRecipes(model.recipes)
        case .favorites:
            return sortedRecipes(model.recipes.filter { model.isFavorite($0.id) })
        case .category(let category):
            return sortedRecipes(model.recipes.filter { $0.categoryID == category.id })
        case .tag(let tag):
            return sortedRecipes(model.recipes.filter { $0.tagIDs.contains(tag.id) })
        }
    }
    
    @ViewBuilder
    private var offlineStatusIndicator: some View {
        if shouldShowCloudStatusIndicator {
            Button {
                showingOfflineNotice = true
            } label: {
                if model.isRetryingCloudConnection {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: cloudStatusSymbol)
                }
            }
            .foregroundStyle(cloudStatusColor)
            .accessibilityLabel(cloudStatusTitle)
        }
    }
    
    // Featured recipe (first or stored random)
    private var featuredRecipe: Recipe? {
        if showingSearchResults {
            return nil // no featured recipes during search.
        }
        
        switch collectionType {
        case .home:
            if let selected = featuredHomeRecipe,
               let current = recipes.first(where: { $0.id == selected.id }) {
                return current
            }
            return recipes.randomElement()
        case .favorites, .category, .tag:
            // Resolve the stored selection against the latest shared recipes so name/image changes show up.
            if let selected = selectedFeaturedRecipe,
               let current = recipes.first(where: { $0.id == selected.id }) {
                return current
            }
            return nil // Don't select here - do it in loadCategoryRecipes
        }
    }

    private func resolvedImageURL(for recipe: Recipe) -> URL? {
        if let imageURL = recipe.imageURL {
            return imageURL
        }
        if let cachedPath = model.cloudKitManager.cachedImagePathForRecipe(recipe.id) {
            return URL(fileURLWithPath: cachedPath)
        }
        return nil
    }
    
    // Remaining recipes (excluding featured)
    private var remainingRecipes: [Recipe] {
        if showingSearchResults {
            return recipes
        }
        
        return recipes
    }
    
    // Check if we're showing a category
    private var isFilteredCollection: Bool {
        if case .category = collectionType {
            return true
        }
        if case .tag = collectionType {
            return true
        }
        if case .favorites = collectionType {
            return true
        }
        return false
    }
    
    // Check if we're showing home
    private var isHome: Bool {
        if case .home = collectionType {
            return true
        }
        return false
    }

    private func categoryName(for recipe: Recipe) -> String? {
        switch collectionType {
        case .favorites:
            return model.categories.first(where: { $0.id == recipe.categoryID })?.name
        case .category(let category):
            return category.name
        case .tag:
            return model.categories.first(where: { $0.id == recipe.categoryID })?.name
        case .home:
            return model.categories.first(where: { $0.id == recipe.categoryID })?.name
        }
    }

    private func tagNames(for recipe: Recipe) -> [String] {
        guard !recipe.tagIDs.isEmpty, !model.tags.isEmpty else { return [] }
        let namesByID = Dictionary(uniqueKeysWithValues: model.tags.map { ($0.id, $0.name) })
        var seen = Set<String>()
        var orderedNames: [String] = []
        for tagID in recipe.tagIDs {
            guard let name = namesByID[tagID], !name.isEmpty else { continue }
            if seen.insert(name).inserted {
                orderedNames.append(name)
            }
        }
        return orderedNames
    }
    
    private var isSearchActive: Bool {
        showingSearchResults || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowCloudStatusIndicator: Bool {
        switch model.cloudConnectionState {
        case .offline, .degraded:
            return true
        case .connected, .syncing, .localOnly:
            return false
        }
    }

    private var cloudStatusTitle: String {
        switch model.cloudConnectionState {
        case .offline:
            return "Offline Mode"
        case .degraded:
            return "Connection Issue"
        case .connected:
            return "Connected"
        case .syncing:
            return "Syncing"
        case .localOnly:
            return "iCloud Unavailable"
        }
    }

    private var cloudStatusSymbol: String {
        switch model.cloudConnectionState {
        case .offline:
            return "wifi.slash"
        case .degraded:
            return "wifi.exclamationmark"
        case .connected:
            return "wifi"
        case .syncing:
            return "arrow.trianglehead.2.clockwise"
        case .localOnly:
            return "exclamationmark.icloud"
        }
    }

    private var cloudStatusColor: Color {
        switch model.cloudConnectionState {
        case .offline:
            return .red
        case .degraded:
            return .orange
        case .connected, .syncing, .localOnly:
            return .primary
        }
    }

#if os(macOS)
    private var isSearchFilterVisible: Bool {
        isSearchPresented || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
#endif

    private var searchPromptText: String {
        switch collectionType {
        case .home:
            return searchScope == .name ? "Search Recipes" : "Search Ingredients"
        case .favorites:
            return searchScope == .name ? "Search Favorites" : "Search ingredients in favorites"
        case .category(let category):
            return searchScope == .name ? "Search in \(category.name)" : "Search ingredients in \(category.name)"
        case .tag(let tag):
            return searchScope == .name ? "Search in \(tag.name)" : "Search ingredients in \(tag.name)"
        }
    }

#if os(macOS)
    private var searchScopeToolbarMenu: some View {
        Menu {
            ForEach(RecipeSearchScope.allCases, id: \.self) { scope in
                Button {
                    searchScope = scope
                } label: {
                    if searchScope == scope {
                        Label(scope.title, systemImage: "checkmark")
                    } else {
                        Text(scope.title)
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .accessibilityLabel("Search Filter")
        .help("Filter recipe search by name or ingredient")
    }
#endif

    private var sortToolbarMenu: some View {
        Menu {
            ForEach(RecipeSortOption.allCases, id: \.self) { option in
                Button {
                    recipeSortOption = option
                } label: {
                    if recipeSortOption == option {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort Recipes")
        .help("Sort recipes")
    }

    private var luckyRecipePool: [Recipe] {
        switch collectionType {
        case .home:
            return model.recipes
        case .favorites:
            return model.recipes.filter { model.isFavorite($0.id) }
        case .category(let category):
            return model.recipes.filter { $0.categoryID == category.id }
        case .tag(let tag):
            return model.recipes.filter { $0.tagIDs.contains(tag.id) }
        }
    }

    private var canEditTagAssignments: Bool {
        guard case .tag = collectionType,
              let source = model.currentSource else { return false }
        return model.canEditSource(source) && !model.isOfflineMode
    }

    private var sourceRecipePool: [Recipe] {
        guard let currentSourceID = model.currentSource?.id else { return [] }
        var ordered: [Recipe] = []
        var seen = Set<CKRecord.ID>()
        for recipe in model.recipes + model.randomRecipes + model.cloudKitManager.recipes {
            if recipe.sourceID == currentSourceID, seen.insert(recipe.id).inserted {
                ordered.append(recipe)
            }
        }
        return ordered
    }

    private var tagRecipeCandidates: [Recipe] {
        sourceRecipePool.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func selectedRecipeIDs(for tag: Tag) -> Set<CKRecord.ID> {
        Set(tagRecipeCandidates.filter { $0.tagIDs.contains(tag.id) }.map(\.id))
    }

    // MARK: - Toolbar Views

    // Initializers
    init(collectionType: RecipeCollectionType = .home) {
        self.collectionType = collectionType
    }
    
    // MARK: - Header Views

    private func openRecipeFromHeader(_ recipe: Recipe) {
        model.saveLastViewedRecipe(recipe)
        // Save app location when navigating to recipe
        switch collectionType {
        case .home:
            model.saveAppLocation(.recipe(recipeID: recipe.id, categoryID: recipe.categoryID))
        case .favorites:
            model.saveAppLocation(.recipe(recipeID: recipe.id, categoryID: recipe.categoryID))
        case .category(let category):
            model.saveAppLocation(.recipe(recipeID: recipe.id, categoryID: category.id))
        case .tag:
            model.saveAppLocation(.recipe(recipeID: recipe.id, categoryID: recipe.categoryID))
        }
    }

    @ViewBuilder
    private func headerRecipeLink(_ recipe: Recipe) -> some View {
        NavigationLink(value: recipe) {
            HStack {
                Image(systemName: "eye")
                Text("View Recipe")
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial.opacity(0.8), in: Capsule())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded {
            openRecipeFromHeader(recipe)
        })
    }

    private func renderHeroImage(_ image: Image, recipe: Recipe, baseHeight: CGFloat) -> some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .backgroundExtensionEffect()
            .collectionFlexibleHeaderContent(baseHeight: baseHeight)
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    VStack(spacing: 8) {
                        Text(recipe.name)
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                        Text("\(recipe.recipeTime) minutes")
                            .font(.headline)
                            .foregroundColor(.white)
                            .opacity(0.9)
                        headerRecipeLink(recipe)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                    )
                    .padding(.bottom, 24)
                }
            }
    }

    private func fallbackHeroHeader(_ recipe: Recipe, baseHeight: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color.gray.opacity(0.45), Color.gray.opacity(0.25)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .backgroundExtensionEffect()
        .collectionFlexibleHeaderContent(baseHeight: baseHeight)
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                VStack(spacing: 8) {
                    Text(recipe.name)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    Text("\(recipe.recipeTime) minutes")
                        .font(.headline)
                        .foregroundColor(.white)
                        .opacity(0.9)
                    headerRecipeLink(recipe)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                )
                .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder
    private func featuredRecipeHeader(_ recipe: Recipe, baseHeight: CGFloat) -> some View {
        if let imageURL = resolvedImageURL(for: recipe) {
            RobustAsyncImage(url: imageURL) { image in
                renderHeroImage(image, recipe: recipe, baseHeight: baseHeight)
            } placeholder: {
                fallbackHeroHeader(recipe, baseHeight: baseHeight)
            }
        } else {
            fallbackHeroHeader(recipe, baseHeight: baseHeight)
        }
    }
    
    // MARK: - Recipes Grid Section
    
    @ViewBuilder
    private func recipesGridSection() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Show grid if there are recipes, or centered no results message if searching with no results
            if !remainingRecipes.isEmpty {
                LazyVGrid(columns: columns, spacing: 15) {
                    ForEach(Array(remainingRecipes.enumerated()), id: \.element.id) { index, recipe in
                        NavigationLink(value: recipe) {
                            RecipeLargeButtonWithState(
                                recipe: recipe,
                                categoryName: categoryName(for: recipe),
                                tagNames: tagNames(for: recipe),
                                index: index
                            )
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            model.saveLastViewedRecipe(recipe)
                            // Save app location when navigating to recipe
                            switch collectionType {
                            case .home:
                                model.saveAppLocation(.recipe(recipeID: recipe.id, categoryID: recipe.categoryID))
                            case .favorites:
                                model.saveAppLocation(.recipe(recipeID: recipe.id, categoryID: recipe.categoryID))
                            case .category(let category):
                                model.saveAppLocation(.recipe(recipeID: recipe.id, categoryID: category.id))
                            case .tag:
                                model.saveAppLocation(.recipe(recipeID: recipe.id, categoryID: recipe.categoryID))
                            }
                        })
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                editingRecipe = recipe
                            } label: {
                                Label("Edit Recipe", systemImage: "pencil")
                            }
                            .disabled(model.isOfflineMode)
                        }
                    }
                }
                .padding(.horizontal, 15)
            } else if showingSearchResults {
                // Centered no results message
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    
                    Text("No results found")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            }
        }
    }
    
    
    // MARK: - Loading Logic
    
    @MainActor
    private func loadRecipes(skipCache: Bool = false) async {
        // Cancel any existing task first
        currentLoadTask?.cancel()
        
        currentLoadTask = Task {
            switch collectionType {
            case .home:
                await loadHomeRecipes(skipCache: skipCache)
            case .favorites:
                await loadFavoriteRecipes(skipCache: skipCache)
            case .category(let category):
                await loadCategoryRecipes(category, skipCache: skipCache)
            case .tag(let tag):
                await loadTagRecipes(tag, skipCache: skipCache)
            }
        }
        
        await currentLoadTask?.value
    }
    
    @MainActor
    private func loadHomeRecipes(skipCache: Bool = false) async {
        guard !Task.isCancelled else { return }

        error = nil
        let visibleRecipes = model.recipes
        if !visibleRecipes.isEmpty {
            if let currentFeatured = featuredHomeRecipe,
               let refreshedFeatured = visibleRecipes.first(where: { $0.id == currentFeatured.id }) {
                featuredHomeRecipe = refreshedFeatured
            } else {
                featuredHomeRecipe = visibleRecipes.randomElement()
            }

            isLoading = false
            if !model.isLoadingRecipes {
                Task { @MainActor in
                    showRefreshSpinner = true
                    await model.loadRandomRecipes(skipCache: skipCache)
                    guard !Task.isCancelled else {
                        showRefreshSpinner = false
                        return
                    }

                    if let currentFeatured = featuredHomeRecipe,
                       let refreshedFeatured = model.recipes.first(where: { $0.id == currentFeatured.id }) {
                        featuredHomeRecipe = refreshedFeatured
                    } else {
                        featuredHomeRecipe = model.recipes.randomElement()
                    }

                    if let modelError = model.error {
                        error = modelError
                    }
                    showRefreshSpinner = false
                }
            }
            return
        }

        isLoading = true
        defer { isLoading = false }

        await model.loadRandomRecipes(skipCache: skipCache)
        guard !Task.isCancelled else { return }

        if let currentFeatured = featuredHomeRecipe,
           let refreshedFeatured = model.recipes.first(where: { $0.id == currentFeatured.id }) {
            featuredHomeRecipe = refreshedFeatured
        } else {
            featuredHomeRecipe = model.recipes.randomElement()
        }

        if let modelError = model.error {
            error = modelError
        }

        try? await Task.sleep(nanoseconds: 800_000_000) // 800ms minimum refresh time
    }
    
    @MainActor
    private func loadCategoryRecipes(_ category: Category, skipCache: Bool = false) async {
        guard !Task.isCancelled else { return }
        
        error = nil
        // Immediately show cached data if present
        let cached = model.recipes.filter { $0.categoryID == category.id }
        if !cached.isEmpty {
            selectedFeaturedRecipe = cached.randomElement()
            isLoading = false
            // Kick off a background refresh of all recipes if we're not already loading
            if !model.isLoadingRecipes {
                Task {
                    showRefreshSpinner = true
                    await model.loadRandomRecipes(skipCache: skipCache)
                    showRefreshSpinner = false
                }
            }
        } else {
            // Nothing cached for this category; block until we fetch
            isLoading = true
            defer { isLoading = false }
            await model.loadRandomRecipes(skipCache: skipCache)
            let fresh = model.recipes.filter { $0.categoryID == category.id }
            if !fresh.isEmpty {
                selectedFeaturedRecipe = fresh.randomElement()
            }
        }
        
        if let modelError = model.error {
            self.error = modelError
        }
    }
    
    @MainActor
    private func refreshCategoryRecipes(skipCache: Bool = false) async {
        guard case .category(let category) = collectionType else { return }
        await loadCategoryRecipes(category, skipCache: skipCache)
    }

    @MainActor
    private func loadFavoriteRecipes(skipCache: Bool = false) async {
        guard !Task.isCancelled else { return }

        error = nil
        let cached = model.recipes.filter { model.isFavorite($0.id) }
        if !cached.isEmpty {
            selectedFeaturedRecipe = cached.randomElement()
            isLoading = false
            if !model.isLoadingRecipes {
                Task {
                    showRefreshSpinner = true
                    await model.loadRandomRecipes(skipCache: skipCache)
                    showRefreshSpinner = false
                }
            }
        } else {
            isLoading = true
            defer { isLoading = false }
            await model.loadRandomRecipes(skipCache: skipCache)
            let fresh = model.recipes.filter { model.isFavorite($0.id) }
            if !fresh.isEmpty {
                selectedFeaturedRecipe = fresh.randomElement()
            }
        }

        if let modelError = model.error {
            self.error = modelError
        }
    }

    @MainActor
    private func refreshFavoriteRecipes(skipCache: Bool = false) async {
        guard case .favorites = collectionType else { return }
        await loadFavoriteRecipes(skipCache: skipCache)
    }

    @MainActor
    private func loadTagRecipes(_ tag: Tag, skipCache: Bool = false) async {
        guard !Task.isCancelled else { return }

        error = nil
        let cached = model.recipes.filter { $0.tagIDs.contains(tag.id) }
        if !cached.isEmpty {
            selectedFeaturedRecipe = cached.randomElement()
            isLoading = false
            if !model.isLoadingRecipes {
                Task {
                    showRefreshSpinner = true
                    await model.loadRandomRecipes(skipCache: skipCache)
                    showRefreshSpinner = false
                }
            }
        } else {
            isLoading = true
            defer { isLoading = false }
            await model.loadRandomRecipes(skipCache: skipCache)
            let fresh = model.recipes.filter { $0.tagIDs.contains(tag.id) }
            if !fresh.isEmpty {
                selectedFeaturedRecipe = fresh.randomElement()
            }
        }

        if let modelError = model.error {
            self.error = modelError
        }
    }

    @MainActor
    private func refreshTagRecipes(skipCache: Bool = false) async {
        guard case .tag(let tag) = collectionType else { return }
        await loadTagRecipes(tag, skipCache: skipCache)
    }
    
    @MainActor
    private func deleteRecipe(_ recipe: Recipe) async {
        isDeleting = true
        let success = await model.deleteRecipeWithUIFeedback(id: recipe.id)
        isDeleting = false
        
        if success {
            // Model.deleteRecipe already updates model.recipes; view will filter it out.
        }

        deletingRecipe = nil
    }
    
    // MARK: - Search Logic

    private func filteredRecipes(for query: String) -> [Recipe] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let base: [Recipe]
        if case .favorites = collectionType {
            base = model.recipes.filter { model.isFavorite($0.id) }
        } else if case .category(let category) = collectionType {
            base = model.recipes.filter { $0.categoryID == category.id }
        } else if case .tag(let tag) = collectionType {
            base = model.recipes.filter { $0.tagIDs.contains(tag.id) }
        } else {
            base = model.recipes
        }

        return sortedRecipes(base.filter { recipe in
            recipeMatchesSearch(recipe, query: trimmed)
        })
    }

    private func recipeMatchesSearch(_ recipe: Recipe, query: String) -> Bool {
        switch searchScope {
        case .name:
            return recipe.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .ingredient:
            let ingredients = recipe.ingredients ?? []
            return ingredients.contains { ingredient in
                ingredient.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
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
        
        showingSearchResults = true
        searchResults = filteredRecipes(for: query)
        isSearching = false
        
        if let modelError = model.error {
            printD("Search error: \(modelError)")
        }
    }

    // MARK: - UI View
    
    private var shouldShowNoSourceState: Bool {
        isHome && model.currentSource == nil && !showingSearchResults
    }
    
    private var shouldShowWelcomeState: Bool {
        isHome && model.currentSource != nil && model.recipes.isEmpty && !isLoading && !showingSearchResults
    }
    
    private var shouldShowEmptyState: Bool {
        !isLoading && recipes.isEmpty && !(isHome && model.recipes.isEmpty) && !showingSearchResults
    }

    private var shouldUseHeroNavigationChrome: Bool {
        !showingSearchResults && !shouldShowNoSourceState && !shouldShowWelcomeState && !shouldShowEmptyState
    }
    
    private var offlineNoticeSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: cloudStatusSymbol)
                .font(.system(size: 48))
                .foregroundStyle(cloudStatusColor)
            Text(cloudStatusTitle)
                .font(.headline)
            Text(model.cloudConnectionMessage ?? "Connect to the internet to sync recipes with iCloud and enable recipe editing.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            if model.canRetryCloudConnection {
                Button {
                    Task {
                        await model.retryCloudConnectionAndRefresh(skipRecipeCache: true)
                        if !model.canRetryCloudConnection {
                            showingOfflineNotice = false
                        }
                    }
                } label: {
                    if model.isRetryingCloudConnection {
                        ProgressView()
                    } else {
                        Text("Retry Connection")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRetryingCloudConnection)
            }
            Button(model.canRetryCloudConnection ? "Close" : "Got it") {
                showingOfflineNotice = false
            }
        }
        .padding(24)
        .frame(minWidth: 280)
    }

    @ViewBuilder
    private var tagRecipePickerSheet: some View {
        if case .tag(let tag) = collectionType {
            TagRecipePickerSheet(
                tagName: tag.name,
                candidates: tagRecipeCandidates,
                selectedIDs: selectedRecipeIDs(for: tag),
                categoryName: categoryName(for:),
                onSave: { ids in
                    await updateTagAssignments(for: tag, selectedIDs: ids)
                }
            )
        }
    }
    
    var body: some View {
        mainContent
            .applyNavigationModifiers(
                collectionType: collectionType,
                showingSearchResults: showingSearchResults,
                showsFeaturedHeader: shouldUseHeroNavigationChrome,
                showInlineTitles: showInlineTitles
            )
            .navigationDestination(for: Recipe.self) { recipe in
                RecipeDetailView(recipe: recipe)
            }
            .applyLifecycleModifiers(searchTask: $searchTask)
            .applyAlertModifiers(
                error: $error,
                deletingRecipe: $deletingRecipe,
                showingDeleteAlert: $showingDeleteAlert
            ) { recipe in
                Task { await deleteRecipe(recipe) }
            }
            .applySheetModifiers(editingRecipe: $editingRecipe, showNewSourceSheet: $showNewSourceSheet, newSourceName: $newSourceName, model: model)
            .sheet(isPresented: $isShowingTagRecipePicker) { tagRecipePickerSheet }
            .toast(isPresented: $showRevokedToast, message: revokedToastMessage)
            .ignoresSafeArea(edges: isSearchActive ? [] : .top)
            .onReceive(NotificationCenter.default.publisher(for: .recipeDeleted), perform: handleRecipeDeleted)
            .onReceive(NotificationCenter.default.publisher(for: .recipeUpdated), perform: handleRecipeUpdated)
#if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: .refreshRequested)) { _ in
                Task { await handleRefresh() }
            }
#endif
            .task { await initialLoadIfNeeded() }
            .onChange(of: collectionType) { _, _ in Task { await handleCollectionTypeChange() } }
            .searchable(text: $searchText, isPresented: $isSearchPresented, placement: .toolbar, prompt: searchPromptText)
#if os(iOS)
            .searchScopes($searchScope) {
                ForEach(RecipeSearchScope.allCases, id: \.self) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .scrollDismissesKeyboard(.immediately)
#endif
            .onSubmit(of: .search) { performSearch() }
            .onChange(of: model.recipes) { _, newValue in
                if case .home = collectionType {
                    if let selected = featuredHomeRecipe,
                       let refreshedFeatured = newValue.first(where: { $0.id == selected.id }) {
                        featuredHomeRecipe = refreshedFeatured
                    } else {
                        featuredHomeRecipe = newValue.randomElement()
                    }
                } else if case .favorites = collectionType {
                    let favoriteRecipes = newValue.filter { model.isFavorite($0.id) }
                    if let selected = selectedFeaturedRecipe,
                       favoriteRecipes.contains(where: { $0.id == selected.id }) == false {
                        selectedFeaturedRecipe = favoriteRecipes.randomElement()
                    } else if selectedFeaturedRecipe == nil {
                        selectedFeaturedRecipe = favoriteRecipes.randomElement()
                    }
                } else if case .category(let category) = collectionType {
                    // Ensure the category view has a featured recipe once data arrives
                    let categoryRecipes = newValue.filter { $0.categoryID == category.id }
                    if let selected = selectedFeaturedRecipe,
                       categoryRecipes.contains(where: { $0.id == selected.id }) == false {
                        selectedFeaturedRecipe = categoryRecipes.randomElement()
                    } else if selectedFeaturedRecipe == nil {
                        selectedFeaturedRecipe = categoryRecipes.randomElement()
                    }
                } else if case .tag(let tag) = collectionType {
                    let tagRecipes = newValue.filter { $0.tagIDs.contains(tag.id) }
                    if let selected = selectedFeaturedRecipe,
                       tagRecipes.contains(where: { $0.id == selected.id }) == false {
                        selectedFeaturedRecipe = tagRecipes.randomElement()
                    } else if selectedFeaturedRecipe == nil {
                        selectedFeaturedRecipe = tagRecipes.randomElement()
                    }
                }
            }
            .onChange(of: searchText, initial: false) { _, newValue in
                handleSearchTextChange(newValue)
            }
            .onChange(of: searchScope) { _, _ in
                let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    searchResults = []
                    showingSearchResults = false
                } else {
                    showingSearchResults = true
                    searchResults = filteredRecipes(for: trimmed)
                }
            }
            .onChange(of: model.favoriteRecipeKeys) { _, _ in
                if case .favorites = collectionType {
                    let favoriteRecipes = model.recipes.filter { model.isFavorite($0.id) }
                    if let selected = selectedFeaturedRecipe,
                       favoriteRecipes.contains(where: { $0.id == selected.id }) == false {
                        selectedFeaturedRecipe = favoriteRecipes.randomElement()
                    } else if selectedFeaturedRecipe == nil {
                        selectedFeaturedRecipe = favoriteRecipes.randomElement()
                    }
                }

                let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    searchResults = []
                    showingSearchResults = false
                } else {
                    showingSearchResults = true
                    searchResults = filteredRecipes(for: trimmed)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .shareRevokedToast), perform: handleShareRevokedToast)
            .refreshable { await handleRefresh() }
            .sheet(isPresented: $showingOfflineNotice) { offlineNoticeSheet }
            .overlay { deletingOverlay }
            .toolbar {
                buildToolbar(
                    showsFeaturedHeader: shouldUseHeroNavigationChrome,
                    showInlineTitles: showInlineTitles
                )
            }
    }

    // MARK: - Event Handlers (extracted to simplify body)

    private func handleRecipeDeleted(_ notification: Notification) {
        if let _ = notification.object as? CKRecord.ID {
            Task {
                if case .favorites = collectionType {
                    await refreshFavoriteRecipes()
                } else if case .category = collectionType {
                    await refreshCategoryRecipes()
                } else if case .tag = collectionType {
                    await refreshTagRecipes()
                }
            }
        }
    }

    private func handleRecipeUpdated(_ notification: Notification) {
        if let _ = notification.object as? Recipe {
            Task { @MainActor in
                if case .favorites = collectionType {
                    await refreshFavoriteRecipes(skipCache: true)
                } else if case .category = collectionType {
                    await refreshCategoryRecipes(skipCache: true)
                } else if case .tag = collectionType {
                    await refreshTagRecipes(skipCache: true)
                } else if case .home = collectionType {
                    await loadRecipes(skipCache: true)
                }
            }
        } else if let _ = notification.object as? CKRecord.ID {
            Task { @MainActor in
                if case .favorites = collectionType {
                    await refreshFavoriteRecipes(skipCache: true)
                } else if case .category = collectionType {
                    await refreshCategoryRecipes(skipCache: true)
                } else if case .tag = collectionType {
                    await refreshTagRecipes(skipCache: true)
                } else if case .home = collectionType {
                    await loadRecipes(skipCache: true)
                }
            }
        }
    }

    private func handleSearchTextChange(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            showingSearchResults = false
            searchResults = []
            searchTask?.cancel()
        } else {
            let wasShowingSearchResults = showingSearchResults
            showingSearchResults = true
            if !wasShowingSearchResults {
                searchActivationScrollResetToken &+= 1
            }
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000) // 250ms debounce
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    searchResults = filteredRecipes(for: trimmed)
                    isSearching = false
                }
            }
        }
    }

    private func handleShareRevokedToast(_ notification: Notification) {
        if let name = notification.object as? String {
            revokedToastMessage = "Collection '\(name)' was revoked"
        } else {
            revokedToastMessage = "A shared collection was revoked"
        }
        withAnimation { showRevokedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { showRevokedToast = false }
        }
    }

    private func triggerFeelingLucky() {
        guard let recipe = luckyRecipePool.randomElement() else { return }
        NotificationCenter.default.post(name: .requestFeelingLucky, object: recipe)
    }

    private func handleRefresh() async {
        guard !isRefreshInFlight else { return }
        isRefreshInFlight = true
        showRefreshSpinner = true
        let start = Date()
        if model.canRetryCloudConnection {
            await model.retryCloudConnectionAndRefresh(skipRecipeCache: true)
        } else {
            await model.refreshSourcesAndCurrentContent(skipRecipeCache: true, forceProbe: true)
        }
        if showingSearchResults {
            performSearch()
        }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 0.8 {
            try? await Task.sleep(nanoseconds: UInt64((0.8 - elapsed) * 1_000_000_000))
        }
        showRefreshSpinner = false
        isRefreshInFlight = false
    }

    @MainActor
    private func updateTagAssignments(for tag: Tag, selectedIDs: [CKRecord.ID]) async -> String? {
        guard canEditTagAssignments else {
            return "Tagged recipes can’t be edited right now."
        }

        let selectedSet = Set(selectedIDs)
        let currentSelected = selectedRecipeIDs(for: tag)
        if currentSelected == selectedSet {
            return nil
        }

        for recipe in tagRecipeCandidates {
            let shouldBeTagged = selectedSet.contains(recipe.id)
            let isTagged = currentSelected.contains(recipe.id)
            guard shouldBeTagged != isTagged else { continue }

            var nextTagIDs = Set(recipe.tagIDs)
            if shouldBeTagged {
                nextTagIDs.insert(tag.id)
            } else {
                nextTagIDs.remove(tag.id)
            }

            let orderedTagIDs = Array(nextTagIDs).sorted {
                $0.recordName.localizedStandardCompare($1.recordName) == .orderedAscending
            }

            let success = await model.updateRecipeWithSteps(
                id: recipe.id,
                categoryId: nil,
                name: nil,
                recipeTime: nil,
                details: nil,
                image: nil,
                recipeSteps: nil,
                tagIDs: orderedTagIDs
            )

            if !success {
                return model.error ?? "Failed to update tagged recipes."
            }
        }

        await refreshTagRecipes(skipCache: true)
        return nil
    }

    private func initialLoadIfNeeded() async {
        if !hasLoadedInitially {
            isLoading = true
            hasLoadedInitially = true
            selectedFeaturedRecipe = nil
            featuredHomeRecipe = nil
            showingSearchResults = false
            searchResults = []
            searchText = ""
            searchTask?.cancel()
            await loadRecipes()
        }
    }

    private func handleCollectionTypeChange() async {
        if case .home = collectionType {
            // Reset home featured when returning home; keep category featured intact to avoid placeholder flicker.
            selectedFeaturedRecipe = nil
            featuredHomeRecipe = model.recipes.randomElement()
        } else if case .favorites = collectionType {
            featuredHomeRecipe = nil
            let favoriteRecipes = model.recipes.filter { model.isFavorite($0.id) }
            selectedFeaturedRecipe = favoriteRecipes.randomElement()
        } else if case .category(let category) = collectionType {
            // Update featured recipe for the new category from existing data
            featuredHomeRecipe = nil
            let categoryRecipes = model.recipes.filter { $0.categoryID == category.id }
            selectedFeaturedRecipe = categoryRecipes.randomElement()
        } else if case .tag(let tag) = collectionType {
            featuredHomeRecipe = nil
            let tagRecipes = model.recipes.filter { $0.tagIDs.contains(tag.id) }
            selectedFeaturedRecipe = tagRecipes.randomElement()
        }
        showingSearchResults = false
        searchResults = []
        searchText = ""
        searchTask?.cancel()
        #if os(iOS)
        // Keep category/tag/home switches consistent with search: always reset list position to top.
        searchActivationScrollResetToken &+= 1
        #endif
        // Don't reload data - it's already in model.recipes
        // Only reload on initial load or manual refresh
    }

    private var deletingOverlay: some View {
        Group {
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

    @ToolbarContentBuilder
    private func buildToolbar(showsFeaturedHeader: Bool, showInlineTitles: Bool) -> some ToolbarContent {
        if model.isLoadingCategories {
            ToolbarItem(placement: .navigation) {
                Button(action: {}) {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                .disabled(true)
            }
        } else if showRefreshSpinner {
            ToolbarItem(placement: .navigation) {
                Button(action: {}) {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                .disabled(true)
            }
        }

#if os(macOS)
        if showsFeaturedHeader && !showInlineTitles {
            ToolbarSpacer(.flexible)
        }
#endif

        if enableFeelingLucky {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    triggerFeelingLucky()
                } label: {
                    Image(systemName: "die.face.5")
                }
                .disabled(luckyRecipePool.isEmpty || isLoading)
                .accessibilityLabel("Feeling Lucky")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            sortToolbarMenu
        }

#if os(macOS)
        if isSearchFilterVisible {
            ToolbarItem(placement: .primaryAction) {
                searchScopeToolbarMenu
            }
        }
#endif

//#if DEBUG
//        ToolbarItem(placement: .primaryAction) {
//            debugMenu
//        }
//#endif

        if case .tag = collectionType, canEditTagAssignments {
#if os(macOS)
            ToolbarSpacer(.fixed)
#endif
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingTagRecipePicker = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Edit Tagged Recipes")
            }
        }

#if os(macOS)
        ToolbarItem(placement: .status) {
            offlineStatusIndicator
        }
#else
        ToolbarItem(placement: .navigationBarLeading) {
            offlineStatusIndicator
        }
#endif
    }
    
    private var mainContent: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !hasLoadedInitially || isLoading || (isFilteredCollection && featuredRecipe == nil && !recipes.isEmpty && !showingSearchResults) {
                        // Show loading spinner while data is loading OR while featured recipe is being selected (for categories)
                        VStack(spacing: 16) {
                            ProgressView()
                            Text(collectionType.loadingText)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    } else if shouldShowNoSourceState {
                        // Show message when no source is available
                        VStack(spacing: 16) {
                            Image(systemName:"book")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                            Text("Please add a Recipe Collection to continue")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text("Open Settings from the toolbar to create or select a collection.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    } else if shouldShowWelcomeState {
                        // Show welcome message when source exists but no recipes yet
                        VStack(spacing: 16) {
                            Text("👋")
                                .font(.system(size: 48))
                            Text("Welcome to iCook!")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Start by adding categories and recipes to get going")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    } else if shouldShowEmptyState {
                        // Centered empty state - replaces the entire scroll content area.
                        VStack(spacing: 16) {
                            Text(collectionType.emptyStateIcon)
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                            Text(collectionType.emptyStateText)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    } else {
                        if !isSearchActive, let featuredRecipe = featuredRecipe {
                            featuredRecipeHeader(featuredRecipe, baseHeight: proxy.size.height * 0.4)
                        }
                        recipesGridSection()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // Reset the scroll view when recipes change so category/home reflect updates.
                .id(AnyHashable(model.recipesRefreshTrigger))
            }
            .collectionFlexibleHeaderScrollView()
            .id(searchActivationScrollResetToken)
        }
    }
}

private struct CollectionFlexibleHeaderContentModifier: ViewModifier {
    let offset: CGFloat
    let baseHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(height: baseHeight - offset)
            .padding(.bottom, offset)
            .offset(y: offset)
    }
}

private struct CollectionFlexibleHeaderScrollViewModifier: ViewModifier {
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                min(geometry.contentOffset.y + geometry.contentInsets.top, 0)
            } action: { _, newOffset in
                offset = newOffset
            }
            .environment(\.collectionFlexibleHeaderOffset, offset)
    }
}

private struct CollectionFlexibleHeaderOffsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private extension EnvironmentValues {
    var collectionFlexibleHeaderOffset: CGFloat {
        get { self[CollectionFlexibleHeaderOffsetKey.self] }
        set { self[CollectionFlexibleHeaderOffsetKey.self] = newValue }
    }
}

private struct CollectionFlexibleHeaderContentEnvironmentModifier: ViewModifier {
    @Environment(\.collectionFlexibleHeaderOffset) private var offset
    let baseHeight: CGFloat

    func body(content: Content) -> some View {
        content.modifier(CollectionFlexibleHeaderContentModifier(offset: offset, baseHeight: baseHeight))
    }
}

private extension ScrollView {
    func collectionFlexibleHeaderScrollView() -> some View {
        modifier(CollectionFlexibleHeaderScrollViewModifier())
    }
}

private extension View {
    func collectionFlexibleHeaderContent(baseHeight: CGFloat) -> some View {
        modifier(CollectionFlexibleHeaderContentEnvironmentModifier(baseHeight: baseHeight))
    }
}

// MARK: - View Modifiers Extension
private struct ToastModifier: ViewModifier {
    @Binding var isPresented: Bool
    let message: String
    
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if isPresented {
                    Text(message)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .shadow(radius: 6)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
    }
}

private extension View {
    func toast(isPresented: Binding<Bool>, message: String) -> some View {
        modifier(ToastModifier(isPresented: isPresented, message: message))
    }
}

extension View {
    @ViewBuilder
    func applyNavigationModifiers(
        collectionType: RecipeCollectionType,
        showingSearchResults: Bool,
        showsFeaturedHeader: Bool,
        showInlineTitles: Bool
    ) -> some View {
        if showsFeaturedHeader && !showInlineTitles {
            self
                .navigationTitle("")
                .toolbar(removing: .title)
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
        } else {
            self
                .navigationTitle(showingSearchResults ? "Search Results" : collectionType.navigationTitle)
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
        }
    }
    
    func applyLifecycleModifiers(
        searchTask: Binding<Task<Void, Never>?>
    ) -> some View {
        self
            .onDisappear {
                searchTask.wrappedValue?.cancel()
            }
    }
    
    func applyAlertModifiers(
        error: Binding<String?>,
        deletingRecipe: Binding<Recipe?>,
        showingDeleteAlert: Binding<Bool>,
        onConfirmDelete: @escaping (Recipe) -> Void
    ) -> some View {
        self
            .alert("Error", isPresented: .init(
                get: { error.wrappedValue != nil },
                set: { if !$0 { error.wrappedValue = nil } }
            )) {
                Button("OK") { error.wrappedValue = nil }
            } message: {
                Text(error.wrappedValue ?? "")
            }
            .alert("Delete Recipe", isPresented: showingDeleteAlert) {
                Button("Delete", role: .destructive) {
                    if let recipe = deletingRecipe.wrappedValue {
                        onConfirmDelete(recipe)
                    }
                }
                Button("Cancel", role: .cancel) {
                    deletingRecipe.wrappedValue = nil
                }
            } message: {
                if let recipe = deletingRecipe.wrappedValue {
                    Text("Are you sure you want to delete '\(recipe.name)'? This action cannot be undone.")
                }
            }
    }
    
    func applySheetModifiers(
        editingRecipe: Binding<Recipe?>,
        showNewSourceSheet: Binding<Bool>,
        newSourceName: Binding<String>,
        model: AppViewModel
    ) -> some View {
        self
            .sheet(item: editingRecipe) { recipe in
                AddEditRecipeView(editingRecipe: recipe)
                    .environmentObject(model)
            }
            .sheet(isPresented: showNewSourceSheet) {
                NewSourceSheet(
                    isPresented: showNewSourceSheet,
                    sourceName: newSourceName
                )
                .environmentObject(model)
            }
    }
}
