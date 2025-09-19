//
//  RecipeCollectionType.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI

enum RecipeCollectionType: Equatable {
    case home
    case category(Category)
    
    var title: String {
        switch self {
        case .home:
            return "iCook"
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
            return "fork.knife"
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
    @State private var isDeleting = false
    @State private var selectedFeaturedRecipe: Recipe?


    
    // Adaptive columns with consistent spacing - account for spacing in minimum width
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 15)]
    
    // Computed property to get the appropriate recipe list
    private var recipes: [Recipe] {
        switch collectionType {
        case .home:
            return model.randomRecipes
        case .category:
            return categoryRecipes
        }
    }
    
    // Featured recipe (first or stored random)
    private var featuredRecipe: Recipe? {
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
                headerPlaceholder {
                    ProgressView()
                        .scaleEffect(1.5)
                }
                
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: 350)
                    .clipped()
                    .backgroundExtensionEffect()
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 8) {
                            Text(recipe.name)
                                .font(.largeTitle)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                            Text("\(recipe.recipe_time) minutes")
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
    private func loadingHeader() -> some View {
        headerPlaceholder {
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                Text(collectionType.loadingText)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    @ViewBuilder
    private func emptyStateHeader() -> some View {
        headerPlaceholder {
            VStack(spacing: 16) {
                Image(systemName: collectionType.emptyStateIcon)
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(collectionType.emptyStateText)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    @ViewBuilder
    private func headerPlaceholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            content()
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: 350)
        .backgroundExtensionEffect()
    }
    
    // MARK: - Recipes Grid Section
    
    @ViewBuilder
    private func recipesGridSection() -> some View {
        if !recipes.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(collectionType.sectionTitle)
                    .font(.title2)
                    .bold()
                    .padding(.top, 20)
                    .padding(.leading, 15)
                
                if remainingRecipes.isEmpty && recipes.count == 1 && isCategory {
                    Text("This is the only recipe in this category")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 15)
                } else if remainingRecipes.isEmpty {
                    ProgressView("Loading recipes...")
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 15) {
                        ForEach(remainingRecipes) { recipe in
                            NavigationLink(destination: RecipeDetailView(recipe: recipe)) {
                                RecipeLargeButton(recipe: recipe)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    editingRecipe = recipe
                                } label: {
                                    Label("Edit Recipe", systemImage: "pencil")
                                }
                                
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
                }
            }
        }
    }
    
    
    
    // MARK: - Loading Logic
    
    @MainActor
    private func loadRecipes() async {
        // Cancel any existing task first
        currentLoadTask?.cancel()
        
        currentLoadTask = Task {
            switch collectionType {
            case .home:
                await loadHomeRecipes()
            case .category(let category):
                await loadCategoryRecipes(category)
            }
        }
        
        await currentLoadTask?.value
    }
    
    @MainActor
    private func loadHomeRecipes() async {
        currentLoadTask?.cancel()
        
        currentLoadTask = Task {
            await model.loadRandomRecipes()
        }
        
        await currentLoadTask?.value
    }
    
    @MainActor
    private func loadCategoryRecipes(_ category: Category) async {
        guard !Task.isCancelled else { return }
        
        isLoading = true
        error = nil
        defer { isLoading = false }
        
        do {
            print("Loading recipes for category: \(category.name) (ID: \(category.id))")
            let recipes = try await APIClient.fetchRecipes(categoryID: category.id, page: 1, limit: 100)
            
            guard !Task.isCancelled else { return }
            
            print("Loaded \(recipes.count) recipes for category \(category.name)")
            self.categoryRecipes = recipes
            
            // Select featured recipe AFTER setting categoryRecipes
            if !recipes.isEmpty {
                selectedFeaturedRecipe = recipes.randomElement()
                print("Selected featured recipe: \(selectedFeaturedRecipe?.name ?? "none")")
            }
        } catch {
            guard !Task.isCancelled else { return }
            
            let errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if !errorMsg.contains("cancelled") {
                self.error = errorMsg
            }
            print("Error loading category recipes: \(error)")
        }
    }
    
    @MainActor
    private func refreshCategoryRecipes() async {
        guard case .category(let category) = collectionType else { return }
        await loadCategoryRecipes(category)
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
    
    // MARK: - UI View
    
    var body: some View {
        Group {
            if !isLoading && recipes.isEmpty && !(isHome && model.randomRecipes.isEmpty) {
                // Centered empty state - replaces the entire scroll view
                VStack(spacing: 16) {
                    Image(systemName: collectionType.emptyStateIcon)
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(collectionType.emptyStateText)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Normal scroll content
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        // Featured header image
                        if let featuredRecipe = featuredRecipe {
                            featuredRecipeHeader(featuredRecipe)
                        } else if isLoading || (isHome && model.randomRecipes.isEmpty) {
                            loadingHeader()
                        }
                        
                        // Recipes grid section
                        recipesGridSection()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recipeDeleted)) { notification in
            if let deletedRecipeId = notification.object as? Int {
                // Remove from category recipes immediately for better UX
                categoryRecipes.removeAll { $0.id == deletedRecipeId }
                
                // Refresh category data to ensure consistency
                Task {
                    if case .category = collectionType {
                        await refreshCategoryRecipes()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recipeUpdated)) { notification in
            if let updatedRecipeId = notification.object as? Int {
                print("Recipe \(updatedRecipeId) was updated, refreshing view")
                
                // Refresh category data to ensure consistency
                Task {
                    if case .category = collectionType {
                        await refreshCategoryRecipes()
                    }
                    // For home view, the model.randomRecipes will be refreshed by the AppViewModel
                }
            }
        }
        .navigationTitle(collectionType.title)
        .task(id: collectionType) {
            // Reset featured recipe selection when collection type changes
            selectedFeaturedRecipe = nil
            await loadRecipes()
        }

        // Also add this modifier to reset when category recipes change:
        .onChange(of: categoryRecipes) { _,newRecipes in
            // Only select new featured recipe if we don't have one or it's no longer valid
            if selectedFeaturedRecipe == nil ||
               !newRecipes.contains(where: { $0.id == selectedFeaturedRecipe?.id }) {
                selectedFeaturedRecipe = newRecipes.isEmpty ? nil : newRecipes.randomElement()
                print("Updated featured recipe: \(selectedFeaturedRecipe?.name ?? "none")")
            }
        }
        .task(id: model.randomRecipes.count) {
            // This will trigger when recipes are added/deleted from home view
            if case .home = collectionType {
                // No need to reload, just let the view update
            }
        }
        .refreshable {
            await loadRecipes()
        }
        .alert("Error", isPresented: .init(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .onDisappear {
            currentLoadTask?.cancel()
        }
        .sheet(item: $editingRecipe) { recipe in
            AddEditRecipeView(editingRecipe: recipe)
                .environmentObject(model)
        }
        .alert("Delete Recipe", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let recipe = deletingRecipe {
                    Task {
                        await deleteRecipe(recipe)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                deletingRecipe = nil
            }
        } message: {
            if let recipe = deletingRecipe {
                Text("Are you sure you want to delete '\(recipe.name)'? This action cannot be undone.")
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
}
