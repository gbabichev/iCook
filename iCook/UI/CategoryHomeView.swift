//
//  CategoryHomeView.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI

struct CategoryHomeView: View {
    let category: Category
    @EnvironmentObject private var model: AppViewModel
    @State private var categoryRecipes: [Recipe] = []
    @State private var isLoading = false
    @State private var error: String?
    
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 20) {
                    // Featured header image - using random recipe from category
                    if let featuredRecipe = categoryRecipes.randomElement() {
                        AsyncImage(url: featuredRecipe.imageURL) { phase in
                            switch phase {
                            case .empty:
                                ZStack {
                                    Rectangle()
                                        .fill(.ultraThinMaterial)
                                    ProgressView()
                                        .scaleEffect(1.5)
                                }
                                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: 350)
                                
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: 350)
                                    .clipped()
                                    .overlay(alignment: .bottom) {
                                        VStack(spacing: 8) {
                                            Text(featuredRecipe.name)
                                                .font(.largeTitle)
                                                .fontWeight(.bold)
                                                .foregroundColor(.white)
                                                .multilineTextAlignment(.center)
                                            Text("\(featuredRecipe.recipe_time) minutes")
                                                .font(.headline)
                                                .foregroundColor(.white)
                                                .opacity(0.8)
                                            NavigationLink(destination: RecipeDetailView(recipe: featuredRecipe)) {
                                                Text("View Recipe")
                                                    .foregroundColor(.white)
                                            }
                                            .controlSize(.large)
                                        }
                                        .padding(.bottom, 32)
                                        .padding(.horizontal, 20)
                                    }
                                    
                            case .failure:
                                ZStack {
                                    Rectangle()
                                        .fill(.ultraThinMaterial)
                                    VStack(spacing: 12) {
                                        Image(systemName: "photo.badge.exclamationmark")
                                            .font(.system(size: 48))
                                            .foregroundStyle(.secondary)
                                        Text("Image not available")
                                            .font(.headline)
                                            .foregroundStyle(.secondary)
                                        Text(featuredRecipe.name)
                                            .font(.title2)
                                            .fontWeight(.bold)
                                        NavigationLink(destination: RecipeDetailView(recipe: featuredRecipe)) {
                                            Text("View Recipe")
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }
                                    .padding()
                                }
                                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: 350)
                                
                            @unknown default:
                                EmptyView()
                            }
                        }
                        .backgroundExtensionEffect()
                    } else if isLoading {
                        // Loading state
                        ZStack {
                            Rectangle()
                                .fill(.ultraThinMaterial)
                            VStack(spacing: 16) {
                                ProgressView()
                                    .scaleEffect(1.5)
                                Text("Loading \(category.name.lowercased()) recipes...")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: 350)
                        .backgroundExtensionEffect()
                    } else if categoryRecipes.isEmpty {
                        // Empty state
                        ZStack {
                            Rectangle()
                                .fill(.ultraThinMaterial)
                            VStack(spacing: 16) {
                                Image(systemName: category.icon)
                                    .font(.system(size: 48))
                                    .foregroundStyle(.secondary)
                                Text("No \(category.name.lowercased()) recipes found")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: 350)
                        .backgroundExtensionEffect()
                    }
                    
                    // Recipes grid section - show all recipes in order, excluding the featured one
                    if !categoryRecipes.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("All \(category.name)")
                                .font(.title2)
                                .bold()
                                .padding(.top, 20)
                                .padding(.leading, 16)
                            
                            let remainingRecipes = categoryRecipes.filter { recipe in
                                // Exclude the featured recipe if there's more than one recipe
                                guard categoryRecipes.count > 1,
                                      let featuredRecipe = categoryRecipes.randomElement() else {
                                    return true
                                }
                                return recipe.id != featuredRecipe.id
                            }
                            
                            if remainingRecipes.isEmpty && categoryRecipes.count == 1 {
                                Text("This is the only recipe in this category")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                            } else {
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(remainingRecipes) { recipe in
                                        NavigationLink(destination: RecipeDetailView(recipe: recipe)) {
                                            RecipeLargeButton(recipe: recipe)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                }
            }
            .navigationTitle(category.name)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
            }
        .task {
            await loadCategoryRecipes()
        }
        .refreshable {
            await loadCategoryRecipes()
        }
        .alert("Error", isPresented: .init(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
    
    @MainActor
    private func loadCategoryRecipes() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        
        do {
            print("Loading recipes for category: \(category.name) (ID: \(category.id))")
            let recipes = try await APIClient.fetchRecipes(categoryID: category.id, page: 1, limit: 100)
            print("Loaded \(recipes.count) recipes for category \(category.name)")
            self.categoryRecipes = recipes
        } catch {
            let errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            self.error = errorMsg
            print("Error loading category recipes: \(error)")
        }
    }
}
