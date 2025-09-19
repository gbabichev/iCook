//
//  RecipeLargeButton.swift
//  iCook
//
//  Created by George Babichev on 9/16/25.
//


import SwiftUI

struct RecipeLargeButton: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: recipe.imageURL) { phase in
                switch phase {
                case .empty:
                    ZStack {
                        Rectangle().opacity(0.08)
                        ProgressView()
                    }
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                case .success(let image):
                    #if os(macOS)
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 190, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    #else
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .clipped()
                    #endif
                case .failure:
                    ZStack {
                        Rectangle().opacity(0.08)
                        Image(systemName: "photo")
                    }
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                @unknown default:
                    EmptyView()
                }
            }
            Text(recipe.name)
                .font(.headline)
                .lineLimit(1)
            Text("\(recipe.recipe_time) min")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
