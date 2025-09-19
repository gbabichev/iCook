//
//  RecipeSearchResultsView.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//


import SwiftUI

// MARK: - Recipe Search Results View

struct RecipeSearchResultsView: View {
    let searchText: String
    let searchResults: [Recipe]
    let isSearching: Bool
    
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Search Results")
                        .font(.largeTitle)
                        .bold()
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                    
                    if !searchText.isEmpty {
                        Text("Results for \"\(searchText)\"")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                    }
                }
                
                // Content
                if isSearching {
                    // Loading state
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Searching recipes...")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if searchResults.isEmpty && !searchText.isEmpty {
                    // Empty state
                    VStack(spacing: 16) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No recipes found")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Try searching with different keywords")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if !searchResults.isEmpty {
                    // Results grid
                    VStack(alignment: .leading, spacing: 16) {
                        Text("\(searchResults.count) recipe\(searchResults.count == 1 ? "" : "s") found")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                        
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(Array(searchResults.enumerated()), id: \.element.id) { index, recipe in
                                NavigationLink(destination: RecipeDetailView(recipe: recipe)) {
                                    RecipeLargeButtonWithState(recipe: recipe, index: index)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                
                Spacer(minLength: 50)
            }
        }
        .navigationTitle("")
    }
}
