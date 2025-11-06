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
                    .task(id: url) {
                        await loadImage()
                    }
            case .success(let image):
                content(image)
            case .failed:
                placeholder()
            }
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
            // Use URLSession to download the image data manually
            let (data, response) = try await URLSession.shared.data(from: url)
            
            // Validate response
            guard let httpResponse = response as? HTTPURLResponse,
                  200...299 ~= httpResponse.statusCode else {
                throw URLError(.badServerResponse)
            }
            
            // Create platform-specific image from data
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
            print("Failed to load image from \(url): \(error)")
            
            if retryCount < maxRetries {
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

// Convenience initializer similar to AsyncImage
extension RobustAsyncImage {
    init(url: URL?) where Content == Image, Placeholder == AnyView {
        self.init(
            url: url,
            content: { image in image },
            placeholder: {
                AnyView(
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                )
            }
        )
    }
}

// Updated RecipeLargeButtonWithState using the robust image loader
struct RecipeLargeButtonWithState: View {
    let recipe: Recipe
    let index: Int
    
    @State private var shouldLoadImage = false
    
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
                    ProgressView()
                        .scaleEffect(0.8)
                }
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(recipe.name)
                    .font(.headline)
                    .lineLimit(2)
                
                Text("\(recipe.recipeTime) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
