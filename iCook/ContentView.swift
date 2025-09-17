import SwiftUI

// MARK: - Root Split View (Landmarks-style)

struct ContentView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var preferredColumn: NavigationSplitViewColumn = .detail
    @State private var selectedCategoryID: Category.ID? = -1 // Use -1 as sentinel for "Home"
    @State private var showingAddCategory = false
    @State private var editingCategory: Category? = nil
    
    // New state for recipe search
    @State private var searchResults: [Recipe] = []
    @State private var isSearching = false
    @State private var showingSearchResults = false

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            
            if horizontalSizeClass == .compact && showingSearchResults {
                   NavigationStack {
                       RecipeSearchResultsView(
                           searchText: searchText,
                           searchResults: searchResults,
                           isSearching: isSearching
                       )
                       .navigationDestination(for: Recipe.self) { recipe in
                           RecipeDetailView(recipe: recipe)
                       }
                   }
            } else {
                CategoryList(
                    selection: $selectedCategoryID,
                    editingCategory: $editingCategory
                )
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingAddCategory = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add Category")
                    }
                }
            }

        } detail: {
            // Single NavigationStack for the detail view
            NavigationStack {
                if showingSearchResults {
                    // Show search results view
                    RecipeSearchResultsView(
                        searchText: searchText,
                        searchResults: searchResults,
                        isSearching: isSearching
                    )
                } else if let id = selectedCategoryID, id != -1,
                   let cat = model.categories.first(where: { $0.id == id }) {
                    RecipeCollectionView(category: cat)
                } else {
                    // Show home view when selectedCategoryID is nil or -1
                    RecipeCollectionView()
                }
            }
#if os(macOS)
            .toolbar(removing: .title)
#else
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar{
                ToolbarSpacer(.flexible)
            }
            .ignoresSafeArea(edges: .top)
            .navigationDestination(for: Recipe.self) { recipe in
                RecipeDetailView(recipe: recipe)
            }
        }
        .searchable(text: $searchText, placement: .automatic, prompt: "Search recipes")
        .onSubmit(of: .search) {
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                performSearch()
            }
        }
        .onChange(of: searchText) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmed.isEmpty {
                // Clear search when text is empty
                showingSearchResults = false
                searchResults = []
                searchTask?.cancel()
            } else {
                // Debounced search
                searchTask?.cancel()
                searchTask = Task { [trimmed] in
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms debounce
                    if !Task.isCancelled && trimmed == searchText.trimmingCharacters(in: .whitespacesAndNewlines) {
                        await performSearch(with: trimmed)
                    }
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
        .sheet(isPresented: $showingAddCategory) {
            AddCategoryView()
                .environmentObject(model)
        }
        .sheet(item: $editingCategory) { category in
            AddCategoryView(editingCategory: category)
                .environmentObject(model)
        }
    }
    
    private func performSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            Task {
                await performSearch(with: trimmed)
            }
        }
    }
    
    @MainActor
    private func performSearch(with query: String) async {
        guard !query.isEmpty else { return }
        
        isSearching = true
        showingSearchResults = true
        
        defer { isSearching = false }
        
        do {
            let results = try await APIClient.searchRecipes(query: query)
            searchResults = results
        } catch {
            print("Search error: \(error)")
            model.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            searchResults = []
        }
    }
}

// MARK: - Recipe Search Results View

struct RecipeSearchResultsView: View {
    let searchText: String
    let searchResults: [Recipe]
    let isSearching: Bool
    
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Search Results")
                        .font(.largeTitle)
                        .bold()
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                    
                    if !searchText.isEmpty {
                        Text("Results for \"\(searchText)\"")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                    }
                }
                
                // Content
                if isSearching {
                    // Loading state
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Searching recipes...")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if searchResults.isEmpty && !searchText.isEmpty {
                    // Empty state
                    VStack(spacing: 16) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No recipes found")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Try searching with different keywords")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if !searchResults.isEmpty {
                    // Results grid
                    VStack(alignment: .leading, spacing: 16) {
                        Text("\(searchResults.count) recipe\(searchResults.count == 1 ? "" : "s") found")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                        
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(searchResults) { recipe in
                                NavigationLink(destination: RecipeDetailView(recipe: recipe)) {
                                    RecipeLargeButton(recipe: recipe)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                
                Spacer(minLength: 50)
            }
        }
        .navigationTitle("")
    }
}

// MARK: - Icon Selection Grid
struct IconSelectionGrid: View {
    @Binding var selectedIcon: String
    
