//
//  RecipeCollectionType.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI
import CloudKit

enum RecipeCollectionType: Hashable {
    case home
    case category(Category)
    
    var navigationTitle: String {
        switch self {
        case .home:
            return ""
        case .category(let category):
            return category.name
        }
    }
    
    var loadingText: String {
        switch self {
        case .home:
            return "Loading featured recipe..."
        case .category(let category):
            return "Loading \(category.name.lowercased()) recipes..."
        }
    }
    
    var emptyStateText: String {
        switch self {
        case .home:
            return "No recipes found"
        case .category(let category):
            return "No \(category.name.lowercased()) recipes found"
        }
    }
    
    var emptyStateIcon: String {
        switch self {
        case .home:
            return "🍴"
        case .category(let category):
            return category.icon
        }
    }
    
    static func == (lhs: RecipeCollectionType, rhs: RecipeCollectionType) -> Bool {
        switch (lhs, rhs) {
        case (.home, .home):
            return true
        case (.category(let lhsCat), .category(let rhsCat)):
            return lhsCat.id == rhsCat.id
        default:
            return false
        }
    }
    
    func hash(into hasher: inout Hasher) {
        switch self {
        case .home:
            hasher.combine("home")
        case .category(let category):
            hasher.combine("category")
            hasher.combine(category.id)
        }
    }
}

struct RecipeCollectionView: View {
    let collectionType: RecipeCollectionType
    @EnvironmentObject private var model: AppViewModel
    
