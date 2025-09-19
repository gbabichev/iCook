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
                         .clipShape(RoundedRectangle(cornerRadius: 12))
                    case .success(let image):
                        #if os(iOS)
                        if UIDevice.current.userInterfaceIdiom == .phone {
                            // iPhone only
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(height: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .clipped()
                        } else {
                            // iPad (runs on iOS but we want the Mac/iPad styling)
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 190, height: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        #elseif os(macOS)
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 190, height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        #endif
                    case .failure(_):
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                ProgressView()
                    .scaleEffect(0.8)
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
        .task {
            // Stagger the image loading
            let delay = Double(index) * 0.05 // 150ms between each image
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            shouldLoadImage = true
        }
        .background(Color.clear)
    }
}

