import SwiftUI

// MARK: - Root Split View (Landmarks-style)

struct ContentView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var preferredColumn: NavigationSplitViewColumn = .detail
    @State private var selectedCategoryID: Category.ID? = -1 // Use -1 as sentinel for "Home"
    @State private var showingAddCategory = false

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            CategoryList(selection: $selectedCategoryID)
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
        } detail: {
            // Single NavigationStack for the detail view
            NavigationStack {
                if let id = selectedCategoryID, id != -1,
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
            .navigationBarHidden(true)
#endif
            .toolbar{
                ToolbarSpacer(.flexible)
            }
            .ignoresSafeArea(edges: .top)
            .navigationDestination(for: Recipe.self) { recipe in
                RecipeDetailView(recipe: recipe)
            }
        }
        .searchable(text: $searchText, placement: .automatic, prompt: "Search categories")
        .onSubmit(of: .search) {
            if !showingAddCategory {
                Task { await model.loadCategories(search: searchText) }
            }
        }
        .onChange(of: searchText) { _, newValue in
            if showingAddCategory { return }
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
        .sheet(isPresented: $showingAddCategory) {
            AddCategoryView()
                .environmentObject(model)
        }
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
                                if !trimmed.isEmpty && !isCreating { createCategory() }
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
            .navigationTitle("Add Category")
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
                        createCategory()
                    } label: {
                        if isCreating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save")
                                .fontWeight(.semibold)
                        }
                    }
                    .keyboardShortcut(.defaultAction) // macOS default ⏎ action; harmless on iOS
                    .disabled(categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                }
            }
        }
        .interactiveDismissDisabled(isCreating) // don’t swipe-dismiss mid-save
        .disabled(isCreating) // prevent taps while saving
        .overlay {
            // Dimmed progress overlay with a smooth fade
            if isCreating {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text("Creating…")
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
    }
    private func createCategory() {
        Task {
            await createCategoryAsync()
        }
    }
    
    @MainActor
    private func createCategoryAsync() async {
        isCreating = true
        defer { isCreating = false }
        
        do {
            let success = await model.createCategory(name: categoryName.trimmingCharacters(in: .whitespacesAndNewlines), icon: selectedIcon)
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
