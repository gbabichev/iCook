//
//  RecipeCollectionType.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI
import CloudKit

enum RecipeCollectionType: Equatable {
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
    
    var sectionTitle: String {
        switch self {
        case .home:
            return "More Recipes"
        case .category(let category):
            return "All \(category.name)"
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
    
    // Add this for proper comparison
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
}

struct RecipeCollectionView: View {
    let collectionType: RecipeCollectionType
    @EnvironmentObject private var model: AppViewModel

    // Toolbar state - passed from parent or locally managed
    @State private var showingAddRecipe = false
    @State private var showNewSourceSheet = false
    @State private var newSourceName = ""
    @State private var isDebugOperationInProgress = false

    // State for category-specific recipes
    @State private var categoryRecipes: [Recipe] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadingTask: Task<Void, Never>?
    @State private var currentLoadTask: Task<Void, Never>?
    @State private var refreshTrigger = UUID()
    @State private var editingRecipe: Recipe?
    @State private var deletingRecipe: Recipe?
    @State private var showingDeleteAlert = false
    @State private var showingOfflineNotice = false
    @State private var isDeleting = false
    @State private var selectedFeaturedRecipe: Recipe?
    @State private var hasLoadedInitially = false
    
    // Search state
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var searchResults: [Recipe] = []
    @State private var isSearching = false
    @State private var showingSearchResults = false
    @State private var isRefreshing = false

    
    // Adaptive columns with consistent spacing - account for spacing in minimum width
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 15)]
    
    // Computed property to get the appropriate recipe list
    private var recipes: [Recipe] {
        if showingSearchResults {
            return searchResults
        }

        switch collectionType {
        case .home:
            return model.randomRecipes
        case .category:
            return categoryRecipes
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
            return recipes.first
        case .category:
            // Only return the stored selection if it exists and is valid
            if let selected = selectedFeaturedRecipe,
               recipes.contains(where: { $0.id == selected.id }) {
                return selected
            }
            return nil // Don't select here - do it in loadCategoryRecipes
        }
    }

