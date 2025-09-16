//
//  HomeView.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppViewModel
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 20) {
                // Featured header image - using random recipe image
                if let featuredRecipe = model.randomRecipes.first {
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
                                            .opacity(0.8)
                                        Button("View Recipe") {
                                            selectionFromHome(featuredRecipe)
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
                                    Button("View Recipe") {
                                        selectionFromHome(featuredRecipe)
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
                } else {
                    // Fallback while loading recipes
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Loading featured recipe...")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: 350)
                    .backgroundExtensionEffect()
                }
                
                // Recipes grid section - skip the first recipe since it's featured above
                VStack(alignment: .leading, spacing: 16) {
                    Text("More Recipes")
                        .font(.title2)
                        .bold()
                        .padding(.top, 20)
                        .padding(.leading, 16)
                    
                    if model.randomRecipes.count <= 1 {
                        ProgressView("Loading recipes...")
                            .frame(maxWidth: .infinity, minHeight: 80)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(Array(model.randomRecipes.dropFirst())) { recipe in
                                Button {
                                    selectionFromHome(recipe)
                                } label: {
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
        .toolbar {
            ToolbarSpacer(.flexible)
        }
        .toolbar(removing: .title)
        .ignoresSafeArea(edges: .top)
        .task {
            if model.randomRecipes.isEmpty {
                await model.loadRandomRecipes()
            }
        }
    }

    func selectionFromHome(_ recipe: Recipe) {
        // For now, just select the recipe's category. Later we can deep-link to a recipe detail.
        model.selectCategory(recipe.category_id)
    }
}
