import SwiftUI
import CloudKit

// MARK: - Root Split View (Landmarks-style)

struct ContentView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var preferredColumn: NavigationSplitViewColumn = .detail
    @State private var selectedCategoryID: CKRecord.ID?
    @State private var isShowingHome = true
    @State private var showingAddCategory = false
    @State private var editingCategory: Category? = nil
    @State private var showSourceSelector = false

    // Recipe management state
    @State private var showingAddRecipe = false
    @State private var isDebugOperationInProgress = false

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            VStack(spacing: 0) {
                // Source selector
                SourceSelector(viewModel: model)

                Divider()

                // Category list
                CategoryList(
                    selection: $selectedCategoryID,
                    editingCategory: $editingCategory,
                    isShowingHome: $isShowingHome
                )
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
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
                if isShowingHome {
                    RecipeCollectionView()
                } else if let id = selectedCategoryID,
                          let cat = model.categories.first(where: { $0.id == id }) {
                    RecipeCollectionView(category: cat)
                } else {
                    RecipeCollectionView()
                }
            }
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddRecipe = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("Add Recipe")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Section("Debug") {
                            Button(role: .destructive) {
                                isDebugOperationInProgress = true
                                Task {
                                    await model.debugDeleteAllSourcesAndReset()
                                    // Reload the UI - don't call loadSources() since the default source is already created
                                    if model.currentSource != nil {
                                        selectedCategoryID = nil
                                        isShowingHome = true
                                        await model.loadCategories()
                                        await model.loadRandomRecipes()
                                    }
                                    isDebugOperationInProgress = false
                                }
                            } label: {
                                Label("Delete all Sources & Restart", systemImage: "trash.fill")
                            }
                        }
                    } label: {
                        Image(systemName: "ladybug")
                    }
                }
                ToolbarSpacer(.flexible)
            }
            .ignoresSafeArea(edges: .top)
            .navigationDestination(for: Recipe.self) { recipe in
                RecipeDetailView(recipe: recipe)
            }
        }
        .task {
            await model.loadSources()
            if model.currentSource != nil {
                await model.loadCategories()
                await model.loadRandomRecipes()
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
        .sheet(isPresented: $showingAddRecipe) {
            AddEditRecipeView(preselectedCategoryId: isShowingHome ? nil : selectedCategoryID)
                .environmentObject(model)
        }
        .overlay(alignment: .center) {
            if isDebugOperationInProgress {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()

                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5, anchor: .center)
                        Text("Resetting sources...")
                            .font(.headline)
                    }
                    .padding(32)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .transition(.opacity)
            }
        }
    }
}

extension Recipe {
    var imageURL: URL? {
        guard let asset = imageAsset else { return nil }
        return asset.fileURL
    }
}
