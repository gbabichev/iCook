import SwiftUI

// Custom AsyncImage that handles decode errors and prevents caching of failed images
struct RobustAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder
    
    @State private var loadingState: LoadingState = .idle
    @State private var retryCount = 0
    private let maxRetries = 2
    
    enum LoadingState {
        case idle
        case loading
        case success(Image)
        case failed
    }
    
    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }
    
    var body: some View {
        Group {
            switch loadingState {
            case .idle, .loading:
                placeholder()
            case .success(let image):
                content(image)
            case .failed:
                placeholder()
            }
        }
        .task(id: url) {
            retryCount = 0
            loadingState = .idle
            await loadImage()
        }
    }
    
    @MainActor
    private func loadImage() async {
        guard let url = url else {
            loadingState = .failed
            return
        }
        
        loadingState = .loading
        do {
            let data: Data
            if url.isFileURL {
                data = try Data(contentsOf: url)
            } else {
                let (fetched, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse {
                    guard 200...299 ~= httpResponse.statusCode else {
                        throw URLError(.badServerResponse)
                    }
                }
                data = fetched
            }
            
#if os(iOS)
            guard let uiImage = UIImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            let image = Image(uiImage: uiImage)
#elseif os(macOS)
            guard let nsImage = NSImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            let image = Image(nsImage: nsImage)
#else
            throw URLError(.cannotDecodeContentData)
#endif
            loadingState = .success(image)
            
        } catch {
            if Task.isCancelled { return }
            printD("Failed to load image from \(url): \(error)")
            
            if retryCount < maxRetries && !url.isFileURL {
                retryCount += 1
                // Add a small delay before retry
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                await loadImage()
            } else {
                loadingState = .failed
            }
        }
    }
}

// Updated RecipeLargeButtonWithState using the robust image loader
struct RecipeLargeButtonWithState: View {
    let recipe: Recipe
    let categoryName: String?
    let tagNames: [String]
    let index: Int
    
    @State private var shouldLoadImage = false

    private var subtitleText: String {
        var parts: [String] = ["\(recipe.recipeTime) min"]
        if let categoryName, !categoryName.isEmpty {
            parts.append(categoryName)
        }
        if !tagNames.isEmpty {
            parts.append(tagNames.joined(separator: ", "))
        }
        return parts.joined(separator: " • ")
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if shouldLoadImage {
                RobustAsyncImage(url: recipe.imageURL) { image in
                    GeometryReader { geometry in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: 140)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .frame(height: 140)
                } placeholder: {
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                        Image(systemName: "fork.knife.circle")
                            .font(.system(size: 80))
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            } else {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                    Image(systemName: "fork.knife.circle")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(recipe.name)
                    .font(.headline)
                    .lineLimit(2)
                
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .task {
            let delay = Double(index) * 0.01
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            shouldLoadImage = true
        }
    }
}

/// The single card-grid presentation used by every recipe search entry point.
struct RecipeSearchResultsView: View {
    @EnvironmentObject private var model: AppViewModel

    let recipes: [Recipe]
    let searchText: String
    let onSelect: (Recipe) -> Void
    var onEdit: ((Recipe) -> Void)? = nil
    var topPadding: CGFloat = 16

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 15)]

    private func categoryName(for recipe: Recipe) -> String? {
        model.categories.first(where: { $0.id == recipe.categoryID })?.name
    }

    private func tagNames(for recipe: Recipe) -> [String] {
        guard !recipe.tagIDs.isEmpty, !model.tags.isEmpty else { return [] }
        let namesByID = Dictionary(uniqueKeysWithValues: model.tags.map { ($0.id, $0.name) })
        var seen = Set<String>()

        return recipe.tagIDs.compactMap { tagID in
            guard let name = namesByID[tagID], !name.isEmpty, seen.insert(name).inserted else {
                return nil
            }
            return name
        }
    }

    @ViewBuilder
    private func recipeLink(_ recipe: Recipe, index: Int) -> some View {
        let link = NavigationLink(value: recipe) {
            RecipeLargeButtonWithState(
                recipe: recipe,
                categoryName: categoryName(for: recipe),
                tagNames: tagNames(for: recipe),
                index: index
            )
        }
        .simultaneousGesture(TapGesture().onEnded {
            onSelect(recipe)
        })
        .buttonStyle(.plain)

        if let onEdit {
            link.contextMenu {
                Button {
                    onEdit(recipe)
                } label: {
                    Label("Edit Recipe", systemImage: "pencil")
                }
                .disabled(model.isOfflineMode)
            }
        } else {
            link
        }
    }

    var body: some View {
        if recipes.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        } else {
            LazyVGrid(columns: columns, spacing: 15) {
                ForEach(Array(recipes.enumerated()), id: \.element.id) { index, recipe in
                    recipeLink(recipe, index: index)
                }
            }
            .padding(.horizontal, 15)
            .padding(.top, topPadding)
        }
    }
}
