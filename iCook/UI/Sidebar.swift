//
//  Sidebar.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI

// MARK: - List Column (Landmarks: *List)

#if os(iOS)
private struct SidebarSearchContent<DefaultContent: View>: View {
    @Environment(\.isSearching) private var isSearching
    let searchText: String
    let searchScope: RecipeSearchScope
    @ViewBuilder let defaultContent: () -> DefaultContent

    var body: some View {
        if isSearching {
            SidebarRecipeSearchResults(searchText: searchText, searchScope: searchScope)
        } else {
            defaultContent()
        }
    }
}

private struct SidebarRecipeSearchResults: View {
    @EnvironmentObject private var model: AppViewModel
    let searchText: String
    let searchScope: RecipeSearchScope

    private var matchingRecipes: [Recipe] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipes = model.recipes.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        guard !query.isEmpty else { return recipes }

        return recipes.filter { $0.matchesSearch(query, scope: searchScope) }
    }

    var body: some View {
        ScrollView {
            RecipeSearchResultsView(
                recipes: matchingRecipes,
                searchText: searchText,
                onSelect: { recipe in
                    model.saveLastViewedRecipe(recipe)
                    model.saveAppLocation(
                        .recipe(recipeID: recipe.id, categoryID: recipe.categoryID)
                    )
                }
            )
        }
        .scrollDismissesKeyboard(.immediately)
    }
}
#endif

struct CategoryList: View {
    @EnvironmentObject private var model: AppViewModel
    @Binding var editingCategory: Category?
    @Binding var editingTag: Tag?
    @Binding var showingAddCategory: Bool
    @Binding var showingAddTag: Bool
    @Binding var collectionType: RecipeCollectionType?
    @AppStorage("SidebarCategoriesExpanded") private var isCategoriesExpanded = true
    @AppStorage("SidebarTagsExpanded") private var isTagsExpanded = true
    @State private var showSourcesOverlay = false
#if os(iOS)
    @State private var searchText = ""
    @State private var searchScope: RecipeSearchScope = .name
#endif
    
    private var homeRecipeCount: Int {
        model.recipeCounts.values.reduce(0, +)
    }

    private var favoriteRecipeCount: Int {
        model.recipes.filter { model.isFavorite($0.id) }.count
    }
    
    private func recipeCount(for category: Category) -> Int {
        model.recipeCounts[category.id] ?? 0
    }

    private func recipeCount(for tag: Tag) -> Int {
        model.recipes.filter { $0.tagIDs.contains(tag.id) }.count
    }
    
    private func refreshCategoriesSmooth() async {
        guard model.currentSource != nil else { return }
        let start = Date()
        if model.canRetryCloudConnection {
            await model.retryCloudConnectionAndRefresh(skipRecipeCache: true)
        } else {
            await model.refreshSourcesAndCurrentContent(skipRecipeCache: true, forceProbe: true)
        }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 1.0 {
            try? await Task.sleep(nanoseconds: UInt64((1.0 - elapsed) * 1_000_000_000))
        }
    }
    
    private var categoryListContent: some View {
        List(selection: $collectionType) {
            Section("Home") {
                NavigationLink(value: RecipeCollectionType.home) {
                    HStack(spacing: 6) {
                        Image(systemName: "house.fill")
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                        Text("All Recipes")
                        
                        Spacer()
                        
                        Text("\(homeRecipeCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if model.currentSource != nil {
                    NavigationLink(value: RecipeCollectionType.favorites) {
                        HStack(spacing: 6) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                                .frame(width: 24)
                            Text("Favorites")

                            Spacer()

                            Text("\(favoriteRecipeCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            
            if !model.categories.isEmpty {
                Section(isExpanded: $isCategoriesExpanded) {
                    ForEach(model.categories) { category in
                        NavigationLink(value: RecipeCollectionType.category(category)) {
                            HStack(spacing: 6) {
                                Text(category.icon)
                                    .frame(width: 24)
                                Text(category.name)
                                
                                Spacer()
                                
                                Text("\(recipeCount(for: category))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button {
                                editingCategory = category
                            } label: {
                                Label("Edit Category", systemImage: "pencil")
                            }
                            .disabled(model.isOfflineMode)
                        }
                    }
                } header: {
                    Text("Categories")
                }
            }

            if model.currentSource != nil {
                Section(isExpanded: $isTagsExpanded) {
                    if model.tags.isEmpty {
                        Text("No tags yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.tags) { tag in
                            NavigationLink(value: RecipeCollectionType.tag(tag)) {
                                HStack(spacing: 6) {
                                    Image(systemName: "tag")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24)
                                    Text(tag.name)

                                    Spacer()

                                    Text("\(recipeCount(for: tag))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contextMenu {
                                Button {
                                    editingTag = tag
                                } label: {
                                    Label("Edit Tag", systemImage: "pencil")
                                }
                                .disabled(model.isOfflineMode || model.currentSource == nil || !(model.currentSource.map(model.canEditSource) ?? false))
                            }
                        }
                    }
                } header: {
                    Text("Tags")
                }
            }
            
            if model.isLoadingCategories {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Updating from iCloud...")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if model.currentSource != nil && model.categories.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.blue)
                            Text("Welcome!")
                                .font(.headline)
                        }
                        Text("Create your first category to get started")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var displayedListContent: some View {
#if os(iOS)
        SidebarSearchContent(searchText: searchText, searchScope: searchScope) {
            categoryListContent
        }
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: searchScope == .name ? "Search Recipes" : "Search Ingredients"
        )
        .searchScopes($searchScope) {
            ForEach(RecipeSearchScope.allCases, id: \.self) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .navigationDestination(for: Recipe.self) { recipe in
            RecipeDetailView(recipe: recipe)
        }
#else
        categoryListContent
#endif
    }

    var body: some View {
        displayedListContent
        .refreshable {
            await refreshCategoriesSmooth()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSourcesOverlay = true
                } label: {
                    Image(systemName: "gear")
                }
                .disabled(model.isOfflineMode)
                .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        NotificationCenter.default.post(name: .requestAddRecipe, object: nil)
                    } label: {
                        Label("Add Recipe", systemImage: "fork.knife.circle")
                    }
                    .disabled(model.currentSource == nil || model.categories.isEmpty)

                    Button {
                        showingAddTag = true
                    } label: {
                        Label("Add Tag", systemImage: "tag")
                    }
                    .disabled(model.currentSource == nil)

                    Button {
                        showingAddCategory = true
                    } label: {
                        Label("Add Category", systemImage: "tray")
                    }
                    .disabled(model.currentSource == nil)
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(model.isOfflineMode)
                .accessibilityLabel("Add")
            }
        }
        .sheet(isPresented: $showSourcesOverlay) {
            SourceSelector()
                .environmentObject(model)
#if os(macOS)
                .frame(minWidth: 400, minHeight: 300)
#endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestShowSettings)) { _ in
            showSourcesOverlay = true
        }
    }
}