    // Toolbar state - passed from parent or locally managed
    @State private var showingAddRecipe = false
    @State private var showNewSourceSheet = false
    @State private var newSourceName = ""
    @State private var isDebugOperationInProgress = false
    
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
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var searchResults: [Recipe] = []
    @State private var isSearching = false
    @State private var showingSearchResults = false
    @State private var isRefreshing = false
    @State private var showRevokedToast = false
    @State private var revokedToastMessage = ""
    @State private var featuredHomeRecipe: Recipe?
    
    
    // Adaptive columns with consistent spacing - account for spacing in minimum width
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 15)]
    
    // Computed property to get the appropriate recipe list
    private var recipes: [Recipe] {
        if showingSearchResults {
            return searchResults
        }
        
        switch collectionType {
        case .home:
            return model.recipes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .category(let category):
            return model.recipes
                .filter { $0.categoryID == category.id }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
    
    //    @ViewBuilder
    //    private var offlineStatusIndicator: some View {
    //        if model.isOfflineMode {
    //            Label("Offline Mode", systemImage: "wifi.slash")
    //                .font(.caption)
    //                .foregroundStyle(.orange)
    //        }
    //    }
    
    @ViewBuilder
    private var offlineStatusIndicator: some View {
        if model.isOfflineMode {
            Button {
                showingOfflineNotice = true
            } label: {
                Image(systemName: "wifi.slash")
            }
            .foregroundStyle(.red)
            .accessibilityLabel("Offline mode")
        }
    }
    
    // Featured recipe (first or stored random)
    private var featuredRecipe: Recipe? {
        if showingSearchResults {
            return nil // no featured recipes during search.
        }
        
        switch collectionType {
        case .home:
            return featuredHomeRecipe ?? recipes.randomElement()
        case .category:
            // Resolve the stored selection against the latest shared recipes so name/image changes show up.
            if let selected = selectedFeaturedRecipe,
               let current = recipes.first(where: { $0.id == selected.id }) {
                return current
            }
            return nil // Don't select here - do it in loadCategoryRecipes
        }
    }
    
    // Remaining recipes (excluding featured)
    private var remainingRecipes: [Recipe] {
        if showingSearchResults {
            return recipes
        }
        
        return recipes
    }
    
    // Check if we're showing a category
    private var isCategory: Bool {
        if case .category = collectionType {
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
    
    private var isSearchActive: Bool {
        showingSearchResults || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private func logSearchState(_ context: String) {
        printD("SearchState [\(context)]: text='\(searchText)', showingSearchResults=\(showingSearchResults), isSearchActive=\(isSearchActive), collectionType=\(collectionType.navigationTitle)")
    }
    
    // Get category ID if viewing a category, nil if viewing home
    private var categoryIdIfApplicable: CKRecord.ID? {
        if case .category(let category) = collectionType {
            return category.id
        }
        return nil
    }
    
    private var hasActiveCollection: Bool {
        model.currentSource != nil
    }
    
    // MARK: - Toolbar Views
    
    private var debugMenu: some View {
        Menu {
            Section("Debug") {
                Button {
                    print("debug")
                } label: {
                    Label("Print debug", systemImage: "terminal")
                }
                
                Button(role: .destructive) {
                    isDebugOperationInProgress = true
                    Task {
                        await model.debugNukeOwnedData()
                        isDebugOperationInProgress = false
                    }
                } label: {
                    Label("Nuke owned CloudKit data", systemImage: "bolt.horizontal.icloud.fill")
                }
            }
        } label: {
            Image(systemName: "ladybug")
        }
    }
    
    // Initializers
    init(collectionType: RecipeCollectionType = .home) {
        self.collectionType = collectionType
    }
    
    // MARK: - Header Views
    
    @ViewBuilder
    private func featuredRecipeHeader(_ recipe: Recipe) -> some View {
        AsyncImage(url: recipe.imageURL) { phase in
            switch phase {
            case .empty:
                VStack(spacing: 8) {
                    
                    Image(systemName: "fork.knife.circle")
                        .font(.system(size: 80))
                        .padding(.top, 100)
                    
                    Text(recipe.name)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("\(recipe.recipeTime) minutes")
                        .font(.headline)
                        .opacity(0.8)
                    
                    // Clickable button within the non-clickable header
                    NavigationLink(value: recipe) {
                        HStack {
                            Image(systemName: "eye")
                            Text("View Recipe")
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.black.opacity(0.6))
                        .cornerRadius(25)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        model.saveLastViewedRecipe(recipe)
                    })
                }
                .padding(.bottom, 32)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .frame(height: 300)
                
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 100, maxHeight: 350)
                    .clipped()
                    .ignoresSafeArea(edges: .top)
                    .backgroundExtensionEffect()
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
                                // Clickable button within the non-clickable header
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
                                    model.saveLastViewedRecipe(recipe)
                                })
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
                
            case .failure:
                headerPlaceholder()
                
            @unknown default:
                EmptyView()
            }
        }
    }
    
    @ViewBuilder
    private func headerPlaceholder() -> some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: 350)
        .backgroundExtensionEffect()
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
                            RecipeLargeButtonWithState(recipe: recipe, index: index)
                        }
                        .onAppear {
                            if let path = recipe.cachedImagePath {
                                let exists = FileManager.default.fileExists(atPath: path)
                                printD("[ImagePath] grid appear: \(recipe.name) path=\(path) exists=\(exists)")
                            } else {
                                printD("[ImagePath] grid appear: \(recipe.name) path=nil")
                            }
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            model.saveLastViewedRecipe(recipe)
                        })
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                editingRecipe = recipe
                            } label: {
                                Label("Edit Recipe", systemImage: "pencil")
                            }
                            .disabled(model.isOfflineMode)
                            
                            Button(role: .destructive) {
                                deletingRecipe = recipe
                                showingDeleteAlert = true
                            } label: {
                                Label("Delete Recipe", systemImage: "trash")
                            }
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
            case .category(let category):
                await loadCategoryRecipes(category, skipCache: skipCache)
            }
        }
        
        await currentLoadTask?.value
    }
    
    @MainActor
    private func loadHomeRecipes(skipCache: Bool = false) async {
        currentLoadTask?.cancel()
        
        currentLoadTask = Task {
            await model.loadRandomRecipes(skipCache: skipCache)
            featuredHomeRecipe = model.recipes.randomElement()
            try? await Task.sleep(nanoseconds: 800_000_000) // 800ms minimum refresh time
        }
        
        await currentLoadTask?.value
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
    private func deleteRecipe(_ recipe: Recipe) async {
        isDeleting = true
        let success = await model.deleteRecipeWithUIFeedback(id: recipe.id)
        isDeleting = false
        
        if success {
            // Model.deleteRecipe already updates model.recipes; view will filter it out.
        }

        deletingRecipe = nil
    }
    
    private func logImagePath(_ recipe: Recipe, context: String) {
        if let path = recipe.cachedImagePath {
            let exists = FileManager.default.fileExists(atPath: path)
            printD("[ImagePath] \(context): \(recipe.name) path=\(path) exists=\(exists)")
        } else {
            printD("[ImagePath] \(context): \(recipe.name) path=nil")
        }
    }
    
    // MARK: - Search Logic
    
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
        
        // Purely local filter for speed and stability
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [Recipe]
        if case .category(let category) = collectionType {
            base = model.recipes.filter { $0.categoryID == category.id }
        } else {
            base = model.recipes
        }
        let filtered = base.filter { recipe in
            recipe.name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        searchResults = filtered
        isSearching = false
        
        if let modelError = model.error {
            print("Search error: \(modelError)")
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
    
    private var offlineNoticeSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("You are offline")
                .font(.headline)
            Text("Connect to the internet to sync recipes with iCloud and enable recipe editing.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("Got it") {
                showingOfflineNotice = false
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(minWidth: 280)
    }
    
    var body: some View {
        mainContent
            .applySearchModifiers(searchText: $searchText, searchTask: $searchTask, showingSearchResults: $showingSearchResults, searchResults: $searchResults)
            .applyNavigationModifiers(collectionType: collectionType, showingSearchResults: showingSearchResults)
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
            .applySheetModifiers(editingRecipe: $editingRecipe, showingAddRecipe: $showingAddRecipe, showNewSourceSheet: $showNewSourceSheet, newSourceName: $newSourceName, categoryIdIfApplicable: categoryIdIfApplicable, model: model)
            .padding(.top, isSearchActive ? 0 : 0)
            .ignoresSafeArea(edges: isSearchActive ? [] : .top)
            .toast(isPresented: $showRevokedToast, message: revokedToastMessage)
            .onReceive(NotificationCenter.default.publisher(for: .recipeDeleted), perform: handleRecipeDeleted)
            .onReceive(NotificationCenter.default.publisher(for: .recipeUpdated), perform: handleRecipeUpdated)
#if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: .refreshRequested)) { _ in
                Task { await handleRefresh() }
            }
#endif
            .task { await initialLoadIfNeeded() }
            .onChange(of: collectionType) { _, _ in Task { await handleCollectionTypeChange() } }
            .task(id: model.recipes.count) {
                if case .home = collectionType {
                    // No need to reload; featured selection handled by changes below
                }
            }
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search recipes")
            .onSubmit(of: .search) { performSearch(); logSearchState("onSubmit") }
            .onChange(of: model.recipes) { _, newValue in
                if let first = newValue.first {
                    logImagePath(first, context: "onChange model.recipes first")
                }
            }
            .onChange(of: model.recipes) { _, newValue in
                if case .home = collectionType {
                    featuredHomeRecipe = newValue.randomElement()
                }
            }
            .onChange(of: searchText, initial: false) { oldValue, newValue in
                // oldValue unused but keeps us on the new API signature for macOS 14+
                _ = oldValue
                handleSearchTextChange(newValue)
            }
            .onReceive(NotificationCenter.default.publisher(for: .shareRevokedToast), perform: handleShareRevokedToast)
            .refreshable { await handleRefresh() }
            .sheet(isPresented: $showingOfflineNotice) { offlineNoticeSheet }
            .overlay { deletingOverlay }
            .overlay(alignment: .center) { debugOverlay }
            .toolbar { buildToolbar() }
    }

    // MARK: - Event Handlers (extracted to simplify body)

    private func handleRecipeDeleted(_ notification: Notification) {
        if let deletedRecipeId = notification.object as? CKRecord.ID {
            Task {
                if case .category = collectionType {
                    await refreshCategoryRecipes()
                }
            }
        }
    }

    private func handleRecipeUpdated(_ notification: Notification) {
        if let updatedRecipe = notification.object as? Recipe {
            Task { @MainActor in
                if case .category = collectionType {
                    await refreshCategoryRecipes(skipCache: true)
                } else if case .home = collectionType {
                    await loadRecipes(skipCache: true)
                }
            }
        } else if let _ = notification.object as? CKRecord.ID {
            Task { @MainActor in
                if case .category = collectionType {
                    await refreshCategoryRecipes(skipCache: true)
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
            logSearchState("onChange cleared")
        } else {
            showingSearchResults = true
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000) // 250ms debounce
                guard !Task.isCancelled else { return }
                await performSearch(with: trimmed)
            }
            logSearchState("onChange typing")
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

    private func handleRefresh() async {
        guard !isRefreshInFlight else { return }
        isRefreshInFlight = true
        showRefreshSpinner = true
        isRefreshing = true
        let start = Date()
        if showingSearchResults {
            performSearch()
        } else {
            // Unified refresh: always load all recipes; categories filter locally.
            await loadHomeRecipes(skipCache: true)
        }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 0.8 {
            try? await Task.sleep(nanoseconds: UInt64((0.8 - elapsed) * 1_000_000_000))
        }
        isRefreshing = false
        showRefreshSpinner = false
        isRefreshInFlight = false
    }

    private func initialLoadIfNeeded() async {
        if !hasLoadedInitially {
            hasLoadedInitially = true
            selectedFeaturedRecipe = nil
            if case .home = collectionType {
                featuredHomeRecipe = model.recipes.randomElement()
            }
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
        } else {
            featuredHomeRecipe = nil
        }
        showingSearchResults = false
        searchResults = []
        searchText = ""
        searchTask?.cancel()
        await loadRecipes()
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

    private var debugOverlay: some View {
        Group {
            if isDebugOperationInProgress {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5, anchor: .center)
                        Text("Resetting sources...")
                            .font(.headline)
                    }
                    .padding(32)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .transition(.opacity)
            }
        }
    }

    @ToolbarContentBuilder
    private func buildToolbar() -> some ToolbarContent {
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
        
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingAddRecipe = true
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .disabled(model.isOfflineMode || !hasActiveCollection || model.categories.isEmpty)
            .help(
                model.isOfflineMode
                ? "Connect to iCloud to add recipes"
                : (!hasActiveCollection
                   ? "Create a collection first"
                   : (model.categories.isEmpty ? "Add a category first" : "Add Recipe"))
            )
            .accessibilityLabel("Add Recipe")
        }
        
#if DEBUG
        ToolbarItem(placement: .primaryAction) {
            debugMenu
        }
#endif
        
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
        Group {
            if isLoading || (isCategory && featuredRecipe == nil && !recipes.isEmpty && !showingSearchResults) {
                // Show loading spinner while data is loading OR while featured recipe is being selected (for categories)
                VStack(spacing: 16) {
                    ProgressView()
                    Text(collectionType.loadingText)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shouldShowNoSourceState {
                // Show message when no source is available
                VStack(spacing: 16) {
                    Image(systemName:"book")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Please add a Recipe Collection to continue")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Tap the book icon in the toolbar to create or select a source.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shouldShowEmptyState {
                // Centered empty state - replaces the entire scroll view
                VStack(spacing: 16) {
                    Text(collectionType.emptyStateIcon)
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(collectionType.emptyStateText)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Normal scroll content
                if isSearchActive {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            recipesGridSection()
                        }
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            // Featured header image
                            if let featuredRecipe = featuredRecipe {
                                featuredRecipeHeader(featuredRecipe)
                            }
                            // Recipes grid section
                            recipesGridSection()
                        }
                        // Reset the scroll view when recipes change so category/home reflect updates.
                        .id(AnyHashable(model.recipesRefreshTrigger))
                    }
                    .safeAreaInset(edge: .top) {
                        if isRefreshing {
                            Color.clear.frame(height: 50)
                        }
                    }
                }
            }
        }
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
    func applySearchModifiers(
        searchText: Binding<String>,
        searchTask: Binding<Task<Void, Never>?>,
        showingSearchResults: Binding<Bool>,
        searchResults: Binding<[Recipe]>
    ) -> some View {
        self
            .onSubmit(of: .search) {
                if !searchText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Perform search here - would need access to performSearch function
                }
            }
            .onChange(of: searchText.wrappedValue) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    showingSearchResults.wrappedValue = false
                    searchResults.wrappedValue = []
                    searchTask.wrappedValue?.cancel()
                }
            }
    }
    
    func applyNavigationModifiers(collectionType: RecipeCollectionType, showingSearchResults: Bool) -> some View {
        self
            .navigationTitle(showingSearchResults ? "Search Results" : collectionType.navigationTitle)
#if os(iOS)
            .navigationBarTitleDisplayMode(showingSearchResults ? .inline : .automatic)
#endif
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
        showingAddRecipe: Binding<Bool>,
        showNewSourceSheet: Binding<Bool>,
        newSourceName: Binding<String>,
        categoryIdIfApplicable: CKRecord.ID?,
        model: AppViewModel
    ) -> some View {
        self
            .sheet(item: editingRecipe) { recipe in
                AddEditRecipeView(editingRecipe: recipe)
                    .environmentObject(model)
            }
            .sheet(isPresented: showingAddRecipe) {
                AddEditRecipeView(preselectedCategoryId: categoryIdIfApplicable)
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
