import SwiftUI

// MARK: - Root Split View (Landmarks-style)

struct ContentView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var preferredColumn: NavigationSplitViewColumn = .detail
    @State private var selectedCategoryID: Category.ID?

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            CategoryList(selection: $selectedCategoryID)
        } detail: {
            NavigationStack {
                if let id = selectedCategoryID,
                   let cat = model.categories.first(where: { $0.id == id }) {
                    CategoryHomeView(category: cat)
                } else {
                    HomeView(onRecipeSelected: { recipe in
                        selectedCategoryID = recipe.category_id
                    })
                }
            }
            .navigationDestination(for: Category.self) { category in
                CategoryHomeView(category: category)
            }
            .navigationDestination(for: Recipe.self) { recipe in
                RecipeDetailView(recipe: recipe)
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
            if model.categories.isEmpty {
                await model.loadCategories()
            }
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
        NavigationStack {
            List(model.categories, selection: $selection) { category in
                NavigationLink(value: category) {
                    CategoryRow(category: category)
                }
            }
            .navigationTitle("Categories")
            .navigationDestination(for: Category.self) { category in
                CategoryHomeView(category: category)
            }
            .navigationDestination(for: Recipe.self) { recipe in
                RecipeDetailView(recipe: recipe)
            }
        }
    }
}

// MARK: - Detail Column (Landmarks: *Detail)

struct CategoryDetail: View {
    let category: Category
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: category.icon)
                .font(.system(size: 48))
                .foregroundStyle(.primary)
                .padding(.bottom, 8)
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
        HStack(spacing: 12) {
            Image(systemName: category.icon)
                .font(.title2)
                .foregroundStyle(.primary)
                .frame(width: 24, height: 24)
            
            Text(category.name)
                .font(.body)
        }
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

// MARK: - Placeholder Recipe Detail View

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
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 250)
                            .clipped()
                    case .failure:
                        ZStack {
                            Rectangle().opacity(0.08)
                            Image(systemName: "photo")
                        }
                        .frame(height: 250)
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
        //.navigationBarTitleDisplayMode(.inline)
    }
}

extension Recipe {
    var imageURL: URL? {
        guard let path = image, !path.isEmpty else { return nil }
        var comps = URLComponents(url: APIConfig.base, resolvingAgainstBaseURL: false)
        comps?.query = nil
        comps?.path = path.hasPrefix("/") ? path : "/" + path
        return comps?.url
    }
}

// MARK: - Make Category and Recipe Hashable for NavigationLink(value:)
