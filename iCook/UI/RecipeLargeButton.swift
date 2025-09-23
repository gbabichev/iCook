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
                            // iPhone - use aspectRatio and maxWidth to constrain properly
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity, maxHeight: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
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
                        ZStack {
                            Rectangle()
                                .fill(.ultraThinMaterial)
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(height: 140)
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
        .task {
            // Stagger the image loading
            let delay = Double(index) * 0.05 // 50ms between each image
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            shouldLoadImage = true
        }
        .background(Color.clear)
    }
}