    // Remaining recipes (excluding featured)
    private var remainingRecipes: [Recipe] {
        if showingSearchResults {
            return recipes
        }
        
        switch collectionType {
        case .home:
            return Array(recipes.dropFirst())
        case .category:
            guard let featured = featuredRecipe else {
                return recipes
            }
            return recipes.filter { $0.id != featured.id }
        }
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

    private var sourceMenu: some View {
        Menu {
            if let source = model.currentSource {
                Section(source.name) {
                    ForEach(model.sources, id: \.id) { s in
                        Button {
                            Task {
                                await model.selectSource(s)
                            }
                        } label: {
                            HStack {
                                Text(s.name)
                                if model.currentSource?.id == s.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }

                    Divider()

                    Button(action: { showNewSourceSheet = true }) {
                        Label("New Collection", systemImage: "plus")
                    }
                }
            }
        } label: {
            Image(systemName: "cloud")
        }
        .accessibilityLabel("Collections")
    }

    private var debugMenu: some View {
        Menu {
            Section("Debug") {
                Button(role: .destructive) {
                    isDebugOperationInProgress = true
                    Task {
                        await model.debugDeleteAllSourcesAndReset()
                        if model.currentSource != nil {
                            await model.loadCategories()
                            await model.loadRandomRecipes()
                        }
                        isDebugOperationInProgress = false
                    }
                } label: {
                    Label("Delete all Sources & Restart", systemImage: "trash.fill")
                }
            }
        } label: {
            Image(systemName: "ladybug")
        }
    }

    // For Home view
    init() {
        self.collectionType = .home
    }
    
    // For Category view
    init(category: Category) {
        self.collectionType = .category(category)
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
                    NavigationLink(destination: RecipeDetailView(recipe: recipe)) {
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
                }
                .padding(.bottom, 32)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .frame(height: 200)
                
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: 350)
                    .clipped()
                    .ignoresSafeArea(edges: .top)
                    .backgroundExtensionEffect()
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 8) {
                            Text(recipe.name)
                                .font(.largeTitle)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                            Text("\(recipe.recipeTime) minutes")
                                .font(.headline)
                                .foregroundColor(.white)
                                .opacity(0.8)
                            // Clickable button within the non-clickable header
                            NavigationLink(destination: RecipeDetailView(recipe: recipe)) {
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
                        }
                        .padding(.bottom, 32)
                        .padding(.horizontal, 20)
                    }
                
            case .failure:
                headerPlaceholder {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Image not available")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text(recipe.name)
                            .font(.title2)
                            .fontWeight(.bold)
                    }
                    .padding()
                }
                
            @unknown default:
                EmptyView()
            }
        }
    }
    
    @ViewBuilder
    private func headerPlaceholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            //content()
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
                        NavigationLink(destination: RecipeDetailView(recipe: recipe)) {
                            RecipeLargeButtonWithState(recipe: recipe, index: index)
                        }
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
            try? await Task.sleep(nanoseconds: 800_000_000) // 800ms minimum refresh time
        }
        
        await currentLoadTask?.value
    }
    
    @MainActor
    private func loadCategoryRecipes(_ category: Category, skipCache: Bool = false) async {
        guard !Task.isCancelled else { return }
        
        isLoading = true
        error = nil
        defer { isLoading = false }

        await model.loadRecipesForCategory(category.id, skipCache: skipCache)
        categoryRecipes = model.recipes

        // Select featured recipe AFTER setting categoryRecipes
        if !categoryRecipes.isEmpty {
            selectedFeaturedRecipe = categoryRecipes.randomElement()
            print("Selected featured recipe: \(selectedFeaturedRecipe?.name ?? "none")")
        }

        if let modelError = model.error {
            self.error = modelError
        }
    }
    
    @MainActor
    private func refreshCategoryRecipes(skipCache: Bool = false) async {
        guard case .category(let category) = collectionType else { return }
        await loadCategoryRecipes(category, skipCache: skipCache)
        refreshTrigger = UUID() // Force view refresh
    }
    
    private func handleRecipeDeleted(_ recipeId: Int) {
        Task {
            if case .category = collectionType {
                await refreshCategoryRecipes()
            }
            // Home view will automatically update via model.randomRecipes
        }
    }
    
    @MainActor
    private func deleteRecipe(_ recipe: Recipe) async {
        isDeleting = true
        let success = await model.deleteRecipeWithUIFeedback(id: recipe.id)
        isDeleting = false
        
        if success {
            // Remove from local category array for immediate UI update
            categoryRecipes.removeAll { $0.id == recipe.id }
        }
        
        deletingRecipe = nil
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

        isSearching = true
        showingSearchResults = true

        defer { isSearching = false }

        await model.searchRecipes(query: query)
        searchResults = model.recipes

        if let modelError = model.error {
            print("Search error: \(modelError)")
        }
    }
    
    // MARK: - UI View

    private var shouldShowNoSourceState: Bool {
        isHome && model.currentSource == nil && !showingSearchResults
    }

    private var shouldShowWelcomeState: Bool {
        isHome && model.currentSource != nil && model.randomRecipes.isEmpty && !isLoading && !showingSearchResults
    }

    private var shouldShowEmptyState: Bool {
        !isLoading && recipes.isEmpty && !(isHome && model.randomRecipes.isEmpty) && !showingSearchResults
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
            .applyLifecycleModifiers(collectionType: collectionType, hasLoadedInitially: $hasLoadedInitially, selectedFeaturedRecipe: $selectedFeaturedRecipe, showingSearchResults: $showingSearchResults, searchResults: $searchResults, searchText: $searchText, searchTask: $searchTask)
            .applyDataModifiers(categoryRecipes: $categoryRecipes, selectedFeaturedRecipe: $selectedFeaturedRecipe, model: model, collectionType: collectionType)
            .applyAlertModifiers(
                error: $error,
                deletingRecipe: $deletingRecipe,
                showingDeleteAlert: $showingDeleteAlert
            ) { recipe in
                Task {
                    await deleteRecipe(recipe)
                }
            }
            .applySheetModifiers(editingRecipe: $editingRecipe, showingAddRecipe: $showingAddRecipe, showNewSourceSheet: $showNewSourceSheet, newSourceName: $newSourceName, categoryIdIfApplicable: categoryIdIfApplicable, model: model)
            .onReceive(NotificationCenter.default.publisher(for: .recipeDeleted)) { notification in
                if let deletedRecipeId = notification.object as? CKRecord.ID {
                    categoryRecipes.removeAll { $0.id == deletedRecipeId }
                    Task {
                        if case .category = collectionType {
                            await refreshCategoryRecipes()
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .recipeUpdated)) { notification in
                if notification.object is CKRecord.ID {
                    Task {
                        if case .category = collectionType {
                            await refreshCategoryRecipes(skipCache: true)
                        } else if case .home = collectionType {
                            await loadRecipes(skipCache: true)
                        }
                    }
                }
            }
            .task {
                if !hasLoadedInitially {
                    hasLoadedInitially = true
                    selectedFeaturedRecipe = nil
                    showingSearchResults = false
                    searchResults = []
                    searchText = ""
                    searchTask?.cancel()
                    await loadRecipes()
                }
            }
            .onChange(of: collectionType) { _, _ in
                Task {
                    selectedFeaturedRecipe = nil
                    showingSearchResults = false
                    searchResults = []
                    searchText = ""
                    searchTask?.cancel()
                    await loadRecipes()
                }
            }
            .task(id: model.randomRecipes.count) {
                if case .home = collectionType {
                    // No need to reload
                }
            }
            .refreshable {
                isRefreshing = true
                let start = Date()
                if showingSearchResults {
                    performSearch()
                } else {
                    await loadRecipes(skipCache: true)
                }
                let elapsed = Date().timeIntervalSince(start)
                if elapsed < 0.8 {
                    try? await Task.sleep(nanoseconds: UInt64((0.8 - elapsed) * 1_000_000_000))
                }
                isRefreshing = false
            }
            .sheet(isPresented: $showingOfflineNotice) {
                offlineNoticeSheet
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
            .overlay(alignment: .center) {
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddRecipe = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(model.isOfflineMode || !hasActiveCollection)
                    .help(model.isOfflineMode ? "Connect to iCloud to add recipes" : (!hasActiveCollection ? "Create a collection first" : "Add Recipe"))
                    .accessibilityLabel("Add Recipe")
                }
//                ToolbarItem(placement: .primaryAction) {
//                    sourceMenu
//                }
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
                //ToolbarSpacer(.flexible)
            }
    }

    private var mainContent: some View {
        Group {
            if isLoading || (isCategory && featuredRecipe == nil && !categoryRecipes.isEmpty) {
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        // Featured header image
                        if let featuredRecipe = featuredRecipe {
                            featuredRecipeHeader(featuredRecipe)
                        } else if showingSearchResults {
                            Spacer()
                                .frame(height: 20)
                        }
                        // Recipes grid section
                        recipesGridSection()
                    }
                }
                .safeAreaInset(edge: .top) {
                    if isRefreshing {
                        Color.clear.frame(height: 50)
                    }
                }
                .ignoresSafeArea(edges: .top)
            }
        }
    }
}

