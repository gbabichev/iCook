//
//  RecipeLargeButton.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//

import SwiftUI

struct RecipeLargeButtonWithState: View {
    let recipe: Recipe
    let index: Int
    
    @State private var shouldLoadImage = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if shouldLoadImage {
                AsyncImage(url: recipe.imageURL) { phase in
                    switch phase {
                    case .empty:
                        ZStack {
                             Rectangle()
                                 .fill(.ultraThinMaterial)
                             Image(systemName: "fork.knife.circle")
                                 .font(.system(size: 80))
                                 .foregroundStyle(.secondary)
                         }
                         .frame(height: 140)
                         .frame(maxWidth: .infinity) // Ensure full width
                         .clipShape(RoundedRectangle(cornerRadius: 12))
                    case .success(let image):
                        // Simplified approach - same for all platforms
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 140)
                            .frame(maxWidth: .infinity) // Ensure consistent full width
                            .clipped() // Use clipped() instead of clipShape for the image
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    case .failure(_):
                        ZStack {
                            Rectangle()
                                .fill(.ultraThinMaterial)
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(height: 140)
                        .frame(maxWidth: .infinity) // Ensure full width
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                    ProgressView()
                        .scaleEffect(0.8)
                }
                .frame(height: 140)
                .frame(maxWidth: .infinity) // Ensure full width
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(recipe.name)
                    .font(.headline)
                    .lineLimit(2)
                
                Text("\(recipe.recipe_time) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading) // Ensure the entire VStack takes full width
        .contentShape(Rectangle()) // Make the entire area tappable
        .task {
            // Stagger the image loading
            let delay = Double(index) * 0.05 // 50ms between each image
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            shouldLoadImage = true
        }
    }
}
