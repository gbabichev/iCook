import SwiftUI

// MARK: - Root Split View (Landmarks-style)

struct ContentView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var preferredColumn: NavigationSplitViewColumn = .detail

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            CategoryList(selection: $model.selectedCategoryID)
        } detail: {
            if let id = model.selectedCategoryID,
               let cat = model.categories.first(where: { $0.id == id }) {
                CategoryDetail(category: cat)
            } else {
                HomeView()
            }
        }
        .navigationTitle("iCook")
        .searchable(text: $searchText, placement: .automatic, prompt: "Search categories")
        .onSubmit(of: .search) {
            Task { await model.loadCategories(search: searchText) }
        }
        .onChange(of: searchText) { _,newValue in
            searchTask?.cancel()
            searchTask = Task { [newValue] in
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
                if !Task.isCancelled {
                    await model.loadCategories(search: newValue)
                }
            }
        }
        .task {
            if model.categories.isEmpty { await model.loadCategories() }
        }
        .alert("Error",
               isPresented: .init(
                   get: { model.error != nil },
                   set: { if !$0 { model.error = nil } }
               ),
               actions: { Button("OK") { model.error = nil } },
               message: { Text(model.error ?? "") }
        )
    }
}

// MARK: - List Column (Landmarks: *List)

struct CategoryList: View {
    @EnvironmentObject private var model: AppViewModel
    @Binding var selection: Category.ID?

    var body: some View {
        List(model.categories) { category in
            Button {
                selection = category.id
            } label: {
                CategoryRow(category: category)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Categories")
    }
}

// MARK: - Detail Column (Landmarks: *Detail)

struct CategoryDetail: View {
    let category: Category
    var body: some View {
        VStack(spacing: 8) {
            Text(category.name)
                .font(.title2).bold()
            Text("Next: recipes list & details view.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(category.name)
    }
}

// MARK: - Row (Landmarks: *Row)

struct CategoryRow: View {
    let category: Category
    var body: some View {
        Text(category.name)
            .font(.body)
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppViewModel
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 20) {
                // Featured header image - similar to LandmarkFeaturedItemView
                Image("HomePlaceholder")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: 350)
                    .clipped()
                    .backgroundExtensionEffect()
//                    .overlay(alignment: .bottom) {
//                        VStack(spacing: 8) {
//                            Text("Featured Recipes")
//                                .font(.subheadline)
//                                .fontWeight(.bold)
//                                .foregroundColor(.white)
//                                .opacity(0.8)
//                            Text("Try something delicious")
//                                .font(.largeTitle)
//                                .fontWeight(.bold)
//                                .foregroundColor(.white)
//                            Button("Browse Recipes") {
//                                if let first = model.categories.first {
//                                    model.selectedCategoryID = first.id
//                                }
//                            }
//                            .buttonStyle(.borderedProminent)
//                            .padding(.bottom, 12)
//                        }
//                        .padding(.bottom, 16)
//                    }

                
                // Recipes grid section
                VStack(alignment: .leading, spacing: 16) {
                    Text("Popular Recipes")
                        .font(.title2)
                        .bold()
                        .padding(.top, 20)
                        .padding(.leading, 16)
                    
                    if model.randomRecipes.isEmpty {
                        ProgressView("Loading recipes…")
                            .frame(maxWidth: .infinity, minHeight: 80)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(model.randomRecipes) { recipe in
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

    private func selectionFromHome(_ recipe: Recipe) {
        // For now, just select the recipe's category. Later we can deep-link to a recipe detail.
        model.selectCategory(recipe.category_id)
    }
}

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
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .clipped()
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

private extension Recipe {
    var imageURL: URL? {
        guard let path = image, !path.isEmpty else { return nil }
        var comps = URLComponents(url: APIConfig.base, resolvingAgainstBaseURL: false)
        comps?.query = nil
        comps?.path = path.hasPrefix("/") ? path : "/" + path
        return comps?.url
    }
}

