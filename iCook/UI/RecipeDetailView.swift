//
//  RecipeDetailView.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI

// MARK: - Recipe Detail View

struct RecipeDetailView: View {
    let recipe: Recipe
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AsyncImage(url: recipe.imageURL) { phase in
                    switch phase {
                    case .empty:
                        ZStack {
                            Rectangle().opacity(0.08)
                            ProgressView()
                        }
                        .frame(height: 250)
                        .backgroundExtensionEffect()
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 250)
                            .clipped()
                            .backgroundExtensionEffect()
                    case .failure:
                        ZStack {
                            Rectangle().opacity(0.08)
                            Image(systemName: "photo")
                        }
                        .frame(height: 250)
                        .backgroundExtensionEffect()
                    @unknown default:
                        EmptyView()
                    }
                }
                
                VStack(alignment: .leading, spacing: 12) {
                    Text(recipe.name)
                        .font(.largeTitle)
                        .bold()
                    
                    Text("\(recipe.recipe_time) minutes")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    Text("Recipe details would go here...")
                        .font(.body)
                }
                .padding(.horizontal)
                
                Spacer()
            }
        }
        .navigationTitle(recipe.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .ignoresSafeArea(edges: .top)
    }
}