    private let iconOptions = [
        "fork.knife", "cup.and.saucer", "birthday.cake", "carrot",
        "leaf", "fish", "popcorn", "wineglass", "mug.fill",
        "takeoutbag.and.cup.and.straw", "refrigerator", "cooktop",
        "flame", "drop", "snowflake", "sun.max", "moon",
        "star", "heart", "house"
    ]
    
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 16) {
            ForEach(iconOptions, id: \.self) { icon in
                IconButton(icon: icon, isSelected: selectedIcon == icon) {
                    selectedIcon = icon
                }
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Individual Icon Button
struct IconButton: View {
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                )
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }
}

struct AddCategoryView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var categoryName = ""
    @State private var selectedIcon = "fork.knife"
    @State private var isCreating = false
    
    let editingCategory: Category?
    
    init(editingCategory: Category? = nil) {
        self.editingCategory = editingCategory
    }
    
    private var isEditing: Bool {
        editingCategory != nil
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Subtle background for a more "carded" form look on iOS
                #if os(iOS)
                Color(.systemGroupedBackground).ignoresSafeArea()
                #endif

                Form {
                    Section("Category Name") {
                        TextField("Enter category name", text: $categoryName)
                            .submitLabel(.done)
                            .onSubmit {
                                let trimmed = categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty && !isCreating { saveCategory() }
                            }
                        #if os(iOS)
                            .textInputAutocapitalization(.words)
                        #endif
                            .disableAutocorrection(true)
                            .accessibilityLabel("Category name")
                            .accessibilityHint("Enter a short, descriptive name")
                            .padding(.vertical, 6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(.red, lineWidth: 2)
                                    .opacity(categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0)
                            )
                            .animation(.easeInOut(duration: 0.15), value: categoryName)
                    }

                    Section("Icon") {
                        IconSelectionGrid(selectedIcon: $selectedIcon)
                            .accessibilityLabel("Icon picker")
                    }
                }
                .scrollContentBackground(.hidden) // lets our background show through
                .formStyle(.grouped)
            }
            .navigationTitle(isEditing ? "Edit Category" : "Add Category")
            .toolbar {
                // iOS keyboard dismiss
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
                #endif

                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveCategory()
                    } label: {
                        if isCreating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save")
                                .fontWeight(.semibold)
                        }
                    }
                    .keyboardShortcut(.defaultAction) // macOS default ⌘ action; harmless on iOS
                    .disabled(categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                }
            }
        }
        .interactiveDismissDisabled(isCreating) // don't swipe-dismiss mid-save
        .disabled(isCreating) // prevent taps while saving
        .overlay {
            // Dimmed progress overlay with a smooth fade
            if isCreating {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text(isEditing ? "Updating…" : "Creating…")
                            .font(.callout)
                            .foregroundStyle(.primary)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isCreating)
        .onAppear {
            if let category = editingCategory {
                categoryName = category.name
                selectedIcon = category.icon
            }
        }
    }
    
    private func saveCategory() {
        Task {
            await saveCategoryAsync()
        }
    }
    
    @MainActor
    private func saveCategoryAsync() async {
        isCreating = true
        defer { isCreating = false }
        
        do {
            let success: Bool
            if let category = editingCategory {
                success = await model.updateCategory(id: category.id, name: categoryName.trimmingCharacters(in: .whitespacesAndNewlines), icon: selectedIcon)
            } else {
                success = await model.createCategory(name: categoryName.trimmingCharacters(in: .whitespacesAndNewlines), icon: selectedIcon)
            }
            
            if success {
                dismiss()
            }
        }
    }
}

// MARK: - List Column (Landmarks: *List)

struct CategoryList: View {
    @EnvironmentObject private var model: AppViewModel
    @Binding var selection: Category.ID?
    @Binding var editingCategory: Category?

    var body: some View {
        List(selection: $selection) {
            // Home section at the top
            Section {
                NavigationLink(value: -1) {
                    HStack(spacing: 12) {
                        Image(systemName: "house.fill")
                            .font(.title2)
                            .foregroundStyle(.primary)
                            .frame(width: 24, height: 24)
                        
                        Text("Home")
                            .font(.body)
                    }
                }
                .tag(-1 as Category.ID?)
            }
            
            // Categories section
            Section("Categories") {
                ForEach(model.categories) { category in
                    NavigationLink(value: category.id) {
                        CategoryRow(category: category)
                    }
                    .tag(category.id)
                    .contextMenu {
                        Button {
                            editingCategory = category
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        
                        Divider()
                        
                        Button(role: .destructive) {
                            Task {
                                // If we're deleting the currently selected category, reset to home
                                if selection == category.id {
                                    selection = -1
                                }
                                await model.deleteCategory(id: category.id)
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("iCook")
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
