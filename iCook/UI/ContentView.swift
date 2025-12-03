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
    @State private var collectionType: RecipeCollectionType? = .home
    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            VStack(spacing: 0) {
                // iCloud status banner
                if !model.cloudKitManager.isCloudKitAvailable {
                    HStack {
                        Image(systemName: "exclamationmark.icloud")
                            .foregroundStyle(.orange)
                        Text("Using local storage only. Sign in to iCloud to enable cloud sync.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.1))
                }

                // Category list
                CategoryList(
                    selection: $selectedCategoryID,
                    editingCategory: $editingCategory,
                    isShowingHome: $isShowingHome,
                    showingAddCategory: $showingAddCategory,
                    collectionType: $collectionType
                )
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 250, max: 400)
            .navigationTitle("iCook") //sidebar title on iOS
        } detail: {
            // Single NavigationStack for the detail view
            NavigationStack(path: $navPath) {
                RecipeCollectionView(collectionType: collectionType ?? .home)
            }
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
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
        .onChange(of: model.currentSource?.id) {
            // Pop to root when switching collections
            navPath = NavigationPath()
            collectionType = .home
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
}

extension Recipe {
    var imageURL: URL? {
        if let cachedImagePath = cachedImagePath {
            let url = URL(fileURLWithPath: cachedImagePath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        guard let asset = imageAsset else { return nil }
        return asset.fileURL
    }
}