// MARK: - View Modifiers Extension

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
    }

    func applyLifecycleModifiers(
        collectionType: RecipeCollectionType,
        hasLoadedInitially: Binding<Bool>,
        selectedFeaturedRecipe: Binding<Recipe?>,
        showingSearchResults: Binding<Bool>,
        searchResults: Binding<[Recipe]>,
        searchText: Binding<String>,
        searchTask: Binding<Task<Void, Never>?>
    ) -> some View {
        self
            .onDisappear {
                searchTask.wrappedValue?.cancel()
            }
    }

    func applyDataModifiers(
        categoryRecipes: Binding<[Recipe]>,
        selectedFeaturedRecipe: Binding<Recipe?>,
        model: AppViewModel,
        collectionType: RecipeCollectionType
    ) -> some View {
        self
            .onChange(of: model.recipes) { _, newRecipes in
                if case .category = collectionType {
                    categoryRecipes.wrappedValue = newRecipes
                }
            }
            .onChange(of: categoryRecipes.wrappedValue) { _, newRecipes in
                if selectedFeaturedRecipe.wrappedValue == nil ||
                   !newRecipes.contains(where: { $0.id == selectedFeaturedRecipe.wrappedValue?.id }) {
                    selectedFeaturedRecipe.wrappedValue = newRecipes.isEmpty ? nil : newRecipes.randomElement()
                }
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
