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
